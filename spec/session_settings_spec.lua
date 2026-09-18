-- The public `open_session_settings()` API (what a user keymap calls) resolves
-- the connection of the buffer it is invoked from: a query buffer's attached
-- connection, or the connection a results pane shows results from.

--- session.get requests the stub client has received, by connection id.
--- @type any[]
local session_gets = {}

package.loaded["grannos.client"] = {
  capabilities = function()
    return { drivers = { { driver = "prom", label = "Prometheus", params = {},
      session_params = { { key = "query_mode", type = "string", label = "Query mode" } } } } }
  end,
  request = function(method, params, cb)
    if method == "connect" then cb(nil, { connection_id = 7 }) end
    return 0
  end,
  get_session = function(conn_id, cb)
    table.insert(session_gets, conn_id)
    cb(nil, { query_mode = "instant" })
  end,
  set_session = function(_, _, cb) cb(nil) end,
}

require("grannos.config").setup()
require("grannos.hl").setup()
require("grannos.session_params").file = vim.fn.tempname()

local grannos     = require("grannos")
local connections = require("grannos.connections")
local results     = require("grannos.ui.results")

local KEY = connections.conn_key("local", "prom", "", "metrics")

--- Close every window but one, floats first, so each test starts from a
--- single plain window.
local function close_all()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_config(w).relative ~= "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  vim.cmd("silent! only")
end

--- The floating window currently open, if any.
--- @return integer|nil
local function float_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then return w end
  end
end

describe("open_session_settings", function()
  local notices

  before_each(function()
    session_gets = {}
    notices      = {}
    vim.notify   = function(msg) table.insert(notices, msg) end
    grannos._send_connect(KEY, {})
  end)

  after_each(close_all)

  it("targets the connection the current query buffer is attached to", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    grannos.set_buf_conn(buf, KEY)

    grannos.open_session_settings()

    assert.same({ 7 }, session_gets)
    assert.truthy(float_win())
  end)

  it("targets the connection a results pane shows results from", function()
    local src = vim.api.nvim_create_buf(true, false)
    vim.bo[src].filetype = "promql"
    results.set_conn_name(KEY, "Prometheus", src)
    results.show_results({ "value" }, { { 1 } }, 1, 1, 1.0)
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if results.is_results_buf(vim.api.nvim_win_get_buf(w)) then vim.api.nvim_set_current_win(w) end
    end
    assert.truthy(results.is_results_buf(vim.api.nvim_get_current_buf()))

    grannos.open_session_settings()

    assert.same({ 7 }, session_gets)
    assert.truthy(float_win())
  end)

  it("warns from a buffer that is neither", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)

    grannos.open_session_settings()

    assert.same({}, session_gets)
    assert.is_nil(float_win())
    assert.truthy(notices[#notices]:find("no active connection", 1, true))
  end)
end)
