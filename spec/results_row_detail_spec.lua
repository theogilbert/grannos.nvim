-- The results pane's `<CR>`: open the row under the cursor in a float as a
-- vertical `column │ value` table, honouring its values' newlines and tabs.
package.loaded["grannos.client"] = {
  request = function() return 1 end,
  cancel = function() end,
  capabilities = function() return { drivers = {} } end,
}
package.loaded["grannos"] = { get_conn = function() return nil end }

local results    = require("grannos.ui.results")
local row_detail = require("grannos.ui.row_detail")
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

--- Press `<CR>` in the results window with the cursor on the line containing `needle`.
--- @param needle string
local function press_enter_on(needle)
  local win = results_win()
  vim.api.nvim_set_current_win(win)
  local buf = vim.api.nvim_win_get_buf(win)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:find(needle, 1, true) then
      vim.api.nvim_win_set_cursor(win, { i, 0 })
      break
    end
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
end

--- The floating window open in this tab, if any.
--- @return integer|nil
local function float_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then return w end
  end
end

describe("row_detail.layout", function()
  it("holds the values verbatim, one field after another with an empty line between", function()
    local lay = row_detail.layout({ "id", "body" }, { 1, "a\n\tb\r\nc" })
    assert.same({ "1", "", "a", "\tb", "c" }, lay.lines)
    assert.same({ 1 }, lay.rules)
  end)

  it("never breaks a long value itself", function()
    local long = string.rep("x", 500)
    assert.same({ long }, row_detail.layout({ "v" }, { long }).lines)
  end)

  it("puts the names in the statuscolumn cells, beside each value's first line", function()
    local lay = row_detail.layout({ "id", "body" }, { 1, "a\nb" })
    assert.truthy(lay.cells[1]:find("id  ", 1, true))
    assert.truthy(lay.cells[3]:find("body", 1, true))
    assert.equal(lay.wrap_cell, lay.cells[4])
  end)

  it("shows NULL and placeholders by their text", function()
    local lay = row_detail.layout({ "a", "b" }, { vim.NIL, { type = "lob", text = "<BLOB 3 bytes>" } })
    assert.same({ "NULL", "", "<BLOB 3 bytes>" }, lay.lines)
  end)
end)

describe("results <CR> opens the row under the cursor", function()
  after_each(function()
    local w = float_win()
    if w then vim.api.nvim_win_close(w, true) end
  end)

  it("in a single result", function()
    results.set_conn_name("srv\0sqlite\0g\0db", "SQLite", nil)
    results.set_query("select 1", "sql")
    results.show_results({ "id", "note" }, { { 1, "first" }, { 2, "line1\nline2" } }, 2, 2, 1.0)
    press_enter_on("line1")
    local w = float_win()
    assert.is_not_nil(w)
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
    assert.same({ "2", "", "line1", "line2" }, lines)
  end)

  it("does nothing on the header", function()
    results.show_results({ "id", "note" }, { { 1, "first" } }, 1, 1, 1.0)
    press_enter_on("note")
    assert.is_nil(float_win())
  end)

  it("in a batch result", function()
    results.begin_batch(2)
    results.append_batch_result(1, 2, { "a" }, { { "x1" } }, 1, 1, 1.0, "select 1")
    results.append_batch_result(2, 2, { "b", "c" }, { { "y1", "z1" }, { "y2", "z2" } }, 2, 2, 1.0, "select 2")
    press_enter_on("y2")
    local w = float_win()
    assert.is_not_nil(w)
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
    assert.same({ "y2", "", "z2" }, lines)
  end)
end)
