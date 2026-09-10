-- Single-pane picker for choosing which open connection a buffer queries against.
-- Search box on top, the full connection list below — the same input+list float
-- the query log uses, without a preview pane (there is nothing to preview: the
-- row already says everything a connection is).
local M = {}

local connections = require("grannos.connections")
local pane        = require("grannos.ui.detail_pane")

local MIN_WIDTH = 32
local MAX_WIDTH = 72

--- @class ConnPickerItem
--- @field key     string   composite connection key
--- @field display string   human-readable connection name
--- @field label   string   row text, marker + display + driver label
--- @field current boolean  true when this is the buffer's current connection

--- Build the sorted item list for `conns`, marking `current_key`'s row.
--- @param conns       table<string, { driver_label: string|nil }>
--- @param current_key string|nil
--- @return ConnPickerItem[]
local function build_items(conns, current_key)
  local items = {}
  for key, conn in pairs(conns) do
    local display = connections.conn_display_name(key)
    local marker  = key == current_key and "● " or "  "
    local label   = marker .. display
    if conn and conn.driver_label then label = label .. "  (" .. conn.driver_label .. ")" end
    table.insert(items, { key = key, display = display, label = label, current = key == current_key })
  end
  table.sort(items, function(a, b) return a.display < b.display end)
  return items
end

--- Content width wide enough for the longest row, clamped to the editor.
--- @param items ConnPickerItem[]
--- @return integer
local function pick_width(items)
  local w = MIN_WIDTH
  for _, item in ipairs(items) do
    w = math.max(w, vim.fn.strdisplaywidth(item.label) + 4)
  end
  return math.min(w, MAX_WIDTH, math.max(MIN_WIDTH, vim.o.columns - 4))
end

--- Open the connection picker. `on_select` receives the chosen connection key
--- once the float has closed; cancelling calls nothing.
--- @param conns       table<string, { driver_label: string|nil }>  open connections by key
--- @param current_key string|nil  the caller's current connection, marked in the list
--- @param on_select   fun(key: string)
function M.open(conns, current_key, on_select)
  local items = build_items(conns, current_key)
  if #items == 0 then return end

  local width  = pick_width(items)
  local list_h = math.min(#items, math.max(3, math.floor(vim.o.lines * 0.5)))
  -- Visual height: 1(top border) + 1(input) + 1(shared border) + list_h + 1(bottom).
  local vis_h  = list_h + 4
  local row0   = math.max(0, math.floor((vim.o.lines   - vis_h)        / 2))
  local col0   = math.max(0, math.floor((vim.o.columns - (width + 2))  / 2))

  local handle
  handle = pane.open_search_list({
    items       = items,
    title       = " Assign connection ",
    row0        = row0, col0 = col0, width = width, list_height = list_h,
    get_label   = function(item) return item.label end,
    get_row_hl  = function(item) return item.current and "GrannosConnection" or nil end,
    empty_msg   = function() return "(no matching connection)" end,
    on_change   = function() end,
    on_submit   = function(item)
      if not item then return end
      handle.close(true)
      on_select(item.key)
    end,
  })
end

return M
