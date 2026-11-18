-- Editor support for query parameters in a connected buffer: the hover key
-- on a placeholder, and completing placeholder names.
-- Stubs must be installed before the modules under test require them.
package.loaded["grannos.client"] = {
  capabilities = function() return { drivers = {} } end,
  request      = function(method, _params, cb)
    if method == "connect" then cb(nil, { connection_id = 1 }) end
    return 0
  end,
}

require("grannos.config").setup()

local hover       = require("grannos.ui.hover")
local grannos     = require("grannos")
local connections = require("grannos.connections")

--- Open a SQL buffer holding `lines` connected to a `driver` connection,
--- cursor on the first `needle`.
--- @param lines  string[]
--- @param needle string
--- @param driver string
--- @return integer
local function sql_buf(lines, needle, driver)
  local key = connections.conn_key("local", driver, "", "test")
  grannos._send_connect(key, {})
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "sql"
  vim.api.nvim_win_set_buf(0, buf)
  grannos.set_buf_conn(buf, key)
  for row, line in ipairs(lines) do
    local col = line:find(needle, 1, true)
    if col then vim.api.nvim_win_set_cursor(0, { row, col - 1 }) break end
  end
  return buf
end

--- Return the lines of the open hover float.
--- @return string[]
local function float_lines()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
    end
  end
  return {}
end

describe("hover key on a query parameter", function()
  after_each(function() hover.close() end)

  it("shows the placeholder's declaration", function()
    sql_buf({ "-- {{status}}: Order status = a | b", "SELECT * FROM t WHERE s = {{status}}" }, "{{status}}", "sqlite")
    vim.api.nvim_win_set_cursor(0, { 2, 30 })
    grannos.describe_symbol_at_cursor()
    assert.is_true(hover.is_open())
    assert.same({ "{{status}}  query parameter", "Order status", "choices: a | b" }, float_lines())
  end)

  it("is not offered on a driver without parameters", function()
    sql_buf({ "MATCH (n {id: {{id}}}) RETURN n" }, "{{id}}", "neo4j")
    grannos.describe_symbol_at_cursor()
    assert.is_false(hover.is_open())
  end)
end)
