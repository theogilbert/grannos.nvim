-- Completion in Cypher buffers, against a canned Neo4j explore tree.
-- Stubs must be installed before the modules under test require them.
local requests = {}

--- Canned explore.list responses, keyed by NUL-joined path, in the shape the
--- Neo4j driver lists: entities → label → properties, relationships → type →
--- properties.
local TREE = {
  [""]                                  = { { name = "entities",      type = "group", expandable = true },
                                            { name = "relationships", type = "group", expandable = true },
                                            { name = "indexes",       type = "group", expandable = true } },
  ["entities"]                          = { { name = "Movie",  type = "label", expandable = true },
                                            { name = "Person", type = "label", expandable = true } },
  ["relationships"]                     = { { name = "ACTED_IN", type = "relationship_type", expandable = true } },
  ["entities\0Person\0properties"]      = { { name = "born", type = "property" },
                                            { name = "name", type = "property" } },
  ["entities\0Movie\0properties"]       = { { name = "title",    type = "property" },
                                            { name = "released", type = "property" } },
  ["relationships\0ACTED_IN\0properties"] = { { name = "roles", type = "property" } },
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
local cypher     = require("grannos.completion.cypher")
local config     = require("grannos.config")

--- Create a Cypher buffer holding `lines`, attached for completion.
--- @param lines string[]
--- @return integer
local function cypher_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "cypher"
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
  return cypher_buf(clean), row, col
end

--- Return the byte column where the word ending at `col` starts.
--- @param text string
--- @param col  integer
--- @return integer
local function word_start(text, col)
  local start = col
  while start > 0 and text:sub(start, start):match("[%w_]") do start = start - 1 end
  return start
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

describe("completion.cypher.at_cursor", function()
  before_each(function() config.setup({}) end)

  --- Classify the position at the "|" marker in a single line.
  --- @param line string
  --- @return CypherCompletionContext|nil
  local function classify(line)
    local buf, row, col = at_marker({ line })
    local text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    return cypher.at_cursor(buf, row, word_start(text, col), col)
  end

  it("classifies a node pattern's label position", function()
    assert.equals("label", classify("MATCH (n:|) RETURN n").kind)
  end)

  it("classifies a second label on the same node", function()
    assert.equals("label", classify("MATCH (n:Person:|) RETURN n").kind)
  end)

  it("classifies a label position inside a label expression", function()
    assert.equals("label", classify("MATCH (n:Person&|) RETURN n").kind)
    assert.equals("label", classify("MATCH (n:(Person|") .kind)
  end)

  it("scopes a property to every label of a label expression", function()
    local ctx = classify("MATCH (n:Person&Movie) RETURN n.|")
    assert.same({ { name = "Person", type = "label" }, { name = "Movie", type = "label" } }, ctx.scopes)
  end)

  it("classifies a relationship type position, even with the pattern unclosed", function()
    assert.equals("relationship_type", classify("MATCH (n:Person)-[:|").kind)
  end)

  it("scopes a property access to the label its variable binds to", function()
    local ctx = classify("MATCH (n:Person) RETURN n.|")
    assert.equals("property", ctx.kind)
    assert.same({ { name = "Person", type = "label" } }, ctx.scopes)
  end)

  it("scopes a relationship property to its relationship type", function()
    local ctx = classify("MATCH (n)-[r:ACTED_IN]->(m) WHERE r.| RETURN n")
    assert.equals("property", ctx.kind)
    assert.same({ { name = "ACTED_IN", type = "relationship_type" } }, ctx.scopes)
  end)

  it("scopes a property key inside a pattern's map literal", function()
    local ctx = classify("MATCH (n:Movie {|: 1}) RETURN n")
    assert.equals("property", ctx.kind)
    assert.same({ { name = "Movie", type = "label" } }, ctx.scopes)
  end)

  it("leaves a property unscoped when its variable carries no label", function()
    local ctx = classify("MATCH (n) RETURN n.|")
    assert.equals("property", ctx.kind)
    assert.same({}, ctx.scopes)
  end)

  it("classifies a bare word in an expression as a variable, with its bindings", function()
    local ctx = classify("MATCH (n:Person)-[r:ACTED_IN]->(m) RETURN |")
    assert.equals("variable", ctx.kind)
    assert.same({ n = { { name = "Person", type = "label" } },
                  r = { { name = "ACTED_IN", type = "relationship_type" } },
                  m = {} }, ctx.variables)
  end)

  it("returns nil inside a string literal", function()
    assert.is_nil(classify("MATCH (n:Person {name: 'x|'}) RETURN n"))
  end)
end)

describe("completion.omnifunc in a Cypher buffer", function()
  before_each(function()
    config.setup({})
    completion.invalidate()
    requests = {}
  end)

  it("offers labels after a colon in a node pattern", function()
    assert.same({ "Movie", "Person" }, complete({ "MATCH (n:|) RETURN n" }))
  end)

  it("offers relationship types after a colon in a relationship pattern", function()
    assert.same({ "ACTED_IN" }, complete({ "MATCH (n:Person)-[r:|]->(m) RETURN n" }))
  end)

  it("offers the properties of the label a variable binds to, annotated with it", function()
    local items = complete_items({ "MATCH (n:Person) RETURN n.|" })
    assert.same({ { word = "born", kind = "p", menu = "Person" },
                  { word = "name", kind = "p", menu = "Person" } }, items)
  end)

  it("offers labels after an & or | in a label expression", function()
    assert.same({ "Movie", "Person" }, complete({ "MATCH (n:Person&|) RETURN n" }))
  end)

  it("offers the properties of every label in a label expression", function()
    assert.same({ "born", "name", "released", "title" }, complete({ "MATCH (n:Person&Movie) RETURN n.|" }))
  end)

  it("offers relationship properties through the relationship's variable", function()
    assert.same({ "roles" }, complete({ "MATCH (n)-[r:ACTED_IN]->(m) RETURN r.|" }))
  end)

  it("offers properties across a multi-line statement", function()
    assert.same({ "released", "title" }, complete({ "MATCH (p:Person)-[:ACTED_IN]->(m:Movie)", "WHERE m.| RETURN m" }))
  end)

  it("offers every variable the statement binds where an expression starts", function()
    local items = complete_items({ "MATCH (n:Person)-[r:ACTED_IN]->(m:Movie) RETURN |" })
    assert.same({ { word = "m", kind = "v", menu = "Movie" },
                  { word = "n", kind = "v", menu = "Person" },
                  { word = "r", kind = "v", menu = "ACTED_IN" } }, items)
  end)

  it("sweeps every label and relationship type for an unlabelled variable", function()
    assert.same({ "born", "name", "released", "roles", "title" }, complete({ "MATCH (n) RETURN n.|" }))
  end)

  it("stops sweeping past max_label_scan and offers nothing instead", function()
    config.setup({ completion = { max_label_scan = 2 } })
    assert.same({}, complete({ "MATCH (n) RETURN n.|" }))
    for _, key in ipairs(requests) do
      assert.is_falsy(key:find("properties", 1, true))
    end
  end)

  it("filters candidates by the typed prefix, case-insensitively", function()
    assert.same({ "Person" }, complete({ "MATCH (n:pe|) RETURN n" }))
  end)

  it("offers nothing inside a string literal", function()
    assert.same({}, complete({ "MATCH (n:Person {name: 'x|'}) RETURN n" }))
  end)

  it("primes the label and relationship type listings on attach, once", function()
    cypher_buf({ "" })
    cypher_buf({ "" })
    assert.same({ "entities", "relationships" }, requests)
  end)

  it("sends one explore.list per path and never repeats one", function()
    complete({ "MATCH (n:Person) RETURN n.|" })
    complete({ "MATCH (n:Person) RETURN n.|" })
    assert.same({ "entities", "relationships", "entities\0Person\0properties" }, requests)
  end)

  it("never sends explore.describe — it reads user data", function()
    complete({ "MATCH (n) RETURN n.|" })
    for _, key in ipairs(requests) do
      assert.is_truthy(key == "entities" or key == "relationships" or key:find("properties", 1, true))
    end
  end)
end)
