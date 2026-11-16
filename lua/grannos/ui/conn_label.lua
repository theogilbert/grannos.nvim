-- A "Connected to <name>" label, right-aligned in the winbar of each window
-- whose buffer has an associated connection — or "Disconnected from <name>
-- (idle timeout)" once the backend closed it for inactivity (the next request
-- reconnects it). Being a row of its own, it never covers the buffer's text. The labels disappear when the association or the
-- window goes away, giving the window back the winbar it had before.
local M = {}

-- Every label starts with this, which is how a winbar is recognised as ours —
-- including one a split copied from a labelled window. It covers both the
-- GrannosConnection and GrannosConnectionIdle highlight groups.
local PREFIX = "%=%#GrannosConnection"

local labels  = {}                       -- [winid] -> { name = s, idle = b, prev = winbar before the label }
local resolve = function() return nil end -- bufnr -> connection name | nil, idle

--- The label's visible text.
--- @param name string
--- @param idle boolean|nil
--- @return string
local function label_text(name, idle)
  if idle then return "Disconnected from " .. name .. " (idle timeout)" end
  return "Connected to " .. name
end

--- Return the window-local 'winbar' of `winid`.
--- @param winid integer
--- @return string
local function get_winbar(winid)
  return vim.api.nvim_get_option_value("winbar", { win = winid, scope = "local" })
end

--- Set the window-local 'winbar' of `winid`.
--- @param winid integer
--- @param value string
local function set_winbar(winid, value)
  vim.api.nvim_set_option_value("winbar", value, { win = winid, scope = "local" })
end

--- Return true when `value` is a winbar this module set.
--- @param value string
--- @return boolean
local function is_label(value)
  return vim.startswith(value, PREFIX)
end

--- Remove the label from `winid`, if any, restoring the winbar it replaced.
--- A label copied into `winid` by a split is cleared back to the global winbar.
--- @param winid integer
function M.hide(winid)
  local entry = labels[winid]
  labels[winid] = nil
  if not vim.api.nvim_win_is_valid(winid) then return end
  if entry then
    set_winbar(winid, entry.prev)
  elseif is_label(get_winbar(winid)) then
    set_winbar(winid, vim.go.winbar)
  end
end

--- Show (replacing any existing) the connection label for `winid`.
--- @param winid integer
--- @param name  string        human-readable connection name
--- @param idle  boolean|nil   true when the backend closed the connection for inactivity
function M.show(winid, name, idle)
  -- What to restore: the winbar now, unless that is a label (ours, or one a
  -- split copied), in which case what this window had before it, else the global.
  local entry = labels[winid]
  local prev  = get_winbar(winid)
  if is_label(prev) then prev = entry and entry.prev or vim.go.winbar end
  local hl = idle and "Idle#" or "#"
  set_winbar(winid, PREFIX .. hl .. label_text(name, idle):gsub("%%", "%%%%"))
  labels[winid] = { name = name, idle = idle or nil, prev = prev }
end

--- Return the label text shown in `winid`, or nil when it has none.
--- @param winid integer
--- @return string|nil
function M.text(winid)
  local entry = labels[winid]
  return entry and label_text(entry.name, entry.idle)
end

--- Show or remove the label for `winid` based on its current buffer's connection.
--- @param winid integer
local function refresh(winid)
  if not vim.api.nvim_win_is_valid(winid) then return end
  -- Skip floating windows.
  if vim.api.nvim_win_get_config(winid).relative ~= "" then return end
  local name, idle = resolve(vim.api.nvim_win_get_buf(winid))
  idle = idle or nil
  if name then
    local entry = labels[winid]
    if not (entry and entry.name == name and entry.idle == idle and is_label(get_winbar(winid))) then
      M.show(winid, name, idle)
    end
  else
    M.hide(winid)
  end
end

--- Remove every label (called on backend teardown).
function M.clear_all()
  for winid in pairs(labels) do M.hide(winid) end
  labels = {}
end

--- Install the autocmds that keep labels in sync and set the buffer→name resolver.
--- @param resolve_fn fun(bufnr: integer): string|nil, boolean|nil  returns the connection name (or nil)
---                    and whether the backend closed it for inactivity
function M.setup(resolve_fn)
  resolve = resolve_fn
  local aug = vim.api.nvim_create_augroup("GrannosConnLabels", { clear = true })
  -- Show or hide the label whenever the buffer in a window changes.
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group    = aug,
    callback = function() refresh(vim.api.nvim_get_current_win()) end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group    = aug,
    callback = function(ev)
      for _, winid in ipairs(vim.fn.win_findbuf(ev.buf)) do refresh(winid) end
    end,
  })
  -- Forget the label entry when a window closes.
  vim.api.nvim_create_autocmd("WinClosed", {
    group    = aug,
    callback = function(ev) labels[tonumber(ev.match)] = nil end,
  })
end

return M
