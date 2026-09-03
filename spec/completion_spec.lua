-- Stubs must be installed before the modules under test require them.
local requests = {}

--- Canned explore.list responses, keyed by NUL-joined path.
local TREE = {
  [""]                            = { { name = "public", type = "schema",   expandable = true } },
  ["public"]                      = { { name = "users",  type = "table",    expandable = true },
                                      { name = "orders", type = "table",    expandable = true } },
  ["public\0users\0columns"]      = { { name = "id",      type = "int4",    expandable = false },
                                      { name = "email",   type = "text",    expandable = false } },
  ["public\0orders\0columns"]     = { { name = "id",      type = "int4",    expandable = false },
                                      { name = "user_id", type = "int4",    expandable = false },
                                      { name = "total",   type = "numeric", expandable = false } },
}

package.loaded["grannos.client"] = {
  request = function(_method, params, cb)
    local key = table.concat(params.path, "\0")
    requests[#requests + 1] = key
    cb(nil, { items = TREE[key] or {} })
  end,
}
package.loaded["grannos"] = {
  get_conn = function() return { conn_id = "0" } end,
}

local completion = require("grannos.completion")
local context    = require("grannos.completion.context")
local config     = require("grannos.config")

--- Create a SQL buffer holding `lines`, attached for completion.
--- @param lines string[]
--- @return integer
local function sql_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "sql"
  vim.api.nvim_set_current_buf(buf)
  completion.attach(buf, "conn")
  return buf
end

--- Place the cursor at the "|" marker in `lines` and return the buffer, the
--- 0-indexed row, and the cursor's byte column.
--- @param lines string[]
--- @return integer, integer, integer
local function at_marker(lines)
  local row, col
  local clean = {}
  for i, l in ipairs(lines) do
    local before, after = l:match("^(.-)|(.*)$")
    if before then
      row, col = i - 1, #before
      clean[i] = before .. after
    else
      clean[i] = l
    end
  end
  return sql_buf(clean), row, col
end

--- Run omnifunc at the marker and return the candidate words.
---
--- Resolution is chained — the tree's shape has to land before a schema can be
--- listed, and that before its table's columns — so this drives the same rounds
--- the popup's refill callback drives in a live session, and reads the result
--- once they stop producing anything new.
--- @param lines string[]
--- @return string[]
local function complete(lines)
  local buf, row, col = at_marker(lines)
  -- Insert mode first: a completion position is very often at end-of-line,
  -- which normal mode clamps back onto the last character.
  vim.cmd("startinsert!")
  vim.api.nvim_win_set_cursor(0, { row + 1, col })
  local base_start = completion.omnifunc(1, "")
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local base = line:sub(base_start + 1, col)

  local words = {}
  for _ = 1, 4 do
    words = {}
    for _, item in ipairs(completion.omnifunc(0, base)) do words[#words + 1] = item.word end
    vim.wait(20, function() return false end)
  end
  return words
end

describe("completion.context", function()
  before_each(function() config.setup({}) end)

  --- Classify the position at the "|" marker in a single line.
  --- @param line string
  --- @return CompletionContext|nil
  local function classify(line)
    local buf, row, col = at_marker({ line })
    local start = col
    local text  = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    while start > 0 and text:sub(start, start):match("[%w_]") do start = start - 1 end
    return context.at_cursor(buf, row, start, col)
  end

  it("classifies a FROM position as a table", function()
    local ctx = classify("SELECT id FROM |")
    assert.equals("table", ctx.kind)
    assert.is_nil(ctx.schema)
  end)

  it("carries the schema a table reference is qualified with", function()
    local ctx = classify("SELECT id FROM public.|")
    assert.equals("table", ctx.kind)
    assert.equals("public", ctx.schema)
  end)

  it("classifies a JOIN position as a table", function()
    assert.equals("table", classify("SELECT * FROM users u JOIN |").kind)
  end)

  it("resolves a qualified column to the alias before the dot", function()
    local ctx = classify("SELECT u.| FROM public.users u")
    assert.equals("column", ctx.kind)
    assert.equals("u", ctx.qualifier)
  end)

  it("collects every FROM/JOIN source for a bare column", function()
    local ctx = classify("SELECT | FROM users u JOIN orders o ON o.user_id = u.id")
    assert.equals("column", ctx.kind)
    assert.is_nil(ctx.qualifier)
    assert.equals(2, #ctx.sources)
    assert.equals("u", ctx.sources[1].alias)
    assert.equals("o", ctx.sources[2].alias)
  end)

  it("resolves a column in ORDER BY, which hangs off the statement", function()
    local ctx = classify("SELECT * FROM users u ORDER BY |")
    assert.equals("column", ctx.kind)
    assert.equals(1, #ctx.sources)
  end)

  it("resolves a column in a WHERE on a multi-line statement", function()
    local buf, row, col = at_marker({ "SELECT *", "FROM public.users u", "WHERE u.|" })
    local ctx = context.at_cursor(buf, row, col, col)
    assert.equals("column", ctx.kind)
    assert.equals("u", ctx.qualifier)
  end)

  it("recovers an INSERT column list, which the grammar cannot parse", function()
    local ctx = classify("INSERT INTO public.users (|")
    assert.equals("column", ctx.kind)
    assert.same({ "public", "users" }, ctx.sources[1].path)
  end)

  it("returns nil where neither a table nor a column belongs", function()
    assert.is_nil(classify("SELECT * FROM users WHERE id = 'lite|'"))
  end)
end)

describe("completion.omnifunc", function()
  before_each(function()
    config.setup({})
    completion.invalidate()
    requests = {}
  end)

  it("offers the columns of the table an alias binds to", function()
    assert.same({ "email", "id" }, complete({ "SELECT u.| FROM public.users u" }))
  end)

  it("offers the columns of every source, plus their aliases, for a bare column", function()
    local words = complete({ "SELECT | FROM public.users u JOIN public.orders o ON o.user_id = u.id" })
    assert.same({ "email", "id", "o", "total", "u", "user_id" }, words)
  end)

  it("finds the schema of a table the query left unqualified", function()
    assert.same({ "email", "id" }, complete({ "SELECT u.| FROM users u" }))
  end)

  it("offers tables of the schema a reference is qualified with", function()
    assert.same({ "orders", "users" }, complete({ "SELECT * FROM public.|" }))
  end)

  it("offers schemas and tables for an unqualified table position", function()
    assert.same({ "orders", "public", "users" }, complete({ "SELECT * FROM |" }))
  end)

  it("filters candidates by the typed prefix, case-insensitively", function()
    assert.same({ "email" }, complete({ "SELECT u.EM| FROM public.users u" }))
  end)

  it("offers nothing where no reference belongs", function()
    assert.same({}, complete({ "SELECT * FROM users WHERE id = 'x|'" }))
  end)

  it("sends one explore.list per path and never repeats one", function()
    complete({ "SELECT u.| FROM public.users u" })
    complete({ "SELECT u.| FROM public.users u" })
    -- The reference is already schema-qualified, so resolving it costs the
    -- root listing (which says the tree has schemas) and the column listing.
    assert.same({ "", "public\0users\0columns" }, requests)
  end)

  local OMNIFUNC = "v:lua.require'grannos.completion'.omnifunc"

  it("claims omnifunc back when the filetype is set after the connection", function()
    -- A scratch query buffer: associated first, `:set ft=sql` afterwards.
    completion.setup()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    completion.attach(buf, "conn")
    assert.equals("", vim.bo[buf].omnifunc)
    vim.bo[buf].filetype = "sql"
    vim.wait(200, function() return vim.bo[buf].omnifunc == OMNIFUNC end)
    assert.equals(OMNIFUNC, vim.bo[buf].omnifunc)
  end)

  it("wins the omnifunc slot even against a later-registered ftplugin", function()
    -- Vim's ftplugin/sql.vim sets omnifunc to sqlcomplete#Complete from a
    -- FileType handler. If it is registered after ours — which depends on
    -- where the user calls setup() — an inline claim loses, and <C-x><C-o>
    -- answers "The dbext plugin must be loaded for dynamic SQL completion".
    completion.setup()
    local later = vim.api.nvim_create_augroup("GrannosSpecFtplugin", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group   = later, pattern = "sql",
      callback = function(a) vim.bo[a.buf].omnifunc = "sqlcomplete#Complete" end,
    })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    completion.attach(buf, "conn")
    vim.bo[buf].filetype = "sql"
    vim.wait(200, function() return vim.bo[buf].omnifunc == OMNIFUNC end)
    assert.equals(OMNIFUNC, vim.bo[buf].omnifunc)

    vim.api.nvim_del_augroup_by_id(later)
  end)

  it("never sends explore.describe — it reads user data", function()
    complete({ "SELECT | FROM public.users u JOIN public.orders o ON o.id = u.id" })
    for _, key in ipairs(requests) do
      assert.is_truthy(key == "" or key:find("columns", 1, true) or not key:find("\0"))
    end
  end)
end)
