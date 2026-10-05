-- Built-in documentation: the generated PromQL and MongoDB tables, the node →
-- built-in lookup, the docstring layout, and the hover key showing it.
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

--- Open a MongoDB buffer holding `text`, cursor on the `nth` (default first) `needle`.
--- @param text   string
--- @param needle string
--- @param nth    integer|nil
--- @return integer
local function mongo_buf(text, needle, nth)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.bo[buf].filetype = "mongo"
  vim.api.nvim_win_set_buf(0, buf)
  local at = 0
  for _ = 1, nth or 1 do at = assert(text:find(needle, at + 1, true)) end
  vim.api.nvim_win_set_cursor(0, { 1, at - 1 })
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

describe("builtins.mongo (generated)", function()
  local data = require("grannos.builtins.mongo")

  it("keys every operator by category, a name in several having an entry in each", function()
    assert.equals("$match: <query>", data.categories.stage["$match"].signature)
    assert.equals("Sets the value of a field.", data.categories.update["$set"].doc)
    assert.is_truthy(data.categories.stage["$set"].doc:find("^Adds new fields"))
    assert.is_nil(data.categories.query["$group"])
  end)

  it("builds each signature from the argument encoding", function()
    assert.equals("$cond: { if, then, else }", data.categories.expression["$cond"].signature)
    assert.equals("$substr: [ string, start, length ]", data.categories.expression["$substr"].signature)
    assert.equals("$add: [ expression, ... ]", data.categories.expression["$add"].signature)
    assert.equals("$group: { _id, <field>: ..., ... }", data.categories.stage["$group"].signature)
  end)

  it("carries the minimum version and the documented arguments", function()
    local trunc = data.categories.expression["$dateTrunc"]
    assert.equals("5.1", trunc.min_version)
    assert.equals("date", trunc.args[1].name)
    assert.is_false(trunc.args[1].optional)
    assert.equals("binSize", trunc.args[3].name)
    assert.is_true(trunc.args[3].optional)
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

describe("builtins.at_cursor in a MongoDB buffer", function()
  local pipeline = '{"aggregate": "orders", "db": "mydb", "pipeline": [{"$set": {"a": 1}}, '
    .. '{"$group": {"_id": "$s", "t": {"$sum": {"$multiply": ["$a", 2]}}}}]}'

  it("names a stage at the top of a pipeline stage", function()
    local b = builtins.at_cursor(mongo_buf(pipeline, "$set"))
    assert.equals("$set", b.name)
    assert.equals("stage", b.category)
  end)

  it("prefers an accumulator inside a grouping stage, an expression below it", function()
    assert.equals("accumulator", builtins.at_cursor(mongo_buf(pipeline, "$sum")).category)
    assert.equals("expression", builtins.at_cursor(mongo_buf(pipeline, "$multiply")).category)
  end)

  it("tells a filter's query operators, $expr's expressions and update operators apart", function()
    local cmd = '{"updateOne": "orders", "db": "mydb", "filter": {"a": {"$gt": 1}, "$expr": {"$gt": [1, 2]}}, "update": {"$set": {"a": 1}}}'
    assert.equals("query", builtins.at_cursor(mongo_buf(cmd, "$gt")).category)
    assert.equals("expression", builtins.at_cursor(mongo_buf(cmd, "$gt", 2)).category)
    assert.equals("update", builtins.at_cursor(mongo_buf(cmd, "$set")).category)
  end)

  it("returns nil on a field, a field reference, a type wrapper and a command key", function()
    assert.is_nil(builtins.at_cursor(mongo_buf(pipeline, 'a":')))
    assert.is_nil(builtins.at_cursor(mongo_buf(pipeline, '$s"')))
    assert.is_nil(builtins.at_cursor(mongo_buf('{"find": "orders", "filter": {"_id": {"$oid": "x"}}}', "$oid")))
    assert.is_nil(builtins.at_cursor(mongo_buf(pipeline, "pipeline")))
  end)

  it("returns nil in JSON that is no Mongo command", function()
    assert.is_nil(builtins.at_cursor(mongo_buf('{"filter": {"$gt": 1}}', "$gt")))
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

  it("lays a Mongo operator out with its arguments and a category/version footer", function()
    local lines, hls = builtins.hover_lines(builtins.lookup("mongo", "$dateTrunc", { "expression" }))
    assert.equals("$dateTrunc: { date, unit, binSize?, timezone?, startOfWeek? }", lines[1])
    assert.equals("Truncates a date.", lines[3])
    assert.equals("date", lines[5])
    assert.is_truthy(lines[6]:find("^  The date to truncate"))
    assert.is_true(vim.tbl_contains(lines, "binSize (optional)"))
    assert.equals("expression · MongoDB 5.1+", lines[#lines])
    assert.same({ "GrannosHeaderRow", 0, 0, #"$dateTrunc" }, hls[1])
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
