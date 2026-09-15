-- Text rendering of an `execute.histogram` result: documents over time as a
-- column chart, one terminal column per bucket, drawn with the eighth-block
-- glyphs so a chart `height` rows tall resolves `height * 8` levels.
--
--   documents over time  ·  @timestamp  ·  5m per bar  ·  peak 1,842
--   1,842 ┤        █
--         ┤        █   ▄                    ▂
--         ┤  ▂     █   █ ▅          ▃      ▄█
--         ┤ ▃█▅   ▇█  ▂█ █▂   ▁    ▅█▃   ▂▇██▃
--         ┤▁███▆▂▄██▆▅███████▄▇█▇▅▆████▇▆██████▇▄▂▁
--         └──────────────────────────────────────────
--         09:00        10:00        11:00        12:00
--
-- Pure: takes the buckets and returns lines plus highlight rules, and a
-- layout describing where the bars sit so a caller can map a cursor position
-- back to a bucket. Nothing here touches a buffer or a window.
local M = {}

-- Eighth-block glyphs, index = number of eighths filled (1..8).
local BLOCKS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

--- Format `n` with `sep` between digit groups ("1,842"); plain digits when
--- `sep` is empty or nil.
--- @param n   integer
--- @param sep string|nil
--- @return string
local function group_digits(n, sep)
  local s = tostring(n)
  if not sep or sep == "" then return s end
  local out = s:reverse():gsub("(%d%d%d)", "%1" .. sep):reverse()
  return (out:gsub("^" .. vim.pesc(sep), ""))
end
M.group_digits = group_digits

--- Pick the strftime pattern for the x-axis labels of buckets spanning
--- `span_ms`: time of day for a single day, month-day and time for anything
--- up to a year, the calendar date beyond that.
--- @param span_ms integer
--- @return string
local function label_format(span_ms)
  if span_ms < 24 * 3600 * 1000 then return "%H:%M" end
  if span_ms < 365 * 24 * 3600 * 1000 then return "%m-%d %H:%M" end
  return "%Y-%m-%d"
end

--- Format a bucket start (Unix milliseconds) in local time.
--- @param ms  integer
--- @param fmt string  strftime pattern
--- @return string
local function fmt_time(ms, fmt)
  return os.date(fmt, math.floor(ms / 1000)) --[[@as string]]
end
M.fmt_time = fmt_time

--- Build the x-axis line: the first bucket's timestamp at column 0, then one
--- label every `step` bars, where `step` is the smallest spacing that keeps a
--- gap of two between labels. Labels are only placed where they fit within
--- the chart's width, so the line never runs past the last bar.
--- @param buckets { time: integer, count: integer }[]
--- @param gutter  string  the blank prefix under the y-axis
--- @param fmt     string  strftime pattern
--- @return string
local function axis_labels(buckets, gutter, fmt)
  local width = #buckets
  local label_w = vim.api.nvim_strwidth(fmt_time(buckets[1].time, fmt))
  local step = label_w + 2
  local cells = {}
  for i = 1, width do cells[i] = " " end
  local col = 1
  while col <= width do
    local label = fmt_time(buckets[col].time, fmt)
    if col + label_w - 1 > width then break end
    for j = 1, label_w do cells[col + j - 1] = label:sub(j, j) end
    col = col + step
  end
  return ((gutter .. table.concat(cells)):gsub("%s+$", ""))
end

--- Render `hist` as buffer lines.
--- @param hist { field: string, interval: string, buckets: { time: integer, count: integer }[] }
--- @param opts { height: integer, thousands_separator: string|nil }
--- @return string[] lines
--- @return table[]  rules   highlight rules with 0-indexed rows relative to `lines`
--- @return table    layout  { gutter: integer, chart_top: integer, chart_bottom: integer }
---                          — display columns before the first bar, and the
---                          0-indexed rows (relative) of the first and last bar row.
---                          `chart_top` is nil when there is nothing to chart.
function M.render(hist, opts)
  local sep     = opts.thousands_separator
  local buckets = hist.buckets or {}
  local header  = "documents over time  ·  " .. (hist.field or "?")
  if #buckets == 0 then
    local line = header .. "  ·  no documents"
    return { line }, { { higroup = "GrannosRowCount", start = { 0, 0 }, finish = { 0, -1 } } }, {}
  end

  local max = 0
  for _, b in ipairs(buckets) do if b.count > max then max = b.count end end
  if hist.interval and hist.interval ~= "" then
    header = header .. "  ·  " .. hist.interval .. " per bar"
  end
  header = header .. "  ·  peak " .. group_digits(max, sep)

  local height   = math.max(1, opts.height or 6)
  local levels   = height * 8
  local scale    = math.max(max, 1)
  local heights  = {}
  for i, b in ipairs(buckets) do
    local h = math.floor(b.count / scale * levels + 0.5)
    if b.count > 0 and h == 0 then h = 1 end  -- a lone document still shows
    heights[i] = h
  end

  local max_label = group_digits(max, sep)
  local label_w   = vim.api.nvim_strwidth(max_label)
  local blank     = string.rep(" ", label_w)
  local gutter_w  = label_w + 2  -- label, space, axis glyph

  local lines = { header }
  local rules = { { higroup = "GrannosRowCount", start = { 0, 0 }, finish = { 0, -1 } } }
  for row = height - 1, 0, -1 do
    local label  = row == height - 1 and max_label or blank
    local prefix = label .. " ┤"
    local cells  = {}
    for i = 1, #buckets do
      local level = math.max(0, math.min(8, heights[i] - row * 8))
      cells[i] = level == 0 and " " or BLOCKS[level]
    end
    local line = (prefix .. table.concat(cells)):gsub("%s+$", "")
    table.insert(lines, line)
    local r = #lines - 1
    table.insert(rules, { higroup = "GrannosRowCount", start = { r, 0 }, finish = { r, label_w } })
    table.insert(rules, { higroup = "GrannosBorder",   start = { r, label_w }, finish = { r, #prefix } })
    table.insert(rules, { higroup = "GrannosHistogramBar", start = { r, #prefix }, finish = { r, -1 } })
  end
  local axis = blank .. " └" .. string.rep("─", #buckets)
  table.insert(lines, axis)
  table.insert(rules, { higroup = "GrannosBorder", start = { #lines - 1, 0 }, finish = { #lines - 1, -1 } })

  local span = buckets[#buckets].time - buckets[1].time
  table.insert(lines, axis_labels(buckets, blank .. "  ", label_format(span)))
  table.insert(rules, { higroup = "GrannosRowCount", start = { #lines - 1, 0 }, finish = { #lines - 1, -1 } })

  return lines, rules, { gutter = gutter_w, chart_top = 1, chart_bottom = height }
end

--- Describe the bucket a cursor position falls on, for a hover float.
--- @param hist   { field: string, interval: string, buckets: { time: integer, count: integer }[] }
--- @param layout table    from `render`
--- @param row    integer  0-indexed row relative to the rendered lines
--- @param vcol   integer  1-indexed display column of the cursor
--- @param sep    string|nil  thousands separator
--- @return string[]|nil  hover lines, or nil when the position is off the bars
function M.describe_at(hist, layout, row, vcol, sep)
  if not layout.chart_top or row < layout.chart_top or row > layout.chart_bottom then return nil end
  local idx = vcol - layout.gutter
  local bucket = hist.buckets[idx]
  if not bucket then return nil end
  local next_b = hist.buckets[idx + 1]
  local from = fmt_time(bucket.time, "%Y-%m-%d %H:%M:%S")
  local range = next_b and (from .. " – " .. fmt_time(next_b.time, "%Y-%m-%d %H:%M:%S")) or ("from " .. from)
  local n = group_digits(bucket.count, sep)
  return { range, n .. " document" .. (bucket.count == 1 and "" or "s") }
end

return M
