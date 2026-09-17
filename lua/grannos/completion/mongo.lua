--- Candidates for MongoDB buffers — Extended JSON command objects, as the
--- `mongo` grammar reads them. See `grannos.completion` for the language-
--- module contract.
---
--- Everything a Mongo command names is a JSON string, so a position is only
--- ever completed inside one, and the string's place in the tree decides
--- what it may hold:
---
---   - a key of the command object itself: the operations and the arguments
---     they take (`find`, `db`, `filter`, `pipeline`, …), less those present;
---   - the value of `"db"`: database names, the root listing;
---   - the value of the operation key: the collections of the named database,
---     or of every database when none is named yet, bounded like SQL's
---     schema sweep — plus `gridfs.<bucket>` for a `find`;
---   - a key nested deeper — in `filter`, `sort`, `update`, a pipeline stage:
---     the collection's fields, and the `$` operators that argument takes
---     (query operators in a filter, update operators in an update, stage
---     names at the top of a pipeline, expression operators inside a stage),
---     the two told apart by what has been typed — every operator starts
---     with `$`, no field does;
---   - a string value starting with `$` (or any string value in a pipeline):
---     a field reference, `"$status"`.
---
--- The half-typed word is replaced by a placeholder (`completion.repair`) and
--- the cursor's statement re-parsed, the string it is in closed right after
--- it and brackets closed at the end (`close_open` below), so a half-typed
--- key parses as a pair of its object.
local cache   = require("grannos.completion.cache")
local config  = require("grannos.config")
local repair  = require("grannos.completion.repair")
local symbols = require("grannos.symbols.mongo")

local M = {}

--- A quote opens every key and value; `$` opens an operator or a field
--- reference and is not a word character to most engines.
M.TRIGGER_CHARACTERS = { '"', "$" }

--- Explore-tree group holding a collection's fields, and the group holding a
--- database's GridFS buckets, as the MongoDB driver lists them.
local FIELDS = "fields"
local GRIDFS = "gridfs"

--- The command object's keys, each with the annotation shown beside it.
--- Operations first, in the driver's order; then the arguments they take.
local COMMAND_KEYS = {
  { "find",             "operation" },
  { "aggregate",        "operation" },
  { "insertOne",        "operation" },
  { "insertMany",       "operation" },
  { "updateOne",        "operation" },
  { "updateMany",       "operation" },
  { "deleteOne",        "operation" },
  { "deleteMany",       "operation" },
  { "createCollection", "operation" },
  { "dropCollection",   "operation" },
  { "createIndex",      "operation" },
  { "dropIndex",        "operation" },
  { "db",               "database (required)" },
  { "filter",           "find, update*, delete*" },
  { "projection",       "find" },
  { "sort",             "find" },
  { "limit",            "find" },
  { "pipeline",         "aggregate" },
  { "document",         "insertOne" },
  { "documents",        "insertMany" },
  { "update",           "update*" },
  { "keys",             "createIndex" },
  { "options",          "createCollection, createIndex" },
  { "name",             "dropIndex" },
}

--- Arguments whose nested keys name nothing the tree lists: pymongo options
--- and an index name.
local OPAQUE_ARGUMENTS = { options = true, name = true, limit = true }

local QUERY_OPERATORS = {
  "$eq", "$ne", "$gt", "$gte", "$lt", "$lte", "$in", "$nin",
  "$and", "$or", "$not", "$nor",
  "$exists", "$type", "$expr", "$jsonSchema", "$mod", "$regex", "$options",
  "$text", "$where", "$all", "$elemMatch", "$size",
  "$geoIntersects", "$geoWithin", "$near", "$nearSphere",
  "$bitsAllClear", "$bitsAllSet", "$bitsAnyClear", "$bitsAnySet",
}

local UPDATE_OPERATORS = {
  "$set", "$unset", "$inc", "$mul", "$rename", "$min", "$max",
  "$currentDate", "$setOnInsert",
  "$push", "$pull", "$pullAll", "$addToSet", "$pop",
  "$each", "$slice", "$sort", "$position", "$bit",
}

local STAGE_OPERATORS = {
  "$match", "$group", "$project", "$sort", "$limit", "$skip", "$count",
  "$unwind", "$lookup", "$graphLookup", "$addFields", "$set", "$unset",
  "$replaceRoot", "$replaceWith", "$facet", "$bucket", "$bucketAuto",
  "$sortByCount", "$sample", "$out", "$merge", "$unionWith", "$redact",
  "$geoNear", "$densify", "$fill", "$setWindowFields", "$documents",
  "$collStats", "$indexStats", "$search", "$searchMeta", "$vectorSearch",
}

local EXPRESSION_OPERATORS = {
  -- accumulators
  "$sum", "$avg", "$min", "$max", "$first", "$last", "$push", "$addToSet",
  "$count", "$stdDevPop", "$stdDevSamp", "$mergeObjects",
  -- arithmetic
  "$add", "$subtract", "$multiply", "$divide", "$mod", "$abs", "$ceil",
  "$floor", "$round", "$trunc", "$pow", "$sqrt",
  -- comparison and boolean
  "$eq", "$ne", "$gt", "$gte", "$lt", "$lte", "$cmp", "$in", "$and", "$or",
  "$not",
  -- conditional
  "$cond", "$ifNull", "$switch",
  -- strings
  "$concat", "$toLower", "$toUpper", "$substr", "$substrCP", "$split",
  "$trim", "$strLenCP", "$regexMatch", "$regexFind",
  -- arrays and objects
  "$arrayElemAt", "$size", "$filter", "$map", "$reduce", "$slice",
  "$concatArrays", "$setUnion", "$setIntersection", "$objectToArray",
  "$arrayToObject", "$getField", "$setField",
  -- dates and conversion
  "$dateToString", "$dateFromString", "$year", "$month", "$dayOfMonth",
  "$hour", "$toString", "$toInt", "$toLong", "$toDouble", "$toDate",
  "$toObjectId", "$convert", "$type", "$literal", "$let",
}

--- Extended JSON type wrappers, valid wherever a value is written.
local TYPE_WRAPPERS = {
  "$oid", "$date", "$numberInt", "$numberLong", "$numberDouble",
  "$numberDecimal", "$binary", "$regularExpression", "$timestamp", "$uuid",
  "$minKey", "$maxKey",
}

--- Databases are what every command names and one listing away, so fetch
--- them on attach. Collections need a database first.
--- @param conn_id any
function M.prime(conn_id)
  cache.children(conn_id, {})
end

--- Return the byte column where the word ending at `col` starts.
---
--- Inside a string the word is everything since the opening quote: a field
--- path is dotted (`address.city`), an operator or a field reference starts
--- with `$`, and a collection name may carry either. Outside one the word is
--- ordinary, though nothing is offered there.
--- @param line string
--- @param col  integer  0-indexed byte column of the cursor
--- @return integer
function M.word_start(line, col)
  local open_at, i = nil, 1
  while i <= col do
    local ch = line:sub(i, i)
    if open_at then
      if ch == "\\" then i = i + 1
      elseif ch == '"' then open_at = nil end
    elseif ch == '"' then
      open_at = i
    elseif line:sub(i, i + 1) == "//" then
      break
    end
    i = i + 1
  end
  if open_at then return open_at end
  local start = col
  while start > 0 and line:sub(start, start):match("[%w_]") do
    start = start - 1
  end
  return start
end

--- Return the first and last row of the command `row` is in, from the
--- buffer's own tree: the top-level node starting at or before `row`, or
--- `row` alone when nothing does. A command still open at `row` swallows
--- what follows it in that tree, so past the cursor a line opening a brace
--- at column 0 — the next command, by JSON's own convention — ends one that
--- has errors; a well-formed command is trusted to its closing brace.
--- @param bufnr integer
--- @param row   integer  0-indexed
--- @return integer, integer  0-indexed, inclusive
local function statement_rows(bufnr, row)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  local tree = ok and parser and parser:parse()[1]
  if not tree then return row, row end
  local first, last, open = row, row, false
  for node in tree:root():iter_children() do
    local sr, _, er, ec = node:range()
    if sr > row then break end
    if node:type() ~= "comment" then
      first = sr
      last  = math.max(row, ec == 0 and er - 1 or er)
      open  = node:has_error()
    end
  end
  if open and last > row then
    local lines = vim.api.nvim_buf_get_lines(bufnr, row + 1, last + 1, false)
    for i, line in ipairs(lines) do
      if line:sub(1, 1) == "{" then last = row + i - 1; break end
    end
  end
  return first, last
end

--- What each opening bracket is closed with.
local CLOSERS = { ["{"] = "}", ["["] = "]" }

--- Return true when `text` holds an unescaped quote between `i` and the end
--- of its line.
--- @param text string
--- @param i    integer
--- @return boolean
local function quote_ahead(text, i)
  while i <= #text do
    local ch = text:sub(i, i)
    if ch == "\n" then return false end
    if ch == "\\" then i = i + 1 elseif ch == '"' then return true end
    i = i + 1
  end
  return false
end

--- Return `text` with the string the placeholder is in closed right after
--- it when nothing closes it on that line, every other string still open at
--- the end of its line closed there, and every bracket still open at the end
--- closed, innermost first. JSON's version of `repair.close_open`: a string
--- never spans lines, and the one being typed ends with the word being
--- typed — closing it any later would swallow whatever follows on the line
--- (`{"|},`). A key left open — the string opens where an object expects a
--- pair — is completed to a whole pair, `"key": null`, with a comma when
--- another pair follows, so the rest of the command keeps its shape.
--- @param text string
--- @return string
local function close_open(text)
  local ph = repair.PLACEHOLDER
  local out, stack, i = {}, {}, 1
  local quote, is_key, last_sig = false, false, nil

  --- Close the string being read, completing it to a pair when it is a key.
  --- @param at integer  index of the first character after the string's text
  local function close_string(at)
    out[#out + 1] = '"'
    if is_key then
      out[#out + 1] = ": null"
      if text:match("^%s*\"", at) then out[#out + 1] = "," end
    end
    quote, last_sig = false, "s"
  end

  while i <= #text do
    local ch = text:sub(i, i)
    if quote then
      if ch == "\\" then out[#out + 1] = text:sub(i, i + 1); i = i + 1
      elseif text:sub(i, i + #ph - 1) == ph then
        out[#out + 1] = ph
        i = i + #ph
        if not quote_ahead(text, i) then close_string(i) end
        i = i - 1
      elseif ch == "\n" then
        close_string(i)
        out[#out + 1] = ch
      else
        out[#out + 1] = ch
        if ch == '"' then quote, last_sig = false, "s" end
      end
    elseif ch == '"' then
      quote  = true
      is_key = stack[#stack] == "}" and (last_sig == "{" or last_sig == ",")
      out[#out + 1] = ch
    elseif text:sub(i, i + 1) == "//" then
      local eol = text:find("\n", i, true) or #text + 1
      out[#out + 1] = text:sub(i, eol - 1); i = eol - 1
    elseif text:sub(i, i + 1) == "/*" then
      local close = text:find("*/", i + 2, true)
      local stop = close and close + 1 or #text
      out[#out + 1] = text:sub(i, stop); i = stop
    else
      out[#out + 1] = ch
      if CLOSERS[ch] then stack[#stack + 1] = CLOSERS[ch]
      elseif stack[#stack] == ch then stack[#stack] = nil end
      if not ch:match("%s") then last_sig = ch end
    end
    i = i + 1
  end
  if quote then close_string(#text + 1) end
  for j = #stack, 1, -1 do out[#out + 1] = stack[j] end
  return table.concat(out)
end

--- Return the text of a `string` node's content, or nil.
--- @param str  userdata|nil
--- @param text string
--- @return string|nil
local function string_text(str, text)
  if not str or str:type() ~= "string" then return nil end
  local content = str:named_child(0)
  return content and vim.treesitter.get_node_text(content, text) or nil
end

--- Return the command-object pair whose value holds `node`, or nil when
--- `node` is not below one.
--- @param node    userdata
--- @param command userdata  the command object
--- @return userdata|nil
local function argument_pair(node, command)
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
--- @param text     string
--- @return string|nil stage, boolean at_stage_level
local function stage_of(node, pipeline, text)
  local n = node
  while n do
    local parent = n:parent()
    if parent and parent:id() == pipeline:id() then
      local first = n:type() == "object" and n:named_child(0) or nil
      local key = first and first:type() == "pair" and string_text(first:field("key")[1], text) or nil
      return key, n:id() == node:id()
    end
    n = parent
  end
  return nil, false
end

--- @class MongoCompletionContext
--- @field kind       "command_key"|"database"|"collection"|"field"|"field_ref"
--- @field db         string|nil     the database the command names
--- @field collection string|nil     the collection its operation names
--- @field operation  string|nil     the operation, when the command has one
--- @field present    table<string, boolean>|nil  command_key: keys the command already has
--- @field operators  string[]|nil   field: the `$` operators this position takes
--- @field fields     boolean|nil    field: whether the collection's fields belong here

--- Return the `$` operators a nested key under `argument` may be, and
--- whether field names belong there too.
--- @param argument string
--- @param stage    string|nil   pipeline: the enclosing stage's operator
--- @param at_stage boolean      pipeline: whether the key opens a stage
--- @return string[], boolean
local function nested_key_offer(argument, stage, at_stage)
  if argument == "pipeline" then
    if at_stage then return STAGE_OPERATORS, false end
    return stage == "$match" and QUERY_OPERATORS or EXPRESSION_OPERATORS, true
  elseif argument == "filter" then
    return QUERY_OPERATORS, true
  elseif argument == "update" then
    return UPDATE_OPERATORS, true
  end
  return {}, true
end

--- Describe what should be completed at [start_col, end_col) on `row`.
--- Returns nil when the position names nothing the server can answer.
--- @param bufnr     integer
--- @param row       integer  0-indexed
--- @param start_col integer  0-indexed byte column of the word being completed
--- @param end_col   integer  0-indexed byte column of the cursor
--- @return MongoCompletionContext|nil
function M.at_cursor(bufnr, row, start_col, end_col)
  local first, last = statement_rows(bufnr, row)
  local text, col = repair.repaired(bufnr, row, start_col, end_col, first, last)
  text = close_open(text)
  local node = repair.node_at(text, "mongo", row - first, col)
  if not node or node:type() ~= "string_content" then return nil end
  local str = node:parent()
  local holder = str and str:parent()
  if not holder then return nil end

  -- Where the string sits: a pair's key or value, a stray string an object
  -- could not place (a key being typed), or an array element. Error nodes
  -- the parser wrapped around the position are looked through.
  local is_key, container
  if holder:type() == "pair" then
    is_key    = holder:field("key")[1]:id() == str:id()
    container = holder:parent()
  elseif holder:type() == "ERROR" then
    is_key, container = true, holder:parent()
  elseif holder:type() == "array" then
    is_key, container = false, holder
  else
    return nil
  end
  while container and container:type() == "ERROR" do container = container:parent() end
  if not container then return nil end

  local command = symbols.command_object(container)
  if not command then return nil end
  local db, collection, operation = symbols.command_target(command, text)
  local ctx = { db = db, collection = collection, operation = operation }

  if container:id() == command:id() then
    if is_key then
      ctx.kind, ctx.present = "command_key", {}
      for pair in command:iter_children() do
        if pair:type() == "pair" and pair:id() ~= holder:id() then
          ctx.present[string_text(pair:field("key")[1], text) or ""] = true
        end
      end
      return ctx
    end
    local key = string_text(holder:field("key")[1], text)
    if key == symbols.DB_KEY then ctx.kind = "database"; return ctx end
    if key and symbols.OPERATIONS[key] then ctx.kind = "collection"; return ctx end
    return nil
  end

  local argument = argument_pair(container, command)
  local arg_name = argument and string_text(argument:field("key")[1], text)
  if not arg_name or OPAQUE_ARGUMENTS[arg_name] then return nil end

  if is_key then
    local stage, at_stage = nil, false
    if arg_name == "pipeline" then
      local pipeline = argument:field("value")[1]
      if not pipeline or pipeline:type() ~= "array" then return nil end
      stage, at_stage = stage_of(container, pipeline, text)
    end
    ctx.kind = "field"
    ctx.operators, ctx.fields = nested_key_offer(arg_name, stage, at_stage)
    return ctx
  end

  -- A value: a field reference when written as one, or anywhere in a
  -- pipeline, where `"$status"` is how a stage names a field. Any other
  -- value is data the tree has no listing for.
  local typed = (vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""):sub(start_col + 1, end_col)
  if arg_name == "pipeline" or typed:sub(1, 1) == "$" then
    ctx.kind = "field_ref"
    return ctx
  end
  return nil
end

--- Feed collection candidates for `ctx` to `add`: the named database's, or
--- every database's when none is named and there are few enough to sweep.
--- A `find` may also target a GridFS bucket as `gridfs.<bucket>`.
--- @param conn_id  any
--- @param ctx      MongoCompletionContext
--- @param add      fun(word: string, kind: string, menu: string)
--- @param on_ready fun()|nil
local function collection_candidates(conn_id, ctx, add, on_ready)
  local dbs
  if ctx.db then
    dbs = { ctx.db }
  else
    local root = cache.children(conn_id, {}, on_ready) or {}
    if #root > config.options.completion.max_schema_scan then return end
    dbs = {}
    for _, item in ipairs(root) do dbs[#dbs + 1] = item.name end
  end
  for _, db in ipairs(dbs) do
    local has_gridfs = false
    for _, item in ipairs(cache.children(conn_id, { db }, on_ready) or {}) do
      if item.type == "collection" then
        add(item.name, "c", db)
      elseif item.name == GRIDFS then
        has_gridfs = true
      end
    end
    if has_gridfs and ctx.operation == "find" then
      for _, bucket in ipairs(cache.children(conn_id, { db, GRIDFS }, on_ready) or {}) do
        add(GRIDFS .. "." .. bucket.name, "c", db .. " (GridFS)")
      end
    end
  end
end

--- Feed the collection's field names to `add`, `prefix` ahead of each.
--- Nothing without a database: which one holds the collection is unknown,
--- and finding out would list every database's collections.
--- @param conn_id  any
--- @param ctx      MongoCompletionContext
--- @param prefix   string
--- @param add      fun(word: string, kind: string, menu: string)
--- @param on_ready fun()|nil
local function field_candidates(conn_id, ctx, prefix, add, on_ready)
  if not ctx.db or not ctx.collection then return end
  for _, item in ipairs(cache.children(conn_id, { ctx.db, ctx.collection, FIELDS }, on_ready) or {}) do
    add(prefix .. item.name, "f", ctx.collection)
  end
end

--- Feed the candidates for `ctx` to `add`, starting any fetch it needs.
--- @param conn_id  any
--- @param ctx      MongoCompletionContext
--- @param add      fun(word: string, kind: string, menu: string, info: string|nil)
--- @param on_ready fun()|nil  called once per fetch that completes
function M.candidates(conn_id, ctx, add, on_ready)
  if ctx.kind == "command_key" then
    for _, entry in ipairs(COMMAND_KEYS) do
      local key, menu = entry[1], entry[2]
      local is_op = symbols.OPERATIONS[key]
      if not ctx.present[key] and not (is_op and ctx.operation) then
        add(key, "k", menu)
      end
    end
  elseif ctx.kind == "database" then
    for _, item in ipairs(cache.children(conn_id, {}, on_ready) or {}) do
      add(item.name, "d", item.type)
    end
  elseif ctx.kind == "collection" then
    collection_candidates(conn_id, ctx, add, on_ready)
  elseif ctx.kind == "field" then
    for _, op in ipairs(ctx.operators) do add(op, "o", "operator") end
    if ctx.fields then
      for _, op in ipairs(TYPE_WRAPPERS) do add(op, "t", "extended json") end
      field_candidates(conn_id, ctx, "", add, on_ready)
    end
  elseif ctx.kind == "field_ref" then
    field_candidates(conn_id, ctx, "$", add, on_ready)
  end
end

return M
