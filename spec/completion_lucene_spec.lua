-- Completion in Lucene buffers, against a canned Elasticsearch explore tree.
-- Stubs must be installed before the modules under test require them.
local requests = {}

--- Canned explore.list responses, keyed by NUL-joined path, in the shape the
--- Elasticsearch driver lists: index → mappings → field, with a pattern's
--- mappings merged server-side.
local TREE = {
  [""]                       = { { name = "logs-2024.01", type = "index", expandable = true },
                                 { name = "logs-2024.02", type = "index", expandable = true },
                                 { name = "orders",       type = "index", expandable = true } },
  ["orders\0mappings"]       = { { name = "@timestamp", type = "date" },
                                 { name = "customer",   type = "object" },
                                 { name = "customer.name", type = "keyword" },
                                 { name = "status",     type = "keyword" },
                                 { name = "total",      type = "float" } },
  ["logs-*\0mappings"]       = { { name = "@timestamp", type = "date" },
                                 { name = "level",      type = "keyword" },
                                 { name = "message",    type = "text" } },
  ["logs-2024.01\0mappings"] = { { name = "@timestamp", type = "date" },
                                 { name = "level",      type = "keyword" } },
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
local lucene     = require("grannos.completion.lucene")
local config     = require("grannos.config")

--- Create a Lucene buffer holding `lines`, attached for completion.
--- @param lines string[]
--- @return integer
local function lucene_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "lucene"
  vim.api.nvim_set_current_buf(buf)
  completion.attach(buf, "conn")
  return buf
end

--- Place the cursor at the "¦" marker in `lines` and return the buffer, the
--- 0-indexed row, and the cursor's byte column. The marker is not "|", which
--- is Lucene's own index separator.
--- @param lines string[]
--- @return integer, integer, integer
local function at_marker(lines)
  local row, col
  local clean = {}
  for i, l in ipairs(lines) do
    local before, after = l:match("^(.-)¦(.*)$")
    if before then
      row, col = i - 1, #before
      clean[i] = before .. after
    else
      clean[i] = l
    end
  end
  return lucene_buf(clean), row, col
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

describe("completion.lucene.word_start", function()
  it("keeps dots and an at-sign inside a word", function()
    assert.equals(9, lucene.word_start("orders | customer.na", 20))
    assert.equals(9, lucene.word_start("orders | @timest", 16))
  end)

  it("keeps dashes, dots and a wildcard inside an index name", function()
    assert.equals(0, lucene.word_start("logs-2024.*", 11))
    assert.equals(7, lucene.word_start("orders,logs-20", 14))
  end)

  it("leaves a leading dash out of the word", function()
    assert.equals(10, lucene.word_start("orders | -sta", 13))
    assert.equals(8, lucene.word_start("orders,-logs", 12))
  end)

  it("starts after a colon", function()
    assert.equals(16, lucene.word_start("orders | status:op", 18))
  end)
end)

describe("completion.lucene.at_cursor", function()
  before_each(function() config.setup({}) end)

  --- Classify the position at the "¦" marker in `lines`.
  --- @param lines string[]
  --- @return LuceneCompletionContext|nil
  local function classify(lines)
    local buf, row, col = at_marker(lines)
    local text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    return lucene.at_cursor(buf, row, lucene.word_start(text, col), col)
  end

  it("classifies an empty buffer and a bare word as an index position", function()
    assert.equals("index", classify({ "¦" }).kind)
    assert.equals("index", classify({ "ord¦" }).kind)
  end)

  it("classifies the next name of an index list as an index position", function()
    assert.equals("index", classify({ "orders,¦" }).kind)
    assert.equals("index", classify({ "orders,lo¦ | *" }).kind)
  end)

  it("classifies a bare term after the pipe as a field position", function()
    local ctx = classify({ "orders | ¦" })
    assert.equals("field", ctx.kind)
    assert.same({ "orders" }, ctx.indices)
    assert.same({ "orders" }, classify({ "orders | sta¦" }).indices)
    assert.same({ "orders" }, classify({ "orders | status:open AND ¦" }).indices)
    assert.same({ "orders" }, classify({ "orders | status:open OR NOT ¦" }).indices)
    assert.same({ "orders" }, classify({ "orders | -¦" }).indices)
  end)

  it("classifies the term ahead of a colon as a field position", function()
    assert.equals("field", classify({ "orders | sta¦:open" }).kind)
  end)

  it("classifies a term inside a group as a field position, closed or not", function()
    assert.equals("field", classify({ "orders | (¦" }).kind)
    assert.equals("field", classify({ "orders | (status:open OR ¦)" }).kind)
  end)

  it("classifies the value of _exists_ as a field position", function()
    assert.equals("field", classify({ "orders | _exists_:¦" }).kind)
    assert.equals("field", classify({ "orders | _exists_:cust¦" }).kind)
  end)

  it("lists every index the query names, a pattern as written, an exclusion left out", function()
    assert.same({ "orders", "logs-*" }, classify({ "orders,logs-* | ¦" }).indices)
    assert.same({ "logs-*" }, classify({ "logs-*,-logs-2024.01 | ¦" }).indices)
  end)

  it("follows a query across lines", function()
    assert.same({ "orders" }, classify({ "orders |", "  status:open", "  AND ¦" }).indices)
    assert.equals("index", classify({ "ord¦", "| status:open" }).kind)
  end)

  it("parses the cursor's query alone in a buffer holding several", function()
    assert.same({ "logs-*" }, classify({ "orders | status:open", "", "logs-* | ¦" }).indices)
    assert.same({ "orders" }, classify({ "-- open orders", "orders | ¦", "", "logs-* | level:error" }).indices)
    assert.equals("index", classify({ "orders | status:open", "", "lo¦" }).kind)
  end)

  it("returns nil for a field's value", function()
    assert.is_nil(classify({ "orders | status:¦" }))
    assert.is_nil(classify({ "orders | status:op¦" }))
    assert.is_nil(classify({ "orders | total:>¦" }))
    assert.is_nil(classify({ "orders | status:(open OR ¦" }))
    assert.is_nil(classify({ "orders | status:(open OR ¦)" }))
  end)

  it("returns nil inside a phrase, a regex or a range", function()
    assert.is_nil(classify({ 'orders | status:"op¦' }))
    assert.is_nil(classify({ 'orders | status:"op¦"' }))
    assert.is_nil(classify({ "orders | total:[1 TO ¦]" }))
    assert.is_nil(classify({ "orders | total:[¦" }))
  end)
end)

describe("completion.omnifunc in a Lucene buffer", function()
  before_each(function()
    config.setup({})
    completion.invalidate()
    requests = {}
  end)

  it("offers index names in an empty buffer, annotated as such", function()
    assert.same({ { word = "logs-2024.01", kind = "i", menu = "index" },
                  { word = "logs-2024.02", kind = "i", menu = "index" },
                  { word = "orders",       kind = "i", menu = "index" } }, complete_items({ "¦" }))
  end)

  it("filters index names by the typed prefix, dashes and dots included", function()
    assert.same({ "logs-2024.01", "logs-2024.02" }, complete({ "logs-¦" }))
    assert.same({ "logs-2024.02" }, complete({ "orders,logs-2024.02¦ | *" }))
  end)

  it("offers the fields of the query's index with their types", function()
    assert.same({ { word = "@timestamp",    kind = "f", menu = "date" },
                  { word = "customer",      kind = "f", menu = "object" },
                  { word = "customer.name", kind = "f", menu = "keyword" },
                  { word = "status",        kind = "f", menu = "keyword" },
                  { word = "total",         kind = "f", menu = "float" } }, complete_items({ "orders | ¦" }))
  end)

  it("filters fields by the typed prefix, dotted paths included", function()
    assert.same({ "customer", "customer.name" }, complete({ "orders | cust¦" }))
    assert.same({ "customer.name" }, complete({ "orders | customer.n¦" }))
    assert.same({ "@timestamp" }, complete({ "orders | @¦" }))
    assert.same({ "status" }, complete({ "orders | -st¦" }))
  end)

  it("asks the server for a pattern's mappings as written", function()
    assert.same({ "@timestamp", "level", "message" }, complete({ "logs-* | ¦" }))
    assert.same({ "logs-*\0mappings" }, vim.tbl_filter(function(k) return k:find("mappings", 1, true) end, requests))
  end)

  it("merges the fields of every index the query names", function()
    assert.same({ "@timestamp", "customer", "customer.name", "level", "status", "total" },
      complete({ "orders,logs-2024.01 | ¦" }))
  end)

  it("offers fields after _exists_", function()
    assert.same({ "status" }, complete({ "orders | _exists_:st¦" }))
  end)

  it("offers nothing for a field's value or with no index named", function()
    assert.same({}, complete({ "orders | status:¦" }))
    assert.same({}, complete({ " | ¦" }))
  end)

  it("lists each path once however many keystrokes ask for it", function()
    complete({ "orders | ¦" })
    complete({ "orders | st¦" })
    complete({ "orders | status:open AND ¦" })
    local mappings = vim.tbl_filter(function(k) return k == "orders\0mappings" end, requests)
    assert.equals(1, #mappings)
  end)
end)
