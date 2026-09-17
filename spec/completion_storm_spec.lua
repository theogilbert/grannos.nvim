-- The nvim-cmp source against a backend that answers late, with many
-- listings in flight at once — the shape of an unqualified table on a
-- server with many schemas. Every landing asks cmp to complete again, and
-- that must not compound: a re-request registered on each still-pending
-- path by each landing would fire 2^n callbacks by the n-th one.
local completes = 0
local source

package.loaded["cmp"] = {
  register_source = function(_, s) source = s end,
  visible  = function() return true end,
  complete = function()
    completes = completes + 1
    source:complete({ context = {} }, function() end)
  end,
}
package.loaded["cmp.types"] = {
  lsp = { CompletionItemKind = { Text = 1, Module = 9, Field = 5, Variable = 6, Struct = 22 } },
}

local N_SCHEMAS = 14

--- Responses are held back until `flush` is called, so every schema listing
--- is in flight at the same time.
local held = {}
package.loaded["grannos.client"] = {
  request = function(_method, params, cb)
    local path = params.path
    local items
    if #path == 0 then
      items = {}
      for i = 1, N_SCHEMAS do items[i] = { name = "s" .. i, type = "schema", expandable = true } end
    elseif #path == 1 then
      items = path[1] == "s" .. N_SCHEMAS and { { name = "users", type = "table", expandable = true } } or {}
    else
      items = { { name = "id", type = "INTEGER" } }
    end
    held[#held + 1] = function() cb(nil, { items = items }) end
  end,
}
package.loaded["grannos"] = { get_conn = function() return { conn_id = "0" } end }

-- The source only re-requests while the user is still inserting; a headless
-- run never is, so stand in for the mode check.
vim.fn.mode = function() return "i" end

local completion = require("grannos.completion")
require("grannos.completion.cmp").setup()
require("grannos.config").setup({ completion = { max_schema_scan = N_SCHEMAS } })

--- Deliver every held response, in order, letting the scheduled work each
--- one triggers run before the next.
local function flush()
  while #held > 0 do
    local batch = held
    held = {}
    for _, respond in ipairs(batch) do
      respond()
      vim.wait(10, function() return false end)
    end
  end
end

describe("completion.cmp under many in-flight listings", function()
  it("asks cmp to complete once per landing, not once per callback ever registered", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "SELECT u. FROM users u" })
    vim.bo[buf].filetype = "sql"
    vim.api.nvim_set_current_buf(buf)
    completion.attach(buf, "conn")
    vim.cmd("startinsert!")
    vim.api.nvim_win_set_cursor(0, { 1, 9 })

    flush()  -- the prime (root listing)
    source:complete({ context = {} }, function() end)
    flush()  -- root again if needed, then every schema, then the columns

    -- One complete per listing that landed is the most a linear scheme
    -- needs: root, N schemas, one columns listing, with a little slack.
    assert.is_true(completes <= 2 * (N_SCHEMAS + 2),
      ("cmp.complete() was called %d times"):format(completes))
    assert.is_true(completes >= N_SCHEMAS, "the menu was never refilled")
  end)

  it("does not sweep the schemas for an unqualified table past max_schema_scan", function()
    require("grannos.config").setup({ completion = { max_schema_scan = N_SCHEMAS - 1 } })
    completion.invalidate()
    held, completes = {}, 0
    local requests = 0
    local request = package.loaded["grannos.client"].request
    package.loaded["grannos.client"].request = function(m, params, cb)
      requests = requests + 1
      request(m, params, cb)
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "SELECT u. FROM users u" })
    vim.bo[buf].filetype = "sql"
    vim.api.nvim_set_current_buf(buf)
    completion.attach(buf, "conn")
    vim.api.nvim_win_set_cursor(0, { 1, 9 })
    flush()
    source:complete({ context = {} }, function() end)
    flush()
    -- The root listing only: no schema was listed to find `users`.
    assert.is_true(requests <= 2, ("%d listings were sent"):format(requests))
  end)
end)
