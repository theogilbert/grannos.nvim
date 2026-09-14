-- Completion in PromQL buffers, against a canned Prometheus explore tree.
-- Stubs must be installed before the modules under test require them.
local requests = {}

--- Canned explore.list responses, keyed by NUL-joined path, in the shape the
--- Prometheus driver lists: metrics → metric → labels, jobs → job.
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

  it("classifies the value of a job matcher, closed or not", function()
    assert.equals("job", classify({ 'up{job="|"}' }).kind)
    assert.equals("job", classify({ 'up{job="|' }).kind)
    assert.equals("job", classify({ 'up{job=~"|"}' }).kind)
    assert.equals("job", classify({ 'up{job="node-ex|' }).kind)
  end)

  it("returns nil for any other string", function()
    assert.is_nil(classify({ 'up{code="|"}' }))
    assert.is_nil(classify({ 'label_replace(up, "|", "", "", "")' }))
  end)
end)

describe("completion.omnifunc in a PromQL buffer", function()
  before_each(function()
    config.setup({})
    completion.invalidate()
    requests = {}
  end)

  it("offers metrics in an empty buffer, annotated as such", function()
    local items = complete_items({ "|" })
    assert.same({ { word = "http_requests_total", kind = "m", menu = "metric" },
                  { word = "node:cpu:rate5m",     kind = "m", menu = "metric" },
                  { word = "up",                  kind = "m", menu = "metric" } }, items)
  end)

  it("offers metrics inside a call", function()
    assert.same({ "http_requests_total", "node:cpu:rate5m", "up" }, complete({ "rate(|" }))
  end)

  it("filters metrics by the typed prefix, colons included", function()
    assert.same({ "node:cpu:rate5m" }, complete({ "node:cp|" }))
  end)

  it("offers a selector's labels, annotated with the metric", function()
    local items = complete_items({ "up{|}" })
    assert.same({ { word = "instance", kind = "l", menu = "up" },
                  { word = "job",      kind = "l", menu = "up" } }, items)
  end)

  it("offers labels in a selector whose braces are not closed yet", function()
    assert.same({ "code", "instance", "job", "method" }, complete({ 'http_requests_total{job="api", |' }))
  end)

  it("offers the labels of every metric a grouping list applies to", function()
    assert.same({ "code", "instance", "job", "method" }, complete({ "sum by (|) (http_requests_total / up)" }))
  end)

  it("offers jobs as the value of a job matcher", function()
    local items = complete_items({ 'up{job="|"}' })
    assert.same({ { word = "api",           kind = "j", menu = "job" },
                  { word = "node-exporter", kind = "j", menu = "job" } }, items)
  end)

  it("completes a hyphenated job from the whole string typed so far", function()
    assert.same({ "node-exporter" }, complete({ 'up{job="node-ex|' }))
  end)

  it("offers nothing for a label with no metric in scope", function()
    assert.same({}, complete({ "{|}" }))
    assert.same({}, complete({ "sum by (|" }))
  end)

  it("offers nothing inside a string that is not a job value", function()
    assert.same({}, complete({ 'up{code="|"}' }))
  end)

  it("primes the metric and job listings on attach, once", function()
    promql_buf({ "" })
    promql_buf({ "" })
    assert.same({ "metrics", "jobs" }, requests)
  end)

  it("sends one explore.list per path and never repeats one", function()
    complete({ "up{|}" })
    complete({ "up{|}" })
    assert.same({ "metrics", "jobs", "metrics\0up" }, requests)
  end)

  it("never sends explore.describe — it samples label values", function()
    complete({ 'http_requests_total{job="|"}' })
    complete({ "sum by (|) (http_requests_total / up)" })
    for _, key in ipairs(requests) do
      assert.is_truthy(key == "metrics" or key == "jobs" or key:find("^metrics\0[^\0]+$"))
    end
  end)
end)
