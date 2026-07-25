-- Shared infrastructure for two-pane and single-item detail floats.
-- Consumers supply item-specific rendering; this module handles all window
-- management, sizing, keymaps, and autocmds.
local M = {}

local hl         = require("grannos.hl")
local Buffer     = require("grannos.buffer")

--- Positional highlight entry: { group, 0-indexed-row, byte-col-start, byte-col-end }.
--- Used in the `hls` accumulator arrays passed between section/tag_line/apply.
--- @class DetailHlRule
--- @field [1] string   highlight group name
--- @field [2] integer  0-indexed buffer row
--- @field [3] integer  byte start column
--- @field [4] integer  byte end column  (-1 = end of line)

--- Per-segment highlight spec returned by tag_line: { group, col_start, col_end }.
--- @class TagSpec
--- @field [1] string   highlight group name
--- @field [2] integer  byte start column within the tag line
--- @field [3] integer  byte end column within the tag line

local SEP        = string.rep("─", 48)
local TAG_SEP    = "  ·  "
local TAG_PREFIX = "  "
local NS         = vim.api.nvim_create_namespace("GrannosDetailPane")

--- True when v is nil or vim.NIL (JSON null decoded by Neovim).
--- @param v any
--- @return boolean
function M.is_nil(v) return v == nil or v == vim.NIL end

--- Default word-wrap width for free-text (comments) shown in a detail float,
--- so a long single-line database comment doesn't force the window as wide
--- as the text itself.
M.COMMENT_WRAP_WIDTH = 78

--- Word-wrap `text` to `width` display columns, preserving existing line
--- breaks (e.g. a comment stored as multiple paragraphs).
--- @param text  string
--- @param width integer  max display width per wrapped line
--- @return string[]
function M.wrap_lines(text, width)
  local out = {}
  for _, para in ipairs(vim.split(tostring(text), "\n", { plain = true })) do
    para = para:gsub("\r$", "")
    if para == "" then
      out[#out + 1] = ""
    else
      local line = ""
      for word in para:gmatch("%S+") do
        local candidate = line == "" and word or (line .. " " .. word)
        if line ~= "" and vim.fn.strdisplaywidth(candidate) > width then
          out[#out + 1] = line
          line = word
        else
          line = candidate
        end
      end
      out[#out + 1] = line
    end
  end
  return out
end

--- Append a bold section header + horizontal separator to the line/highlight accumulators.
--- @param lines table  mutable string array being built
--- @param hls   DetailHlRule[]  mutable highlight-rule array being built
--- @param title string
function M.section(lines, hls, title)
  local row = #lines
  lines[#lines + 1] = "  " .. title
  hls[#hls + 1] = { "GrannosHeaderRow", row, 2, 2 + #title }
  row = #lines
  lines[#lines + 1] = "  " .. SEP
  hls[#hls + 1] = { "GrannosBorder", row, 2, 2 + #SEP }
end

--- Build a "tag summary" line with per-segment highlight specs.
--- @param tagged table  list of {text, hl_group} pairs (hl_group nil/false = no highlight)
--- @return string line, TagSpec[] specs
function M.tag_line(tagged)
  local texts = {}
  for _, t in ipairs(tagged) do texts[#texts + 1] = t[1] end
  local line  = TAG_PREFIX .. table.concat(texts, TAG_SEP)
  local specs = {}
  local pos   = #TAG_PREFIX
  for i, t in ipairs(tagged) do
    if t[2] then
      specs[#specs + 1] = { t[2], pos, pos + #t[1] }
    end
    pos = pos + #t[1] + (i < #tagged and #TAG_SEP or 0)
  end
  return line, specs
end

--- Write lines + highlights into buf (replaces all existing content).
--- @param buf   integer
--- @param lines string[]
--- @param hls   DetailHlRule[]
function M.apply(buf, lines, hls)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(buf, NS, h[1], h[2], h[3], h[4])
  end
end

local SEARCH_PROMPT     = "/ "
local SEARCH_PROMPT_LEN = #SEARCH_PROMPT
local SCROLLBAR_NS      = vim.api.nvim_create_namespace("GrannosScrollbar")

--- Draw a proportional scrollbar thumb along the right edge of `win`, as virtual
--- text anchored to the buffer lines it currently overlaps. A no-op (and clears
--- any previous thumb) when all of `buf` already fits within the window.
--- @param win        integer
--- @param buf        integer
--- @param win_height integer
local function draw_scrollbar(win, buf, win_height)
  vim.api.nvim_buf_clear_namespace(buf, SCROLLBAR_NS, 0, -1)
  local total_lines = vim.api.nvim_buf_line_count(buf)
  if total_lines <= win_height or not vim.api.nvim_win_is_valid(win) then return end

  local info    = vim.fn.getwininfo(win)[1]
  local topline = info and info.topline or 1

  local thumb_size   = math.max(1, math.min(win_height, math.floor(win_height * win_height / total_lines + 0.5)))
  local max_offset   = win_height - thumb_size
  local scroll_range = total_lines - win_height
  local thumb_offset = scroll_range > 0
    and math.floor((topline - 1) / scroll_range * max_offset + 0.5)
    or 0
  thumb_offset = math.max(0, math.min(max_offset, thumb_offset))

  for i = 0, thumb_size - 1 do
    local line = topline - 1 + thumb_offset + i  -- 0-indexed buffer line
    if line >= 0 and line < total_lines then
      vim.api.nvim_buf_set_extmark(buf, SCROLLBAR_NS, line, 0, {
        virt_text      = { { "▐", "GrannosScrollbarThumb" } },
        virt_text_pos  = "right_align",
        hl_mode        = "combine",
      })
    end
  end
end

--- Build the search-input + filtered-list left pane shared by browsing floats: a
--- one-line search box stitched above a scrollable, cursorline-highlighted list.
--- The caller supplies the item set and is notified whenever the selected item
--- changes (cursor move or re-filter); it owns and positions any other windows
--- belonging to the same float (e.g. a detail pane) and registers them via
--- `register_win` so they share this pane's close/WinLeave lifecycle.
---
--- @param opts table
---   .items       array                     items to browse (must be non-empty)
---   .title       string                    left window title (with surrounding spaces)
---   .row0        integer                   screen row for the top of the input window
---   .col0        integer                   screen col for the left edge
---   .width       integer                   content width of the left pane
---   .list_height integer                   height of the list window
---   .get_label   fn(item)→string           label shown for each row
---   .matches     fn(item, text)→boolean|nil   filter predicate; text is trimmed and
---                non-empty. Defaults to a case-insensitive substring match on get_label.
---   .get_row_hl  fn(item)→string|nil|nil   optional highlight group applied to a row
---   .empty_msg   fn(text)→string|nil       message shown when filtering yields no rows
---                (default: "(no matches)")
---   .on_change   fn(item|nil)              called with the newly-selected item
---   .on_submit   fn(item|nil)|nil          called when <CR> is pressed in the search box
---   .extra_help  { lhs: string, desc: string, group: string }[]|nil   additional entries
---                shown by <C-h>'s help float, for keymaps a caller adds on its own windows
--- @return table  { input_win, list_win, close = fun(), register_win = fun(winid), show_help = fun() }
function M.open_search_list(opts)
  local items       = opts.items
  local matches     = opts.matches or function(item, text)
    local ok, m = pcall(vim.fn.match, opts.get_label(item), "\\c" .. text)
    return ok and m >= 0
  end
  local empty_msg = opts.empty_msg or function() return "(no matches)" end

  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].bufhidden = "wipe"
  vim.bo[input_buf].complete  = ""   -- disable completion so <C-n>/<C-p> don't open a popup
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { SEARCH_PROMPT })

  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[list_buf].bufhidden  = "wipe"
  vim.bo[list_buf].modifiable = false

  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative  = "editor",
    row       = opts.row0, col = opts.col0,
    width     = opts.width, height = 1,
    style     = "minimal",
    border    = { "╭", "─", "╮", "│", "┤", "─", "├", "│" },
    title     = opts.title, title_pos = "center",
  })
  vim.api.nvim_set_option_value("number", false, { win = input_win })
  vim.api.nvim_set_option_value("wrap",   false, { win = input_win })
  vim.api.nvim_win_set_hl_ns(input_win, hl.NS_ID)

  local list_win = vim.api.nvim_open_win(list_buf, false, {
    relative  = "editor",
    row       = opts.row0 + 2,  -- same screen row as input_win's bottom border
    col       = opts.col0,
    width     = opts.width, height = opts.list_height,
    style     = "minimal",
    border    = { "├", "─", "┤", "│", "╯", "─", "╰", "│" },
    zindex    = 51,
  })
  vim.api.nvim_set_option_value("cursorline", true,  { win = list_win })
  vim.api.nvim_set_option_value("number",     false, { win = list_win })
  vim.api.nvim_set_option_value("wrap",       false, { win = list_win })
  vim.api.nvim_win_set_hl_ns(list_win, hl.NS_ID)

  local all_wins     = { input_win, list_win }
  local all_wins_set = { [input_win] = true, [list_win] = true }
  local closed       = false
  local aug = vim.api.nvim_create_augroup("GrannosSearchList_" .. list_buf, { clear = true })

  --- Close every window registered with this pane.
  local function close()
    if closed then return end
    closed = true
    vim.schedule(function() pcall(vim.api.nvim_del_augroup_by_id, aug) end)
    for _, w in ipairs(all_wins) do
      if vim.api.nvim_win_is_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
    end
  end

  --- Register another float window (e.g. a detail pane) as part of this group:
  --- closing it closes the whole group, and it won't trigger the leave-to-close check.
  --- @param winid integer
  local function register_win(winid)
    all_wins[#all_wins + 1] = winid
    all_wins_set[winid]     = true
    vim.api.nvim_create_autocmd("WinClosed", {
      group = aug, pattern = tostring(winid), once = true,
      callback = function() close() end,
    })
  end

  --- Register a transient window (e.g. the <C-h> help float) as temporarily
  --- "inside" the group for the leave-to-close check, without its own closing
  --- cascading into closing the group. Un-registered automatically once it
  --- closes. Needed because opening it can race the leave-to-close check
  --- scheduled by whatever window switch preceded it (see WinLeave below):
  --- without this, that deferred check can fire after focus has already
  --- landed on the (unregistered) transient window and wrongly conclude the
  --- float was left entirely.
  --- @param winid integer
  local function register_transient_win(winid)
    all_wins_set[winid] = true
    vim.api.nvim_create_autocmd("WinClosed", {
      group = aug, pattern = tostring(winid), once = true,
      callback = function() all_wins_set[winid] = nil end,
    })
  end

  for _, w in ipairs(all_wins) do
    vim.api.nvim_create_autocmd("WinClosed", {
      group = aug, pattern = tostring(w), once = true,
      callback = function() close() end,
    })
  end

  local line_map = {}  -- [1-indexed row] → item; reassigned by update_list

  --- Repopulate the list, applying `filter_text` as a filter, and notify on_change.
  --- @param filter_text string
  local function update_list(filter_text)
    local filtered = {}
    if filter_text == "" then
      filtered = items
    else
      for _, item in ipairs(items) do
        if matches(item, filter_text) then table.insert(filtered, item) end
      end
    end

    line_map = {}
    local list_lines, list_rules = {}, {}

    if #filtered == 0 then
      list_lines = { empty_msg(filter_text) }
    else
      for i, item in ipairs(filtered) do
        list_lines[i] = "  " .. opts.get_label(item)
        line_map[i]   = item
        local g = opts.get_row_hl and opts.get_row_hl(item)
        if g then
          table.insert(list_rules, { higroup = g, start = { i - 1, 0 }, finish = { i - 1, -1 } })
        end
      end
    end

    vim.bo[list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, list_lines)
    vim.bo[list_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(list_buf, hl.NS_ID, 0, -1)
    for _, rule in ipairs(list_rules) do
      vim.hl.range(list_buf, hl.NS_ID, rule.higroup, rule.start, rule.finish)
    end

    if vim.api.nvim_win_is_valid(list_win) then
      local line_count = math.max(1, vim.api.nvim_buf_line_count(list_buf))
      local ok, cur     = pcall(vim.api.nvim_win_get_cursor, list_win)
      local row         = ok and math.min(cur[1], line_count) or 1
      pcall(vim.api.nvim_win_set_cursor, list_win, { row, 0 })
      draw_scrollbar(list_win, list_buf, opts.list_height)
      opts.on_change(line_map[row])
    end
  end

  update_list("")

  -- Keep cursor inside the search prompt in the input window.
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group    = aug,
    buffer   = input_buf,
    callback = function()
      local col = vim.api.nvim_win_get_cursor(0)[2]
      if col < SEARCH_PROMPT_LEN then
        vim.api.nvim_win_set_cursor(0, { 1, SEARCH_PROMPT_LEN })
      end
    end,
  })

  -- Re-filter the list whenever the search text changes.
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    group    = aug,
    buffer   = input_buf,
    callback = function()
      local line = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
      update_list(vim.trim(line:sub(SEARCH_PROMPT_LEN + 1)))
    end,
  })

  -- Notify on_change when the list cursor moves.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group    = aug,
    buffer   = list_buf,
    callback = function()
      if not vim.api.nvim_win_is_valid(list_win) then return end
      local row = vim.api.nvim_win_get_cursor(list_win)[1]
      draw_scrollbar(list_win, list_buf, opts.list_height)
      opts.on_change(line_map[row])
    end,
  })

  -- Catch-all for scrolling that doesn't move the cursor (e.g. mouse wheel,
  -- <C-e>/<C-y> while focused directly on the list).
  vim.api.nvim_create_autocmd("WinScrolled", {
    group    = aug,
    pattern  = tostring(list_win),
    callback = function() draw_scrollbar(list_win, list_buf, opts.list_height) end,
  })

  -- Close when focus leaves the float entirely (e.g. <C-w>l).
  -- WinLeave fires before the new window is entered, so schedule the check.
  for _, buf in ipairs({ input_buf, list_buf }) do
    vim.api.nvim_create_autocmd("WinLeave", {
      group    = aug,
      buffer   = buf,
      callback = function()
        vim.schedule(function()
          if closed then return end
          if not all_wins_set[vim.api.nvim_get_current_win()] then close() end
        end)
      end,
    })
  end

  --- Move the list cursor by `delta` rows from the input window.
  --- @param delta integer
  local function list_move(delta)
    if not vim.api.nvim_win_is_valid(list_win) then return end
    local count = math.max(1, vim.api.nvim_buf_line_count(list_buf))
    local row   = vim.api.nvim_win_get_cursor(list_win)[1]
    local new   = math.max(1, math.min(count, row + delta))
    if new ~= row then
      vim.api.nvim_win_set_cursor(list_win, { new, 0 })
      draw_scrollbar(list_win, list_buf, opts.list_height)
      opts.on_change(line_map[new])
    end
  end

  --- Register <Down>/<C-n> and <Up>/<C-p> keymaps on the input buffer.
  local function register_nav_keymaps()
    if not vim.api.nvim_buf_is_valid(input_buf) then return end
    for _, key in ipairs({ "<Down>", "<C-n>" }) do
      vim.keymap.set({ "i", "n" }, key, function() list_move(1)  end,
        { buffer = input_buf, nowait = true, silent = true })
    end
    for _, key in ipairs({ "<Up>", "<C-p>" }) do
      vim.keymap.set({ "i", "n" }, key, function() list_move(-1) end,
        { buffer = input_buf, nowait = true, silent = true })
    end
  end

  -- Register now (overrides BufEnter-based plugins like nvim-cmp).
  register_nav_keymaps()

  -- Re-register after InsertEnter so any InsertEnter-based plugin that sets
  -- buffer-local <C-n>/<C-p> keymaps gets overridden. vim.schedule defers
  -- until all InsertEnter handlers have completed.
  vim.api.nvim_create_autocmd("InsertEnter", {
    group    = aug,
    buffer   = input_buf,
    once     = true,
    callback = function() vim.schedule(register_nav_keymaps) end,
  })

  -- Block <BS> from eating the "/ " prompt.
  vim.keymap.set("i", "<BS>", function()
    if vim.api.nvim_win_get_cursor(0)[2] <= SEARCH_PROMPT_LEN then return end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<BS>", true, false, true), "n", false)
  end, { buffer = input_buf, nowait = true })

  -- <CR> in input: hand the selected item to on_submit, if the caller wants one.
  vim.keymap.set({ "i", "n" }, "<CR>", function()
    if not opts.on_submit or not vim.api.nvim_win_is_valid(list_win) then return end
    vim.cmd("stopinsert")  -- leave insert mode before on_submit may switch windows/buffers
    local row = vim.api.nvim_win_get_cursor(list_win)[1]
    opts.on_submit(line_map[row])
  end, { buffer = input_buf, nowait = true, silent = true })

  -- <Esc> in input: if filter is non-empty, clear it; otherwise close.
  -- Insert mode: no `nowait` so that terminal arrow-key sequences (e.g. \x1b[A for
  -- <Up> over SSH) are not immediately consumed by the \x1b prefix before the rest
  -- of the sequence arrives. Normal mode: nowait is safe.
  --- Clear the search text on first press; close the viewer on second press.
  local function esc_action()
    vim.cmd("stopinsert")  -- always leave insert mode; keymap suppresses the default <Esc> behaviour
    local line = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
    local text = vim.trim(line:sub(SEARCH_PROMPT_LEN + 1))
    if text ~= "" then
      vim.api.nvim_buf_set_lines(input_buf, 0, 1, false, { SEARCH_PROMPT })
      vim.api.nvim_win_set_cursor(input_win, { 1, SEARCH_PROMPT_LEN })
      update_list("")
    else
      close()
    end
  end
  vim.keymap.set("i", "<Esc>", esc_action, { buffer = input_buf, silent = true })
  vim.keymap.set("n", "<Esc>", esc_action, { buffer = input_buf, nowait = true, silent = true })

  -- <C-c> in input: close immediately, regardless of filter state (unlike <Esc>,
  -- which clears the filter first).
  local function cancel_action()
    vim.cmd("stopinsert")
    close()
  end
  vim.keymap.set({ "i", "n" }, "<C-c>", cancel_action, { buffer = input_buf, nowait = true, silent = true })

  -- Fallback close if the user somehow focuses the list (e.g. mouse click).
  vim.keymap.set("n", "q",     close, { buffer = list_buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = list_buf, nowait = true, silent = true })
  vim.keymap.set("n", "<C-c>", close, { buffer = list_buf, nowait = true, silent = true })

  -- <C-h>: show a help float listing every keymap active in this browsing float.
  local help_keymaps = {
    { lhs = "<Down>/<C-n>", desc = "Next item",     group = "Navigate" },
    { lhs = "<Up>/<C-p>",   desc = "Previous item", group = "Navigate" },
  }
  if opts.on_submit then
    table.insert(help_keymaps, { lhs = "<CR>", desc = "Select", group = "Navigate" })
  end
  vim.list_extend(help_keymaps, opts.extra_help or {})
  vim.list_extend(help_keymaps, {
    { lhs = "<Esc>", desc = "Clear filter, then close", group = "" },
    { lhs = "<C-c>", desc = "Close",                    group = "" },
    { lhs = "q",     desc = "Close (from the list)",    group = "" },
    { lhs = "<C-h>", desc = "Show this help",           group = "" },
  })

  --- Open the help float and, if it opened, register it as a transient member
  --- of this group (see register_transient_win for why that matters).
  local function show_help()
    local win = Buffer.render_help_float(help_keymaps)
    if win then register_transient_win(win) end
  end
  vim.keymap.set({ "i", "n" }, "<C-h>", show_help, { buffer = input_buf, nowait = true, silent = true })
  vim.keymap.set("n", "<C-h>", show_help, { buffer = list_buf, nowait = true, silent = true })

  -- Start in search mode.
  vim.schedule(function() vim.cmd("startinsert!") end)

  return {
    input_win    = input_win,
    list_win     = list_win,
    close        = close,
    register_win = register_win,
    show_help    = show_help,
  }
end

--- Open a two-pane browsing float with a search box filtering the left-hand list.
--- Left: search input + filtered list (see open_search_list). Right: detail view
--- that updates to match the selected item. q/<Esc>/<C-c> closes from either pane;
--- <Tab> switches focus back and forth between the search box and the detail
--- pane; <C-h> anywhere opens a help float listing every keymap (the detail
--- pane's footer hints at this).
---
--- @param opts table
---   .items      array             items to browse (must be non-empty)
---   .left_title string            left window title (with surrounding spaces)
---   .get_label  fn(item)→string   label shown for each row in the left pane
---   .matches    fn(item, text)→boolean|nil   optional filter predicate (see open_search_list)
---   .get_title  fn(item)→string   right window title for the focused item (no surrounding spaces)
---   .render     fn(buf, item)     populate the right buffer for the focused item
---   .estimate   fn(item)→number   estimated rendered line count (for window sizing)
function M.open_searchable_two_pane(opts)
  local items = opts.items
  if #items == 0 then
    vim.notify("grannos: nothing to display", vim.log.levels.WARN)
    return
  end

  local ew      = vim.o.columns
  local eh      = vim.o.lines
  local left_w  = math.min(36, math.max(24, math.floor(ew * 0.22)))
  local right_w = math.min(math.floor(ew * 0.60), 110)
  local max_h   = math.max(math.floor(eh * 0.72), 8)
  local list_h  = math.min(math.max(#items + 2, 8), max_h)
  local max_content = 8
  for _, item in ipairs(items) do
    max_content = math.max(max_content, opts.estimate(item))
  end
  local right_h = math.min(max_content, max_h)
  local total   = left_w + 2 + 1 + right_w + 2
  local col0    = math.max(0, math.floor((ew - total) / 2))
  -- Left visual height = search box(1) + stitched list(list_h) + 4 border rows.
  -- Right visual height = right_h + 2 border rows. Center on whichever is taller
  -- so neither side overflows past the bottom of the screen.
  local vis_h   = math.max(list_h + 4, right_h + 2)
  local row0    = math.max(0, math.floor((eh - vis_h) / 2))

  local rbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[rbuf].bufhidden  = "wipe"
  vim.bo[rbuf].modifiable = false

  local rwin = vim.api.nvim_open_win(rbuf, false, {
    relative   = "editor",
    row        = row0, col = col0 + left_w + 3,
    width      = right_w, height = right_h,
    style      = "minimal", border = "rounded",
    footer     = " Press <C-h> for help ",
    footer_pos = "right",
  })
  vim.api.nvim_win_set_hl_ns(rwin, hl.NS_ID)
  vim.api.nvim_set_option_value("wrap", false, { win = rwin })

  --- Sync the right pane to reflect the currently-selected item.
  --- @param item any|nil
  local function sync(item)
    if not item then return end
    pcall(vim.api.nvim_win_set_config, rwin, {
      title     = " " .. opts.get_title(item) .. " ",
      title_pos = "center",
    })
    opts.render(rbuf, item)
    pcall(vim.api.nvim_win_set_cursor, rwin, { 1, 0 })
  end

  local handle = M.open_search_list({
    items       = items,
    title       = opts.left_title,
    row0        = row0, col0 = col0, width = left_w, list_height = list_h,
    get_label   = opts.get_label,
    matches     = opts.matches,
    on_change   = sync,
    extra_help  = {
      { lhs = "<Tab>", desc = "Switch between list and detail pane", group = "Navigate" },
    },
  })
  handle.register_win(rwin)

  --- Focus the search box, ready to type.
  local function focus_input()
    if not vim.api.nvim_win_is_valid(handle.input_win) then return end
    vim.api.nvim_set_current_win(handle.input_win)
    vim.cmd("startinsert!")
  end

  --- Focus the right (detail) pane. Leaves insert mode first: this may be
  --- called while still typing in the search box, and the detail buffer is
  --- read-only, so staying in insert mode would make the next keystroke try
  --- (and fail) to edit it instead of triggering a keymap.
  local function focus_right()
    if not vim.api.nvim_win_is_valid(rwin) then return end
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(rwin)
  end

  -- <Tab> in the search box jumps to the detail pane, mirroring <Tab> jumping
  -- back below. Re-registered after InsertEnter so InsertEnter-based
  -- completion/snippet plugins that also bind <Tab> don't win the race.
  local input_buf = vim.api.nvim_win_get_buf(handle.input_win)
  local function register_focus_right_keymap()
    if not vim.api.nvim_buf_is_valid(input_buf) then return end
    vim.keymap.set({ "i", "n" }, "<Tab>", focus_right, { buffer = input_buf, nowait = true, silent = true })
  end
  register_focus_right_keymap()
  vim.api.nvim_create_autocmd("InsertEnter", {
    buffer   = input_buf,
    once     = true,
    callback = function() vim.schedule(register_focus_right_keymap) end,
  })

  --- @param key string
  --- @param fn  fun()
  local function rmap(key, fn) vim.keymap.set("n", key, fn, { buffer = rbuf, nowait = true, silent = true }) end
  rmap("q",     handle.close)
  rmap("<Esc>", handle.close)
  rmap("<C-c>", handle.close)
  rmap("<Tab>", focus_input)
  rmap("<C-h>", handle.show_help)
end

--- Open a single-item detail float.
---
--- @param opts table
---   .item     any              item to display
---   .title    string           window title (no surrounding spaces — they are added here)
---   .render   fn(buf, item)    populate the buffer
---   .estimate fn(item)→number  estimated line count for window height
function M.open_single(opts)
  local ew     = vim.o.columns
  local eh     = vim.o.lines
  local width  = math.min(math.floor(ew * 0.60), 110)
  local max_h  = math.max(math.floor(eh * 0.72), 8)
  local height = math.min(math.max(opts.estimate(opts.item), 8), max_h)
  local col0   = math.max(0, math.floor((ew - width  - 2) / 2))
  local row0   = math.max(0, math.floor((eh - height - 2) / 2))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false

  opts.render(buf, opts.item)

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = row0, col = col0,
    width     = width, height = height,
    style     = "minimal", border = "rounded",
    title     = " " .. opts.title .. " ",
    title_pos = "center",
  })
  vim.api.nvim_win_set_hl_ns(win, hl.NS_ID)
  vim.api.nvim_set_option_value("wrap", false, { win = win })

  --- Close the single-item float.
  local function close() pcall(vim.api.nvim_win_close, win, true) end

  local aug = vim.api.nvim_create_augroup("GrannosDetailPane_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug, pattern = tostring(win), once = true,
    callback = function() vim.api.nvim_del_augroup_by_id(aug) end,
  })
  vim.keymap.set("n", "q",     close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, silent = true })
end

return M
