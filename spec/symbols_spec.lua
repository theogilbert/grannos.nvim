local symbols = require("grannos.symbols")

--- Describe the symbol under a cursor placed at the first occurrence of
--- `needle` in a scratch buffer of filetype `ft` containing `text`.
--- @param ft     string
--- @param text   string
--- @param needle string  substring whose first character positions the cursor
--- @return SymbolQuery|nil
local function symbol_at(ft, text, needle)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n"))
  vim.bo[buf].filetype = ft
  vim.api.nvim_win_set_buf(0, buf)
  local col = assert(text:find(needle, 1, true)) - 1
  vim.api.nvim_win_set_cursor(0, { 1, col })
  return symbols.at_cursor(buf)
end

describe("symbols.at_cursor for SQL", function()
  local function sql_at(text, needle) return symbol_at("sql", text, needle) end

  it("scopes a column qualified by an alias to the alias's table", function()
    assert.same(
      { name = "id", type = "column", scope = { { name = "users", type = "table" } } },
      sql_at("SELECT u.id FROM users u;", "id FROM"))
  end)

  it("scopes a column qualified by the table's own name", function()
    assert.same(
      { name = "name", type = "column", scope = { { name = "users", type = "table" } } },
      sql_at("SELECT users.name FROM users;", "name FROM"))
  end)

  it("scopes a bare column to the single table in scope", function()
    assert.same(
      { name = "id", type = "column", scope = { { name = "orders", type = "table" } } },
      sql_at("SELECT id FROM orders;", "id FROM"))
  end)

  it("scopes a bare column to every table in scope", function()
    assert.same(
      {
        name  = "id",
        type  = "column",
        scope = { { name = "a", type = "table" }, { name = "b", type = "table" } },
      },
      sql_at("SELECT id FROM a JOIN b ON a.x = b.x;", "id FROM"))
  end)

  it("carries the schema of a qualified source into a column's scope", function()
    assert.same(
      {
        name  = "id",
        type  = "column",
        scope = { { name = "users", type = "table" }, { name = "public", type = "schema" } },
      },
      sql_at("SELECT u.id FROM public.users u;", "id FROM"))
  end)

  it("gives up on a bare column when a FROM source is a derived table", function()
    -- The column may well belong to the subquery rather than to any real table.
    assert.is_nil(sql_at("SELECT id FROM a JOIN (SELECT 1) b ON a.x = b.x;", "id FROM"))
  end)

  it("scopes a schema-qualified table name to its schema", function()
    assert.same(
      { name = "users", type = "table", scope = { { name = "public", type = "schema" } } },
      sql_at("SELECT * FROM public.users;", "users;"))
  end)

  it("names an unqualified table with no scope at all", function()
    assert.same(
      { name = "orders", type = "table", scope = {} },
      sql_at("SELECT * FROM orders;", "orders;"))
  end)

  it("resolves a table's own alias identifier to the table", function()
    assert.same(
      { name = "users", type = "table", scope = {} },
      sql_at("SELECT * FROM users usr;", "usr;"))
  end)

  it("gives up on a column qualified by a derived table", function()
    assert.is_nil(sql_at("SELECT x.id FROM (SELECT id FROM users) x;", "x.id"))
  end)

  it("resolves the INSERT target table", function()
    assert.same(
      { name = "employees", type = "table", scope = {} },
      sql_at("INSERT INTO employees (name) VALUES ('a');", "employees"))
  end)

  it("resolves the UPDATE target table", function()
    assert.same(
      { name = "employees", type = "table", scope = {} },
      sql_at("UPDATE employees SET name = 'a';", "employees"))
  end)

  it("resolves the UPDATE target table via its alias", function()
    assert.same(
      { name = "id", type = "column", scope = { { name = "users", type = "table" } } },
      sql_at("UPDATE users AS u SET name = 'x' WHERE u.id = 1;", "id = 1"))
  end)

  it("resolves the DELETE target table via its alias", function()
    assert.same(
      { name = "id", type = "column", scope = { { name = "users", type = "table" } } },
      sql_at("DELETE FROM users u WHERE u.id = 1;", "id = 1"))
  end)

  it("resolves a self-join column via its alias", function()
    assert.same(
      { name = "mgr_id", type = "column", scope = { { name = "users", type = "table" } } },
      sql_at("SELECT a.id FROM users a JOIN users b ON a.mgr_id = b.id;", "mgr_id"))
  end)

  it("returns nil when the cursor is not on an identifier", function()
    assert.is_nil(sql_at("SELECT id FROM orders;", "SELECT"))
  end)

  it("returns nil for a bare column with no FROM source to scope it", function()
    assert.is_nil(sql_at("SELECT id;", "id;"))
  end)
end)

describe("symbols.at_cursor for Cypher", function()
  local function cypher_at(text, needle) return symbol_at("cypher", text, needle) end

  it("names a node label", function()
    assert.same(
      { name = "Person", type = "label", scope = {} },
      cypher_at('MATCH (n:Person) RETURN n', "Person"))
  end)

  it("names a relationship type", function()
    assert.same(
      { name = "ACTED_IN", type = "relationship_type", scope = {} },
      cypher_at('MATCH (n:Person)-[r:ACTED_IN]->(m:Movie) RETURN r', "ACTED_IN"))
  end)

  it("scopes a property access to the label its variable binds to", function()
    assert.same(
      { name = "name", type = "property", scope = { { name = "Person", type = "label" } } },
      cypher_at('MATCH (n:Person) WHERE n.name = "x" RETURN n', "name ="))
  end)

  it("scopes a property in a SET clause", function()
    assert.same(
      { name = "age", type = "property", scope = { { name = "Person", type = "label" } } },
      cypher_at('MATCH (n:Person) SET n.age = 3', "age"))
  end)

  it("scopes a property key inside a pattern's map literal", function()
    assert.same(
      { name = "name", type = "property", scope = { { name = "Person", type = "label" } } },
      cypher_at('MATCH (n:Person {name: "x"}) RETURN n', "name:"))
  end)

  it("scopes a property to every label its variable carries", function()
    assert.same(
      {
        name  = "age",
        type  = "property",
        scope = { { name = "A", type = "label" }, { name = "B", type = "label" } },
      },
      cypher_at('MATCH (n:A:B) SET n.age = 3', "age"))
  end)

  it("scopes a relationship property to its relationship type", function()
    assert.same(
      {
        name  = "roles",
        type  = "property",
        scope = { { name = "ACTED_IN", type = "relationship_type" } },
      },
      cypher_at('MATCH (n)-[r:ACTED_IN]->(m) RETURN r.roles', "roles"))
  end)

  it("leaves a property unscoped when its variable carries no label", function()
    -- MATCH (n) is a perfectly good query; the backend reports the candidates.
    assert.same(
      { name = "name", type = "property", scope = {} },
      cypher_at('MATCH (n) WHERE n.name = "x" RETURN n', "name ="))
  end)

  it("resolves a variable to the label it binds to", function()
    assert.same(
      { name = "Person", type = "label", scope = {} },
      cypher_at('MATCH (n:Person) RETURN n', "n)"))
  end)

  it("returns nil for a variable bound to several labels", function()
    assert.is_nil(cypher_at('MATCH (n:A:B) RETURN n', "n:A"))
  end)
end)

describe("symbols.at_cursor for PromQL", function()
  local function promql_at(text, needle) return symbol_at("promql", text, needle) end

  it("names a bare metric", function()
    assert.same(
      { name = "up", type = "metric", scope = {} },
      promql_at('up', "up"))
  end)

  it("names a metric inside a call", function()
    assert.same(
      { name = "http_requests_total", type = "metric", scope = {} },
      promql_at('rate(http_requests_total[5m])', "http_requests_total"))
  end)

  it("scopes a label matcher to its metric", function()
    assert.same(
      {
        name  = "code",
        type  = "label",
        scope = { { name = "http_requests_total", type = "metric" } },
      },
      promql_at('http_requests_total{job="api", code="500"}', "code"))
  end)

  it("scopes a label in an aggregation modifier to the aggregated metric", function()
    assert.same(
      { name = "instance", type = "label", scope = { { name = "up", type = "metric" } } },
      promql_at('sum by (instance) (up)', "instance"))
  end)

  it("names the scrape job a job matcher selects", function()
    assert.same(
      { name = "api", type = "job", scope = {} },
      promql_at('http_requests_total{job="api"}', '"api"'))
  end)

  it("returns nil for an ordinary label value", function()
    assert.is_nil(promql_at('http_requests_total{code="500"}', '"500"'))
  end)
end)

describe("symbols.at_cursor for MongoDB", function()
  local function mongo_at(text, needle) return symbol_at("json", text, needle) end

  it("names the collection an operation targets", function()
    assert.same(
      { name = "orders", type = "collection", scope = { { name = "mydb", type = "database" } } },
      mongo_at('{"find": "orders", "db": "mydb"}', "orders"))
  end)

  it("names the database", function()
    assert.same(
      { name = "mydb", type = "database", scope = {} },
      mongo_at('{"find": "orders", "db": "mydb"}', "mydb"))
  end)

  it("scopes a filter key to its collection and database", function()
    assert.same(
      {
        name  = "status",
        type  = "field",
        scope = { { name = "orders", type = "collection" }, { name = "mydb", type = "database" } },
      },
      mongo_at('{"find": "orders", "db": "mydb", "filter": {"status": "open"}}', "status"))
  end)

  it("scopes a key nested under an update operator", function()
    assert.same(
      {
        name  = "age",
        type  = "field",
        scope = { { name = "users", type = "collection" }, { name = "mydb", type = "database" } },
      },
      mongo_at('{"updateOne": "users", "db": "mydb", "update": {"$set": {"age": 31}}}', "age"))
  end)

  it("resolves an aggregation field reference in a value", function()
    assert.same(
      {
        name  = "status",
        type  = "field",
        scope = { { name = "orders", type = "collection" }, { name = "mydb", type = "database" } },
      },
      mongo_at('{"aggregate": "orders", "db": "mydb", "pipeline": [{"$group": {"_id": "$status"}}]}',
        "$status"))
  end)

  it("ignores the command object's own structural keys", function()
    assert.is_nil(mongo_at('{"find": "orders", "db": "mydb", "filter": {"status": "open"}}', "filter"))
    assert.is_nil(mongo_at('{"find": "orders", "db": "mydb"}', "find"))
  end)

  it("ignores dollar-prefixed operators", function()
    assert.is_nil(
      mongo_at('{"updateOne": "users", "db": "mydb", "update": {"$set": {"age": 31}}}', "$set"))
  end)

  it("returns nil for JSON that is not a Mongo command", function()
    assert.is_nil(mongo_at('{"query": {"match": {"title": "test"}}}', "title"))
  end)
end)
