-- Two-pane float for choosing between the candidates explore.find returns for
-- an ambiguous symbol (e.g. a bare column name that exists on every joined
-- table). Left: the candidate paths, filterable. Right: the describe result for
-- the focused candidate, fetched lazily so opening the picker costs one request
-- per candidate actually looked at.
local M = {}

local client   = require("grannos.client")
local column   = require("grannos.ui.column")
local explorer = require("grannos.ui.explorer")
local pane     = require("grannos.ui.detail_pane")

--- @class SymbolCandidate
--- @field path    string[]       absolute explorer path, as returned by explore.find
--- @field conn_id any            connection to describe the path against
--- @field details any|nil        describe result once fetched (vim.NIL when the node has none)
--- @field err     string|nil     error text when the describe failed

--- The candidate currently synced into the right pane, so an in-flight describe
--- only redraws when its own candidate is still the focused one.
--- @type SymbolCandidate|nil
local current

--- Render the fetched describe result for `item` into `buf`.
--- Fields get the condensed column view; everything else goes through the
--- explorer's own entity renderer.
--- @param buf  integer
--- @param item SymbolCandidate
local function render_details(buf, item)
  local details = item.details
  if details == nil or details == vim.NIL then
    pane.apply(buf, { "  (nothing to describe)" }, { { "GrannosExplorerDim", 0, 0, -1 } })
    return
  end
  if details.type == "field" then
    local lines, hls = column.hover_lines(details)
    pane.apply(buf, lines, hls)
  else
    local node = { name = item.path[#item.path], type = "table" }
    local lines, hls = explorer.render_describe(details, node)
    pane.apply(buf, lines, hls)
  end
end

--- Describe `item`'s path and redraw `buf` when it is still the focused candidate.
--- @param buf  integer
--- @param item SymbolCandidate
local function fetch_details(buf, item)
  client.request("explore.describe", { connection_id = item.conn_id, path = item.path }, function(err, result)
    vim.schedule(function()
      if err then
        item.err = err
      else
        item.details = result and result.details
      end
      if current == item and vim.api.nvim_buf_is_valid(buf) then
        if item.err then
          pane.apply(buf, { "  " .. item.err }, { { "GrannosError", 0, 0, -1 } })
        else
          render_details(buf, item)
        end
      end
    end)
  end)
end

--- Populate the right pane for `item`, fetching its describe result on first view.
--- @param buf  integer
--- @param item SymbolCandidate
local function render(buf, item)
  current = item
  if item.err then
    pane.apply(buf, { "  " .. item.err }, { { "GrannosError", 0, 0, -1 } })
  elseif item.details ~= nil then
    render_details(buf, item)
  else
    pane.apply(buf, { "  Loading…" }, { { "GrannosExplorerDim", 0, 0, -1 } })
    fetch_details(buf, item)
  end
end

--- Open the candidate picker for an ambiguous symbol. `on_select` receives the
--- chosen path (the same shape explore.find returned) once the float has closed.
--- @param conn_id   any
--- @param paths     string[][]  candidate paths from explore.find
--- @param name      string      the symbol as it was written in the query, for the title
--- @param on_select fun(path: string[])
function M.open(conn_id, paths, name, on_select)
  local items = {}
  for _, path in ipairs(paths) do
    items[#items + 1] = { path = path, conn_id = conn_id }
  end
  current = nil

  pane.open_searchable_two_pane({
    items      = items,
    left_title = " " .. name .. " · " .. #items .. " matches ",
    get_label  = function(item) return table.concat(item.path, ".") end,
    get_title  = function(item) return item.path[#item.path] end,
    render     = render,
    estimate   = function() return 14 end,
    on_submit  = function(item) if item then on_select(item.path) end end,
  })
end

return M
