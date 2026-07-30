-- Query results window.
--
-- One buffer per (source buffer, connection) pair, named:
--   "grannos://results [conn (driver)] [filename]"   (named source buf)
--   "grannos://results [conn (driver)] #N"            (unnamed source buf)
-- Changing a source buffer's connection and running another query therefore opens
-- a new results buffer rather than renaming/reusing the old one; the old one stays
-- listed so the user can still :b back to it.
-- Buffers are listed so the user can :b between them.
-- One results window per tab: running a query in tab A never clobbers tab B.
local Buffer         = require("grannos.buffer")
local table_fmt      = require("grannos.table")
local hl             = require("grannos.hl")
local config         = require("grannos.config")
local col_picker     = require("grannos.ui.col_picker")
local connections    = require("grannos.connections")
local export         = require("grannos.export")
local client         = require("grannos.client")
local content_buffer = require("grannos.ui.content_buffer")
local hover          = require("grannos.ui.hover")
local column_ui      = require("grannos.ui.column")

local M = {}

local BUFNAME = "grannos://results"

-- Same glyph as the gutter's running mark (see ui/gutter.lua), so the results
-- pane and the gutter agree on what "waiting for the server" looks like.
local ICON_RUNNING = "\xEE\xA9\xB7"  -- U+EA77

local render_table              -- forward declaration; defined after apply_highlights
local export_results            -- forward declaration; defined after open_export_buffer
local toggle_thousands_separator -- forward declaration; defined after rebuild_segments
local segment_at_line           -- forward declaration; defined after render_segments

--- Return true when column arrays `a` and `b` are identical.
--- @param a string[]
--- @param b string[]
--- @return boolean
local function same_columns(a, b)
  if #a ~= #b then return false end
  for i, c in ipairs(a) do if c ~= b[i] then return false end end
  return true
end

--- Return the `buf_state.raw_columns` indices for `buf_state.vis_columns`, in display order.
--- @param buf_state table
--- @return integer[]
local function visible_col_indices(buf_state)
  local indices = {}
  for _, vc in ipairs(buf_state.vis_columns) do
    for i, rc in ipairs(buf_state.raw_columns) do
      if rc == vc then table.insert(indices, i); break end
    end
  end
  return indices
end

--- Build the row-count label shown above the results table.
--- @param rows_returned integer
--- @param rows_total    integer
--- @param page          integer  1-indexed current page
--- @param page_size     integer
--- @return string
local function rows_label(rows_returned, rows_total, page, page_size)
  local total_pages = math.max(1, math.ceil(rows_returned / page_size))
  local first       = (page - 1) * page_size + 1
  local last        = math.min(rows_returned, page * page_size)

  local count
  if rows_returned == rows_total then
    count = total_pages <= 1
        and (rows_returned .. " row" .. (rows_returned == 1 and "" or "s"))
        or  ("rows %d–%d of %d"):format(first, last, rows_returned)
  else
    count = total_pages <= 1
        and ("%d returned  ·  %d matched"):format(rows_returned, rows_total)
        or  ("rows %d–%d of %d returned  ·  %d matched"):format(first, last, rows_returned, rows_total)
  end

  if total_pages > 1 then
    return count .. ("  ·  page %d/%d  (] next  [ prev)"):format(page, total_pages)
  end
  return count
end

--- Build a per-display-column thousands-separator array from the set of columns the
--- user has toggled on for `buf_state`. The separator is off by default for every column;
--- `t` on a results-pane cell toggles it for that column only.
--- @param display_columns string[]  columns in display order
--- @param sep_columns     table     set of column names with the separator toggled on
--- @return string[]|nil
local function sep_array_for(display_columns, sep_columns)
  local char = config.options.results.thousands_separator
  char = (char and char ~= "") and char or nil
  if not char or not next(sep_columns) then return nil end
  local arr, any = {}, false
  for i, name in ipairs(display_columns) do
    if sep_columns[name] then arr[i] = char; any = true end
  end
  return any and arr or nil
end

--- Return the "N row(s) <verb>" message for a DML result.
--- @param n    integer
--- @param verb string
--- @return string
local function rows_affected_msg(n, verb)
  return n .. " row" .. (n == 1 and "" or "s") .. " " .. verb
end

--- Format a duration in milliseconds as a human-readable string ("1.234s", "2m 5s", etc.).
--- @param ms number
--- @return string
local function format_duration(ms)
  local total_s = ms / 1000
  if total_s >= 3600 then
    local h = math.floor(total_s / 3600)
    local m = math.floor((total_s % 3600) / 60)
    return ("%dh %dm"):format(h, m)
  elseif total_s >= 60 then
    local m = math.floor(total_s / 60)
    local s = math.floor(total_s % 60)
    return ("%dm %ds"):format(m, s)
  else
    return ("%.3f"):format(total_s):gsub("0+$", ""):gsub("%.$", "") .. "s"
  end
end


-- state.buffers[buf_key] = buf_state        (buf_key = buf_key_for(src_bufnr, conn_key))
-- state.win_ids[tabpage] = win_id            (one results window per tab)
-- state.autocmds[win_id] = { scroll, close }
local state = {
  buffers    = {},
  win_ids    = {},
  autocmds   = {},
  active_src = nil,  -- buf_key set by set_conn_name before each query
}

--- Return the buf_state for the currently active source buffer, or nil.
--- @return table|nil
local function active_buf_state()
  return state.active_src and state.buffers[state.active_src]
end

--- Return the buf_state whose Buffer.buf_id matches the buffer in `win_id`, or nil.
--- @param win_id integer
--- @return table|nil
local function win_buf_state_for(win_id)
  if not win_id or not vim.api.nvim_win_is_valid(win_id) then return nil end
  local buf_id = vim.api.nvim_win_get_buf(win_id)
  for _, buf_state in pairs(state.buffers) do
    if buf_state.buffer.buf_id == buf_id then return buf_state end
  end
  return nil
end

--- Return the results window id for the current tab, or nil.
--- @return integer|nil
local function current_results_win()
  return state.win_ids[vim.api.nvim_get_current_tabpage()]
end

--- Return the buf_state for the results window in the current tab, or nil.
--- @return table|nil
local function win_buf_state()
  return win_buf_state_for(current_results_win())
end


--- Scroll the results window left (direction < 0) or right (direction > 0) by one column.
--- @param direction integer  positive = right, negative = left
local function scroll_columns(direction)
  local win_id = vim.api.nvim_get_current_win()
  local buf_state = win_buf_state_for(win_id)
  if not buf_state or not buf_state.table_data then return end
  local boundaries = table_fmt.column_boundaries(buf_state.table_data.columns_width)

  local leftcol
  vim.api.nvim_win_call(win_id, function()
    leftcol = vim.fn.winsaveview().leftcol
  end)

  local target = leftcol
  if direction > 0 then
    local win_width = vim.api.nvim_win_get_width(win_id)
    for i, b in ipairs(boundaries) do
      if i == #boundaries then break end
      if b > leftcol then
        local new_target = math.max(0, boundaries[i + 1] - win_width + 1)
        if new_target > leftcol then target = new_target break end
      end
    end
  else
    target = 0
    for _, b in ipairs(boundaries) do
      if b < leftcol then target = b end
    end
  end

  if target ~= leftcol then
    vim.api.nvim_win_call(win_id, function()
      local cursor_vcol = vim.fn.virtcol(".")
      local new_vcol    = math.max(1, target + cursor_vcol - leftcol)
      local row         = vim.fn.line(".")
      local byte_col    = vim.fn.virtcol2col(0, row, new_vcol) - 1
      vim.api.nvim_win_set_cursor(0, { row, byte_col })
      vim.fn.winrestview({ leftcol = target })
    end)
  end
end


--- Reset the results window cursor to line 1, column 0, with no horizontal scroll.
local function reset_cursor()
  local win_id = current_results_win()
  if not win_id or not vim.api.nvim_win_is_valid(win_id) then return end
  vim.api.nvim_win_set_cursor(win_id, { 1, 0 })
  vim.api.nvim_win_call(win_id, function() vim.fn.winrestview({ leftcol = 0 }) end)
end

--- Redraw truncation indicator extmarks (◂/▸) based on the current scroll position.
--- @param win_id integer|nil  defaults to the current tab's results window
local function update_truncation_indicators(win_id)
  win_id = win_id or current_results_win()
  if not win_id or not vim.api.nvim_win_is_valid(win_id) then return end
  local buf_state = win_buf_state_for(win_id)
  if not buf_state then return end
  local buf_id = buf_state.buffer.buf_id
  vim.api.nvim_buf_clear_namespace(buf_id, hl.TRUNCATION_NS_ID, 0, -1)

  if not buf_state.table_data then return end
  local boundaries = table_fmt.column_boundaries(buf_state.table_data.columns_width)

  local win_width = vim.api.nvim_win_get_width(win_id)
  local leftcol = 0
  vim.api.nvim_win_call(win_id, function()
    leftcol = vim.fn.winsaveview().leftcol
  end)

  local trunc_right = boundaries[#boundaries] >= leftcol + win_width
  local trunc_left  = leftcol > 0
  if not trunc_right and not trunc_left then return end

  for row = 0, vim.api.nvim_buf_line_count(buf_id) - 1 do
    if trunc_right then
      vim.api.nvim_buf_set_extmark(buf_id, hl.TRUNCATION_NS_ID, row, 0, {
        virt_text = { { "▸", "GrannosTruncated" } },
        virt_text_pos = "right_align",
      })
    end
    if trunc_left then
      vim.api.nvim_buf_set_extmark(buf_id, hl.TRUNCATION_NS_ID, row, 0, {
        virt_text         = { { "◂", "GrannosTruncated" } },
        virt_text_win_col = 0,
      })
    end
  end
end


--- Remove autocmds and win_ids tracking for a closed results window.
--- @param win_id integer
local function teardown(win_id)
  local ac = state.autocmds[win_id]
  if ac then
    pcall(vim.api.nvim_del_autocmd, ac.scroll)
    pcall(vim.api.nvim_del_autocmd, ac.close)
    state.autocmds[win_id] = nil
  end
  for tab, wid in pairs(state.win_ids) do
    if wid == win_id then state.win_ids[tab] = nil; break end
  end
end

--- Set the display options and highlight namespace any window showing a results
--- buffer should have, regardless of how it was opened.
--- @param win_id integer
local function configure_win_chrome(win_id)
  vim.api.nvim_set_option_value("number",       false, { win = win_id })
  vim.api.nvim_set_option_value("signcolumn",   "no",  { win = win_id })
  vim.api.nvim_set_option_value("winfixheight", true,  { win = win_id })
  vim.api.nvim_set_option_value("winfixwidth",  true,  { win = win_id })
  vim.api.nvim_set_option_value("wrap",         false, { win = win_id })
  vim.api.nvim_win_set_hl_ns(win_id, hl.NS_ID)
end

--- Ensure chrome, scroll tracking, and close-cleanup are wired up for any window
--- displaying a results buffer — whether it was opened by running a query or by
--- the user navigating there directly (`:sb`, `:b`, buffer list, etc.).
--- @param win_id integer
local function ensure_win_setup(win_id)
  configure_win_chrome(win_id)
  update_truncation_indicators(win_id)
  if state.autocmds[win_id] then return end
  state.autocmds[win_id] = {
    scroll = vim.api.nvim_create_autocmd("WinScrolled", {
      pattern  = tostring(win_id),
      callback = function() update_truncation_indicators(win_id) end,
    }),
    close = vim.api.nvim_create_autocmd("WinClosed", {
      pattern  = tostring(win_id),
      once     = true,
      callback = function() teardown(win_id) end,
    }),
  }
end

vim.api.nvim_create_autocmd("BufWinEnter", {
  pattern  = BUFNAME .. "*",
  callback = function() ensure_win_setup(vim.api.nvim_get_current_win()) end,
})

--- Open a new results split/vsplit for the current tab.
--- @param buf_id integer
local function open_win(buf_id)
  local opts     = config.options.results
  local cmd      = opts.split == "right"
      and "botright vsplit"
      or  ("botright " .. opts.height .. "split")
  local prev_win = vim.api.nvim_get_current_win()
  local tab      = vim.api.nvim_get_current_tabpage()
  vim.cmd(cmd)
  local win_id = vim.api.nvim_get_current_win()
  state.win_ids[tab] = win_id
  vim.api.nvim_win_set_buf(win_id, buf_id)
  vim.api.nvim_set_current_win(prev_win)
end

--- Open the results window for the current tab if closed; otherwise swap the buffer.
--- @param buf_id integer
local function ensure_win(buf_id)
  local tab    = vim.api.nvim_get_current_tabpage()
  local win_id = state.win_ids[tab]
  if win_id and vim.api.nvim_win_is_valid(win_id) then
    vim.api.nvim_win_set_buf(win_id, buf_id)
  else
    open_win(buf_id)
  end
end

--- Return a short suffix that identifies the source buffer (" [filename]" or " #N").
--- @param src_bufnr integer|nil
--- @return string
local function src_buf_suffix(src_bufnr)
  if not src_bufnr then return "" end
  local name = vim.api.nvim_buf_get_name(src_bufnr)
  if name ~= "" then
    return " [" .. vim.fn.fnamemodify(name, ":t") .. "]"
  end
  return " #" .. src_bufnr
end

--- Build the `state.buffers` key for a (source buffer, connection) pair. Two calls
--- with the same source buffer but different connections must produce different
--- keys, so changing a buffer's connection routes to a fresh results buffer.
--- @param src_bufnr integer|nil
--- @param conn_key  string|nil
--- @return string
local function buf_key_for(src_bufnr, conn_key)
  return (src_bufnr or 0) .. "\0" .. (conn_key or "")
end

--- Open a float showing the SQL text that produced the current results. In a
--- batch view, shows only the statement whose segment is under the cursor,
--- not the whole batch.
--- @param buf_state table
local function show_source_query(buf_state)
  local sql = buf_state.query
  if buf_state.segments and #buf_state.segments > 0 then
    local seg = segment_at_line(buf_state, vim.fn.line(".") - 1)
    sql = seg and seg.sql
  end
  if not sql then return end
  local lines = vim.split(sql, "\n", { plain = true })
  local fbuf  = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.bo[fbuf].modifiable = false
  vim.bo[fbuf].bufhidden  = "wipe"
  if buf_state.query_ft and buf_state.query_ft ~= "" then
    vim.bo[fbuf].filetype = buf_state.query_ft
    pcall(vim.treesitter.start, fbuf)
  end
  local ui     = vim.api.nvim_list_uis()[1]
  local width  = math.min(math.max(20, math.floor(ui.width * 0.6)), 120)
  local height = math.min(#lines + 2, math.floor(ui.height * 0.6))
  local row    = math.floor((ui.height - height) / 2)
  local col    = math.floor((ui.width  - width)  / 2)
  local fwin   = vim.api.nvim_open_win(fbuf, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "rounded",
    title     = " Source query ",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value("wrap",       false, { win = fwin })
  vim.api.nvim_set_option_value("number",     false, { win = fwin })
  vim.api.nvim_set_option_value("signcolumn", "no",  { win = fwin })
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, function()
      if vim.api.nvim_win_is_valid(fwin) then vim.api.nvim_win_close(fwin, true) end
    end, { buffer = fbuf, nowait = true, silent = true })
  end
end

--- Open `content` in a new unnamed, listed buffer in a new tab so the user can inspect or :w it.
--- @param content  string  newline-joined export text
--- @param filetype string  Neovim filetype to assign, or "" for none
local function open_export_buffer(content, filetype)
  local lines = vim.split(content, "\n", { plain = true })
  local buf   = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if filetype ~= "" then vim.bo[buf].filetype = filetype end
  vim.cmd("tab sbuffer " .. buf)
end

--- Prompt for an export format and open the full (unpaginated) result set in a scratch buffer.
--- Serialization runs across multiple event-loop ticks (export.run_async) so large result
--- sets don't freeze the UI for the duration of the export.
--- @param buf_state table
export_results = function(buf_state)
  if not buf_state.raw_columns or not buf_state.raw_rows then return end
  vim.ui.select(export.FORMATS, { prompt = "Export results as:" }, function(format)
    if not format then return end
    vim.notify("grannos: exporting…", vim.log.levels.INFO)
    export.run_async(function()
      local indices = visible_col_indices(buf_state)
      local rows = {}
      for ri, row in ipairs(buf_state.raw_rows) do
        local r = {}
        for _, idx in ipairs(indices) do table.insert(r, row[idx]) end
        table.insert(rows, r)
        if coroutine.isyieldable() and ri % export.CHUNK_SIZE == 0 then coroutine.yield() end
      end
      return export.render(format, buf_state.vis_columns, rows)
    end, function(content)
      open_export_buffer(content, export.FILETYPES[format])
    end)
  end)
end

--- Return the raw LobPlaceholder cell under the cursor, or nil when the cursor
--- isn't on a LOB cell. `table_data.lines` holds raw cell values (in the
--- currently-rendered page and visible-column order) at the same 0-indexed
--- buffer-line numbering `table.lua`'s *_hl_rules functions use internally —
--- see their "data row i maps to 0-indexed buffer line i" comment. The table
--- always starts at absolute buffer line 2 (row-count label, blank line, then
--- the table itself — see render_table's `content = { label, "" }`).
--- @param buf_state table
--- @return table|nil
local function lob_cell_at_cursor(buf_state)
  local tbl = buf_state.table_data
  if not tbl then return nil end
  local buf_line  = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-indexed
  local data_line = buf_line - 2
  local row       = tbl.lines[data_line]
  if not row then return nil end
  local col_idx = table_fmt.get_column_at_cursor(tbl.columns_width, vim.fn.virtcol("."))
  local cell     = col_idx and row[col_idx]
  if type(cell) == "table" and cell.type == "lob" then return cell end
  return nil
end

--- Return the download ref for the LOB cell under the cursor, notifying and
--- returning nil when there's no LOB cell there or the driver didn't attach a
--- ref (some LOB values can't be safely re-fetched later — e.g. Oracle's LOB
--- locator, which crashes the process if read after its cursor closes; see
--- docs/protocol.md's LobPlaceholder).
--- @param buf_state table
--- @return string|nil
local function lob_ref_at_cursor(buf_state)
  local cell = lob_cell_at_cursor(buf_state)
  if not cell then return nil end
  if not cell.ref then
    vim.notify("grannos: this value can't be downloaded again — re-run the query and use it before the connection moves on", vim.log.levels.WARN)
    return nil
  end
  return cell.ref
end

--- Handle the "o" keymap in the results pane: open the LOB cell under the
--- cursor's full content in a scratch buffer.
--- @param buf_state table
local function on_open_lob_in_buffer(buf_state)
  local ref = lob_ref_at_cursor(buf_state)
  if not ref then return end
  local conn = buf_state.conn_key and require("grannos").get_conn(buf_state.conn_key)
  if not conn then return end
  vim.notify("grannos: downloading…", vim.log.levels.INFO)
  client.request("explore.download", { connection_id = conn.conn_id, ref = ref }, function(err, result)
    vim.schedule(function()
      if err then
        vim.notify("grannos: " .. err, vim.log.levels.ERROR)
        return
      end
      content_buffer.open(result.content_base64, result.filename, result.content_type)
    end)
  end)
end

--- Handle the "s" keymap in the results pane: save the LOB cell under the
--- cursor's full content straight to a local file (prompted), without ever
--- routing it through this buffer — the right choice for binary content.
--- @param buf_state table
local function on_save_lob_to_disk(buf_state)
  local ref = lob_ref_at_cursor(buf_state)
  if not ref then return end
  local conn = buf_state.conn_key and require("grannos").get_conn(buf_state.conn_key)
  if not conn then return end
  vim.ui.input({ prompt = "Save to: ", default = vim.fn.getcwd() .. "/", completion = "file" }, function(path)
    if not path or path == "" then return end
    local abs_path = vim.fn.fnamemodify(path, ":p")
    vim.notify(("grannos: saving to %q…"):format(abs_path), vim.log.levels.INFO)
    client.request("explore.download", { connection_id = conn.conn_id, ref = ref, dest_path = abs_path },
      function(err, result)
        vim.schedule(function()
          if err then
            vim.notify("grannos: " .. err, vim.log.levels.ERROR)
            return
          end
          vim.notify(("grannos: saved %d bytes to %q"):format(result.size, result.written_to), vim.log.levels.INFO)
        end)
      end)
  end)
end

--- Show a condensed column-description hover float for the column under the cursor.
--- Only available when the current results came from an explorer table preview
--- (`buf_state.table_path` set); a no-op otherwise, since arbitrary query results have
--- no reliable way to resolve which table a column came from.
--- @param buf_state table
local function show_column_hover(buf_state)
  if not buf_state.table_path or not buf_state.table_data or not buf_state.vis_columns then return end
  local col_idx  = table_fmt.get_column_at_cursor(buf_state.table_data.columns_width, vim.fn.virtcol("."))
  local col_name = col_idx and buf_state.vis_columns[col_idx]
  if not col_name then return end

  local conn = buf_state.conn_key and require("grannos").get_conn(buf_state.conn_key)
  if not conn then return end

  local function show(details)
    local lines, hls = column_ui.hover_lines(details)
    hover.open(lines, buf_state.buffer.buf_id, { hls = hls, above = true })
  end

  buf_state.column_cache = buf_state.column_cache or {}
  local cached = buf_state.column_cache[col_name]
  if cached then show(cached) return end

  local path = vim.list_extend(vim.list_slice(buf_state.table_path), { "columns", col_name })
  client.request("explore.describe", { connection_id = conn.conn_id, path = path }, function(err, result)
    vim.schedule(function()
      if err or not result or not result.details then return end
      buf_state.column_cache[col_name] = result.details
      show(result.details)
    end)
  end)
end

--- Return an existing valid buf_state for `buf_key` (see `buf_key_for`), or create
--- and register a new one.
--- @param buf_key   string
--- @param buf_title string
--- @return table
local function get_or_create_buf_state(buf_key, buf_title)
  local existing = state.buffers[buf_key]
  if existing and existing.buffer:is_valid() then return existing end

  local buf = Buffer:new(buf_title, "grannos_results", false, "nofile", "hide")
  vim.bo[buf.buf_id].buflisted = true
  table_fmt.setup_buf_hl(buf.buf_id)

  local buf_state = {
    buffer        = buf,
    table_data    = nil,
    segments      = {},
    raw_columns   = nil,
    raw_rows      = nil,
    vis_columns   = nil,
    rows_returned = nil,
    rows_total    = nil,
    duration_ms   = nil,
    page          = 1,
    query         = nil,
    query_ft      = nil,
    conn_key      = nil,
    table_path    = nil,  -- explore-tree path to the source table, if known
    column_cache  = nil,  -- column name -> FieldDescription, reset with table_path
    sep_columns   = {},   -- column name -> true, thousands separator toggled on via `t`
    is_loading    = false,
  }
  state.buffers[buf_key] = buf_state

  buf:set_keymap("n", "q", function()
    local win_id = vim.api.nvim_get_current_win()
    pcall(vim.api.nvim_win_close, win_id, true)
  end, { desc = "Close results window", silent = true })
  buf:set_keymap("n", "L", function() scroll_columns(1)  end,
    { desc = "Scroll right one column", silent = true })
  buf:set_keymap("n", "H", function() scroll_columns(-1) end,
    { desc = "Scroll left one column",  silent = true })
  buf:set_keymap("n", "c", function()
    if not buf_state.raw_columns then return end
    col_picker.open(buf_state.raw_columns, buf_state.vis_columns, function(sel)
      buf_state.vis_columns = sel
      render_table(buf_state)
    end)
  end, { desc = "Select displayed columns", silent = true })
  buf:set_keymap("n", "]", function()
    if not buf_state.raw_rows then return end
    local page_size   = config.options.results.page_size
    local total_pages = math.max(1, math.ceil(#buf_state.raw_rows / page_size))
    if buf_state.page < total_pages then
      buf_state.page = buf_state.page + 1
      render_table(buf_state)
    end
  end, { desc = "Next page", silent = true })
  buf:set_keymap("n", "[", function()
    if not buf_state.raw_rows or buf_state.page <= 1 then return end
    buf_state.page = buf_state.page - 1
    render_table(buf_state)
  end, { desc = "Previous page", silent = true })
  buf:set_keymap("n", "gq", function() show_source_query(buf_state) end,
    { desc = "Show source query", silent = true })
  buf:set_keymap("n", "e", function() export_results(buf_state) end,
    { desc = "Export results", silent = true })
  buf:set_keymap("n", config.options.keymaps.hover_key, function() show_column_hover(buf_state) end,
    { desc = "Show column info", silent = true })
  buf:set_keymap("n", "t", function() toggle_thousands_separator(buf_state) end,
    { desc = "Toggle thousands separator for column", silent = true })
  buf:set_keymap("n", "o", function() on_open_lob_in_buffer(buf_state) end,
    { desc = "Open LOB cell in buffer", silent = true })
  buf:set_keymap("n", "s", function() on_save_lob_to_disk(buf_state) end,
    { desc = "Save LOB cell to disk", silent = true })
  return buf_state
end


--- Apply header, row-count, NULL, LobPlaceholder, and SpecialFloat highlight rules to
--- `buf_state.buffer`.
--- `label_line` and `tbl_offset` are 0-indexed buffer rows.
--- @param buf_state table
--- @param tbl        table   FormattedTable from table_fmt.from_structured_data
--- @param label_line integer  0-indexed row for GrannosRowCount
--- @param tbl_offset integer  0-indexed row where the table starts
local function apply_highlights(buf_state, tbl, label_line, tbl_offset)
  local rules = table_fmt.col_hl_rules("GrannosHeaderRow", tbl_offset, 1, tbl)
  table.insert(rules, {
    higroup = "GrannosRowCount",
    start   = { label_line, 0 },
    finish  = { label_line, -1 },
  })
  local null_rules = table_fmt.null_hl_rules(tbl)
  for _, r in ipairs(null_rules) do
    r.start[1]  = r.start[1]  + tbl_offset
    r.finish[1] = r.finish[1] + tbl_offset
  end
  vim.list_extend(rules, null_rules)
  local lob_rules = table_fmt.lob_hl_rules(tbl)
  for _, r in ipairs(lob_rules) do
    r.start[1]  = r.start[1]  + tbl_offset
    r.finish[1] = r.finish[1] + tbl_offset
  end
  vim.list_extend(rules, lob_rules)
  local special_float_rules = table_fmt.special_float_hl_rules(tbl)
  for _, r in ipairs(special_float_rules) do
    r.start[1]  = r.start[1]  + tbl_offset
    r.finish[1] = r.finish[1] + tbl_offset
  end
  vim.list_extend(rules, special_float_rules)
  local sep_rules = table_fmt.thousands_hl_rules(tbl)
  for _, r in ipairs(sep_rules) do
    r.start[1]  = r.start[1]  + tbl_offset
    r.finish[1] = r.finish[1] + tbl_offset
  end
  vim.list_extend(rules, sep_rules)
  buf_state.buffer:apply_highlight(rules)
end


--- Re-render the results table for `buf_state`, respecting the current page and visible columns.
--- @param buf_state table
render_table = function(buf_state)
  local page_size    = config.options.results.page_size
  local rows_ret     = buf_state.rows_returned or #buf_state.raw_rows
  local rows_tot     = buf_state.rows_total    or rows_ret
  local total_pages  = math.max(1, math.ceil(rows_ret / page_size))
  buf_state.page = math.max(1, math.min(buf_state.page, total_pages))

  local first = (buf_state.page - 1) * page_size + 1
  local last  = math.min(rows_ret, buf_state.page * page_size)

  local col_indices = visible_col_indices(buf_state)

  local display = { buf_state.vis_columns }
  for i = first, last do
    local row = {}
    for _, idx in ipairs(col_indices) do table.insert(row, buf_state.raw_rows[i][idx]) end
    table.insert(display, row)
  end

  local sep = sep_array_for(buf_state.vis_columns, buf_state.sep_columns)
  local tbl = table_fmt.from_structured_data(display, 1, sep, config.options.results.decimal_separator)
  buf_state.table_data = tbl

  local label = rows_label(rows_ret, rows_tot, buf_state.page, page_size)
  if buf_state.duration_ms then
    label = label .. "  ·  " .. format_duration(buf_state.duration_ms)
  end
  local content = { label, "" }
  vim.list_extend(content, tbl.text)
  buf_state.buffer:set_content(content)
  apply_highlights(buf_state, tbl, 0, 2)
  update_truncation_indicators()
end


--- Return the batch header separator line for statement `idx` of `total`.
--- @param idx   integer
--- @param total integer
--- @return string
local function make_separator(idx, total)
  return ("── Query %d / %d "):format(idx, total) .. string.rep("─", 44)
end

--- Return the first 80 characters of `sql` with newlines removed, for use as a
--- batch header preview. When the flattened text is longer than 80 characters,
--- the last character is replaced with "…" to signal truncation.
--- @param sql string
--- @return string
local function preview_text(sql)
  local flat = (sql:gsub("\n", ""))
  if vim.fn.strchars(flat) <= 80 then
    return flat
  end
  return vim.fn.strcharpart(flat, 0, 79) .. "…"
end

--- Return the two-line batch header for statement `idx` of `total`: the separator
--- line followed by a preview of the statement text.
--- @param idx   integer
--- @param total integer
--- @param sql   string
--- @return string[]
local function make_header(idx, total, sql)
  return { make_separator(idx, total), preview_text(sql) }
end

--- Concatenate all batch segments into the results buffer.
--- @param buf_state table
local function render_segments(buf_state)
  local all_lines, all_rules = {}, {}
  for _, seg in ipairs(buf_state.segments) do
    local hdr_lnum = #all_lines
    for _, l in ipairs(seg.header) do table.insert(all_lines, l) end
    local offset = #all_lines
    for _, l in ipairs(seg.lines) do table.insert(all_lines, l) end
    for _, r in ipairs(seg.hl_rules) do
      table.insert(all_rules, {
        higroup = r.higroup,
        start   = { r.start[1] + offset,  r.start[2] },
        finish  = { r.finish[1] + offset, r.finish[2] },
      })
    end
    table.insert(all_rules, { higroup = "GrannosHeaderRow",
      start = { hdr_lnum, 0 }, finish = { hdr_lnum, -1 } })
    table.insert(all_rules, { higroup = "GrannosHelp",
      start = { hdr_lnum + 1, 0 }, finish = { hdr_lnum + 1, -1 } })
    table.insert(all_lines, "")
  end
  buf_state.buffer:set_content(all_lines)
  buf_state.buffer:apply_highlight(all_rules)
  update_truncation_indicators()
  reset_cursor()
end


--- Clear `buf_state`'s busy state, if set.
--- @param buf_state table
local function stop_loading(buf_state)
  buf_state.is_loading = false
end

--- Show a "the plugin is busy" message in the results window, marked with the same
--- icon as the gutter's running mark (see ui/gutter.lua). Covers both phases of
--- running a query — waiting on the server (e.g. "Executing…") and formatting a
--- response already received (e.g. "Processing…") — so callers just vary the text.
--- Distinct from `show_message`, which sets one-shot status text with no busy icon
--- (e.g. error/result messages, or the explorer's unrelated "Loading…").
--- @param msg string
function M.show_loading(msg)
  local buf_state = active_buf_state()
  buf_state.table_data  = nil
  buf_state.is_loading  = true
  ensure_win(buf_state.buffer.buf_id)
  buf_state.buffer:set_content({ ICON_RUNNING .. " " .. msg })
  buf_state.buffer:apply_highlight({
    { higroup = "GrannosQueryRunning", start = { 0, 0 }, finish = { 0, -1 } },
  })
  reset_cursor()
end

--- Store the SQL and filetype on the active buf_state for the "source query" float.
--- @param sql      string
--- @param filetype string
function M.set_query(sql, filetype)
  local buf_state = active_buf_state()
  if buf_state then
    buf_state.query    = sql
    buf_state.query_ft = filetype
  end
end

--- Create (if needed) the results buffer for `src_bufnr` and make it the active source.
--- @param key        string|nil  connection key
--- @param driver_label string|nil
--- @param src_bufnr  integer|nil  source buffer number
function M.set_conn_name(key, driver_label, src_bufnr)
  local display   = key and connections.conn_display_name(key) or nil
  local label     = display and (driver_label and (display .. " (" .. driver_label .. ")") or display)
  local buf_title = (label and (BUFNAME .. " [" .. label .. "]") or BUFNAME)
                    .. src_buf_suffix(src_bufnr)
  local buf_key   = buf_key_for(src_bufnr, key)
  local buf_state        = get_or_create_buf_state(buf_key, buf_title)
  buf_state.conn_key      = key
  buf_state.table_path    = nil
  buf_state.column_cache  = nil
  state.active_src = buf_key
end

--- Record the explore-tree path to the table backing the current results, enabling
--- the column-hover float (`K`) to resolve columns via `explore.describe`.
--- Cleared by `set_conn_name` at the start of every new query context.
--- @param path string[]  explore-tree path to the table (e.g. {"public", "users"})
function M.set_source_table(path)
  local buf_state = active_buf_state()
  if buf_state then
    buf_state.table_path   = path
    buf_state.column_cache = {}
  end
end

--- Prepare the results buffer for a batch of `n` statements.
--- @param n integer
function M.begin_batch(n)
  local buf_state = active_buf_state()
  stop_loading(buf_state)
  ensure_win(buf_state.buffer.buf_id)
  buf_state.table_data = nil
  buf_state.segments   = {}
  buf_state.buffer:set_content({ ("Executing %d quer%s…"):format(n, n == 1 and "y" or "ies") })
  buf_state.buffer:apply_highlight({})
end

--- Build a batch-view segment for one SELECT-type statement, honoring `sep_columns`.
--- Stores the raw inputs alongside the rendered `tbl`/`lines`/`hl_rules` so the segment
--- can be rebuilt later when the user toggles the thousands separator on a column.
--- @param idx           integer
--- @param total         integer
--- @param columns       string[]
--- @param rows          table[]
--- @param rows_returned integer
--- @param rows_total    integer
--- @param duration_ms   number|nil
--- @param sep_columns   table  set of column names with the separator toggled on
--- @param sql           string  the statement text, for the batch header preview
--- @return table  segment
local function build_segment(idx, total, columns, rows, rows_returned, rows_total, duration_ms, sep_columns, sql)
  local page_size = config.options.results.page_size
  local display   = { columns }
  for i = 1, math.min(rows_returned, page_size) do table.insert(display, rows[i]) end
  local sep   = sep_array_for(columns, sep_columns)
  local tbl   = table_fmt.from_structured_data(display, 1, sep, config.options.results.decimal_separator)
  local label = rows_label(rows_returned, rows_total, 1, page_size)
  if duration_ms then label = label .. "  ·  " .. format_duration(duration_ms) end
  local content = { label, "" }
  vim.list_extend(content, tbl.text)
  local rules = table_fmt.col_hl_rules("GrannosHeaderRow", 2, 1, tbl)
  table.insert(rules, { higroup = "GrannosRowCount",
    start = { 0, 0 }, finish = { 0, -1 } })
  for _, r in ipairs(table_fmt.thousands_hl_rules(tbl)) do
    table.insert(rules, {
      higroup = r.higroup,
      start   = { r.start[1]  + 2, r.start[2] },
      finish  = { r.finish[1] + 2, r.finish[2] },
    })
  end
  return {
    header = make_header(idx, total, sql), lines = content, hl_rules = rules, tbl = tbl,
    idx = idx, total = total, columns = columns, rows = rows,
    rows_returned = rows_returned, rows_total = rows_total, duration_ms = duration_ms, sql = sql,
  }
end

--- Rebuild every SELECT-type segment in `buf_state.segments` from its stored raw inputs,
--- picking up the current `buf_state.sep_columns` state. Non-SELECT segments (errors,
--- row-count messages) have no `tbl` and are left untouched.
--- @param buf_state table
local function rebuild_segments(buf_state)
  for i, seg in ipairs(buf_state.segments) do
    if seg.tbl then
      buf_state.segments[i] = build_segment(seg.idx, seg.total, seg.columns, seg.rows,
        seg.rows_returned, seg.rows_total, seg.duration_ms, buf_state.sep_columns, seg.sql)
    end
  end
end

--- Return the batch segment covering 0-indexed buffer line `line0`, or nil.
--- Mirrors the line layout `render_segments` builds: each segment occupies its
--- header line, its content lines, and one trailing blank line.
--- @param buf_state table
--- @param line0 integer  0-indexed buffer line
--- @return table|nil
segment_at_line = function(buf_state, line0)
  local offset = 0
  for _, seg in ipairs(buf_state.segments) do
    local seg_len = #seg.header + #seg.lines + 1
    if line0 < offset + seg_len then return seg end
    offset = offset + seg_len
  end
end

--- Toggle the thousands separator for the column under the cursor, in whichever
--- results view (single-page or batch) is currently showing.
--- @param buf_state table
toggle_thousands_separator = function(buf_state)
  local col_name
  if buf_state.table_data then
    local col_idx = table_fmt.get_column_at_cursor(buf_state.table_data.columns_width, vim.fn.virtcol("."))
    col_name = col_idx and buf_state.vis_columns[col_idx]
  elseif #buf_state.segments > 0 then
    local seg = segment_at_line(buf_state, vim.fn.line(".") - 1)
    if seg and seg.tbl then
      local col_idx = table_fmt.get_column_at_cursor(seg.tbl.columns_width, vim.fn.virtcol("."))
      col_name = col_idx and seg.columns[col_idx]
    end
  end
  if not col_name then return end

  buf_state.sep_columns[col_name] = not buf_state.sep_columns[col_name] or nil

  if buf_state.table_data then
    render_table(buf_state)
  else
    rebuild_segments(buf_state)
    render_segments(buf_state)
  end
end

--- Append the result of one SELECT-type statement to the batch view.
--- @param idx           integer
--- @param total         integer
--- @param columns       string[]
--- @param rows          table[]
--- @param rows_returned integer
--- @param rows_total    integer|nil
--- @param duration_ms   number|nil
--- @param sql           string  the statement text, for the batch header preview
function M.append_batch_result(idx, total, columns, rows, rows_returned, rows_total, duration_ms, sql)
  local buf_state = active_buf_state()
  rows_returned = rows_returned or #rows
  rows_total    = rows_total    or rows_returned
  table.insert(buf_state.segments, build_segment(idx, total, columns, rows, rows_returned, rows_total, duration_ms, buf_state.sep_columns, sql))
  render_segments(buf_state)
end

--- Append an error message from one batch statement.
--- @param idx   integer
--- @param total integer
--- @param msg   string
--- @param sql   string  the statement text, for the batch header preview
function M.append_batch_error(idx, total, msg, sql)
  local buf_state    = active_buf_state()
  local lines = vim.split(msg, "\n", { plain = true })
  lines[1]    = "Error: " .. lines[1]
  table.insert(buf_state.segments, {
    header   = make_header(idx, total, sql),
    lines    = lines,
    hl_rules = { { higroup = "GrannosError", start = { 0, 0 }, finish = { #lines - 1, -1 } } },
    sql      = sql,
  })
  render_segments(buf_state)
end

--- Display the SELECT results, preserving column visibility when columns match the previous query.
--- @param columns       string[]
--- @param rows          table[]
--- @param rows_returned integer
--- @param rows_total    integer|nil
--- @param duration_ms   number|nil
function M.show_results(columns, rows, rows_returned, rows_total, duration_ms)
  local buf_state = active_buf_state()
  stop_loading(buf_state)
  if not buf_state.raw_columns or not same_columns(buf_state.raw_columns, columns) then
    buf_state.vis_columns = vim.list_extend({}, columns)
  end
  buf_state.raw_columns    = columns
  buf_state.raw_rows       = rows
  buf_state.rows_returned  = rows_returned or #rows
  buf_state.rows_total     = rows_total    or buf_state.rows_returned
  buf_state.duration_ms    = duration_ms
  buf_state.page           = 1
  ensure_win(buf_state.buffer.buf_id)
  render_table(buf_state)
  reset_cursor()
end

--- Display a DML row-count message.
--- @param n           integer
--- @param verb        string
--- @param duration_ms number|nil
function M.show_rows_affected(n, verb, duration_ms)
  local buf_state = active_buf_state()
  stop_loading(buf_state)
  buf_state.table_data = nil
  ensure_win(buf_state.buffer.buf_id)
  local msg = rows_affected_msg(n, verb)
  if duration_ms then msg = msg .. "  ·  " .. format_duration(duration_ms) end
  buf_state.buffer:set_content({ msg })
  buf_state.buffer:apply_highlight({
    { higroup = "GrannosRowCount", start = { 0, 0 }, finish = { 0, -1 } },
  })
  reset_cursor()
end

--- Append a DML row-count message to the batch view.
--- @param idx         integer
--- @param total       integer
--- @param n           integer
--- @param verb        string
--- @param duration_ms number|nil
--- @param sql         string  the statement text, for the batch header preview
function M.append_batch_rows_affected(idx, total, n, verb, duration_ms, sql)
  local buf_state = active_buf_state()
  local msg = rows_affected_msg(n, verb)
  if duration_ms then msg = msg .. "  ·  " .. format_duration(duration_ms) end
  table.insert(buf_state.segments, {
    header   = make_header(idx, total, sql),
    lines    = { msg },
    hl_rules = { { higroup = "GrannosRowCount", start = { 0, 0 }, finish = { 0, -1 } } },
    sql      = sql,
  })
  render_segments(buf_state)
end

--- Display an error message in the results window.
--- @param msg string
function M.show_error(msg)
  local buf_state    = active_buf_state()
  stop_loading(buf_state)
  buf_state.table_data = nil
  ensure_win(buf_state.buffer.buf_id)
  local lines = vim.split(msg, "\n", { plain = true })
  lines[1]    = "Error: " .. lines[1]
  buf_state.buffer:set_content(lines)
  buf_state.buffer:apply_highlight({
    { higroup = "GrannosError", start = { 0, 0 }, finish = { #lines - 1, -1 } },
  })
  reset_cursor()
end

--- Display a plain text message in the results window (e.g. "Executing…").
--- @param msg string
function M.show_message(msg)
  local buf_state = active_buf_state()
  stop_loading(buf_state)
  buf_state.table_data = nil
  ensure_win(buf_state.buffer.buf_id)
  buf_state.buffer:set_content({ msg })
  buf_state.buffer:apply_highlight({})
  reset_cursor()
end

--- Return true when `buf_id` is an grannos results buffer.
--- @param buf_id integer
--- @return boolean
function M.is_results_buf(buf_id)
  return vim.startswith(vim.api.nvim_buf_get_name(buf_id), BUFNAME)
end

--- Return the connection key associated with a results buffer, or nil.
--- @param buf_id integer
--- @return string|nil
function M.conn_key_for_buf(buf_id)
  for _, buf_state in pairs(state.buffers) do
    if buf_state.buffer.buf_id == buf_id then return buf_state.conn_key end
  end
end

return M
