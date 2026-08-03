local M = {}

local client            = require("grannos.client")
local config            = require("grannos.config")
local hl                = require("grannos.hl")
local connections       = require("grannos.connections")
local executor          = require("grannos.executor")
local explorer          = require("grannos.ui.explorer")
local conn_label        = require("grannos.ui.conn_label")
local connections_panel = require("grannos.ui.connections")
local selection         = require("grannos.selection")
local gutter            = require("grannos.ui.gutter")
local ts_queries        = require("grannos.ts_queries")
local symbols           = require("grannos.symbols")
local log               = require("grannos.log")
local hover             = require("grannos.ui.hover")

local FLASH_NS = vim.api.nvim_create_namespace("GrannosFlash")

--- @class ConnSession
--- @field conn_id      any     backend connection id returned by the server
--- @field driver       string  driver identifier (e.g. "postgres", "neo4j")
--- @field key          string  composite NUL-separated connection key
--- @field driver_label string  human-readable driver name for UI labels

--- Briefly highlight a range in `bufnr` using the GrannosQueryFlash group, then clear it.
--- All coordinates are 0-indexed.
--- @param bufnr integer
--- @param sr    integer  start row
--- @param sc    integer  start col
--- @param er    integer  end row
--- @param ec    integer  end col
local function flash_range(bufnr, sr, sc, er, ec)
  vim.api.nvim_buf_clear_namespace(bufnr, FLASH_NS, 0, -1)
  vim.api.nvim_buf_set_extmark(bufnr, FLASH_NS, sr, sc, {
    end_row  = er,
    end_col  = ec,
    hl_group = "GrannosQueryFlash",
    priority = 200,
  })
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, FLASH_NS, 0, -1)
    end
  end, 200)
end

-- Session state.
--   conns:       connections opened this session  { [conn_key] = ConnSession }
--   buf_conns:   connection each buffer queries    { [bufnr]    = conn_key }
--   silent_bufs: buf_conns entries that must not surface the floating "Connected
--                to …" label or the query-info "K" keymap (e.g. diagram viewer
--                buffers, associated only so generic current-buffer APIs work)
local state = {
  conns       = {},
  buf_conns   = {},
  silent_bufs = {},
}

--- Return the connection record for `bufnr`, or nil when none is associated.
--- @param bufnr integer
--- @return ConnSession|nil
local function conn_for_buf(bufnr)
  local name = state.buf_conns[bufnr]
  return name and state.conns[name]
end

--- Return the human-readable label "display_name (Driver Label)" for a connection key.
--- @param key string
--- @return string
local function conn_display_label(key)
  local conn  = state.conns[key]
  local label = conn and (conn.driver_label or conn.driver)
  return label and (connections.conn_display_name(key) .. " (" .. label .. ")") or connections.conn_display_name(key)
end

--- Associate (or, with name=nil, dissociate) a buffer with a connection and update winbar labels.
--- @param bufnr integer
--- @param name  string|nil
--- @param opts  { silent: boolean|nil }|nil  silent = true records the association (so
---              current-buffer APIs like `open_explorer()` resolve it) without showing
---              the floating "Connected to …" label or installing the query-info "K" keymap
local function set_buf_conn(bufnr, name, opts)
  state.buf_conns[bufnr]   = name
  state.silent_bufs[bufnr] = (opts and opts.silent) or nil
  if state.silent_bufs[bufnr] then return end
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if name then conn_label.show(winid, conn_display_label(name)) else conn_label.hide(winid) end
  end
  if name then
    vim.keymap.set("n", "K", function() M.show_query_info() end, { buffer = bufnr, desc = "Show query info" })
  else
    pcall(vim.keymap.del, "n", "K", { buffer = bufnr })
  end
end

--- Public wrapper around set_buf_conn for use by other modules.
--- @param bufnr    integer
--- @param conn_key string|nil
--- @param opts     { silent: boolean|nil }|nil
function M.set_buf_conn(bufnr, conn_key, opts)
  set_buf_conn(bufnr, conn_key, opts)
end

--- Initialise config, highlights, gutter, and the connection-label autocmds.
--- @param opts table|nil
function M.setup(opts)
  config.setup(opts)
  hl.setup()
  gutter.setup()
  conn_label.setup(function(bufnr)
    if state.silent_bufs[bufnr] then return nil end
    local name = state.buf_conns[bufnr]
    return name and conn_display_label(name)
  end)
end


--- Start the backend if it isn't already running.
--- Returns false (and notifies) if the process could not be spawned.
--- @return boolean
local function start_backend()
  if client.is_running() then return true end
  local ok, err = pcall(client.start, config.options.server_cmd)
  if not ok then
    vim.notify("grannos: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Start the backend if needed, then deliver capabilities to `callback`.
--- Returns false if the backend could not be started.
--- @param callback fun(caps: table)
--- @return boolean
function M.ensure_backend_with_caps(callback)
  if not start_backend() then return false end
  client.ensure_capabilities(callback)
  return true
end

--- Connect to the named connection, or open the picker when `name` is blank.
--- @param name string  connection name or key (empty = open picker)
function M.attach(name)
  local bufnr = vim.api.nvim_get_current_buf()
  local auto_assign = vim.bo[bufnr].buftype == ""

  --- Associate the current buffer with the new connection if appropriate.
  --- @param conn_name string
  local function after_connect(conn_name)
    if auto_assign and vim.api.nvim_buf_is_valid(bufnr) then
      set_buf_conn(bufnr, conn_name)
    end
  end

  if name and name ~= "" then
    local params = connections.get(name)
    local resolved_key = name
    if not params then
      -- Search the active server's connections by display name (:DbAttach <name>).
      local active_caps = client.capabilities()
      local server = active_caps and (active_caps.server or "") or ""
      local server_data = connections.load(server)
      for driver_id, driver_data in pairs(server_data) do
        for group, group_conns in pairs(driver_data.groups or {}) do
          for conn_name, conn_params in pairs(group_conns) do
            if conn_name == name then
              resolved_key = connections.conn_key(server, driver_id, group, conn_name)
              params = conn_params
              break
            end
          end
          if params then break end
        end
        if params then break end
      end
    end
    if not params then
      vim.notify(("grannos: connection %q not found"):format(name), vim.log.levels.ERROR)
      return
    end
    M.ensure_backend_with_caps(function(caps)
      local _, driver = connections.conn_parts(resolved_key)
      connections.prompt_password(caps, driver, params, function(params_with_pw)
        if not params_with_pw then return end
        M._do_connect(resolved_key, params_with_pw, after_connect)
      end)
    end)
  else
    local ft = vim.bo[bufnr].filetype
    M.ensure_backend_with_caps(function(caps)
      local active_set = {}
      for _, k in ipairs(M.active_keys()) do active_set[k] = true end
      connections.pick(caps, active_set, ft, function(picked_name, params)
        if not picked_name then return end
        if not params then
          -- Picked an already-open connection: associate, don't reconnect.
          after_connect(picked_name)
          return
        end
        M._do_connect(picked_name, params, after_connect)
      end)
    end)
  end
end

--- Set the loading indicator on the connections panel, start the backend, then send connect.
--- @param name         string
--- @param params       table
--- @param after_connect fun(name: string)|nil
function M._do_connect(name, params, after_connect)
  connections_panel.set_conn_loading(name)
  local ok = M.ensure_backend_with_caps(function()
    M._send_connect(name, params, after_connect)
  end)
  if not ok then connections_panel.clear_conn_loading(name) end
end

-- Fields in connection params that must not be forwarded to the server.
local CLIENT_ONLY_FIELDS = { requires_password = true }

--- Send the "connect" request to the backend and register the connection on success.
--- @param name          string
--- @param params        table
--- @param after_connect fun(name: string)|nil
function M._send_connect(name, params, after_connect)
  local _, driver, _, _ = connections.conn_parts(name)
  local server_params = { driver = driver }
  for k, v in pairs(params) do
    if not CLIENT_ONLY_FIELDS[k] then server_params[k] = v end
  end
  local display = connections.conn_display_name(name)
  -- Get the human-readable driver label from capabilities.
  local driver_label = driver
  local caps = client.capabilities()
  if caps then
    for _, d in ipairs(caps.drivers or {}) do
      if d.driver == driver then driver_label = d.label or driver; break end
    end
  end
  client.request("connect", server_params, function(err, result)
    connections_panel.clear_conn_loading(name)
    if err then
      vim.notify(("grannos: %q failed — %s"):format(display, err), vim.log.levels.ERROR)
      connections_panel.set_conn_error(name, err)
      return
    end
    state.conns[name] = { conn_id = result.connection_id, driver = driver, key = name, driver_label = driver_label }
    vim.notify(("grannos: connected to %q (%s)"):format(display, driver_label), vim.log.levels.INFO)
    connections_panel.refresh()
    if after_connect then after_connect(name) end
  end)
end

--- Prompt the user to associate the current buffer with one of the open connections.
function M.associate()
  local keys = vim.tbl_keys(state.conns)
  if #keys == 0 then
    vim.notify("grannos: no open connections — open the connection panel with :DbConnections", vim.log.levels.WARN)
    return
  end
  table.sort(keys)
  vim.ui.select(keys, {
    prompt      = "Associate connection:",
    format_item = function(key)
      local conn  = state.conns[key]
      local label = conn and conn.driver_label
      return label and (connections.conn_display_name(key) .. " (" .. label .. ")") or connections.conn_display_name(key)
    end,
  }, function(key)
    if not key then return end
    set_buf_conn(vim.api.nvim_get_current_buf(), key)
    vim.notify(("grannos: buffer associated with %q"):format(connections.conn_display_name(key)), vim.log.levels.INFO)
  end)
end

--- Disconnect from `name` (or the current buffer's connection when `name` is empty).
--- @param name string  connection key or display name, or "" for current buffer
function M.disconnect(name)
  local key = name ~= "" and name or state.buf_conns[vim.api.nvim_get_current_buf()]
  if not key then
    vim.notify("grannos: no active connection", vim.log.levels.WARN)
    return
  end
  local conn = state.conns[key]
  if not conn then
    -- Try matching by display name
    for k in pairs(state.conns) do
      if connections.conn_display_name(k) == key then
        key = k
        conn = state.conns[k]
        break
      end
    end
  end
  if not conn then
    vim.notify(("grannos: not connected to %q"):format(name), vim.log.levels.ERROR)
    return
  end
  client.request("disconnect", { connection_id = conn.conn_id }, function(err, _)
    if err then
      vim.notify("grannos: " .. err, vim.log.levels.ERROR)
      return
    end
    state.conns[key] = nil
    -- Clear the label from every buffer that was using this connection.
    for bufnr, conn_name in pairs(state.buf_conns) do
      if conn_name == key then set_buf_conn(bufnr, nil) end
    end
    vim.notify(("grannos: disconnected from %q"):format(connections.conn_display_name(key)), vim.log.levels.INFO)
    connections_panel.refresh()
  end)
end

--- Return display names of all currently-open connections (for tab completion).
--- @return string[]
function M.active_names()
  local names = {}
  local seen = {}
  for key in pairs(state.conns) do
    local dn = connections.conn_display_name(key)
    if not seen[dn] then seen[dn] = true; table.insert(names, dn) end
  end
  table.sort(names)
  return names
end

--- Return the storage keys of all currently-open connections.
--- @return string[]
function M.active_keys()
  local keys = vim.tbl_keys(state.conns)
  table.sort(keys)
  return keys
end

--- Return the active connection record for `key`, or nil.
--- @param key string
--- @return ConnSession|nil
function M.get_conn(key)
  return state.conns[key]
end

--- Return valid bufnrs whose associated connection matches `name`.
--- @param name string  connection key
--- @return integer[]
function M.buffers_for(name)
  local result = {}
  for bufnr, conn_name in pairs(state.buf_conns) do
    if conn_name == name and vim.api.nvim_buf_is_valid(bufnr) then
      table.insert(result, bufnr)
    end
  end
  return result
end


--- Execute `sql` against the connection associated with `bufnr`, showing errors when none.
--- @param sql        string
--- @param bufnr      integer
--- @param first_line integer  0-indexed first line of `sql` in `bufnr`
local function execute_sql(sql, bufnr, first_line)
  if not sql or sql == "" then
    vim.notify("grannos: no SQL to execute", vim.log.levels.WARN)
    return
  end
  local conn = conn_for_buf(bufnr)
  if not conn then
    if next(state.conns) == nil then
      vim.notify("grannos: no active connection — use :DbConnections to connect", vim.log.levels.WARN)
    else
      vim.notify("grannos: no active connection — run :DbAssociate first", vim.log.levels.WARN)
    end
    return
  end
  executor.run(conn, sql, bufnr, first_line)
end

--- Execute the visual selection, or the treesitter statement at cursor, or the current line.
function M.execute()
  local bufnr = vim.api.nvim_get_current_buf()

  if selection.is_in_visual_mode() then
    local vsr = vim.fn.getpos("v")[2]
    local ver = vim.fn.getpos(".")[2]
    local sr  = math.min(vsr, ver) - 1  -- 0-indexed
    local er  = math.max(vsr, ver) - 1

    -- Flash when the selection fully covers 2+ distinct statements.
    local ts_stmts = ts_queries.statements_in_range(bufnr, sr, er)
    if ts_stmts and #ts_stmts > 1 then
      local first_s = ts_stmts[1]
      local last_s  = ts_stmts[#ts_stmts]
      -- end_row is exclusive in treesitter, so allow off-by-one vs er
      if first_s.start_row >= sr and last_s.end_row <= er + 1 then
        flash_range(bufnr, first_s.start_row, first_s.start_col, last_s.end_row, last_s.end_col)
      end
    end

    local sql = selection.get_selection()
    if not sql or sql == "" then
      vim.notify("grannos: empty selection", vim.log.levels.WARN)
      return
    end
    execute_sql(sql, bufnr, sr)
  else
    -- No selection: use treesitter to find the outermost statement at cursor.
    local ts_stmt = ts_queries.statement_at_cursor(bufnr)
    if ts_stmt then
      flash_range(bufnr, ts_stmt.start_row, ts_stmt.start_col, ts_stmt.end_row, ts_stmt.end_col)
      execute_sql(ts_stmt.text, bufnr, ts_stmt.start_row)
      return
    end

    -- Treesitter unavailable — fall back to the current line.
    local sql = vim.api.nvim_get_current_line()
    if vim.trim(sql) == "" then
      vim.notify("grannos: current line is empty", vim.log.levels.WARN)
      return
    end
    execute_sql(sql, bufnr, vim.api.nvim_win_get_cursor(0)[1] - 1)
  end
end

--- Execute lines `line1`–`line2` (1-indexed, inclusive) in the current buffer.
--- @param line1 integer
--- @param line2 integer
function M.execute_range(line1, line2)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)
  execute_sql(table.concat(lines, "\n"), bufnr, line1 - 1)
end

--- Open the connections panel sidebar.
function M.open_connections()
  connections_panel.open()
end

--- Open driver help for the connection associated with the current buffer.
--- @param opts table|nil  passed through to open_driver_help
function M.open_current_driver_help(opts)
  local conn = conn_for_buf(vim.api.nvim_get_current_buf())
  if not conn then
    vim.notify("grannos: no connection associated with this buffer", vim.log.levels.WARN)
    return
  end
  M.open_driver_help(conn.driver, opts)
end

--- Fetch and display markdown help for `driver` in a floating or split window.
--- @param driver string
--- @param opts   table|nil  { position = "bottom" } for a split; otherwise a centred float
function M.open_driver_help(driver, opts)
  opts = opts or {}
  if not start_backend() then return end
  client.request("driver.help", { driver = driver }, function(err, result)
    if err then
      vim.notify("grannos: " .. err, vim.log.levels.ERROR)
      return
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(result.content, "\n"))
    vim.bo[buf].filetype   = "markdown"
    vim.bo[buf].modifiable = false
    local win
    if opts.position == "bottom" then
      vim.cmd("belowright split")
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.api.nvim_win_set_height(win, math.floor(vim.o.lines * 0.4))
    else
      local width  = math.floor(vim.o.columns * 0.8)
      local height = math.floor(vim.o.lines   * 0.8)
      win = vim.api.nvim_open_win(buf, true, {
        relative   = "editor",
        width      = width,
        height     = height,
        row        = math.floor((vim.o.lines   - height) / 2),
        col        = math.floor((vim.o.columns - width)  / 2),
        style      = "minimal",
        border     = "rounded",
        title      = " " .. driver .. " ",
        title_pos  = "center",
      })
    end
    vim.keymap.set("n", "q",     function() vim.api.nvim_win_close(win, true) end, { buffer = buf, nowait = true })
    vim.keymap.set("n", "<Esc>", function() vim.api.nvim_win_close(win, true) end, { buffer = buf, nowait = true })
  end)
end

--- Open the schema explorer for the connection registered under `name`.
--- @param name string  connection key
function M.open_explorer_for(name)
  local conn = state.conns[name]
  if not conn then
    vim.notify(("grannos: not connected to %q — press <CR> to connect first"):format(connections.conn_display_name(name)), vim.log.levels.ERROR)
    return
  end
  explorer.open(conn.conn_id, connections.conn_display_name(name), conn.driver, name, conn.driver_label)
end

--- Open a form to view/change a live connection's runtime-only session
--- settings (session.set/session.get — see docs/protocol.md), e.g.
--- Prometheus's query_mode. Never persisted to connections.json. Notifies
--- and does nothing if the connection isn't open or its driver has no
--- session settings.
--- @param key string  composite connection key
function M.open_session_settings_for(key)
  local conn = state.conns[key]
  if not conn then
    vim.notify(("grannos: not connected to %q — press <CR> to connect first"):format(connections.conn_display_name(key)), vim.log.levels.ERROR)
    return
  end
  client.get_session(conn.conn_id, function(err, current)
    if err then
      vim.notify(("grannos: %s has no session settings"):format(conn.driver_label or conn.driver), vim.log.levels.WARN)
      return
    end
    local caps   = client.capabilities() or { drivers = {} }
    local fields = connections.session_fields(caps, conn.driver, current)
    if #fields == 0 then
      vim.notify(("grannos: %s has no session settings"):format(conn.driver_label or conn.driver), vim.log.levels.WARN)
      return
    end
    require("grannos.ui.conn_form").open({
      title     = "Session Settings",
      fields    = fields,
      on_cancel = function() end,
      on_submit = function(values, done)
        local session_values = connections.build_session_values(caps, conn.driver, values)
        client.set_session(conn.conn_id, session_values, function(err2)
          done(err2)
        end)
      end,
    })
  end)
end

--- Open the session settings form for the current buffer's connection.
function M.open_session_settings()
  local key = state.buf_conns[vim.api.nvim_get_current_buf()]
  if not key then
    vim.notify("grannos: no active connection — run :DbAttach first", vim.log.levels.WARN)
    return
  end
  M.open_session_settings_for(key)
end

--- Open the schema explorer for the current buffer's connection.
function M.open_explorer()
  local key = state.buf_conns[vim.api.nvim_get_current_buf()]
  local conn = key and state.conns[key]
  if not conn then
    vim.notify("grannos: no active connection — run :DbAttach first", vim.log.levels.WARN)
    return
  end
  explorer.open(conn.conn_id, connections.conn_display_name(key), conn.driver, key, conn.driver_label)
end

--- Stop the backend and clear all session state.
local function teardown()
  client.stop()  -- also resets capabilities cache
  state.conns = {}
  for _, bufnr in ipairs(vim.tbl_keys(state.buf_conns)) do
    set_buf_conn(bufnr, nil)
  end
  explorer.reset()
end

--- Stop the backend process and notify the user.
function M.stop()
  teardown()
  vim.notify("grannos: backend stopped", vim.log.levels.INFO)
end

--- Restart the backend process (teardown then start).
function M.restart()
  teardown()
  if start_backend() then
    vim.notify("grannos: backend restarted", vim.log.levels.INFO)
  end
end

--- Open the save-query wizard for `content` in the context of `bufnr`.
--- @param content string
--- @param bufnr   integer
local function open_save_query(content, bufnr)
  local ext = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":e")
  if ext == "" then ext = vim.bo[bufnr].filetype end
  require("grannos.ui.save_query").open(content, state.buf_conns[bufnr], ext)
end

--- Save the visual selection or current line as a named query (mode-aware).
function M.save_query()
  local bufnr = vim.api.nvim_get_current_buf()
  local content
  if selection.is_in_visual_mode() then
    content = selection.get_selection()
    if not content or content == "" then
      vim.notify("grannos: empty selection", vim.log.levels.WARN)
      return
    end
  else
    content = vim.api.nvim_get_current_line()
    if vim.trim(content) == "" then
      vim.notify("grannos: current line is empty", vim.log.levels.WARN)
      return
    end
  end
  open_save_query(content, bufnr)
end

--- Save lines `line1`–`line2` (1-indexed, already resolved by Neovim) as a named query.
--- @param line1 integer
--- @param line2 integer
function M.save_query_range(line1, line2)
  local bufnr   = vim.api.nvim_get_current_buf()
  local lines   = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)
  local content = table.concat(lines, "\n")
  if vim.trim(content) == "" then
    vim.notify("grannos: empty selection", vim.log.levels.WARN)
    return
  end
  open_save_query(content, bufnr)
end

local render_query_info  -- forward declaration; defined below show_query_info

--- Describe the node at `path` in a float — the same dispatch diagram.lua uses
--- for hovering diagram regions.
--- @param conn_key string
--- @param path     string[]
local function describe_symbol(conn_key, path)
  local conn = state.conns[conn_key]
  if not conn then return end
  client.request("explore.describe", { connection_id = conn.conn_id, path = path }, function(err, result)
    vim.schedule(function()
      if err then
        vim.notify("grannos: " .. err, vim.log.levels.ERROR)
        return
      end
      local details = result and result.details
      if not details or details == vim.NIL then
        vim.notify("grannos: nothing to describe here", vim.log.levels.WARN)
        return
      end
      if details.type == "field" then
        require("grannos.ui.column").open_single(details)
      else
        explorer.open_describe_float(details, { name = path[#path], type = "table" })
      end
    end)
  end)
end

--- Resolve the symbol described by `query` to a node path via `explore.find`,
--- then describe it. The backend owns the search: it knows where each kind of
--- node lives in its own tree, and matches names case-insensitively against the
--- catalog's own casing, which the query text rarely reproduces.
--- Notifies instead of describing when the symbol names no node, or more than
--- one — a bare column across joined tables is genuinely ambiguous, and picking
--- one would be a guess.
--- @param conn_key string
--- @param query    SymbolQuery
local function find_and_describe_symbol(conn_key, query)
  local conn = state.conns[conn_key]
  if not conn then return end
  local params = {
    connection_id = conn.conn_id,
    type          = query.type,
    name          = query.name,
    scope         = query.scope,
  }
  client.request("explore.find", params, function(err, result)
    vim.schedule(function()
      if err then
        vim.notify("grannos: " .. err, vim.log.levels.ERROR)
        return
      end
      local paths = result and result.paths or {}
      if #paths == 0 then
        vim.notify(
          ('grannos: no information found for "%s"'):format(query.name),
          vim.log.levels.INFO)
      elseif #paths > 1 then
        vim.notify(
          ('grannos: "%s" is ambiguous — %d matches'):format(query.name, #paths),
          vim.log.levels.WARN)
      else
        describe_symbol(conn_key, paths[1])
      end
    end)
  end)
end

--- Open a hover float showing execution info for the query at the cursor.
--- If the hover float is already open, close it and open the results pane instead.
--- When the cursor sits on a table or column reference (see
--- grannos.symbols.at_cursor), describes that symbol instead — including when
--- the symbol turns out to name nothing, which is reported rather than falling
--- back to query-execution info: the cursor is on an identifier, so execution
--- info is not what was being asked for.
function M.show_query_info()
  local bufnr    = vim.api.nvim_get_current_buf()
  local conn_key = state.buf_conns[bufnr]
  if not conn_key then return end

  local symbol = symbols.at_cursor(bufnr)
  if symbol then
    find_and_describe_symbol(conn_key, symbol)
    return
  end

  local stmt  = ts_queries.statement_at_cursor(bufnr)
  local line  = stmt and stmt.start_row or (vim.api.nvim_win_get_cursor(0)[1] - 1)
  local entry = log.find_at(conn_key, bufnr, line)
  if not entry then
    vim.notify("grannos: no executed query at cursor", vim.log.levels.INFO)
    return
  end

  if hover.is_open() then
    hover.close()
    local results_ui = require("grannos.ui.results")
    local conn       = state.conns[conn_key]
    results_ui.set_conn_name(conn_key, conn and conn.driver_label, entry.bufnr or bufnr)
    if entry.status == "success" then
      results_ui.show_results(
        entry.columns or {}, log.load_rows(entry),
        entry.rows_returned, entry.rows_total, entry.duration_ms)
    elseif entry.status == "rows_affected" then
      results_ui.show_rows_affected(entry.rows_affected, entry.verb or "affected", entry.duration_ms)
    elseif entry.status == "error" then
      results_ui.show_error(entry.error_msg or "unknown error")
    end
    return
  end

  hover.open(render_query_info(entry), bufnr)
end

--- Return display lines for a query log entry (pure, no nvim API calls).
--- @param entry LogEntry
--- @return string[]
render_query_info = function(entry)
  local lines = {}
  table.insert(lines, "Executed: " .. os.date("%Y-%m-%d %H:%M:%S", entry.timestamp))
  if entry.status == "running" then
    table.insert(lines, "Status:   running…")
  elseif entry.status == "error" then
    table.insert(lines, "Status:   error")
    if entry.error_msg then
      table.insert(lines, "Error:    " .. entry.error_msg)
    end
  else
    table.insert(lines, ("Duration: %d ms"):format(entry.duration_ms or 0))
    if entry.status == "rows_affected" then
      table.insert(lines, ("Rows:     %d %s"):format(entry.rows_affected or 0, entry.verb or "affected"))
    elseif entry.rows_returned ~= nil then
      local s = ("Rows:     %d returned"):format(entry.rows_returned)
      if entry.rows_total and entry.rows_total > entry.rows_returned then
        s = s .. (" (of %d)"):format(entry.rows_total)
      end
      table.insert(lines, s)
    end
  end
  return lines
end

--- Cancel the running query that covers the cursor line.
function M.cancel_query()
  local bufnr      = vim.api.nvim_get_current_buf()
  local line       = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-indexed
  local request_id = gutter.find_request_covering_line(bufnr, line)
  if not request_id then
    vim.notify("grannos: no running query covers the cursor", vim.log.levels.WARN)
    return
  end
  client.cancel(request_id, function(err, _)
    if err then
      vim.notify("grannos: cancel failed — " .. err, vim.log.levels.ERROR)
    end
  end)
end

--- Ensure `conn_key` has an active connection, connecting first (prompting for a password
--- if needed) when it does not, then invoke `callback(conn_key)`. Does nothing further if
--- the user cancels the password prompt or the connect attempt fails.
--- @param conn_key string
--- @param callback fun(conn_key: string)
function M.ensure_connected(conn_key, callback)
  if state.conns[conn_key] then
    callback(conn_key)
    return
  end
  local params = connections.get(conn_key)
  if not params then
    vim.notify(("grannos: connection %q not found"):format(conn_key), vim.log.levels.ERROR)
    return
  end
  M.ensure_backend_with_caps(function(caps)
    local _, driver = connections.conn_parts(conn_key)
    connections.prompt_password(caps, driver, params, function(params_with_pw)
      if not params_with_pw then return end
      M._do_connect(conn_key, params_with_pw, callback)
    end)
  end)
end

--- Open the saved-query picker for `conn_key` (defaults to the current buffer's connection).
--- @param conn_key string|nil
function M.load_query(conn_key)
  if not conn_key then
    conn_key = state.buf_conns[vim.api.nvim_get_current_buf()]
  end
  if not conn_key then
    vim.notify("grannos: no connection associated with current buffer", vim.log.levels.WARN)
    return
  end
  require("grannos.ui.query_picker").open(conn_key)
end

--- Open the query log viewer for `conn_key` (defaults to the current buffer's connection).
--- @param conn_key string|nil
function M.query_log(conn_key)
  if not conn_key then
    local cur = vim.api.nvim_get_current_buf()
    local results_ui = require("grannos.ui.results")
    if results_ui.is_results_buf(cur) then
      conn_key = results_ui.conn_key_for_buf(cur)
    else
      conn_key = state.buf_conns[cur]
    end
  end
  if not conn_key then
    vim.notify("grannos: no connection associated with current buffer", vim.log.levels.WARN)
    return
  end
  require("grannos.ui.query_log").open(conn_key, state.conns[conn_key])
end

return M
