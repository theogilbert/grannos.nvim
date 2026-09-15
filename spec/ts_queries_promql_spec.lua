-- Statement extraction in PromQL buffers, where the grammar delimits queries
-- by blank lines rather than a terminator.
local ts_queries = require("grannos.ts_queries")

--- Create a PromQL buffer holding `lines`, current in the window.
--- @param lines string[]
--- @return integer
local function promql_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "promql"
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

describe("ts_queries in a PromQL buffer", function()
  it("finds the multi-line query under the cursor", function()
    promql_buf({ "sum by (job) (", "  rate(http_requests_total[5m])", ")", "", "up" })
    vim.api.nvim_win_set_cursor(0, { 2, 4 })
    local stmt = ts_queries.statement_at_cursor(0)
    assert.equals("sum by (job) (\n  rate(http_requests_total[5m])\n)", stmt.text)
    assert.equals(0, stmt.start_row)
    assert.equals(2, stmt.end_row)
  end)

  it("finds the query after a blank line, not the one before it", function()
    promql_buf({ "sum by (job) (", "  rate(http_requests_total[5m])", ")", "", "up" })
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    assert.equals("up", ts_queries.statement_at_cursor(0).text)
  end)

  it("lists every query a range overlaps", function()
    local buf = promql_buf({ "up", "", "absent(up)", "", "rate(x[5m])" })
    local stmts = ts_queries.statements_in_range(buf, 0, 2)
    assert.equals(2, #stmts)
    assert.equals("up", stmts[1].text)
    assert.equals("absent(up)", stmts[2].text)
  end)
end)
