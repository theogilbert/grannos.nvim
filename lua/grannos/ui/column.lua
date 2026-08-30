-- Two-pane float for browsing all fields of an entity (EntityDescription.properties),
-- and a single-field detail float (FieldDescription).
-- The right pane of the two-pane browser reuses the same renderer as the
-- single-field float. Window management is handled by detail_pane.
local M = {}

local pane = require("grannos.ui.detail_pane")
local ICON = "󰠵 "
local ARROW = "  →  "

--- @param v any
--- @return boolean
local function is_nil(v) return pane.is_nil(v) end

--- Build the "schema.table." prefix for the referenced side of a TableReference.
--- `table`/`schema` name the FK-owning side; `ref_table`/`ref_schema` name the
--- side it points at, which is what a "→ target" display wants.
--- @param ref table  TableReference
--- @return string
local function ref_table_prefix(ref)
  return (not is_nil(ref.ref_schema) and ref.ref_schema .. "." or "") .. ref.ref_table .. "."
end

--- Return the estimated rendered line count for a single column detail view.
--- @param col table  FieldDescription
--- @return integer
local function estimate_lines(col)
  local n = 2  -- header + blank
  if not is_nil(col.comment) and col.comment ~= "" then
    n = n + #pane.wrap_lines(col.comment, pane.COMMENT_WRAP_WIDTH)
  end
  if not is_nil(col.default) and col.default ~= "" then n = n + 4 end
  local excl = type(col.exclusive_indices) == "table" and col.exclusive_indices or {}
  if #excl > 0 then n = n + 3 + #excl end
  local comp = type(col.composite_indices) == "table" and col.composite_indices or {}
  if #comp > 0 then n = n + 3 + #comp end
  local sample = type(col.sample) == "table" and col.sample or {}
  if #sample > 0 then n = n + 3 + #sample end
  local refs = type(col.outgoing_references) == "table" and col.outgoing_references or {}
  if #refs > 0 then n = n + 3 + #refs end
  return n
end

--- Build the tagged type-summary segments for a field: types · nullable/not null · primary key.
--- @param col table  FieldDescription
--- @return table  tagged list consumed by detail_pane.tag_line
local function type_tags(col)
  local types = type(col.types) == "table" and col.types or {}
  local data_type = #types > 0 and table.concat(types, "|") or "?"
  local tagged = { { data_type, "GrannosExplorerTable" } }
  if col.nullable == true then
    tagged[#tagged + 1] = { "nullable", "GrannosExplorerDim" }
  elseif col.nullable == false then
    tagged[#tagged + 1] = { "not null", "GrannosExplorerDim" }
  end
  if col.pk then tagged[#tagged + 1] = { "primary key", "GrannosExplorerSchema" } end
  return tagged
end

--- Populate `buf` with the detail view for a single column.
--- @param buf integer
--- @param col table  FieldDescription
local function render(buf, col)
  local lines = {}
  local hls   = {}

  local row0 = #lines
  local line, specs = pane.tag_line(type_tags(col))
  lines[#lines + 1] = line
  for _, s in ipairs(specs) do hls[#hls + 1] = { s[1], row0, s[2], s[3] } end

  if not is_nil(col.comment) and col.comment ~= "" then
    for _, cline in ipairs(pane.wrap_lines(col.comment, pane.COMMENT_WRAP_WIDTH)) do
      local comment_row  = #lines
      local comment_line = "  " .. cline
      lines[#lines + 1] = comment_line
      hls[#hls + 1] = { "GrannosExplorerDim", comment_row, 0, #comment_line }
    end
  end

  lines[#lines + 1] = ""

  if not is_nil(col.default) and col.default ~= "" then
    pane.section(lines, hls, "Default")
    lines[#lines + 1] = "  " .. tostring(col.default)
    lines[#lines + 1] = ""
  end

  local refs = type(col.outgoing_references) == "table" and col.outgoing_references or {}
  if #refs > 0 then
    pane.section(lines, hls, "Foreign keys")
    for _, ref in ipairs(refs) do
      local row_idx = #lines
      local parts, pos = {}, 0
      local function seg(s, grp)
        if grp then hls[#hls + 1] = { grp, row_idx, pos, pos + #s } end
        parts[#parts + 1] = s
        pos = pos + #s
      end
      seg("  ")
      seg(ref.column, "GrannosExplorerColumn")
      seg(ARROW)
      seg(ref_table_prefix(ref), "GrannosExplorerTable")
      seg(ref.ref_column, "GrannosExplorerColumn")
      lines[#lines + 1] = table.concat(parts)
    end
    lines[#lines + 1] = ""
  end

  local excl = type(col.exclusive_indices) == "table" and col.exclusive_indices or {}
  if #excl > 0 then
    pane.section(lines, hls, "Exclusive indices")
    for _, idx in ipairs(excl) do
      local name = type(idx) == "table" and idx.name or tostring(idx)
      local irow = #lines
      lines[#lines + 1] = "  " .. name
      hls[#hls + 1] = { "GrannosExplorerIndex", irow, 2, 2 + #name }
    end
    lines[#lines + 1] = ""
  end

  local comp = type(col.composite_indices) == "table" and col.composite_indices or {}
  if #comp > 0 then
    pane.section(lines, hls, "Composite indices")
    for _, idx in ipairs(comp) do
      local name = type(idx) == "table" and idx.name or tostring(idx)
      local irow = #lines
      lines[#lines + 1] = "  " .. name
      hls[#hls + 1] = { "GrannosExplorerIndex", irow, 2, 2 + #name }
    end
    lines[#lines + 1] = ""
  end

  local sample = type(col.sample) == "table" and col.sample or {}
  if #sample > 0 then
    pane.section(lines, hls, "Sample values")
    for _, v in ipairs(sample) do
      lines[#lines + 1] = "  " .. tostring(v)
    end
    lines[#lines + 1] = ""
  end

  pane.apply(buf, lines, hls)
end

--- Open the two-pane columns browser.
--- @param details    table      EntityDescription as decoded from the server response
---                               (the group-level "columns" path no longer resolves —
---                               callers describe the parent entity and pass its
---                               `properties` list here instead)
--- @param title      string     Left pane window title (caller derives from the request path)
--- @param conn_id    any|nil    connection to refetch from; with `group_path`, enables "r" to
---                               refresh the focused column
--- @param group_path string[]|nil  path to the columns group node (e.g. `[..., "columns"]`);
---                               a focused column's own leaf path is `group_path .. {name}`,
---                               per the field-refresh convention in docs/protocol.md
function M.open(details, title, conn_id, group_path)
  local columns = type(details.properties) == "table" and details.properties or {}
  if #columns == 0 then
    vim.notify("grannos: no columns found", vim.log.levels.WARN)
    return
  end
  pane.open_searchable_two_pane({
    items      = columns,
    left_title = title or " Columns ",
    get_label  = function(col) return col.name end,
    get_title  = function(col) return ICON .. col.name end,
    render     = render,
    estimate   = estimate_lines,
    conn_id    = conn_id,
    item_path  = group_path and function(col) return vim.list_extend(vim.list_slice(group_path), { col.name }) end or nil,
  })
end

--- Open the two-pane columns browser for a columns *group* node, deriving the
--- left pane's title from the group path's own ancestry. The single entry point
--- for "describe the columns group", so every caller — the explorer's `columns`
--- group node and the diagram's "..." row alike — renders an identical picker.
--- An entity's fields live on the entity's describe result rather than on the
--- group path, so callers describe the parent path and pass that
--- EntityDescription here.
--- @param details    table     EntityDescription for the group's parent entity
--- @param group_path string[]  path to the columns group node (e.g. `[..., "columns"]`)
--- @param conn_id    any|nil   connection to refetch from; enables "r" to refresh the focused column
function M.open_group(details, group_path, conn_id)
  local ctx = table.concat(vim.list_slice(group_path, 1, #group_path - 1), ".")
  M.open(details, ctx ~= "" and (" Columns · " .. ctx .. " ") or " Columns ", conn_id, group_path)
end

--- Build condensed hover lines for a column: name, type/constraints, comment.
--- A shorter view than `render()`, which also lists defaults, indices, and samples.
--- @param col table  FieldDescription
--- @return string[] lines
--- @return DetailHlRule[] hls
function M.hover_lines(col)
  local lines, hls = {}, {}

  local name_row = #lines
  lines[#lines + 1] = col.name
  hls[#hls + 1] = { "GrannosHeaderRow", name_row, 0, #col.name }

  local tag_row = #lines
  local line, specs = pane.tag_line(type_tags(col))
  lines[#lines + 1] = line
  for _, s in ipairs(specs) do hls[#hls + 1] = { s[1], tag_row, s[2], s[3] } end

  if not is_nil(col.comment) and col.comment ~= "" then
    for _, cline in ipairs(pane.wrap_lines(col.comment, pane.COMMENT_WRAP_WIDTH)) do
      local comment_row  = #lines
      local comment_line = "  " .. cline
      lines[#lines + 1] = comment_line
      hls[#hls + 1] = { "GrannosExplorerDim", comment_row, 0, #comment_line }
    end
  end

  local refs = type(col.outgoing_references) == "table" and col.outgoing_references or {}
  for _, ref in ipairs(refs) do
    local row_idx = #lines
    local parts, pos = {}, 0
    local function seg(s, grp)
      if grp then hls[#hls + 1] = { grp, row_idx, pos, pos + #s } end
      parts[#parts + 1] = s
      pos = pos + #s
    end
    seg(ARROW)
    seg(ref_table_prefix(ref), "GrannosExplorerTable")
    seg(ref.ref_column, "GrannosExplorerColumn")
    lines[#lines + 1] = table.concat(parts)
  end

  return lines, hls
end

--- Open a single-column detail float.
--- @param col     table       FieldDescription as decoded from the server response
--- @param conn_id any|nil     connection to refetch from; with `path`, enables "r" to refresh
--- @param path    string[]|nil  leaf path this column was described at
function M.open_single(col, conn_id, path)
  pane.open_single({
    item     = col,
    title    = ICON .. col.name,
    render   = render,
    estimate = estimate_lines,
    conn_id  = conn_id,
    path     = path,
  })
end

return M
