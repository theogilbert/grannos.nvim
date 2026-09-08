--- In-flight indicator for symbol lookups (`explore.find` / `explore.describe`
--- driven by the hover and goto keys).
---
--- Deliberately quiet: an animated braille spinner and a short label as dim
--- virtual text at the end of the line the symbol sits on. It costs no screen
--- space, is anchored to the thing being looked up, and leaves no trace in
--- `:messages` — a lookup that resolves quickly should be barely noticed, while
--- one waiting on a slow catalog says so where the user is already looking.
---
--- Marks are extmarks, so they follow the line through edits, and several
--- lookups can be outstanding at once. Every `start` must be matched by a
--- `stop`; `reset` exists for teardown, when the requests they track will never
--- answer.
local Spinner = require("grannos.ui.spinner")

local M = {}

--- @class SymbolBusyToken
--- @field bufnr   integer  buffer the extmark lives in
--- @field mark_id integer  extmark id, reused on every frame
--- @field label   string   text shown after the spinner glyph

local NS     = vim.api.nvim_create_namespace("GrannosSymbolBusy")
local active = {}  --- @type table<SymbolBusyToken, true>

--- Redraw one token's virtual text at the current spinner frame.
--- @param token SymbolBusyToken
--- @param glyph string
local function draw(token, glyph)
  if not vim.api.nvim_buf_is_valid(token.bufnr) then return end
  local pos = vim.api.nvim_buf_get_extmark_by_id(token.bufnr, NS, token.mark_id, {})
  local row = pos[1]
  if not row then return end
  vim.api.nvim_buf_set_extmark(token.bufnr, NS, row, 0, {
    id           = token.mark_id,
    virt_text    = { { ("  %s %s"):format(glyph, token.label), "GrannosExplorerDim" } },
    virt_text_pos = "eol",
    hl_mode      = "combine",
  })
end

-- Forward-declared so the tick callback can reach the spinner it belongs to.
local spinner
spinner = Spinner.new(function()
  local glyph = spinner:glyph()
  for token in pairs(active) do draw(token, glyph) end
end)

--- Show the indicator on `row` of `bufnr` and start animating it.
--- @param bufnr integer
--- @param row   integer  0-indexed
--- @param label string   what is being waited on, e.g. "finding users"
--- @return SymbolBusyToken|nil  nil when the buffer is gone; safe to pass to `stop`
function M.start(bufnr, row, label)
  if not vim.api.nvim_buf_is_valid(bufnr) then return nil end
  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, NS, row, 0, {})
  local token   = { bufnr = bufnr, mark_id = mark_id, label = label }
  active[token] = true
  spinner:start()
  draw(token, spinner:glyph())
  return token
end

--- Remove `token`'s indicator and release its hold on the spinner.
--- A no-op for nil or an already-stopped token, so callers can stop
--- unconditionally on every path out of a request.
--- @param token SymbolBusyToken|nil
function M.stop(token)
  if not token or not active[token] then return end
  active[token] = nil
  if vim.api.nvim_buf_is_valid(token.bufnr) then
    vim.api.nvim_buf_del_extmark(token.bufnr, NS, token.mark_id)
  end
  spinner:stop()
end

--- Drop every outstanding indicator (backend teardown: nothing will answer).
function M.reset()
  for token in pairs(active) do
    if vim.api.nvim_buf_is_valid(token.bufnr) then
      vim.api.nvim_buf_del_extmark(token.bufnr, NS, token.mark_id)
    end
  end
  active = {}
  spinner:reset()
end

return M
