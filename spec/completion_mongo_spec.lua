-- Completion in MongoDB buffers, against a canned explore tree.
-- Stubs must be installed before the modules under test require them.
local requests = {}

--- Canned explore.list responses, keyed by NUL-joined path, in the shape the
--- MongoDB driver lists: database → collection → fields, plus a `gridfs`
--- group of buckets under a database that has any.
local TREE = {
  [""]                     = { { name = "auth", type = "database", expandable = true },
                               { name = "mydb", type = "database", expandable = true } },
  ["auth"]                 = { { name = "users", type = "collection", expandable = true } },
  ["mydb"]                 = { { name = "events", type = "collection", expandable = true },
                               { name = "orders", type = "collection", expandable = true },
                               { name = "gridfs", type = "group",      expandable = true } },
  ["mydb\0gridfs"]         = { { name = "fs",      type = "gridfs_bucket" },
                               { name = "reports", type = "gridfs_bucket" } },
  ["mydb\0orders\0fields"] = { { name = "_id",    type = "field" },
                               { name = "amount", type = "field" },
                               { name = "status", type = "field" } },
  ["auth\0users\0fields"]  = { { name = "_id",   type = "field" },
                               { name = "email", type = "field" } },
}

package.loaded["grannos.client"] = {
  request = function(_method, params, cb)
    local key = table.concat(params.path, "\0")
    requests[#requests + 1] = key
    cb(nil, { items = TREE[key] or {} })
  end,
}
package.loaded["grannos"] = {
  get_conn = function() return { conn_id = "0" } end,
}

local completion = require("grannos.completion")
local mongo      = require("grannos.completion.mongo")
local config     = require("grannos.config")

--- Create a MongoDB buffer holding `lines`, attached for completion.
--- @param lines string[]
--- @return integer
local function mongo_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "mongo"
  vim.api.nvim_set_current_buf(buf)
  completion.attach(buf, "conn")
  return buf
end

--- Place the cursor at the "|" marker in `lines` and return the buffer, the
--- 0-indexed row, and the cursor's byte column.
--- @param lines string[]
--- @return integer, integer, integer
local function at_marker(lines)
  local row, col
  local clean = {}
  for i, l in ipairs(lines) do
    local before, after = l:match("^(.-)|(.*)$")
    if before then
      row, col = i - 1, #before
      clean[i] = before .. after
    else
      clean[i] = l
    end
  end
  return mongo_buf(clean), row, col
end

--- Run omnifunc at the marker and return the candidates, driving the refill
--- rounds a live session's popup would drive until nothing new arrives.
--- @param lines string[]
--- @return table[]  { word, kind, menu }
local function complete_items(lines)
  local buf, row, col = at_marker(lines)
  vim.cmd("startinsert!")
  vim.api.nvim_win_set_cursor(0, { row + 1, col })
  local base_start = completion.omnifunc(1, "")
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local base = line:sub(base_start + 1, col)

  local items = {}
  for _ = 1, 4 do
    items = completion.omnifunc(0, base)
    vim.wait(20, function() return false end)
  end
  return items
end

--- Run omnifunc at the marker and return the candidate words.
--- @param lines string[]
--- @return string[]
local function complete(lines)
  local words = {}
  for _, item in ipairs(complete_items(lines)) do words[#words + 1] = item.word end
  return words
end

--- Return true when `list` holds `word`.
--- @param list string[]
--- @param word string
--- @return boolean
local function has(list, word)
  for _, w in ipairs(list) do if w == word then return true end end
  return false
end

describe("completion.mongo.word_start", function()
  it("starts a word inside a string at its opening quote", function()
    assert.equals(10, mongo.word_start('{"find": "ord', 13))
    assert.equals(10, mongo.word_start('{"find": "', 10))
    assert.equals(40, mongo.word_start('{"find": "orders", "filter": {"$set": {"address.ci', 50))
  end)

  it("keeps a dollar sign and dots inside the word", function()
    assert.equals(31, mongo.word_start('{"find": "orders", "filter": {"$ex', 34))
    assert.equals(52, mongo.word_start('{"find": "orders", "pipeline": [{"$group": {"_id": "$sta', 56))
  end)

  it("skips an escaped quote inside a string", function()
    assert.equals(10, mongo.word_start('{"find": "a\\"b', 14))
  end)

  it("falls back to an ordinary word outside a string", function()
    assert.equals(9, mongo.word_start('{"find": tru', 12))
  end)
end)

describe("completion.mongo.at_cursor", function()
  before_each(function() config.setup({}) end)

  --- Classify the position at the "|" marker in `lines`.
  --- @param lines string[]
  --- @return MongoCompletionContext|nil
  local function classify(lines)
    local buf, row, col = at_marker(lines)
    local text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    return mongo.at_cursor(buf, row, mongo.word_start(text, col), col)
  end

  it("classifies a key of the command object, finished or not", function()
    local ctx = classify({ '{"|' })
    assert.equals("command_key", ctx.kind)
    assert.same({}, ctx.present)
    ctx = classify({ '{"find": "orders", "fi|' })
    assert.equals("command_key", ctx.kind)
    assert.is_true(ctx.present.find)
    assert.equals("find", ctx.operation)
    assert.equals("command_key", classify({ '{"find": "orders", "d|": "mydb"}' }).kind)
    assert.equals("command_key", classify({ '{"find": "orders", "|}' }).kind)
    assert.equals("command_key", classify({ '{"find": "orders", "|, "db": "mydb"}' }).kind)
  end)

  it("classifies the value of db as a database position", function()
    assert.equals("database", classify({ '{"find": "orders", "db": "|' }).kind)
    assert.equals("database", classify({ '{"find": "orders", "db": "my|"}' }).kind)
  end)

  it("classifies the value of an operation as a collection position", function()
    local ctx = classify({ '{"find": "|' })
    assert.equals("collection", ctx.kind)
    assert.is_nil(ctx.db)
    ctx = classify({ '{"db": "mydb", "insertOne": "|"}' })
    assert.equals("collection", ctx.kind)
    assert.equals("mydb", ctx.db)
    assert.equals("insertOne", ctx.operation)
  end)

  it("classifies a nested key as a field position under its argument", function()
    local ctx = classify({ '{"find": "orders", "db": "mydb", "filter": {"|' })
    assert.equals("field", ctx.kind)
    assert.equals("orders", ctx.collection)
    assert.equals("mydb", ctx.db)
    assert.is_true(ctx.fields)
    assert.is_true(has(ctx.operators, "$eq"))
    assert.is_false(has(ctx.operators, "$set"))

    ctx = classify({ '{"updateOne": "orders", "db": "mydb", "filter": {}, "update": {"$set": {"sta|' })
    assert.equals("field", ctx.kind)
    assert.is_true(has(ctx.operators, "$set"))
    assert.is_false(has(ctx.operators, "$eq"))

    ctx = classify({ '{"find": "orders", "db": "mydb", "sort": {"|"}}' })
    assert.equals("field", ctx.kind)
    assert.same({}, ctx.operators)
  end)

  it("offers stage names at the top of a pipeline and expressions inside one", function()
    local ctx = classify({ '{"aggregate": "orders", "db": "mydb", "pipeline": [{"|' })
    assert.equals("field", ctx.kind)
    assert.is_false(ctx.fields)
    assert.is_true(has(ctx.operators, "$group"))

    ctx = classify({ '{"aggregate": "orders", "db": "mydb", "pipeline": [{"$group": {"_id": "$status", "total": {"|' })
    assert.is_true(ctx.fields)
    assert.is_true(has(ctx.operators, "$sum"))
    assert.is_false(has(ctx.operators, "$group"))

    ctx = classify({ '{"aggregate": "orders", "db": "mydb", "pipeline": [{"$match": {"|' })
    assert.is_true(has(ctx.operators, "$eq"))
    assert.is_false(has(ctx.operators, "$sum"))
  end)

  it("classifies a dollar value as a field reference, and any value in a pipeline", function()
    assert.equals("field_ref", classify({ '{"aggregate": "orders", "db": "mydb", "pipeline": [{"$group": {"_id": "|' }).kind)
    assert.equals("field_ref", classify({ '{"aggregate": "orders", "db": "mydb", "pipeline": [{"$project": {"x": ["$a", "|"]}}]}' }).kind)
    assert.equals("field_ref", classify({ '{"find": "orders", "db": "mydb", "filter": {"$expr": {"$gt": ["$am|' }).kind)
  end)

  it("returns nil for a plain value, an opaque argument and outside a string", function()
    assert.is_nil(classify({ '{"find": "orders", "db": "mydb", "filter": {"status": "|' }))
    assert.is_nil(classify({ '{"find": "orders", "db": "mydb", "filter": {"status": "op|"}}' }))
    assert.is_nil(classify({ '{"createIndex": "orders", "db": "mydb", "options": {"|' }))
    assert.is_nil(classify({ '{"find": "orders", "limit": |' }))
    assert.is_nil(classify({ '// |' }))
  end)

  it("follows a command across lines and finds its target after the cursor", function()
    local ctx = classify({ '{"find": "orders",', ' "filter": {"|},', ' "db": "mydb"}' })
    assert.equals("field", ctx.kind)
    assert.equals("mydb", ctx.db)
    assert.equals("orders", ctx.collection)
  end)

  it("parses the cursor's command alone in a buffer holding several", function()
    local ctx = classify({ '{"find": "users", "db": "auth"}', '{"find": "orders", "db": "mydb", "filter": {"|' , '{"find": "events", "db": "mydb"}' })
    assert.equals("field", ctx.kind)
    assert.equals("orders", ctx.collection)
    assert.equals("mydb", ctx.db)
    ctx = classify({ '{"find": "users", "db": "auth"}', '', '{"find": "|', '', '{"find": "events", "db": "mydb"}' })
    assert.equals("collection", ctx.kind)
    assert.is_nil(ctx.db)
  end)
end)

describe("completion.omnifunc in a MongoDB buffer", function()
  before_each(function()
    config.setup({})
    requests = {}
    completion.invalidate()
  end)

  it("offers the operations and arguments as command keys, less those present", function()
    local words = complete({ '{"|' })
    assert.is_true(has(words, "find"))
    assert.is_true(has(words, "db"))
    assert.is_true(has(words, "pipeline"))
    words = complete({ '{"find": "orders", "db": "mydb", "|' })
    assert.is_false(has(words, "find"))
    assert.is_false(has(words, "aggregate"))
    assert.is_false(has(words, "db"))
    assert.is_true(has(words, "filter"))
  end)

  it("offers database names for db", function()
    assert.same({ "auth", "mydb" }, complete({ '{"find": "orders", "db": "|' }))
    assert.same({ "mydb" }, complete({ '{"find": "orders", "db": "my|' }))
  end)

  it("offers the named database's collections, buckets included for a find", function()
    assert.same({ "events", "gridfs.fs", "gridfs.reports", "orders" },
      complete({ '{"db": "mydb", "find": "|' }))
    assert.same({ "events", "orders" }, complete({ '{"db": "mydb", "deleteMany": "|' }))
  end)

  it("sweeps every database for a collection when none is named", function()
    local items = complete_items({ '{"find": "|' })
    local seen = {}
    for _, item in ipairs(items) do seen[item.word] = item.menu end
    assert.equals("auth", seen.users)
    assert.equals("mydb", seen.orders)
  end)

  it("offers schema names only, past the sweep bound", function()
    config.setup({ completion = { max_schema_scan = 1 } })
    assert.same({}, complete({ '{"find": "|' }))
  end)

  it("offers fields and the argument's operators for a nested key", function()
    local words = complete({ '{"find": "orders", "db": "mydb", "filter": {"|' })
    assert.is_true(has(words, "status"))
    assert.is_true(has(words, "$eq"))
    assert.is_true(has(words, "$oid"))
    assert.is_false(has(words, "$set"))
    assert.same({ "status" }, complete({ '{"find": "orders", "db": "mydb", "filter": {"st|' }))
    assert.same({ "$exists", "$expr" }, complete({ '{"find": "orders", "db": "mydb", "filter": {"$ex|' }))
  end)

  it("offers field references with the dollar sign", function()
    assert.same({ "$status" },
      complete({ '{"aggregate": "orders", "db": "mydb", "pipeline": [{"$group": {"_id": "$st|' }))
  end)

  it("lists a collection's fields once, and only with a database", function()
    complete({ '{"find": "orders", "db": "mydb", "filter": {"|' })
    complete({ '{"find": "orders", "db": "mydb", "sort": {"|' })
    local fetches = 0
    for _, key in ipairs(requests) do
      if key == "mydb\0orders\0fields" then fetches = fetches + 1 end
    end
    assert.equals(1, fetches)
    assert.is_false(has(complete({ '{"find": "orders", "sort": {"|' }), "status"))
  end)

  it("fires on a quote and a dollar sign", function()
    local chars = completion.trigger_characters()
    assert.is_true(has(chars, '"'))
    assert.is_true(has(chars, "$"))
  end)
end)
