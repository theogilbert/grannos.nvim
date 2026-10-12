-- Single-row detail float for the results pane: one row laid out as a vertical
-- `column │ value` table, so a row too wide to read across can be read down.
-- Unlike the results table, which escapes control characters to keep each row
-- on one line, a value's newlines and tabs are honoured here: a newline starts
-- a continuation line under the value column, a tab expands to the next tab
-- stop measured from that column. Long lines wrap under the value column too.
local pane = require("grannos.ui.detail_pane")

local M = {}

local SEP      = " │ "
local TABSTOP  = 4
local NAME_MAX = 32

--- Return the display text of a cell and the highlight group it renders in.
--- @param cell any
--- @return string text, string|nil group
local function cell_text(cell)
  if cell == vim.NIL then return "NULL", "GrannosNull" end
  if cell == nil then return "", nil end
  if type(cell) == "table" then
    if cell.type == "lob" then return tostring(cell.text), "GrannosLob" end
    if cell.type == "special_float" then return tostring(cell.text), nil end
    local ok, json = pcall(vim.json.encode, cell)
    return ok and json or vim.inspect(cell), nil
  end
  return tostring(cell), nil
end

--- Expand tabs to spaces (tab stops every TABSTOP columns from the start of
--- `s`) and escape any control character other than a tab as `\xNN`.
--- @param s string  one line of a value, with no newline in it
--- @return string
local function expand_line(s)
  if not s:find("%c") then return s end
  local out, width = {}, 0
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if ch == "\t" then
      local n = TABSTOP - width % TABSTOP
      out[#out + 1] = string.rep(" ", n)
      width = width + n
    else
      if ch:find("^%c$") then ch = ("\\x%02X"):format(ch:byte()) end
      out[#out + 1] = ch
      width = width + vim.fn.strdisplaywidth(ch)
    end
  end
  return table.concat(out)
end

--- Split `s` into chunks of at most `width` display columns.
--- @param s     string
--- @param width integer
--- @return string[]
local function chunk(s, width)
  if width < 1 or vim.fn.strdisplaywidth(s) <= width then return { s } end
  local chunks, cur, cur_w = {}, {}, 0
  for _, ch in ipairs(vim.fn.split(s, [[\zs]])) do
    local w = vim.fn.strdisplaywidth(ch)
    if cur_w + w > width and #cur > 0 then
      chunks[#chunks + 1] = table.concat(cur)
      cur, cur_w = {}, 0
    end
    cur[#cur + 1] = ch
    cur_w = cur_w + w
  end
  chunks[#chunks + 1] = table.concat(cur)
  return chunks
end

--- Truncate `s` to `width` display columns, marking the cut with an ellipsis.
--- @param s     string
--- @param width integer
--- @return string
local function truncate(s, width)
  if vim.fn.strdisplaywidth(s) <= width then return s end
  local out = ""
  for _, ch in ipairs(vim.fn.split(s, [[\zs]])) do
    if vim.fn.strdisplaywidth(out .. ch) > width - 1 then break end
    out = out .. ch
  end
  return out .. "…"
end

--- Render one row as `name │ value` lines, one field after another, with each
--- value's newlines and wrapped overflow continuing under the value column.
--- @param columns string[]  column names, in display order
--- @param row     any[]     cell values, parallel to `columns`
--- @param width   integer   display columns available per line
--- @return string[] lines, DetailHlRule[] hls
function M.render(columns, row, width)
  local name_w = 0
  for _, name in ipairs(columns) do name_w = math.max(name_w, vim.fn.strdisplaywidth(name)) end
  name_w = math.min(name_w, NAME_MAX, math.max(1, math.floor(width / 3)))
  local value_w = math.max(1, width - name_w - vim.fn.strdisplaywidth(SEP))

  local lines, hls = {}, {}
  for i, name in ipairs(columns) do
    local label = truncate(name, name_w)
    label = label .. string.rep(" ", name_w - vim.fn.strdisplaywidth(label))
    local blank = string.rep(" ", name_w)

    local text, group = cell_text(row[i])
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    local first = true
    for _, raw in ipairs(vim.split(text, "\n", { plain = true })) do
      for _, piece in ipairs(chunk(expand_line(raw), value_w)) do
        local row0   = #lines
        local lead   = first and label or blank
        local prefix = lead .. SEP
        lines[#lines + 1] = prefix .. piece
        if first then hls[#hls + 1] = { "GrannosHeaderRow", row0, 0, #lead } end
        hls[#hls + 1] = { "GrannosBorder", row0, #lead, #prefix }
        if group then hls[#hls + 1] = { group, row0, #prefix, -1 } end
        first = false
      end
    end
  end
  return lines, hls
end

--- Open a float showing one result row as a vertical table.
--- @param columns string[]  column names, in display order
--- @param row     any[]     cell values, parallel to `columns`
--- @param title   string    window title
function M.open(columns, row, title)
  local width = math.min(math.floor(vim.o.columns * 0.60), 110)
  local lines, hls = M.render(columns, row, width - 1)
  pane.open_single({
    item     = row,
    title    = title,
    width    = width,
    render   = function(buf) pane.apply(buf, lines, hls) end,
    estimate = function() return #lines end,
  })
end

return M
