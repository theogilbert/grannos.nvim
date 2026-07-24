-- Exercises connections.create/edit/clone's field-list construction and
-- on_submit logic (validation, collision checks, param coercion, upsert)
-- without opening any real floating window: ui/conn_form.lua is replaced
-- with a stub that hands the test the raw `opts` passed to `.open`.
local config = require("grannos.config")

--- Stub ui/conn_form: captures the last `.open` call's opts.
local stub = { last = nil }
function stub.open(opts) stub.last = opts end
package.loaded["grannos.ui.conn_form"] = stub

--- Stub grannos.client: records every `connect`/`disconnect` request and lets
--- the test script the backend's response via client_stub.reply_connect.
local client_stub = { requests = {}, reply_connect = nil }
function client_stub.request(method, params, callback)
  table.insert(client_stub.requests, { method = method, params = params })
  if method == "connect" then
    local err, result = client_stub.reply_connect(params)
    callback(err, result)
  else
    callback(nil, { ok = true })
  end
end
package.loaded["grannos.client"] = client_stub

local connections = require("grannos.connections")

local CAPS = {
  server = "srv",
  drivers = {
    {
      driver = "pg",
      label  = "Postgres",
      params = {
        { key = "host",     type = "string",  label = "Host", required = true },
        { key = "port",     type = "integer", label = "Port", default = 5432 },
        { key = "password", type = "string",  label = "Password", secret = true },
      },
    },
  },
}

--- Find a field by key in a ConnFormField list.
--- @param fields table[]
--- @param key    string
--- @return table
local function find(fields, key)
  for _, f in ipairs(fields) do
    if f.key == key then return f end
  end
  error("no field with key " .. key)
end

--- Gather values from every field, mimicking what conn_form.lua does before
--- calling on_submit.
--- @param fields table[]
--- @return table
local function gather(fields)
  local values = {}
  for _, f in ipairs(fields) do values[f.key] = f.get() end
  return values
end

--- Call on_submit with the current field values and capture the `done` outcome.
--- @param opts table  captured from stub.last
--- @return string|nil err
local function submit(opts)
  local err
  opts.on_submit(gather(opts.fields), function(e) err = e end)
  return err
end

describe("connections.create (form-based)", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname() .. ".json"
    config.setup({ connections_file = tmp })
    connections.invalidate()
    stub.last = nil
  end)

  after_each(function()
    pcall(vim.fn.delete, tmp)
  end)

  it("builds name, group, driver params, and password fields, in order", function()
    connections.create(CAPS, function() end, { driver = "pg" })
    local fields = stub.last.fields
    local keys = vim.tbl_map(function(f) return f.key end, fields)
    assert.same({ "name", "group", "host", "port", "password", "remember_password" }, keys)
  end)

  it("rejects submit when the required name field is empty", function()
    connections.create(CAPS, function() end, { driver = "pg" })
    local name_field = find(stub.last.fields, "name")
    assert.is_false(name_field.is_valid())
  end)

  it("writes the connection to disk and calls back with key+params on submit", function()
    local got_key, got_params
    connections.create(CAPS, function(key, params) got_key, got_params = key, params end, { driver = "pg" })

    find(stub.last.fields, "name").commit_text("mydb")
    find(stub.last.fields, "host").commit_text("localhost")

    local err = submit(stub.last)
    assert.is_nil(err)
    assert.equals(connections.conn_key("srv", "pg", "", "mydb"), got_key)
    assert.equals("localhost", got_params.host)
    assert.equals(5432, got_params.port)  -- integer default coerced to a number
    assert.is_false(got_params.requires_password)

    local saved = connections.get(got_key)
    assert.equals("localhost", saved.host)
  end)

  it("keeps the form open with an inline error on a duplicate name instead of aborting", function()
    connections.create(CAPS, function() end, { driver = "pg" })
    find(stub.last.fields, "name").commit_text("dup")
    find(stub.last.fields, "host").commit_text("localhost")
    assert.is_nil(submit(stub.last))

    -- Second create with the same name+group should surface as an inline error.
    connections.create(CAPS, function() end, { driver = "pg" })
    find(stub.last.fields, "name").commit_text("dup")
    find(stub.last.fields, "host").commit_text("otherhost")
    local err = submit(stub.last)
    assert.is_not_nil(err)
    assert.matches("already exists", err)
  end)

  it("stores the password and clears requires_password when remember_password is Yes", function()
    local got_params
    connections.create(CAPS, function(_, params) got_params = params end, { driver = "pg" })
    find(stub.last.fields, "name").commit_text("mydb")
    find(stub.last.fields, "host").commit_text("localhost")
    find(stub.last.fields, "password").commit_text("hunter2")
    find(stub.last.fields, "remember_password").commit_choice({ value = true })

    submit(stub.last)
    assert.equals("hunter2", got_params.password)
    assert.is_false(got_params.requires_password)
  end)

  it("sets requires_password without persisting the password when remember_password stays No", function()
    local got_key, got_params
    connections.create(CAPS, function(key, params) got_key, got_params = key, params end, { driver = "pg" })
    find(stub.last.fields, "name").commit_text("mydb")
    find(stub.last.fields, "host").commit_text("localhost")
    find(stub.last.fields, "password").commit_text("hunter2")

    submit(stub.last)
    -- The callback's params still carry the typed password so this session can
    -- connect immediately...
    assert.equals("hunter2", got_params.password)
    assert.is_true(got_params.requires_password)
    -- ...but it must not have been written to disk.
    assert.is_nil(connections.get(got_key).password)
  end)
end)

describe("connections.edit (form-based)", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname() .. ".json"
    config.setup({ connections_file = tmp })
    connections.invalidate()
    stub.last = nil
    connections.create(CAPS, function() end, { driver = "pg" })
    find(stub.last.fields, "name").commit_text("mydb")
    find(stub.last.fields, "host").commit_text("localhost")
    submit(stub.last)
    stub.last = nil
  end)

  after_each(function()
    pcall(vim.fn.delete, tmp)
  end)

  it("pre-fills fields from the existing connection", function()
    local key = connections.conn_key("srv", "pg", "", "mydb")
    connections.edit(key, CAPS, function() end)
    assert.equals("mydb", find(stub.last.fields, "name").get())
    assert.equals("localhost", find(stub.last.fields, "host").get())
    assert.equals("(not set)", find(stub.last.fields, "password").display())
  end)

  it("renames the connection and moves it under the new key", function()
    local key = connections.conn_key("srv", "pg", "", "mydb")
    local got_new_key
    connections.edit(key, CAPS, function(new_key) got_new_key = new_key end)
    find(stub.last.fields, "name").commit_text("renamed")

    local err = submit(stub.last)
    assert.is_nil(err)
    assert.equals(connections.conn_key("srv", "pg", "", "renamed"), got_new_key)
    assert.is_nil(connections.get(key))
    assert.is_not_nil(connections.get(got_new_key))
  end)

  it("keeps the existing password when the password field is left unedited", function()
    -- Give the connection a remembered password first.
    local key = connections.conn_key("srv", "pg", "", "mydb")
    connections.edit(key, CAPS, function() end)
    find(stub.last.fields, "password").commit_text("hunter2")
    find(stub.last.fields, "remember_password").commit_choice({ value = true })
    submit(stub.last)

    -- Re-open edit and submit without touching the password field.
    local got_params
    connections.edit(key, CAPS, function(_, params) got_params = params end)
    assert.equals("(unchanged)", find(stub.last.fields, "password").display())
    submit(stub.last)
    assert.equals("hunter2", got_params.password)
  end)
end)

describe("connections.clone (form-based)", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname() .. ".json"
    config.setup({ connections_file = tmp })
    connections.invalidate()
    stub.last = nil
    connections.create(CAPS, function() end, { driver = "pg", group = "prod" })
    find(stub.last.fields, "name").commit_text("mydb")
    find(stub.last.fields, "host").commit_text("localhost")
    submit(stub.last)
    stub.last = nil
  end)

  after_each(function()
    pcall(vim.fn.delete, tmp)
  end)

  it("pre-fills the group from the source connection", function()
    local key = connections.conn_key("srv", "pg", "prod", "mydb")
    connections.clone(key, "mydb-copy", CAPS, function() end)
    assert.equals("prod", find(stub.last.fields, "group").get())
    assert.equals("localhost", find(stub.last.fields, "host").get())
  end)

  it("creates a separate connection under the new name", function()
    local key = connections.conn_key("srv", "pg", "prod", "mydb")
    local got_new_key
    connections.clone(key, "mydb-copy", CAPS, function(new_key) got_new_key = new_key end)

    local err = submit(stub.last)
    assert.is_nil(err)
    assert.equals(connections.conn_key("srv", "pg", "prod", "mydb-copy"), got_new_key)
    assert.is_not_nil(connections.get(key))          -- original untouched
    assert.is_not_nil(connections.get(got_new_key))  -- clone created
  end)
end)

describe("Test Connection button (on_test)", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname() .. ".json"
    config.setup({ connections_file = tmp })
    connections.invalidate()
    stub.last = nil
    client_stub.requests = {}
    client_stub.reply_connect = function() return nil, { connection_id = "0" } end
  end)

  after_each(function()
    pcall(vim.fn.delete, tmp)
  end)

  it("connects then disconnects using the form's current unsaved values, driver at the top level", function()
    connections.create(CAPS, function() end, { driver = "pg" })
    find(stub.last.fields, "host").commit_text("localhost")
    find(stub.last.fields, "password").commit_text("hunter2")

    local ok, err
    stub.last.on_test(gather(stub.last.fields), function(o, e) ok, err = o, e end)

    assert.is_true(ok)
    assert.is_nil(err)
    assert.equals(2, #client_stub.requests)
    assert.equals("connect", client_stub.requests[1].method)
    assert.equals("pg", client_stub.requests[1].params.driver)
    assert.equals("localhost", client_stub.requests[1].params.host)
    assert.equals(5432, client_stub.requests[1].params.port)  -- integer default coerced
    assert.equals("hunter2", client_stub.requests[1].params.password)
    assert.equals("disconnect", client_stub.requests[2].method)
    assert.equals("0", client_stub.requests[2].params.connection_id)

    -- Testing must never write anything to disk.
    assert.same({}, connections.load_all())
  end)

  it("reports the backend's error string on failure without disconnecting", function()
    client_stub.reply_connect = function() return "connection refused", nil end
    connections.create(CAPS, function() end, { driver = "pg" })
    find(stub.last.fields, "host").commit_text("unreachable-host")

    local ok, err
    stub.last.on_test(gather(stub.last.fields), function(o, e) ok, err = o, e end)

    assert.is_false(ok)
    assert.equals("connection refused", err)
    assert.equals(1, #client_stub.requests)  -- no disconnect attempted after a failed connect
  end)

  it("falls back to the connection's already-stored password when unedited (edit)", function()
    connections.create(CAPS, function() end, { driver = "pg" })
    find(stub.last.fields, "name").commit_text("mydb")
    find(stub.last.fields, "host").commit_text("localhost")
    find(stub.last.fields, "password").commit_text("hunter2")
    find(stub.last.fields, "remember_password").commit_choice({ value = true })
    submit(stub.last)

    stub.last = nil
    connections.edit(connections.conn_key("srv", "pg", "", "mydb"), CAPS, function() end)

    client_stub.requests = {}
    stub.last.on_test(gather(stub.last.fields), function() end)
    assert.equals("hunter2", client_stub.requests[1].params.password)
  end)
end)
