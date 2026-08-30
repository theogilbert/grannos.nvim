local connections = require("grannos.connections")
local config      = require("grannos.config")

-- Write a full file-format table to the temp path.
local function write_file(path, data)
  vim.fn.writefile({ vim.json.encode(data) }, path)
end

describe("connections key helpers", function()
  it("conn_key encodes server/driver/group/name", function()
    assert.equals("srv\0drv\0grp\0nm", connections.conn_key("srv", "drv", "grp", "nm"))
  end)

  it("conn_key with empty group (no group)", function()
    assert.equals("srv\0drv\0\0nm", connections.conn_key("srv", "drv", "", "nm"))
  end)

  it("conn_parts roundtrips a key", function()
    local key = connections.conn_key("grannos", "sqlite", "prod", "mydb")
    local s, d, g, n = connections.conn_parts(key)
    assert.equals("grannos", s)
    assert.equals("sqlite",    d)
    assert.equals("prod",      g)
    assert.equals("mydb",      n)
  end)

  it("conn_parts roundtrips a key with empty group", function()
    local key = connections.conn_key("grannos", "sqlite", "", "mydb")
    local s, d, g, n = connections.conn_parts(key)
    assert.equals("grannos", s)
    assert.equals("sqlite",    d)
    assert.equals("",          g)
    assert.equals("mydb",      n)
  end)

  it("conn_display_name returns the connection name for ungrouped connections", function()
    local key = connections.conn_key("grannos", "sqlite", "", "mydb")
    assert.equals("mydb", connections.conn_display_name(key))
  end)

  it("conn_display_name includes group prefix when group is set", function()
    local key_grouped   = connections.conn_key("srv", "sqlite", "prod", "mydb")
    local key_ungrouped = connections.conn_key("srv", "sqlite", "",     "mydb")
    assert.equals("prod/mydb", connections.conn_display_name(key_grouped))
    assert.equals("mydb",      connections.conn_display_name(key_ungrouped))
  end)
end)

describe("connections uniqueness (M.get)", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname() .. ".json"
    config.setup({ connections_file = tmp })
    connections.invalidate()
  end)

  after_each(function()
    pcall(vim.fn.delete, tmp)
  end)

  local PARAMS = { requires_password = false, path = "/tmp/test.db" }

  local function seed(server, driver, group, name)
    write_file(tmp, {
      [server] = {
        [driver] = {
          label  = driver,
          groups = { [group] = { [name] = PARAMS } },
        },
      },
    })
  end

  it("exact match → collision", function()
    seed("srv", "sqlite", "", "mydb")
    assert.is_not_nil(connections.get(connections.conn_key("srv", "sqlite", "", "mydb")))
  end)

  it("same name, same driver, different group → allowed", function()
    seed("srv", "sqlite", "prod", "mydb")
    assert.is_nil(connections.get(connections.conn_key("srv", "sqlite", "", "mydb")))
    assert.is_nil(connections.get(connections.conn_key("srv", "sqlite", "dev", "mydb")))
  end)

  it("same name, different driver, same group → allowed", function()
    seed("srv", "sqlite", "", "mydb")
    assert.is_nil(connections.get(connections.conn_key("srv", "mongodb", "", "mydb")))
  end)

  it("same name, different driver, different group → allowed", function()
    seed("srv", "sqlite", "dev", "mydb")
    assert.is_nil(connections.get(connections.conn_key("srv", "mongodb", "prod", "mydb")))
  end)

  it("group↔no-group: grouped name does not block ungrouped slot", function()
    seed("srv", "sqlite", "mygroup", "mydb")
    assert.is_nil(connections.get(connections.conn_key("srv", "sqlite", "", "mydb")))
  end)

  it("group↔no-group: ungrouped name does not block grouped slot", function()
    seed("srv", "sqlite", "", "mydb")
    assert.is_nil(connections.get(connections.conn_key("srv", "sqlite", "mygroup", "mydb")))
  end)
end)
