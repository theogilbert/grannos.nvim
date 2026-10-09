-- A query file naming a saved connection in a `grannos: connection=…`
-- directive comment is attached to it on open, connecting first if needed.

--- connect requests the stub client has received.
--- @type table[]
local connects = {}

--- Whether the stub's next connect fails.
local fail_connect = false

package.loaded["grannos.client"] = {
  is_running         = function() return true end,
  set_exit_handler   = function() end,
  capabilities       = function() return { server = "srv", drivers = { { driver = "pg", label = "Postgres", params = {} } } } end,
  ensure_capabilities = function(cb) cb({ server = "srv", drivers = { { driver = "pg", label = "Postgres", params = {} } } }) end,
  request = function(method, params, cb)
    if method == "connect" then
      table.insert(connects, params)
      if fail_connect then cb("refused") else cb(nil, { connection_id = #connects }) end
    elseif method == "disconnect" then
      cb(nil, {})
    end
    return 0
  end,
  get_session = function(_, cb) cb(nil, {}) end,
  set_session = function(_, _, cb) cb(nil) end,
}

local directive   = require("grannos.directive")
local connections = require("grannos.connections")

describe("directive.parse_line", function()
  it("reads the name after any comment leader", function()
    assert.equals("prod", directive.parse_line("-- grannos: connection=prod"))
    assert.equals("team/prod", directive.parse_line("// grannos: connection = team/prod  "))
    assert.equals("prod", directive.parse_line("# grannos:connection=prod"))
  end)

  it("drops a trailing block-comment closer", function()
    assert.equals("prod", directive.parse_line("/* grannos: connection=prod */"))
    assert.equals("my db", directive.parse_line("<!-- grannos: connection=my db -->"))
  end)

  it("ignores lines without a directive", function()
    assert.is_nil(directive.parse_line("SELECT 1"))
    assert.is_nil(directive.parse_line("-- grannos: connection="))
  end)
end)

--- Return a scratch file buffer holding `lines`.
--- @param lines string[]
--- @return integer
local function buf_with(lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

describe("directive.connection", function()
  it("finds a directive in the last lines of a long file", function()
    local lines = {}
    for i = 1, 30 do lines[i] = "SELECT " .. i .. ";" end
    lines[29] = "-- grannos: connection=tail"
    assert.equals("tail", directive.connection(buf_with(lines)))
  end)

  it("ignores a directive in the middle of a long file", function()
    local lines = {}
    for i = 1, 30 do lines[i] = "SELECT " .. i .. ";" end
    lines[15] = "-- grannos: connection=middle"
    assert.is_nil(directive.connection(buf_with(lines)))
  end)
end)

describe("connections.find", function()
  local tmp
  before_each(function()
    tmp = vim.fn.tempname()
    require("grannos.config").setup({ connections_file = tmp })
    vim.fn.writefile({ vim.json.encode({ srv = {
      pg = { groups = { [""] = { prod = {}, dup = {} }, team = { prod = {}, staging = {} } } },
      my = { groups = { [""] = { dup = {} } } },
    } }) }, tmp)
    connections.invalidate()
  end)
  after_each(function() vim.fn.delete(tmp) connections.invalidate() end)

  it("prefers an exact display-name match", function()
    assert.equals(connections.conn_key("srv", "pg", "", "prod"), connections.find("srv", "prod"))
    assert.equals(connections.conn_key("srv", "pg", "team", "prod"), connections.find("srv", "team/prod"))
  end)

  it("falls back to a unique bare name", function()
    assert.equals(connections.conn_key("srv", "pg", "team", "staging"), connections.find("srv", "staging"))
  end)

  it("reports an ambiguous or unknown name", function()
    assert.same({ nil, nil, "ambiguous" }, { connections.find("srv", "dup") })
    assert.same({ nil, nil, "not found" }, { connections.find("srv", "nope") })
  end)
end)

describe("auto_attach", function()
  local grannos = require("grannos")
  local tmp, notices
  local KEY = connections.conn_key("srv", "pg", "team", "prod")

  before_each(function()
    tmp = vim.fn.tempname()
    require("grannos.config").setup({ connections_file = tmp })
    require("grannos.hl").setup()
    require("grannos.session_params").file = vim.fn.tempname()
    vim.fn.writefile({ vim.json.encode({ srv = { pg = { groups = { team = { prod = { host = "h" } } } } } }) }, tmp)
    connections.invalidate()
    connects, fail_connect, notices = {}, false, {}
    vim.notify = function(msg) table.insert(notices, msg) end
  end)

  after_each(function()
    if grannos.get_conn(KEY) then
      grannos.disconnect(KEY)
    end
    vim.fn.delete(tmp)
    connections.invalidate()
  end)

  it("connects and attaches a buffer naming a saved connection", function()
    local buf = buf_with({ "-- grannos: connection=team/prod", "SELECT 1;" })
    grannos.auto_attach(buf)
    assert.equals(1, #connects)
    assert.equals("h", connects[1].host)
    assert.same({ buf }, grannos.buffers_for(KEY))
  end)

  it("reuses an open connection", function()
    local a = buf_with({ "-- grannos: connection=prod" })
    local b = buf_with({ "-- grannos: connection=prod" })
    grannos.auto_attach(a)
    grannos.auto_attach(b)
    assert.equals(1, #connects)
    local bufs = grannos.buffers_for(KEY)
    table.sort(bufs)
    assert.same({ a, b }, bufs)
  end)

  it("warns about an unknown connection and leaves the buffer alone", function()
    local buf = buf_with({ "-- grannos: connection=nope" })
    grannos.auto_attach(buf)
    assert.equals(0, #connects)
    assert.truthy(notices[1]:find("not found", 1, true))
  end)

  it("ignores a buffer without a directive", function()
    grannos.auto_attach(buf_with({ "SELECT 1;" }))
    assert.equals(0, #connects)
    assert.equals(0, #notices)
  end)

  it("retries after a failed connect", function()
    fail_connect = true
    grannos.auto_attach(buf_with({ "-- grannos: connection=prod" }))
    fail_connect = false
    local buf = buf_with({ "-- grannos: connection=prod" })
    grannos.auto_attach(buf)
    assert.equals(2, #connects)
    assert.same({ buf }, grannos.buffers_for(KEY))
  end)
end)
