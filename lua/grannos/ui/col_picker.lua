-- Floating two-panel column picker.
--
-- Left panel:  available (unselected) columns.
-- Right panel: selected columns (in display order).
-- j/k navigate within the focused panel; h/l switch panels.
-- Tab/Enter/Space move the item under the cursor to the other panel.
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

--- The window title: the picker's name, plus the filter being typed or in
--- force. The title rather than a buffer line, so it stays in view however
--- far a long column list scrolls.
--- @return string
local function title()
  if p.filter_editing then return (" Columns  /%s▏ "):format(p.filter or "") end
  if p.filter and p.filter ~= "" then
    return (" Columns  /%s  %d of %d "):format(p.filter, #shown_available(), #p.available)
  end
  return " Columns "
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
  local available = shown_available()
  local n = math.max(#available, #p.selected, 1, (p.height or 2) - 2)
  for i = 1, n do
    local ltext = available[i] and ("  " .. available[i]) or ""
    local rtext = p.selected[i] and ("  " .. p.selected[i]) or ""
    table.insert(lines, pad(ltext, cw) .. SEP .. pad(rtext, cw))
  end
  vim.api.nvim_buf_set_lines(p.buf, 0, -1, false, lines)

  vim.api.nvim_buf_clear_namespace(p.buf, ns_id, 0, -1)

  -- Header text
  vim.api.nvim_buf_set_extmark(p.buf, ns_id, 0, 0,
    { end_col = cw, hl_group = "GrannosHeaderRow" })
  vim.api.nvim_buf_set_extmark(p.buf, ns_id, 0, cw + SEP_LEN,
    { end_col = cw + SEP_LEN + cw, hl_group = "GrannosHeaderRow" })

  -- Cursor highlight (0-indexed: header=0, sep-row=1, items start at 2)
  local item_lnum = p.cursor + 1
  if p.side == "left" and available[p.cursor] then
    vim.api.nvim_buf_set_extmark(p.buf, ns_id, item_lnum, 0,
      { end_col = cw, hl_group = "PmenuSel" })
  elseif p.side == "right" and p.selected[p.cursor] then
    vim.api.nvim_buf_set_extmark(p.buf, ns_id, item_lnum, cw + SEP_LEN,
      { end_col = cw + SEP_LEN + cw, hl_group = "PmenuSel" })
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
--- @param snap { available: string[], selected: string[] }
local function restore(snap)
  p.available = vim.list_extend({}, snap.available)
  p.selected  = vim.list_extend({}, snap.selected)
  local list  = p.side == "left" and shown_available() or p.selected
  if #list == 0 then
    p.side = p.side == "left" and "right" or "left"
    list   = p.side == "left" and shown_available() or p.selected
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
  p.side     = "left"
  p.cursor   = math.min(p.cursor, math.max(#p.available, 1))
  render()
  if p.on_change then p.on_change({}) end
end

--- Move the item under the cursor between available and selected.
local function move_item()
  if p.side == "left" then
    local col = shown_available()[p.cursor]
    if not col then return end
    push_history()
    for i, c in ipairs(p.available) do
      if c == col then table.remove(p.available, i); break end
    end
    table.insert(p.selected, col)
    local left = #shown_available()
    p.cursor = math.min(p.cursor, math.max(left, 1))
    if left == 0 then p.side = "right"; p.cursor = #p.selected end
  else
    local col = p.selected[p.cursor]
    if not col then return end
    push_history()
    table.remove(p.selected, p.cursor)
    insert_sorted_available(col)
    p.cursor = math.min(p.cursor, math.max(#p.selected, 1))
    if #p.selected == 0 then p.side = "left"; p.cursor = 1 end
  end
  render()
  if p.on_change then p.on_change(vim.list_extend({}, p.selected)) end
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
        if shown_available()[p.cursor] then
          move_item()
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

  --- Esc: drop the filter when one is on; otherwise close.
  local function esc()
    if p.filter then
      p.filter = nil
      p.cursor = 1
      render()
    else
      close()
    end
  end

  --- Move cursor to the next item in the focused panel.
  local function nav_down()
    local list = p.side == "left" and shown_available() or p.selected
    p.cursor   = math.min(p.cursor + 1, math.max(#list, 1))
    render()
  end
  --- Move cursor to the previous item in the focused panel.
  local function nav_up()   p.cursor = math.max(1, p.cursor - 1); render() end
  --- Switch focus to the available (left) panel.
  local function nav_left()
    p.side   = "left"
    p.cursor = math.min(p.cursor, math.max(#shown_available(), 1))
    render()
  end
  --- Switch focus to the selected (right) panel.
  local function nav_right()
    p.side   = "right"
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
  map("<Tab>",   move_item,  "Toggle column")
  map("<CR>",    move_item,  "")
  map("<Space>", move_item,  "")
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
