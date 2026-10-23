-- The explorer and results panes go with the query buffer they were opened
-- for: deleting it closes them (pinned results panes excepted), whether its
-- window closes with it (`:bd`) or a buffer-delete plugin keeps that window.
package.loaded["grannos.client"] = {
  request = function(_, _, cb) cb(nil, { items = {} }) return 1 end,
  cancel = function() end,
  capabilities = function() return { drivers = {} } end,
}

local results  = require("grannos.ui.results")
local explorer = require("grannos.ui.explorer")
require("grannos.config").setup({})
require("grannos.hl").setup()

local CONN_KEY = "srv\0sqlite\0g\0db"

--- Return what kind of thing each window of the current tab shows.
--- @return string[]  "explorer", "results", "pinned" or the buffer's file name
local function windows()
  local out = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
    if name:find("grannos://explorer", 1, true) then
      out[#out + 1] = "explorer"
    elseif name:find("grannos://results", 1, true) then
      out[#out + 1] = name:find("(pin", 1, true) and "pinned" or "results"
    else
      out[#out + 1] = vim.fn.fnamemodify(name, ":t")
    end
  end
  table.sort(out)
  return out
end

--- Open a query buffer named `name` in the current window, show a result for
--- it and open its explorer, leaving the cursor in the query window.
--- @param name string
--- @return integer bufnr
local function query_buffer(name)
  vim.cmd("enew")
  vim.api.nvim_buf_set_name(0, name)
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  results.set_conn_name(CONN_KEY, "SQLite", buf)
  results.set_query("select 1", "sql", buf, 0)
  results.show_results({ "a" }, { { 1 } }, 1, 1, 1.0)
  explorer.open("c", "db", "sqlite", CONN_KEY, "SQLite")
  vim.api.nvim_set_current_win(win)
  return buf
end

--- Let the scheduled pane teardown run.
local function settle() vim.wait(50, function() return false end) end

describe("panes follow their query buffer", function()
  before_each(function()
    vim.cmd("silent! %bwipeout!")
    vim.cmd("enew")
    vim.api.nvim_buf_set_name(0, "other.sql")
  end)

  it("closes both when the buffer is deleted with its window kept open", function()
    local buf = query_buffer("a.sql")
    assert.same({ "a.sql", "explorer", "results" }, windows())
    vim.cmd("buffer other.sql")
    vim.cmd("bdelete! " .. buf)
    settle()
    assert.same({ "other.sql" }, windows())
  end)

  it("leaves an ordinary window behind when :bd closes the last query window", function()
    local buf = query_buffer("a.sql")
    vim.cmd("bdelete! " .. buf)
    settle()
    assert.same({ "other.sql" }, windows())
    assert.is_false(vim.wo.winfixwidth)
    assert.is_false(vim.wo.winfixheight)
    assert.equals("", vim.wo.winbar)
  end)

  it("leaves the panes of another query window alone", function()
    local a = query_buffer("a.sql")
    vim.cmd("rightbelow vsplit")
    query_buffer("b.sql")
    vim.cmd("bdelete! " .. a)
    settle()
    assert.same({ "b.sql", "explorer", "results" }, windows())
  end)

  it("keeps a pinned results pane", function()
    local buf  = query_buffer("a.sql")
    local host = vim.api.nvim_get_current_win()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find("grannos://results", 1, true) then
        vim.api.nvim_set_current_win(w)
      end
    end
    vim.api.nvim_feedkeys("P", "x", false)
    vim.api.nvim_set_current_win(host)
    vim.cmd("buffer other.sql")
    vim.cmd("bdelete! " .. buf)
    settle()
    assert.same({ "other.sql", "pinned" }, windows())
  end)

  it("does not leak panel options into the global defaults", function()
    query_buffer("a.sql")
    assert.is_false(vim.go.winfixwidth)
    assert.is_false(vim.go.winfixheight)
    assert.equals("", vim.go.winbar)
  end)
end)
