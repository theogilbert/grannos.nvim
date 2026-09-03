--- nvim-cmp source, so completion fires as you type instead of on
--- |i_CTRL-X_CTRL-O|.
---
--- A native source rather than `cmp-omni` because the two disagree about who
--- owns the popup. The omnifunc path refreshes itself with `vim.fn.complete()`
--- when a listing arrives, which cmp neither sees nor honours — so through
--- `cmp-omni` a cold lookup shows an empty menu and stays empty until the next
--- keystroke. cmp has its own vocabulary for exactly this (`isIncomplete`), and
--- this source speaks it.
local cache      = require("grannos.completion.cache")
local completion = require("grannos.completion")

local M = {}

--- Source name to list in cmp's `sources`.
M.NAME = "grannos"

-- Our single-letter 'kind' column, mapped to cmp's LSP kinds so the menu shows
-- a familiar icon per candidate.
local KINDS = {
  t = "Struct",    -- table or view
  s = "Module",    -- schema
  c = "Field",     -- column
  a = "Variable",  -- FROM/JOIN alias
}

--- Convert one omnifunc-shaped candidate into a cmp item.
--- @param item table  { word, kind, menu }
--- @return table
local function cmp_item(item)
  local lsp = require("cmp.types").lsp
  return {
    label  = item.word,
    kind   = lsp.CompletionItemKind[KINDS[item.kind] or "Text"],
    detail = item.menu,
  }
end

local source = {}

--- Only offer candidates in a buffer that has a connection.
--- @return boolean
function source:is_available()
  return completion.conn_id(vim.api.nvim_get_current_buf()) ~= nil
end

--- @return string
function source:get_debug_name()
  return M.NAME
end

--- "." must trigger a request: after `alias.` there is no word character for
--- cmp's own keyword matching to fire on, and that is exactly the position
--- where the qualified column list is most wanted.
--- @return string[]
function source:get_trigger_characters()
  return { "." }
end

--- Return candidates for the cursor position.
---
--- `isIncomplete` is set while any listing is still on its way, which asks cmp
--- to come back rather than cache a half-answer. The re-request is not left to
--- the user's next keystroke: the arrival itself asks cmp to complete again, so
--- a menu opened on a cold cache fills in on its own.
--- @param params   table  cmp completion params
--- @param callback fun(response: table)
function source:complete(params, callback)
  local bufnr   = vim.api.nvim_get_current_buf()
  local conn_id = completion.conn_id(bufnr)
  if not conn_id then
    callback({ items = {}, isIncomplete = false })
    return
  end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  -- No `base`: cmp filters and ranks the list itself.
  local raw = completion.candidates_at(bufnr, row - 1, col, "", function()
    -- Ask cmp for a fresh cycle, but only while the cursor still sits where
    -- this request was made — otherwise the user has moved on.
    vim.schedule(function()
      local r, c = unpack(vim.api.nvim_win_get_cursor(0))
      if r ~= row or c ~= col then return end
      if not vim.fn.mode():match("^i") then return end
      local ok, cmp = pcall(require, "cmp")
      if ok and cmp.visible() then cmp.complete() end
    end)
  end)

  callback({ items = vim.tbl_map(cmp_item, raw), isIncomplete = cache.is_fetching(conn_id) })
end

--- Register the source with nvim-cmp, if it is installed.
--- Safe to call when cmp is absent; it simply does nothing.
--- @return boolean  whether the source was registered
function M.setup()
  local ok, cmp = pcall(require, "cmp")
  if not ok then return false end
  cmp.register_source(M.NAME, source)
  return true
end

--- The source table itself, for a user who prefers to register it by hand.
M.source = source

return M
