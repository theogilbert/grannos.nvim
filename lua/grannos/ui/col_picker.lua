-- Floating column checklist for the results pane: common.columns in
-- grannos's colours. See common.columns for its keys.
local hl = require("grannos.hl")

local M = {}

local ns_id = vim.api.nvim_create_namespace("grannos_col_picker")

--- Open the column picker.
--- @param all_cols  string[]  all column names in original order
--- @param vis_cols  string[]  currently visible column names, in display order
--- @param on_change fun(selected: string[])  called live on every change
function M.open(all_cols, vis_cols, on_change)
  return require("common.columns").open(all_cols, vis_cols, on_change, {
    name   = "grannos",
    hl     = { shown = "GrannosColumnShown", hidden = "GrannosColumnHidden" },
    ns     = ns_id,
    win_ns = hl.NS_ID,
  })
end

return M
