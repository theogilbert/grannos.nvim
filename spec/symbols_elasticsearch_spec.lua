-- Symbol extraction in Elasticsearch buffers: Lucene queries and Console
-- (Dev Tools) requests, for the describe and reveal keys.
local symbols = require("grannos.symbols")

--- Describe the symbol under a cursor placed at the first occurrence of
--- `needle` (or its `nth` occurrence) in a scratch buffer of filetype `ft`
--- holding `lines`.
--- @param ft     string
--- @param lines  string[]
--- @param needle string  substring whose first character positions the cursor
--- @param nth    integer|nil  which occurrence, 1 by default
--- @return SymbolQuery|nil
local function symbol_at(ft, lines, needle, nth)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  vim.api.nvim_win_set_buf(0, buf)
  local seen = 0
  for row, line in ipairs(lines) do
    local init = 1
    while true do
      local col = line:find(needle, init, true)
      if not col then break end
      seen = seen + 1
      if seen == (nth or 1) then
        vim.api.nvim_win_set_cursor(0, { row, col - 1 })
        return symbols.at_cursor(buf)
      end
      init = col + 1
    end
  end
  error("needle not found: " .. needle)
end

local function index(name) return { name = name, type = "index", scope = {} } end

--- A field query scoped to `indices`.
--- @param name    string
--- @param indices string[]
--- @return SymbolQuery
local function field(name, indices)
  return {
    name = name, type = "field",
    scope = vim.tbl_map(function(i) return { name = i, type = "index" } end, indices),
  }
end

describe("symbols.at_cursor for Lucene", function()
  local function at(text, needle, nth) return symbol_at("lucene", { text }, needle, nth) end

  it("names the target under the cursor as an index, an exclusion included", function()
    assert.same(index("orders"), at("orders,-archive | *", "orders"))
    assert.same(index("archive"), at("orders,-archive | *", "archive"))
  end)

  it("names nothing for a pattern", function()
    assert.is_nil(at("logs-* | *", "logs"))
  end)

  it("scopes a field to the query's indices, patterns and exclusions left out", function()
    assert.same(field("status", { "orders", "sales" }),
      at("orders,sales,logs-*,-old | status:open", "status"))
  end)

  it("names the value of _exists_ as a field", function()
    assert.same(field("user.name", { "orders" }), at("orders | _exists_:user.name", "user.name"))
  end)

  it("names nothing for a plain value", function()
    assert.is_nil(at("orders | status:open", "open"))
  end)
end)

describe("symbols.at_cursor for Elasticsearch Console", function()
  local REQUEST = {
    "GET /orders,sales/_search",
    "{",
    '  "query": {"bool": {"filter": [{"term": {"status": "open"}},',
    '                                {"range": {"total": {"gte": 5}}}]}},',
    '  "sort": [{"created_at": "desc"}],',
    '  "_source": ["customer.name"],',
    '  "aggs": {"by": {"terms": {"field": "region"}}}',
    "}",
  }
  local function at(needle, nth) return symbol_at("esconsole", REQUEST, needle, nth) end

  it("names the target under the cursor as an index", function()
    assert.same(index("orders"), at("orders"))
    assert.same(index("sales"), at("sales"))
  end)

  it("names nothing for an endpoint", function()
    assert.is_nil(at("_search"))
  end)

  it("names fields keyed by a leaf query, scoped to the request's targets", function()
    assert.same(field("status", { "orders", "sales" }), at("status"))
    assert.same(field("total", { "orders", "sales" }), at("total"))
  end)

  it("names fields keyed by a sort clause and listed in _source", function()
    assert.same(field("created_at", { "orders", "sales" }), at("created_at"))
    assert.same(field("customer.name", { "orders", "sales" }), at("customer.name"))
  end)

  it("names the value of field", function()
    assert.same(field("region", { "orders", "sales" }), at("region"))
  end)

  it("names nothing for DSL keys or plain values", function()
    assert.is_nil(at("query"))
    assert.is_nil(at("open"))
    assert.is_nil(at("gte"))
  end)

  it("scopes a field unscoped when the request targets no index", function()
    assert.same(field("status", {}),
      symbol_at("esconsole", { "GET _search", '{"query": {"term": {"status": 1}}}' }, "status"))
  end)

  it("names nothing on a placeholder", function()
    assert.is_nil(symbol_at("esconsole", { "GET /{{index}}/_search" }, "index"))
  end)
end)
