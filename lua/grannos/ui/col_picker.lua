-- Floating column checklist.
--
-- One line per column, in display order; the buffer holds nothing but the
-- names, so the line under the cursor is the column acted on and every
-- native motion and search works unchanged: j/k, gg/G, counts, / ? n N *,
-- 'hlsearch'. Whether a column is shown is drawn beside it in the sign
-- column (󰄲 shown, 󰄱 hidden, its name dimmed), never in the text, so `/`
-- matches names alone and `/^user_` or `/_at$` mean what they say.
--
-- Space/Tab/Enter toggle the column under the cursor; in visual mode, every
--     selected column (shown when any of them was hidden, else hidden).
-- g/  toggle every column the last search matches, by the same rule, so
--     `/^event\.` then `g/` acts on a whole family.
-- J/K move the column under the cursor down/up (takes a count).
-- >/< show/hide every column.
-- u   undo the last change; Ctrl-R redo. Every change is applied live via the
--     on_change callback, so an accidental `<` has already reached the table
--     (and the saved selection) — undo is what takes it back. Vim's own undo
--     can't: the buffer is rewritten, not edited, and is not modifiable.
-- r   reset to the selection the picker was opened with.
-- Esc clears the search highlight; it never closes, so a stray Esc after a
--     search or a visual selection keeps the picker open.
-- q   close.
local hl = require("grannos.hl")

local M = {}

local ns_id = vim.api.nvim_create_namespace("grannos_col_picker")

--- Sign beside a shown column, and beside a hidden one.
local SHOWN_SIGN  = "󰄲"  -- nf-md-checkbox_marked
local HIDDEN_SIGN = "󰄱"  -- nf-md-checkbox_blank_outline

--- Most undo steps kept; older ones are dropped.
local HISTORY_MAX = 100

-- One picker at a time.
local p = {}

--- The shown columns, in list order: what the table displays.
--- @return string[]
local function selection()
  local out = {}
  for _, c in ipairs(p.order) do
    if p.shown[c] then out[#out + 1] = c end
  end
  return out
end

--- The window title: the picker's name and how many columns are shown.
--- @return string
local function title()
  return (" Columns  %d of %d shown "):format(#selection(), #p.order)
end

--- Redraw the buffer and its signs from the picker state.
local function render()
  if not p.buf or not vim.api.nvim_buf_is_valid(p.buf) then return end
  vim.bo[p.buf].modifiable = true
  vim.api.nvim_buf_set_lines(p.buf, 0, -1, false, p.order)
  vim.bo[p.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(p.buf, ns_id, 0, -1)
  for i, c in ipairs(p.order) do
    if p.shown[c] then
      vim.api.nvim_buf_set_extmark(p.buf, ns_id, i - 1, 0,
        { sign_text = SHOWN_SIGN, sign_hl_group = "GrannosColumnShown" })
    else
      vim.api.nvim_buf_set_extmark(p.buf, ns_id, i - 1, 0,
        { sign_text = HIDDEN_SIGN, sign_hl_group = "GrannosColumnHidden",
          end_col = #c, hl_group = "GrannosColumnHidden" })
    end
  end

  if p.win and vim.api.nvim_win_is_valid(p.win) then
    vim.api.nvim_win_set_config(p.win, { title = title(), title_pos = "center" })
  end
end

--- A copy of the current selection state, for the undo history.
--- @return { order: string[], shown: table<string, true> }
local function snapshot()
  return { order = vim.list_extend({}, p.order), shown = vim.deepcopy(p.shown) }
end

--- Apply `fn` to the picker state as one undoable change, then redraw and
--- report the new selection. A change that alters nothing is dropped, so it
--- leaves no empty undo step and no redundant on_change.
--- @param fn fun()
local function change(fn)
  local before = snapshot()
  fn()
  if vim.deep_equal(before, snapshot()) then return end
  table.insert(p.history, before)
  if #p.history > HISTORY_MAX then table.remove(p.history, 1) end
  p.redo = {}
  render()
  if p.on_change then p.on_change(selection()) end
end

--- Make `snap` the current state, keeping the cursor where it is.
--- @param snap { order: string[], shown: table<string, true> }
local function restore(snap)
  p.order, p.shown = snap.order, snap.shown
  render()
  if p.on_change then p.on_change(selection()) end
end

--- Take back the last change.
local function undo()
  local snap = table.remove(p.history)
  if not snap then return end
  table.insert(p.redo, snapshot())
  restore(snap)
end

--- Reapply the last undone change.
local function redo()
  local snap = table.remove(p.redo)
  if not snap then return end
  table.insert(p.history, snapshot())
  restore(snap)
end

--- Toggle `cols` together: show them all when any is hidden, else hide them
--- all — so a mixed set ends up uniformly shown, the less destructive choice.
--- @param cols string[]
local function toggle(cols)
  if #cols == 0 then return end
  local all_shown = true
  for _, c in ipairs(cols) do
    if not p.shown[c] then all_shown = false break end
  end
  change(function()
    for _, c in ipairs(cols) do p.shown[c] = (not all_shown) or nil end
  end)
end

--- Toggle the column under the cursor.
local function toggle_current()
  toggle({ p.order[vim.fn.line(".")] })
end

--- Toggle every line of the visual selection, then leave visual mode.
local function toggle_visual()
  local a, b = vim.fn.line("v"), vim.fn.line(".")
  if a > b then a, b = b, a end
  vim.cmd("normal! \27")
  toggle(vim.list_slice(p.order, a, b))
end

--- Toggle every column the last search pattern matches.
local function toggle_matches()
  local pat = vim.fn.getreg("/")
  if pat == "" then
    vim.notify("grannos: no search pattern — search with / first", vim.log.levels.WARN)
    return
  end
  local cols = {}
  for _, c in ipairs(p.order) do
    local ok, idx = pcall(vim.fn.match, c, pat)
    if ok and idx >= 0 then cols[#cols + 1] = c end
  end
  if #cols == 0 then
    vim.notify("grannos: no column matches /" .. pat, vim.log.levels.WARN)
    return
  end
  toggle(cols)
end

--- Move the column under the cursor `delta` lines (negative = up), times the
--- count, clamped to the list; the cursor follows it.
--- @param delta integer
local function move(delta)
  local from = vim.fn.line(".")
  local to   = math.max(1, math.min(#p.order, from + delta * vim.v.count1))
  if to == from then return end
  change(function()
    table.insert(p.order, to, table.remove(p.order, from))
  end)
  vim.api.nvim_win_set_cursor(p.win, { to, 0 })
end

--- Show (`on` true) or hide every column.
--- @param on boolean
local function set_all(on)
  change(function()
    for _, c in ipairs(p.order) do p.shown[c] = on or nil end
  end)
end

--- Restore the selection the picker was opened with.
local function reset()
  change(function()
    p.order = vim.list_extend({}, p.init.order)
    p.shown = vim.deepcopy(p.init.shown)
  end)
end

--- Close the picker window.
local function close()
  if p.win and vim.api.nvim_win_is_valid(p.win) then
    vim.api.nvim_win_close(p.win, true)
  end
end

--- The list order the picker opens with: the visible columns in display
--- order, each hidden one slotted in right after the column it follows in
--- the result (already placed, visible or not, since the result is walked in
--- order) — so an untouched order reads as the result's, and a hidden column
--- sits beside its neighbour.
--- @param all_cols string[]
--- @param vis_cols string[]
--- @return string[]
local function initial_order(all_cols, vis_cols)
  local order, placed = vim.list_extend({}, vis_cols), {}
  for _, c in ipairs(vis_cols) do placed[c] = true end
  for i, c in ipairs(all_cols) do
    if not placed[c] then
      local at = 1
      if i > 1 then
        for k, o in ipairs(order) do
          if o == all_cols[i - 1] then at = k + 1 break end
        end
      end
      table.insert(order, at, c)
      placed[c] = true
    end
  end
  return order
end

--- Open a floating cheatsheet of the picker's keymaps.
--- @param buf integer  the picker buffer
local function show_help(buf)
  local lines = {}
  for _, mode in ipairs({ "n", "x" }) do
    for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
      if km.desc and km.desc ~= "" then
        local lhs = km.lhs:gsub("^<lt>$", "<")
        table.insert(lines, ("  %-10s  %s"):format((mode == "x" and "v_" or "") .. lhs, km.desc))
      end
    end
  end
  table.insert(lines, ("  %-10s  %s"):format("/ ? n N *", "Search columns (native)"))
  table.sort(lines)
  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, vim.api.nvim_strwidth(l)) end
  local hbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(hbuf, 0, -1, false, lines)
  vim.bo[hbuf].modifiable = false
  vim.bo[hbuf].bufhidden  = "wipe"
  local hwin = vim.api.nvim_open_win(hbuf, true, {
    relative  = "cursor",
    row       = 1,
    col       = 0,
    width     = width + 2,
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

--- Open the column picker.
--- @param all_cols  string[]  all column names in original order
--- @param vis_cols  string[]  currently visible column names, in display order
--- @param on_change fun(selected: string[])  called live on every change
function M.open(all_cols, vis_cols, on_change)
  if p.win and vim.api.nvim_win_is_valid(p.win) then
    vim.api.nvim_set_current_win(p.win)
    return
  end

  local shown = {}
  for _, c in ipairs(vis_cols) do shown[c] = true end
  local order = initial_order(all_cols, vis_cols)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  p = {
    buf       = buf,
    win       = nil,
    order     = order,
    shown     = shown,
    init      = { order = vim.list_extend({}, order), shown = vim.deepcopy(shown) },
    on_change = on_change,
    history   = {},
    redo      = {},
  }
  render()

  local name_w = 0
  for _, c in ipairs(all_cols) do name_w = math.max(name_w, vim.api.nvim_strwidth(c)) end
  local digits  = #tostring(#all_cols)
  local title_w = #(" Columns  %s of %s shown "):format(("9"):rep(digits), ("9"):rep(digits))
  -- 2 sign-column cells, the gap after them, the name, and a cell of right padding.
  local width   = math.min(math.max(name_w + 4, title_w), vim.o.columns - 4)
  local height  = math.max(1, math.min(#all_cols, vim.o.lines - 8))

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = math.max(0, math.floor((vim.o.lines   - height - 2) / 2)),
    col       = math.max(0, math.floor((vim.o.columns - width  - 2) / 2)),
    width     = width,
    height    = height,
    style     = "minimal",
    border    = "rounded",
    title     = title(),
    title_pos = "center",
  })
  p.win = win

  vim.api.nvim_win_set_hl_ns(win, hl.NS_ID)
  vim.wo[win].signcolumn = "yes:1"
  -- The sign column, then a space, so a name never sits flush against its mark.
  vim.wo[win].statuscolumn = "%s "
  vim.wo[win].cursorline = true
  vim.wo[win].wrap       = false

  --- Register a keymap on the picker buffer.
  --- @param mode string
  --- @param key  string
  --- @param fn   fun()
  --- @param desc string
  local function map(mode, key, fn, desc)
    vim.keymap.set(mode, key, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  map("n", "q",       close,          "Close")
  map("n", "<Esc>",   function() vim.cmd("nohlsearch") end, "Clear the search highlight")
  map("n", "<Space>", toggle_current, "Show/hide the column")
  map("n", "<Tab>",   toggle_current, "")
  map("n", "<CR>",    toggle_current, "")
  map("x", "<Space>", toggle_visual,  "Show/hide the selected columns")
  map("x", "<Tab>",   toggle_visual,  "")
  map("x", "<CR>",    toggle_visual,  "")
  map("n", "g/",      toggle_matches, "Show/hide every column the last search matches")
  map("n", "J",       function() move(1)  end, "Move the column down")
  map("n", "K",       function() move(-1) end, "Move the column up")
  map("n", ">",       function() set_all(true)  end, "Show every column")
  map("n", "<",       function() set_all(false) end, "Hide every column")
  map("n", "r",       reset, "Reset to the initial selection")
  map("n", "u",       undo,  "Undo the last change")
  map("n", "<C-r>",   redo,  "Redo")
  map("n", "g?",      function() show_help(buf) end, "Show keymaps")

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern  = tostring(win),
    once     = true,
    callback = function() p = {} end,
  })
end

return M
