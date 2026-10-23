-- Shared window helpers for grannos's sidebar panels.
local M = {}

local SIDEBAR_WIDTH = 35

--- Open `buf` in a vertical sidebar split and apply the shared panel chrome.
--- Without `host` the split spans the whole screen height on `side`; with it,
--- only `host` is split, the sidebar taking `side` of that window alone.
--- @param buf  integer
--- @param side "left"|"right"
--- @param host integer|nil  window to split
--- @return integer winid  the newly created (and focused) window
function M.open_sidebar(buf, side, host)
  local win
  if host then
    win = vim.api.nvim_open_win(buf, true, { split = side, win = host, width = SIDEBAR_WIDTH })
  else
    local anchor = side == "left" and "topleft" or "botright"
    vim.cmd(anchor .. " " .. SIDEBAR_WIDTH .. "vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  end
  vim.api.nvim_set_option_value("number",     false,   { win = win, scope = "local" })
  vim.api.nvim_set_option_value("signcolumn", "no",    { win = win, scope = "local" })
  vim.api.nvim_set_option_value("fillchars",  "eob: ", { win = win, scope = "local" })
  vim.api.nvim_set_option_value("wrap",       false,   { win = win, scope = "local" })
  vim.api.nvim_set_option_value("winfixwidth", true,  { win = win, scope = "local" })
  return win
end

-- Window-local options a grannos panel overrides, restored to their global
-- values when a panel window is turned back into an ordinary one.
local PANEL_OPTIONS = {
  "number", "signcolumn", "fillchars", "wrap", "winfixwidth", "winfixheight", "winbar", "cursorline",
}

--- Whether `buf` is one of grannos' own panel buffers.
--- @param buf integer
--- @return boolean
local function is_panel_buf(buf)
  return vim.startswith(vim.bo[buf].filetype, "grannos_")
    or vim.startswith(vim.api.nvim_buf_get_name(buf), "grannos://")
end

--- Return the most recently used listed buffer that is no grannos panel,
--- creating an empty one when there is none — what `:bdelete` would show next.
--- @return integer
local function fallback_buf()
  local best
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    if not is_panel_buf(info.bufnr) and (not best or info.lastused > best.lastused) then best = info end
  end
  return best and best.bufnr or vim.api.nvim_create_buf(true, false)
end

--- Whether closing the window that showed `buf` was a plain window close
--- (`:q`) rather than the side effect of deleting `buf` (`:bd`), which
--- closes every window showing it before the buffer goes.
--- @param buf integer
--- @return boolean
function M.closed_by_quit(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted
end

--- Close the panel windows `wins`. When nothing else would be left in their
--- tab — the query window they were docked to is gone and they are all that
--- remain — one is kept rather than failing on the last window: with `quit`,
--- it is quit like `:q` on a last window (closing the tab, or Neovim), and
--- otherwise, or when that is refused, it becomes an ordinary window showing
--- the most recent buffer, as `:bdelete` leaves one.
--- @param wins integer[]
--- @param quit boolean  the query window was closed (`:q`), not its buffer deleted
function M.close_panels(wins, quit)
  local closing, keep = {}, nil
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_is_valid(w) then closing[w] = true; keep = keep or w end
  end
  if not keep then return end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(keep))) do
    if not closing[w] and vim.api.nvim_win_get_config(w).relative == "" then
      keep = nil
      break
    end
  end
  if keep then closing[keep] = nil end
  for w in pairs(closing) do pcall(vim.api.nvim_win_close, w, true) end
  if not keep then return end

  if quit then
    vim.api.nvim_set_current_win(keep)
    if pcall(vim.cmd, "quit") then return end
  end
  vim.api.nvim_win_set_buf(keep, fallback_buf())
  for _, opt in ipairs(PANEL_OPTIONS) do
    vim.api.nvim_set_option_value(opt, vim.api.nvim_get_option_value(opt, { scope = "global" }), { win = keep, scope = "local" })
  end
  vim.api.nvim_win_set_hl_ns(keep, 0)
end

return M
