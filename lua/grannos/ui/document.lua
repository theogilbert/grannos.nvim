-- Single-item detail float for a RawDocument (an opaque text document, e.g.
-- a driver's running configuration file), opened by hovering a "document"
-- node in the explorer.
local M = {}

local pane = require("grannos.ui.detail_pane")
local ICON = "󰈙 "

--- Return the estimated rendered line count for a document detail view.
--- @param doc table  RawDocument
--- @return integer
local function estimate_lines(doc)
  return #vim.split(tostring(doc.content), "\n", { plain = true })
end

--- Populate `buf` with the raw content of `doc`, syntax-highlighted per its
--- `filetype` hint (normalized to a real Neovim filetype via vim.filetype.match,
--- since the hint is a free-form driver-supplied string, not guaranteed to
--- already be a valid Neovim filetype name).
--- @param buf integer
--- @param doc table  RawDocument
local function render(buf, doc)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(tostring(doc.content), "\n", { plain = true }))
  vim.bo[buf].modifiable = false
  if not pane.is_nil(doc.filetype) and doc.filetype ~= "" then
    vim.bo[buf].filetype = vim.filetype.match({ filename = "grannos." .. doc.filetype }) or doc.filetype
    pcall(vim.treesitter.start, buf)
  end
end

--- Open a single-document detail float.
--- @param doc  table       RawDocument as decoded from the server response
--- @param name string|nil  display name of the node this was described from
function M.open_single(doc, name)
  pane.open_single({
    item     = doc,
    title    = ICON .. (name or doc.filetype or "document"),
    render   = render,
    estimate = estimate_lines,
  })
end

return M
