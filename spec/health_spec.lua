local client = require("grannos.client")
local health = require("grannos.health")

--- Write an executable stub that answers one JSON line and exits.
--- @param response string  the line the fake backend prints on stdout
--- @return string  path to the stub
local function fake_backend(response)
  local path = vim.fn.tempname()
  vim.fn.writefile({
    "#!/bin/sh",
    "read line",
    "printf '%s\\n' " .. vim.fn.shellescape(response),
  }, path)
  vim.fn.setfperm(path, "rwx------")
  return path
end

describe("client.executable_name", function()
  it("returns the command itself", function()
    assert.are.equal("belvedere", client.executable_name("belvedere"))
  end)

  it("returns the first word of a command with arguments", function()
    assert.are.equal("belvedere", client.executable_name("  belvedere --log -v  "))
  end)

  it("returns a quoted path containing spaces", function()
    assert.are.equal("/opt/my backend/belvedere",
      client.executable_name([["/opt/my backend/belvedere" --log]]))
  end)

  it("returns nil for shell syntax it cannot inspect", function()
    assert.is_nil(client.executable_name("BELVEDERE_LOG=1 belvedere"))
    assert.is_nil(client.executable_name("$HOME/bin/belvedere"))
    assert.is_nil(client.executable_name(""))
    assert.is_nil(client.executable_name(nil))
  end)
end)

describe("client.check_executable", function()
  it("returns nil when the executable is on $PATH", function()
    assert.is_nil(client.check_executable("sh -c 'true'"))
  end)

  it("returns nil when the command is shell syntax", function()
    assert.is_nil(client.check_executable("FOO=1 not-a-real-binary-zzz"))
  end)

  it("names a missing command and how to configure it", function()
    local msg = client.check_executable("not-a-real-binary-zzz --log")
    assert.is_not_nil(msg)
    assert.truthy(msg:match("not%-a%-real%-binary%-zzz"))
    assert.truthy(msg:match("%$PATH"))
    assert.truthy(msg:match("server_cmd"))
  end)

  it("reports a missing path differently from a missing $PATH lookup", function()
    local msg = client.check_executable("/nonexistent/dir/belvedere")
    assert.is_not_nil(msg)
    assert.truthy(msg:match("does not exist or is not executable"))
  end)
end)

describe("client.start", function()
  it("errors with the missing-executable message instead of spawning", function()
    local ok, err = pcall(client.start, "not-a-real-binary-zzz")
    assert.is_false(ok)
    assert.truthy(tostring(err):match("not%-a%-real%-binary%-zzz"))
    assert.is_false(client.is_running())
  end)
end)

describe("health.probe", function()
  it("returns the capabilities result the backend answers with", function()
    local cmd = fake_backend(
      '{"id":1,"result":{"server":"fake","protocol_version":"1.0",'
      .. '"drivers":[{"driver":"x","label":"X"}]}}')
    local caps, err = health.probe(cmd, 5000)
    vim.fn.delete(cmd)
    assert.is_nil(err)
    assert.are.equal("fake", caps.server)
    assert.are.equal("1.0", caps.protocol_version)
    assert.are.equal("X", caps.drivers[1].label)
  end)

  it("reports the exit code and stderr when the backend dies", function()
    local caps, err = health.probe([[sh -c 'echo boom >&2; exit 3']], 5000)
    assert.is_nil(caps)
    assert.truthy(err:match("exited with code 3"))
    assert.truthy(err:match("boom"))
  end)

  it("reports the backend's own error response", function()
    local cmd = fake_backend('{"id":1,"error":{"message":"unsupported method"}}')
    local caps, err = health.probe(cmd, 5000)
    vim.fn.delete(cmd)
    assert.is_nil(caps)
    assert.truthy(err:match("unsupported method"))
  end)

  it("times out when the backend never answers", function()
    local caps, err = health.probe("cat", 200)
    assert.is_nil(caps)
    assert.truthy(err:match("did not answer"))
  end)

  it("reports a command that cannot be spawned", function()
    local caps, err = health.probe("/nonexistent/dir/belvedere", 200)
    assert.is_nil(caps)
    assert.is_not_nil(err)
  end)
end)

describe("health.report", function()
  it("produces sections and entries with renderable levels", function()
    require("grannos.config").setup({ server_cmd = "not-a-real-binary-zzz" })
    local entries = health.report()

    local levels = { start = true, ok = true, info = true, warn = true, error = true }
    local sections, backend_error = {}, nil
    for _, entry in ipairs(entries) do
      assert.is_true(levels[entry.level])
      assert.are.equal("string", type(entry.msg))
      if entry.level == "start" then table.insert(sections, entry.msg) end
      if entry.level == "error" and entry.msg:match("not%-a%-real%-binary%-zzz") then
        backend_error = entry
      end
    end

    assert.are.same({
      "grannos: requirements",
      "grannos: configuration",
      "grannos: backend",
      "grannos: treesitter parsers",
      "grannos: optional dependencies",
    }, sections)

    -- A missing backend is reported as an error, with advice on how to fix it.
    assert.is_not_nil(backend_error)
    assert.is_true(#backend_error.advice > 0)
  end)
end)
