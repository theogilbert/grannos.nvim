-- Formats a sequence of row arrays into a box-drawing-character table.
-- The values (NULL, LOBs, numbers with separators) are grannos's; the layout
-- and geometry are common.grid's.
local grid = require("common.grid")

local M = {}

--- @class FormattedTable
--- @field lines         any[][]    raw row arrays (first row is the header)
--- @field columns_width integer[]  display-column widths per column
--- @field text          string[]   rendered lines ready to set into a buffer
--- @field sep           string|nil thousands-separator used for numeric cells, if any
--- @field decimal_sep   string|nil decimal-point separator used for numeric cells, if any
--- @field left_aligned  table<integer, boolean> columns whose cells are left-aligned rather than centered

M.COL_SEPARATOR = grid.SEP

-- Row count between cooperative yields in from_structured_data's per-row loops
-- below. Only takes effect inside a coroutine driven by e.g. export.run_async;
-- a plain synchronous call (as used for the paginated results pane) is
-- unaffected since coroutine.isyieldable() is false outside one.
local CHUNK_SIZE = 1000

--- Yield to the event loop every CHUNK_SIZE-th call, if running inside a
--- coroutine. A no-op when called synchronously, so it's safe in any loop
--- without changing that loop's synchronous behaviour.
--- @param i integer  current 1-based row index
local function maybe_yield(i)
  if coroutine.isyieldable() and i % CHUNK_SIZE == 0 then coroutine.yield() end
end

-- Display string for JSON null values (vim.NIL sentinel).
local NULL_TEXT = "NULL"

--- Whether `cell` is a LobPlaceholder value (a decoded `{type="lob", text=...}` object
--- sent by the server in place of an inlined large-object value).
--- @param cell any
--- @return boolean
local function is_lob(cell)
  return type(cell) == "table" and cell.type == "lob"
end

--- Whether `cell` is a SpecialFloat value (a decoded `{type="special_float", text=...}`
--- object sent by the server in place of a NaN/Infinity/-Infinity value, which plain
--- JSON cannot represent).
--- @param cell any
--- @return boolean
local function is_special_float(cell)
  return type(cell) == "table" and cell.type == "special_float"
end

--- Insert `sep` between digit groups in the integer part of a number's decimal
--- representation, and swap in `decimal_sep` for the decimal point, if set.
--- @param n           number
--- @param sep         string|nil  separator to insert between digit groups (e.g. ","), or nil to disable
--- @param decimal_sep string|nil  decimal-point character (e.g. "," or "."), or nil for "."
--- @return string display  the formatted number
--- @return integer int_len  byte length of the sign + grouped integer part (excludes the decimal point and fraction)
local function format_number(n, sep, decimal_sep)
  local s = tostring(n)
  local sign, rest      = s:match("^(%-?)(.*)$")
  local int_part, frac  = rest:match("^(%d+)(.*)$")
  if not int_part then return s, #s end

  local grouped = int_part
  if sep and #int_part > 3 then
    local sep_rev  = sep:reverse()
    local sep_repl = sep_rev:gsub("%%", "%%%%")
    grouped = int_part:reverse():gsub("(%d%d%d)", "%1" .. sep_repl)
    if grouped:sub(-#sep_rev) == sep_rev then
      grouped = grouped:sub(1, -#sep_rev - 1)
    end
    grouped = grouped:reverse()
  end

  if decimal_sep and decimal_sep ~= "." and frac:sub(1, 1) == "." then
    frac = decimal_sep .. frac:sub(2)
  end

  local int_str = sign .. grouped
  return int_str .. frac, #int_str
end

--- Control characters written as escapes, so a multi-line value renders as
--- one line of one row (see common.grid.escape).
local escape_control = grid.escape

--- Return the display string for a cell value, mapping vim.NIL → "NULL", a
--- LobPlaceholder/SpecialFloat object → its server-formatted `text`, and formatting
--- numeric cells with the configured thousands/decimal separators.
--- @param cell        any
--- @param sep         string|nil  thousands-separator character, or nil/"" to disable
--- @param decimal_sep string|nil  decimal-point character, or nil/"" for "."
--- @return string
local function cell_display(cell, sep, decimal_sep)
  if cell == vim.NIL then return NULL_TEXT end
  if cell == nil     then return "" end
  if is_lob(cell)    then return escape_control(cell.text) end
  if is_special_float(cell) then return escape_control(cell.text) end
  sep         = (sep and sep ~= "") and sep or nil
  decimal_sep = (decimal_sep and decimal_sep ~= "") and decimal_sep or nil
  if type(cell) == "number" and (sep or decimal_sep) then
    local s = format_number(cell, sep, decimal_sep)
    return s
  end
  return escape_control(tostring(cell))
end

--- Display-column offset of `text` from the start of its cell.
local text_offset = grid.offset

--- Normalize a `sep` argument into a per-column array (or nil when disabled everywhere).
--- Accepts a single string (applied uniformly to every column, for callers that don't
--- need per-column control) or an already-per-column array (sparse, nil entries disable
--- that column). `false`/`""`/`nil` disables the separator entirely.
--- @param sep   string|table|boolean|nil
--- @param ncols integer
--- @return string[]|nil
local function normalize_sep(sep, ncols)
  if not sep or sep == "" then return nil end
  local arr, any = {}, false
  if type(sep) == "table" then
    for i = 1, ncols do
      if sep[i] and sep[i] ~= "" then arr[i] = sep[i]; any = true end
    end
  else
    for i = 1, ncols do arr[i] = sep end
    any = ncols > 0
  end
  return any and arr or nil
end

--- The display strings of `row`'s first `ncols` cells.
--- @param row         table
--- @param ncols       integer
--- @param sep         string[]|nil
--- @param decimal_sep string|nil
--- @return string[]
local function display_row(row, ncols, sep, decimal_sep)
  local out = {}
  for j = 1, ncols do out[j] = cell_display(row and row[j], sep and sep[j], decimal_sep) end
  return out
end

--- Build a FormattedTable from a list of row arrays.
--- @param lines table    rows, each an array of cell values
--- @param header_lines integer|nil  rows to treat as header (default 1)
--- @param sep string|table|boolean|nil  thousands-separator for numeric cells: a single string applies to
---   every column, a per-column array (sparse; nil entries disable that column) applies selectively,
---   nil/false/"" disables it everywhere
--- @param decimal_sep string|boolean|nil  decimal-point separator for numeric cells, or nil/false/"" for "."
--- @param left_align_width integer|nil  a column wider than this many display columns is left-aligned
---   instead of centered, so its short cells don't float in the middle of a wide one; nil centers every column
--- @return FormattedTable
function M.from_structured_data(lines, header_lines, sep, decimal_sep, left_align_width)
  header_lines = header_lines or 1
  decimal_sep = (decimal_sep and decimal_sep ~= "") and decimal_sep or nil
  -- Every row renders the same number of columns as the widest one: a row that
  -- is short a trailing cell (a driver that omits trailing NULLs, a row built
  -- with table.insert over a nil value) would otherwise render a shorter line
  -- than the header, and a row with an extra cell a longer one — either way the
  -- data stops lining up with the header above it. Missing cells render empty.
  local ncols = 0
  for _, row in ipairs(lines) do ncols = math.max(ncols, #row) end
  sep = normalize_sep(sep, ncols)
  local display = {}
  for i, row in ipairs(lines) do
    display[i] = display_row(row, ncols, sep, decimal_sep)
    maybe_yield(i)
  end
  local laid = grid.layout(display, { header = header_lines, left_align = left_align_width })
  local widths, formatted, left_aligned = laid.widths, laid.text, laid.left

  return { lines = lines, columns_width = widths, text = formatted, sep = sep, decimal_sep = decimal_sep,
           left_aligned = left_aligned }
end

--- Return the 1-indexed column at a virtual cursor position,
--- or nil when the cursor is on a separator.
--- @param cols_width integer[]
--- @param virtual_col integer  1-indexed
--- @return integer|nil
M.get_column_at_cursor = grid.column_at

--- Return the virtual-column positions of each column boundary (left edge of
--- the leading separator + each trailing separator).  The first entry is always
--- 0 (left edge of the table); the last is the right edge.
--- @param cols_width integer[]
--- @return integer[]
M.column_boundaries = grid.boundaries

--- Compute the byte {start, finish} of each column cell in a formatted line.
--- Accounts for multi-byte cell content so positions are valid for vim.hl.range.
--- @param row table|nil   raw cell values for this row
--- @param cols_width integer[]
--- @param sep string[]|nil  per-column thousands-separator in effect, or nil
--- @param decimal_sep string|nil  decimal-point separator in effect, or nil
--- @return table   list of {byte_start, byte_end} per column
function M.column_byte_positions(row, cols_width, sep, decimal_sep)
  return grid.spans(row and display_row(row, #cols_width, sep, decimal_sep), cols_width)
end

--- Build per-column highlight rules for one buffer line.
--- @param higroup string
--- @param buf_line integer   0-indexed buffer row
--- @param data_line integer  1-indexed into tbl.lines
--- @param tbl FormattedTable
--- @return table   list of { higroup, start, finish } rules
function M.col_hl_rules(higroup, buf_line, data_line, tbl)
  if not tbl then return {} end
  local positions = M.column_byte_positions(tbl.lines[data_line], tbl.columns_width, tbl.sep, tbl.decimal_sep)
  local rules     = {}
  for i, pos in ipairs(positions) do
    rules[i] = { higroup = higroup,
                 start   = { buf_line, pos[1] },
                 finish  = { buf_line, pos[2] } }
  end
  return rules
end

--- Return highlight rules for all NULL (vim.NIL) cells in the data rows.
--- @param tbl FormattedTable
--- @return table   list of { higroup, start, finish } rules
function M.null_hl_rules(tbl)
  local rules = {}
  -- tbl.lines[1] = header; data rows start at tbl.lines[2].
  -- With one separator after the header, data row i maps to 0-indexed buffer line i.
  for i = 2, #tbl.lines do
    local row      = tbl.lines[i]
    local buf_line = i
    local positions = M.column_byte_positions(row, tbl.columns_width, tbl.sep, tbl.decimal_sep)
    for j, cell in ipairs(row) do
      if cell == vim.NIL then
        rules[#rules + 1] = {
          higroup = "GrannosNull",
          start   = { buf_line, positions[j][1] },
          finish  = { buf_line, positions[j][2] },
        }
      end
    end
  end
  return rules
end

--- Return highlight rules for all LobPlaceholder cells in the data rows.
--- @param tbl FormattedTable
--- @return table   list of { higroup, start, finish } rules
function M.lob_hl_rules(tbl)
  local rules = {}
  -- tbl.lines[1] = header; data rows start at tbl.lines[2].
  -- With one separator after the header, data row i maps to 0-indexed buffer line i.
  for i = 2, #tbl.lines do
    local row      = tbl.lines[i]
    local buf_line = i
    local positions = M.column_byte_positions(row, tbl.columns_width, tbl.sep, tbl.decimal_sep)
    for j, cell in ipairs(row) do
      if is_lob(cell) then
        rules[#rules + 1] = {
          higroup = "GrannosLob",
          start   = { buf_line, positions[j][1] },
          finish  = { buf_line, positions[j][2] },
        }
      end
    end
  end
  return rules
end

--- Return highlight rules for all SpecialFloat cells (NaN/Infinity/-Infinity) in the data rows.
--- @param tbl FormattedTable
--- @return table   list of { higroup, start, finish } rules
function M.special_float_hl_rules(tbl)
  local rules = {}
  -- tbl.lines[1] = header; data rows start at tbl.lines[2].
  -- With one separator after the header, data row i maps to 0-indexed buffer line i.
  for i = 2, #tbl.lines do
    local row      = tbl.lines[i]
    local buf_line = i
    local positions = M.column_byte_positions(row, tbl.columns_width, tbl.sep, tbl.decimal_sep)
    for j, cell in ipairs(row) do
      if is_special_float(cell) then
        rules[#rules + 1] = {
          higroup = "GrannosSpecialFloat",
          start   = { buf_line, positions[j][1] },
          finish  = { buf_line, positions[j][2] },
        }
      end
    end
  end
  return rules
end

--- Return highlight rules for the thousands-separator characters within numeric cells.
--- Only matches within the grouped integer part, so a decimal separator that happens
--- to share the same character as the thousands separator is never dimmed.
--- @param tbl FormattedTable
--- @return table   list of { higroup, start, finish } rules
function M.thousands_hl_rules(tbl)
  local rules = {}
  if not tbl.sep then return rules end
  -- tbl.lines[1] = header; data rows start at tbl.lines[2], mapping to 0-indexed buffer line i.
  for i = 2, #tbl.lines do
    local row       = tbl.lines[i]
    local buf_line  = i
    local positions = M.column_byte_positions(row, tbl.columns_width, tbl.sep, tbl.decimal_sep)
    for j, cell in ipairs(row) do
      local sep_char = tbl.sep[j]
      if type(cell) == "number" and sep_char then
        local s, int_len = format_number(cell, sep_char, tbl.decimal_sep)
        local base  = positions[j][1]
          + text_offset(s, tbl.columns_width[j], tbl.left_aligned and tbl.left_aligned[j] or false)
        local int_s = s:sub(1, int_len)
        local from  = 1
        while true do
          local a, b = int_s:find(sep_char, from, true)
          if not a then break end
          rules[#rules + 1] = {
            higroup = "GrannosThousandsSeparator",
            start   = { buf_line, base + a - 1 },
            finish  = { buf_line, base + b },
          }
          from = b + 1
        end
      end
    end
  end
  return rules
end


--- Set up box-drawing character highlighting for a buffer that shows a table.
--- Call once after creating the buffer. 'synmaxcol' is lifted: syntax stops
--- matching past it (3000 bytes by default), and every box-drawing glyph is 3
--- bytes, so a wide table's borders would otherwise lose their colour from
--- about its 1000th character on.
--- @param buf_id integer
function M.setup_buf_hl(buf_id)
  vim.bo[buf_id].synmaxcol = 0
  vim.api.nvim_buf_call(buf_id, function()
    vim.cmd("syntax match GrannosTableBorder /[│├┼─┤]/")
  end)
  vim.cmd("highlight link GrannosTableBorder GrannosBorder")
end

return M
