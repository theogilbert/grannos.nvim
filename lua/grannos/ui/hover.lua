-- The hover float near the cursor (common.hover): one at a time, gone on the
-- next move in the buffer it was opened over.
local M = {}

local hover = require("common.hover").new()

--- Close the current hover float if one is open.
function M.close()
  hover:close()
end

--- Return true if a hover float is currently visible.
--- @return boolean
function M.is_open()
  return hover:is_open()
end

--- Open a non-focusable hover float near the cursor displaying `lines`.
--- The float closes automatically when the cursor moves or `source_bufnr` is left.
--- @param lines        string[]  lines to display
--- @param source_bufnr integer   buffer to attach the autoclose autocmd to
--- @param opts table|nil
---   .hls   DetailHlRule[]|nil  positional highlights: { group, row, col_start, col_end }
---   .above boolean|nil         anchor the float above the cursor line (default: below)
function M.open(lines, source_bufnr, opts)
  opts = opts or {}
  local marks = {}
  for _, h in ipairs(opts.hls or {}) do
    -- col_end -1 is "to the end of the line".
    table.insert(marks, { h[2], h[3], h[4] ~= -1 and h[4] or nil, h[1] })
  end
  hover:open(lines, {
    buf = source_bufnr,
    marks = marks,
    above = opts.above,
    events = { "CursorMoved", "CursorMovedI", "BufLeave" },
  })
end

return M
