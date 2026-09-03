--- Client-side cache of explore-tree children, for completion.
---
--- Completion needs an answer within a keystroke, so it can never wait on a
--- round trip. Every lookup here is synchronous: it returns what is already
--- known, and starts a fetch for what isn't, calling `on_ready` when that
--- lands so the caller can refill the popup in place.
---
--- Only `explore.list` is ever sent. That is one catalog query per path on the
--- server (which caches it to disk permanently), and it never reads user table
--- data — unlike `explore.describe`, which additionally samples values from
--- every column. A completion popup must not cost that.
local client = require("grannos.client")

local M = {}

--- conn_id → { [path_key] = ExploreItem[] }
local items = {}
--- conn_id → { [path_key] = fun(items)[] }  callbacks waiting on an in-flight fetch
local pending = {}

--- Return the table key for `path` under `conn_id`.
--- @param path string[]
--- @return string
local function key_of(path)
  return table.concat(path, "\0")
end

--- Return the per-connection table in `store`, creating it when absent.
--- @param store table
--- @param conn_id any
--- @return table
local function bucket(store, conn_id)
  local b = store[conn_id]
  if not b then b = {}; store[conn_id] = b end
  return b
end

--- Return the cached children of `path`, or nil when they aren't known yet.
---
--- A nil return always means a fetch is now in flight: `on_ready` fires with
--- the items once it lands (never on the error path, where completion simply
--- has nothing to offer). Repeat calls for a path already being fetched queue
--- another callback rather than sending a second request, so a burst of
--- keystrokes produces exactly one query.
--- @param conn_id  any
--- @param path     string[]
--- @param on_ready fun(items: table[])|nil
--- @return table[]|nil
function M.children(conn_id, path, on_ready)
  if conn_id == nil then return nil end
  local key   = key_of(path)
  local known = bucket(items, conn_id)
  if known[key] then return known[key] end

  local waiting = bucket(pending, conn_id)
  if waiting[key] then
    if on_ready then table.insert(waiting[key], on_ready) end
    return nil
  end
  waiting[key] = on_ready and { on_ready } or {}

  client.request("explore.list", { connection_id = conn_id, path = path }, function(err, result)
    vim.schedule(function()
      local callbacks = waiting[key] or {}
      waiting[key] = nil
      if err then return end
      local list = (result and result.items) or {}
      bucket(items, conn_id)[key] = list
      for _, cb in ipairs(callbacks) do cb(list) end
    end)
  end)
  return nil
end

--- Return true when the connection's tree puts schemas above tables.
---
--- SQLite lists its tables at the root; every other SQL driver lists schemas
--- there. Nothing needs to be configured per driver — the root listing's own
--- item types say which shape this is. Returns nil until the root is known.
--- @param conn_id  any
--- @param on_ready fun()|nil
--- @return boolean|nil
function M.has_schemas(conn_id, on_ready)
  local root = M.children(conn_id, {}, on_ready and function() on_ready() end or nil)
  if not root then return nil end
  for _, item in ipairs(root) do
    if item.type == "schema" then return true end
  end
  return false
end

--- Return the columns of the table at `table_path`, or nil while fetching.
---
--- Every SQL driver names this group "columns", so the group path is assumed
--- rather than discovered — listing the table node first to find the group
--- would double the query count for every table completed against.
--- @param conn_id    any
--- @param table_path string[]
--- @param on_ready   fun(items: table[])|nil
--- @return table[]|nil
function M.columns(conn_id, table_path, on_ready)
  local path = vim.list_extend(vim.list_slice(table_path), { "columns" })
  return M.children(conn_id, path, on_ready)
end

--- Return true when any path is currently being fetched for `conn_id`.
--- Lets a completion engine mark its response incomplete, so it asks again
--- once the answer is in rather than settling for a partial list.
--- @param conn_id any
--- @return boolean
function M.is_fetching(conn_id)
  for _ in pairs(pending[conn_id] or {}) do return true end
  return false
end

--- Drop everything cached for `conn_id`, or for every connection when nil.
--- Called when a connection closes and when the user asks for a refresh, so a
--- re-listed tree is picked up rather than served from a stale copy.
--- @param conn_id any|nil
function M.invalidate(conn_id)
  if conn_id == nil then
    items, pending = {}, {}
    return
  end
  items[conn_id], pending[conn_id] = nil, nil
end

return M
