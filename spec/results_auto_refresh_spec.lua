-- The results pane's `gr`: re-run the pane's query on a timer, off by default.
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

local results = require("grannos.ui.results")

-- Stands in for executor.run: records the run and, unless `hold` is set,
-- answers it straight away through the same results calls the executor makes.
local runs = {}
local hold = false
local answer_rows = { { 1, 2 } }
package.loaded["grannos.executor"] = {
  run = function(conn, query, bufnr, first_line, opts)
    table.insert(runs, { conn = conn, query = query, bufnr = bufnr, first_line = first_line, opts = opts or {} })
    local target = results.set_conn_name(conn.key, conn.driver_label, bufnr,
      { target = opts and opts.target, auto = opts and opts.auto })
    results.set_query(query, "sql", bufnr, first_line, opts and opts.values)
    results.show_loading("Executing…")
    if hold then return end
    results.activate(target)
    results.show_results({ "a", "b" }, answer_rows, #answer_rows, #answer_rows, 1.0)
  end,
}

require("grannos.config").setup({ results = { auto_refresh_intervals = { "0.05s", "1m" } } })
require("grannos.hl").setup()

local SQL = "select 1, 2"

--- The results window in this tab.
--- @return integer|nil
local function results_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):find("grannos://results", 1, true) then return w end
  end
end

--- Show a result for SQL run from `src`, as executor.run would.
--- @param src integer
local function show(src)
  results.set_conn_name(CONN_KEY, "SQLite", src)
  results.set_query(SQL, "sql", src, 0, { id = "42" })
  results.show_results({ "a", "b" }, answer_rows, #answer_rows, #answer_rows, 1.0)
end

--- Press `gr` in the results window and pick the item whose label contains `label`.
--- @param label string
local function pick(label)
  vim.ui.select = function(items, opts, cb)
    for _, it in ipairs(items) do
      if opts.format_item(it):find(label, 1, true) then return cb(it) end
    end
    error("no item " .. label)
  end
  vim.api.nvim_set_current_win(results_win())
  vim.api.nvim_feedkeys("gr", "x", false)
end

--- Turn auto-refresh off from the results window `win`, wherever it is.
--- @param win integer
local function pick_off_in(win)
  vim.ui.select = function(items, _, cb) cb(items[1]) end
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys("gr", "x", false)
end

--- The auto-refresh indicator's text on the first line of the results
--- buffer (the one in `win`, else the results window in this tab), or nil.
--- @param win integer|nil
--- @return string|nil
local function indicator(win)
  local buf = vim.api.nvim_win_get_buf(win or results_win())
  local ns  = vim.api.nvim_get_namespaces()["GrannosAutoRefresh"]
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { 0, 0 }, { 0, -1 }, { details = true })
  return marks[1] and marks[1][4].virt_text[1][1]
end

describe("results auto-refresh", function()
  local src

  before_each(function()
    runs, hold, conn_open = {}, false, true
    answer_rows = { { 1, 2 } }
    vim.notify = function() end
    src = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { SQL })
    vim.api.nvim_set_current_buf(src)
  end)

  after_each(function()
    if results_win() then pcall(pick, "Off") end
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if #vim.api.nvim_tabpage_list_wins(0) > 1 then pcall(vim.api.nvim_win_close, w, true) end
    end
  end)

  it("parses intervals", function()
    assert.equals(30000, results.parse_interval("30s"))
    assert.equals(30000, results.parse_interval("30"))
    assert.equals(120000, results.parse_interval("2m"))
    assert.equals(3600000, results.parse_interval("1h"))
    assert.is_nil(results.parse_interval("0s"))
    assert.is_nil(results.parse_interval("soon"))
  end)

  it("is off until chosen", function()
    show(src)
    vim.wait(150, function() return false end)
    assert.equals(0, #runs)
    assert.is_nil(indicator())
  end)

  it("re-runs the query unattended into its own pane until turned off", function()
    show(src)
    pick("0.05s")
    assert.truthy(indicator():find("every 0.05s", 1, true))
    assert.is_true(vim.wait(500, function() return #runs >= 2 end))
    local r = runs[1]
    assert.equals(SQL, r.query)
    assert.is_true(r.opts.auto)
    assert.same({ id = "42" }, r.opts.values)
    assert.is_not_nil(r.opts.target)
    pick("Off")
    assert.is_nil(indicator())
    local n = #runs
    vim.wait(150, function() return false end)
    assert.equals(n, #runs)
  end)

  it("keeps the last result, cursor and page on screen while a refresh is out", function()
    answer_rows = {}
    for i = 1, 30 do answer_rows[i] = { i, i } end
    show(src)
    local win = results_win()
    vim.api.nvim_win_set_cursor(win, { 10, 0 })
    local before = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    hold = true
    pick("0.05s")
    assert.is_true(vim.wait(500, function() return #runs >= 1 end))
    assert.same(before, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false))
    assert.equals(10, vim.api.nvim_win_get_cursor(win)[1])
    -- The run is still out: no second one is sent on top of it.
    vim.wait(150, function() return false end)
    assert.equals(1, #runs)
    -- Its answer lands without moving the cursor, and the indicator survives the redraw.
    results.show_results({ "a", "b" }, answer_rows, #answer_rows, #answer_rows, 1.0)
    assert.equals(10, vim.api.nvim_win_get_cursor(win)[1])
    assert.truthy(indicator():find("every", 1, true))
  end)

  it("keeps the indicator on the first line after a refresh, with the time it landed", function()
    show(src)
    pick("0.05s")
    assert.is_nil(indicator():find("last", 1, true))
    assert.is_true(vim.wait(500, function() return #runs >= 1 end))
    local text = indicator()
    assert.truthy(text:find("every 0.05s", 1, true))
    assert.truthy(text:find("last %d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d"))
  end)

  it("refreshes in the pane's own tab while the user is in another", function()
    show(src)
    local win = results_win()
    pick("0.05s")
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    local n_wins = #vim.api.nvim_tabpage_list_wins(0)
    assert.is_true(vim.wait(500, function() return #runs >= 2 end))
    assert.equals(tab, vim.api.nvim_get_current_tabpage())
    assert.equals(n_wins, #vim.api.nvim_tabpage_list_wins(0))
    assert.is_nil(results_win())
    assert.truthy(indicator(win):find("last", 1, true))
    pick_off_in(win)
    vim.cmd("tabclose")
  end)

  it("stops once the pane is closed", function()
    show(src)
    pick("0.05s")
    vim.api.nvim_win_close(results_win(), true)
    vim.wait(200, function() return false end)
    assert.equals(0, #runs)
  end)

  it("stops when the connection is closed", function()
    show(src)
    pick("0.05s")
    conn_open = false
    vim.wait(200, function() return false end)
    assert.equals(0, #runs)
    assert.is_nil(indicator())
  end)

  it("a manual run in the pane goes back to resetting the cursor", function()
    answer_rows = {}
    for i = 1, 30 do answer_rows[i] = { i, i } end
    show(src)
    local win = results_win()
    vim.api.nvim_win_set_cursor(win, { 10, 0 })
    show(src)
    assert.equals(1, vim.api.nvim_win_get_cursor(win)[1])
  end)
end)
