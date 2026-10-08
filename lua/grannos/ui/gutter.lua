local M = {}

--- @class GutterHandle
--- @field bufnr   integer  buffer the extmark lives in
--- @field mark_id integer  extmark id returned by nvim_buf_set_extmark

local NS
local running = {}  -- [bufnr][mark_id] = request_id

local ICON_RUNNING = "\xEE\xA9\xB7"  -- U+EA77
local ICON_SUCCESS = "\xEE\xAA\xB2"  -- U+EAB2
local ICON_ERROR   = "\xEE\xAA\xB8"  -- U+EAB8

--- Create the extmark namespace used by all gutter marks.
function M.setup()
  NS = vim.api.nvim_create_namespace("GrannosGutter")
end

--- Return the 0-indexed row of `mark_id` in `bufnr`, or nil when not found.
--- @param bufnr   integer
--- @param mark_id integer
--- @return integer|nil
local function get_mark_row(bufnr, mark_id)
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, NS, mark_id, {})
  return pos[1]
end

--- Replace the sign text and highlight of an existing extmark handle.
--- @param handle GutterHandle|nil
--- @param icon   string
--- @param hl     string  highlight group name
local function replace(handle, icon, hl)
  if not handle or not vim.api.nvim_buf_is_valid(handle.bufnr) then return end
  local row = get_mark_row(handle.bufnr, handle.mark_id)
  if not row then return end
  vim.api.nvim_buf_set_extmark(handle.bufnr, NS, row, 0, {
    id            = handle.mark_id,
    sign_text     = icon,
    sign_hl_group = hl,
    priority      = 100,
  })
end

--- Replace any existing mark on `line` with the running icon and return a handle.
--- @param bufnr integer
--- @param line  integer  0-indexed
--- @return GutterHandle
function M.show_running(bufnr, line)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, NS, {line, 0}, {line, -1}, {})) do
    vim.api.nvim_buf_del_extmark(bufnr, NS, m[1])
  end
  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, NS, line, 0, {
    sign_text     = ICON_RUNNING,
    sign_hl_group = "GrannosQueryRunning",
    priority      = 100,
  })
  return { bufnr = bufnr, mark_id = mark_id }
end

--- Remove every finished mark (success or error) on lines `first`..`last`
--- (0-indexed, inclusive), so a batch run over them shows no stale result
--- while its statements wait their turn. A mark still tracking a running
--- request is kept: its query is in flight, and cancel finds it by its mark.
--- @param bufnr integer
--- @param first integer
--- @param last  integer
function M.clear_range(bufnr, first, last)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local by_buf = running[bufnr] or {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, NS, { first, 0 }, { last, -1 }, {})) do
    if not by_buf[m[1]] then vim.api.nvim_buf_del_extmark(bufnr, NS, m[1]) end
  end
end

--- Update the gutter mark to the success icon.
--- @param handle GutterHandle|nil
function M.show_success(handle)
  replace(handle, ICON_SUCCESS, "GrannosQuerySuccess")
end

--- Update the gutter mark to the error icon.
--- @param handle GutterHandle|nil
function M.show_error(handle)
  replace(handle, ICON_ERROR, "GrannosQueryError")
end

--- Associate a backend request id with a gutter mark handle.
--- @param handle     GutterHandle|nil
--- @param request_id integer|nil
--- @param end_line   integer|nil  0-indexed last line of the query in the source buffer
function M.register_request(handle, request_id, end_line)
  if not handle or not request_id then return end
  running[handle.bufnr] = running[handle.bufnr] or {}
  running[handle.bufnr][handle.mark_id] = { id = request_id, end_line = end_line }
end

--- Remove the request-id association for a gutter mark handle.
--- @param handle GutterHandle|nil
function M.unregister_request(handle)
  if not handle then return end
  local by_buf = running[handle.bufnr]
  if by_buf then by_buf[handle.mark_id] = nil end
end

--- Return the request_id of a running query whose range covers `cursor_line` (0-indexed), or nil.
--- @param bufnr        integer
--- @param cursor_line  integer  0-indexed
--- @return integer|nil
function M.find_request_covering_line(bufnr, cursor_line)
  local by_buf = running[bufnr]
  if not by_buf then return nil end
  for mark_id, entry in pairs(by_buf) do
    local start_line = get_mark_row(bufnr, mark_id)
    if start_line and start_line <= cursor_line then
      if not entry.end_line or cursor_line <= entry.end_line then
        return entry.id
      end
    end
  end
  return nil
end

return M
