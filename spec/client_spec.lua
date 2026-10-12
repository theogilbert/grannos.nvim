local client = require("grannos.client")

describe("client.check_protocol_compat", function()
  it("returns nil when the server's major version matches the client's", function()
    assert.is_nil(client.check_protocol_compat(client.PROTOCOL_VERSION))
  end)

  it("returns nil when the server's minor version differs but major matches", function()
    local client_major = client.PROTOCOL_VERSION:match("^(%d+)")
    assert.is_nil(client.check_protocol_compat(client_major .. ".99"))
  end)

  it("returns a warning when the server's major version differs", function()
    local warning = client.check_protocol_compat("999.0")
    assert.is_not_nil(warning)
    assert.truthy(warning:match("protocol version mismatch"))
  end)

  it("returns a warning when the server predates protocol versioning (nil)", function()
    local warning = client.check_protocol_compat(nil)
    assert.is_not_nil(warning)
    assert.truthy(warning:match("pre%-versioning server"))
  end)
end)

describe("client exit handler", function()
  it("fires when the backend process exits and clears the running state", function()
    local calls = {}
    client.set_exit_handler(function(code) table.insert(calls, code) end)
    client.start([[sh -c 'exit 3']])
    assert.is_true(client.is_running())
    vim.wait(5000, function() return #calls > 0 end, 20)
    client.set_exit_handler(nil)
    assert.are.same({ 3 }, calls)
    assert.is_false(client.is_running())
  end)

  it("reports the exit to in-flight requests before the handler runs", function()
    local events = {}
    client.set_exit_handler(function() table.insert(events, "exit") end)
    client.start("cat")
    client.request("capabilities", {}, function(err, _) table.insert(events, err) end)
    client.stop()
    vim.wait(5000, function() return #events >= 2 end, 20)
    client.set_exit_handler(nil)
    assert.are.same({ "backend exited", "exit" }, events)
  end)
end)

describe("client.capabilities_snapshot", function()
  -- A stand-in backend answering every request with fixed capabilities.
  local FAKE = [[sed -u 's/.*"id":\([0-9]*\).*/{"id":\1,"result":{"server":"srv","protocol_version":"1.1","drivers":[{"driver":"pg","default":null}]},"error":null}/']]

  before_each(function()
    client.caps_file = vim.fn.tempname() .. ".json"
    client.reset_capabilities()
  end)

  after_each(function()
    client.stop()
    vim.wait(5000, function() return not client.is_running() end, 20)
    pcall(vim.fn.delete, client.caps_file)
    client.caps_file = nil
  end)

  it("is nil before any backend has reported its capabilities", function()
    assert.is_nil(client.capabilities_snapshot(FAKE))
  end)

  it("returns what the backend last reported, for the command it was started with only", function()
    client.start(FAKE)
    local got
    client.ensure_capabilities(function(caps) got = caps end)
    vim.wait(5000, function() return got ~= nil end, 20)

    assert.same({ server = "srv", protocol_version = "1.1", drivers = { { driver = "pg" } } }, client.capabilities_snapshot(FAKE))
    assert.is_nil(client.capabilities_snapshot("other-cmd"))
  end)
end)
