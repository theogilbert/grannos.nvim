-- The results pane's `gh` toggle: fetches an execute.histogram for the query
-- on show and draws it under the row-count label; off by default; sticky per
-- results buffer; a late answer for a superseded query is dropped.
local requests = {}   -- every client.request call: { method, params, callback }
package.loaded["grannos.client"] = {
  request = function(method, params, callback)
    table.insert(requests, { method = method, params = params, callback = callback })
    return #requests
  end,
  cancel = function() end,
  capabilities = function()
    return { drivers = {
      { driver = "elasticsearch", label = "Elasticsearch", supports_histogram = true },
      { driver = "sqlite",        label = "SQLite" },
    } }
  end,
}
local conn_driver = "elasticsearch"
package.loaded["grannos"] = {
  get_conn = function() return { conn_id = "0", driver = conn_driver } end,
}

local results = require("grannos.ui.results")
require("grannos.config").setup({})
require("grannos.hl").setup()

--- Return the lines of the results buffer shown in this tab's results window.
--- @return string[]
local function lines()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):find("grannos://results", 1, true) then
      return vim.api.nvim_buf_get_lines(b, 0, -1, false)
    end
  end
  return {}
end

--- What `gh` does in the results window.
local function toggle()
  results.toggle_histogram()
end

--- The pending histogram requests, oldest first.
--- @return table[]
local function histogram_requests()
  local out = {}
  for _, r in ipairs(requests) do
    if r.method == "execute.histogram" then table.insert(out, r) end
  end
  return out
end

--- Answer a request and drain the scheduled re-render.
--- @param req    table
--- @param err    string|nil
--- @param result table|nil
local function answer(req, err, result)
  req.callback(err, result)
  vim.wait(50, function() return false end)
end

local BUCKETS = {
  { time = 1704067200000, count = 8 },
  { time = 1704067500000, count = 4 },
}

--- Run a query through the pane's public API, as the executor does.
--- @param sql string
local function show(sql)
  results.set_conn_name("srv\0" .. conn_driver .. "\0g\0" .. conn_driver, conn_driver, nil)
  results.set_query(sql, "")
  results.show_results({ "id" }, { { 1 }, { 2 } }, 2, 2, 1.0)
end

describe("results histogram toggle", function()
  before_each(function()
    requests = {}
    conn_driver = "elasticsearch"
    show("logs | *")
    -- A previous test may have left the toggle on for this results buffer.
    if #histogram_requests() > 0 then
      toggle()
      requests = {}
    end
  end)

  it("is off by default", function()
    assert.same({}, histogram_requests())
    assert.is_nil(lines()[2]:find("documents over time", 1, true))
  end)

  it("requests a histogram for the query when turned on and draws it", function()
    toggle()
    local reqs = histogram_requests()
    assert.same(1, #reqs)
    assert.same("0", reqs[1].params.connection_id)
    assert.same("logs | *", reqs[1].params.query)
    assert.is_true(reqs[1].params.buckets >= 10)
    assert.is_truthy(lines()[3]:find("Fetching histogram", 1, true))

    answer(reqs[1], nil, { field = "@timestamp", interval = "5m", buckets = BUCKETS, duration_ms = 1 })
    local all = lines()
    assert.same("2 rows  ·  0.001s", all[1])
    assert.same("documents over time  ·  @timestamp  ·  5m per bar  ·  peak 8", all[3])
    assert.same("8 ┤█", all[4])       -- top of six rows: only the peak reaches it
    assert.same("  ┤██", all[9])      -- bottom row: both bars
    assert.same("  └──", all[10])
    assert.same("", all[12])
    assert.same("│ id │", all[13])    -- the table follows, unchanged
  end)

  it("removes the chart and sends nothing when turned off again", function()
    toggle()
    answer(histogram_requests()[1], nil, { field = "@timestamp", interval = "5m", buckets = BUCKETS })
    toggle()
    assert.same(1, #histogram_requests())
    for _, l in ipairs(lines()) do
      assert.is_nil(l:find("documents over time", 1, true))
    end
    toggle()  -- leave it off for the next test's before_each
    requests = {}
  end)

  it("stays on across queries in the same results buffer", function()
    toggle()
    answer(histogram_requests()[1], nil, { field = "@timestamp", interval = "5m", buckets = BUCKETS })
    show("logs | level:error")
    local reqs = histogram_requests()
    assert.same(2, #reqs)
    assert.same("logs | level:error", reqs[2].params.query)
  end)

  it("drops a late answer for a query that has been replaced", function()
    toggle()
    local first = histogram_requests()[1]
    show("logs | level:error")
    local second = histogram_requests()[2]
    answer(first, nil, { field = "@timestamp", interval = "5m", buckets = { { time = 0, count = 999 } } })
    assert.is_truthy(lines()[3]:find("Fetching histogram", 1, true))
    answer(second, nil, { field = "@timestamp", interval = "5m", buckets = BUCKETS })
    assert.is_truthy(lines()[3]:find("peak 8", 1, true))
  end)

  it("shows the server's error in place of the chart", function()
    toggle()
    answer(histogram_requests()[1], "Histograms are not available in Dev Tools mode", nil)
    assert.same("Histogram unavailable: Histograms are not available in Dev Tools mode", lines()[3])
  end)

  it("refuses without a round trip on a driver that cannot chart", function()
    conn_driver = "sqlite"
    show("SELECT 1")
    toggle()
    assert.same({}, histogram_requests())
    assert.same("Histogram unavailable: SQLite does not support histograms", lines()[3])
  end)
end)
