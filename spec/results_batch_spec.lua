-- The batch view of the results panel: segments appended one statement at a
-- time, with a progress line underneath until the last one lands.
package.loaded["grannos.client"] = { request = function() end, cancel = function() end }

local results = require("grannos.ui.results")
require("grannos.config").setup({})
require("grannos.hl").setup()

--- Return the results buffer's lines.
--- @return string[]
local function lines()
  local buf = vim.fn.bufnr("grannos://results")
  if buf == -1 then
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find("grannos://results", 1, true) then buf = b; break end
    end
  end
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Return the lines that mention batch progress, minus the running icon.
--- @return string[]
local function progress_lines()
  local out = {}
  for _, l in ipairs(lines()) do
    if l:find("completed", 1, true) then out[#out + 1] = l:match("Executing.*$") end
  end
  return out
end

describe("results batch progress", function()
  before_each(function()
    results.set_conn_name(nil, nil, nil)
    results.begin_batch(3)
  end)

  it("starts at zero completed", function()
    assert.same({ "Executing 3 queries… 0 / 3 completed" }, progress_lines())
  end)

  it("advances as each statement's segment is appended, whatever its outcome", function()
    results.append_batch_rows_affected(1, 3, 2, "updated", 1.0, "UPDATE t SET x = 1")
    assert.same({ "Executing 3 queries… 1 / 3 completed" }, progress_lines())
    results.append_batch_error(2, 3, "boom", "SELECT nope")
    assert.same({ "Executing 3 queries… 2 / 3 completed" }, progress_lines())
  end)

  it("keeps the progress line below the segments", function()
    results.append_batch_error(1, 3, "boom", "SELECT nope")
    local all = lines()
    assert.is_truthy(all[#all]:find("1 / 3 completed", 1, true))
  end)

  it("drops the progress line once the last statement lands", function()
    results.append_batch_error(1, 3, "boom", "SELECT 1")
    results.append_batch_error(2, 3, "boom", "SELECT 2")
    results.append_batch_result(3, 3, { "id" }, { { 1 } }, 1, 1, 1.0, "SELECT id FROM t")
    assert.same({}, progress_lines())
  end)
end)
