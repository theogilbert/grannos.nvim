-- Single-row detail float for the results pane: one row laid out as a vertical
-- `column │ value` table, so a row too wide to read across can be read down.
--
-- The buffer holds nothing but the values, verbatim: one line per line of a
-- value (its own newlines are the only line breaks, its tabs stay tabs), and
-- an empty line between fields. Column names live in the window's
-- 'statuscolumn', which draws a field's name beside its first line and the
-- border beside every other screen row, wrapped ones included. So Neovim's own
-- 'wrap' folds a long value under the value column and refolds it when the
-- window is resized, and `yy` (a one-line value) or `yip` (any value) yanks
-- exactly the value, with no name, border or injected break in it.
--
-- It shows every column of the row by default; `a` toggles to the columns the
-- results pane displays (its column selection) and back.
local pane   = require("grannos.ui.detail_pane")
local hl     = require("grannos.hl")
local Buffer = require("grannos.buffer")

local M = {}

local SEP      = " │ "
local NS       = vim.api.nvim_create_namespace("GrannosRowDetail")
local NAME_MAX = 32
local TABSTOP  = 4

--- Per-buffer statuscolumn state: `cells[lnum]` is the text drawn beside that
--- buffer line's first screen row, `wrap_cell` beside every wrapped row.
--- @type table<integer, { cells: string[], wrap_cell: string }>
local state = {}

--- Return the text of a cell and the highlight group it renders in.
--- @param cell any
--- @return string text, string|nil group
local function cell_text(cell)
  if cell == vim.NIL then return "NULL", "GrannosNull" end
  if cell == nil then return "", nil end
  if type(cell) == "table" then
    if cell.type == "lob" then return tostring(cell.text), "GrannosLob" end
    if cell.type == "special_float" then return tostring(cell.text), nil end
    local ok, json = pcall(vim.json.encode, cell)
    return ok and json or vim.inspect(cell), nil
  end
  return tostring(cell), nil
end

--- Truncate `s` to `width` display columns, marking the cut with an ellipsis.
--- @param s     string
--- @param width integer
--- @return string
local function truncate(s, width)
  if vim.fn.strdisplaywidth(s) <= width then return s end
  local out = ""
  for _, ch in ipairs(vim.fn.split(s, [[\zs]])) do
    if vim.fn.strdisplaywidth(out .. ch) > width - 1 then break end
    out = out .. ch
  end
  return out .. "…"
end

--- Escape `%` for a statusline-format string.
--- @param s string
--- @return string
local function fmt_escape(s)
  return (s:gsub("%%", "%%%%"))
end

--- Lay one row out as buffer lines (the values) and the statuscolumn cell
--- beside each line (the names and borders).
--- @param columns string[]  column names, in display order
--- @param row     any[]     cell values, parallel to `columns`
--- @return { lines: string[], hls: DetailHlRule[], cells: string[], wrap_cell: string, gutter: integer, rules: integer[] }
function M.layout(columns, row)
  local name_w = 1
  for _, name in ipairs(columns) do name_w = math.max(name_w, vim.fn.strdisplaywidth(name)) end
  name_w = math.min(name_w, NAME_MAX)

  local blank     = string.rep(" ", name_w)
  local border    = "%#GrannosBorder#" .. SEP
  local wrap_cell = blank .. border
  local sep_cell  = "%#GrannosBorder#" .. string.rep("─", name_w + 1) .. "┼─"

  local lines, hls, cells, rules = {}, {}, {}, {}
  for i, name in ipairs(columns) do
    if i > 1 then
      lines[#lines + 1] = ""
      cells[#lines] = sep_cell
      rules[#rules + 1] = #lines - 1
    end
    local label = truncate(name, name_w)
    label = label .. string.rep(" ", name_w - vim.fn.strdisplaywidth(label))

    local text, group = cell_text(row[i])
    local value = vim.split(text:gsub("\r\n", "\n"), "\n", { plain = true })
    for j, l in ipairs(value) do
      lines[#lines + 1] = l
      cells[#lines] = j == 1 and ("%#GrannosHeaderRow#" .. fmt_escape(label) .. border) or wrap_cell
      if group then hls[#hls + 1] = { group, #lines - 1, 0, -1 } end
    end
  end
  return { lines = lines, hls = hls, cells = cells, wrap_cell = wrap_cell,
           gutter = name_w + vim.fn.strdisplaywidth(SEP), rules = rules }
end

--- 'statuscolumn' expression for a row-detail window: the field name beside
--- a value's first line, the border beside its other and wrapped rows, a rule
--- beside the empty line between fields.
--- @return string
function M.statuscolumn()
  local win = vim.g.statusline_winid
  local s   = state[vim.api.nvim_win_get_buf(win)]
  if not s then return "" end
  if vim.v.virtnum ~= 0 then return s.wrap_cell end
  return s.cells[vim.v.lnum] or s.wrap_cell
end

--- Screen rows `lines` take when wrapped to `width` display columns.
--- @param lines string[]
--- @param width integer
--- @return integer
local function wrapped_height(lines, width)
  local rows = 0
  for _, l in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(l, 0)
    rows = rows + math.max(1, math.ceil(w / math.max(1, width)))
  end
  return rows
end

--- Window geometry for the float: as wide as its longest value line needs, up
--- to 90% of the editor, and as tall as its wrapped content, up to 85%. Given
--- the float's window, the content height is what Neovim actually wraps it to
--- ('linebreak' breaks at word boundaries, so it can take more rows than a
--- character count says); without one it is estimated.
--- @param lay table         from M.layout
--- @param win integer|nil   the float, once open and sized to its width
--- @return { row: integer, col: integer, width: integer, height: integer }
local function geometry(lay, win)
  local ew, eh = vim.o.columns, vim.o.lines
  local longest = 0
  for _, l in ipairs(lay.lines) do longest = math.max(longest, vim.fn.strdisplaywidth(l, 0)) end
  local width = math.min(math.max(math.floor(ew * 0.90), 20), math.max(60, lay.gutter + longest + 1))
  local content
  if win and vim.api.nvim_win_text_height then
    content = vim.api.nvim_win_text_height(win, {}).all
  else
    content = wrapped_height(lay.lines, width - lay.gutter)
  end
  local height = math.min(math.max(math.floor(eh * 0.85), 3), content)
  return {
    width  = width,
    height = height,
    col    = math.max(0, math.floor((ew - width - 2) / 2)),
    row    = math.max(0, math.floor((eh - height - 2) / 2)),
  }
end

--- Open a float showing one result row as a vertical table, every column of
--- it at first. With `selected`, `a` toggles between those columns (the
--- results pane's selection) and every column.
--- @param columns  string[]        every column name, in result order
--- @param row      any[]           cell values, parallel to `columns`
--- @param title    string          window title
--- @param selected integer[]|nil   indices into `columns` the results pane shows, in its order
function M.open(columns, row, title, selected)
  local restore_origin = pane.capture_origin()
  local show_all = true

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].tabstop   = TABSTOP

  --- The layout of the columns currently shown, and the title naming them.
  --- @return table lay, string win_title
  local function current()
    if show_all or not selected then
      local suffix = selected and (" · all %d columns"):format(#columns) or ""
      return M.layout(columns, row), " " .. title .. suffix .. " "
    end
    local cols, vals = {}, {}
    for i, idx in ipairs(selected) do cols[i], vals[i] = columns[idx], row[idx] end
    return M.layout(cols, vals), (" %s · %d/%d selected columns "):format(title, #selected, #columns)
  end

  --- Write `lay` into the buffer and the statuscolumn state.
  --- @param lay table  from M.layout
  local function fill(lay)
    pane.apply(buf, lay.lines, lay.hls)
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    for _, r in ipairs(lay.rules) do
      vim.api.nvim_buf_set_extmark(buf, NS, r, 0, {
        virt_text = { { string.rep("─", 1000), "GrannosBorder" } }, virt_text_pos = "overlay",
      })
    end
    state[buf] = { cells = lay.cells, wrap_cell = lay.wrap_cell }
  end

  local lay, win_title = current()
  fill(lay)

  local g   = geometry(lay)
  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = g.row, col = g.col,
    width     = g.width, height = g.height,
    style     = "minimal", border = "rounded",
    title     = win_title,
    title_pos = "center",
  })
  vim.api.nvim_win_set_hl_ns(win, hl.NS_ID)
  local wo = vim.wo[win]
  wo.wrap         = true
  wo.linebreak    = true
  wo.list         = false
  wo.number       = true  -- the statuscolumn only draws while a number column would
  wo.numberwidth  = 1
  wo.statuscolumn = "%!v:lua.require'grannos.ui.row_detail'.statuscolumn()"

  --- Fit the float to the editor and to its content as wrapped at its width.
  local function fit()
    vim.api.nvim_win_set_config(win, vim.tbl_extend("force", { relative = "editor" }, geometry(lay)))
    vim.api.nvim_win_set_config(win, vim.tbl_extend("force", { relative = "editor" }, geometry(lay, win)))
  end
  fit()

  --- Close the float and return the user where they came from.
  local function close()
    pcall(vim.api.nvim_win_close, win, true)
    restore_origin()
  end

  --- Switch between every column and the results pane's selection.
  local function toggle_columns()
    show_all = not show_all
    lay, win_title = current()
    fill(lay)
    vim.api.nvim_win_set_config(win, { title = win_title, title_pos = "center" })
    pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
  end

  local keymaps = {}
  --- Map `lhs` in the float and list it in the `g?` help.
  --- @param lhs  string
  --- @param fn   fun()
  --- @param desc string
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
    keymaps[#keymaps + 1] = { lhs = lhs, desc = desc, group = "" }
  end
  if selected then map("a", toggle_columns, "Toggle all columns / the results pane's selected columns") end
  map("q",     close, "Close")
  map("<Esc>", close, "Close")
  map("g?",    function() Buffer.render_help_float(keymaps) end, "Show this help")

  local aug = vim.api.nvim_create_augroup("GrannosRowDetail_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = aug,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then fit() end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug, pattern = tostring(win), once = true,
    callback = function()
      state[buf] = nil
      vim.api.nvim_del_augroup_by_id(aug)
    end,
  })
end

return M
