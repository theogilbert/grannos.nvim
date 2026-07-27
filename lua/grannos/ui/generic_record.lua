-- Float for a group of GenericRecordDescription (a bare array returned for
-- driver-specific groups whose members don't fit any of the other
-- description shapes, e.g. a Prometheus job's scrape targets): fields shared
-- by every record render once as defaults, fields that vary become a table
-- with one row per record. Also a single-record detail float
-- (GenericRecordDescription).
local M = {}

local pane      = require("grannos.ui.detail_pane")
local table_fmt = require("grannos.table")
local hl        = require("grannos.hl")
local ICON      = "󰋼 "

--- @param v any
--- @return boolean
local function is_nil(v) return pane.is_nil(v) end

local BOOL_GLYPH = { [true] = "✓", [false] = "✗" }
local BOOL_HL    = { [true] = "GrannosBoolTrue", [false] = "GrannosBoolFalse" }

--- Classify `value` as a boolean-like string, case-insensitively — deliberately
--- narrow (only literal "true"/"false") so numeric or yes/no fields that merely
--- resemble a boolean aren't misidentified — or nil if it isn't one. Exposed on
--- `M`, alongside `format_value`, for unit testing without a floating window.
--- @param value any
--- @return boolean|nil
function M.bool_value(value)
  if value == nil then return nil end
  local v = tostring(value):lower()
  if v == "true" then return true end
  if v == "false" then return false end
  return nil
end

--- Return the display text for a field value — the ✓/✗ glyph when it's
--- boolean-like, its raw text otherwise — and the glyph's highlight group,
--- or nil when the value isn't boolean-like.
--- @param value any
--- @return string display
--- @return string|nil hl_group
function M.format_value(value)
  local b = M.bool_value(value)
  if b == nil then return tostring(value), nil end
  return BOOL_GLYPH[b], BOOL_HL[b]
end

--- Return the estimated rendered line count for a single record detail view.
--- @param rec table  GenericRecordDescription
--- @return integer
local function estimate_lines(rec)
  local fields = type(rec.fields) == "table" and rec.fields or {}
  return 2 + #fields  -- kind line + blank + one line per field
end

--- Populate `buf` with the label/value fields of a single generic record.
--- @param buf integer
--- @param rec table  GenericRecordDescription
local function render(buf, rec)
  local lines = {}
  local hls   = {}

  if not is_nil(rec.kind) and rec.kind ~= "" then
    local krow = #lines
    local kline = "  " .. rec.kind
    lines[#lines + 1] = kline
    hls[#hls + 1] = { "GrannosExplorerDim", krow, 0, #kline }
  end
  lines[#lines + 1] = ""

  local fields = type(rec.fields) == "table" and rec.fields or {}
  local label_w = 0
  for _, f in ipairs(fields) do
    label_w = math.max(label_w, vim.fn.strdisplaywidth(tostring(f.label)))
  end

  for _, f in ipairs(fields) do
    local label  = tostring(f.label)
    local frow   = #lines
    local prefix = "  " .. label .. string.rep(" ", label_w - vim.fn.strdisplaywidth(label)) .. "  "
    local value_text, value_hl = M.format_value(f.value)
    lines[#lines + 1] = prefix .. value_text
    hls[#hls + 1] = { "GrannosExplorerDim", frow, 2, 2 + #label }
    if value_hl then
      hls[#hls + 1] = { value_hl, frow, #prefix, #prefix + #value_text }
    end
  end

  pane.apply(buf, lines, hls)
end

--- Return the value of `label` in `rec.fields`, or nil if `rec` has no such field.
--- @param rec   table  GenericRecordDescription
--- @param label string
--- @return string|nil
function M.field_value(rec, label)
  for _, f in ipairs(rec.fields or {}) do
    if f.label == label then return f.value end
  end
  return nil
end

--- Split the field labels seen across `records` into ones every record has
--- with an identical value (shared defaults, rendered once) and ones that
--- vary or are missing on some record (rendered as table columns instead).
--- With fewer than two records there's nothing to compare, so "common" (in
--- the sense of "shared across records") isn't a meaningful concept — every
--- label is treated as varying, so a single-record table still shows its
--- fields as columns instead of being entirely swallowed into a "Defaults"
--- block that would just restate the one row.
--- Exposed on `M` (rather than kept local) so this — the one piece of actual
--- decision-making in this module — is unit-testable independent of any
--- floating window.
--- @param records table[]  GenericRecordDescription[]
--- @return table     common          ordered {label, value}[]
--- @return string[]  varying_labels  ordered labels to render as table columns
function M.split_common_and_varying(records)
  local label_order, seen = {}, {}
  for _, rec in ipairs(records) do
    for _, f in ipairs(rec.fields or {}) do
      if not seen[f.label] then
        seen[f.label] = true
        label_order[#label_order + 1] = f.label
      end
    end
  end

  if #records < 2 then
    return {}, label_order
  end

  local common, varying_labels = {}, {}
  for _, label in ipairs(label_order) do
    local values, all_present = {}, true
    for _, rec in ipairs(records) do
      local value = M.field_value(rec, label)
      if value == nil then all_present = false end
      values[#values + 1] = value
    end
    local all_equal = true
    for i = 2, #values do
      if values[i] ~= values[1] then
        all_equal = false
        break
      end
    end
    if all_present and all_equal then
      common[#common + 1] = { label = label, value = values[1] }
    else
      varying_labels[#varying_labels + 1] = label
    end
  end
  return common, varying_labels
end

--- Populate `buf` with a shared-defaults header (fields identical across
--- every record, when there's more than one) followed by a table with one
--- row per record — labeled by its `name` — and one column per field that
--- varies between records (every field, when there's only one record).
--- @param buf     integer
--- @param records table[]  GenericRecordDescription[], non-empty
--- @return integer widest  display width of the widest rendered line
local function render_table(buf, records)
  local common, varying_labels = M.split_common_and_varying(records)
  local lines, hls = {}, {}

  local kind = records[1].kind
  if not is_nil(kind) and kind ~= "" then
    local krow = #lines
    local kline = "  " .. kind
    lines[#lines + 1] = kline
    hls[#hls + 1] = { "GrannosExplorerDim", krow, 0, #kline }
    lines[#lines + 1] = ""
  end

  if #common > 0 then
    pane.section(lines, hls, "Defaults")
    local label_w = 0
    for _, c in ipairs(common) do
      label_w = math.max(label_w, vim.fn.strdisplaywidth(c.label))
    end
    for _, c in ipairs(common) do
      local frow   = #lines
      local prefix = "  " .. c.label .. string.rep(" ", label_w - vim.fn.strdisplaywidth(c.label)) .. "  "
      local value_text, value_hl = M.format_value(c.value)
      lines[#lines + 1] = prefix .. value_text
      hls[#hls + 1] = { "GrannosExplorerDim", frow, 2, 2 + #c.label }
      if value_hl then
        hls[#hls + 1] = { value_hl, frow, #prefix, #prefix + #value_text }
      end
    end
    lines[#lines + 1] = ""
  end

  pane.section(lines, hls, "Records (" .. #records .. ")")

  local header = { "Name" }
  for _, label in ipairs(varying_labels) do header[#header + 1] = label end
  local rows = { header }
  -- Positions of ✓/✗ cells, recorded now (raw values) so they can be
  -- highlighted once from_structured_data has fixed each column's byte offsets.
  local bool_cells = {}
  for _, rec in ipairs(records) do
    local row = { rec.name }
    for col_idx, label in ipairs(varying_labels) do
      local raw = M.field_value(rec, label)
      if raw == nil then
        row[#row + 1] = ""
      else
        local value_text, value_hl = M.format_value(raw)
        row[#row + 1] = value_text
        if value_hl then
          bool_cells[#bool_cells + 1] = { data_line = #rows + 1, col = col_idx + 1, hl = value_hl }
        end
      end
    end
    rows[#rows + 1] = row
  end

  local formatted = table_fmt.from_structured_data(rows, 1)
  local table_start_line = #lines
  for _, line in ipairs(formatted.text) do
    lines[#lines + 1] = line
  end
  for _, bc in ipairs(bool_cells) do
    local positions = table_fmt.column_byte_positions(
      rows[bc.data_line], formatted.columns_width, formatted.sep, formatted.decimal_sep)
    local pos = positions[bc.col]
    hls[#hls + 1] = { bc.hl, table_start_line + bc.data_line, pos[1], pos[2] }
  end

  local widest = 0
  for _, line in ipairs(lines) do
    widest = math.max(widest, vim.fn.strdisplaywidth(line))
  end

  pane.apply(buf, lines, hls)
  table_fmt.setup_buf_hl(buf)
  return widest
end

--- Open a float with a shared-defaults header (when there's more than one
--- record) and a table of per-record fields for a group of generic records
--- (e.g. a Prometheus job's targets) — one row per record, even when there's
--- only one.
--- @param details table   Bare array of GenericRecordDescription, as decoded
---                        from the server response
--- @param title   string  Window title (caller derives from the request path)
function M.open(details, title)
  local records = type(details) == "table" and details or {}
  if #records == 0 then
    vim.notify("grannos: nothing to describe for this node", vim.log.levels.WARN)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].modifiable = false

  local widest = render_table(buf, records)

  local ew     = vim.o.columns
  local eh     = vim.o.lines
  local width  = math.min(math.max(widest + 2, 40), ew - 4)
  local max_h  = math.max(math.floor(eh * 0.72), 8)
  local height = math.min(math.max(vim.api.nvim_buf_line_count(buf), 8), max_h)
  local col0   = math.max(0, math.floor((ew - width  - 2) / 2))
  local row0   = math.max(0, math.floor((eh - height - 2) / 2))

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = row0, col = col0,
    width     = width, height = height,
    style     = "minimal", border = "rounded",
    title     = title or " Records ",
    title_pos = "center",
  })
  vim.api.nvim_win_set_hl_ns(win, hl.NS_ID)
  vim.api.nvim_set_option_value("wrap", false, { win = win })

  local function close() pcall(vim.api.nvim_win_close, win, true) end

  local aug = vim.api.nvim_create_augroup("GrannosGenericRecordTable_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug, pattern = tostring(win), once = true,
    callback = function() vim.api.nvim_del_augroup_by_id(aug) end,
  })
  vim.keymap.set("n", "q",     close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, silent = true })
end

--- Open a single-record detail float.
--- @param rec table  GenericRecordDescription as decoded from the server response
function M.open_single(rec)
  pane.open_single({
    item     = rec,
    title    = ICON .. rec.name,
    render   = render,
    estimate = estimate_lines,
  })
end

return M
