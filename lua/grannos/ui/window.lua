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
  vim.api.nvim_set_option_value("number",     false,   { win = win })
  vim.api.nvim_set_option_value("signcolumn", "no",    { win = win })
  vim.api.nvim_set_option_value("fillchars",  "eob: ", { win = win })
  vim.api.nvim_set_option_value("wrap",       false,   { win = win })
  vim.api.nvim_set_option_value("winfixwidth", true,  { win = win })
  return win
end

return M
