-- Completion in PromQL buffers, against a canned Prometheus explore tree.
-- Stubs must be installed before the modules under test require them.
local requests = {}

--- Canned explore.list responses, keyed by NUL-joined path, in the shape the
--- Prometheus driver lists: metrics → metric → label → values, jobs → job.
local TREE = {
  [""]                             = { { name = "metrics",       type = "group",         expandable = true },
                                       { name = "jobs",          type = "group",         expandable = true },
                                       { name = "configuration", type = "configuration", expandable = false } },
  ["metrics"]                      = { { name = "http_requests_total", type = "metric", expandable = true },
                                       { name = "node:cpu:rate5m",     type = "metric", expandable = true },
                                       { name = "up",                  type = "metric", expandable = true } },
  ["jobs"]                         = { { name = "api",           type = "job", expandable = true },
                                       { name = "node-exporter", type = "job", expandable = true } },
  ["metrics\0http_requests_total"] = { { name = "code",     type = "label" },
                                       { name = "instance", type = "label" },
                                       { name = "job",      type = "label" },
                                       { name = "method",   type = "label" } },
  ["metrics\0up"]                  = { { name = "instance", type = "label" },
                                       { name = "job",      type = "label" } },
  ["metrics\0node:cpu:rate5m"]     = { { name = "instance", type = "label" } },
  ["metrics\0http_requests_total\0code"] = { { name = "200", type = "label_value" },
                                              { name = "500", type = "label_value" } },
  ["metrics\0up\0job"]             = { { name = "api", type = "label_value" } },
  ["metrics\0up\0instance"]        = { { name = "api-1:9090", type = "label_value" },
                                       { name = "api-2:9090", type = "label_value" } },
}

package.loaded["grannos.client"] = {
  request = function(_method, params, cb)
    local key = table.concat(params.path, "\0")
    requests[#requests + 1] = key
    cb(nil, { items = TREE[key] or {} })
  end,
}
package.loaded["grannos"] = {
  get_conn = function() return { conn_id = "0" } end,
}

local completion = require("grannos.completion")
local promql     = require("grannos.completion.promql")
local repair     = require("grannos.completion.repair")
local config     = require("grannos.config")

--- Create a PromQL buffer holding `lines`, attached for completion.
--- @param lines string[]
--- @return integer
local function promql_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "promql"
  vim.api.nvim_set_current_buf(buf)
  completion.attach(buf, "conn")
  return buf
end

--- Place the cursor at the "|" marker in `lines` and return the buffer, the
--- 0-indexed row, and the cursor's byte column.
--- @param lines string[]
--- @return integer, integer, integer
local function at_marker(lines)
  local row, col
  local clean = {}
  for i, l in ipairs(lines) do
    local before, after = l:match("^(.-)|(.*)$")
    if before then
      row, col = i - 1, #before
      clean[i] = before .. after
    else
      clean[i] = l
    end
  end
  return promql_buf(clean), row, col
end

--- Run omnifunc at the marker and return the candidates, driving the refill
--- rounds a live session's popup would drive until nothing new arrives.
--- @param lines string[]
--- @return table[]  { word, kind, menu }
local function complete_items(lines)
  local buf, row, col = at_marker(lines)
  vim.cmd("startinsert!")
  vim.api.nvim_win_set_cursor(0, { row + 1, col })
  local base_start = completion.omnifunc(1, "")
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local base = line:sub(base_start + 1, col)

  local items = {}
  for _ = 1, 4 do
    items = completion.omnifunc(0, base)
    vim.wait(20, function() return false end)
  end
  return items
end

--- Run omnifunc at the marker and return the candidate words.
--- @param lines string[]
--- @return string[]
local function complete(lines)
  local words = {}
  for _, item in ipairs(complete_items(lines)) do words[#words + 1] = item.word end
  return words
end

describe("completion.repair.close_open", function()
  it("closes brackets still open, innermost first", function()
    assert.equals("sum(up{x})", repair.close_open("sum(up{x", "#"))
  end)

  it("adds nothing to a balanced text", function()
    assert.equals("sum by (x) (up)", repair.close_open("sum by (x) (up)", "#"))
  end)

  it("closes an open string before the brackets around it", function()
    assert.equals('up{job="x"}', repair.close_open('up{job="x', "#"))
  end)

  it("ignores brackets inside strings and comments", function()
    assert.equals('up{job="a}b"}', repair.close_open('up{job="a}b"', "#"))
    assert.equals("# rate (per second)\nrate(up)", repair.close_open("# rate (per second)\nrate(up", "#"))
  end)

  it("skips an escaped quote", function()
    assert.equals('up{job="a\\"b"}', repair.close_open('up{job="a\\"b', "#"))
  end)
end)

describe("completion.promql.word_start", function()
  it("keeps colons inside a word", function()
    assert.equals(0, promql.word_start("node:cpu:rate", 13))
    assert.equals(5, promql.word_start("rate(node:cpu", 13))
  end)

  it("starts a word inside a string at its opening quote", function()
    assert.equals(8, promql.word_start('up{job="node-ex', 15))
    assert.equals(8, promql.word_start('up{job="node-ex"}', 15))
  end)

  it("is unaffected by a string closed before the cursor", function()
    assert.equals(14, promql.word_start('up{job="a-b", in', 16))
  end)
end)

describe("completion.promql.at_cursor", function()
  before_each(function() config.setup({}) end)

  --- Classify the position at the "|" marker in `lines`.
  --- @param lines string[]
  --- @return PromqlCompletionContext|nil
  local function classify(lines)
    local buf, row, col = at_marker(lines)
    local text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    return promql.at_cursor(buf, row, promql.word_start(text, col), col)
  end

  it("classifies an empty buffer and a bare word as a metric position", function()
    assert.equals("metric", classify({ "|" }).kind)
    assert.equals("metric", classify({ "ht|" }).kind)
  end)

  it("classifies a call's argument as a metric position, closed or not", function()
    assert.equals("metric", classify({ "rate(|)" }).kind)
    assert.equals("metric", classify({ "rate(|" }).kind)
    assert.equals("metric", classify({ "sum(|)" }).kind)
  end)

  it("classifies an operand as a metric position", function()
    assert.equals("metric", classify({ "up + |" }).kind)
  end)

  it("scopes a label inside a selector's braces to its metric", function()
    local ctx = classify({ "up{|}" })
    assert.equals("label", ctx.kind)
    assert.same({ "up" }, ctx.metrics)
  end)

  it("recovers a selector whose braces are not closed yet", function()
    assert.same({ "up" }, classify({ "up{|" }).metrics)
    assert.same({ "http_requests_total" }, classify({ 'http_requests_total{job="api", |' }).metrics)
    assert.same({ "http_requests_total" }, classify({ "sum(rate(http_requests_total{|" }).metrics)
  end)

  it("scopes a label across lines", function()
    assert.same({ "up" }, classify({ "up{", "  |", "}" }).metrics)
  end)

  it("parses the cursor's query alone in a buffer holding several", function()
    assert.same({ "up" }, classify({ "rate(http_requests_total[5m])", "", "up{|" }).metrics)
    assert.same({ "up" }, classify({ "up{|", "", "rate(http_requests_total[5m])" }).metrics)
    assert.same({ "up" }, classify({ "# two queries", "sum(", "  up{|", "", "absent(x)" }).metrics)
    assert.equals("metric", classify({ "up", "", "rate(|" }).kind)
  end)

  it("leaves a label in a bare selector unscoped", function()
    local ctx = classify({ "{|}" })
    assert.equals("label", ctx.kind)
    assert.same({}, ctx.metrics)
  end)

  it("scopes a grouping list to every metric of the expression it modifies", function()
    assert.same({ "up" }, classify({ "sum by (|) (up)" }).metrics)
    assert.same({ "up" }, classify({ "sum(up) by (instance, |)" }).metrics)
    assert.same({ "http_requests_total" }, classify({ "sum(rate(http_requests_total[5m])) without (|)" }).metrics)
    assert.same({ "http_requests_total", "up" }, classify({ "sum by (|) (http_requests_total / up)" }).metrics)
    assert.same({ "http_requests_total", "up" }, classify({ "http_requests_total / on(|) up" }).metrics)
    assert.same({ "http_requests_total", "up" }, classify({ "http_requests_total / ignoring(x) group_left(|) up" }).metrics)
  end)

  it("scopes a grouping list to its own aggregation, not a neighbouring one", function()
    assert.same({ "up" }, classify({ "sum(http_requests_total) by (job) / sum(up) by (|)" }).metrics)
  end)

  it("leaves a grouping list typed before its expression unscoped", function()
    local ctx = classify({ "sum by (|" })
    assert.equals("label", ctx.kind)
    assert.same({}, ctx.metrics)
  end)

  it("classifies a matcher's value by its label and metric, closed or not", function()
    local ctx = classify({ 'http_requests_total{code="|"}' })
    assert.equals("label_value", ctx.kind)
    assert.equals("code", ctx.label)
    assert.same({ "http_requests_total" }, ctx.metrics)
    assert.same({ "up" }, classify({ 'up{job="|' }).metrics)
    assert.equals("job", classify({ 'up{job=~"|"}' }).label)
    assert.equals("instance", classify({ 'up{instance="api-|' }).label)
  end)

  it("classifies a job matcher with no metric as a scrape-job position", function()
    assert.equals("job", classify({ '{job="|"}' }).kind)
    assert.equals("job", classify({ '{job="node-ex|' }).kind)
  end)

  it("returns nil for a string that is no matcher value, or an unscoped non-job matcher", function()
    assert.is_nil(classify({ '{code="|"}' }))
    assert.is_nil(classify({ 'label_replace(up, "|", "", "", "")' }))
  end)
end)

describe("completion.omnifunc in a PromQL buffer", function()
  before_each(function()
    config.setup({})
    completion.invalidate()
    requests = {}
  end)

  --- The candidates of `kind` among `items`.
  --- @param items table[]
  --- @param kind  string
  --- @return table[]
  local function of_kind(items, kind)
    return vim.tbl_filter(function(i) return i.kind == kind end, items)
  end

  it("offers metrics in an empty buffer, annotated as such", function()
    local items = of_kind(complete_items({ "|" }), "m")
    assert.same({ { word = "http_requests_total", kind = "m", menu = "metric" },
                  { word = "node:cpu:rate5m",     kind = "m", menu = "metric" },
                  { word = "up",                  kind = "m", menu = "metric" } }, items)
  end)

  it("offers metrics inside a call", function()
    local words = {}
    for _, i in ipairs(of_kind(complete_items({ "rate(|" }), "m")) do words[#words + 1] = i.word end
    assert.same({ "http_requests_total", "node:cpu:rate5m", "up" }, words)
  end)

  it("offers built-in functions and aggregation operators where a metric goes, with their docstring", function()
    local items = complete_items({ "sum(|" })
    local by_word = {}
    for _, i in ipairs(items) do by_word[i.word] = i end
    assert.equals("f", by_word.rate.kind)
    assert.equals("function", by_word.rate.menu)
    assert.is_truthy(by_word.rate.info:find("^rate%(v range%-vector%)\n\nCalculates the per%-second"))
    assert.equals("o", by_word.topk.kind)
    assert.equals("aggregation", by_word.topk.menu)
    assert.is_truthy(by_word.topk.info:find("topk [without|by (<label list>)]", 1, true))
    assert.is_truthy(by_word.limitk.info:find("experimental", 1, true))
  end)

  it("filters built-ins by the typed prefix alongside metrics", function()
    assert.same({ "histogram_avg", "histogram_count", "histogram_fraction", "histogram_quantile",
                  "histogram_quantiles", "histogram_stddev", "histogram_stdvar", "histogram_sum",
                  "hour", "http_requests_total" }, complete({ "h|" }))
  end)

  it("offers no built-in inside a selector's braces or a grouping list", function()
    assert.same({}, of_kind(complete_items({ "up{|" }), "f"))
    assert.same({}, of_kind(complete_items({ "sum by (|) (up)" }), "f"))
  end)

  it("filters metrics by the typed prefix, colons included", function()
    assert.same({ "node:cpu:rate5m" }, complete({ "node:cp|" }))
  end)

  it("offers a selector's labels, annotated with the metric", function()
    local items = complete_items({ "up{|}" })
    assert.same({ { word = "instance", kind = "l", menu = "up" },
                  { word = "job",      kind = "l", menu = "up" } }, items)
  end)

  it("completes the query under the cursor when the buffer holds several", function()
    assert.same({ "instance", "job" }, complete({ "rate(http_requests_total[5m])", "", "up{|" }))
    assert.same({ "code", "instance", "job", "method" }, complete({ "http_requests_total{|", "", "up" }))
  end)

  it("offers labels in a selector whose braces are not closed yet", function()
    assert.same({ "code", "instance", "job", "method" }, complete({ 'http_requests_total{job="api", |' }))
  end)

  it("offers the labels of every metric a grouping list applies to", function()
    assert.same({ "code", "instance", "job", "method" }, complete({ "sum by (|) (http_requests_total / up)" }))
  end)

  it("offers a label's values for the selector's metric, annotated with the label", function()
    local items = complete_items({ 'http_requests_total{code="|"}' })
    assert.same({ { word = "200", kind = "e", menu = "code" },
                  { word = "500", kind = "e", menu = "code" } }, items)
    assert.same({ "api" }, complete({ 'up{job="|' }))
  end)

  it("completes a hyphenated value from the whole string typed so far", function()
    assert.same({ "api-1:9090", "api-2:9090" }, complete({ 'up{instance="api-|' }))
    assert.same({ "api-2:9090" }, complete({ 'up{instance="api-2|"}' }))
  end)

  it("offers every scrape job as the value of a job matcher with no metric", function()
    local items = complete_items({ '{job="|"}' })
    assert.same({ { word = "api",           kind = "j", menu = "job" },
                  { word = "node-exporter", kind = "j", menu = "job" } }, items)
    assert.same({ "node-exporter" }, complete({ '{job="node-ex|' }))
  end)

  it("offers nothing for a label with no metric in scope", function()
    assert.same({}, complete({ "{|}" }))
    assert.same({}, complete({ "sum by (|" }))
  end)

  it("offers nothing for a matcher value with neither metric nor job to draw on", function()
    assert.same({}, complete({ '{code="|"}' }))
    assert.same({}, complete({ 'label_replace(up, "|", "", "", "")' }))
  end)

  it("primes the metric and job listings on attach, once", function()
    promql_buf({ "" })
    promql_buf({ "" })
    assert.same({ "metrics", "jobs" }, requests)
  end)

  it("sends one explore.list per path and never repeats one", function()
    complete({ "up{|}" })
    complete({ "up{|}" })
    complete({ 'up{job="|"}' })
    assert.same({ "metrics", "jobs", "metrics\0up", "metrics\0up\0job" }, requests)
  end)

  it("never sends explore.describe — it samples label values", function()
    complete({ 'http_requests_total{job="|"}' })
    complete({ "sum by (|) (http_requests_total / up)" })
    for _, key in ipairs(requests) do
      assert.is_truthy(key == "metrics" or key == "jobs" or key:find("^metrics\0[^\0]+\0?[^\0]*$"))
    end
  end)
end)
