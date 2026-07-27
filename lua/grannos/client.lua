-- Manages the Python backend process and speaks newline-delimited JSON.
--
-- Wire format (both directions): one JSON object per line.
--
-- Request  fields: {id, method, params}
-- Response fields: {id, result, error}
local M = {}

local state = {
  job_id     = nil,
  next_id    = 1,
  pending    = {},  -- id → callback(err, result)
  line_parts = {},  -- chunks of the partial line accumulated across on_stdout calls
}

local caps_cache   = nil  -- cached capabilities result
local caps_pending = {}   -- callbacks waiting for the first fetch

-- Wire-protocol version this client was built against, as "<major>.<minor>".
-- Bump the major component alongside protocol.md and grannos-py's
-- PROTOCOL_VERSION for breaking changes; bump minor for additive changes.
-- Only major is checked for compatibility — a minor bump is guaranteed
-- backward-compatible by convention.
local PROTOCOL_VERSION = "1.0"
M.PROTOCOL_VERSION = PROTOCOL_VERSION


-- Neovim jobstart line convention: data[1] continues the previous partial
-- line; data[#data] is always the (possibly empty) start of the next line.
--
-- A single response line can be many megabytes (e.g. a large SELECT) and
-- arrives across many separate on_stdout calls. Chunks are collected in
-- line_parts and joined with a single table.concat once a line boundary
-- shows up, rather than repeatedly concatenating strings — Lua strings are
-- immutable, so `buf = buf .. chunk` on every call would copy the
-- ever-growing buffer each time (O(n^2) in the line's total size).
--- @param _ any
--- @param data string[]
--- @param __ any
local function on_stdout(_, data, _)
  table.insert(state.line_parts, data[1])
  for i = 2, #data do
    local line = table.concat(state.line_parts)
    state.line_parts = { data[i] }
    if line ~= "" then
      local ok, msg = pcall(vim.json.decode, line)
      if ok then
        M._dispatch(msg)
      end
    end
  end
end


--- Recursively strip vim.NIL from object keys; preserve it in array positions
--- so that SQL NULL cells remain as vim.NIL for the table renderer.
--- @param v any
--- @return any
local function strip_nil(v)
  if v == vim.NIL then return nil end
  if type(v) ~= "table" then return v end
  if vim.islist(v) then
    for i = 1, #v do
      local val = v[i]
      if val ~= vim.NIL and type(val) == "table" then
        v[i] = strip_nil(val)
      end
    end
  else
    for k, val in pairs(v) do
      v[k] = strip_nil(val)
    end
  end
  return v
end

--- Route an incoming server message to its waiting callback.
--- Progress messages invoke on_progress without resolving the pending entry.
--- @param msg table  decoded JSON message from the server
function M._dispatch(msg)
  local id = msg.id
  if id == nil then return end
  local entry = state.pending[id]
  if not entry then return end
  if msg.progress then
    if entry.progress then entry.progress(msg.progress) end
    return
  end
  state.pending[id] = nil
  local err = msg.error
  if err and err ~= vim.NIL then
    entry.cb(err, nil)
  else
    entry.cb(nil, strip_nil(msg.result))
  end
end


--- Send a JSON-RPC request to the backend.
--- @param method      string
--- @param params      table|nil
--- @param callback    fun(err: string|nil, result: any)  called on completion
--- @param on_progress fun(progress: table)|nil           called for each intermediate progress message
--- @return integer|nil  request id, or nil when the backend is not running
function M.request(method, params, callback, on_progress)
  if not state.job_id then
    callback("Backend not running", nil)
    return nil
  end
  local id      = state.next_id
  state.next_id = id + 1
  state.pending[id] = { cb = callback, progress = on_progress }
  local p = (params == nil or vim.tbl_isempty(params)) and vim.empty_dict() or params
  local line = vim.json.encode({ id = id, method = method, params = p }) .. "\n"
  vim.fn.chansend(state.job_id, line)
  return id
end

--- Send a cancellation request for `request_id`.
--- @param request_id integer
--- @param callback   fun(err: string|nil, result: any)|nil
function M.cancel(request_id, callback)
  M.request("cancel", { request_id = request_id }, callback or function() end)
end

--- Update runtime-only session settings on a live connection (never persisted
--- to connections.json; see capabilities.drivers[].session_params).
--- @param conn_id  string
--- @param values   table  driver-specific session_params fields to change
--- @param callback fun(err: string|nil, result: any)
function M.set_session(conn_id, values, callback)
  local params = vim.tbl_extend("force", { connection_id = conn_id }, values)
  M.request("session.set", params, callback)
end

--- Fetch a live connection's current session-only setting values.
--- @param conn_id  string
--- @param callback fun(err: string|nil, result: table|nil)
function M.get_session(conn_id, callback)
  M.request("session.get", { connection_id = conn_id }, callback)
end

--- Start the backend process identified by `cmd`.
--- Errors if the process cannot be spawned (e.g. command not found).
--- @param cmd string  shell command to launch the backend
function M.start(cmd)
  if state.job_id then return end
  local job_id = vim.fn.jobstart(cmd, {
    on_stdout = on_stdout,
    on_exit   = function(_, code, _)
      state.job_id     = nil
      state.line_parts = {}
      local pending    = state.pending
      state.pending  = {}
      M.reset_capabilities()
      for _, entry in pairs(pending) do
        entry.cb("backend exited", nil)
      end
      if code == 127 then
        vim.notify("`grannos` not found in PATH. Are you sure that it is correctly installed?", vim.log.levels.ERROR)
      elseif code ~= 0 then
        vim.notify(("grannos: backend exited with code %d"):format(code), vim.log.levels.ERROR)
      end
    end,
    stdin  = "pipe",
    stdout = "pipe",
  })
  if job_id <= 0 then
    error(("grannos: failed to start %q — is it installed?"):format(cmd))
  end
  state.job_id = job_id
end

--- Return a human-readable warning when `server_version`'s major component
--- doesn't match this client's, or nil when compatible (including when
--- `server_version` is nil, e.g. a pre-versioning server).
--- @param server_version string|nil  `protocol_version` from `capabilities`
--- @return string|nil
function M.check_protocol_compat(server_version)
  local client_major = PROTOCOL_VERSION:match("^(%d+)")
  local server_major = server_version and server_version:match("^(%d+)")
  if server_major == client_major then return nil end
  return ("grannos: protocol version mismatch — client expects v%s, server reports %s. Update grannos.nvim and grannos-py to compatible versions."):format(
    PROTOCOL_VERSION, server_version or "none (pre-versioning server)")
end

--- Fetch capabilities once and cache the result; subsequent calls return immediately.
--- @param callback fun(caps: table)
function M.ensure_capabilities(callback)
  if caps_cache then callback(caps_cache) return end
  table.insert(caps_pending, callback)
  if #caps_pending > 1 then return end  -- request already in-flight
  M.request("capabilities", {}, function(err, result)
    if err then
      caps_cache = { server = "", drivers = {} }
    else
      caps_cache = result
      local warning = M.check_protocol_compat(caps_cache.protocol_version)
      if warning then vim.notify(warning, vim.log.levels.ERROR) end
    end
    local waiting = caps_pending
    caps_pending = {}
    for _, cb in ipairs(waiting) do cb(caps_cache) end
  end)
end

--- Return the cached capabilities synchronously, or nil if not yet fetched.
--- @return table|nil
function M.capabilities()
  return caps_cache
end

--- Clear the capabilities cache and any pending callbacks.
function M.reset_capabilities()
  caps_cache   = nil
  caps_pending = {}
end

--- Stop the backend process and reset capabilities.
function M.stop()
  if state.job_id then
    vim.fn.jobstop(state.job_id)
  end
  M.reset_capabilities()
end

--- Return true when the backend process is currently running.
--- @return boolean
function M.is_running()
  return state.job_id ~= nil
end

return M
