--- Shows that completion is waiting on the server.
---
--- Completion never blocks, so a popup opened on a cold cache is empty, or
--- partial, until the listing lands — which looks exactly like "nothing to
--- offer" unless something says otherwise. While any listing for the current
--- buffer's connection is in flight, the cursor line carries a spinner and
--- "fetching completions" as end-of-line virtual text, redrawn on each
--- spinner tick so it follows the cursor and disappears the moment the last
--- fetch lands. The popup menu draws below the cursor line, so the two never
--- cover each other.
local cache   = require("grannos.completion.cache")
local Spinner = require("grannos.ui.spinner")

local M = {}

local NS   = vim.api.nvim_create_namespace("GrannosCompletionFetch")
local TEXT = " fetching completions…"
local HL   = "GrannosCompletionFetch"

--- bufnr → connection id, or nil; set by `setup`.
local conn_id_for = function(_) return nil end

--- Buffer holding the mark on screen, if any.
local marked = nil

--- Remove the mark, if one is on screen.
local function clear()
  if marked and vim.api.nvim_buf_is_valid(marked) then
    vim.api.nvim_buf_clear_namespace(marked, NS, 0, -1)
  end
  marked = nil
end

local spinner

--- Draw the mark on the cursor line when the current buffer's connection has
--- a fetch in flight, and remove it otherwise.
local function draw()
  clear()
  local bufnr   = vim.api.nvim_get_current_buf()
  local conn_id = conn_id_for(bufnr)
  if not conn_id or not cache.is_fetching(conn_id) then return end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  vim.api.nvim_buf_set_extmark(bufnr, NS, row, 0, {
    virt_text     = { { spinner:glyph() .. TEXT, HL } },
    virt_text_pos = "eol",
  })
  marked = bufnr
end

spinner = Spinner.new(draw)

--- Start or stop the spinner for one fetch. Refcounted through the spinner,
--- so a burst of listings shows a single indicator until the last one lands.
--- @param _       any      connection id; the draw decides per buffer
--- @param started boolean
local function on_fetch(_, started)
  if started then spinner:start() else spinner:stop() end
  draw()
end

--- Return true while the indicator is on screen. For specs.
--- @return boolean
function M.is_shown()
  return marked ~= nil
end

--- Hook into the cache's fetch events.
--- @param resolve fun(bufnr: integer): any|nil  the connection id a buffer completes against
function M.setup(resolve)
  conn_id_for    = resolve
  cache.on_fetch = on_fetch
end

return M
