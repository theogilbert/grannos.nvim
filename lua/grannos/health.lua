--- `:checkhealth grannos` — verifies that the plugin is set up and that the
--- backend named by `server_cmd` is installed, runnable, and speaks a
--- compatible protocol version.
---
--- The report is built by `M.report()` as a flat list of entries and only
--- rendered by `M.check()`, so the checks are testable without a checkhealth
--- buffer.
local M = {}

local client      = require("grannos.client")
local config      = require("grannos.config")
local connections = require("grannos.connections")

-- Languages with a symbol extractor (see grannos/symbols/init.lua). The first
-- three ship as precompiled parsers under parser/; json comes with Neovim.
local LANGUAGES = { "sql", "cypher", "promql", "json" }

-- How long the probe waits for the backend to answer `capabilities`.
local PROBE_TIMEOUT_MS = 5000

--- @class HealthEntry
--- @field level  "start"|"ok"|"info"|"warn"|"error"
--- @field msg    string
--- @field advice string[]|nil  remediation lines; only rendered for warn/error

--- Append an entry to `entries`.
--- @param entries HealthEntry[]
--- @param level   "start"|"ok"|"info"|"warn"|"error"
--- @param msg     string
--- @param advice  string[]|nil
local function add(entries, level, msg, advice)
  entries[#entries + 1] = { level = level, msg = msg, advice = advice }
end

--- Start `cmd`, ask it for `capabilities`, and wait for the reply.
--- Runs its own short-lived process rather than reusing the session's backend,
--- so the check reports whether the configured command actually works.
--- @param cmd        string   shell command that launches the backend
--- @param timeout_ms integer  how long to wait for the response
--- @return table|nil result  the decoded `capabilities` result
--- @return string|nil err    human-readable failure reason, when result is nil
function M.probe(cmd, timeout_ms)
  local result, failure, exit_code
  local stderr, parts = {}, {}

  --- Record the first complete response line the backend writes.
  --- @param line string
  local function handle_line(line)
    if line == "" or result or failure then return end
    local ok, msg = pcall(vim.json.decode, line)
    if not ok or type(msg) ~= "table" then return end
    local err = msg.error
    if err and err ~= vim.NIL then
      failure = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
    else
      result = msg.result
    end
  end

  local job = vim.fn.jobstart(cmd, {
    on_stdout = function(_, data)
      parts[#parts + 1] = data[1]
      for i = 2, #data do
        handle_line(table.concat(parts))
        parts = { data[i] }
      end
    end,
    on_stderr = function(_, data)
      for _, chunk in ipairs(data) do
        if chunk ~= "" then stderr[#stderr + 1] = chunk end
      end
    end,
    on_exit = function(_, code, _)
      handle_line(table.concat(parts))
      exit_code = code
    end,
    stdin  = "pipe",
    stdout = "pipe",
    stderr = "pipe",
  })
  if job <= 0 then return nil, ("could not spawn %q"):format(cmd) end

  pcall(vim.fn.chansend, job,
    vim.json.encode({ id = 1, method = "capabilities", params = vim.empty_dict() }) .. "\n")
  vim.wait(timeout_ms, function()
    return result ~= nil or failure ~= nil or exit_code ~= nil
  end, 20)
  pcall(vim.fn.jobstop, job)

  if result ~= nil then return result, nil end

  local detail = #stderr > 0 and ("\nstderr: " .. table.concat(stderr, "\n        ")) or ""
  if failure then
    return nil, ("the backend answered `capabilities` with an error: %s%s"):format(failure, detail)
  end
  if exit_code then
    return nil, ("the backend exited with code %d before answering `capabilities`%s"):format(exit_code, detail)
  end
  return nil, ("the backend did not answer `capabilities` within %dms%s"):format(timeout_ms, detail)
end

--- Report on `setup()` having run, and on the paths it resolved.
--- @param entries HealthEntry[]
--- @return boolean  whether setup() has been called
local function check_config(entries)
  add(entries, "start", "grannos: configuration")

  if vim.tbl_isempty(config.options) then
    add(entries, "error", 'require("grannos").setup() has not been called', {
      'Add `require("grannos").setup()` to your config — no option has a value until it runs.',
    })
    return false
  end
  add(entries, "ok", 'require("grannos").setup() has been called')

  local path = config.options.connections_file
  if vim.fn.filereadable(path) == 1 then
    local ok, parsed = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
    if ok and type(parsed) == "table" then
      local count = 0
      for _ in pairs(connections.load_all()) do count = count + 1 end
      add(entries, "ok", ("connections file: %s (%d server%s)"):format(path, count, count == 1 and "" or "s"))
    else
      add(entries, "error", "connections file is not valid JSON: " .. path, {
        "Fix or remove the file — connections cannot be read or saved while it is corrupted.",
      })
    end
  else
    add(entries, "info", ("connections file: %s (not created yet)"):format(path))
  end

  local queries_dir = config.options.queries_dir
  add(entries, "info", ("queries directory: %s%s"):format(
    queries_dir, vim.fn.isdirectory(queries_dir) == 1 and "" or " (not created yet)"))
  return true
end

--- Report on the backend: that its executable exists, that it runs, and that
--- it speaks a compatible protocol version.
--- @param entries HealthEntry[]
--- @param cmd     string  the configured server_cmd
local function check_backend(entries, cmd)
  add(entries, "start", "grannos: backend")
  add(entries, "info", ("server_cmd: %s"):format(cmd))

  local problem = client.check_executable(cmd)
  if problem then
    add(entries, "error", problem, {
      "Install a server that implements the grannos protocol (e.g. grannos-py).",
      'Then set `server_cmd` in require("grannos").setup({ server_cmd = "…" }) if it is not on $PATH.',
    })
    return
  end

  local name = client.executable_name(cmd)
  if name then
    add(entries, "ok", ("backend executable found: %s"):format(vim.fn.exepath(name) ~= "" and vim.fn.exepath(name) or name))
  else
    add(entries, "info", "server_cmd is a shell expression; skipping the executable lookup")
  end

  local caps, err = M.probe(cmd, PROBE_TIMEOUT_MS)
  if not caps then
    add(entries, "error", "backend did not respond: " .. err, {
      "Run the command in a shell to see what it prints.",
      "The backend must speak newline-delimited JSON on stdio — see docs/protocol.md.",
    })
    return
  end

  add(entries, "ok", ("backend responded to `capabilities` (server: %s)"):format(
    caps.server ~= nil and caps.server ~= "" and tostring(caps.server) or "unnamed"))

  local warning = client.check_protocol_compat(caps.protocol_version)
  if warning then
    add(entries, "error", warning, { "Update grannos.nvim and the backend to compatible versions." })
  else
    add(entries, "ok", ("protocol version %s (client expects %s)"):format(
      caps.protocol_version, client.PROTOCOL_VERSION))
  end

  local drivers = {}
  for _, driver in ipairs(caps.drivers or {}) do
    drivers[#drivers + 1] = driver.label or driver.driver or "?"
  end
  if #drivers > 0 then
    add(entries, "ok", ("%d driver%s available: %s"):format(
      #drivers, #drivers == 1 and "" or "s", table.concat(drivers, ", ")))
  else
    add(entries, "warn", "the backend reports no drivers", {
      "Install the database drivers your backend needs (see its documentation).",
    })
  end
end

--- Report on the treesitter parsers the symbol extractors need.
--- @param entries HealthEntry[]
local function check_parsers(entries)
  add(entries, "start", "grannos: treesitter parsers")
  for _, lang in ipairs(LANGUAGES) do
    if pcall(vim.treesitter.language.add, lang) then
      add(entries, "ok", ("`%s` parser available"):format(lang))
    else
      add(entries, "warn", ("`%s` parser not available"):format(lang), {
        ("Statement detection and symbol lookups will not work in %s buffers."):format(lang),
        lang == "json"
          and "Install it with `:TSInstall json` (used for MongoDB queries)."
          or ("grannos.nvim ships this parser in parser/%s.so — check that the plugin directory is on your runtimepath."):format(lang),
      })
    end
  end
end

--- Report on optional integrations.
--- @param entries HealthEntry[]
local function check_optional(entries)
  add(entries, "start", "grannos: optional dependencies")
  if pcall(require, "fzf-lua") then
    add(entries, "ok", "fzf-lua installed — used for the saved-query picker")
  else
    add(entries, "info", "fzf-lua not installed — the saved-query picker falls back to vim.ui.select")
  end
end

--- Build the full health report.
--- @return HealthEntry[]
function M.report()
  local entries = {}

  add(entries, "start", "grannos: requirements")
  local v = vim.version()
  if vim.fn.has("nvim-0.9") == 1 then
    add(entries, "ok", ("Neovim %d.%d.%d"):format(v.major, v.minor, v.patch))
  else
    add(entries, "error", "Neovim 0.9 or later is required", { "Upgrade Neovim." })
  end

  local configured = check_config(entries)
  check_backend(entries, configured and config.options.server_cmd or config.defaults.server_cmd)
  check_parsers(entries)
  check_optional(entries)
  return entries
end

--- Render the report through vim.health. Entry point for `:checkhealth grannos`.
function M.check()
  local h = vim.health
  -- vim.health.report_* was renamed to vim.health.* in Neovim 0.10.
  local render = {
    start = h.start or h.report_start,
    ok    = h.ok    or h.report_ok,
    info  = h.info  or h.report_info,
    warn  = h.warn  or h.report_warn,
    error = h.error or h.report_error,
  }
  for _, entry in ipairs(M.report()) do
    if entry.advice then
      render[entry.level](entry.msg, entry.advice)
    else
      render[entry.level](entry.msg)
    end
  end
end

return M
