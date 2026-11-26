local M = {}

local queries     = require("grannos.queries")
local connections = require("grannos.connections")
local notify = require("grannos.notify")

local PROMPT     = "Name> "
local PROMPT_LEN = #PROMPT

-- Open a two-float widget that looks like one window:
--
--   ╭────────────── Save query ──────────────╮
--   │ (editable name input)                  │
--   ├──────────────── Preview ───────────────┤   ← shared border row
--   │ SELECT * FROM users                    │
--   ╰────────────────────────────────────────╯
--
-- The input window's bottom border (├─┤) and the preview window's top border
-- (├─┤) are drawn on the same screen row; the preview's zindex = 51 wins, so
-- its " Preview " title appears on the divider.
--
-- on_confirm(name) is called on <CR> with a non-empty name.
-- on_cancel() is called on <Esc> / <C-c> / empty <CR>.
--- @param content    string
--- @param filetype   string
--- @param hint       string|nil  pre-filled name text after the prompt
--- @param on_confirm fun(name: string)
--- @param on_cancel  fun()
local function prompt_name(content, filetype, hint, on_confirm, on_cancel)
  local preview_lines = vim.split(content, "\n", { plain = true })
  local width  = math.min(math.floor(vim.o.columns * 0.7), 90)
  local ph     = math.min(math.max(#preview_lines, 1), math.floor(vim.o.lines * 0.35))
  -- Total screen rows consumed: top-border(1) + input(1) + shared-border(1) + preview(ph) + bottom-border(1) = ph+4
  local row    = math.max(0, math.floor((vim.o.lines - (ph + 4)) / 2))
  local col    = math.max(0, math.floor((vim.o.columns - width - 2) / 2))

  -- ── Input window ───────────────────────────────────────────────────────────
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { PROMPT .. (hint or "") })

  -- Keep the cursor on or after the prompt prefix at all times.
  local aug = vim.api.nvim_create_augroup("GrannosNameInput", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer   = input_buf,
    group    = aug,
    callback = function()
      if vim.api.nvim_win_get_cursor(0)[2] < PROMPT_LEN then
        vim.api.nvim_win_set_cursor(0, { 1, PROMPT_LEN })
      end
    end,
  })

  -- Block <BS> when it would eat into the prompt.
  vim.keymap.set("i", "<BS>", function()
    if vim.api.nvim_win_get_cursor(0)[2] <= PROMPT_LEN then return end
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<BS>", true, false, true), "n", false)
  end, { buffer = input_buf, nowait = true })

  -- Block <C-u> from clearing the prompt; only erase user text.
  vim.keymap.set("i", "<C-u>", function()
    local col  = vim.api.nvim_win_get_cursor(0)[2]
    if col <= PROMPT_LEN then return end
    local line = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1]
    vim.api.nvim_buf_set_lines(input_buf, 0, 1, false, { line:sub(1, PROMPT_LEN) })
    vim.api.nvim_win_set_cursor(0, { 1, PROMPT_LEN })
  end, { buffer = input_buf, nowait = true })

  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative  = "editor",
    width     = width,
    height    = 1,
    row       = row,
    col       = col,
    style     = "minimal",
    -- bottom border uses ├─┤ instead of ╰─╯ so it matches the preview's top
    border    = { "╭", "─", "╮", "│", "┤", "─", "├", "│" },
    title     = " Save query ",
    title_pos = "center",
  })

  -- ── Preview window ─────────────────────────────────────────────────────────
  local preview_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, preview_lines)
  vim.bo[preview_buf].modifiable = false
  local ft = filetype ~= "" and (vim.filetype.match({ filename = "q." .. filetype }) or filetype) or "sql"
  vim.bo[preview_buf].filetype   = ft
  vim.bo[preview_buf].bufhidden  = "wipe"
  pcall(vim.treesitter.start, preview_buf)

  -- row + 2 = the same screen row as the input window's bottom border.
  -- zindex 51 > input's default 50, so preview's top border renders on top,
  -- showing the " Preview " title on the shared divider line.
  vim.api.nvim_open_win(preview_buf, false, {
    relative  = "editor",
    width     = width,
    height    = ph,
    row       = row + 2,
    col       = col,
    style     = "minimal",
    border    = { "├", "─", "┤", "│", "╯", "─", "╰", "│" },
    title     = " Preview ",
    title_pos = "center",
    zindex    = 51,
  })

  -- ── Keymaps and lifecycle ───────────────────────────────────────────────────
  --- Close both floats and stop insert mode.
  local function close()
    pcall(vim.api.nvim_del_augroup_by_id, aug)
    vim.cmd("stopinsert")
    -- Close both floats; bufhidden=wipe cleans up the buffers automatically.
    for _, w in ipairs(vim.fn.win_findbuf(input_buf)) do
      if vim.api.nvim_win_is_valid(w) then vim.api.nvim_win_close(w, true) end
    end
    for _, w in ipairs(vim.fn.win_findbuf(preview_buf)) do
      if vim.api.nvim_win_is_valid(w) then vim.api.nvim_win_close(w, true) end
    end
  end

  --- Read the name from the input buffer and call on_confirm or on_cancel.
  local function confirm()
    local line = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
    local name = vim.trim(line:sub(PROMPT_LEN + 1))
    close()
    if name ~= "" then on_confirm(name) else on_cancel() end
  end

  --- Close and call on_cancel.
  local function cancel()
    close()
    on_cancel()
  end

  vim.keymap.set({ "i", "n" }, "<CR>",  confirm, { buffer = input_buf, nowait = true })
  vim.keymap.set({ "i", "n" }, "<Esc>", cancel,  { buffer = input_buf, nowait = true })
  vim.keymap.set({ "i", "n" }, "<C-c>", cancel,  { buffer = input_buf, nowait = true })

  vim.schedule(function()
    vim.cmd("startinsert!")  -- cursor after last char (after hint, or after "Name> ")
  end)
end

-- ── Scope pickers ─────────────────────────────────────────────────────────────

--- Ask the user to pick a save scope for a known connection.
--- @param conn_key string
--- @param callback fun(scope_key: string|nil)
local function pick_scope_for_conn(conn_key, callback)
  local _, driver, group, name = connections.conn_parts(conn_key)
  local group_label = group ~= "" and group or "[no group]"
  local options = {
    { level = "driver",     label = "Driver (" .. driver .. ")" },
    { level = "group",      label = "Group (" .. group_label .. ")" },
    { level = "connection", label = "Connection (" .. name .. ")" },
  }
  vim.ui.select(options, {
    prompt      = "Save scope:",
    format_item = function(o) return o.label end,
  }, function(chosen)
    if not chosen then callback(nil) return end
    callback(queries.scope_key(chosen.level, conn_key))
  end)
end

--- Return a flat list of all connection entries across all configured servers.
--- @return table[]
local function all_conn_entries()
  local entries = {}
  for server, server_data in pairs(connections.load_all()) do
    for driver, driver_data in pairs(server_data) do
      local dlabel = driver_data.label or driver
      for group, group_conns in pairs(driver_data.groups or {}) do
        for conn_name in pairs(group_conns) do
          table.insert(entries, { server = server, driver = driver, driver_label = dlabel, group = group, name = conn_name })
        end
      end
    end
  end
  return entries
end

--- Ask the user to pick a save scope when there is no active connection.
--- Prompts scope type → driver → (group or connection), then calls callback.
--- @param callback fun(scope_key: string|nil)
local function pick_scope_no_conn(callback)
  vim.ui.select({ "Driver", "Group", "Connection" }, { prompt = "Save at scope:" }, function(scope_type)
    if not scope_type then callback(nil) return end
    local level   = scope_type:lower()
    local entries = all_conn_entries()

    local driver_map = {}
    for _, e in ipairs(entries) do driver_map[e.server .. "/" .. e.driver] = e end
    local drivers = vim.tbl_values(driver_map)
    table.sort(drivers, function(a, b) return a.driver_label < b.driver_label end)

    if #drivers == 0 then
      notify.warn("no connections configured")
      callback(nil)
      return
    end

    vim.schedule(function()
      vim.ui.select(drivers, {
        prompt      = "Driver:",
        format_item = function(d) return d.driver_label end,
      }, function(d)
        if not d then callback(nil) return end
        if level == "driver" then
          callback("driver/" .. d.server .. "/" .. d.driver)
          return
        end

        if level == "connection" then
          -- Flat list of all connections for this driver; group shown in label.
          local conn_items = {}
          for _, e in ipairs(entries) do
            if e.server == d.server and e.driver == d.driver then
              table.insert(conn_items, e)
            end
          end
          table.sort(conn_items, function(a, b)
            local la = a.group ~= "" and (a.group .. "/" .. a.name) or a.name
            local lb = b.group ~= "" and (b.group .. "/" .. b.name) or b.name
            return la < lb
          end)
          vim.schedule(function()
            vim.ui.select(conn_items, {
              prompt      = "Connection:",
              format_item = function(e)
                return e.group ~= "" and (e.group .. "/" .. e.name) or e.name
              end,
            }, function(conn)
              if not conn then callback(nil) return end
              local g = conn.group ~= "" and conn.group or "_"
              callback("connection/" .. conn.server .. "/" .. conn.driver .. "/" .. g .. "/" .. conn.name)
            end)
          end)
          return
        end

        -- level == "group": pick a group
        local group_set = {}
        for _, e in ipairs(entries) do
          if e.server == d.server and e.driver == d.driver then group_set[e.group] = true end
        end
        local group_items = {}
        for g in pairs(group_set) do
          table.insert(group_items, { label = g ~= "" and g or "[no group]", value = g })
        end
        table.sort(group_items, function(a, b) return a.label < b.label end)

        vim.schedule(function()
          vim.ui.select(group_items, {
            prompt      = "Group:",
            format_item = function(g) return g.label end,
          }, function(grp)
            if not grp then callback(nil) return end
            local g = grp.value ~= "" and grp.value or "_"
            callback("group/" .. d.server .. "/" .. d.driver .. "/" .. g)
          end)
        end)
      end)
    end)
  end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Open the save-query wizard.
--- Prompts for a name and scope, then persists the query via `queries.save`.
--- @param content  string       query text to save
--- @param conn_key string|nil   active connection key (used to seed the scope picker)
--- @param ext      string|nil   file extension hint (e.g. "sql", "cypher")
function M.open(content, conn_key, ext)
  ext = ext or ""

  --- Delegate to conn or no-conn scope picker.
  --- @param callback fun(scope_key: string|nil)
  local function pick_scope(callback)
    if conn_key then pick_scope_for_conn(conn_key, callback)
    else             pick_scope_no_conn(callback)
    end
  end

  -- Called when a duplicate is detected: re-opens the name float (scope already known).
  --- @param scope_key string
  --- @param name_hint string
  local function do_save(scope_key, name_hint)
    prompt_name(content, ext, name_hint, function(name)
      local ok = queries.save(scope_key, name, content, ext)
      if not ok then
        notify.warn(("%q already exists in this scope — choose a different name"):format(name))
        vim.schedule(function() do_save(scope_key, name) end)
        return
      end
      notify.info(('saved "%s" (%s)'):format(name, queries.scope_label(scope_key)))
    end, function() end)
  end

  prompt_name(content, ext, nil, function(name)
    vim.schedule(function()
      pick_scope(function(scope_key)
        if not scope_key then return end
        vim.schedule(function()
          local ok = queries.save(scope_key, name, content, ext)
          if not ok then
            notify.warn(("%q already exists in this scope — choose a different name"):format(name))
            vim.schedule(function() do_save(scope_key, name) end)
            return
          end
          notify.info(('saved "%s" (%s)'):format(name, queries.scope_label(scope_key)))
        end)
      end)
    end)
  end, function() end)
end

return M
