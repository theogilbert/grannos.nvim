-- Single-pane connection picker used by :DbAttach: search box on top, one row
-- per connection below — the same input+list float the query log uses, without
-- a preview pane (there is nothing to preview: the row already says everything
-- a connection is). The caller decides what the rows are and what selecting
-- one means; this module only lays them out, filters them and reports the pick.
local M = {}

local pane = require("grannos.ui.detail_pane")

local MIN_WIDTH = 32
local MAX_WIDTH = 72

--- @class ConnPickerRow
--- @field label string      row text as displayed (and matched against)
--- @field hl    string|nil  highlight group for the whole row

--- Content width wide enough for the longest row, clamped to the editor.
--- @param rows ConnPickerRow[]
--- @return integer
local function pick_width(rows)
  local w = MIN_WIDTH
  for _, row in ipairs(rows) do
    w = math.max(w, vim.fn.strdisplaywidth(row.label) + 4)
  end
  return math.min(w, MAX_WIDTH, math.max(MIN_WIDTH, vim.o.columns - 4))
end

--- Open the picker over `rows`. `on_select` receives the chosen row once the
--- float has closed; closing it any other way calls `on_cancel` (when given).
--- Does nothing when there are no rows.
--- @param opts { rows: ConnPickerRow[], title: string, on_select: fun(row: ConnPickerRow), on_cancel: fun()|nil }
function M.open(opts)
  local rows = opts.rows
  if #rows == 0 then return end
  local selected = nil

  local width  = pick_width(rows)
  local list_h = math.min(#rows, math.max(3, math.floor(vim.o.lines * 0.5)))
  -- Visual height: 1(top border) + 1(input) + 1(shared border) + list_h + 1(bottom).
  local vis_h  = list_h + 4
  local row0   = math.max(0, math.floor((vim.o.lines   - vis_h)        / 2))
  local col0   = math.max(0, math.floor((vim.o.columns - (width + 2))  / 2))

  local handle
  handle = pane.open_search_list({
    items       = rows,
    title       = opts.title,
    row0        = row0, col0 = col0, width = width, list_height = list_h,
    get_label   = function(row) return row.label end,
    get_row_hl  = function(row) return row.hl end,
    empty_msg   = function() return "(no matching connection)" end,
    on_change   = function() end,
    on_close    = function()
      if selected then
        -- The submit keymap has a `stopinsert` pending that only takes effect
        -- once it returns. Defer the callback past it: a vim.ui.input opened
        -- synchronously here (the password prompt) would otherwise start in
        -- insert mode and be torn down by that InsertLeave immediately.
        vim.schedule(function() opts.on_select(selected) end)
      elseif opts.on_cancel then opts.on_cancel() end
    end,
    on_submit   = function(row)
      if not row then return end
      selected = row
      handle.close(true)
    end,
  })
end

return M
