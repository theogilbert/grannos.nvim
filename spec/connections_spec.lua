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

describe("connections.pick", function()
  local tmp

  --- Press `keys` synchronously in the current window.
  --- @param keys string
  local function feed(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end

  --- Append `text` to the picker's search box and let the filter run.
  --- @param text string
  local function type_filter(text)
    local buf  = vim.api.nvim_get_current_buf()
    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { line .. text })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  end

  --- Lines currently shown in the picker's list window.
  --- @return string[]
  local function list_lines()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= "" and cfg.height > 1 then
        return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
      end
    end
    return {}
  end

  local CAPS = {
    server  = "srv",
    drivers = {
      { driver = "postgres", label = "PostgreSQL", languages = { "sql" }, params = {} },
      { driver = "neo4j",    label = "Neo4j",      languages = { "cypher" }, params = {} },
    },
  }
  local PG_PARAMS = { host = "db" }
  local function key(driver, group, name) return connections.conn_key("srv", driver, group, name) end

  before_each(function()
    require("grannos.hl").setup()
    tmp = vim.fn.tempname() .. ".json"
    config.setup({ connections_file = tmp })
    connections.invalidate()
    write_file(tmp, {
      srv = {
        postgres = { label = "PostgreSQL", groups = {
          prod = { alpha = PG_PARAMS, beta = PG_PARAMS },
          [""] = { local_db = PG_PARAMS },
        } },
        neo4j = { label = "Neo4j", groups = { graph = { movies = { uri = "bolt://x" } } } },
      },
    })
  end)

  after_each(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    vim.cmd("silent! only")
    pcall(vim.fn.delete, tmp)
  end)

  it("lists every saved connection, open ones first, then by filetype rank and name", function()
    connections.pick(CAPS, { active_set = { [key("neo4j", "graph", "movies")] = true }, filetype = "sql" },
      function() end)

    -- The list pane indents every row by two columns.
    assert.same({
      "  ● graph/movies  (Neo4j)",
      "    local_db  (PostgreSQL)",
      "    prod/alpha  (PostgreSQL)",
      "    prod/beta  (PostgreSQL)",
      "    [+ New connection]",
    }, list_lines())
  end)

  it("ranks the current filetype's driver first among closed connections", function()
    connections.pick(CAPS, { active_set = {}, filetype = "cypher" }, function() end)

    assert.equals("    graph/movies  (Neo4j)", list_lines()[1])
  end)

  it("selecting a closed connection calls back with its params", function()
    local got_key, got_params
    connections.pick(CAPS, { active_set = {}, filetype = "sql" }, function(k, p) got_key, got_params = k, p end)
    type_filter("beta")
    feed("<CR>")

    assert.equals(key("postgres", "prod", "beta"), got_key)
    assert.same(PG_PARAMS, got_params)
  end)

  it("selecting an open connection calls back with nil params", function()
    local got_key, got_params = nil, "unset"
    local active = { [key("postgres", "prod", "alpha")] = true }
    connections.pick(CAPS, { active_set = active, filetype = "sql" }, function(k, p) got_key, got_params = k, p end)
    type_filter("alpha")
    feed("<CR>")

    assert.equals(key("postgres", "prod", "alpha"), got_key)
    assert.is_nil(got_params)
  end)

  it("cancelling calls back with nil", function()
    local called, got_key = false, "unset"
    connections.pick(CAPS, { active_set = {}, filetype = "sql" }, function(k) called, got_key = true, k end)
    feed("<C-c>")

    assert.is_true(called)
    assert.is_nil(got_key)
  end)
end)
