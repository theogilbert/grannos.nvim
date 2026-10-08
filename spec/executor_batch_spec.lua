-- A batch run's gutter marks: every statement's old mark is cleared the
-- moment the batch is asked for, not as each statement's turn comes.
local pending = {}  -- execute callbacks, in request order
package.loaded["grannos.client"] = {
  request = function(_, _, on_done)
    table.insert(pending, on_done)
    return #pending
  end,
  cancel = function() end,
}
package.loaded["grannos.connections"] = { get = function() return { allow_writes = true } end }
package.loaded["grannos.log"] = { add = function() return "log" end, update = function() end }
package.loaded["grannos.ui.results"] = setmetatable({}, { __index = function() return function() end end })

require("grannos.config").setup({})
local gutter   = require("grannos.ui.gutter")
local executor = require("grannos.executor")
gutter.setup()

local CONN  = { conn_id = 1, key = "srv\0sqlite\0g\0db", driver_label = "SQLite" }
local LINES = { "select 1;", "select 2;", "select 3;" }

--- Settle every vim.schedule callback queued so far.
local function settle()
  vim.wait(50, function() return false end)
end

--- Answer the oldest pending execute request with an empty result.
local function finish_next()
  table.remove(pending, 1)(nil, { columns = {}, rows = {} })
  settle()
end

--- The gutter sign on each line that has one, by 0-indexed line.
--- @param bufnr integer
--- @return table<integer, string>
local function signs(bufnr)
  local ns  = vim.api.nvim_get_namespaces()["GrannosGutter"]
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
    out[m[2]] = m[4].sign_hl_group
  end
  return out
end

describe("executor batch gutter marks", function()
  local bufnr

  before_each(function()
    pending = {}
    bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, LINES)
    vim.bo[bufnr].filetype = "sql"
  end)

  --- Run the whole buffer as one batch.
  local function run_all()
    executor.run(CONN, table.concat(LINES, "\n"), bufnr, 0)
  end

  it("clears every statement's previous mark as soon as the batch starts", function()
    run_all()
    finish_next(); finish_next(); finish_next()
    assert.same({ [0] = "GrannosQuerySuccess", [1] = "GrannosQuerySuccess", [2] = "GrannosQuerySuccess" },
      signs(bufnr))

    run_all()
    -- Only the first statement has started; the others wait, unmarked.
    assert.same({ [0] = "GrannosQueryRunning" }, signs(bufnr))
    finish_next()
    assert.same({ [0] = "GrannosQuerySuccess", [1] = "GrannosQueryRunning" }, signs(bufnr))
  end)

  it("leaves marks outside the batch alone", function()
    executor.run(CONN, LINES[3], bufnr, 2)
    finish_next()
    executor.run(CONN, table.concat({ LINES[1], LINES[2] }, "\n"), bufnr, 0)
    assert.same({ [0] = "GrannosQueryRunning", [2] = "GrannosQuerySuccess" }, signs(bufnr))
  end)
end)
