-- The results pane's H/L: scroll one column at a time, from any line of the
-- pane — including lines too short to hold the cursor at the new column.
package.loaded["grannos.client"] = {
  request = function() return 1 end,
  cancel = function() end,
  capabilities = function() return { drivers = {} } end,
}
package.loaded["grannos"] = { get_conn = function() return nil end }

local results = require("grannos.ui.results")
require("grannos.config").setup({})
require("grannos.hl").setup()

--- The results window in this tab.
--- @return integer|nil
local function results_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):find("grannos://results", 1, true) then return w end
  end
end

describe("results H/L", function()
  local columns

  before_each(function()
    columns = vim.o.columns
    vim.o.columns = 40
    local cols, row = {}, {}
    for i = 1, 12 do cols[i] = "column_" .. i; row[i] = "value" .. i end
    results.set_conn_name("srv\0sqlite\0g\0db", "SQLite", nil)
    results.set_query("select 1", "sql")
    results.show_results(cols, { row }, 1, 1, 1.0)
    vim.api.nvim_set_current_win(results_win())
  end)

  after_each(function()
    vim.o.columns = columns
    vim.cmd("silent! only")
  end)

  it("scrolls from the blank line above the table instead of failing", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    assert.equal("", vim.api.nvim_get_current_line())
    vim.api.nvim_feedkeys("LL", "x", false)
    assert.is_true(vim.fn.winsaveview().leftcol > 0)
    vim.api.nvim_feedkeys("HH", "x", false)
    assert.equal(0, vim.fn.winsaveview().leftcol)
  end)

  it("scrolls from every line of the pane", function()
    local n = vim.api.nvim_buf_line_count(0)
    for lnum = 1, n do
      vim.fn.winrestview({ leftcol = 0 })
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      vim.api.nvim_feedkeys("LLLHL", "x", false)
      assert.is_true(vim.fn.winsaveview().leftcol > 0, "line " .. lnum)
    end
  end)
end)
