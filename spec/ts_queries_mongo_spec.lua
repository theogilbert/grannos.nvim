-- Statement extraction and write detection in MongoDB buffers, where a
-- statement is one command object and nothing separates two.
local ts_queries = require("grannos.ts_queries")

--- Create a MongoDB buffer holding `lines`, current in the window.
--- @param lines string[]
--- @return integer
local function mongo_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "mongo"
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

describe("ts_queries in a MongoDB buffer", function()
  it("finds the multi-line command under the cursor", function()
    mongo_buf({
      '{"aggregate": "orders", "db": "mydb", "pipeline": [',
      '  {"$group": {"_id": "$status", "total": {"$sum": "$amount"}}}',
      ']}',
      '{"find": "orders", "db": "mydb"}',
    })
    vim.api.nvim_win_set_cursor(0, { 2, 10 })
    local stmt = ts_queries.statement_at_cursor(0)
    assert.equals(0, stmt.start_row)
    assert.equals(2, stmt.end_row)
    assert.equals('{"aggregate": "orders", "db": "mydb", "pipeline": [\n'
      .. '  {"$group": {"_id": "$status", "total": {"$sum": "$amount"}}}\n]}', stmt.text)
  end)

  it("finds the command on the next line, not the one before it", function()
    mongo_buf({ '{"find": "orders", "db": "mydb"}', '{"find": "users", "db": "mydb"}' })
    vim.api.nvim_win_set_cursor(0, { 2, 5 })
    assert.equals('{"find": "users", "db": "mydb"}', ts_queries.statement_at_cursor(0).text)
  end)

  it("leaves a comment ahead of the command out of its text", function()
    mongo_buf({ "// open orders", '{"find": "orders", "db": "mydb"}' })
    vim.api.nvim_win_set_cursor(0, { 2, 5 })
    assert.equals('{"find": "orders", "db": "mydb"}', ts_queries.statement_at_cursor(0).text)
  end)

  it("lists every command a range overlaps", function()
    local buf = mongo_buf({
      '{"find": "a", "db": "mydb"}',
      '{"find": "b",',
      ' "db": "mydb"}',
      '{"find": "c", "db": "mydb"}',
    })
    local stmts = ts_queries.statements_in_range(buf, 1, 2)
    assert.equals(1, #stmts)
    assert.equals('{"find": "b",\n "db": "mydb"}', stmts[1].text)
    assert.equals(3, #ts_queries.statements_in_range(buf, 0, 3))
  end)

  it("tells a writing operation from a reading one", function()
    local buf = mongo_buf({
      '{"find": "orders", "db": "mydb", "filter": {"deleteOne": true}}',
      '{"deleteOne": "orders", "db": "mydb", "filter": {"status": "cancelled"}}',
      '{"updateMany": "users", "db": "mydb", "update": {"$set": {"x": 1}}}',
    })
    assert.is_false(ts_queries.has_write_statement(buf, 0, 0))
    assert.is_true(ts_queries.has_write_statement(buf, 1, 1))
    assert.is_true(ts_queries.has_write_statement(buf, 2, 2))
    assert.is_true(ts_queries.has_write_statement(buf, 0, 2))
  end)
end)
