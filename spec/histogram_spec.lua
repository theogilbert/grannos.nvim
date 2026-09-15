-- The documents-over-time chart renderer: pure text out of buckets in.
local histogram = require("grannos.ui.histogram")

--- Build `n` five-minute buckets starting at 2024-01-01T00:00:00Z with `counts`.
--- @param counts integer[]
--- @return table[]
local function buckets(counts)
  local out = {}
  for i, c in ipairs(counts) do
    out[i] = { time = 1704067200000 + (i - 1) * 300000, count = c }
  end
  return out
end

describe("histogram.render", function()
  it("draws one column per bucket, scaled to the tallest", function()
    local lines, _, layout = histogram.render(
      { field = "@timestamp", interval = "5m", buckets = buckets({ 8, 4, 0, 1 }) },
      { height = 1 })
    assert.same("documents over time  ·  @timestamp  ·  5m per bar  ·  peak 8", lines[1])
    assert.same("8 ┤█▄ ▁", lines[2])
    assert.same("  └────", lines[3])
    assert.same({ gutter = 3, chart_top = 1, chart_bottom = 1 }, layout)
  end)

  it("stacks eighths across rows from the bottom up", function()
    local lines = histogram.render(
      { field = "ts", interval = "", buckets = buckets({ 16, 12, 4 }) },
      { height = 2 })
    assert.same("16 ┤█▄", lines[2])
    assert.same("   ┤██▄", lines[3])
  end)

  it("omits the interval when the server could not tell it", function()
    local lines = histogram.render({ field = "ts", interval = "", buckets = buckets({ 1 }) }, { height = 1 })
    assert.same("documents over time  ·  ts  ·  peak 1", lines[1])
  end)

  it("groups digits in the peak and the y-axis label", function()
    local lines = histogram.render(
      { field = "ts", interval = "1h", buckets = buckets({ 1842 }) },
      { height = 1, thousands_separator = "," })
    assert.same("documents over time  ·  ts  ·  1h per bar  ·  peak 1,842", lines[1])
    assert.same("1,842 ┤█", lines[2])
  end)

  it("shows a lone document even when it rounds to nothing", function()
    local lines = histogram.render(
      { field = "ts", interval = "", buckets = buckets({ 1000, 1 }) },
      { height = 1 })
    assert.same("1000 ┤█▁", lines[2])
  end)

  it("labels the x-axis at the first bucket and then at even steps", function()
    local counts = {}
    for i = 1, 20 do counts[i] = 1 end
    local lines = histogram.render({ field = "ts", interval = "5m", buckets = buckets(counts) }, { height = 1 })
    local labels = lines[#lines]
    local first = histogram.fmt_time(1704067200000, "%H:%M")
    local second = histogram.fmt_time(1704067200000 + 7 * 300000, "%H:%M")
    assert.same("   " .. first .. "  " .. second .. "  " .. histogram.fmt_time(1704067200000 + 14 * 300000, "%H:%M"), labels)
  end)

  it("says so when there is nothing to chart", function()
    local lines, rules, layout = histogram.render({ field = "ts", interval = "", buckets = {} }, { height = 6 })
    assert.same({ "documents over time  ·  ts  ·  no documents" }, lines)
    assert.same(1, #rules)
    assert.is_nil(layout.chart_top)
  end)

  it("highlights the bars separately from the axis", function()
    local _, rules = histogram.render({ field = "ts", interval = "", buckets = buckets({ 3 }) }, { height = 1 })
    local groups = {}
    for _, r in ipairs(rules) do groups[r.higroup] = true end
    assert.is_true(groups.GrannosHistogramBar)
    assert.is_true(groups.GrannosBorder)
  end)
end)

describe("histogram.describe_at", function()
  local hist = { field = "ts", interval = "5m", buckets = buckets({ 8, 4, 0, 1 }) }
  local _, _, layout = histogram.render(hist, { height = 2 })

  it("names the bucket under a bar column", function()
    local lines = histogram.describe_at(hist, layout, 1, layout.gutter + 2, nil)
    assert.same({
      histogram.fmt_time(1704067500000, "%Y-%m-%d %H:%M:%S") .. " – " .. histogram.fmt_time(1704067800000, "%Y-%m-%d %H:%M:%S"),
      "4 documents",
    }, lines)
  end)

  it("singularises one document", function()
    local lines = histogram.describe_at(hist, layout, 2, layout.gutter + 4, nil)
    assert.same("1 document", lines[2])
    assert.is_truthy(lines[1]:find("^from "))
  end)

  it("is nil off the bars", function()
    assert.is_nil(histogram.describe_at(hist, layout, 0, layout.gutter + 1, nil))  -- header row
    assert.is_nil(histogram.describe_at(hist, layout, 1, layout.gutter, nil))      -- the axis glyph
    assert.is_nil(histogram.describe_at(hist, layout, 1, layout.gutter + 5, nil))  -- past the last bar
    assert.is_nil(histogram.describe_at(hist, {}, 1, 1, nil))                     -- nothing charted
  end)
end)
