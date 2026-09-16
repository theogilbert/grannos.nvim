-- The results pane's `p`: pin the pane so the next query from the same source
-- buffer opens a fresh pane beside it instead of replacing its content.
package.loaded["grannos.client"] = {
  request = function() return 1 end,
  cancel = function() end,
  capabilities = function() return { drivers = {} } end,
}
package.loaded["grannos"] = { get_conn = function() return nil end }

local results = require("grannos.ui.results")
require("grannos.config").setup({})
require("grannos.hl").setup()

local CONN_KEY = "srv\0sqlite\0g\0db"

--- Every non-floating window in this tab showing a results buffer, in layout order.
--- @return integer[]
local function results_wins()
  local wins = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):find("grannos://results", 1, true)
      and vim.api.nvim_win_get_config(w).relative == "" then
      table.insert(wins, w)
    end
  end
  return wins
end

--- Show a one-row result for `value` from source buffer `src`.
--- @param src   integer
--- @param value string
local function show(src, value)
  results.set_conn_name(CONN_KEY, "SQLite", src)
  results.set_query("select '" .. value .. "'", "sql", src, 0)
  results.show_results({ "v" }, { { value } }, 1, 1, 1.0)
end

--- Whether `buf` renders a cell containing `value`.
--- @param buf   integer
--- @param value string
--- @return boolean
local function shows(buf, value)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:find(value, 1, true) then return true end
  end
  return false
end

describe("results p pins the pane", function()
  local src

  before_each(function()
    vim.cmd("silent! only")
    src = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(src)
  end)

  after_each(function()
    for _, w in ipairs(results_wins()) do pcall(vim.api.nvim_win_close, w, true) end
  end)

  it("keeps the pinned result and opens the next one beside it", function()
    show(src, "first")
    local pinned_win = results_wins()[1]
    local pinned_buf = vim.api.nvim_win_get_buf(pinned_win)
    vim.api.nvim_set_current_win(pinned_win)
    vim.api.nvim_feedkeys("p", "x", false)
    assert.truthy(vim.api.nvim_buf_get_name(pinned_buf):find("(pin 1)", 1, true))

    vim.api.nvim_set_current_win(vim.fn.bufwinid(src))
    show(src, "second")

    local wins = results_wins()
    assert.equals(2, #wins)
    local new_win = wins[1] == pinned_win and wins[2] or wins[1]
    local new_buf = vim.api.nvim_win_get_buf(new_win)
    assert.equals(pinned_buf, vim.api.nvim_win_get_buf(pinned_win))
    assert.are_not.equals(pinned_buf, new_buf)
    assert.is_true(shows(pinned_buf, "first"))
    assert.is_false(shows(pinned_buf, "second"))
    assert.is_true(shows(new_buf, "second"))
    -- Side by side under the default `below` layout: same row, different columns.
    assert.equals(vim.api.nvim_win_get_position(pinned_win)[1], vim.api.nvim_win_get_position(new_win)[1])
    assert.are_not.equals(vim.api.nvim_win_get_position(pinned_win)[2], vim.api.nvim_win_get_position(new_win)[2])
  end)

  it("a third query reuses the unpinned pane, not the pinned one", function()
    show(src, "first")
    vim.api.nvim_set_current_win(results_wins()[1])
    vim.api.nvim_feedkeys("p", "x", false)
    vim.api.nvim_set_current_win(vim.fn.bufwinid(src))
    show(src, "second")
    show(src, "third")
    local wins = results_wins()
    assert.equals(2, #wins)
    local seen = {}
    for _, w in ipairs(wins) do
      local b = vim.api.nvim_win_get_buf(w)
      seen[shows(b, "first") and "first" or (shows(b, "third") and "third" or "?")] = true
    end
    assert.same({ first = true, third = true }, seen)
  end)

  it("pinning twice from the same source numbers the pins", function()
    show(src, "first")
    vim.api.nvim_set_current_win(results_wins()[1])
    vim.api.nvim_feedkeys("p", "x", false)
    vim.api.nvim_set_current_win(vim.fn.bufwinid(src))
    show(src, "second")
    local new_win
    for _, w in ipairs(results_wins()) do
      if shows(vim.api.nvim_win_get_buf(w), "second") then new_win = w end
    end
    vim.api.nvim_set_current_win(new_win)
    vim.api.nvim_feedkeys("p", "x", false)
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(new_win))
    assert.truthy(name:find("(pin ", 1, true))
    assert.is_nil(name:find("(pin 1)", 1, true))
  end)
end)
