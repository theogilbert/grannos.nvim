-- Query parameters in Elasticsearch Dev Tools requests: found through the
-- esconsole grammar and substituted into the text, encoded for their place.
local query_params = require("grannos.query_params")
local connections  = require("grannos.connections")
local config       = require("grannos.config")

describe("query_params (esconsole)", function()
  local REQUEST = table.concat({
    "# {{index}}: Index to search",
    "GET /{{index}}/_search?routing={{r}}",
    '{"size": {{n}}, "query": {"terms": {"id": {{ids[]}}}},',
    ' "post_filter": {"match": {"status": "{{status}}"}}}',
  }, "\n")

  it("finds placeholders in the path, as values and inside strings, not in comments", function()
    assert.same({
      { name = "index",  list = false },
      { name = "r",      list = false },
      { name = "n",      list = false },
      { name = "ids",    list = true },
      { name = "status", list = false },
    }, query_params.find(REQUEST, "esconsole"))
  end)

  it("leaves SQL scanning to skip placeholders inside strings", function()
    assert.same({}, query_params.find('GET /x\n{"a": "{{x}}"}'))
  end)

  it("encodes each value for where it stands", function()
    local out = query_params.substitute(REQUEST, {
      index = "logs-*,app", r = "a/b c", n = "10", ids = { "1", "x\"y" }, status = 'say "hi"',
    })
    assert.equals(table.concat({
      "# {{index}}: Index to search",
      "GET /logs-*,app/_search?routing=a%2Fb%20c",
      '{"size": 10, "query": {"terms": {"id": [1,"x\\"y"]}},',
      ' "post_filter": {"match": {"status": "say \\"hi\\""}}}',
    }, "\n"), out)
  end)

  --- Substitute `values` into a request whose body is `body`, returning the body.
  --- @param body   string
  --- @param values table
  --- @return string
  local function sub_body(body, values)
    return (query_params.substitute("GET /x\n" .. body, values):gsub("^GET /x\n", ""))
  end

  it("keeps typed literals and quotes anything else as a JSON value", function()
    local text = '{"a": {{v}}}'
    assert.equals('{"a": true}', sub_body(text, { v = "true" }))
    assert.equals('{"a": null}', sub_body(text, { v = "null" }))
    assert.equals('{"a": -2.5e3}', sub_body(text, { v = "-2.5e3" }))
    assert.equals('{"a": "open"}', sub_body(text, { v = "open" }))
    assert.equals('{"a": "01"}', sub_body(text, { v = "01" }))
    assert.equals('{"a": " 1"}', sub_body(text, { v = " 1" }))
    assert.equals('{"a": 0.5}', sub_body(text, { v = "0.5" }))
  end)

  it("joins a list in a path or string with commas, and makes an empty value list an empty array", function()
    assert.equals("GET /a,b/_search", query_params.substitute("GET /{{i[]}}/_search", { i = { "a", "b" } }))
    assert.equals('{"q": "a,b"}', sub_body('{"q": "{{i[]}}"}', { i = { "a", "b" } }))
    assert.equals('{"q": []}', sub_body('{"q": {{i[]}}}', { i = {} }))
  end)

  it("binds Elasticsearch requests by substitution, with no positional binds", function()
    local q, binds = query_params.bind('GET /x/_search\n{"size": {{n}}}', "elasticsearch", { n = "5" })
    assert.equals('GET /x/_search\n{"size": 5}', q)
    assert.same({}, binds)
  end)

  it("reads # and // declaration comments", function()
    local decls = query_params.declarations("# {{a}}: first\n// {{b}}: second = x | y")
    assert.equals("first", decls.a.description)
    assert.same({ "x", "y" }, decls.b.choices)
  end)

  it("logs parameters under the dialect's own comment", function()
    assert.same({ "# parameters:", "#   a = 'x'" },
      query_params.format_logged({ { name = "a", list = false, value = "x" } }, "#"))
  end)

  describe("dialect", function()
    local tmp
    before_each(function()
      tmp = vim.fn.tempname() .. ".json"
      vim.fn.writefile({ vim.json.encode({ srv = { elasticsearch = { groups = { [""] = {
        dt  = { query_mode = "dev_tools" },
        luc = { query_mode = "lucene" },
      } } } } }) }, tmp)
      config.setup({ connections_file = tmp })
      connections.invalidate()
    end)
    after_each(function() pcall(vim.fn.delete, tmp) end)

    --- A ConnSession for connection `name` of `driver` on "srv".
    --- @param driver string
    --- @param name   string
    --- @return { driver: string, key: string }
    local function conn(driver, name)
      return { driver = driver, key = connections.conn_key("srv", driver, "", name) }
    end

    it("is esconsole only for Dev Tools mode, sql for binding drivers, else nil", function()
      assert.equals("esconsole", query_params.dialect(conn("elasticsearch", "dt")))
      assert.is_nil(query_params.dialect(conn("elasticsearch", "luc")))
      assert.equals("sql", query_params.dialect(conn("postgres", "x")))
      assert.is_nil(query_params.dialect(conn("neo4j", "x")))
      assert.is_false(query_params.supports(nil))
    end)
  end)
end)
