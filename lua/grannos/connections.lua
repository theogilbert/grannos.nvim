-- Manages the connections file ($XDG_CONFIG_HOME/grannos/connections.json).
--
-- File format:
--   {
--     "<server>": {
--       "<driver>": {
--         "label": "...",
--         "groups": {
--           "":             { "<name>": { <params> }, ... },
--           "<group_name>": { "<name>": { <params> }, ... }
--         }
--       }
--     }
--   }
--
-- Connection params contain only driver-specific fields plus requires_password/password.
-- driver, group and server are encoded in the internal key, not stored in params.
local M = {}

local config = require("grannos.config")

local _cache = nil  -- cached parsed file contents; nil means not yet loaded

--- Build the internal NUL-separated composite key for a connection.
--- @param server string
--- @param driver string
--- @param group  string
--- @param name   string
--- @return string
function M.conn_key(server, driver, group, name)
  return (server or "") .. "\0" .. (driver or "") .. "\0" .. (group or "") .. "\0" .. name
end

--- Split a composite key into (server, driver, group, name).
--- @param key string
--- @return string, string, string, string
function M.conn_parts(key)
  local parts = {}
  local s = 1
  for _ = 1, 3 do
    local e = key:find("\0", s, true)
    if not e then break end
    table.insert(parts, key:sub(s, e - 1))
    s = e + 1
  end
  table.insert(parts, key:sub(s))
  while #parts < 4 do table.insert(parts, "") end
  return parts[1], parts[2], parts[3], parts[4]
end

--- Return the user-visible connection name: "group/name" when a group exists, else just "name".
--- @param key string
--- @return string
function M.conn_display_name(key)
  local _, _, group, name = M.conn_parts(key)
  local display = name ~= "" and name or key
  return group ~= "" and (group .. "/" .. display) or display
end

--- Return `v` when it is not nil/vim.NIL, otherwise return `default`.
--- @param v       any
--- @param default any
--- @return any
local function jval(v, default)
  if v == nil or v == vim.NIL then return default end
  return v
end

--- If `params.requires_password` is set, prompt the user and inject the password.
--- Calls `callback(params_with_pw)` on success, or `callback(nil)` on cancel.
--- @param params   table
--- @param callback fun(params: table|nil)
local function prompt_password(params, callback)
  if not params.requires_password then callback(params) return end
  vim.ui.input({ prompt = "Password: ", secret = true }, function(val)
    if val == nil then callback(nil) return end
    callback(vim.tbl_extend("force", params, { password = val }))
  end)
end
M.prompt_password = prompt_password

--- Return the path to the connections JSON file.
--- @return string
local function file_path() return config.options.connections_file end

--- Read and parse the connections file, caching the result.
--- Returns nil (and notifies) when the file is corrupted.
--- @return table|nil
local function read_data()
  if _cache then return _cache end
  local path = file_path()
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or #lines == 0 then _cache = {}; return _cache end
  local ok2, parsed = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok2 or type(parsed) ~= "table" then
    vim.notify(
      "grannos: connections file is corrupted and could not be loaded.\n"
      .. "  Path: " .. path .. "\n"
      .. "  Fix or remove it to continue.",
      vim.log.levels.ERROR
    )
    return nil
  end
  _cache = parsed
  return _cache
end

--- Serialise `data` to the connections file and update the cache.
--- @param data table
local function write_data(data)
  local path = file_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(data) }, path)
  vim.uv.fs_chmod(path, tonumber("600", 8))
  _cache = data
end

--- Invalidate the in-memory cache so the next read re-parses the file.
function M.invalidate()
  _cache = nil
end

--- Persist the `allow_writes` flag for the connection identified by `key`.
--- When true, the write-detection prompt is skipped for this connection.
--- @param key string
function M.set_allow_writes(key)
  local server, driver, group, name = M.conn_parts(key)
  local data = read_data()
  if not data then return end
  local params = ((((data[server] or {})[driver] or {}).groups or {})[group] or {})[name]
  if not params then return end
  params.allow_writes = true
  write_data(data)
end

--- Return the full parsed connections file, or an empty table on error.
--- @return table
function M.load_all()
  return read_data() or {}
end

--- Return the driver map for `server`: { driver → { label, groups → { group → { name → params } } } }.
--- @param server string
--- @return table
function M.load(server)
  return ((read_data() or {})[server] or {})
end

--- Return the params for a specific 4-part key, or nil when not found.
--- @param key string
--- @return table|nil
function M.get(key)
  local server, driver, group, name = M.conn_parts(key)
  local d = (((read_data() or {})[server] or {})[driver] or {})
  return ((d.groups or {})[group] or {})[name]
end

--- Ensure the server → driver → group path exists in `data` and write the connection params.
--- @param data         table   mutable file-data table
--- @param server       string
--- @param driver       string
--- @param driver_label string|nil
--- @param group        string
--- @param name         string
--- @param params       table
local function upsert(data, server, driver, driver_label, group, name, params)
  data[server] = data[server] or {}
  if not data[server][driver] then
    data[server][driver] = { label = driver_label, groups = {} }
  else
    if driver_label then data[server][driver].label = driver_label end
    data[server][driver].groups = data[server][driver].groups or {}
  end
  local d = data[server][driver]
  d.groups[group] = d.groups[group] or {}
  d.groups[group][name] = params
end

--- Delete the connection identified by `key` and write the updated file.
--- @param key string
function M.delete(key)
  local server, driver, group, name = M.conn_parts(key)
  local data = read_data()
  if not data then return end
  local d    = (data[server] or {})[driver]
  local g    = d and (d.groups or {})[group]
  if not g or not g[name] then
    vim.notify(("grannos: connection %q not found"):format(name), vim.log.levels.WARN)
    return
  end
  g[name] = nil
  write_data(data)
  vim.notify(("grannos: deleted connection %q"):format(name), vim.log.levels.INFO)
end

--- Delete an entire group and all its connections.
--- @param server string
--- @param driver string
--- @param group  string
function M.delete_group(server, driver, group)
  local data = read_data()
  if not data then return end
  local d = (data[server] or {})[driver]
  if not d or not (d.groups or {})[group] then
    vim.notify(("grannos: group %q not found"):format(group), vim.log.levels.WARN)
    return
  end
  local count = vim.tbl_count(d.groups[group])
  d.groups[group] = nil
  write_data(data)
  local label = group ~= "" and group or "(no group)"
  vim.notify(("grannos: deleted group %q and %d connection(s)"):format(label, count), vim.log.levels.INFO)
end

--- Create an empty named group for a driver.
--- Returns false and notifies when the group already exists.
--- @param server       string
--- @param driver       string
--- @param driver_label string
--- @param group_name   string
--- @return boolean
function M.create_group(server, driver, driver_label, group_name)
  local data = read_data()
  if not data then return false end
  data[server] = data[server] or {}
  if not data[server][driver] then
    data[server][driver] = { label = driver_label, groups = {} }
  end
  local d = data[server][driver]
  d.groups = d.groups or {}
  if d.groups[group_name] ~= nil then
    vim.notify(("grannos: group %q already exists"):format(group_name), vim.log.levels.WARN)
    return false
  end
  d.groups[group_name] = {}
  write_data(data)
  return true
end

--- Return the {fields, pw_param} for `driver` from capabilities.
--- `pw_param` is the secret field descriptor (or nil); `fields` are the non-secret ones.
--- @param caps   table
--- @param driver string
--- @return table[], table|nil
local function driver_fields(caps, driver)
  for _, tech in ipairs(caps.drivers or {}) do
    if tech.driver == driver then
      local pw_param, fields = nil, {}
      for _, p in ipairs(tech.params or {}) do
        if p.secret then pw_param = p else table.insert(fields, p) end
      end
      return fields, pw_param
    end
  end
  return {}, nil
end

--- Coerce string values for integer-typed fields back to numbers.
--- @param fields table[]  field descriptors
--- @param values table    mutable key→value map
local function coerce_integer_fields(fields, values)
  for _, p in ipairs(fields) do
    if p.type == "integer" and values[p.key] then
      values[p.key] = tonumber(values[p.key]) or values[p.key]
    end
  end
end

--- Return the human-readable label for `driver`, preferring capabilities over the stored file.
--- @param caps   table
--- @param server string
--- @param driver string
--- @return string
local function resolve_driver_label(caps, server, driver)
  for _, d in ipairs(caps.drivers or {}) do
    if d.driver == driver then return d.label or driver end
  end
  return (M.load(server)[driver] or {}).label or driver
end

--- Build the "Connection name" ConnFormField (see ui/conn_form.lua for the field shape).
--- @param initial string|nil
--- @return table
local function make_name_field(initial)
  local raw = initial or ""
  return {
    key          = "name",
    label        = "Connection name",
    kind         = "text",
    get          = function() return raw end,
    display      = function() return raw ~= "" and raw or "(none)" end,
    edit_prefill = function() return raw end,
    commit_text  = function(v) raw = v end,
    is_valid     = function() return raw ~= "" end,
  }
end

--- Build the "Group" ConnFormField: a choice field over existing groups for
--- (server, driver), plus "[No group]" and a "[+ New group]" escape hatch that
--- switches into free-text entry (mirrors the old pick_group wizard step).
--- @param server  string
--- @param driver  string
--- @param initial string|nil
--- @return table
local function make_group_field(server, driver, initial)
  local raw = initial or ""
  return {
    key     = "group",
    label   = "Group",
    kind    = "choice",
    get     = function() return raw end,
    display = function() return raw ~= "" and raw or "[No group]" end,
    options = function()
      local driver_data = M.load(server)[driver] or {}
      local existing = {}
      for gname in pairs(driver_data.groups or {}) do
        if gname ~= "" then table.insert(existing, gname) end
      end
      table.sort(existing)
      local items = { { value = "", label = "[No group]" } }
      for _, gname in ipairs(existing) do table.insert(items, { value = gname, label = gname }) end
      table.insert(items, { is_new = true, label = "[+ New group]" })
      return items
    end,
    commit_choice = function(item) raw = item.value end,
    commit_text   = function(v) if v and v ~= "" then raw = v end end,
  }
end

--- Build a ConnFormField for one driver-specific DriverParam, pre-filled from
--- `current` (existing params, for edit/clone) or `p.default` (create).
--- @param p       table     DriverParam descriptor (key/type/label/required/default/choices)
--- @param current table|nil existing param values; nil for create
--- @return table
local function driver_param_field(p, current)
  local initial = current and current[p.key]
  if initial == nil or initial == vim.NIL then initial = jval(p.default) end
  local raw      = initial ~= nil and tostring(initial) or ""
  local required = jval(p.required, false)

  local field = {
    key      = p.key,
    label    = p.label,
    kind     = (p.type == "enum") and "choice" or "text",
    required = required,
    get      = function() return raw end,
    is_valid = function() return not required or raw ~= "" end,
  }

  if field.kind == "choice" then
    field.display = function()
      for _, c in ipairs(p.choices or {}) do
        if c.value == raw then return c.label or c.value end
      end
      return raw ~= "" and raw or "(none)"
    end
    field.options = function()
      local items = {}
      for _, c in ipairs(p.choices or {}) do
        table.insert(items, { value = c.value, label = c.label or c.value })
      end
      return items
    end
    field.commit_choice = function(item) raw = item.value end
  else
    field.display      = function() return raw ~= "" and raw or "(none)" end
    field.edit_prefill  = function() return raw end
    field.commit_text   = function(v) raw = v end
  end
  return field
end

--- Build a Yes/No ConnFormField.
--- @param key     string
--- @param label   string
--- @param initial boolean
--- @return table
local function make_toggle_field(key, label, initial)
  local value = initial and true or false
  return {
    key     = key,
    label   = label,
    kind    = "toggle",
    get     = function() return value end,
    display = function() return value and "[x]" or "[ ]" end,
    toggle  = function() value = not value end,
  }
end

--- Build the password (+ "Remember password") ConnFormFields for `pw_param`.
--- `had_value` seeds the unedited display: for create this is always false
--- ("(empty)"); for edit/clone it reflects whether the connection already has
--- a password or a `requires_password` flag (masked stars). Leaving the field
--- unedited always means "keep whatever is already there" (or "no password",
--- for create) — mirrors the old prompt_password_and_remember semantics,
--- minus its "confirm empty password" dialog: the form shows the set/not-set
--- state persistently, so a failed paste is immediately visible. The mask is
--- a fixed-width placeholder rather than one star per character, since the
--- unedited case may be reporting a password the client never even sees the
--- plaintext of (requires_password with no stored value) — there's no real
--- length to reflect, so a fixed width avoids implying one.
--- @param pw_param  table|nil
--- @param had_value boolean
--- @return table[]  empty when there is no secret param for this driver
local function make_password_fields(pw_param, had_value)
  if not pw_param then return {} end
  local PW_MASK = "********"
  local raw, edited = "", false
  local pw_field = {
    key          = "password",
    label        = pw_param.label,
    kind         = "secret",
    get          = function() return { edited = edited and raw ~= "", raw = raw } end,
    display      = function()
      local has_value = (edited and raw ~= "") or had_value
      return has_value and PW_MASK or "(empty)"
    end,
    edit_prefill = function() return "" end,
    commit_text  = function(v) raw = v or ""; edited = true end,
  }
  return { pw_field, make_toggle_field("remember_password", "Remember password", false) }
end

--- Build the params table to send to the backend's `connect` method from the
--- form's raw `values` (as gathered by conn_form, i.e. before they've been
--- validated/persisted). Coerces integer fields and resolves the password the
--- same way a submit would: an edited, non-empty password field wins, and an
--- unedited one falls back to `current`'s already-stored password (nil for
--- create, where an unedited/empty password just means "no password").
--- @param dfields table[]     driver param descriptors (excludes the secret one)
--- @param values  table       raw values gathered from the form
--- @param current table|nil   existing connection params, for password fallback
--- @return table
local function build_connect_params(dfields, values, current)
  local params = {}
  for _, p in ipairs(dfields) do params[p.key] = values[p.key] end
  coerce_integer_fields(dfields, params)

  local pw_result = values.password or { edited = false, raw = "" }
  local current_pw = current and current.password
  if current_pw == vim.NIL then current_pw = nil end
  local pw = (pw_result.edited and pw_result.raw ~= "") and pw_result.raw or current_pw
  if pw and pw ~= "" then params.password = pw end
  return params
end

--- Attempt to open, then immediately close, a connection on the backend using
--- `driver` + `params` (never persisted to disk) — the "Test Connection"
--- button's action. Calls `done(true, nil)` on success or `done(false, err)`
--- with the backend's plain-string error on failure.
--- @param driver string
--- @param params table
--- @param done   fun(ok: boolean, err: string|nil)
local function test_connect(driver, params, done)
  local client = require("grannos.client")
  local server_params = vim.tbl_extend("force", { driver = driver }, params)
  client.request("connect", server_params, function(err, result)
    if err then
      done(false, err)
      return
    end
    client.request("disconnect", { connection_id = result.connection_id }, function() end)
    done(true, nil)
  end)
end

-- Maps protocol language identifiers (from the server's Language enum) to Vim
-- filetypes.  This is the only place that knows about Vim-specific filetype names.
local LANGUAGE_TO_FT = {
  sql    = "sql",
  cypher = "cypher",
  promql = "promql",
}

--- Interactively pick a connection from `caps` and call `callback(key, params)`.
--- Proposes already-open connections first; selecting one calls back with `params = nil`
--- (the caller should associate rather than reconnect). Falls through to the
--- driver/group/connection wizard when there are no open connections, or when
--- "[+ New connection]" is chosen.
--- Skips driver and/or group steps when there is only one choice.
--- Calls `callback(nil)` on cancel.
--- @param caps       table   server capabilities (from client.ensure_capabilities)
--- @param active_set table   { [conn_key] = true } for all currently open connections
--- @param filetype   string  current buffer filetype, used to rank drivers
--- @param callback   fun(key: string|nil, params: table|nil)
function M.pick(caps, active_set, filetype, callback)
  local server      = caps.server or ""
  local server_data = M.load(server)

  --- Show the driver/group/connection wizard (the original, full `pick` flow).
  local function pick_driver()

  -- Build a rank map from caps so driver ordering is data-driven, not hardcoded.
  -- rank 1 = one of the driver's languages maps to the current filetype,
  -- rank 2 = generic driver (no declared languages),
  -- rank 3 = specialty driver for a different filetype.
  -- Connection count (descending) breaks ties within a rank.
  local rank_map = {}
  for _, d in ipairs(caps.drivers or {}) do
    local langs = d.languages or {}
    local rank = #langs == 0 and 2 or 3
    for _, lang in ipairs(langs) do
      if LANGUAGE_TO_FT[lang] == filetype then rank = 1; break end
    end
    rank_map[d.driver] = rank
  end

  -- Build label map from caps for drivers not yet in server_data.
  local caps_label = {}
  for _, d in ipairs(caps.drivers or {}) do
    caps_label[d.driver] = d.label or d.driver
  end

  -- Count saved connections per driver so busier drivers sort first within a rank.
  local driver_counts = {}
  for driver_id, driver_data in pairs(server_data) do
    local total = 0
    for _, gconns in pairs(driver_data.groups or {}) do total = total + vim.tbl_count(gconns) end
    driver_counts[driver_id] = total
  end

  -- Collect all known drivers: those with saved connections plus all caps drivers.
  local driver_id_set = {}
  for driver_id, driver_data in pairs(server_data) do
    for _, group_conns in pairs(driver_data.groups or {}) do
      if next(group_conns) then driver_id_set[driver_id] = true; break end
    end
  end
  for _, d in ipairs(caps.drivers or {}) do
    driver_id_set[d.driver] = true
  end
  local driver_ids = vim.tbl_keys(driver_id_set)
  table.sort(driver_ids, function(a, b)
    local ra, rb = rank_map[a] or 2, rank_map[b] or 2
    if ra ~= rb then return ra < rb end
    local ca, cb = driver_counts[a] or 0, driver_counts[b] or 0
    if ca ~= cb then return ca > cb end
    return a < b
  end)

  --- Show the connection list for (driver_id, group) and call callback on selection.
  --- @param driver_id string
  --- @param group     string
  local function do_pick_conn(driver_id, group)
    local driver_data = server_data[driver_id] or {}
    local group_conns = ((driver_data.groups or {})[group]) or {}
    local items = {}
    for name, params in pairs(group_conns) do
      local key = M.conn_key(server, driver_id, group, name)
      table.insert(items, { key = key, params = params })
    end
    table.sort(items, function(a, b) return M.conn_display_name(a.key) < M.conn_display_name(b.key) end)
    table.insert(items, { key = "[+ New connection]" })

    vim.ui.select(items, {
      prompt      = "Connection:",
      format_item = function(item)
        if not item.params then return item.key end
        local dn = M.conn_display_name(item.key)
        if active_set[item.key] then dn = dn .. "  [connected]" end
        return dn
      end,
    }, function(choice)
      if not choice then callback(nil) return end
      if not choice.params then
        M.create(caps, callback, { driver = driver_id, group = group })
        return
      end
      prompt_password(choice.params, function(params)
        if not params then callback(nil) return end
        callback(choice.key, params)
      end)
    end)
  end

  --- Show the group picker for `driver_id`, then delegate to do_pick_conn.
  --- Uses a flat list when the total connection count is at or below the threshold.
  --- @param driver_id string
  local function do_pick_group(driver_id)
    local driver_data = server_data[driver_id] or {}
    local groups = {}
    for group, group_conns in pairs(driver_data.groups or {}) do
      if next(group_conns) then table.insert(groups, group) end
    end
    table.sort(groups)

    if #groups <= 1 then
      do_pick_conn(driver_id, groups[1] or "")
      return
    end

    -- Count total connections across all groups.
    local total = 0
    for _, g in ipairs(groups) do
      total = total + vim.tbl_count((driver_data.groups or {})[g] or {})
    end

    local threshold = config.options.flat_conn_threshold or 5
    if total <= threshold then
      -- Flat list: show every connection as "group/name", sorted by display name.
      local items = {}
      for _, g in ipairs(groups) do
        local group_conns = (driver_data.groups or {})[g] or {}
        for conn_name, params in pairs(group_conns) do
          local key   = M.conn_key(server, driver_id, g, conn_name)
          local label = M.conn_display_name(key)
          if active_set[key] then label = label .. "  [connected]" end
          table.insert(items, { key = key, params = params, label = label })
        end
      end
      table.sort(items, function(a, b) return a.label < b.label end)
      table.insert(items, { key = "[+ New connection]" })

      vim.ui.select(items, {
        prompt      = "Connection:",
        format_item = function(item) return item.label or item.key end,
      }, function(choice)
        if not choice then callback(nil) return end
        if not choice.params then M.create(caps, callback, { driver = driver_id }) return end
        prompt_password(choice.params, function(params)
          if not params then callback(nil) return end
          callback(choice.key, params)
        end)
      end)
      return
    end

    local group_items = {}
    for _, g in ipairs(groups) do
      table.insert(group_items, { name = g, label = g ~= "" and g or "[No group]" })
    end

    vim.ui.select(group_items, {
      prompt      = "Group:",
      format_item = function(item) return item.label end,
    }, function(choice)
      if not choice then callback(nil) return end
      vim.schedule(function() do_pick_conn(driver_id, choice.name) end)
    end)
  end

  if #driver_ids == 0 then
    M.create(caps, callback)
    return
  end

  if #driver_ids == 1 then
    do_pick_group(driver_ids[1])
    return
  end

  local driver_items = {}
  for _, driver_id in ipairs(driver_ids) do
    local label = (server_data[driver_id] or {}).label or caps_label[driver_id] or driver_id
    table.insert(driver_items, { driver_id = driver_id, label = label })
  end

  vim.ui.select(driver_items, {
    prompt      = "Driver:",
    format_item = function(item) return item.label end,
  }, function(choice)
    if not choice then callback(nil) return end
    vim.schedule(function() do_pick_group(choice.driver_id) end)
  end)
  end

  local active_keys = vim.tbl_keys(active_set)
  if #active_keys == 0 then
    pick_driver()
    return
  end

  table.sort(active_keys, function(a, b) return M.conn_display_name(a) < M.conn_display_name(b) end)
  local active_items = {}
  for _, key in ipairs(active_keys) do
    local _, driver = M.conn_parts(key)
    local label = M.conn_display_name(key) .. " (" .. resolve_driver_label(caps, server, driver) .. ")"
    table.insert(active_items, { key = key, label = label })
  end
  table.insert(active_items, { key = nil, label = "[+ New connection]" })

  vim.ui.select(active_items, {
    prompt      = "Connection:",
    format_item = function(item) return item.label end,
  }, function(choice)
    if not choice then callback(nil) return end
    if not choice.key then pick_driver() return end
    callback(choice.key, nil)
  end)
end

--- Interactively create a new connection via a single form, save it, and call `callback(key, params)`.
--- Calls `callback(nil)` on cancel.
--- @param caps     table
--- @param callback fun(key: string|nil, params: table|nil)
--- @param defaults table|nil  { driver: string|nil, group: string|nil }  skip the driver picker
---                            and/or pre-fill the group field when the caller already knows them.
function M.create(caps, callback, defaults)
  caps = caps or { server = "", drivers = {} }
  local server = caps.server or ""
  defaults = defaults or {}

  --- Open the form once the driver is known.
  --- @param driver       string
  --- @param driver_label string
  local function with_driver(driver, driver_label)
    local dfields, pw_param = driver_fields(caps, driver)

    local fields = { make_name_field(nil), make_group_field(server, driver, defaults.group) }
    for _, p in ipairs(dfields) do table.insert(fields, driver_param_field(p, nil)) end
    vim.list_extend(fields, make_password_fields(pw_param, false))

    require("grannos.ui.conn_form").open({
      title     = "New Connection",
      fields    = fields,
      on_cancel = function() callback(nil) end,
      on_test   = function(values, done)
        test_connect(driver, build_connect_params(dfields, values, nil), done)
      end,
      on_submit = function(values, done)
        local name  = values.name
        local group = values.group
        local existing = ((M.load(server)[driver] or {}).groups or {})[group] or {}
        if existing[name] then
          done(("%q already exists in this group"):format(name))
          return
        end

        local params = { requires_password = false }
        for _, p in ipairs(dfields) do params[p.key] = values[p.key] end
        coerce_integer_fields(dfields, params)

        local pw_result = values.password or { edited = false, raw = "" }
        local pw = (pw_result.edited and pw_result.raw ~= "") and pw_result.raw or nil
        if pw and values.remember_password then
          params.password          = pw
          params.requires_password = false
        else
          params.requires_password = pw ~= nil and pw ~= ""
        end

        local key   = M.conn_key(server, driver, group, name)
        local data2 = read_data()
        if not data2 then done("failed to read the connections file"); return end
        upsert(data2, server, driver, driver_label, group, name, params)
        write_data(data2)
        vim.notify(("grannos: saved %q"):format(name), vim.log.levels.INFO)
        local out = (pw ~= nil and pw ~= "")
          and vim.tbl_extend("force", params, { password = pw }) or params
        done(nil)
        callback(key, out)
      end,
    })
  end

  if defaults.driver then
    with_driver(defaults.driver, resolve_driver_label(caps, server, defaults.driver))
    return
  end

  vim.ui.select(caps.drivers, {
    prompt      = "Driver:",
    format_item = function(d) return d.label or d.driver end,
  }, function(d)
    if not d then callback(nil) return end
    vim.schedule(function()
      with_driver(d.driver, d.label or d.driver)
    end)
  end)
end

--- Interactively edit an existing connection via a single form and call `callback(new_key, params)`.
--- Calls `callback(nil)` on cancel or error.
--- @param key      string
--- @param caps     table
--- @param callback fun(new_key: string|nil, params: table|nil)
function M.edit(key, caps, callback)
  caps = caps or { server = "", drivers = {} }
  local server, driver, group, name = M.conn_parts(key)
  local current = M.get(key)
  if not current then
    vim.notify(("grannos: connection %q not found"):format(name), vim.log.levels.ERROR)
    callback(nil)
    return
  end

  local driver_label  = resolve_driver_label(caps, server, driver)
  local dfields, pw_param = driver_fields(caps, driver)
  local had_password  = (current.password ~= nil and current.password ~= vim.NIL) or current.requires_password

  local fields = { make_name_field(name), make_group_field(server, driver, group) }
  for _, p in ipairs(dfields) do table.insert(fields, driver_param_field(p, current)) end
  vim.list_extend(fields, make_password_fields(pw_param, had_password))
  table.insert(fields, make_toggle_field("allow_writes", "Always allow write operations", current.allow_writes))

  require("grannos.ui.conn_form").open({
    title     = "Edit Connection",
    fields    = fields,
    on_cancel = function() callback(nil) end,
    on_test   = function(values, done)
      test_connect(driver, build_connect_params(dfields, values, current), done)
    end,
    on_submit = function(values, done)
      local new_name  = values.name
      local new_group = values.group
      local new_key   = M.conn_key(server, driver, new_group, new_name)
      if new_key ~= key and M.get(new_key) then
        done(("%q already exists in this group"):format(new_name))
        return
      end

      local params = { requires_password = current.requires_password or false }
      for _, p in ipairs(dfields) do params[p.key] = values[p.key] end
      coerce_integer_fields(dfields, params)
      params.allow_writes = values.allow_writes and true or nil

      local pw_result = values.password or { edited = false, raw = "" }
      local pw = (pw_result.edited and pw_result.raw ~= "") and pw_result.raw or nil
      if pw then
        if values.remember_password then
          params.password = pw; params.requires_password = false
        else
          params.requires_password = true
        end
      else
        if current.password then
          params.password = current.password; params.requires_password = false
        else
          params.requires_password = current.requires_password
        end
        pw = current.password
      end

      local data2 = read_data()
      if not data2 then done("failed to read the connections file"); return end
      if new_key ~= key then
        local og = (((data2[server] or {})[driver] or {}).groups or {})[group]
        if og then og[name] = nil end
      end
      upsert(data2, server, driver, driver_label, new_group, new_name, params)
      write_data(data2)
      vim.notify(("grannos: saved %q"):format(new_name), vim.log.levels.INFO)
      local final = (pw ~= nil and pw ~= "")
        and vim.tbl_extend("force", params, { password = pw }) or params
      done(nil)
      callback(new_key, final)
    end,
  })
end

--- Clone `source_key` under `new_name` via a single form and call `callback(new_key, params)`.
--- Calls `callback(nil)` on cancel.
--- @param source_key string
--- @param new_name   string
--- @param caps       table
--- @param callback   fun(new_key: string|nil, params: table|nil)
function M.clone(source_key, new_name, caps, callback)
  caps = caps or { server = "", drivers = {} }
  local server, driver, group = M.conn_parts(source_key)
  local current = M.get(source_key)
  if not current then
    vim.notify(("grannos: connection %q not found"):format(M.conn_display_name(source_key)), vim.log.levels.ERROR)
    callback(nil)
    return
  end

  local driver_label  = resolve_driver_label(caps, server, driver)
  local dfields, pw_param = driver_fields(caps, driver)
  local had_password  = (current.password ~= nil and current.password ~= vim.NIL) or current.requires_password

  local fields = { make_name_field(new_name), make_group_field(server, driver, group) }
  for _, p in ipairs(dfields) do table.insert(fields, driver_param_field(p, current)) end
  vim.list_extend(fields, make_password_fields(pw_param, had_password))

  require("grannos.ui.conn_form").open({
    title     = "Clone Connection",
    fields    = fields,
    on_cancel = function() callback(nil) end,
    on_test   = function(values, done)
      test_connect(driver, build_connect_params(dfields, values, current), done)
    end,
    on_submit = function(values, done)
      local name      = values.name
      local new_group = values.group
      local new_key   = M.conn_key(server, driver, new_group, name)
      local existing  = ((M.load(server)[driver] or {}).groups or {})[new_group] or {}
      if existing[name] then
        done(("%q already exists in this group"):format(name))
        return
      end

      local params = {
        requires_password = current.requires_password or false,
        allow_writes       = current.allow_writes,
      }
      for _, p in ipairs(dfields) do params[p.key] = values[p.key] end
      coerce_integer_fields(dfields, params)

      local pw_result = values.password or { edited = false, raw = "" }
      local pw = (pw_result.edited and pw_result.raw ~= "") and pw_result.raw or nil
      if pw then
        if values.remember_password then
          params.password = pw; params.requires_password = false
        else
          params.requires_password = true
        end
      else
        if current.password then
          params.password = current.password; params.requires_password = false
        else
          params.requires_password = current.requires_password
        end
        pw = current.password
      end

      local data2 = read_data()
      if not data2 then done("failed to read the connections file"); return end
      upsert(data2, server, driver, driver_label, new_group, name, params)
      write_data(data2)
      vim.notify(("grannos: saved %q"):format(name), vim.log.levels.INFO)
      local final = (pw ~= nil and pw ~= "")
        and vim.tbl_extend("force", params, { password = pw }) or params
      done(nil)
      callback(new_key, final)
    end,
  })
end

return M
