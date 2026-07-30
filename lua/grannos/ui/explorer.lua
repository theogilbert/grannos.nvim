-- Tree-style DB explorer in a sidebar buffer.
-- Navigation: <CR> expands/collapses nodes; hover_key (default K) describes the item under cursor.
local M = {}

local Buffer         = require("grannos.buffer")
local client         = require("grannos.client")
local config         = require("grannos.config")
local content_buffer = require("grannos.ui.content_buffer")
local hl             = require("grannos.hl")
local pane           = require("grannos.ui.detail_pane")
local results        = require("grannos.ui.results")
local window         = require("grannos.ui.window")
local Spinner        = require("grannos.ui.spinner")

local BUFNAME = "grannos://explorer"

--- Group-path explore.describe results (e.g. an entity's indexes) come back
--- as a bare JSON array rather than a wrapper object.
--- @param v any
--- @return boolean
local function is_array(v)
  if type(v) ~= "table" then return false end
  if vim.islist then return vim.islist(v) end
  return vim.tbl_islist(v)
end

local EXPLORER_NS = vim.api.nvim_create_namespace("GrannosExplorer")

local EXPLORER_HL = {
  database       = "GrannosExplorerDatabase",
  schema         = "GrannosExplorerSchema",
  table          = "GrannosExplorerTable",
  ["base table"] = "GrannosExplorerTable",
  view           = "GrannosExplorerView",
  collection     = "GrannosExplorerCollection",
  index          = "GrannosExplorerIndex",
  constraint     = "GrannosExplorerConstraint",
  group          = "GrannosExplorerGroup",
  document       = "GrannosExplorerDocument",
  bucket         = "GrannosExplorerDatabase",
  prefix         = "GrannosExplorerSchema",
  object         = "GrannosExplorerDocument",
  gridfs_bucket  = "GrannosExplorerCollection",
}

local TYPE_ICONS = {
  database       = "󰆼 ",
  schema         = "󱁳 ",
  table          = "󰓫 ",
  ["base table"] = "󰓫 ",
  view           = "󰈈 ",
  collection     = "󱃗 ",
  index          = "󰒻 ",
  constraint     = "󰌾 ",
  document       = "󰈙 ",
  bucket         = "󰆼 ",
  prefix         = "󱁳 ",
  object         = "󰈙 ",
  gridfs_bucket  = "󱃗 ",
}
local GROUP_ICON = { closed = " ", open = " " }
local FIELD_ICON = "󰠵 "

--- Return the icon glyph for `node`, based on its type and expansion state.
--- @param node ExplorerNode
--- @return string
local function node_icon(node)
  if node.type == "group" then
    return node.expanded and GROUP_ICON.open or GROUP_ICON.closed
  end
  return TYPE_ICONS[node.type] or FIELD_ICON
end

local state = {
  buffer           = nil,
  tree             = {},
  conn_id          = nil,
  conn_label       = nil,  -- "name (driver)" shown in the buffer name
  conn_key         = nil,  -- storage key for results panel header
  conn_driver_label = nil,
  root_loading     = false,
}


local render  -- forward declaration so the spinner callback can reference it

local spinner = Spinner.new(function() render() end)

--- Redraw the explorer buffer from state.tree.
render = function()
  local buf = state.buffer.buf_id
  if state.root_loading then
    state.buffer:set_content({ "  " .. spinner:glyph() .. " Loading…" })
    vim.api.nvim_buf_clear_namespace(buf, EXPLORER_NS, 0, -1)
    return
  end

  local lines = {}
  local hls   = {}

  --- Accumulate a highlight rule for a single buffer row.
  --- @param row   integer  0-indexed
  --- @param col_s integer  byte start column
  --- @param col_e integer  byte end column
  --- @param group string   highlight group name
  local function add_hl(row, col_s, col_e, group)
    hls[#hls + 1] = { row, col_s, col_e, group }
  end

  --- Recursively append nodes at `indent` depth to `lines`/`hls`.
  --- @param nodes  table[]
  --- @param indent integer
  local function walk(nodes, indent)
    for _, node in ipairs(nodes) do
      local indent_s  = string.rep("  ", indent)
      local chevron_s = node.expandable
          and (node.expanded and "▾ " or "▸ ") or "  "
      local icon_s    = node_icon(node)
      local label     = ""
      if not node.expandable and not TYPE_ICONS[node.type] and node.type ~= "group" then
        label = "  " .. node.type
      end

      local row = #lines  -- 0-based
      local desc_s = node.describing and (" " .. spinner:glyph()) or ""
      lines[#lines + 1] = indent_s .. chevron_s .. icon_s .. node.name .. label .. desc_s

      -- Byte column boundaries (Lua # gives byte length).
      local c0 = #indent_s
      local c1 = c0 + #chevron_s
      local c2 = c1 + #icon_s
      local c3 = c2 + #node.name

      if node.expandable then
        add_hl(row, c0, c1, "GrannosExplorerDim")
      end
      local type_hl = EXPLORER_HL[node.type]
      if type_hl then
        add_hl(row, c1, c3, type_hl)
      end
      if label ~= "" then
        -- skip the two-space separator before the type string
        add_hl(row, c3 + 2, c3 + 2 + #node.type, "GrannosExplorerDim")
      end

      if node.loading then
        lines[#lines + 1] = string.rep("  ", indent + 1) .. "  " .. spinner:glyph() .. " Loading…"
      elseif node.expanded and node.children then
        walk(node.children, indent + 1)
      end
    end
  end

  walk(state.tree, 0)
  state.buffer:set_content(lines)
  vim.api.nvim_buf_clear_namespace(buf, EXPLORER_NS, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(buf, EXPLORER_NS, h[4], h[1], h[2], h[3])
  end
end

--- @class ServerItem
--- @field name       string
--- @field type       string
--- @field expandable boolean

--- Construct a tree node from a server item and its absolute path.
--- @param item ServerItem
--- @param path string[]  absolute path from the root
--- @return ExplorerNode
local function make_node(item, path)
  return {
    name       = item.name,
    type       = item.type,
    path       = path,
    expandable = item.expandable,
    expanded   = false,
    children   = nil,
  }
end

--- Walk state.tree and return the node at `path`, or nil when not found.
--- @param path string[]
--- @return table|nil
local function node_at_path(path)
  local nodes = state.tree
  local node
  for _, name in ipairs(path) do
    node = nil
    for _, n in ipairs(nodes) do
      if n.name == name then
        node = n
        nodes = n.children or {}
        break
      end
    end
    if not node then return nil end
  end
  return node
end

--- Return the node that occupies 1-indexed `line` in the current rendering, or nil.
--- @param line integer  1-indexed
--- @return table|nil
local function node_at_line(line)
  local idx = 0
  local function walk(nodes)
    for _, node in ipairs(nodes) do
      idx = idx + 1
      if idx == line then return node end
      if node.expanded and node.children then
        local found = walk(node.children)
        if found then return found end
      end
    end
  end
  return walk(state.tree)
end

--- Send an explore.list request for `node`, populate its children, and re-render.
--- `reset_cache` = true instructs the server to discard its cache.
--- @param node        ExplorerNode
--- @param reset_cache boolean|nil
local function load_children(node, reset_cache)
  node.loading = true
  spinner:start()
  render()
  local params = { connection_id = state.conn_id, path = node.path }
  if reset_cache then params.reset_cache = true end
  client.request("explore.list", params, function(err, result)
    node.loading = false
    spinner:stop()
    if err then
      vim.schedule(function()
        vim.notify("grannos explorer: " .. err, vim.log.levels.ERROR)
        render()
      end)
      return
    end
    node.children = {}
    for _, item in ipairs(result.items or {}) do
      local child_path = vim.list_extend(vim.list_slice(node.path), { item.name })
      node.children[#node.children + 1] = make_node(item, child_path)
    end
    node.expanded = true
    vim.schedule(render)
  end)
end

--- Handle <CR>: toggle expansion of the node under the cursor.
local function on_enter()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local node = node_at_line(line)
  if not node or not node.expandable then return end
  if node.expanded then
    node.expanded = false
    render()
  else
    load_children(node)
  end
end

--- @class ExplorerNode
--- @field name        string
--- @field type        string
--- @field path        string[]
--- @field expandable  boolean
--- @field expanded    boolean
--- @field children    ExplorerNode[]|nil
--- @field loading     boolean|nil
--- @field describing  boolean|nil

--- @class TableColumn
--- @field name            string
--- @field type            string
--- @field nullable        boolean|nil
--- @field pk              boolean|nil
--- @field default         any
--- @field exclusive_index boolean|nil
--- @field composite_index boolean|nil

--- @class TableReference
--- @field column     string       local column participating in the relationship
--- @field table      string       name of the other table
--- @field ref_column string       column on the other table
--- @field schema     string|nil   schema of the other table, or nil for databases without schema support

--- @class TableDetails
--- @field table                string|nil
--- @field schema               string|nil
--- @field columns              TableColumn[]|nil
--- @field comment              string|nil
--- @field outgoing_references  TableReference[]|nil  foreign keys on this table referencing other tables
--- @field incoming_references  TableReference[]|nil  foreign keys on other tables referencing this table

--- @class HlRule
--- @field [1] string   highlight group name
--- @field [2] integer  0-indexed row
--- @field [3] integer  byte start column
--- @field [4] integer  byte end column (-1 for end of line)

local render_describe, calculate_win_size, present_describe_float  -- forward declarations

--- Open a floating window showing the describe details returned by the server for a node.
--- @param details TableDetails|nil
--- @param node    ExplorerNode
--- @param conn_id any|nil        connection to refetch from; with `path`, enables "r" to refresh
--- @param path    string[]|nil   leaf path `details` was described at
local function open_describe_float(details, node, conn_id, path)
  if not details or details == vim.NIL then
    vim.notify("grannos: nothing to describe for this node", vim.log.levels.WARN)
    return
  end
  local handle = present_describe_float(render_describe(details, node))

  if conn_id and path then
    local refreshing = false
    local base_title = " " .. handle.title .. " "
    --- Re-describe `path` with the server cache discarded, and redraw in place.
    local function refresh()
      if refreshing or not vim.api.nvim_win_is_valid(handle.win) then return end
      refreshing = true
      pcall(vim.api.nvim_win_set_config, handle.win, { title = base_title:gsub(" $", " (refreshing…) ") })
      pane.refetch(conn_id, path, function(err, new_details)
        vim.schedule(function()
          refreshing = false
          if not vim.api.nvim_win_is_valid(handle.win) then return end
          if err then
            pcall(vim.api.nvim_win_set_config, handle.win, { title = base_title })
            vim.notify("grannos: " .. err, vim.log.levels.ERROR)
            return
          end
          local new_lines, new_hls, new_title = render_describe(new_details, node)
          local width, height = calculate_win_size(new_lines)
          vim.bo[handle.buf].modifiable = true
          vim.api.nvim_buf_set_lines(handle.buf, 0, -1, false, new_lines)
          vim.bo[handle.buf].modifiable = false
          vim.api.nvim_buf_clear_namespace(handle.buf, handle.ns, 0, -1)
          for _, rule in ipairs(new_hls) do
            vim.api.nvim_buf_add_highlight(handle.buf, handle.ns, rule[1], rule[2], rule[3], rule[4])
          end
          pcall(vim.api.nvim_win_set_config, handle.win, {
            title = " " .. new_title .. " ", width = width, height = height,
          })
          pcall(vim.api.nvim_win_set_cursor, handle.win, { 1, 0 })
        end)
      end)
    end
    vim.keymap.set("n", "r", refresh, { buffer = handle.buf, nowait = true, silent = true })
  end
end

--- Return display lines, highlight rules, and window title for a describe float (pure).
--- @param details TableDetails
--- @param node    ExplorerNode
--- @return string[], HlRule[], string  lines, hl_rules, win_title
render_describe = function(details, node)
  local lines    = {}
  local hl_rules = {}

  local function add_hl(group, line_idx, col_s, col_e)
    table.insert(hl_rules, { group, line_idx, col_s, col_e })
  end

  local function is_nil_val(v) return v == nil or v == vim.NIL end

  local function rpad(s, n)
    return s .. string.rep(" ", math.max(0, n - vim.fn.strdisplaywidth(s)))
  end

  local function field_type_string(col)
    local types = type(col.types) == "table" and col.types or {}
    return #types > 0 and table.concat(types, "|") or "?"
  end

  --- Flatten each field's own reference list (outgoing_references or
  --- incoming_references) into one list for the entity — EntityDescription
  --- no longer carries these itself, only its fields do.
  local function flatten_refs(properties, key)
    local refs = {}
    if type(properties) ~= "table" then return refs end
    for _, field in ipairs(properties) do
      local field_refs = field[key]
      if type(field_refs) == "table" then
        for _, r in ipairs(field_refs) do
          refs[#refs + 1] = r
        end
      end
    end
    return refs
  end

  local tname     = details.name or node.name
  local schema    = not is_nil_val(details.schema) and details.schema or nil
  local win_title = (schema and schema .. "." or "") .. tname
  local hdr_title = node_icon(node) .. win_title

  table.insert(lines, "  " .. hdr_title)
  add_hl("GrannosHeaderRow", 0, 2, 2 + #hdr_title)

  if not is_nil_val(details.comment) and details.comment ~= "" then
    for _, cline in ipairs(pane.wrap_lines(details.comment, pane.COMMENT_WRAP_WIDTH)) do
      local comment_line = "  " .. cline
      table.insert(lines, comment_line)
      add_hl("GrannosExplorerDim", #lines - 1, 0, #comment_line)
    end
  end

  table.insert(lines, "")

  local cols = details.properties
  if cols and #cols > 0 then
    -- Null/PK/Index columns are driver-dependent concepts (e.g. Prometheus
    -- fields have neither): only show them when at least one field actually
    -- carries that data, instead of always rendering an all-blank column.
    local has_nullable, has_pk, has_default, has_index = false, false, false, false
    for _, col in ipairs(cols) do
      if not is_nil_val(col.nullable) then has_nullable = true end
      if col.pk then has_pk = true end
      if not is_nil_val(col.default) then has_default = true end
      local excl = type(col.exclusive_indices) == "table" and col.exclusive_indices or {}
      local comp = type(col.composite_indices) == "table" and col.composite_indices or {}
      if #excl > 0 or #comp > 0 then has_index = true end
    end

    --- One column of the properties table.
    --- @class DescribeColumnSpec
    --- @field header string
    --- @field width  integer  set below, after scanning all fields
    --- @field value  fun(col: table): string
    --- @field hl     fun(col: table, s: string): string|nil  highlight group for the rendered value, or nil

    --- @type DescribeColumnSpec[]
    local specs = {
      {
        header = "Name",
        value  = function(col) return col.name end,
        hl     = function(col) return col.pk and "GrannosExplorerSchema" or nil end,
      },
      {
        header = "Type",
        value  = function(col) return field_type_string(col) end,
        hl     = function() return "GrannosExplorerTable" end,
      },
    }
    if has_nullable then
      specs[#specs + 1] = {
        header = "Null",
        value  = function(col) return col.nullable == true and "✓" or col.nullable == false and "✗" or "" end,
        hl     = function(_, s) return s ~= "" and "GrannosExplorerDim" or nil end,
      }
    end
    if has_pk then
      specs[#specs + 1] = {
        header = "PK",
        value  = function(col) return col.pk and "✓" or "" end,
        hl     = function(col) return col.pk and "GrannosExplorerSchema" or nil end,
      }
    end
    if has_default then
      specs[#specs + 1] = {
        header = "Default",
        value  = function(col) return not is_nil_val(col.default) and tostring(col.default) or "—" end,
        hl     = function() return nil end,
      }
    end
    if has_index then
      specs[#specs + 1] = {
        header = "Excl.",
        value  = function(col)
          return (type(col.exclusive_indices) == "table" and #col.exclusive_indices > 0) and "✓" or ""
        end,
        hl = function(_, s) return s == "✓" and "GrannosExplorerIndex" or nil end,
      }
      specs[#specs + 1] = {
        header = "Comp.",
        value  = function(col)
          return (type(col.composite_indices) == "table" and #col.composite_indices > 0) and "✓" or ""
        end,
        hl = function(_, s) return s == "✓" and "GrannosExplorerIndex" or nil end,
      }
    end

    for _, spec in ipairs(specs) do
      local w = vim.fn.strdisplaywidth(spec.header)
      for _, col in ipairs(cols) do
        w = math.max(w, vim.fn.strdisplaywidth(spec.value(col)))
      end
      spec.width = w
    end

    local GAP = "  "

    if has_index then
      local excl_off, idx_w, offset = nil, 0, 2  -- 2 = left margin
      for _, spec in ipairs(specs) do
        if spec.header == "Excl." then excl_off = offset end
        if spec.header == "Excl." or spec.header == "Comp." then
          idx_w = offset + spec.width - excl_off
        end
        offset = offset + spec.width + #GAP
      end
      local grp_lbl  = "Index"
      local grp_off  = excl_off + math.floor((idx_w - #grp_lbl) / 2)
      local grp_line = string.rep(" ", grp_off) .. grp_lbl
      table.insert(lines, grp_line)
      add_hl("GrannosHeaderRow", #lines - 1, grp_off, grp_off + #grp_lbl)
    end

    local hdr_parts = { "  " }
    for i, spec in ipairs(specs) do
      hdr_parts[#hdr_parts + 1] = rpad(spec.header, spec.width)
      if i < #specs then hdr_parts[#hdr_parts + 1] = GAP end
    end
    local hdr = table.concat(hdr_parts)
    table.insert(lines, hdr)
    add_hl("GrannosHeaderRow", #lines - 1, 0, #hdr)

    local sep = "  " .. string.rep("─", vim.fn.strdisplaywidth(hdr) - 2)
    table.insert(lines, sep)
    add_hl("GrannosBorder", #lines - 1, 0, #sep)

    for _, col in ipairs(cols) do
      local row_idx = #lines
      local parts, pos = {}, 0
      local function seg(s, grp)
        if grp then add_hl(grp, row_idx, pos, pos + #s) end
        parts[#parts + 1] = s
        pos = pos + #s
      end

      seg("  ")
      for i, spec in ipairs(specs) do
        local v = spec.value(col)
        seg(rpad(v, spec.width), spec.hl(col, v))
        if i < #specs then seg(GAP) end
      end

      table.insert(lines, table.concat(parts))
    end
  end

  local ARROW = "  →  "

  --- Render one references section ("Foreign keys" / "Incoming references").
  --- Table names use GrannosExplorerTable; column names use GrannosExplorerColumn.
  --- `table`/`column` on a TableReference always name the FK-OWNING side and
  --- `ref_table`/`ref_column` always name the side it points at — regardless
  --- of whether it came from `outgoing_references` (owned by this entity) or
  --- `incoming_references` (owned by the other entity) — so which pair is
  --- "the other table" flips with `reverse`.
  --- @param label   string
  --- @param refs    TableReference[]
  --- @param reverse boolean  true for incoming references
  local function render_refs(label, refs, reverse)
    if type(refs) ~= "table" or #refs == 0 then return end

    table.insert(lines, "")
    local hdr = "  " .. label
    table.insert(lines, hdr)
    add_hl("GrannosHeaderRow", #lines - 1, 2, 2 + #label)

    for _, r in ipairs(refs) do
      local row_idx  = #lines
      local parts, pos = {}, 0
      local function seg(s, grp)
        if grp then add_hl(grp, row_idx, pos, pos + #s) end
        parts[#parts + 1] = s
        pos = pos + #s
      end

      seg("  ")
      if reverse then
        local other_table = (not is_nil_val(r.schema) and r.schema .. "." or "") .. r.table .. "."
        seg(other_table,  "GrannosExplorerTable")
        seg(r.column,      "GrannosExplorerColumn")
        seg(ARROW)
        seg(r.ref_column,  "GrannosExplorerColumn")
      else
        local other_table = (not is_nil_val(r.ref_schema) and r.ref_schema .. "." or "") .. r.ref_table .. "."
        seg(r.column,      "GrannosExplorerColumn")
        seg(ARROW)
        seg(other_table,  "GrannosExplorerTable")
        seg(r.ref_column, "GrannosExplorerColumn")
      end

      table.insert(lines, table.concat(parts))
    end
  end

  render_refs("Foreign keys",         flatten_refs(details.properties, "outgoing_references"), false)
  render_refs("Incoming references",  flatten_refs(details.properties, "incoming_references"), true)

  return lines, hl_rules, win_title
end

--- Compute float dimensions for `lines` (display-width aware).
--- @param lines string[]
--- @return integer, integer  width, height
calculate_win_size = function(lines)
  local max_w = 0
  for _, l in ipairs(lines) do max_w = math.max(max_w, vim.fn.strdisplaywidth(l)) end
  return math.max(max_w + 2, 30), math.min(#lines, math.floor(vim.o.lines * 0.7))
end

--- Open a centred editor float displaying `lines` with `hl_rules` applied.
--- @param lines     string[]
--- @param hl_rules  HlRule[]
--- @param win_title string
--- @return { buf: integer, win: integer, ns: integer, title: string }
present_describe_float = function(lines, hl_rules, win_title)
  local width, height = calculate_win_size(lines)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden  = "wipe"

  local ns = vim.api.nvim_create_namespace("GrannosDescribeFloat")
  for _, rule in ipairs(hl_rules) do
    vim.api.nvim_buf_add_highlight(buf, ns, rule[1], rule[2], rule[3], rule[4])
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = math.floor((vim.o.lines - height) / 2),
    col       = math.floor((vim.o.columns - width)  / 2),
    width     = width,
    height    = height,
    style     = "minimal",
    border    = "rounded",
    title     = " " .. win_title .. " ",
    title_pos = "center",
  })
  vim.api.nvim_win_set_hl_ns(win, hl.NS_ID)
  vim.api.nvim_set_option_value("cursorline", true, { win = win })

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function() pcall(vim.api.nvim_win_close, win, true) end,
      { buffer = buf, silent = true, nowait = true })
  end

  return { buf = buf, win = win, ns = ns, title = win_title }
end

--- Handle the hover key: request explore.describe for the node under the cursor.
---
--- The "columns" group node is special: for drivers where that path no longer
--- resolves on its own (an entity's fields live on the entity's own describe
--- result instead), hovering it describes the *parent* entity path and reads
--- its `properties` list — same two-pane columns browser, sourced differently.
--- Other drivers (e.g. Neo4j's "properties" group) resolve the group path
--- directly, returning a bare array of FieldDescription; that case is handled
--- below by discriminating the array's element `type` tag, not by path name.
local function on_describe()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local node = node_at_line(line)
  if not node then return end
  node.describing = true
  spinner:start()
  render()

  local is_columns_group = node.type == "group" and node.path[#node.path] == "columns"
  local describe_path = is_columns_group
    and vim.list_slice(node.path, 1, #node.path - 1)
    or node.path

  client.request("explore.describe", { connection_id = state.conn_id, path = describe_path }, function(err, result)
    node.describing = false
    spinner:stop()
    if err then
      vim.schedule(function()
        vim.notify("grannos: " .. err, vim.log.levels.ERROR)
        render()
      end)
      return
    end
    vim.schedule(function()
      render()
      local details = result.details
      if is_columns_group then
        local p = node.path
        local parts = vim.list_slice(p, 1, #p - 1)
        local ctx = table.concat(parts, ".")
        local title = ctx ~= "" and (" Columns · " .. ctx .. " ") or " Columns "
        require("grannos.ui.column").open(details, title, state.conn_id, node.path)
      elseif is_array(details) then
        local p = node.path
        local parts = vim.list_slice(p, 1, #p - 1)
        local ctx = table.concat(parts, ".")
        -- Group-describe arrays come back as a bare list of FieldDescription,
        -- IndexDescription, or GenericRecordDescription; the element's own
        -- `type` tag says which (some drivers, e.g. Neo4j's "properties"
        -- group, resolve a fields group directly instead of requiring the
        -- parent-entity redirect above).
        if details[1] and details[1].type == "field" then
          local title = ctx ~= "" and (" Columns · " .. ctx .. " ") or " Columns "
          require("grannos.ui.column").open({ properties = details }, title, state.conn_id, node.path)
        elseif details[1] and details[1].type == "generic_record" then
          local title = ctx ~= "" and (" " .. ctx .. " ") or " Records "
          require("grannos.ui.generic_record").open(details, title, state.conn_id, node.path)
        else
          local title = ctx ~= "" and (" Indices · " .. ctx .. " ") or " Indices "
          require("grannos.ui.indices").open(details, title, state.conn_id, node.path)
        end
      elseif details and details.type == "index" then
        require("grannos.ui.indices").open_single(details, state.conn_id, describe_path)
      elseif details and details.type == "field" then
        require("grannos.ui.column").open_single(details, state.conn_id, describe_path)
      elseif details and details.type == "document" then
        require("grannos.ui.document").open_single(details, node.name, state.conn_id, describe_path)
      elseif details and details.type == "generic_record" then
        require("grannos.ui.generic_record").open_single(details, state.conn_id, describe_path)
      else
        open_describe_float(details, node, state.conn_id, describe_path)
      end
    end)
  end)
end

--- Fetch the root node list from the server and repopulate state.tree.
--- @param reset_cache boolean|nil  pass true to discard the server-side cache
local function load_root(reset_cache)
  local params = { connection_id = state.conn_id, path = {} }
  if reset_cache then params.reset_cache = true end
  state.root_loading = true
  spinner:start()
  render()
  client.request("explore.list", params, function(err, result)
    state.root_loading = false
    spinner:stop()
    if err then
      vim.schedule(function()
        vim.notify("grannos explorer: " .. err, vim.log.levels.ERROR)
        render()
      end)
      return
    end
    state.tree = {}
    for _, item in ipairs(result.items or {}) do
      state.tree[#state.tree + 1] = make_node(item, { item.name })
    end
    vim.schedule(render)
  end)
end

local PREVIEWABLE_TYPES  = { table = true, ["base table"] = true, view = true, collection = true }
local DIAGRAM_TYPES      = { table = true, ["base table"] = true, view = true }
local DOWNLOADABLE_TYPES = { object = true }

--- Handle the "D" keymap: request an ASCII diagram for the table under the cursor.
local function on_diagram()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local node = node_at_line(line)
  if not node or not DIAGRAM_TYPES[node.type] then return end
  require("grannos.ui.diagram").open(state.conn_id, node.path, node.name, state.conn_key)
end

--- Handle the "p" keymap: request a row preview for the node under the cursor.
local function on_preview_rows()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local node = node_at_line(line)
  if not node or not PREVIEWABLE_TYPES[node.type] then return end
  results.set_conn_name(state.conn_key, state.conn_driver_label)
  results.set_source_table(node.path)
  results.show_message("Loading…")
  client.request("explore.preview", { connection_id = state.conn_id, path = node.path },
    function(err, result)
      vim.schedule(function()
        if err then
          results.show_error(err)
          return
        end
        if type(result.columns) ~= "table" then
          results.show_error("Preview not supported for this node type")
          return
        end
        local rows = type(result.rows) == "table" and result.rows or {}
        results.show_results(result.columns, rows, #rows, result.rows_total, result.duration_ms)
      end)
    end)
end

--- Handle the "o" keymap: open the full content of the node under the
--- cursor in a scratch buffer (e.g. an S3 object). No-op for node types
--- that don't support content download.
local function on_open_in_buffer()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local node = node_at_line(line)
  if not node or not DOWNLOADABLE_TYPES[node.type] then return end
  vim.notify(("grannos: downloading %q…"):format(node.name), vim.log.levels.INFO)
  client.request("explore.download", { connection_id = state.conn_id, path = node.path },
    function(err, result)
      vim.schedule(function()
        if err then
          vim.notify("grannos: " .. err, vim.log.levels.ERROR)
          return
        end
        content_buffer.open(result.content_base64, result.filename, result.content_type)
      end)
    end)
end

--- Handle the "s" keymap: save the full content of the node under the cursor
--- straight to a local file (prompted), without routing it through a buffer —
--- the right choice for binary content, and for anything too large to
--- comfortably hold in a Neovim buffer.
local function on_save_to_disk()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local node = node_at_line(line)
  if not node or not DOWNLOADABLE_TYPES[node.type] then return end
  vim.ui.input({ prompt = "Save to: ", default = vim.fn.getcwd() .. "/" .. node.name, completion = "file" },
    function(path)
      if not path or path == "" then return end
      local abs_path = vim.fn.fnamemodify(path, ":p")
      vim.notify(("grannos: saving %q…"):format(abs_path), vim.log.levels.INFO)
      client.request("explore.download",
        { connection_id = state.conn_id, path = node.path, dest_path = abs_path },
        function(err, result)
          vim.schedule(function()
            if err then
              vim.notify("grannos: " .. err, vim.log.levels.ERROR)
              return
            end
            vim.notify(("grannos: saved %d bytes to %q"):format(result.size, result.written_to), vim.log.levels.INFO)
          end)
        end)
    end)
end

--- Create the explorer Buffer (with keymaps) if it doesn't exist or has been wiped.
local function get_or_create_buffer()
  if state.buffer and state.buffer:is_valid() then return end
  state.buffer = Buffer:new(BUFNAME, "grannos_explorer", false, "nofile")
  state.buffer:set_keymap("n", "<CR>", on_enter,
    { nowait = true, silent = true, desc = "Expand / collapse node" })
  state.buffer:set_keymap("n", config.options.keymaps.hover_key, on_describe,
    { nowait = true, silent = true, desc = "Describe item" })
  state.buffer:set_keymap("n", "r", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local node = node_at_line(line)
    if node and not node.expandable then
      local parent_path = vim.list_slice(node.path, 1, #node.path - 1)
      node = #parent_path > 0 and node_at_path(parent_path) or nil
    end
    if node then
      node.children = nil
      load_children(node, true)
    else
      state.tree = {}
      load_root(true)
    end
  end, { nowait = true, silent = true, desc = "Refresh node" })
  state.buffer:set_keymap("n", "R", function()
    state.tree = {}
    load_root(true)
  end, { nowait = true, silent = true, desc = "Refresh explorer" })
  state.buffer:set_keymap("n", "p", on_preview_rows,
    { nowait = true, silent = true, desc = "Preview rows" })
  state.buffer:set_keymap("n", "D", on_diagram,
    { nowait = true, silent = true, desc = "Show table diagram" })
  state.buffer:set_keymap("n", "o", on_open_in_buffer,
    { nowait = true, silent = true, desc = "Open content in buffer" })
  state.buffer:set_keymap("n", "s", on_save_to_disk,
    { nowait = true, silent = true, desc = "Save content to disk" })
  state.buffer:set_keymap("n", "q", function()
    local win = vim.fn.bufwinid(state.buffer.buf_id)
    if win ~= -1 then vim.api.nvim_win_close(win, true) end
  end, { nowait = true, silent = true, desc = "Close explorer" })
end

--- Open (or focus) the explorer sidebar for the given connection.
--- @param conn_id      any
--- @param conn_name    string
--- @param driver       string
--- @param conn_key     string
--- @param driver_label string
function M.open(conn_id, conn_name, driver, conn_key, driver_label)
  get_or_create_buffer()

  -- Reset the tree when switching to a different connection.
  if conn_id ~= state.conn_id then
    state.tree             = {}
    state.conn_id          = conn_id
    state.conn_key         = conn_key
    state.conn_driver_label = driver_label
    state.conn_label       = conn_name .. " (" .. driver .. ")"
    pcall(vim.api.nvim_buf_set_name, state.buffer.buf_id,
      BUFNAME .. " [" .. state.conn_label .. "]")
  end

  local win = vim.fn.bufwinid(state.buffer.buf_id)
  if win == -1 then
    win = window.open_sidebar(state.buffer.buf_id, "left")
  end
  vim.api.nvim_set_current_win(win)

  if state.conn_label then
    -- Escape % so statusline format doesn't misinterpret it.
    local label = state.conn_label:gsub("%%", "%%%%")
    vim.api.nvim_set_option_value("winbar",
      "%#GrannosHeaderRow#  " .. label, { win = win })
  end

  if #state.tree == 0 then
    load_root()
  else
    render()
  end
end

--- Return the names of the already-fetched children at `path` for `conn_id`,
--- or nil when that path hasn't been expanded in the sidebar (including when
--- the sidebar is currently showing a different connection). Read-only —
--- never triggers a fetch of its own, so callers can use it as a cheap,
--- best-effort lookup into whatever the user has already browsed.
--- @param conn_id any
--- @param path    string[]  empty for the root (schema) list
--- @return string[]|nil
function M.cached_child_names(conn_id, path)
  if conn_id ~= state.conn_id then return nil end
  local children
  if #path == 0 then
    children = #state.tree > 0 and state.tree or nil
  else
    local node = node_at_path(path)
    children = node and node.children
  end
  if not children then return nil end
  local names = {}
  for _, n in ipairs(children) do table.insert(names, n.name) end
  return names
end

--- Clear the explorer tree and stop the spinner (called on backend teardown).
function M.reset()
  state.tree         = {}
  state.root_loading = false
  spinner:reset()
end

--- Open the table/view describe float for `details`, using `node` for its
--- display name and icon. Exposed so other modules (e.g. the diagram viewer)
--- can reuse the same renderer for paths not backed by a real ExplorerNode.
--- @param details TableDetails|nil
--- @param node    { name: string, type: string }
--- @param conn_id any|nil        connection to refetch from; with `path`, enables "r" to refresh
--- @param path    string[]|nil   leaf path `details` was described at
M.open_describe_float = open_describe_float

return M
