-- Floating two-panel column picker.
--
-- Left panel:  available (unselected) columns.
-- Right panel: selected columns (in display order).
-- j/k navigate within the focused panel; h/l switch panels.
-- Tab/Enter/Space move the item under the cursor to the other panel — or,
--     when items in the focused panel are marked or a range is active, every
--     one of those at once.
-- m   mark/unmark the item under the cursor and step down, so a run of `m`
--     picks out a scattered set; M clears every mark.
-- v/V start a range at the cursor, extended by j/k, dropped by v again or Esc.
-- K/J (right panel only) move the item under the cursor up/down.
-- >   move all available columns to selected (only the matches, when filtering).
-- <   move all selected columns back to available.
-- /   filter the available panel: type to narrow it (fuzzy). While typing,
--     Down/Up move among the matches and Tab picks the highlighted one and
--     clears the filter, ready for the next name. Enter keeps the filter and
--     goes back to picking, Esc clears it. While a filter is on, Esc in the
--     picker clears it rather than closing.
-- u   undo the last change; Ctrl-R redo. Every change is applied live via the
--     on_change callback, so an accidental < or > has already reached the
--     table (and the saved selection) — undo is what takes it back.
-- r   reset selection to its state when the picker was opened.
-- q/Esc close.
local hl        = require("grannos.hl")
local table_fmt = require("grannos.table")

local M = {}

local ns_id   = vim.api.nvim_create_namespace("grannos_col_picker")
local SEP     = "│"
local SEP_LEN = #SEP  -- 3 bytes for the UTF-8 box-drawing character

--- Right-pad `s` with spaces so its display width equals `width`.
--- @param s     string
--- @param width integer
--- @return string
local function pad(s, width)
  return s .. string.rep(" ", math.max(0, width - vim.api.nvim_strwidth(s)))
end

-- One picker at a time.
local p = {}

--- Most undo steps kept; older ones are dropped.
local HISTORY_MAX = 100

--- The available columns the left panel shows: all of them, or those the
--- filter matches, best match first.
--- @return string[]
local function shown_available()
  if not p.filter or p.filter == "" then return p.available end
  return vim.fn.matchfuzzy(p.available, p.filter)
end

--- The list the focused panel shows.
--- @return string[]
local function focused_list()
  return p.side == "left" and shown_available() or p.selected
end

--- Whether item `i` of the focused panel is inside the active range.
--- @param i integer
--- @return boolean
local function in_range(i)
  if not p.anchor then return false end
  return i >= math.min(p.anchor, p.cursor) and i <= math.max(p.anchor, p.cursor)
end

--- The number of marked columns.
--- @return integer
local function mark_count()
  local n = 0
  for _ in pairs(p.marks) do n = n + 1 end
  return n
end

--- The columns a toggle acts on, in panel order: the active range, else the
--- marked items of the focused panel, else the item under the cursor alone.
--- @return string[]
local function targets()
  local list = focused_list()
  local out = {}
  for i, col in ipairs(list) do
    if in_range(i) or (not p.anchor and p.marks[col]) then out[#out + 1] = col end
  end
  if #out == 0 and list[p.cursor] then out[1] = list[p.cursor] end
  return out
end

--- The window title: the picker's name, plus the filter being typed or in
--- force. The title rather than a buffer line, so it stays in view however
--- far a long column list scrolls.
--- @return string
local function title()
  if p.filter_editing then return (" Columns  /%s▏ "):format(p.filter or "") end
  local marked = mark_count()
  local suffix = marked > 0 and ("  %d marked "):format(marked) or " "
  if p.filter and p.filter ~= "" then
    return (" Columns  /%s  %d of %d%s"):format(p.filter, #shown_available(), #p.available, suffix)
  end
  return " Columns" .. suffix
end

--- Redraw the picker buffer from the current picker state.
local function render()
  if not p.buf or not vim.api.nvim_buf_is_valid(p.buf) then return end

  local cw    = p.col_width
  local lines = {}

  -- Header
  table.insert(lines, pad("  Available columns", cw) .. SEP .. pad("  Selected columns", cw))
  -- Separator row
  table.insert(lines, string.rep("─", cw) .. "┼" .. string.rep("─", cw))

  -- Item rows — pad both sides so every line is exactly cw+SEP_LEN+cw bytes.
  -- At least enough rows to fill the window, so the divider runs to its
  -- bottom edge when a filter or a lopsided split leaves a panel short.
  -- A marked item, or one inside the active range, carries a bullet.
  local available = shown_available()
  local n = math.max(#available, #p.selected, 1, (p.height or 2) - 2)
  local picked = {}  -- { [lnum] = { left = bool, right = bool } }
  for i = 1, n do
    local lcol, rcol = available[i], p.selected[i]
    local lpick = lcol and (p.marks[lcol] or (p.side == "left" and in_range(i))) or false
    local rpick = rcol and (p.marks[rcol] or (p.side == "right" and in_range(i))) or false
    local ltext = lcol and ((lpick and "• " or "  ") .. lcol) or ""
    local rtext = rcol and ((rpick and "• " or "  ") .. rcol) or ""
    table.insert(lines, pad(ltext, cw) .. SEP .. pad(rtext, cw))
    picked[i + 1] = { left = lpick, right = rpick }
  end
  vim.api.nvim_buf_set_lines(p.buf, 0, -1, false, lines)

  vim.api.nvim_buf_clear_namespace(p.buf, ns_id, 0, -1)

  -- Header text
  vim.api.nvim_buf_set_extmark(p.buf, ns_id, 0, 0,
    { end_col = cw, hl_group = "GrannosHeaderRow" })
  vim.api.nvim_buf_set_extmark(p.buf, ns_id, 0, cw + SEP_LEN,
    { end_col = cw + SEP_LEN + cw, hl_group = "GrannosHeaderRow" })

  -- Marked and ranged rows (0-indexed: header=0, sep-row=1, items start at 2)
  for lnum, pick in pairs(picked) do
    if pick.left then
      vim.api.nvim_buf_set_extmark(p.buf, ns_id, lnum, 0,
        { end_col = cw, hl_group = "Visual", priority = 50 })
    end
    if pick.right then
      vim.api.nvim_buf_set_extmark(p.buf, ns_id, lnum, cw + SEP_LEN,
        { end_col = cw + SEP_LEN + cw, hl_group = "Visual", priority = 50 })
    end
  end

  -- Cursor highlight, above any mark
  local item_lnum = p.cursor + 1
  if p.side == "left" and available[p.cursor] then
    vim.api.nvim_buf_set_extmark(p.buf, ns_id, item_lnum, 0,
      { end_col = cw, hl_group = "PmenuSel", priority = 100 })
  elseif p.side == "right" and p.selected[p.cursor] then
    vim.api.nvim_buf_set_extmark(p.buf, ns_id, item_lnum, cw + SEP_LEN,
      { end_col = cw + SEP_LEN + cw, hl_group = "PmenuSel", priority = 100 })
  end

  -- Keep the Neovim cursor on the highlighted item so the window auto-scrolls.
  if p.win and vim.api.nvim_win_is_valid(p.win) then
    local nvim_col = p.side == "right" and (cw + SEP_LEN) or 0
    pcall(vim.api.nvim_win_set_cursor, p.win, { item_lnum + 1, nvim_col })
    vim.api.nvim_win_set_config(p.win, { title = title(), title_pos = "center" })
  end
end

--- Close the picker window.
local function close()
  if p.win and vim.api.nvim_win_is_valid(p.win) then
    vim.api.nvim_win_close(p.win, true)
  end
end

--- Snapshot the selection ahead of a change, so `undo` can take it back.
--- Starts a fresh redo chain: the change makes any undone future moot.
local function push_history()
  table.insert(p.history, { available = vim.list_extend({}, p.available), selected = vim.list_extend({}, p.selected) })
  if #p.history > HISTORY_MAX then table.remove(p.history, 1) end
  p.redo = {}
end

--- Make `snap` the current selection, keeping the cursor on a valid item.
--- Marks and the range are dropped: they were made against a selection
--- that is no longer the one shown.
--- @param snap { available: string[], selected: string[] }
local function restore(snap)
  p.available = vim.list_extend({}, snap.available)
  p.selected  = vim.list_extend({}, snap.selected)
  p.marks, p.anchor = {}, nil
  local list  = focused_list()
  if #list == 0 then
    p.side = p.side == "left" and "right" or "left"
    list   = focused_list()
  end
  p.cursor = math.max(1, math.min(p.cursor, #list))
  render()
  if p.on_change then p.on_change(vim.list_extend({}, p.selected)) end
end

--- Take back the last change.
local function undo()
  local snap = table.remove(p.history)
  if not snap then return end
  table.insert(p.redo, { available = vim.list_extend({}, p.available), selected = vim.list_extend({}, p.selected) })
  restore(snap)
end

--- Reapply the last undone change.
local function redo()
  local snap = table.remove(p.redo)
  if not snap then return end
  table.insert(p.history, { available = vim.list_extend({}, p.available), selected = vim.list_extend({}, p.selected) })
  restore(snap)
end

--- Re-insert `col` into the available list while preserving original column order.
--- @param col string
local function insert_sorted_available(col)
  local rank = {}
  for i, c in ipairs(p.all_cols) do rank[c] = i end
  local cr = rank[col]
  for i, ac in ipairs(p.available) do
    if rank[ac] > cr then
      table.insert(p.available, i, col)
      return
    end
  end
  table.insert(p.available, col)
end

--- Move the focused item in the selected list up (`delta` = -1) or down (+1).
--- @param delta integer
local function reorder(delta)
  if p.side ~= "right" then return end
  local target = p.cursor + delta
  if target < 1 or target > #p.selected then return end
  push_history()
  p.selected[p.cursor], p.selected[target] = p.selected[target], p.selected[p.cursor]
  p.cursor = target
  render()
  if p.on_change then p.on_change(vim.list_extend({}, p.selected)) end
end

--- Restore available and selected to the state when the picker was opened.
local function reset()
  push_history()
  p.available = vim.list_extend({}, p.init_available)
  p.selected  = vim.list_extend({}, p.init_selected)
  p.marks, p.anchor = {}, nil
  p.side      = #p.init_available > 0 and "left" or "right"
  p.cursor    = 1
  render()
  if p.on_change then p.on_change(vim.list_extend({}, p.selected)) end
end

--- Move all available columns into selected — only the filter's matches, when
--- one is on, so `/prefix` then `>` picks a family of columns at once.
local function select_all()
  local moving = shown_available()
  if #moving == 0 then return end
  push_history()
  local moved = {}
  for _, col in ipairs(moving) do
    table.insert(p.selected, col)
    moved[col] = true
  end
  p.available = vim.tbl_filter(function(c) return not moved[c] end, p.available)
  p.marks, p.anchor = {}, nil
  p.side      = "right"
  p.cursor    = math.min(p.cursor, math.max(#p.selected, 1))
  render()
  if p.on_change then p.on_change(vim.list_extend({}, p.selected)) end
end

--- Move all selected columns back to available (in original order).
local function deselect_all()
  if #p.selected == 0 then return end
  push_history()
  for _, col in ipairs(p.selected) do
    insert_sorted_available(col)
  end
  p.selected = {}
  p.marks, p.anchor = {}, nil
  p.side     = "left"
  p.cursor   = math.min(p.cursor, math.max(#p.available, 1))
  render()
  if p.on_change then p.on_change({}) end
end

--- Move `cols` — items of the focused panel, in panel order — to the other
--- panel. Their marks go with them: once moved they are done with.
--- @param cols string[]
local function move_items(cols)
  if #cols == 0 then return end
  push_history()
  local moving = {}
  for _, col in ipairs(cols) do moving[col] = true; p.marks[col] = nil end
  p.anchor = nil
  if p.side == "left" then
    p.available = vim.tbl_filter(function(c) return not moving[c] end, p.available)
    vim.list_extend(p.selected, cols)
    local left = #shown_available()
    p.cursor = math.min(p.cursor, math.max(left, 1))
    if left == 0 then p.side = "right"; p.cursor = #p.selected end
  else
    p.selected = vim.tbl_filter(function(c) return not moving[c] end, p.selected)
    for _, col in ipairs(cols) do insert_sorted_available(col) end
    p.cursor = math.min(p.cursor, math.max(#p.selected, 1))
    if #p.selected == 0 then p.side = "left"; p.cursor = 1 end
  end
  render()
  if p.on_change then p.on_change(vim.list_extend({}, p.selected)) end
end

--- Move the range, the marked items, or the item under the cursor to the
--- other panel.
local function move_item()
  move_items(targets())
end

--- Mark or unmark the item under the cursor and step to the next one, so
--- a run of `m` picks out a scattered set.
local function toggle_mark()
  local list = focused_list()
  local col  = list[p.cursor]
  if not col then return end
  p.marks[col] = not p.marks[col] or nil
  p.cursor = math.min(p.cursor + 1, #list)
  render()
end

--- Drop every mark.
local function clear_marks()
  p.marks = {}
  render()
end

--- Start a range at the cursor, or drop the one in progress.
local function toggle_range()
  p.anchor = not p.anchor and p.cursor or nil
  render()
end

--- Open the column picker.
--- @param all_cols  string[]  all column names in original order
--- @param vis_cols  string[]  currently visible column names
--- @param on_change fun(selected: string[])  called live on every toggle
function M.open(all_cols, vis_cols, on_change)
  if p.win and vim.api.nvim_win_is_valid(p.win) then
    vim.api.nvim_set_current_win(p.win)
    return
  end

  local vis_set  = {}
  for _, c in ipairs(vis_cols) do vis_set[c] = true end
  local available = {}
  for _, c in ipairs(all_cols) do
    if not vis_set[c] then table.insert(available, c) end
  end

  local col_width = vim.api.nvim_strwidth("  Available columns")
  for _, c in ipairs(all_cols) do
    col_width = math.max(col_width, vim.api.nvim_strwidth(c) + 2)
  end

  local inner_h = math.min(#all_cols + 2, vim.o.lines - 8)
  local inner_w = col_width * 2 + SEP_LEN
  local row     = math.max(0, math.floor((vim.o.lines   - inner_h - 2) / 2))
  local col     = math.max(0, math.floor((vim.o.columns - inner_w - 2) / 2))

  local buf = vim.api.nvim_create_buf(false, true)
  table_fmt.setup_buf_hl(buf)

  p = {
    buf            = buf,
    win            = nil,
    available      = available,
    selected       = vim.list_extend({}, vis_cols),
    init_available = vim.list_extend({}, available),
    init_selected  = vim.list_extend({}, vis_cols),
    all_cols       = all_cols,
    side           = #available > 0 and "left" or "right",
    cursor         = 1,
    col_width      = col_width,
    height         = inner_h,
    on_change      = on_change,
    history        = {},
    redo           = {},
    filter         = nil,
    filter_editing = false,
    marks          = {},   -- { [column] = true }
    anchor         = nil,  -- range start in the focused panel, while one is active
  }

  render()

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = row,
    col       = col,
    width     = inner_w,
    height    = inner_h,
    style     = "minimal",
    border    = "rounded",
    title     = title(),
    title_pos = "center",
  })
  p.win = win

  vim.api.nvim_win_set_hl_ns(win, hl.NS_ID)
  vim.api.nvim_set_option_value("number",     false, { win = win })
  vim.api.nvim_set_option_value("signcolumn", "no",  { win = win })
  vim.api.nvim_set_option_value("wrap",       false, { win = win })
  vim.api.nvim_set_option_value("cursorline", false, { win = win })

  render()  -- second call positions the Neovim cursor now that p.win is set

  --- Register a normal-mode keymap on the picker buffer.
  --- @param key string
  --- @param fn  fun()
  --- @param desc string
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  --- Open a floating keymap cheatsheet for the picker.
  local function show_help()
    local keymaps = vim.api.nvim_buf_get_keymap(buf, "n")
    local lines   = {}
    for _, km in ipairs(keymaps) do
      if km.desc and km.desc ~= "" then
        local lhs = km.lhs:gsub("^<lt>$", "<")
      table.insert(lines, string.format("  %-10s  %s", lhs, km.desc))
      end
    end
    table.sort(lines)
    if #lines == 0 then return end
    local width = 0
    for _, l in ipairs(lines) do width = math.max(width, #l) end
    local hbuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(hbuf, 0, -1, false, lines)
    vim.bo[hbuf].modifiable = false
    vim.bo[hbuf].bufhidden  = "wipe"
    local hwin = vim.api.nvim_open_win(hbuf, true, {
      relative  = "cursor",
      row       = 1,
      col       = 0,
      width     = width,
      height    = #lines,
      style     = "minimal",
      border    = "rounded",
      title     = " keymaps ",
      title_pos = "center",
    })
    for _, key in ipairs({ "q", "<Esc>", "g?" }) do
      vim.keymap.set("n", key, function() pcall(vim.api.nvim_win_close, hwin, true) end,
        { buffer = hbuf, silent = true })
    end
  end

  --- Type a filter for the available panel, narrowing it as each character
  --- lands. Always starts empty: a filter kept from an earlier `/` is what
  --- Enter leaves in force, and pressing `/` again means a new search, not
  --- an edit of the old one. While typing, Down/Up (or Ctrl-N/Ctrl-P) move
  --- among the matches and Tab picks the highlighted one and clears the
  --- filter, so the next name can be typed straight away without leaving
  --- the prompt. Enter keeps the filter in force and hands the keys back to
  --- the picker; Esc drops it. Reads keys directly rather than through a
  --- prompt buffer so the panels can redraw between keystrokes.
  local function edit_filter()
    p.filter_editing = true
    p.filter = ""
    p.side   = "left"
    p.cursor = 1
    p.anchor = nil
    -- Keys are matched by their |keytrans()| name, so a special key arrives
    -- as "<Down>" whatever bytes the terminal sent, and only a key with no
    -- such name — a plain character — is ever typed into the filter. An
    -- unrecognised special key (a function key, an Alt chord, a stray
    -- escape sequence) is ignored rather than inserted as its raw bytes.
    local bs   = { ["<BS>"] = true, ["<C-H>"] = true, ["<Del>"] = true }
    local down = { ["<Down>"] = true, ["<C-N>"] = true }
    local up   = { ["<Up>"] = true, ["<C-P>"] = true }
    local literal = { ["<Space>"] = " ", ["<lt>"] = "<" }
    while true do
      render()
      vim.cmd.redraw()
      local ok, ch = pcall(vim.fn.getcharstr)
      local key = ok and (ch == "\127" and "<Del>" or vim.fn.keytrans(ch)) or "<C-C>"
      if key == "<C-C>" or key:sub(1, 5) == "<Esc>" then
        p.filter = nil
        break
      elseif key == "<CR>" or key == "<NL>" then
        if p.filter == "" then p.filter = nil end
        break
      elseif key == "<Tab>" then
        local match = shown_available()[p.cursor]
        if match then
          move_items({ match })
          p.filter = ""
          p.side   = "left"
          p.cursor = 1
        end
      elseif down[key] then
        p.cursor = math.min(p.cursor + 1, math.max(#shown_available(), 1))
      elseif up[key] then
        p.cursor = math.max(1, p.cursor - 1)
      elseif bs[key] then
        p.filter = vim.fn.strcharpart(p.filter, 0, vim.fn.strchars(p.filter) - 1)
        p.cursor = 1
      elseif key == "<C-U>" then
        p.filter = ""
        p.cursor = 1
      elseif literal[key] or not key:match("^<.*>$") then
        p.filter = p.filter .. (literal[key] or ch)
        p.cursor = 1
      end
    end
    p.filter_editing = false
    if #shown_available() == 0 then p.side = "right" end
    p.cursor = 1
    render()
  end

  --- Esc: drop the range in progress, else the filter when one is on;
  --- otherwise close.
  local function esc()
    if p.anchor then
      p.anchor = nil
      render()
    elseif p.filter then
      p.filter = nil
      p.cursor = 1
      render()
    else
      close()
    end
  end

  --- Move cursor to the next item in the focused panel.
  local function nav_down()
    p.cursor = math.min(p.cursor + 1, math.max(#focused_list(), 1))
    render()
  end
  --- Move cursor to the previous item in the focused panel.
  local function nav_up()   p.cursor = math.max(1, p.cursor - 1); render() end
  --- Switch focus to the available (left) panel. A range belongs to the
  --- panel it was started in, so switching drops it.
  local function nav_left()
    p.side   = "left"
    p.anchor = nil
    p.cursor = math.min(p.cursor, math.max(#shown_available(), 1))
    render()
  end
  --- Switch focus to the selected (right) panel.
  local function nav_right()
    p.side   = "right"
    p.anchor = nil
    p.cursor = math.min(p.cursor, math.max(#p.selected, 1))
    render()
  end

  map("q",       close,      "Close")
  map("<Esc>",   esc,        "Clear filter, or close")
  map("j",       nav_down,   "Move cursor down")
  map("<Down>",  nav_down,   "")
  map("k",       nav_up,     "Move cursor up")
  map("<Up>",    nav_up,     "")
  map("h",       nav_left,   "Focus available panel")
  map("<Left>",  nav_left,   "")
  map("l",       nav_right,  "Focus selected panel")
  map("<Right>", nav_right,  "")
  map("<Tab>",   move_item,  "Toggle column (or the marked ones, or the range)")
  map("<CR>",    move_item,  "")
  map("<Space>", move_item,  "")
  map("m",       toggle_mark,  "Mark/unmark column")
  map("M",       clear_marks,  "Clear marks")
  map("v",       toggle_range, "Start/stop a range")
  map("V",       toggle_range, "")
  map("K",       function() reorder(-1) end, "Move column up")
  map("J",       function() reorder(1)  end, "Move column down")
  map(">",       select_all,   "Select all")
  map("<",       deselect_all, "Deselect all")
  map("r",       reset,        "Reset to initial selection")
  map("u",       undo,         "Undo last change")
  map("<C-r>",   redo,         "Redo")
  map("/",       edit_filter,  "Filter available columns")
  map("g?",      show_help,    "Show keymaps")

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern  = tostring(win),
    once     = true,
    callback = function()
      if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      p = {}
    end,
  })
end

return M
