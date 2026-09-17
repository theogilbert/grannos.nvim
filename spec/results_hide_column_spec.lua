-- The results pane's `x`: hide the column under the cursor in place, saved
-- like a picker selection so it sticks for the next result with these columns.
package.loaded["grannos.client"] = {
  request = function() return 1 end,
  cancel = function() end,
  capabilities = function() return { drivers = {} } end,
}
package.loaded["grannos"] = { get_conn = function() return nil end }

local results       = require("grannos.ui.results")
local col_selection = require("grannos.col_selection")
require("grannos.config").setup({})
require("grannos.hl").setup()

local COLS = { "id", "name", "email" }

--- The results window in this tab.
--- @return integer|nil
local function results_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):find("grannos://results", 1, true) then return w end
  end
end

--- The header row of the rendered table.
--- @return string
local function header()
  local buf = vim.api.nvim_win_get_buf(results_win())
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:find("│", 1, true) then return l end
  end
  return ""
end

--- Press `x` with the cursor on the table header, at display column `vcol`.
--- @param vcol integer
local function press_x_at(vcol)
  local win = results_win()
  vim.api.nvim_set_current_win(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local row
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:find("│", 1, true) then row = i; break end
  end
  vim.api.nvim_win_set_cursor(win, { row, 0 })
  vim.cmd(("normal! %d|"):format(vcol))
  vim.api.nvim_feedkeys("x", "x", false)
end

--- The display column of `name` in the header row.
--- @param name string
--- @return integer
local function vcol_of(name)
  local h = header()
  local byte = h:find(name, 1, true)
  return vim.fn.strdisplaywidth(h:sub(1, byte - 1)) + 1
end

--- Show a result with COLS, after one with other columns: the pane keeps its
--- selection across re-runs of the same column list, so this is what makes
--- it consult the store afresh.
local function show()
  results.set_conn_name("srv\0sqlite\0g\0db", "SQLite", nil)
  results.set_query("select 1", "sql")
  results.show_results({ "other" }, { { 1 } }, 1, 1, 1.0)
  results.show_results(COLS, { { 1, "a", "a@x" } }, 1, 1, 1.0)
end

describe("results x hides the column under the cursor", function()
  local tmp
  local KEY = "srv\0sqlite\0g\0db"

  before_each(function()
    tmp = vim.fn.tempname() .. ".json"
    col_selection.file = tmp
    col_selection.clear_cache()
    show()
  end)

  after_each(function()
    col_selection.file = nil
    col_selection.clear_cache()
    vim.fn.delete(tmp)
    vim.cmd("silent! only")
  end)

  it("drops the column and keeps the rest in order", function()
    press_x_at(vcol_of("name"))
    local h = header()
    assert.is_truthy(h:find("id", 1, true))
    assert.is_nil(h:find("name", 1, true))
    assert.is_truthy(h:find("email", 1, true))
  end)

  it("persists like a picker selection", function()
    press_x_at(vcol_of("name"))
    assert.same({ "id", "email" }, col_selection.load(KEY, COLS))
    show()
    assert.is_nil(header():find("name", 1, true))
  end)

  it("does nothing off the table", function()
    local win = results_win()
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })  -- the row-count label
    vim.api.nvim_feedkeys("x", "x", false)
    assert.same({ "id", "name", "email" }, col_selection.load(KEY, COLS) or COLS)
    assert.is_truthy(header():find("name", 1, true))
  end)
end)
