-- Persistence of per-connection session settings (the driver's session_params,
-- changed via session.set). The backend only ever holds these in memory, so
-- they would otherwise be lost with every backend restart and every Neovim
-- restart. This module remembers the last values the user submitted for each
-- saved connection and hands them back on reconnect, where init.lua replays
-- them with session.set right after the connect succeeds.
--
-- Storage: a single JSON file, $XDG_DATA_HOME/grannos/session_params.json,
-- nested like connections.json — [server][driver][group][name] = values —
-- so entries follow the same identity as the connection they belong to.
-- These are preferences: a missing or unreadable file is an empty store.
local M = {}

local connections = require("grannos.connections")

--- Override for the storage file path (tests point this at a temp file).
--- @type string|nil
M.file = nil

--- In-memory copy of the store, read from disk once per session.
--- @type table|nil
local cache = nil

--- Return the path of the JSON store file.
--- @return string
local function file_path()
  if M.file then return M.file end
  local xdg = vim.env.XDG_DATA_HOME or vim.fn.expand("~/.local/share")
  return xdg .. "/grannos/session_params.json"
end

--- Read the store from disk (once per session) and cache it.
--- @return table
local function load_store()
  if cache then return cache end
  cache = {}
  local f = io.open(file_path(), "r")
  if f then
    local content = f:read("*a")
    f:close()
    local ok, decoded = pcall(vim.json.decode, content)
    if ok and type(decoded) == "table" then cache = decoded end
  end
  return cache
end

--- Write the cached store to disk, creating its directory if needed.
local function write_store()
  local path = file_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "w")
  if not f then return end
  f:write(vim.json.encode(load_store()))
  f:close()
end

--- Return the group table holding `key`'s entry, creating intermediate
--- levels when `create` is set. Nil when absent and not creating.
--- @param key    string   composite connection key
--- @param create boolean
--- @return table|nil group  { [name] = values }
--- @return string   name
local function group_for(key, create)
  local server, driver, group, name = connections.conn_parts(key)
  local node = load_store()
  for _, seg in ipairs({ server, driver, group }) do
    local child = node[seg]
    if type(child) ~= "table" then
      if not create then return nil, name end
      child = {}
      node[seg] = child
    end
    node = child
  end
  return node, name
end

--- Return the session values last saved for `key`, or nil if none.
--- @param key string  composite connection key
--- @return table|nil  values keyed by session param key
function M.get(key)
  local g, name = group_for(key, false)
  local values = g and g[name]
  return type(values) == "table" and values or nil
end

--- Remember `values` as `key`'s session settings, replacing any previous
--- entry, and write the store to disk.
--- @param key    string  composite connection key
--- @param values table   values keyed by session param key
function M.save(key, values)
  local g, name = group_for(key, true)
  g[name] = values
  write_store()
end

--- Forget `key`'s session settings, if any.
--- @param key string  composite connection key
function M.delete(key)
  local g, name = group_for(key, false)
  if not g or g[name] == nil then return end
  g[name] = nil
  write_store()
end

--- Forget the session settings of every connection in a group.
--- @param server string
--- @param driver string
--- @param group  string
function M.delete_group(server, driver, group)
  local store = load_store()
  local d = type(store[server]) == "table" and store[server][driver]
  if type(d) ~= "table" or d[group] == nil then return end
  d[group] = nil
  write_store()
end

--- Move `old_key`'s session settings under `new_key` (a renamed or regrouped
--- connection keeps its settings). No-op when the keys are equal or `old_key`
--- has no entry.
--- @param old_key string
--- @param new_key string
function M.rename(old_key, new_key)
  if old_key == new_key then return end
  local values = M.get(old_key)
  if not values then return end
  local og, oname = group_for(old_key, false)
  og[oname] = nil
  local ng, nname = group_for(new_key, true)
  ng[nname] = values
  write_store()
end

--- Forget the cached store, so the next call re-reads from disk.
function M.clear_cache()
  cache = nil
end

return M
