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

describe("row_detail.render", function()
  it("lays a row out as name │ value lines", function()
    local lines = row_detail.render({ "id", "name" }, { 1, "bob" }, 40)
    assert.same({ "id   │ 1", "name │ bob" }, lines)
  end)

  it("continues a value's newlines under the value column and expands its tabs", function()
    local lines = row_detail.render({ "id", "body" }, { 1, "a\n\tb\r\nc" }, 40)
    assert.same({ "id   │ 1", "body │ a", "     │     b", "     │ c" }, lines)
  end)

  it("wraps a long value under the value column", function()
    local lines = row_detail.render({ "v" }, { string.rep("x", 10) }, 8)
    assert.same({ "v │ xxxx", "  │ xxxx", "  │ xx" }, lines)
  end)

  it("shows NULL and placeholders by their text", function()
    local lines = row_detail.render({ "a", "b" }, { vim.NIL, { type = "lob", text = "<BLOB 3 bytes>" } }, 40)
    assert.same({ "a │ NULL", "b │ <BLOB 3 bytes>" }, lines)
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
    assert.same({ "id   │ 2", "note │ line1", "     │ line2" }, lines)
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
    assert.same({ "b │ y2", "c │ z2" }, lines)
  end)
end)
