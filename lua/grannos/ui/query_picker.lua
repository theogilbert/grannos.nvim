local M = {}

local queries = require("grannos.queries")

local SEP     = "\t"
local KEY_SEP = "\1"   -- SOH: won't appear in scope keys or query names

local COMMENT_PREFIX = { cypher = "//", mongo = "//" }

--- Return the line-comment prefix for `filetype`, defaulting to "--".
--- @param filetype string
--- @param text     string
--- @return string
local function render_comment(filetype, text)
  return (COMMENT_PREFIX[filetype] or "--") .. " " .. text
end

--- Build the fzf entry string for a saved-query record.
--- Format: "[scope_label] name <TAB> first_line <TAB> path <TAB> scope_key\1name"
--- @param e table  { scope_key, name, content, path, ... }
--- @return string
local function make_entry(e)
  local first_line = (e.content:match("^[^\n]*") or ""):gsub("\t", "  ")
  if #first_line > 100 then first_line = first_line:sub(1, 100) .. "…" end
  local label  = "[" .. queries.scope_label(e.scope_key) .. "]"
  local hidden = e.scope_key .. KEY_SEP .. e.name
  return label .. " " .. e.name .. SEP .. first_line .. SEP .. (e.path or "") .. SEP .. hidden
end

--- Extract scope_key and query name from a fzf entry string.
--- Returns nil, nil when the entry is malformed.
--- @param s string  raw fzf selection string
--- @return string|nil scope_key, string|nil name
local function decode_entry(s)
  local parts  = vim.split(s, SEP, { plain = true })
  local hidden = parts[#parts]
  local sep    = hidden:find(KEY_SEP, 1, true)
  if not sep then return nil, nil end
  return hidden:sub(1, sep - 1), hidden:sub(sep + 1)
end

--- Return the bufnr of the buffer whose name equals `name`, or -1 when not found.
--- @param name string
--- @return integer
local function find_buf_by_name(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == name then
      return b
    end
  end
  return -1
end

--- Open (or focus) a scratch buffer containing the saved query `name` under `scope_key`.
--- Optionally associates the buffer with `conn_key`.
--- @param scope_key  string
--- @param name       string
--- @param data_by_key table<string, table>  all entries indexed by "scope_key\1name"
--- @param conn_key   string|nil
local function open_query_buffer(scope_key, name, data_by_key, conn_key)
  local e = data_by_key[scope_key .. KEY_SEP .. name]
  if not e then return end

  local bufname = "grannos://queries/" .. scope_key .. "/" .. name
  local bufnr   = find_buf_by_name(bufname)

  -- A buffer can be valid but unloaded (e.g. after :bdelete or session restore),
  -- keeping its name while losing its lines. Repopulate in that case instead of
  -- silently reusing an empty buffer.
  if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
    if bufnr == -1 then
      bufnr = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_buf_set_name(bufnr, bufname)
    else
      vim.fn.bufload(bufnr)
    end
    local ft = e.ext ~= "" and (vim.filetype.match({ filename = "q." .. e.ext }) or e.ext) or "sql"
    local lines = vim.split(e.content, "\n", { plain = true })
    table.insert(lines, 1, render_comment(ft, "NOTE: This buffer is editable, but changes will not update the saved query."))
    table.insert(lines, 2, "")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].filetype   = ft
    vim.bo[bufnr].buftype    = ""
    vim.bo[bufnr].bufhidden  = "hide"
    pcall(vim.treesitter.start, bufnr)
  end

  if conn_key then require("grannos").set_buf_conn(bufnr, conn_key) end

  vim.cmd("leftabove vsplit")
  vim.api.nvim_set_current_buf(bufnr)
end

--- Resolve `conn_key` to an active connection (connecting first if needed) and, on success,
--- open the buffer for (scope_key, name). No-op when `conn_key` is nil (group-scoped picker).
--- @param scope_key   string
--- @param name        string
--- @param data_by_key table<string, table>
--- @param conn_key    string|nil
local function select_query(scope_key, name, data_by_key, conn_key)
  if not conn_key then
    open_query_buffer(scope_key, name, data_by_key, nil)
    return
  end
  require("grannos").ensure_connected(conn_key, function(key)
    open_query_buffer(scope_key, name, data_by_key, key)
  end)
end

--- Open fzf-lua (or fallback vim.ui.select) to pick from `entries_data`.
--- @param entries_data table[]  list of { scope_key, name, content, ext, path, ... }
--- @param conn_key     string|nil  associated connection for the opened buffer
local function show_picker(entries_data, conn_key)
  if #entries_data == 0 then
    vim.notify("grannos: no saved queries", vim.log.levels.INFO)
    return
  end

  local data_by_key   = {}
  local entry_strings = {}

  for _, e in ipairs(entries_data) do
    data_by_key[e.scope_key .. KEY_SEP .. e.name] = e
    table.insert(entry_strings, make_entry(e))
  end

  local preview_cmd = vim.fn.executable("bat") == 1
    and "bat --style=plain --color=always {3}"
    or  "cat {3}"

  local ok, fzf = pcall(require, "fzf-lua")
  if ok then
    fzf.fzf_exec(entry_strings, {
      prompt    = "Saved queries> ",
      previewer = false,
      fzf_opts  = {
        ["--delimiter"] = "\t",
        ["--with-nth"]  = "1",
        ["--nth"]       = "1,2",
        ["--preview"]   = preview_cmd,
        ["--header"]    = "CTRL-D: delete",
      },
      actions = {
        ["default"] = function(selected)
          if not selected or not selected[1] then return end
          local sk, name = decode_entry(selected[1])
          if not sk then return end
          vim.schedule(function() select_query(sk, name, data_by_key, conn_key) end)
        end,
        ["ctrl-d"] = function(selected)
          if not selected or not selected[1] then return end
          local sk, name = decode_entry(selected[1])
          if not sk then return end
          vim.schedule(function()
            vim.ui.select({ "No", "Yes" }, {
              prompt = ('Delete query %q?'):format(name),
            }, function(choice)
              if choice == "Yes" then
                queries.delete(sk, name)
                vim.notify(('grannos: deleted "%s"'):format(name), vim.log.levels.INFO)
              end
            end)
          end)
        end,
      },
    })
    return
  end

  -- Fallback: vim.ui.select (no preview).
  local labels = vim.tbl_map(function(e)
    return "[" .. queries.scope_label(e.scope_key) .. "] " .. e.name
  end, entries_data)

  vim.ui.select(labels, { prompt = "Saved queries:" }, function(_, idx)
    if not idx then return end
    local e = entries_data[idx]
    vim.schedule(function() select_query(e.scope_key, e.name, data_by_key, conn_key) end)
  end)
end

--- Open the picker for all queries visible to a connection (conn + group + driver).
--- @param conn_key string
function M.open(conn_key)
  show_picker(queries.list_for_conn(conn_key), conn_key)
end

--- Open the picker for a group entry: shows group-level and driver-level queries.
--- conn_key is nil here; the opened buffer won't be auto-associated.
--- @param server    string
--- @param driver_id string
--- @param group     string
function M.open_for_group(server, driver_id, group)
  local g          = group ~= "" and group or "_"
  local group_sk   = "group/"  .. server .. "/" .. driver_id .. "/" .. g
  local driver_sk  = "driver/" .. server .. "/" .. driver_id

  local seen, entries_data = {}, {}
  for _, sk in ipairs({ group_sk, driver_sk }) do
    for name, q in pairs(queries.list(sk)) do
      if not seen[name] then
        seen[name] = true
        table.insert(entries_data, { scope_key = sk, name = name, content = q.content, created_at = q.created_at, ext = q.ext, path = q.path })
      end
    end
  end
  show_picker(entries_data, nil)
end

return M
