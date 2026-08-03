--- Symbol extraction for MongoDB buffers. See `grannos.symbols` for the contract.
---
--- MongoDB queries are Extended JSON command objects rather than a language of
--- their own, so this runs on the `json` parser:
---
---     {"find": "orders", "db": "mydb", "filter": {"status": "open"}}
---
--- The operation key's value names the collection, `"db"` names the database,
--- and every key nested deeper than the command object itself names a field.
local util = require("grannos.symbols.util")

local M = {}

-- Top-level keys whose value names the collection the command operates on
-- (the backend's MongoDriver._Op).
local OPERATIONS = {
  find = true, aggregate = true,
  insertOne = true, insertMany = true,
  updateOne = true, updateMany = true,
  deleteOne = true, deleteMany = true,
  createCollection = true, dropCollection = true,
  createIndex = true, dropIndex = true,
}

local DB_KEY = "db"

--- Return the text inside a `string` node, or nil when it has no content
--- (an empty string literal).
--- @param str   userdata|nil  a `string` node
--- @param bufnr integer
--- @return string|nil
local function string_text(str, bufnr)
  if not str or str:type() ~= "string" then return nil end
  local content = str:named_child(0)
  return content and util.text(content, bufnr) or nil
end

--- Return the outermost object containing `node` — the command object itself.
--- @param node userdata
--- @return userdata|nil
local function command_object(node)
  local outermost = nil
  local n = node
  while n do
    if n:type() == "object" then outermost = n end
    n = n:parent()
  end
  return outermost
end

--- Return the command's database name and the collection its operation names.
--- @param command userdata  the command object
--- @param bufnr   integer
--- @return string|nil db, string|nil collection
local function command_target(command, bufnr)
  local db, collection = nil, nil
  for pair in command:iter_children() do
    if pair:type() == "pair" then
      local key = string_text(pair:field("key")[1], bufnr)
      local value = string_text(pair:field("value")[1], bufnr)
      if key == DB_KEY then
        db = value
      elseif key and OPERATIONS[key] then
        collection = value
      end
    end
  end
  return db, collection
end

--- Return the scopes a field of this command sits under: its collection, and
--- the database that collection lives in.
--- @param db         string|nil
--- @param collection string|nil
--- @return SearchScope[]
local function field_scopes(db, collection)
  local scopes = {}
  if collection then table.insert(scopes, { name = collection, type = "collection" }) end
  if db then table.insert(scopes, { name = db, type = "database" }) end
  return scopes
end

--- Describe the MongoDB collection/database/field reference under the cursor.
--- Handles:
---   - the collection named by the operation key's value
---   - the database named by `"db"`
---   - a field key nested inside `filter`, `sort`, `update`, `pipeline`, … —
---     anything deeper than the command object, since only the command object's
---     own keys are structural
---   - an aggregation field reference in a value, `{"_id": "$status"}`
---
--- Returns nil for `$`-prefixed operators (`$set`, `$group`, `$sum`), which name
--- no database node, and for JSON that is not a Mongo command at all — an
--- Elasticsearch query body names no collection, so nothing here matches it.
--- @param node  userdata  the named node under the cursor
--- @param bufnr integer
--- @return SymbolQuery|nil
function M.extract(node, bufnr)
  if node:type() ~= "string_content" then return nil end
  local str = node:parent()
  local pair = str and str:parent()
  if not pair or pair:type() ~= "pair" then return nil end

  local command = command_object(pair)
  if not command then return nil end

  local db, collection = command_target(command, bufnr)
  -- No operation key means this JSON is not a Mongo command at all — an
  -- Elasticsearch query body, or an ordinary JSON file that happens to have a
  -- connection attached. Guessing that its keys are field names would turn
  -- every hover into a search for something that was never named.
  if not collection then return nil end
  local key = string_text(pair:field("key")[1], bufnr)
  local on_key = pair:field("key")[1] == str
  local text = util.text(node, bufnr)

  if on_key then
    -- The command object's own keys are structural: the operation, "db",
    -- "filter", "pipeline" and friends. Only deeper keys name fields.
    if pair:parent() == command then return nil end
    if text:sub(1, 1) == "$" then return nil end
    return { name = text, type = "field", scope = field_scopes(db, collection) }
  end

  if key == DB_KEY then
    return { name = text, type = "database", scope = {} }
  end

  if key and OPERATIONS[key] and pair:parent() == command then
    local scopes = db and { { name = db, type = "database" } } or {}
    return { name = text, type = "collection", scope = scopes }
  end

  -- An aggregation stage referring to a field by value, e.g. {"_id": "$status"}.
  if text:sub(1, 1) == "$" and #text > 1 then
    return {
      name  = text:sub(2),
      type  = "field",
      scope = field_scopes(db, collection),
    }
  end

  return nil
end

return M
