-- A single persistent form for creating/editing/cloning a connection.
-- All fields are shown at once and can be edited in any order: j/k move focus,
-- <CR> edits the focused field in place — an editable overlay right over the
-- value cell for text/secret fields, a dropdown directly below the row for
-- choice fields — <C-s> submits, q/<Esc> cancels the whole form. Cancelling an
-- individual field edit only returns focus to the form — it never discards the
-- rest of the form's state.
local M = {}

local hl     = require("grannos.hl")
local Buffer = require("grannos.buffer")

local NS = vim.api.nvim_create_namespace("GrannosConnForm")

-- Module-level state: only one form is open at a time.
local f = {}

local HELP_KEYMAPS = {
  { lhs = "j/<Down>", desc = "Next field",     group = "Navigate" },
  { lhs = "k/<Up>",   desc = "Previous field", group = "Navigate" },
  { lhs = "<CR>",     desc = "Edit field",     group = "Navigate" },
  { lhs = "<C-s>",    desc = "Save",           group = "" },
  { lhs = "q/<Esc>",  desc = "Cancel",         group = "" },
  { lhs = "g?",       desc = "Show this help", group = "" },
}

--- Redraw the form buffer from the current field values/cursor/error state.
local function render()
  if not f.buf or not vim.api.nvim_buf_is_valid(f.buf) then return end

  local lines = {}
  for i, field in ipairs(f.fields) do
    field._row0 = i - 1
    local label  = field.label .. string.rep(" ", f.label_w - vim.api.nvim_strwidth(field.label))
    local prefix = "  " .. label .. ": "
    field._value_col = #prefix  -- byte column where the value starts, for dropdown alignment
    local line = prefix .. field.display()
    if field.is_valid and not field.is_valid() then line = line .. "  (required)" end
    lines[i] = line
  end
  table.insert(lines, "")
  local err_row = nil
  if f.error then
    err_row = #lines
    table.insert(lines, "  \xE2\x9C\x97 " .. f.error)  -- ✗
    table.insert(lines, "")
  end
  table.insert(lines, "  <Enter> edit   <C-s> save   q/<Esc> cancel   g? help")

  vim.bo[f.buf].modifiable = true
  vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, lines)
  vim.bo[f.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(f.buf, NS, 0, -1)
  for i, field in ipairs(f.fields) do
    if field.is_valid and not field.is_valid() then
      vim.hl.range(f.buf, NS, "GrannosConnError", { i - 1, 0 }, { i - 1, -1 })
    end
  end
  if err_row then
    vim.hl.range(f.buf, NS, "GrannosConnError", { err_row, 0 }, { err_row, -1 })
  end
  if f.fields[f.cursor] then
    vim.hl.range(f.buf, NS, "PmenuSel", { f.cursor - 1, 0 }, { f.cursor - 1, -1 })
  end
  if f.win and vim.api.nvim_win_is_valid(f.win) then
    pcall(vim.api.nvim_win_set_cursor, f.win, { f.cursor, 0 })
  end
end

--- Close the form window/buffer and clear module state.
local function close()
  if f.win and vim.api.nvim_win_is_valid(f.win) then
    pcall(vim.api.nvim_win_close, f.win, true)
  end
  f = {}
end

--- Open a borderless, single-row editable overlay directly over `field`'s
--- value cell (text/secret fields), flush with the form so it reads as an
--- in-place edit rather than a popup. <CR> commits the typed text via
--- `field.commit_text`; leaving insert mode any other way (<Esc>, <C-c>, or
--- anything else that fires InsertLeave) cancels without committing. Secret
--- fields mask every character as "*" via a per-column conceal extmark (a
--- single extmark's conceal only shows one replacement glyph for its whole
--- range, so each column needs its own to mask every character).
--- @param field table  ConnFormField (kind == "text" or "secret")
local function open_text_overlay(field)
  local initial = field.edit_prefill and field.edit_prefill() or ""
  local width   = math.max(10, (f.width or 60) - field._value_col - 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { initial })

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "win",
    win       = f.win,
    bufpos    = { field._row0, field._value_col },
    row       = 0,
    col       = 0,
    width     = width,
    height    = 1,
    style     = "minimal",
    border    = "none",
    zindex    = 60,
  })
  vim.wo[win].wrap = false
  -- Tint the background so the row reads as actively editable/in insert mode,
  -- since the overlay otherwise has no border to set it apart from the form.
  -- Deliberately NOT linked to hl.NS_ID here (unlike the form/dropdown
  -- windows): nvim_win_set_hl_ns takes precedence over 'winhighlight' and
  -- would silently defeat this tint, so GrannosConnFormEdit is a global group.
  vim.wo[win].winhl = "Normal:GrannosConnFormEdit,NormalNC:GrannosConnFormEdit"

  if field.kind == "secret" then
    local mask_ns = vim.api.nvim_create_namespace("GrannosConnFormMask_" .. buf)
    --- Re-cover every character of the (single) line with its own conceal extmark.
    local function remask()
      vim.api.nvim_buf_clear_namespace(buf, mask_ns, 0, -1)
      local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
      for col = 0, #line - 1 do
        vim.api.nvim_buf_set_extmark(buf, mask_ns, 0, col, { end_col = col + 1, conceal = "*" })
      end
    end
    vim.wo[win].conceallevel  = 2
    vim.wo[win].concealcursor = "nvic"
    remask()
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = buf, callback = remask })
  end

  pcall(vim.api.nvim_win_set_cursor, win, { 1, #initial })

  -- Guards against double-closing: <CR>/<Esc>/<C-c> below leave insert mode
  -- themselves via stopinsert, which re-fires InsertLeave; and InsertLeave
  -- itself is the catch-all for any other way of leaving insert mode.
  local closed = false

  --- Commit the typed line, then close.
  local function confirm()
    if closed then return end
    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    closed = true
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    field.commit_text(line)
    render()
  end

  --- Close without committing.
  local function cancel_edit()
    if closed then return end
    closed = true
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  vim.keymap.set({ "i", "n" }, "<CR>",  confirm,     { buffer = buf, nowait = true, silent = true })
  vim.keymap.set({ "i", "n" }, "<Esc>", cancel_edit, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set({ "i", "n" }, "<C-c>", cancel_edit, { buffer = buf, nowait = true, silent = true })

  -- Catch-all: any other way of leaving insert mode (mouse click elsewhere,
  -- a user-defined insert-mode exit mapping, etc.) closes without committing.
  vim.api.nvim_create_autocmd("InsertLeave", { buffer = buf, callback = cancel_edit })

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win), once = true,
    callback = function()
      if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    end,
  })

  vim.schedule(function() vim.cmd("startinsert!") end)
end

--- Open a dropdown float listing `field`'s options directly below its row.
--- Selecting a normal option calls `field.commit_choice`; selecting the
--- reserved "is_new" option (if present) instead opens the same in-place text
--- overlay used by text/secret fields, which calls `field.commit_text`.
--- @param field table  ConnFormField (kind == "choice")
local function open_dropdown(field)
  local items = field.options()
  if #items == 0 then return end

  local width = 10
  for _, item in ipairs(items) do width = math.max(width, vim.api.nvim_strwidth(item.label)) end

  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for _, item in ipairs(items) do table.insert(lines, "  " .. item.label) end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden  = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "win",
    win       = f.win,
    bufpos    = { field._row0, field._value_col },
    row       = 1,
    col       = 0,
    width     = width + 2,
    height    = #items,
    style     = "minimal",
    border    = "rounded",
    zindex    = 60,
  })
  vim.api.nvim_win_set_hl_ns(win, hl.NS_ID)
  vim.api.nvim_set_option_value("cursorline", true, { win = win })

  --- Close the dropdown only (the parent form stays open).
  local function close_dropdown()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  --- Commit whichever option is under the dropdown cursor.
  local function choose()
    local idx = vim.api.nvim_win_get_cursor(win)[1]
    local item = items[idx]
    close_dropdown()
    if item.is_new then
      vim.schedule(function() open_text_overlay(field) end)
    else
      field.commit_choice(item)
      render()
    end
  end

  for _, key in ipairs({ "<CR>", "<Space>" }) do
    vim.keymap.set("n", key, choose, { buffer = buf, nowait = true, silent = true })
  end
  for _, key in ipairs({ "q", "<Esc>", "<C-c>" }) do
    vim.keymap.set("n", key, close_dropdown, { buffer = buf, nowait = true, silent = true })
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win), once = true,
    callback = function()
      if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    end,
  })
end

--- Activate the field currently under the cursor: open its dropdown (choice
--- fields) or its in-place text overlay (text/secret fields).
local function activate()
  local field = f.fields[f.cursor]
  if not field then return end
  if field.kind == "choice" then
    open_dropdown(field)
  else
    open_text_overlay(field)
  end
end

--- Validate required fields, gather values, and hand them to on_submit.
--- on_submit's `done(err)` either closes the form (err == nil) or keeps it
--- open with an inline error message (err ~= nil) so the user can fix the
--- offending field without losing anything else they've entered.
local function submit()
  for _, field in ipairs(f.fields) do
    if field.is_valid and not field.is_valid() then
      vim.notify("grannos: fill in all required fields", vim.log.levels.WARN)
      return
    end
  end

  local values = {}
  for _, field in ipairs(f.fields) do values[field.key] = field.get() end

  local on_submit = f.on_submit
  on_submit(values, function(err)
    if err then
      f.error = err
      render()
    else
      close()
    end
  end)
end

--- Cancel the whole form and notify the caller.
local function cancel()
  local on_cancel = f.on_cancel
  close()
  if on_cancel then on_cancel() end
end

--- Open the connection form.
--- @param opts table
---   .title     string
---   .fields    table[]  ConnFormField list (see module docstring for the shape:
---              key, label, kind ("text"|"secret"|"choice"), get, display, is_valid,
---              edit_prefill/commit_text for text/secret, options/commit_choice for choice)
---   .on_submit fun(values: table<string, any>, done: fun(err: string|nil))
---   .on_cancel fun()
function M.open(opts)
  close()  -- only one form at a time

  local label_w = 1
  for _, field in ipairs(opts.fields) do
    label_w = math.max(label_w, vim.api.nvim_strwidth(field.label))
  end

  local width  = math.min(math.max(60, label_w + 40), vim.o.columns - 4)
  local height = #opts.fields + 3

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = math.max(0, math.floor((vim.o.lines   - height - 2) / 2)),
    col       = math.max(0, math.floor((vim.o.columns - width  - 2) / 2)),
    width     = width,
    height    = height,
    style     = "minimal",
    border    = "rounded",
    title     = " " .. opts.title .. " ",
    title_pos = "center",
  })
  vim.api.nvim_win_set_hl_ns(win, hl.NS_ID)

  f = {
    buf       = buf,
    win       = win,
    fields    = opts.fields,
    cursor    = 1,
    label_w   = label_w,
    width     = width,
    error     = nil,
    on_submit = opts.on_submit,
    on_cancel = opts.on_cancel,
  }

  render()

  --- Register a normal-mode keymap on the form buffer.
  --- @param key string
  --- @param fn  fun()
  local function map(key, fn) vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true }) end

  local function nav_down() f.cursor = math.min(f.cursor + 1, #f.fields); render() end
  local function nav_up()   f.cursor = math.max(f.cursor - 1, 1);         render() end

  map("j",      nav_down)
  map("<Down>", nav_down)
  map("k",      nav_up)
  map("<Up>",   nav_up)
  map("<CR>",   activate)
  map("<C-s>",  submit)
  map("q",      cancel)
  map("<Esc>",  cancel)
  map("g?",     function() Buffer.render_help_float(HELP_KEYMAPS) end)

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win), once = true,
    callback = function() if f.win == win then f = {} end end,
  })
end

return M
