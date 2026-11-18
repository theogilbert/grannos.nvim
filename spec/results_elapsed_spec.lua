-- The elapsed time shown on a running query's loading line and a running
-- batch's progress line, advanced once a second.
package.loaded["grannos.client"] = { request = function() end, cancel = function() end }

local results = require("grannos.ui.results")
require("grannos.config").setup({})
require("grannos.hl").setup()

--- Return the results buffer's lines.
--- @return string[]
local function lines()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):find("grannos://results", 1, true) then
      return vim.api.nvim_buf_get_lines(b, 0, -1, false)
    end
  end
  return {}
end

--- Wait until the results buffer's line `lnum` (1-indexed, negative from the
--- end) ends with `suffix`, failing after `ms`.
--- @param lnum   integer
--- @param suffix string
--- @param ms     integer
local function wait_for(lnum, suffix, ms)
  local ok = vim.wait(ms, function()
    local ls = lines()
    local l = ls[lnum > 0 and lnum or #ls + 1 + lnum] or ""
    return l:sub(-#suffix) == suffix
  end, 50)
  assert.is_true(ok, "never saw " .. suffix .. " in: " .. vim.inspect(lines()))
end

describe("results elapsed time", function()
  before_each(function() results.set_conn_name(nil, nil, nil) end)

  it("counts up on the loading line, keeping one clock across phases", function()
    results.show_loading("Executing…")
    assert.is_truthy(lines()[1]:find("Executing…  0s$"))
    wait_for(1, "Executing…  1s", 1600)
    results.show_loading("Processing…")
    assert.is_truthy(lines()[1]:find("Processing…  1s$"))
    results.show_message("done")
  end)

  it("stops once a result replaces the loading line", function()
    results.show_loading("Executing…")
    results.show_message("done")
    vim.wait(1300)
    assert.same({ "done" }, lines())
  end)

  it("counts up on a batch's progress line", function()
    results.begin_batch(2)
    wait_for(-1, "0 / 2 completed  1s", 1600)
    results.append_batch_rows_affected(1, 2, 1, "updated", 1.0, "UPDATE t SET x = 1")
    assert.is_truthy(lines()[#lines()]:find("1 / 2 completed  1s$"))
    results.append_batch_error(2, 2, "boom", "SELECT nope")
    assert.is_falsy(lines()[#lines()]:find("completed"))
  end)
end)
