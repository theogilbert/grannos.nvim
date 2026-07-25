-- Panel listing all saved connections, grouped by driver then group.
-- Keymaps: <CR> expand/collapse or connect, b jump to buffer, e edit, c clone, D delete,
--          n new connection, G new group, d disconnect, x explore, s session settings,
--          l load queries, L query log, K hover, ? driver help, R refresh, q close.
local M = {}

local Buffer      = require("grannos.buffer")
local connections = require("grannos.connections")
local config      = require("grannos.config")
local hl          = require("grannos.hl")
local window      = require("grannos.ui.window")
local Spinner     = require("grannos.ui.spinner")

local BUFNAME     = "grannos://connections"
local ACTIVE_MARK = " ✓"
local ERROR_MARK  = " ✗"
local ICON_DRIVER = "\xEF\x87\x80"  -- U+F1C0  nf-fa-database
local ICON_GROUP  = "\xEF\x81\xBB"  -- U+F07B  nf-fa-folder
local ICON_CONN   = "\xEF\x83\x81"  -- U+F0C1  nf-fa-link

local state = {
  buffer        = nil,
  line_map      = {},   -- [line_nr] -> entry
  expanded      = {},   -- [key]     -> bool
  conn_errors   = {},   -- [key]     -> string
  conn_loading  = {},   -- [key]     -> Spinner
  panel_loading = nil,  -- Spinner while waiting for initial capabilities
  hover_win     = nil,
}

--- Build the line/highlight/line_map arrays for a single server's data.
--- @param server      string
--- @param server_data table   the connections data for one server
--- @param active_set  table<string, boolean>  keys of currently active connections
--- @return string[], table[], table<integer, string>
local function build(server, server_data, active_set)
  local lines, line_map, hl_rules = {}, {}, {}

  --- Append a connection row at the given indent level.
  --- @param key    string   composite connection key
  --- @param indent integer  number of leading spaces (in units of 1 space each)
  local function add_conn_row(key, indent)
    local active  = active_set[key]
    local loading = state.conn_loading[key]
    local has_err = state.conn_errors[key]
    local mark    = active  and ACTIVE_MARK
                 or loading and (" " .. loading:glyph())
                 or has_err and ERROR_MARK
                 or ""
    local _, _, _, conn_name = connections.conn_parts(key)
    table.insert(lines,    string.rep(" ", indent) .. ICON_CONN .. " " .. conn_name .. mark)
    table.insert(line_map, { type = "conn", key = key })
    if active      then hl_rules[#lines] = "GrannosConnection"
    elseif has_err then hl_rules[#lines] = "GrannosConnError" end
  end

  local driver_ids = vim.tbl_keys(server_data)
  local driver_totals = {}
  for _, driver_id in ipairs(driver_ids) do
    local total = 0
    for _, gconns in pairs(server_data[driver_id].groups or {}) do total = total + vim.tbl_count(gconns) end
    driver_totals[driver_id] = total
  end
  table.sort(driver_ids, function(a, b)
    if driver_totals[a] ~= driver_totals[b] then return driver_totals[a] > driver_totals[b] end
    return (server_data[a].label or a):lower() < (server_data[b].label or b):lower()
  end)

  for _, driver_id in ipairs(driver_ids) do
    local driver_data = server_data[driver_id]
    local label  = driver_data.label or driver_id
    local groups = driver_data.groups or {}
    local total  = driver_totals[driver_id]

    local expanded = state.expanded[driver_id]
    local chevron  = expanded and "▾ " or "▸ "
    table.insert(lines,    chevron .. ICON_DRIVER .. " " .. label .. " (" .. total .. ")")
    table.insert(line_map, { type = "header", driver = driver_id })
    hl_rules[#lines] = "GrannosHeaderRow"

    if expanded then
      local group_names = vim.tbl_keys(groups)
      table.sort(group_names, function(a, b)
        if a == "" then return true end
        if b == "" then return false end
        return a < b
      end)

      for _, group_name in ipairs(group_names) do
        local conn_names = vim.tbl_keys(groups[group_name])
        table.sort(conn_names)

        if group_name == "" then
          for _, conn_name in ipairs(conn_names) do
            add_conn_row(connections.conn_key(server, driver_id, "", conn_name), 4)
          end
        else
          local skey    = driver_id .. "\1" .. group_name
          local sg_exp  = state.expanded[skey]
          local sg_chev = sg_exp and "▾ " or "▸ "
          table.insert(lines,    "  " .. sg_chev .. ICON_GROUP .. " " .. group_name .. " (" .. #conn_names .. ")")
          table.insert(line_map, { type = "subgroup", driver = driver_id, group = group_name })
          hl_rules[#lines] = "GrannosHeaderRow"
          if sg_exp then
            for _, conn_name in ipairs(conn_names) do
              add_conn_row(connections.conn_key(server, driver_id, group_name, conn_name), 6)
            end
          end
        end
      end
    end
  end

  return lines, line_map, hl_rules
end

local FOOTER = "Press g? in any pane for help"

--- Append blank padding and the help footer to `lines` so it fills the panel height.
--- @param lines string[]
local function append_footer(lines)
  local win        = state.buffer and vim.fn.bufwinid(state.buffer.buf_id) or -1
  local win_height = win ~= -1 and vim.api.nvim_win_get_height(win) or 0
  local padding    = math.max(0, win_height - #lines - 2)
  for _ = 1, padding do table.insert(lines, "") end
  table.insert(lines, "")
  table.insert(lines, FOOTER)
end

--- Rebuild and redisplay the connections panel buffer.
local function refresh()
  if state.panel_loading then return end

  local db   = require("grannos")
  local caps = require("grannos.client").capabilities()
  local server = caps and (caps.server or "") or ""

  local active_set = {}
  for _, k in ipairs(db.active_keys()) do active_set[k] = true end

  local server_data = connections.load(server)
  local lines, line_map, hl_rules = build(server, server_data, active_set)
  state.line_map = line_map

  if #lines == 0 then lines = { "(no saved connections)" } end
  append_footer(lines)
  state.buffer:set_content(lines)

  local rules = {}
  for lnum, group in pairs(hl_rules) do
    table.insert(rules, { higroup = group, start = { lnum - 1, 0 }, finish = { lnum - 1, -1 } })
  end
  table.insert(rules, { higroup = "GrannosHelp", start = { #lines - 1, 0 }, finish = { #lines - 1, -1 } })
  state.buffer:apply_highlight(rules)
end

--- Return the line_map entry for the line the cursor is currently on, or nil.
--- @return table|nil
local function entry_at_cursor()
  return state.line_map[vim.api.nvim_win_get_cursor(0)[1]]
end

--- <CR> handler: expand/collapse driver/group rows, or connect for connection rows.
local function on_enter()
  local entry = entry_at_cursor()
  if not entry then return end
  if entry.type == "header" then
    state.expanded[entry.driver] = not state.expanded[entry.driver]
    refresh()
  elseif entry.type == "subgroup" then
    local skey = entry.driver .. "\1" .. entry.group
    state.expanded[skey] = not state.expanded[skey]
    refresh()
  else
    state.conn_errors[entry.key] = nil
    require("grannos").attach(entry.key)
  end
end

--- D key handler: delete the connection or group under the cursor.
local function on_delete()
  local entry = entry_at_cursor()
  if not entry then return end
  if entry.type == "conn" then
    vim.ui.select({ "No", "Yes" }, {
      prompt = ('Delete connection %q?'):format(connections.conn_display_name(entry.key)),
    }, function(choice)
      if choice ~= "Yes" then return end
      connections.delete(entry.key)
      refresh()
    end)
  elseif entry.type == "subgroup" then
    local caps   = require("grannos.client").capabilities()
    local server = caps and (caps.server or "") or ""
    local label  = entry.group ~= "" and entry.group or "(no group)"
    local count  = vim.tbl_count(
      (((connections.load(server)[entry.driver] or {}).groups or {})[entry.group] or {})
    )
    vim.ui.select({ "No", "Yes" }, {
      prompt = ('Delete group %q and its %d connection(s)?'):format(label, count),
    }, function(choice)
      if choice ~= "Yes" then return end
      connections.delete_group(server, entry.driver, entry.group)
      refresh()
    end)
  end
end

--- d key handler: disconnect the connection under the cursor.
local function on_disconnect()
  local entry = entry_at_cursor()
  if not entry or entry.type ~= "conn" then return end
  require("grannos").disconnect(entry.key)
end

--- e key handler: open the edit wizard for the connection under the cursor.
local function on_edit()
  local entry = entry_at_cursor()
  if not entry or entry.type ~= "conn" then return end
  local db = require("grannos")
  db.ensure_backend_with_caps(function(caps)
    connections.edit(entry.key, caps, function(new_key, _)
      if not new_key then return end
      refresh()
    end)
  end)
end

--- c key handler: clone the connection under the cursor.
local function on_clone()
  local entry = entry_at_cursor()
  if not entry or entry.type ~= "conn" then return end
  local _, _, _, bare_name = connections.conn_parts(entry.key)
  vim.ui.input({ prompt = "Clone as: ", default = (bare_name ~= "" and bare_name or connections.conn_display_name(entry.key)) .. "-copy" }, function(new_name)
    if not new_name or new_name == "" then return end
    local db = require("grannos")
    db.ensure_backend_with_caps(function(caps)
      connections.clone(entry.key, new_name, caps, function(new_key, _)
        if not new_key then return end
        refresh()
      end)
    end)
  end)
end

--- n key handler: open the new-connection wizard.
local function on_new()
  local db = require("grannos")
  db.ensure_backend_with_caps(function(caps)
    connections.create(caps, function(key, params)
      if not key then return end
      db._do_connect(key, params)
      refresh()
    end)
  end)
end

--- G key handler: create a new named group for a driver.
local function on_new_group()
  local db = require("grannos")
  db.ensure_backend_with_caps(function(caps)
    local server = caps.server or ""
    vim.ui.input({ prompt = "Group name: " }, function(name)
      if not name or name == "" then return end
      vim.schedule(function()
        vim.ui.select(caps.drivers, {
          prompt      = "Driver:",
          format_item = function(d) return d.label or d.driver end,
        }, function(d)
          if not d then return end
          local ok = connections.create_group(server, d.driver, d.label or d.driver, name)
          if ok then refresh() end
        end)
      end)
    end)
  end)
end

--- x key handler: open the schema explorer for the connection under the cursor.
local function on_explore()
  local entry = entry_at_cursor()
  if not entry or entry.type ~= "conn" then return end
  require("grannos").open_explorer_for(entry.key)
end

--- s key handler: open the session settings form for the connection under the cursor.
local function on_session_settings()
  local entry = entry_at_cursor()
  if not entry or entry.type ~= "conn" then return end
  require("grannos").open_session_settings_for(entry.key)
end

--- b key handler: jump to a buffer associated with the connection under the cursor.
local function on_jump()
  local entry = entry_at_cursor()
  if not entry or entry.type ~= "conn" then return end
  local db   = require("grannos")
  local bufs = db.buffers_for(entry.key)
  if #bufs == 0 then
    vim.notify("grannos: no buffers associated with " .. connections.conn_display_name(entry.key), vim.log.levels.WARN)
    return
  end
  local panel_win = vim.fn.bufwinid(state.buffer.buf_id)

  --- Switch to `bufnr` in a non-panel window, or open one if needed.
  --- @param bufnr integer
  local function jump_to(bufnr)
    for _, w in ipairs(vim.fn.win_findbuf(bufnr)) do
      if w ~= panel_win then vim.api.nvim_set_current_win(w) return end
    end
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if w ~= panel_win and vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "" then
        vim.api.nvim_set_current_win(w)
        vim.api.nvim_set_current_buf(bufnr)
        return
      end
    end
    vim.cmd("leftabove vsplit")
    vim.api.nvim_set_current_buf(bufnr)
  end
  if #bufs == 1 then
    jump_to(bufs[1])
  else
    local names = vim.tbl_map(function(b)
      local n = vim.api.nvim_buf_get_name(b)
      return n ~= "" and n or ("[No Name] #" .. b)
    end, bufs)
    vim.ui.select(names, { prompt = "Open buffer:" }, function(_, idx)
      if idx then jump_to(bufs[idx]) end
    end)
  end
end

--- ? key handler: open driver help for the item under the cursor.
local function on_help()
  local entry = entry_at_cursor()
  if not entry then return end
  local driver
  if entry.type == "header" or entry.type == "subgroup" then
    driver = entry.driver
  else
    local _, drv = connections.conn_parts(entry.key)
    driver = drv
  end
  if not driver or driver == "" then return end
  require("grannos").open_driver_help(driver)
end

local HIDDEN_CONN_FIELDS = { password = true, requires_password = true }

--- Open a non-focusable float displaying `lines` near the cursor.
--- Closes automatically on `CursorMoved` or `BufLeave`.
--- @param lines     string[]
--- @param title     string
--- @param border_hl string|nil  FloatBorder highlight group
--- @param line_hl   string|nil  highlight group applied to every line
local function open_hover_float(lines, title, border_hl, line_hl)
  local max_w = 1
  for _, l in ipairs(lines) do max_w = math.max(max_w, vim.fn.strdisplaywidth(l)) end
  local win_w = math.min(max_w, vim.o.columns - 6)

  local height = 0
  for _, l in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(l)
    height = height + (w == 0 and 1 or math.ceil(w / win_w))
  end

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.bo[fbuf].modifiable = false
  vim.bo[fbuf].bufhidden  = "wipe"
  if line_hl then
    for i = 0, #lines - 1 do
      vim.api.nvim_buf_add_highlight(fbuf, -1, line_hl, i, 0, -1)
    end
  end

  local fwin = vim.api.nvim_open_win(fbuf, false, {
    relative  = "cursor",
    row       = 1,
    col       = 0,
    width     = win_w,
    height    = height,
    style     = "minimal",
    border    = "rounded",
    title     = " " .. title .. " ",
    title_pos = "center",
    focusable = false,
  })
  if border_hl then
    vim.api.nvim_set_option_value("winhl", "FloatBorder:" .. border_hl, { win = fwin })
  end
  vim.api.nvim_set_option_value("wrap", true, { win = fwin })

  state.hover_win = fwin
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave" }, {
    group    = vim.api.nvim_create_augroup("GrannosHoverFloat", { clear = true }),
    buffer   = state.buffer.buf_id,
    once     = true,
    callback = function()
      pcall(vim.api.nvim_win_close, state.hover_win, true)
      state.hover_win = nil
    end,
  })
end

--- K key handler: show connection details or error in a hover float.
--- A second press makes the float focusable (so the user can scroll it).
local function on_hover()
  local entry = entry_at_cursor()
  if not entry or entry.type ~= "conn" then return end

  if state.hover_win and vim.api.nvim_win_is_valid(state.hover_win) then
    pcall(vim.api.nvim_del_augroup_by_name, "GrannosHoverFloat")
    local fwin = state.hover_win
    local fbuf = vim.api.nvim_win_get_buf(fwin)
    local prev = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_config(fwin, { focusable = true })
    vim.api.nvim_set_current_win(fwin)
    for _, k in ipairs({ "q", "<Esc>" }) do
      vim.keymap.set("n", k, function()
        pcall(vim.api.nvim_win_close, fwin, true)
        state.hover_win = nil
        if vim.api.nvim_win_is_valid(prev) then vim.api.nvim_set_current_win(prev) end
      end, { buffer = fbuf, silent = true, nowait = true })
    end
    return
  end

  local err_msg = state.conn_errors[entry.key]
  if err_msg then
    open_hover_float(vim.split(err_msg, "\n", { plain = true }),
      "error", "GrannosConnError", "GrannosConnError")
    return
  end

  local params = connections.get(entry.key)
  if not params then return end

  local _, driver = connections.conn_parts(entry.key)
  local labels = {}
  local caps = require("grannos.client").capabilities()
  if caps then
    for _, d in ipairs(caps.drivers or {}) do
      if d.driver == driver then
        for _, p in ipairs(d.params or {}) do
          if p.key and p.label then labels[p.key] = p.label end
        end
        break
      end
    end
  end

  local keys = {}
  for k in pairs(params) do
    if not HIDDEN_CONN_FIELDS[k] then table.insert(keys, k) end
  end
  table.sort(keys)

  local label_w = 0
  for _, k in ipairs(keys) do label_w = math.max(label_w, #(labels[k] or k)) end

  local lines = {}
  for _, k in ipairs(keys) do
    local label = labels[k] or k
    table.insert(lines, label .. string.rep(" ", label_w - #label) .. "  " .. tostring(params[k]))
  end

  open_hover_float(lines, connections.conn_display_name(entry.key), nil, nil)
end


--- l key handler: open the saved-query picker for the item under the cursor.
local function on_load_query()
  local entry = entry_at_cursor()
  if not entry then return end
  if entry.type == "conn" then
    require("grannos").load_query(entry.key)
  elseif entry.type == "subgroup" then
    local caps   = require("grannos.client").capabilities()
    local server = caps and (caps.server or "") or ""
    require("grannos.ui.query_picker").open_for_group(server, entry.driver, entry.group)
  end
end

--- L key handler: open the query log for the connection under the cursor.
local function on_query_log()
  local entry = entry_at_cursor()
  if not entry or entry.type ~= "conn" then return end
  require("grannos").query_log(entry.key)
end

--- Open (or close) the connections panel.
function M.open()
  connections.invalidate()
  local db = require("grannos")
  db.ensure_backend_with_caps(function()
    if state.panel_loading then
      state.panel_loading:reset()
      state.panel_loading = nil
    end
    for _, key in ipairs(db.active_keys()) do
      local _, driver, group = connections.conn_parts(key)
      if driver ~= "" then
        state.expanded[driver] = true
        if group ~= "" then
          state.expanded[driver .. "\1" .. group] = true
        end
      end
    end
    M.refresh()
  end)

  local needs_loading = not require("grannos.client").capabilities()

  if not (state.buffer and state.buffer:is_valid()) then
    state.buffer = Buffer:new(BUFNAME, "grannos_connections", false, "nofile")
    vim.api.nvim_create_autocmd("WinResized", { callback = function() M.refresh() end })
    local hover_key = config.options.keymaps.hover_key
    state.buffer:set_keymap("n", "<CR>",    on_enter,      { nowait = true, silent = true, desc = "Expand/collapse or connect", group = "Navigate" })
    state.buffer:set_keymap("n", "b",       on_jump,       { nowait = true, silent = true, desc = "Jump to associated buffer",  group = "Navigate" })
    state.buffer:set_keymap("n", "q", function()
      local win = vim.fn.bufwinid(state.buffer.buf_id)
      if win ~= -1 then vim.api.nvim_win_close(win, true) end
    end, { nowait = true, silent = true, desc = "Close panel", group = "Navigate" })
    state.buffer:set_keymap("n", "n",       on_new,        { nowait = true, silent = true, desc = "New connection",            group = "Manage" })
    state.buffer:set_keymap("n", "G",       on_new_group,  { nowait = true, silent = true, desc = "New group",                 group = "Manage" })
    state.buffer:set_keymap("n", "e",       on_edit,       { nowait = true, silent = true, desc = "Edit",                      group = "Manage" })
    state.buffer:set_keymap("n", "c",       on_clone,      { nowait = true, silent = true, desc = "Clone",                     group = "Manage" })
    state.buffer:set_keymap("n", "D",       on_delete,     { nowait = true, silent = true, desc = "Delete",                    group = "Manage" })
    state.buffer:set_keymap("n", "d",       on_disconnect,  { nowait = true, silent = true, desc = "Disconnect",                group = "Session" })
    state.buffer:set_keymap("n", "x",       on_explore,     { nowait = true, silent = true, desc = "Open explorer",             group = "Session" })
    state.buffer:set_keymap("n", "s",       on_session_settings, { nowait = true, silent = true, desc = "Session settings",     group = "Session" })
    state.buffer:set_keymap("n", "l",       on_load_query,  { nowait = true, silent = true, desc = "Load saved queries",        group = "Session" })
    state.buffer:set_keymap("n", "L",       on_query_log,   { nowait = true, silent = true, desc = "Query log",                 group = "Session" })
    state.buffer:set_keymap("n", hover_key, on_hover,      { nowait = true, silent = true, desc = "Hover details / error",     group = "Info" })
    state.buffer:set_keymap("n", "?",       on_help,       { nowait = true, silent = true, desc = "Driver help",               group = "Info" })
    state.buffer:set_keymap("n", "R",       refresh,       { nowait = true, silent = true, desc = "Refresh",                   group = "Info" })
  end

  local win = vim.fn.bufwinid(state.buffer.buf_id)
  if win ~= -1 then vim.api.nvim_win_close(win, true) return end

  local new_win = window.open_sidebar(state.buffer.buf_id, "right")
  vim.api.nvim_win_set_hl_ns(new_win, hl.NS_ID)

  if needs_loading then
    state.panel_loading = Spinner.new(function()
      if state.buffer and state.buffer:is_valid() and state.panel_loading then
        state.buffer:set_content({ state.panel_loading:glyph() .. " Loading connections…" })
      end
    end)
    state.buffer:set_content({ Spinner.FRAMES[1] .. " Loading connections…" })
    state.panel_loading:start()
  else
    refresh()
  end
end

--- Refresh the panel if it is currently visible.
function M.refresh()
  if state.buffer and state.buffer:is_valid() then refresh() end
end

--- Record a connection error and redisplay.
--- @param name string  composite connection key
--- @param msg  string|nil
function M.set_conn_error(name, msg)
  state.conn_errors[name] = msg or "unknown error"
  M.refresh()
end

--- Stop and remove the loading spinner for a connection.
--- @param name string  composite connection key
function M.clear_conn_loading(name)
  local spinner = state.conn_loading[name]
  if not spinner then return end
  state.conn_loading[name] = nil
  spinner:reset()
end

--- Start an animated loading indicator for a connection row.
--- @param name string  composite connection key
function M.set_conn_loading(name)
  M.clear_conn_loading(name)
  local spinner = Spinner.new(function() M.refresh() end)
  state.conn_loading[name] = spinner
  spinner:start()
end

return M
