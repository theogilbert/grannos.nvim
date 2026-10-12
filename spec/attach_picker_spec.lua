-- :DbAttach with no name opens the connection picker on the capabilities the
-- backend last reported (a snapshot on disk), without waiting for the backend
-- just started to report its own; a selection acts on the live ones.

--- Capabilities the stub backend reports, once `land` is called.
--- @type table
local live

--- The snapshot the stub client holds, or nil for none.
--- @type table|nil
local snapshot

--- Callbacks waiting on the live capabilities.
--- @type fun(caps: table)[]
local waiting = {}

--- Whether the live capabilities have landed.
local landed = false

--- connect requests the stub client has received.
--- @type table[]
local connects = {}

package.loaded["grannos.client"] = {
  is_running            = function() return true end,
  set_exit_handler      = function() end,
  capabilities          = function() return landed and live or nil end,
  capabilities_snapshot = function() return snapshot end,
  ensure_capabilities   = function(cb)
    if landed then cb(live) else table.insert(waiting, cb) end
  end,
  request = function(method, params, cb)
    if method == "connect" then
      table.insert(connects, params)
      cb(nil, { connection_id = #connects })
    elseif method == "disconnect" then
      cb(nil, {})
    end
    return 0
  end,
  get_session = function(_, cb) cb(nil, {}) end,
  set_session = function(_, _, cb) cb(nil) end,
}

local connections = require("grannos.connections")
local config      = require("grannos.config")
local db          = require("grannos")

--- Deliver the live capabilities to everything waiting on them.
local function land()
  landed = true
  local cbs = waiting
  waiting = {}
  for _, cb in ipairs(cbs) do cb(live) end
end

--- Press `keys` synchronously in the current window, then run what they
--- scheduled: the picker hands its selection over on the next loop turn.
--- @param keys string
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  vim.wait(0)
end

--- Lines currently shown in the picker's list window, or {} when it is closed.
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

--- Return capabilities for server `server` with a single driver `pg`.
--- @param server string
--- @return table
local function caps_for(server)
  return { server = server, drivers = { { driver = "pg", label = "Postgres", languages = { "sql" }, params = {} } } }
end

describe(":DbAttach picker", function()
  local tmp

  before_each(function()
    require("grannos.hl").setup()
    tmp = vim.fn.tempname() .. ".json"
    config.setup({ connections_file = tmp })
    local f = assert(io.open(tmp, "w"))
    f:write(vim.json.encode({
      old = { pg = { label = "Postgres", groups = { [""] = { stale_db = { host = "a" } } } } },
      srv = { pg = { label = "Postgres", groups = { [""] = { prod = { host = "b" } } } } },
    }))
    f:close()
    connections.invalidate()
    live, snapshot, waiting, landed, connects = caps_for("srv"), caps_for("srv"), {}, false, {}
    vim.cmd("enew")
  end)

  after_each(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    vim.cmd("silent! only")
    for _, k in ipairs(db.active_keys()) do db.disconnect(k) end
    pcall(vim.fn.delete, tmp)
  end)

  it("opens on the snapshot before the backend reports its capabilities", function()
    db.attach("")

    assert.is_false(landed)
    assert.same({ "    prod  (Postgres)", "    [+ New connection]" }, list_lines())
  end)

  it("connects a selection only once the live capabilities land", function()
    db.attach("")
    feed("<CR>")
    assert.equals(0, #connects)

    land()
    assert.equals(1, #connects)
    assert.equals("b", connects[1].host)
  end)

  it("lists again when the live server is not the one the snapshot came from", function()
    snapshot = caps_for("old")
    db.attach("")
    assert.equals("    stale_db  (Postgres)", list_lines()[1])

    feed("<CR>")
    land()
    assert.equals(0, #connects)
    assert.equals("    prod  (Postgres)", list_lines()[1])
  end)

  it("waits for the live capabilities when there is no snapshot", function()
    snapshot = nil
    db.attach("")
    assert.same({}, list_lines())

    land()
    assert.equals("    prod  (Postgres)", list_lines()[1])
  end)
end)
