-- Stubs must be installed before the modules under test require them.

--- Requests the stub client has received and not yet answered, in order.
--- @type { method: string, params: table, cb: fun(err: string|nil, result: table|nil) }[]
local pending = {}

package.loaded["grannos.client"] = {
  capabilities = function() return { drivers = {} } end,
  request      = function(method, params, cb)
    -- "connect" answers straight away, as does the completion cache's own
    -- listing; only the symbol lookups are left outstanding, so a test can
    -- inspect what the UI shows while the backend is still thinking.
    if method == "connect" then
      cb(nil, { connection_id = 1 })
      return 0
    end
    if method == "explore.list" then
      cb(nil, { items = {} })
      return 0
    end
    pending[#pending + 1] = { method = method, params = params, cb = cb }
    return #pending
  end,
}

require("grannos.config").setup()

local grannos     = require("grannos")
local connections = require("grannos.connections")

local BUSY_NS = vim.api.nvim_create_namespace("GrannosSymbolBusy")

--- Text of every in-flight-indicator mark in `bufnr`, in row order.
--- @param bufnr integer
--- @return { row: integer, text: string }[]
local function busy_marks(bufnr)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, BUSY_NS, 0, -1, { details = true })) do
    local chunk = m[4].virt_text and m[4].virt_text[1]
    out[#out + 1] = { row = m[2], text = chunk and chunk[1] or "" }
  end
  table.sort(out, function(a, b) return a.row < b.row end)
  return out
end

--- Answer the oldest outstanding request with `result`.
--- @param result table
--- @return string  the method that was answered
local function answer(result)
  local req = assert(table.remove(pending, 1), "no request in flight")
  req.cb(nil, result)
  vim.wait(200, function() return false end)  -- let the scheduled handler run
  return req.method
end

--- Open a connected query buffer holding `text`, cursor on the first `needle`.
--- @param text   string
--- @param needle string
--- @param ft     string|nil  filetype, "sql" by default
--- @return integer  bufnr
local function connected_buf(text, needle, ft)
  local key = connections.conn_key("local", ft == "cypher" and "neo4j" or "postgres", "", "test")
  grannos._send_connect(key, {})

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n"))
  vim.bo[buf].filetype = ft or "sql"
  vim.api.nvim_win_set_buf(0, buf)
  grannos.set_buf_conn(buf, key)
  vim.api.nvim_win_set_cursor(0, { 1, assert(text:find(needle, 1, true)) - 1 })
  return buf
end

describe("describe_symbol_at_cursor progress", function()
  before_each(function() pending = {} end)

  it("marks the symbol's line while the lookup is in flight", function()
    local buf = connected_buf("SELECT * FROM users;", "users")

    grannos.describe_symbol_at_cursor()

    assert.equals("explore.find", pending[1] and pending[1].method)
    local marks = busy_marks(buf)
    assert.equals(1, #marks)
    assert.equals(0, marks[1].row)
    assert.truthy(marks[1].text:find("users", 1, true))
  end)

  it("keeps an indicator up across the find → describe handover", function()
    local buf = connected_buf("SELECT * FROM users;", "users")
    grannos.describe_symbol_at_cursor()

    assert.equals("explore.find", answer({ paths = { { "public", "users" } } }))

    -- The describe is now the outstanding request, and the line still says so.
    assert.equals("explore.describe", pending[1] and pending[1].method)
    local marks = busy_marks(buf)
    assert.equals(1, #marks)
    assert.truthy(marks[1].text:find("users", 1, true))
  end)

  it("clears the indicator once the lookup finishes", function()
    local buf = connected_buf("SELECT * FROM users;", "users")
    grannos.describe_symbol_at_cursor()
    answer({ paths = { { "public", "users" } } })
    answer({ details = vim.NIL })  -- nothing to describe: notifies and stops

    assert.same({}, busy_marks(buf))
  end)
end)

describe("symbol keys in a Cypher buffer", function()
  before_each(function() pending = {} end)

  it("K sends a label-scoped property find, then describes the path found", function()
    connected_buf("MATCH (p:Person) RETURN p.born", "born", "cypher")
    grannos.describe_symbol_at_cursor()

    local req = assert(pending[1])
    assert.equals("explore.find", req.method)
    assert.equals("property", req.params.type)
    assert.equals("born", req.params.name)
    assert.same({ { name = "Person", type = "label" } }, req.params.scope)

    assert.equals("explore.find", answer({ paths = { { "entities", "Person", "properties", "born" } } }))
    assert.equals("explore.describe", pending[1] and pending[1].method)
    assert.same({ "entities", "Person", "properties", "born" }, pending[1].params.path)
  end)

  it("K on a label finds it unscoped", function()
    connected_buf("MATCH (p:Person)-[:ACTED_IN]->(m:Movie) RETURN m", "ACTED_IN", "cypher")
    grannos.describe_symbol_at_cursor()
    local req = assert(pending[1])
    assert.equals("relationship_type", req.params.type)
    assert.equals("ACTED_IN", req.params.name)
    assert.same({}, req.params.scope)
  end)

  it("<C-]> resolves the same way before revealing the node", function()
    connected_buf("MATCH (p:Person) RETURN p", "Person", "cypher")
    grannos.goto_symbol_at_cursor()
    local req = assert(pending[1])
    assert.equals("explore.find", req.method)
    assert.equals("label", req.params.type)
    assert.equals("Person", req.params.name)
  end)
end)
