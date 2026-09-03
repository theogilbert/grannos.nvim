-- The nvim-cmp source, exercised against a stubbed cmp so the suite carries no
-- dependency on the plugin being installed.
local registered = {}

package.loaded["cmp"] = {
  register_source = function(name, source) registered[name] = source end,
  visible = function() return false end,
  complete = function() end,
}
package.loaded["cmp.types"] = {
  lsp = {
    CompletionItemKind = { Text = 1, Module = 9, Field = 5, Variable = 6, Struct = 22 },
  },
}

local TREE = {
  [""]                = { { name = "users", type = "table", expandable = true } },
  ["users\0columns"]  = { { name = "id",    type = "INTEGER" },
                          { name = "email", type = "TEXT" } },
}
package.loaded["grannos.client"] = {
  request = function(_method, params, cb)
    cb(nil, { items = TREE[table.concat(params.path, "\0")] or {} })
  end,
}
package.loaded["grannos"] = { get_conn = function() return { conn_id = "0" } end }

local completion = require("grannos.completion")
local cmp_source = require("grannos.completion.cmp")
require("grannos.config").setup({})

--- Open a SQL buffer holding `line`, attached, with the cursor at `col`.
--- @param line string
--- @param col  integer  0-indexed byte column
--- @return integer
local function buf_at(line, col)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.bo[buf].filetype = "sql"
  vim.api.nvim_set_current_buf(buf)
  completion.attach(buf, "conn")
  vim.cmd("startinsert!")
  vim.api.nvim_win_set_cursor(0, { 1, col })
  return buf
end

--- Call the source's complete() until the listings it needs have landed, and
--- return the last response.
--- @return table
local function complete_response()
  local last
  for _ = 1, 4 do
    cmp_source.source:complete({ context = {} }, function(res) last = res end)
    vim.wait(20, function() return false end)
  end
  return last
end

describe("completion.cmp", function()
  before_each(function() completion.invalidate() end)

  it("registers itself with cmp under a stable name", function()
    assert.is_true(cmp_source.setup())
    assert.is_not_nil(registered[cmp_source.NAME])
    assert.equals("grannos", cmp_source.NAME)
  end)

  it("triggers on '.', where a qualified column list is wanted", function()
    assert.same({ "." }, cmp_source.source:get_trigger_characters())
  end)

  it("is unavailable in a buffer with no connection", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    assert.is_false(cmp_source.source:is_available())
  end)

  it("is available once the buffer has a connection", function()
    buf_at("SELECT 1", 8)
    assert.is_true(cmp_source.source:is_available())
  end)

  it("returns the qualified column list as cmp items with LSP kinds", function()
    buf_at("SELECT * FROM users u WHERE u.", 30)
    local res = complete_response()
    local labels = {}
    for _, it in ipairs(res.items) do labels[#labels + 1] = it.label end
    table.sort(labels)
    assert.same({ "email", "id" }, labels)
    assert.equals(5, res.items[1].kind)             -- Field
    assert.is_truthy(res.items[1].detail:find("·", 1, true))
  end)

  it("marks the response incomplete while a listing is still in flight", function()
    buf_at("SELECT * FROM users u WHERE u.", 30)
    local first
    cmp_source.source:complete({ context = {} }, function(res) first = res end)
    assert.is_true(first.isIncomplete)
    -- ...and complete once everything it needed has arrived.
    assert.is_false(complete_response().isIncomplete)
  end)

  it("returns an unfiltered list, leaving matching to cmp", function()
    buf_at("SELECT * FROM users u WHERE u.em", 32)
    local res = complete_response()
    assert.equals(2, #res.items)  -- both columns, not just the one matching "em"
  end)
end)
