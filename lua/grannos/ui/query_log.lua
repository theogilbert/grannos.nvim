-- Query log viewer: four-panel float.
-- Left: search input (top) + filtered list (bottom) — built by detail_pane.open_search_list.
-- Right: SQL preview (top) + results preview (bottom), stitched with shared border.
-- The right stacked-border pair uses the save_query.lua technique: the lower window's
-- top border overlaps the upper window's bottom border row; zindex wins on that row.
local M = {}

local log       = require("grannos.log")
local table_fmt = require("grannos.table")
local hl        = require("grannos.hl")
local config    = require("grannos.config")
local pane      = require("grannos.ui.detail_pane")

--- Return the Neovim filetype string for a given driver name.
--- @param driver string|nil
--- @return string
local function driver_filetype(driver)
  if not driver then return "sql" end
  local d = driver:lower()
  if d == "neo4j" or d:find("cypher") then return "cypher" end
  return "sql"
end

--- Format a millisecond duration as a human-readable seconds string.
--- @param ms number
--- @return string
local function format_duration(ms)
  return ("%.3f"):format(ms / 1000):gsub("0+$", ""):gsub("%.$", "") .. "s"
end

--- Build a single-line summary of a log entry for the list panel.
--- @param entry      table   log entry record
--- @param content_w  integer available character width for the line
--- @return string
local function format_entry_line(entry, content_w)
  local status  = entry.status == "error"   and "✗ "
               or entry.status == "running" and "… "
               or "  "
  -- Entries are kept for a rolling 7-day window, so the year is never ambiguous.
  local time_s  = os.date("%m-%d %H:%M:%S", entry.timestamp)
  local line_s  = ("ln:%-4d"):format((entry.source_line or 0) + 1)
  local prefix  = status .. time_s .. "  " .. line_s .. "  "
  local sql_one = vim.trim(entry.sql:gsub("%s+", " "))
  local sql_w   = math.max(0, content_w - vim.fn.strdisplaywidth(prefix))
  if vim.fn.strdisplaywidth(sql_one) > sql_w and sql_w > 1 then
    sql_one = vim.fn.strcharpart(sql_one, 0, sql_w - 1) .. "…"
  end
  return prefix .. sql_one
end

--- Open the log viewer for `conn_key`.
--- @param conn_key string
--- @param conn     table|nil  { conn_id, driver, key, driver_label } — may be nil if inactive
function M.open(conn_key, conn)
  local entries = log.entries(conn_key)

  -- ── Layout ─────────────────────────────────────────────────────────────────
  -- Right side: sql_win (height=sql_h) stitched above res_win (height=res_h).
  -- Right visual height = 1(top) + sql_h + 1(shared) + res_h + 1(bottom) = sql_h+res_h+3.
  --
  -- Left side: input_win (height=1) stitched above list_win (height=list_h).
  -- Left visual height  = 1(top) + 1(input) + 1(shared) + list_h + 1(bottom) = list_h+4.
  -- For both sides to be the same height: list_h+4 = sql_h+res_h+3 → list_h = sql_h+res_h-1.
  local total_w  = math.min(math.floor(vim.o.columns * 0.92), 200)
  local sql_h    = math.max(3, math.floor(vim.o.lines * 0.30))
  local res_h    = math.max(3, math.floor(vim.o.lines * 0.25))
  local list_h   = math.max(2, sql_h + res_h - 1)
  local vis_h    = sql_h + res_h + 3  -- total visual height of either side

  local left_cw  = math.max(30, math.floor(total_w * 0.35) - 2)
  local left_vw  = left_cw + 2
  local gap      = 2
  local right_cw = math.max(10, total_w - left_vw - gap - 2)

  local start_row = math.max(0, math.floor((vim.o.lines   - vis_h)   / 2))
  local start_col = math.max(0, math.floor((vim.o.columns - total_w) / 2))
  local right_col = start_col + left_vw + gap

  -- ── Buffers ────────────────────────────────────────────────────────────────
  -- SQL preview (read-only, treesitter-highlighted).
  local sql_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[sql_buf].bufhidden  = "wipe"
  vim.bo[sql_buf].modifiable = false
  vim.bo[sql_buf].filetype   = driver_filetype(conn and conn.driver)
  pcall(vim.treesitter.start, sql_buf)

  -- Results preview (read-only).
  local res_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[res_buf].bufhidden  = "wipe"
  vim.bo[res_buf].modifiable = false

  -- ── Windows ────────────────────────────────────────────────────────────────
  -- SQL window (top-right). Bottom border = ├─┤, shared with res_win's top.
  local sql_win = vim.api.nvim_open_win(sql_buf, false, {
    relative  = "editor",
    row       = start_row,
    col       = right_col,
    width     = right_cw,
    height    = sql_h,
    style     = "minimal",
    border    = { "╭", "─", "╮", "│", "┤", "─", "├", "│" },
    title     = " SQL ",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value("number", false, { win = sql_win })
  vim.api.nvim_set_option_value("wrap",   false, { win = sql_win })
  vim.api.nvim_win_set_hl_ns(sql_win, hl.NS_ID)

  -- Results window (bottom-right). Top border overlaps sql_win's bottom border row.
  -- Window at row=R, height=H → bottom border at R+H+1. So res_win row = start_row+sql_h+1.
  local res_win = vim.api.nvim_open_win(res_buf, false, {
    relative  = "editor",
    row       = start_row + sql_h + 1,  -- same screen row as sql_win's bottom border
    col       = right_col,
    width     = right_cw,
    height    = res_h,
    style     = "minimal",
    border    = { "├", "─", "┤", "│", "╯", "─", "╰", "│" },
    title     = " Results ",
    title_pos = "center",
    zindex    = 51,
  })
  vim.api.nvim_set_option_value("number", false, { win = res_win })
  vim.api.nvim_set_option_value("wrap",   false, { win = res_win })
  vim.api.nvim_win_set_hl_ns(res_win, hl.NS_ID)

  --- Write `lines` to `buf`, flattening any embedded newlines.
  --- @param buf   integer
  --- @param lines string[]
  local function set_buf_lines(buf, lines)
    -- nvim_buf_set_lines rejects items that contain \n; flatten them.
    local flat = {}
    for _, l in ipairs(lines) do
      if l:find("\n", 1, true) then
        for _, sub in ipairs(vim.split(l, "\n", { plain = true })) do
          flat[#flat + 1] = sub
        end
      else
        flat[#flat + 1] = l
      end
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, flat)
    vim.bo[buf].modifiable = false
  end

  -- ── Preview (right panels) ─────────────────────────────────────────────────
  --- Update the SQL and results preview panes to reflect `entry`.
  --- @param entry table|nil
  local function update_preview(entry)
    if not entry then
      set_buf_lines(sql_buf, {})
      set_buf_lines(res_buf, {})
      vim.api.nvim_buf_clear_namespace(res_buf, hl.NS_ID, 0, -1)
      return
    end

    set_buf_lines(sql_buf, vim.split(entry.sql, "\n", { plain = true }))

    local res_lines, res_rules = {}, {}

    if entry.status == "running" then
      res_lines = { "Executing…" }

    elseif entry.status == "error" then
      res_lines = { "Error: " .. (entry.error_msg or "unknown error") }
      res_rules = { { higroup = "GrannosError", start = { 0, 0 }, finish = { 0, -1 } } }

    elseif entry.status == "rows_affected" then
      local msg = (entry.rows_affected or 0) .. " row"
          .. ((entry.rows_affected or 0) == 1 and "" or "s")
          .. " " .. (entry.verb or "affected")
      if entry.duration_ms then msg = msg .. "  ·  " .. format_duration(entry.duration_ms) end
      res_lines = { msg }
      res_rules = { { higroup = "GrannosRowCount", start = { 0, 0 }, finish = { 0, -1 } } }

    elseif entry.status == "success" then
      -- Browsing only ever needs a preview; entry.rows is always capped at
      -- log.PREVIEW_ROWS (100), so this never triggers a read of the
      -- (possibly large) spillover file for truncated entries.
      local rows     = entry.rows or {}
      local cols     = entry.columns or {}
      local rows_ret = entry.rows_returned or #rows
      local rows_tot = entry.rows_total    or rows_ret

      local count_msg = rows_ret == rows_tot
          and (rows_ret .. " row" .. (rows_ret == 1 and "" or "s"))
          or  (rows_ret .. " returned  ·  " .. rows_tot .. " matched")
      if entry.duration_ms then count_msg = count_msg .. "  ·  " .. format_duration(entry.duration_ms) end

      res_lines = { count_msg, "" }
      res_rules = { { higroup = "GrannosRowCount", start = { 0, 0 }, finish = { 0, -1 } } }

      if #cols > 0 then
        local display = { cols }
        for i = 1, math.min(#rows, 50) do table.insert(display, rows[i]) end
        local tbl        = table_fmt.from_structured_data(display, 1, config.options.results.thousands_separator, config.options.results.decimal_separator)
        local tbl_offset = 2

        for _, l in ipairs(tbl.text) do table.insert(res_lines, l) end
        for _, r in ipairs(table_fmt.col_hl_rules("GrannosHeaderRow", tbl_offset, 1, tbl)) do
          table.insert(res_rules, r)
        end
        for _, r in ipairs(table_fmt.null_hl_rules(tbl)) do
          table.insert(res_rules, {
            higroup = r.higroup,
            start   = { r.start[1]  + tbl_offset, r.start[2] },
            finish  = { r.finish[1] + tbl_offset, r.finish[2] },
          })
        end
        for _, r in ipairs(table_fmt.thousands_hl_rules(tbl)) do
          table.insert(res_rules, {
            higroup = r.higroup,
            start   = { r.start[1]  + tbl_offset, r.start[2] },
            finish  = { r.finish[1] + tbl_offset, r.finish[2] },
          })
        end
      end
    end

    set_buf_lines(res_buf, res_lines)
    vim.api.nvim_buf_clear_namespace(res_buf, hl.NS_ID, 0, -1)
    for _, rule in ipairs(res_rules) do
      vim.hl.range(res_buf, hl.NS_ID, rule.higroup, rule.start, rule.finish)
    end
  end

  -- ── Search list (left panel) ──────────────────────────────────────────────
  -- Search input + filtered list, plus their lifecycle (close/WinLeave/nav
  -- keymaps), are built by detail_pane; sql_win/res_win join the same group.
  local handle
  handle = pane.open_search_list({
    items       = entries,
    title       = " Query Log ",
    row0        = start_row, col0 = start_col, width = left_cw, list_height = list_h,
    get_label   = function(e) return format_entry_line(e, left_cw) end,
    matches     = function(e, text)
      local ok, m = pcall(vim.fn.match, e.sql, "\\c" .. text)
      return ok and m >= 0
    end,
    get_row_hl  = function(e)
      if e.status == "error"   then return "GrannosConnError" end
      if e.status == "running" then return "GrannosHelp" end
    end,
    empty_msg   = function(text)
      return text == "" and "(no queries executed yet)" or "(no matches)"
    end,
    on_change   = update_preview,

    -- <CR> in the search box: open the currently selected list entry.
    on_submit   = function(entry)
      if not entry then return end

      handle.close()

      -- Resolve source buffer: valid in-session bufnr takes priority; fall back to
      -- source_file for entries loaded from a previous session.
      local target_buf
      if entry.bufnr and vim.api.nvim_buf_is_valid(entry.bufnr) then
        target_buf = entry.bufnr
      elseif entry.source_file and entry.source_file ~= "" then
        local bn = vim.fn.bufnr(entry.source_file)
        if bn > 0 then
          target_buf = bn
        else
          vim.cmd("edit " .. vim.fn.fnameescape(entry.source_file))
          if entry.source_line then
            pcall(vim.api.nvim_win_set_cursor, 0, { entry.source_line + 1, 0 })
          end
        end
      end
      if target_buf then
        local buf_wins = vim.tbl_filter(function(w)
          return vim.api.nvim_win_is_valid(w)
              and vim.api.nvim_win_get_config(w).relative == ""
        end, vim.fn.win_findbuf(target_buf))
        if #buf_wins > 0 then
          vim.api.nvim_set_current_win(buf_wins[1])
        else
          vim.api.nvim_set_current_buf(target_buf)
        end
        if entry.source_line then
          vim.api.nvim_win_set_cursor(0, { entry.source_line + 1, 0 })
        end
      end

      local results_ui = require("grannos.ui.results")
      results_ui.set_conn_name(conn_key, conn and conn.driver_label, entry.bufnr)
      if entry.status == "success" then
        -- Opening an entry (as opposed to browsing it) needs the full result
        -- set; this lazily reads the spillover file for truncated entries.
        local rows = log.load_rows(entry)
        results_ui.show_results(
          entry.columns or {}, rows, entry.rows_returned, entry.rows_total, entry.duration_ms)
      elseif entry.status == "rows_affected" then
        results_ui.show_rows_affected(entry.rows_affected, entry.verb or "affected", entry.duration_ms)
      elseif entry.status == "error" then
        results_ui.show_error(entry.error_msg or "unknown error")
      end
    end,
  })

  handle.register_win(sql_win)
  handle.register_win(res_win)
end

return M
