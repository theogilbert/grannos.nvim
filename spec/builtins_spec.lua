-- Built-in documentation: the generated PromQL table, the node → built-in
-- lookup, the docstring layout, and the hover key showing it.
-- Stubs must be installed before the modules under test require them.
package.loaded["grannos.client"] = {
  capabilities = function() return { drivers = {} } end,
  request      = function(method, _params, cb)
    if method == "connect" then cb(nil, { connection_id = 1 }) end
    return 0
  end,
}

require("grannos.config").setup()

local builtins    = require("grannos.builtins")
local hover       = require("grannos.ui.hover")
local grannos     = require("grannos")
local connections = require("grannos.connections")

--- Open a PromQL buffer holding `text`, cursor on the first `needle`.
--- @param text   string
--- @param needle string
--- @return integer
local function promql_buf(text, needle)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n"))
  vim.bo[buf].filetype = "promql"
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { 1, assert(text:find(needle, 1, true)) - 1 })
  return buf
end

describe("builtins.promql (generated)", function()
  local data = require("grannos.builtins.promql")

  it("carries every function the parser knows, with the documented signature", function()
    assert.equals("rate(v range-vector)", data.entries.rate.signature)
    assert.equals("function", data.entries.rate.kind)
    assert.is_false(data.entries.rate.experimental)
    assert.equals("label_replace(v instant-vector, dst_label string, replacement string, src_label string, regex string)",
      data.entries.label_replace.signature)
  end)

  it("describes each in the documentation's words, made to stand alone", function()
    assert.is_truthy(data.entries.rate.doc:find("^Calculates the per%-second average rate of increase"))
    assert.is_truthy(data.entries.histogram_sum.doc:find("^Returns the sum of observations"))
    assert.is_truthy(data.entries.avg_over_time.doc:find("^The average value"))
    assert.equals("Same as sort, but sorts in descending order.", data.entries.sort_desc.doc)
  end)

  it("carries the aggregation operators and their general syntax", function()
    assert.equals("aggregation", data.entries.topk.kind)
    assert.equals("topk(k, v)", data.entries.topk.signature)
    assert.equals("Largest k elements by sample value", data.entries.topk.doc)
    assert.is_true(data.entries.limitk.experimental)
    assert.is_truthy(data.aggregation_syntax:find("^<aggr%-op> %[without|by"))
  end)

  it("flags experimental functions", function()
    assert.is_true(data.entries.info.experimental)
    assert.is_true(data.entries.mad_over_time.experimental)
  end)

  it("names a Lua keyword as a function without tripping the loader", function()
    assert.equals("end()", data.entries["end"].signature)
  end)
end)

describe("builtins.at_cursor", function()
  it("finds a call's function", function()
    local buf = promql_buf("sum(rate(http_requests_total[5m]))", "rate")
    local b = builtins.at_cursor(buf)
    assert.equals("rate", b.name)
    assert.equals("promql", b.lang)
  end)

  it("finds an aggregation operator", function()
    assert.equals("sum", builtins.at_cursor(promql_buf("sum by (job) (up)", "sum")).name)
  end)

  it("returns nil on a metric, even one named like a function", function()
    assert.is_nil(builtins.at_cursor(promql_buf("rate(http_requests_total[5m])", "http")))
    assert.is_nil(builtins.at_cursor(promql_buf("rate + 1", "rate")))
  end)

  it("returns nil for an unknown function and in another language", function()
    assert.is_nil(builtins.at_cursor(promql_buf("nosuchfn(up)", "nosuch")))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "SELECT count(*) FROM t;" })
    vim.bo[buf].filetype = "sql"
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    assert.is_nil(builtins.at_cursor(buf))
  end)
end)

describe("builtins.hover_lines", function()
  it("lays a function out as signature, blank, wrapped description", function()
    local lines, hls = builtins.hover_lines(builtins.lookup("promql", "rate"))
    assert.equals("rate(v range-vector)", lines[1])
    assert.equals("", lines[2])
    assert.is_truthy(lines[3]:find("^Calculates"))
    assert.is_true(#lines > 3)
    assert.same({ "GrannosHeaderRow", 0, 0, 4 }, hls[1])
  end)

  it("appends an aggregation's syntax with the operator filled in", function()
    local lines = builtins.hover_lines(builtins.lookup("promql", "sum"))
    assert.equals("sum [without|by (<label list>)] ([parameter,] <vector expression>)", lines[#lines])
  end)

  it("ends with the feature flag an experimental built-in needs", function()
    local lines, hls = builtins.hover_lines(builtins.lookup("promql", "limitk"))
    assert.is_truthy(lines[#lines]:find("promql%-experimental%-functions"))
    assert.equals("GrannosExplorerDim", hls[#hls][1])
  end)
end)

describe("hover key on a built-in", function()
  it("opens the docstring float without a connection and closes it when the cursor moves", function()
    local buf = promql_buf("rate(http_requests_total[5m])", "rate")
    grannos.describe_symbol_at_cursor()
    assert.is_true(hover.is_open())
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    assert.is_false(hover.is_open())
  end)

  it("shows the signature and description in the float", function()
    promql_buf("sum by (job) (rate(http_requests_total[5m]))", "sum")
    grannos.describe_symbol_at_cursor()
    assert.is_true(hover.is_open())
    local fwin
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then fwin = w end
    end
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(fwin), 0, -1, false)
    assert.equals("sum(v)", lines[1])
    assert.equals("Calculate sum over dimensions", lines[3])
    hover.close()
  end)

  it("still describes a symbol through the connection when the cursor is not on a built-in", function()
    local key = connections.conn_key("local", "prometheus", "", "test")
    grannos._send_connect(key, {})
    local buf = promql_buf("rate(http_requests_total[5m])", "http_requests_total")
    grannos.set_buf_conn(buf, key)
    grannos.describe_symbol_at_cursor()
    assert.is_false(hover.is_open())
  end)
end)
