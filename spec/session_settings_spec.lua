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
    session_gets = {}  -- drop the session.get the connect itself sends
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

describe("connection label", function()
  before_each(function()
    vim.notify = function() end
    grannos._send_connect(KEY, {})
  end)

  after_each(close_all)

  --- Text of the "Connected to …" label in the current window, if any.
  --- @return string|nil
  local function label_text()
    return require("grannos.ui.conn_label").text(vim.api.nvim_get_current_win())
  end

  it("shows the connection's session values in parentheses", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    grannos.set_buf_conn(buf, KEY)

    assert.equals("Connected to metrics (Prometheus) (query_mode=instant)", label_text())
  end)

  it("shows in the winbar, leaving the buffer unmodified", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "up" })
    vim.bo[buf].modified = false
    vim.api.nvim_win_set_buf(0, buf)
    grannos.set_buf_conn(buf, KEY)
    assert.same({ "up" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_false(vim.bo[buf].modified)
    assert.truthy(vim.wo.winbar:find("Connected to metrics", 1, true))
  end)

  it("gives the window back its own winbar when the buffer is detached", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    vim.wo.winbar = "mine"
    grannos.set_buf_conn(buf, KEY)
    assert.are_not.equal("mine", vim.wo.winbar)
    grannos.set_buf_conn(buf, nil)
    assert.equals("mine", vim.wo.winbar)
    vim.wo.winbar = ""
  end)

  it("does not carry over into a split showing another buffer", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    grannos.set_buf_conn(buf, KEY)
    vim.cmd("split")
    assert.truthy(vim.wo.winbar:find("Connected to", 1, true))
    vim.cmd("enew")
    assert.equals("", vim.wo.winbar)
    vim.cmd("close")
  end)
end)
