local devtools    = require("grannos.devtools")
local connections = require("grannos.connections")
local config      = require("grannos.config")

--- Create a scratch buffer holding `lines` and make it current.
--- @param lines string[]
--- @return integer
local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

describe("devtools.statements_in_range", function()
  local LINES = {
    "# list the orders",                 -- 0
    "GET /orders/_search",               -- 1
    "{",                                 -- 2
    '  "query": {"match_all": {}}',      -- 3
    "}",                                 -- 4
    "",                                  -- 5
    "// then the products",              -- 6
    "post /products/_search",            -- 7
    '{"query": {"term": {"get": "x"}}}', -- 8
    "",                                  -- 9
    "/* GET /ignored",                   -- 10
    "   GET /ignored */",                -- 11
    "GET _cat/indices",                  -- 12
  }

  it("splits a buffer into one statement per request", function()
    local bufnr = make_buf(LINES)
    local stmts = devtools.statements_in_range(bufnr, 0, #LINES - 1)
    assert.equals(3, #stmts)
    assert.equals('GET /orders/_search\n{\n  "query": {"match_all": {}}\n}', stmts[1].text)
    assert.equals(1, stmts[1].start_row)
    assert.equals(4, stmts[1].end_row)
    assert.equals('post /products/_search\n{"query": {"term": {"get": "x"}}}', stmts[2].text)
    assert.equals(7, stmts[2].start_row)
    assert.equals(8, stmts[2].end_row)
    assert.equals("GET _cat/indices", stmts[3].text)
    assert.equals(12, stmts[3].start_row)
  end)

  it("returns only the requests overlapping the range", function()
    local bufnr = make_buf(LINES)
    local stmts = devtools.statements_in_range(bufnr, 3, 8)
    assert.equals(2, #stmts)
    assert.equals(1, stmts[1].start_row)
    assert.equals(7, stmts[2].start_row)
  end)

  it("returns nil when no request overlaps the range", function()
    local bufnr = make_buf(LINES)
    assert.is_nil(devtools.statements_in_range(bufnr, 9, 11))
  end)
end)

describe("devtools.statement_at_cursor", function()
  it("returns the request whose body holds the cursor", function()
    local bufnr = make_buf({ "GET /a/_search", "{", '  "size": 1', "}", "", "GET /b/_search" })
    vim.api.nvim_win_set_cursor(0, { 3, 2 })
    local stmt = devtools.statement_at_cursor(bufnr)
    assert.equals('GET /a/_search\n{\n  "size": 1\n}', stmt.text)
  end)

  it("returns nil between requests", function()
    local bufnr = make_buf({ "GET /a/_search", "", "GET /b/_search" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    assert.is_nil(devtools.statement_at_cursor(bufnr))
  end)
end)

describe("devtools.applies", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname() .. ".json"
    vim.fn.writefile({ vim.json.encode({
      srv = {
        elasticsearch = { label = "Elasticsearch", groups = { [""] = {
          dsl    = { host = "localhost", query_mode = "dev_tools" },
          lucene = { host = "localhost", query_mode = "lucene" },
        } } },
        sqlite = { label = "SQLite", groups = { [""] = {
          db = { database = "/tmp/x.db", query_mode = "dev_tools" },
        } } },
      },
    }) }, tmp)
    config.setup({ connections_file = tmp })
    connections.invalidate()
  end)

  after_each(function()
    pcall(vim.fn.delete, tmp)
  end)

  --- A ConnSession for connection `name` of `driver` on "srv".
  --- @param driver string
  --- @param name   string
  --- @return { driver: string, key: string }
  local function conn(driver, name)
    return { driver = driver, key = connections.conn_key("srv", driver, "", name) }
  end

  it("is true for an Elasticsearch connection in Dev Tools mode", function()
    assert.is_true(devtools.applies(conn("elasticsearch", "dsl")))
  end)

  it("is false for any other query mode, driver, or no connection", function()
    assert.is_false(devtools.applies(conn("elasticsearch", "lucene")))
    assert.is_false(devtools.applies(conn("sqlite", "db")))
    assert.is_false(devtools.applies(nil))
  end)
end)

describe("esconsole write detection", function()
  local ts_queries = require("grannos.ts_queries")

  --- Return whether the single request `line` is detected as a write.
  --- @param line string
  --- @return boolean
  local function writes(line)
    local bufnr = make_buf({ line })
    vim.bo[bufnr].filetype = "esconsole"
    return ts_queries.has_write_statement(bufnr, 0, 0)
  end

  it("reads GET, HEAD and POSTs to read endpoints", function()
    assert.is_false(writes("GET /orders/_search"))
    assert.is_false(writes("head /orders"))
    assert.is_false(writes("POST /orders/_search"))
    assert.is_false(writes("POST _query"))
  end)

  it("writes PUT, DELETE and other POSTs", function()
    assert.is_true(writes("PUT /orders"))
    assert.is_true(writes("DELETE /orders/_doc/1"))
    assert.is_true(writes("POST _bulk"))
    assert.is_true(writes("POST /orders/_doc"))
  end)
end)
