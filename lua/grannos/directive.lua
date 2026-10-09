-- Parses the grannos directive comment a query file may carry to name the
-- saved connection it should attach to when opened, e.g.
--
--   -- grannos: connection=analytics/prod
--   // grannos: connection=prod
--
-- Like a Vim modeline, it is looked for in the first and last few lines only,
-- and the comment leader is not checked, so one form works in every query
-- language. The value is a connection's display name: "group/name", or just
-- "name" for an ungrouped connection or one whose name is unique.
local M = {}

--- How many lines at each end of the buffer are searched for the directive.
M.SCAN_LINES = 5

--- Return the connection named by the directive on `line`, or nil when the
--- line carries none. A trailing block-comment closer (`*/`, `-->`) is not
--- part of the name.
--- @param line string
--- @return string|nil
function M.parse_line(line)
  local value = line:match("grannos:%s*connection%s*=%s*(.-)%s*$")
  if not value then return nil end
  value = vim.trim(value:gsub("%*/$", ""):gsub("%-%->$", ""))
  return value ~= "" and value or nil
end

--- Return the connection named by the first directive in `bufnr`'s first or
--- last SCAN_LINES lines, or nil when there is none.
--- @param bufnr integer
--- @return string|nil
function M.connection(bufnr)
  local count = vim.api.nvim_buf_line_count(bufnr)
  local head  = vim.api.nvim_buf_get_lines(bufnr, 0, math.min(M.SCAN_LINES, count), false)
  for _, line in ipairs(head) do
    local name = M.parse_line(line)
    if name then return name end
  end
  local tail_start = math.max(M.SCAN_LINES, count - M.SCAN_LINES)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, tail_start, count, false)) do
    local name = M.parse_line(line)
    if name then return name end
  end
  return nil
end

return M
