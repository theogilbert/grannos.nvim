local query_params = require("grannos.query_params")

describe("query_params.find", function()
  it("returns each distinct parameter in order of first appearance", function()
    local params = query_params.find("SELECT * FROM t WHERE a = {{a}} AND b IN ({{bs[]}}) AND c = {{ a }}")
    assert.are.same({ { name = "a", list = false }, { name = "bs", list = true } }, params)
  end)

  it("ignores placeholders in strings, quoted identifiers and comments", function()
    local sql = table.concat({
      "SELECT '{{s}}', \"{{q}}\", $$ {{d}} $$, $tag$ {{t}} $tag$ -- {{c}}",
      "/* {{b}} */ FROM t WHERE x = {{x}} AND y = 'it''s {{s2}}'",
    }, "\n")
    assert.are.same({ { name = "x", list = false } }, query_params.find(sql))
  end)

  it("leaves malformed braces alone", function()
    assert.are.same({}, query_params.find("SELECT '{' || x FROM t WHERE m = {{1x}} OR n = {{x[}}"))
  end)

  it("rejects a name used both as a scalar and a list", function()
    local params, err = query_params.find("SELECT {{a}}, {{a[]}}")
    assert.is_nil(params)
    assert.truthy(err:find("both"))
  end)
end)

describe("query_params.bind", function()
  local values = { id = "42", ids = { "1", "2", "3" }, none = {} }

  it("uses ? markers, binding a scalar once per occurrence", function()
    local q, binds = query_params.bind("SELECT * FROM t WHERE id = {{id}} OR parent = {{id}}", "sqlite", values)
    assert.are.equal("SELECT * FROM t WHERE id = ? OR parent = ?", q)
    assert.are.same({ "42", "42" }, binds)
  end)

  it("expands a list to one marker per item", function()
    local q, binds = query_params.bind("SELECT * FROM t WHERE id IN ({{ids[]}}) AND x = {{id}}", "duckdb", values)
    assert.are.equal("SELECT * FROM t WHERE id IN (?, ?, ?) AND x = ?", q)
    assert.are.same({ "1", "2", "3", "42" }, binds)
  end)

  it("turns an empty list into NULL", function()
    local q, binds = query_params.bind("SELECT * FROM t WHERE id IN ({{none[]}})", "sqlserver", values)
    assert.are.equal("SELECT * FROM t WHERE id IN (NULL)", q)
    assert.are.same({}, binds)
  end)

  it("numbers Oracle markers by position", function()
    local q, binds = query_params.bind("SELECT * FROM t WHERE id IN ({{ids[]}}) OR id = {{id}}", "oracle", values)
    assert.are.equal("SELECT * FROM t WHERE id IN (:1, :2, :3) OR id = :4", q)
    assert.are.same({ "1", "2", "3", "42" }, binds)
  end)

  it("doubles literal % for Postgres when anything is bound", function()
    local q = query_params.bind("SELECT '100%' FROM t WHERE n LIKE 'a%' AND id = {{id}}", "postgres", values)
    assert.are.equal("SELECT '100%%' FROM t WHERE n LIKE 'a%%' AND id = %s", q)
  end)

  it("leaves % alone for Postgres when nothing is bound", function()
    local q, binds = query_params.bind("SELECT 'a%' WHERE id IN ({{none[]}})", "postgres", values)
    assert.are.equal("SELECT 'a%' WHERE id IN (NULL)", q)
    assert.are.same({}, binds)
  end)

  it("leaves the query untouched for a driver without parameters", function()
    local q, binds = query_params.bind("MATCH (n {id: {{id}}}) RETURN n", "neo4j", values)
    assert.are.equal("MATCH (n {id: {{id}}}) RETURN n", q)
    assert.are.same({}, binds)
  end)
end)

describe("query_params.parse_list", function()
  it("takes one trimmed item per non-blank line", function()
    assert.are.same({ "a", "b c", "d" }, query_params.parse_list("  a\n\nb c \n\td\n"))
  end)
end)

describe("query_params.declarations", function()
  it("reads a description and choices from a comment line", function()
    local decls = query_params.declarations(table.concat({
      "-- {{status}}: Order status = active | 'shipped' | cancelled",
      "-- {{ids[]}} customer ids",
      "SELECT * FROM t WHERE s = {{status}} -- {{not_a_decl}}: no",
    }, "\n"))
    assert.are.same({ description = "Order status", choices = { "active", "shipped", "cancelled" } }, decls.status)
    assert.are.same({ description = "customer ids" }, decls.ids)
    assert.is_nil(decls.not_a_decl)
  end)

  it("keeps a single = in the description rather than taking one choice", function()
    local decls = query_params.declarations("-- {{n}}: rows where x = 1")
    assert.are.same({ description = "rows where x = 1" }, decls.n)
  end)

  it("takes choices alone, and merges a later declaration into an earlier one", function()
    local decls = query_params.declarations("-- {{s}} = a | b\n-- {{s}}: the s")
    assert.are.same({ description = "the s", choices = { "a", "b" } }, decls.s)
  end)
end)

describe("query_params.prompt", function()
  local form = require("grannos.ui.conn_form")
  local orig

  before_each(function() orig = form.open end)
  after_each(function() form.open = orig end)

  it("turns declared choices into a dropdown, a multi-select and hints", function()
    local opened
    form.open = function(opts) opened = opts end
    query_params.prompt("k-decl", { { name = "s", list = false }, { name = "xs", list = true }, { name = "t", list = false } },
      function() end,
      { s = { description = "status", choices = { "a", "b" } }, xs = { choices = { "x", "y" } } })
    local s, xs, t = opened.fields[1], opened.fields[2], opened.fields[3]
    assert.are.equal("choice", s.kind)
    assert.are.equal("status", s.hint)
    assert.are.equal("a", s.get())  -- first choice by default
    assert.are.same({ "a", "b", "other…" }, vim.tbl_map(function(o) return o.label end, s.options()))
    assert.are.equal("multichoice", xs.kind)
    xs.commit_selection({ "y" })
    assert.are.same({ "y" }, xs.get())
    assert.are.equal("text", t.kind)
    assert.is_nil(t.hint)
  end)
end)
