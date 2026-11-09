-- Marks what `grannos.execute` would run from the cursor, in query buffers.
--
-- Only normal mode has such a target: a visual selection runs instead of the
-- statement, and text being inserted is not ready to run. So the mark goes away
-- in those modes, and when the cursor leaves the buffer or window.

local M = {}

local NS    = vim.api.nvim_create_namespace("GrannosStatementHl")
local GROUP = vim.api.nvim_create_augroup("GrannosStatementHl", { clear = true })

-- Below treesitter's default priority (100), so a colorscheme whose group sets
-- a foreground never recolours the query's syntax; the execute flash sits above.
local PRIORITY = 90

--- Remove the mark from `bufnr`.
--- @param bufnr integer
local function clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  end
end

--- Bring the mark on `bufnr` up to date with the cursor and mode.
--- @param bufnr   integer
--- @param resolve fun(bufnr: integer): SqlStatement|nil  what would run from the cursor
local function refresh(bufnr, resolve)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr then return end
  local mode = vim.api.nvim_get_mode().mode:sub(1, 1)
  -- A `:` typed from normal mode leaves the mark up until the command is done.
  if mode == "c" then return end
  clear(bufnr)
  if mode ~= "n" then return end
  local target = resolve(bufnr)
  if not target then return end
  vim.api.nvim_buf_set_extmark(bufnr, NS, target.start_row, target.start_col, {
    end_row  = target.end_row,
    end_col  = target.end_col,
    hl_group = "GrannosStatementCursor",
    priority = PRIORITY,
    strict   = false,
  })
end

--- Keep `bufnr` marked with what would run from the cursor, until `detach`.
--- Attaching again replaces the previous attachment.
--- @param bufnr   integer
--- @param resolve fun(bufnr: integer): SqlStatement|nil  what would run from the cursor
function M.attach(bufnr, resolve)
  M.detach(bufnr)
  vim.api.nvim_create_autocmd({ "CursorMoved", "TextChanged", "ModeChanged", "BufEnter", "WinEnter" }, {
    group    = GROUP,
    buffer   = bufnr,
    callback = function() refresh(bufnr, resolve) end,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group    = GROUP,
    buffer   = bufnr,
    callback = function() clear(bufnr) end,
  })
  refresh(bufnr, resolve)
end

--- Stop marking `bufnr` and remove its mark. No-op when it is not attached.
--- @param bufnr integer
function M.detach(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_clear_autocmds({ group = GROUP, buffer = bufnr })
  end
  clear(bufnr)
end

return M
