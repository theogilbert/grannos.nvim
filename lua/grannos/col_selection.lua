-- Persisted results-pane column selections, one per connection: the last
-- selection made on it.
--
-- Storage: a single JSON file, $XDG_DATA_HOME/grannos/col_selections.json,
-- nested like connections.json — [server][driver][group][name] = entry — so
-- entries follow the same identity as the connection they belong to, and are
-- deleted, renamed and regrouped with it. An entry holds the visible column
-- names in display order and the names that were hidden:
--
--   { "visible": ["name", "id"], "hidden": ["created_at"] }
--
-- Applied to the next result on that connection, whatever its columns: the
-- names in `visible` come first, in that order, then the result's remaining
-- columns in their own order, less any in `hidden`. The same query therefore
-- comes back exactly as it was left; an edited one keeps the choice and
-- appends what is new; an unrelated one, sharing no names, shows everything.
--
-- Every save replaces the entry — it is the previous selection that is
-- remembered, not an accumulation — and selecting every column again in its
-- own order deletes it, since that is no selection at all. These are
-- preferences: a missing or unreadable file is an empty store.
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
  return xdg .. "/grannos/col_selections.json"
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
--- @return table|nil group  { [name] = entry }
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

--- Return the entry saved for `key`, or nil.
--- @param key string
--- @return { visible: string[], hidden: string[] }|nil
local function entry_for(key)
  local g, name = group_for(key, false)
  local entry = g and g[name]
  if type(entry) ~= "table" or type(entry.visible) ~= "table" then return nil end
  if type(entry.hidden) ~= "table" then entry.hidden = {} end
  return entry
end

--- Return true when both lists hold the same strings in the same order.
--- @param a string[]
--- @param b string[]
--- @return boolean
local function same_list(a, b)
  if #a ~= #b then return false end
  for i, v in ipairs(a) do if v ~= b[i] then return false end end
  return true
end

--- Return the visible-column list for a result with these columns on
--- connection `key`, or nil when nothing was ever selected there. An empty
--- list is a valid answer: the user hid every column the result has.
--- @param key     string|nil  composite connection key
--- @param columns string[]    the result's full column list, in original order
--- @return string[]|nil
function M.load(key, columns)
  if not key or not columns or #columns == 0 then return nil end
  local entry = entry_for(key)
  if not entry then return nil end

  local present = {}
  for _, c in ipairs(columns) do present[c] = true end

  local visible, placed = {}, {}
  for _, c in ipairs(entry.visible) do
    if present[c] and not placed[c] then
      table.insert(visible, c)
      placed[c] = true
    end
  end
  local hidden = {}
  for _, c in ipairs(entry.hidden) do hidden[c] = true end
  for _, c in ipairs(columns) do
    if not placed[c] and not hidden[c] then
      table.insert(visible, c)
      placed[c] = true
    end
  end
  return visible
end

--- Remember `visible` as the selection last made on connection `key`, for a
--- result whose full column list is `columns`, replacing any earlier entry.
--- Selecting every column in its own order forgets the entry instead.
--- @param key     string|nil  composite connection key
--- @param columns string[]    the result's full column list, in original order
--- @param visible string[]    visible column names, in display order
function M.save(key, columns, visible)
  if not key or not columns or #columns == 0 or not visible then return end

  if same_list(columns, visible) then
    M.delete(key)
    return
  end

  local shown = {}
  for _, c in ipairs(visible) do shown[c] = true end
  local hidden = {}
  for _, c in ipairs(columns) do
    if not shown[c] then table.insert(hidden, c) end
  end

  local g, name = group_for(key, true)
  g[name] = { visible = vim.list_extend({}, visible), hidden = hidden }
  write_store()
end

--- Forget `key`'s selection, if any.
--- @param key string  composite connection key
function M.delete(key)
  local g, name = group_for(key, false)
  if not g or g[name] == nil then return end
  g[name] = nil
  write_store()
end

--- Forget the selections of every connection in a group.
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

--- Move `old_key`'s selection under `new_key` (a renamed or regrouped
--- connection keeps it). No-op when the keys are equal or `old_key` has no
--- entry.
--- @param old_key string
--- @param new_key string
function M.rename(old_key, new_key)
  if old_key == new_key then return end
  local entry = entry_for(old_key)
  if not entry then return end
  local og, oname = group_for(old_key, false)
  og[oname] = nil
  local ng, nname = group_for(new_key, true)
  ng[nname] = entry
  write_store()
end

--- Forget the store read this session, so the next call re-reads from disk.
--- Only needed by tests and after the storage file changes.
function M.clear_cache()
  cache = nil
end

return M
