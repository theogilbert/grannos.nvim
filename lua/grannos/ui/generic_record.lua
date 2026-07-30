-- Float for a group of GenericRecordDescription (a bare array returned for
-- driver-specific groups whose members don't fit any of the other
-- description shapes, e.g. a Prometheus job's scrape targets): every field
-- of every record renders as a table column, one row per record. Also a
-- single-record detail float (GenericRecordDescription).
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

--- Return the field labels seen across `records`, in first-seen order, with
--- duplicates removed — every one of them becomes a table column.
--- Exposed on `M` (rather than kept local) so it's unit-testable independent
--- of any floating window.
--- @param records table[]  GenericRecordDescription[]
--- @return string[]  labels  ordered labels to render as table columns
function M.field_labels(records)
  local label_order, seen = {}, {}
  for _, rec in ipairs(records) do
    for _, f in ipairs(rec.fields or {}) do
      if not seen[f.label] then
        seen[f.label] = true
        label_order[#label_order + 1] = f.label
      end
    end
  end
  return label_order
end

--- Populate `buf` with a table with one row per record — labeled by its
--- `name` — and one column per field seen across the group.
--- @param buf     integer
--- @param records table[]  GenericRecordDescription[], non-empty
--- @return integer widest  display width of the widest rendered line
local function render_table(buf, records)
  local labels = M.field_labels(records)
  local lines, hls = {}, {}

  local kind = records[1].kind
  if not is_nil(kind) and kind ~= "" then
    local krow = #lines
    local kline = "  " .. kind
    lines[#lines + 1] = kline
    hls[#hls + 1] = { "GrannosExplorerDim", krow, 0, #kline }
    lines[#lines + 1] = ""
  end

  pane.section(lines, hls, "Records (" .. #records .. ")")

  local header = { "Name" }
  for _, label in ipairs(labels) do header[#header + 1] = label end
  local rows = { header }
  -- Positions of ✓/✗ cells, recorded now (raw values) so they can be
  -- highlighted once from_structured_data has fixed each column's byte offsets.
  local bool_cells = {}
  for _, rec in ipairs(records) do
    local row = { rec.name }
    for col_idx, label in ipairs(labels) do
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

--- Open a float with a table of per-record fields for a group of generic
--- records (e.g. a Prometheus job's targets) — one row per record, one
--- column per field.
--- @param details    table      Bare array of GenericRecordDescription, as decoded
---                               from the server response
--- @param title      string     Window title (caller derives from the request path)
--- @param conn_id    any|nil    connection to refetch from; with `group_path`, enables "r" to
---                               refresh the whole set of records (there's no per-record leaf
---                               path convention for generic records, so refresh re-describes
---                               the whole group)
--- @param group_path string[]|nil  path to the group node `details` was described from
function M.open(details, title, conn_id, group_path)
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
  local max_h  = math.max(math.floor(eh * 0.72), 8)
  local base_title = title or " Records "

  --- (Re)size and reposition the float around `buf`'s current content.
  --- @param win integer
  local function resize(win)
    local width  = math.min(math.max(widest + 2, 40), ew - 4)
    local height = math.min(math.max(vim.api.nvim_buf_line_count(buf), 8), max_h)
    pcall(vim.api.nvim_win_set_config, win, {
      relative = "editor",
      row      = math.max(0, math.floor((eh - height - 2) / 2)),
      col      = math.max(0, math.floor((ew - width  - 2) / 2)),
      width    = width, height = height,
    })
  end

  local init_width  = math.min(math.max(widest + 2, 40), ew - 4)
  local init_height = math.min(math.max(vim.api.nvim_buf_line_count(buf), 8), max_h)
  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = math.max(0, math.floor((eh - init_height - 2) / 2)),
    col       = math.max(0, math.floor((ew - init_width  - 2) / 2)),
    width     = init_width, height = init_height,
    style     = "minimal", border = "rounded",
    title     = base_title,
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

  if conn_id and group_path then
    local refreshing = false
    --- Re-describe group_path with the server cache discarded, and redraw in place.
    local function refresh()
      if refreshing or not vim.api.nvim_win_is_valid(win) then return end
      refreshing = true
      pcall(vim.api.nvim_win_set_config, win, { title = base_title:gsub(" $", " (refreshing…) ") })
      pane.refetch(conn_id, group_path, function(err, new_details)
        vim.schedule(function()
          refreshing = false
          if not vim.api.nvim_win_is_valid(win) then return end
          if err then
            pcall(vim.api.nvim_win_set_config, win, { title = base_title })
            vim.notify("grannos: " .. err, vim.log.levels.ERROR)
            return
          end
          local new_records = type(new_details) == "table" and new_details or {}
          if #new_records == 0 then
            pcall(vim.api.nvim_win_set_config, win, { title = base_title })
            vim.notify("grannos: no records found", vim.log.levels.WARN)
            return
          end
          records = new_records
          widest  = render_table(buf, records)
          pcall(vim.api.nvim_win_set_config, win, { title = base_title })
          resize(win)
          pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
        end)
      end)
    end
    vim.keymap.set("n", "r", refresh, { buffer = buf, nowait = true, silent = true })
  end
end

--- Open a single-record detail float.
--- @param rec     table       GenericRecordDescription as decoded from the server response
--- @param conn_id any|nil     connection to refetch from; with `path`, enables "r" to refresh
--- @param path    string[]|nil  leaf path this record was described at
function M.open_single(rec, conn_id, path)
  pane.open_single({
    item     = rec,
    title    = ICON .. rec.name,
    render   = render,
    estimate = estimate_lines,
    conn_id  = conn_id,
    path     = path,
  })
end

return M
