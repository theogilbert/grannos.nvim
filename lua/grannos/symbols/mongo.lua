--- Symbol extraction for MongoDB buffers. See `grannos.symbols` for the contract.
---
--- MongoDB queries are Extended JSON command objects, and the `mongo` grammar
--- (../treesitters/treesitter-mongo) is the JSON tree with a `statement`
--- around each top-level object, so this reads JSON nodes and runs unchanged
--- on the `json` parser too:
---
---     {"find": "orders", "db": "mydb", "filter": {"status": "open"}}
---
--- The operation key's value names the collection, `"db"` names the database,
--- and every key nested deeper than the command object itself names a field.
local util = require("grannos.symbols.util")

local M = {}

--- Top-level keys whose value names the collection the command operates on
--- (the backend's MongoDriver._Op). Shared with completion.
M.OPERATIONS = {
  find = true, aggregate = true,
  insertOne = true, insertMany = true,
  updateOne = true, updateMany = true,
  deleteOne = true, deleteMany = true,
  createCollection = true, dropCollection = true,
  createIndex = true, dropIndex = true,
}
local OPERATIONS = M.OPERATIONS

--- The top-level key naming the database. Shared with completion.
M.DB_KEY = "db"
local DB_KEY = M.DB_KEY

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
function M.command_object(node)
  local outermost = nil
  local n = node
  while n do
    if n:type() == "object" then outermost = n end
    n = n:parent()
  end
  return outermost
end
local command_object = M.command_object

--- Return the command's database name, the collection its operation names,
--- and the operation itself.
--- @param command userdata        the command object
--- @param source  integer|string  the buffer or text `command` was parsed from
--- @return string|nil db, string|nil collection, string|nil operation
function M.command_target(command, source)
  local db, collection, operation = nil, nil, nil
  for pair in command:iter_children() do
    if pair:type() == "pair" then
      local key = string_text(pair:field("key")[1], source)
      local value = string_text(pair:field("value")[1], source)
      if key == DB_KEY then
        db = value
      elseif key and OPERATIONS[key] then
        collection, operation = value, key
      end
    end
  end
  return db, collection, operation
end
local command_target = M.command_target

--- Return the command-object pair whose value holds `node`, or nil when
--- `node` is not below one.
--- @param node    userdata
--- @param command userdata  the command object
--- @return userdata|nil
function M.argument_pair(node, command)
  local n = node
  while n and n:parent() do
    local parent = n:parent()
    if parent:id() == command:id() then
      return n:type() == "pair" and n or nil
    end
    n = parent
  end
  return nil
end

--- Return the `$stage` name of the pipeline stage `node` is inside, and
--- whether `node` is the stage object itself. A stage is an object that is
--- an element of the pipeline array, keyed by its one operator.
--- @param node     userdata  the object holding the position
--- @param pipeline userdata  the `pipeline` argument's array
--- @param source   integer|string
--- @return string|nil stage, boolean at_stage_level
local function stage_of(node, pipeline, source)
  local n = node
  while n do
    local parent = n:parent()
    if parent and parent:id() == pipeline:id() then
      local first = n:type() == "object" and n:named_child(0) or nil
      local key = first and first:type() == "pair" and string_text(first:field("key")[1], source) or nil
      return key, n:id() == node:id()
    end
    n = parent
  end
  return nil, false
end

--- Return true when a pair keyed `$expr` holds `node` below `argument`: an
--- aggregation expression inside a query.
--- @param node     userdata
--- @param argument userdata  the command-object pair
--- @param source   integer|string
--- @return boolean
local function under_expr(node, argument, source)
  local n = node
  while n and n:id() ~= argument:id() do
    if n:type() == "pair" and string_text(n:field("key")[1], source) == "$expr" then return true end
    n = n:parent()
  end
  return false
end

--- Stages whose nested keys are accumulators first: `$group`'s fields, the
--- `output` of `$bucket`, `$bucketAuto` and `$setWindowFields`.
local ACCUMULATING_STAGES = {
  ["$group"] = true, ["$bucket"] = true, ["$bucketAuto"] = true, ["$setWindowFields"] = true,
}

--- Return the operator categories (as `grannos.builtins` names them) a key
--- of `object` may name, most specific first, and whether the collection's
--- field names belong there too; nil when `argument`'s value is not what its
--- name says (a `pipeline` that is not an array). Shared by completion, which
--- offers the operators, and hover, which describes the one written.
---
---   - `filter`, and a `$match` stage: query operators;
---   - `update`: update operators;
---   - the top of a pipeline stage: stage names, and no fields;
---   - inside a grouping stage: accumulators, then expression operators;
---   - inside any other stage, or a `$expr`: expression operators;
---   - anywhere else: no operator at all.
--- @param object   userdata  the object the key is in
--- @param argument userdata  the command-object pair holding it (see argument_pair)
--- @param source   integer|string
--- @return string[]|nil categories, boolean fields
function M.key_categories(object, argument, source)
  local name = string_text(argument:field("key")[1], source)
  if name == "pipeline" then
    local pipeline = argument:field("value")[1]
    if not pipeline or pipeline:type() ~= "array" then return nil, false end
    local stage, at_stage = stage_of(object, pipeline, source)
    if at_stage then return { "stage" }, false end
    if under_expr(object, argument, source) then return { "expression" }, true end
    if stage == "$match" then return { "query" }, true end
    if ACCUMULATING_STAGES[stage] then return { "accumulator", "expression" }, true end
    return { "expression" }, true
  elseif name == "filter" then
    return { under_expr(object, argument, source) and "expression" or "query" }, true
  elseif name == "update" then
    return { "update" }, true
  end
  return {}, true
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
