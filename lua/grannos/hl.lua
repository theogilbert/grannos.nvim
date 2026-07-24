-- Highlight groups and namespaces for grannos.
-- Ported and adapted from nvim-dap-df/lua/nvim-dap-df-pane/hl.lua.
local M = {}

local BORDER_FG    = "#555555"
local HEADER_FG    = "#9CDCFE"
local ERROR_FG     = "#CA2722"
local TRUNCATED_FG = "#666666"
local ROW_COUNT_FG = "#7F8490"
local CONN_FG      = "#7DB88A"
local NULL_FG      = "#6B7280"
local LOB_FG       = "#6B7280"
local HELP_FG      = "#4B9CD3"
local THOUSANDS_FG = "#767676"
local SCROLLBAR_FG = "#888888"
local EDIT_BG      = "#1F3D2B"  -- subtle green, echoing the common insert-mode statusline color

local DIAGRAM_ROOT_TABLE_FG = "#DAA520" -- gold, reserved for a diagram's source/root table

-- Muted, low-saturation colors cycled across non-root tables in a schema diagram,
-- so each table's box reads as visually distinct without competing with the
-- gold reserved for the diagram's root/source table. Hues are NOT evenly spaced
-- around the wheel by degree — HSL hue angle is not perceptually uniform (e.g.
-- blue/purple hues compress much more tightly in perceived difference per
-- degree than others do), so equal-degree spacing reliably produces close-
-- looking pairs despite "even" spacing (this palette previously had violet and
-- magenta only 8.3 apart in CIE Lab distance despite a 26° hue gap). These 10
-- were instead chosen by a greedy farthest-point search over CIE Lab distance
-- at fixed saturation/lightness, also kept away from the root table's gold, so
-- the worst-case pair here is ~14 apart in Lab (vs. 8.3 before).
local DIAGRAM_TABLE_FG = {
  "#8181BB", -- blue
  "#81BB90", -- green
  "#BB8E81", -- rust
  "#81ADBB", -- sky
  "#BB81A4", -- pink
  "#BBB281", -- mustard
  "#81BBAF", -- teal
  "#8196BB", -- cornflower
  "#AB81BB", -- purple
  "#A2BB81", -- olive
}

--- Highlight group for a diagram's source/root table (the one `explore.diagram`
--- was requested for) — gold and bold, distinct from GrannosExplorerTable so
--- this styling stays scoped to the diagram view instead of also affecting
--- table names in the sidebar/other floats.
M.DIAGRAM_ROOT_TABLE = "GrannosDiagramRootTable"

--- Ordered highlight group names backing DIAGRAM_TABLE_FG, for callers that need
--- to cycle through them (e.g. assigning one per table in a schema diagram).
M.DIAGRAM_TABLE_PALETTE = {}
for i = 1, #DIAGRAM_TABLE_FG do
  M.DIAGRAM_TABLE_PALETTE[i] = "GrannosDiagramTable" .. i
end

--- Build the table of highlight group definitions.
--- @return table<string, table>
local function build_highlights()
  local highlights = {
    GrannosBorder    = { fg = BORDER_FG },
    GrannosHeaderRow = { fg = HEADER_FG, bold = true },
    GrannosError     = { fg = ERROR_FG },
    GrannosTruncated = { fg = TRUNCATED_FG, bold = true },
    GrannosRowCount  = { fg = ROW_COUNT_FG },
    GrannosNull      = { fg = NULL_FG, italic = true },
    GrannosLob       = { fg = LOB_FG, italic = true },
    GrannosHelp      = { fg = HELP_FG, italic = true },
    GrannosThousandsSeparator = { fg = THOUSANDS_FG },
    GrannosScrollbarThumb     = { fg = SCROLLBAR_FG },
    [M.DIAGRAM_ROOT_TABLE]      = { fg = DIAGRAM_ROOT_TABLE_FG, bold = true },
  }
  for i, group in ipairs(M.DIAGRAM_TABLE_PALETTE) do
    highlights[group] = { fg = DIAGRAM_TABLE_FG[i] }
  end
  return highlights
end

--- Create namespaces and define all highlight groups; re-called on ColorScheme.
local function setup_highlights()
  M.NS_ID            = vim.api.nvim_create_namespace("GrannosNs")
  M.TRUNCATION_NS_ID = vim.api.nvim_create_namespace("GrannosTruncationNs")
  for group, opts in pairs(build_highlights()) do
    vim.api.nvim_set_hl(M.NS_ID, group, opts)
  end
  -- Defined globally so it works in any buffer's extmarks; default = true allows user override.
  vim.api.nvim_set_hl(0, "GrannosConnection",          { fg = CONN_FG,    italic = true, default = true })
  vim.api.nvim_set_hl(0, "GrannosConnError",           { fg = ERROR_FG,   default = true })
  vim.api.nvim_set_hl(0, "GrannosQueryRunning",        { fg = "#E5C07B",  default = true })
  vim.api.nvim_set_hl(0, "GrannosQuerySuccess",        { fg = "#98C379",  default = true })
  vim.api.nvim_set_hl(0, "GrannosQueryError",          { fg = "#CA2722",  default = true })
  vim.api.nvim_set_hl(0, "GrannosQueryFlash",          { link = "Visual", default = true })
  vim.api.nvim_set_hl(0, "GrannosExplorerDatabase",    { fg = "#98C379",  default = true })
  vim.api.nvim_set_hl(0, "GrannosExplorerSchema",      { fg = "#E5C07B",  default = true })
  vim.api.nvim_set_hl(0, "GrannosExplorerTable",       { fg = "#61AFEF",  default = true })
  vim.api.nvim_set_hl(0, "GrannosExplorerColumn",      { fg = "#D19A66",  default = true })
  vim.api.nvim_set_hl(0, "GrannosExplorerView",        { fg = "#C678DD",  default = true })
  vim.api.nvim_set_hl(0, "GrannosExplorerCollection",  { fg = "#4EC9B0",  default = true })
  vim.api.nvim_set_hl(0, "GrannosExplorerIndex",       { fg = "#56B6C2",  default = true })
  vim.api.nvim_set_hl(0, "GrannosExplorerConstraint",  { fg = "#E06C75",  default = true })
  vim.api.nvim_set_hl(0, "GrannosExplorerGroup",       { fg = "#848D9E",  default = true })
  vim.api.nvim_set_hl(0, "GrannosExplorerDim",         { fg = "#6B7691",  default = true })
  -- Global (not NS_ID-scoped): applied via 'winhighlight' on windows that must
  -- NOT be linked to NS_ID via nvim_win_set_hl_ns, since that takes precedence
  -- over 'winhighlight' and would silently defeat it.
  vim.api.nvim_set_hl(0, "GrannosConnFormEdit",        { bg = EDIT_BG,    default = true })
end

--- Initialize namespaces, define highlights, and register a ColorScheme autocmd.
function M.setup()
  setup_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = setup_highlights })
end

return M
