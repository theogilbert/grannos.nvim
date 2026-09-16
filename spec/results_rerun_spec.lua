-- The results pane's `R`: run the query that produced the results again,
-- against the same connection and from the same source buffer.
package.loaded["grannos.client"] = {
  request = function() return 1 end,
  cancel = function() end,
  capabilities = function() return { drivers = {} } end,
}

local CONN_KEY = "srv\0sqlite\0g\0db"
local CONN     = { conn_id = 1, driver = "sqlite", driver_label = "SQLite", key = CONN_KEY }
local conn_open = true
package.loaded["grannos"] = {
  get_conn = function(key) return (conn_open and key == CONN_KEY) and CONN or nil end,
}

local session_opened = {}
package.loaded["grannos"].open_session_settings_for = function(key) table.insert(session_opened, key) end

local runs = {}
package.loaded["grannos.executor"] = {
  run = function(conn, query, bufnr, first_line)
    table.insert(runs, { conn = conn, query = query, bufnr = bufnr, first_line = first_line })
  end,
}

local results = require("grannos.ui.results")
require("grannos.config").setup({})
require("grannos.hl").setup()

local SQL = "select 1,\n  2"

--- The results window in this tab.
--- @return integer|nil
local function results_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):find("grannos://results", 1, true) then return w end
  end
end

--- Press `R` in the results window.
local function press_R()
  vim.api.nvim_set_current_win(results_win())
  vim.api.nvim_feedkeys("R", "x", false)
end

--- A source buffer holding SQL at line 1 (0-indexed).
--- @return integer
local function source_buf()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- header", "select 1,", "  2", "-- trailer" })
  vim.bo[buf].filetype = "sql"
  return buf
end

--- Show a result for SQL run from `src` at `first_line`, as executor.run would.
--- @param src        integer|nil
--- @param first_line integer|nil
local function show(src, first_line)
  results.set_conn_name(CONN_KEY, "SQLite", src)
  results.set_query(SQL, "sql", src, first_line)
  results.show_results({ "a", "b" }, { { 1, 2 } }, 1, 1, 1.0)
end

describe("results R re-runs the query", function()
  local notices

  before_each(function()
    runs      = {}
    notices   = {}
    conn_open = true
    vim.notify = function(msg) table.insert(notices, msg) end
  end)

  after_each(function()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if #vim.api.nvim_tabpage_list_wins(0) > 1 then pcall(vim.api.nvim_win_close, w, true) end
    end
  end)

  it("runs the stored query against the same connection and source position", function()
    local src = source_buf()
    show(src, 1)
    press_R()
    assert.equals(1, #runs)
    assert.equals(CONN, runs[1].conn)
    assert.equals(SQL, runs[1].query)
    assert.equals(src, runs[1].bufnr)
    assert.equals(1, runs[1].first_line)
  end)

  it("drops the source position when the buffer no longer holds the query there", function()
    local src = source_buf()
    show(src, 1)
    vim.api.nvim_buf_set_lines(src, 1, 2, false, { "select 42," })
    press_R()
    assert.equals(1, #runs)
    assert.equals(SQL, runs[1].query)
    assert.equals(src, runs[1].bufnr)
    assert.is_nil(runs[1].first_line)
  end)

  it("does nothing without a query", function()
    results.set_conn_name(CONN_KEY, "SQLite", nil)
    results.show_results({ "a" }, { { 1 } }, 1, 1, 1.0)
    press_R()
    assert.equals(0, #runs)
    assert.truthy(notices[1]:find("no query"))
  end)

  it("does nothing when the connection is closed", function()
    show(source_buf(), 1)
    conn_open = false
    press_R()
    assert.equals(0, #runs)
    assert.truthy(notices[1]:find("connection"))
  end)

  it("s opens the session settings for the results' connection", function()
    show(source_buf(), 1)
    session_opened = {}
    vim.api.nvim_set_current_win(results_win())
    vim.api.nvim_feedkeys("s", "x", false)
    assert.same({ CONN_KEY }, session_opened)
  end)

  it("does nothing when the source buffer is gone", function()
    local src = source_buf()
    show(src, 1)
    vim.api.nvim_buf_delete(src, { force = true })
    press_R()
    assert.equals(0, #runs)
    assert.truthy(notices[1]:find("source buffer"))
  end)
end)
