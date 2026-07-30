-- Opens explore.download content (base64) in a scratch buffer for inspection.
-- Shared by the explorer (S3 objects, etc.) and — later — the results pane's
-- LOB-cell download flow.
local M = {}

--- Filetype fallbacks for common MIME types, used when `filename` has no
--- extension `vim.filetype.match` can key off (e.g. a bare S3 object key).
local CONTENT_TYPE_FT = {
  ["application/json"] = "json",
  ["text/yaml"]         = "yaml",
  ["application/yaml"]  = "yaml",
  ["text/xml"]          = "xml",
  ["application/xml"]   = "xml",
  ["text/html"]         = "html",
  ["text/csv"]          = "csv",
  ["text/markdown"]     = "markdown",
}

--- Open downloaded content in a new unnamed, listed buffer in a new tab, so the
--- user can inspect or `:w` it to a path of their choosing — mirrors
--- `ui/results.lua`'s export buffer, deliberately unnamed so `:w` always
--- prompts rather than silently writing to a path that happens to share the
--- object's basename.
---
--- Refuses (and notifies) content containing NUL bytes: Neovim's file-write
--- path swaps embedded NULs for newlines on save, which would silently
--- corrupt genuinely binary content on round-trip. Suggests the query
--- language's `cp`, which downloads straight to disk instead.
--- @param content_base64 string  base64-encoded content, as returned by explore.download
--- @param filename       string  suggested filename, used only for filetype detection
--- @param content_type   string  MIME type, used as a filetype fallback
function M.open(content_base64, filename, content_type)
  local ok, content = pcall(vim.base64.decode, content_base64)
  if not ok then
    vim.notify("grannos: failed to decode downloaded content", vim.log.levels.ERROR)
    return
  end
  if content:find("\0", 1, true) then
    vim.notify(
      "grannos: content looks binary — can't display it safely in a buffer. "
        .. "Use the query language's `cp` to download it to disk instead.",
      vim.log.levels.WARN
    )
    return
  end
  local lines = vim.split(content, "\n", { plain = true })
  local buf   = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local ft = vim.filetype.match({ filename = filename }) or CONTENT_TYPE_FT[content_type]
  if ft then vim.bo[buf].filetype = ft end
  vim.cmd("tab sbuffer " .. buf)
end

return M
