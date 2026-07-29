-- ASCII schema diagram viewer, opened in a new tab.
local M = {}

local client = require("grannos.client")
local config = require("grannos.config")
local hl     = require("grannos.hl")

local NS_ID = vim.api.nvim_create_namespace("GrannosDiagram")

-- Box-drawing and tree-connector characters used to frame table boxes and join lines.
-- Matched as a set of UTF-8 byte sequences since Lua patterns are byte-oriented.
local BORDER_PATTERN = "[┌┐└┘─│├┬┴┼→]+"

-- Explicit stacking order for overlapping highlights (e.g. a table's box-border
-- region and the generic border dim both cover the same bytes; a column region
-- sits inside a table's interior row). Higher wins, regardless of call order —
-- deliberately not relying on nvim_buf_add_highlight's implicit "last extmark
-- inserted wins" behavior for same-priority overlaps.
local PRIORITY = { border = 100, table = 110, edge = 110, column = 120 }

--- Dim the box-drawing/connector characters in `lines` so they recede behind the
--- table and column names highlighted via `apply_regions`.
--- @param buf   integer
--- @param lines string[]
local function apply_border_highlight(buf, lines)
  for row, line in ipairs(lines) do
    for s, e in line:gmatch("()" .. BORDER_PATTERN .. "()") do
      vim.hl.range(buf, NS_ID, "GrannosBorder",
        { row - 1, s - 1 }, { row - 1, e - 1 }, { priority = PRIORITY.border })
    end
  end
end

--- Join a DiagramRegion path into a table usable as a lookup key.
--- @param path string[]
--- @return string
local function path_key(path)
  return table.concat(path, "\0")
end

--- Derive a relationship edge's owning-table path from its region path
--- (`[..., "relationships", <column>]` → `[...]`).
--- @param edge_path string[]
--- @return string[]
local function owner_table_path(edge_path)
  return vim.list_slice(edge_path, 1, #edge_path - 2)
end

--- Infer which tables are directly connected by an edge, so color assignment
--- can keep adjacent tables visually distinct. An edge's owner table is known
--- exactly from its path; the table on the other side isn't encoded in
--- DiagramRegion, so it's approximated as whichever other table's box rows
--- sit nearest (smallest row gap) to the edge's own rows — reliable for the
--- tree layout `explore.diagram` draws, where an edge is always sandwiched
--- directly between the two boxes it connects.
--- @param regions table[]  DiagramRegion objects: { row, col_start, col_end, kind, path }
--- @return table<string, table<string, boolean>>  path-key → set of adjacent path-keys
local function build_adjacency(regions)
  local table_rows = {} -- path-key → { min, max, path }
  local edge_rows   = {} -- edge path-key → { min, max, path }

  local function extend(rows, key, row, path)
    local r = rows[key]
    if not r then
      rows[key] = { min = row, max = row, path = path }
    else
      r.min = math.min(r.min, row)
      r.max = math.max(r.max, row)
    end
  end

  for _, region in ipairs(regions) do
    if region.kind == "table" then
      extend(table_rows, path_key(region.path), region.row, region.path)
    elseif region.kind == "edge" then
      extend(edge_rows, path_key(region.path), region.row, region.path)
    end
  end

  --- Row distance between two ranges; 0 when they overlap.
  local function row_gap(a, b)
    if a.min > b.max then return a.min - b.max end
    if b.min > a.max then return b.min - a.max end
    return 0
  end

  local adj = {}
  local function link(a, b)
    adj[a] = adj[a] or {}
    adj[a][b] = true
    adj[b] = adj[b] or {}
    adj[b][a] = true
  end

  for edge_key, edge in pairs(edge_rows) do
    local owner_key = path_key(owner_table_path(edge.path))
    local nearest_key, nearest_gap = nil, nil
    for table_key, t in pairs(table_rows) do
      if table_key ~= owner_key then
        local gap = row_gap(edge, t)
        if not nearest_gap or gap < nearest_gap then
          nearest_key, nearest_gap = table_key, gap
        end
      end
    end
    if nearest_key then link(owner_key, nearest_key) end
  end

  return adj
end

--- Assign each table in `regions` a highlight group: the root table (the one
--- originally requested) keeps the dedicated gold DIAGRAM_ROOT_TABLE color;
--- every other table gets a color cycled from hl.DIAGRAM_TABLE_PALETTE, in the
--- order its first region is encountered, skipping any color already used by
--- a table it's directly connected to (per build_adjacency) so linked tables
--- don't end up looking alike.
--- @param regions   table[]  DiagramRegion objects: { row, col_start, col_end, kind, path }
--- @param root_path string[] path of the table `explore.diagram` was requested for
--- @return table<string, string>  path-key → highlight group
local function assign_table_colors(regions, root_path)
  local palette = hl.DIAGRAM_TABLE_PALETTE
  local adj     = build_adjacency(regions)
  local colors  = { [path_key(root_path)] = hl.DIAGRAM_ROOT_TABLE }

  local order, seen = {}, {}
  for _, region in ipairs(regions) do
    if region.kind == "table" then
      local key = path_key(region.path)
      if not seen[key] then
        seen[key] = true
        order[#order + 1] = key
      end
    end
  end

  local next_i = 1
  for _, key in ipairs(order) do
    if not colors[key] then
      local used = {}
      for neighbor in pairs(adj[key] or {}) do
        if colors[neighbor] then used[colors[neighbor]] = true end
      end
      local chosen
      for i = 0, #palette - 1 do
        local candidate = palette[(next_i - 1 + i) % #palette + 1]
        if not used[candidate] then
          chosen = candidate
          break
        end
      end
      colors[key] = chosen or palette[(next_i - 1) % #palette + 1]
      next_i = next_i + 1
    end
  end

  return colors
end

--- Highlight group for a DiagramRegion. Prefers the explicit `kind` field;
--- falls back to sniffing `path`'s shape for servers predating `kind`
--- (a column path ends in `.columns.<name>`; anything else names a table/view).
--- Table regions are colored per-table via `table_colors`; edge regions inherit
--- the color of the table that owns the foreign key (the first path segments
--- before `relationships`/`<column>`), so a relationship reads as belonging to
--- its owning table's box.
--- @param region       table  DiagramRegion object: { row, col_start, col_end, kind, path }
--- @param table_colors table<string, string>  path-key → highlight group, from assign_table_colors
--- @return string
local function region_hl_group(region, table_colors)
  local kind = region.kind
  if kind == nil then
    kind = (#region.path >= 2 and region.path[#region.path - 1] == "columns") and "column" or "table"
  end
  if kind == "column" then return "GrannosExplorerColumn" end
  if kind == "table" then
    return table_colors[path_key(region.path)] or "GrannosExplorerTable"
  end
  if kind == "edge" then
    return table_colors[path_key(owner_table_path(region.path))] or "GrannosExplorerConstraint"
  end
  return "GrannosExplorerTable"
end

--- Apply highlight groups to `buf` for each region in `regions`. Uses explicit
--- priorities (see PRIORITY) rather than call order, since table-box and column
--- regions can cover overlapping bytes (e.g. a table's interior-row border
--- characters flank that row's column-name region).
--- @param buf          integer
--- @param regions      table[]  DiagramRegion objects: { row, col_start, col_end, kind, path }
--- @param table_colors table<string, string>  path-key → highlight group, from assign_table_colors
local function apply_regions(buf, regions, table_colors)
  for _, region in ipairs(regions) do
    local kind     = region.kind or "table"
    local priority = PRIORITY[kind] or PRIORITY.table
    vim.hl.range(buf, NS_ID, region_hl_group(region, table_colors),
      { region.row, region.col_start }, { region.row, region.col_end }, { priority = priority })
  end
end

--- Find the region under a 0-indexed (row, col) cursor position, if any.
--- @param regions table[]  DiagramRegion objects: { row, col_start, col_end, kind, path }
--- @param row     integer  0-indexed
--- @param col     integer  0-indexed byte offset
--- @return table|nil
local function region_at(regions, row, col)
  for _, region in ipairs(regions) do
    if region.row == row and col >= region.col_start and col < region.col_end then
      return region
    end
  end
  return nil
end

--- Collect the distinct relationship (`kind == "edge"`) paths covering a 0-indexed
--- (row, col) cursor position. Regions sharing a `path` are one edge (see
--- docs/protocol.md#diagramregion), but a branch point where several
--- relationships share a trunk column can still put more than one distinct
--- edge path under the same cell — unlike `region_at`, which only ever
--- resolves the first match, this lets a caller notice and handle all of them.
--- @param regions table[]  DiagramRegion objects: { row, col_start, col_end, kind, path }
--- @param row     integer  0-indexed
--- @param col     integer  0-indexed byte offset
--- @return string[][]  distinct edge paths, in first-seen order
local function edge_paths_at(regions, row, col)
  local paths, seen = {}, {}
  for _, region in ipairs(regions) do
    if region.kind == "edge" and region.row == row and col >= region.col_start and col < region.col_end then
      local key = path_key(region.path)
      if not seen[key] then
        seen[key] = true
        paths[#paths + 1] = region.path
      end
    end
  end
  return paths
end

--- Request an ASCII diagram for the table at `path` and display it in a new tab.
--- The diagram buffer is silently associated with `conn_key` (its source connection)
--- via `set_buf_conn`, so generic Lua APIs that resolve a connection from the current
--- buffer (e.g. `require("grannos").open_explorer()`) work from it — without showing
--- the floating "Connected to …" label query buffers get.
--- @param conn_id  any
--- @param path     string[]
--- @param title    string  table name, used in the buffer name
--- @param conn_key string|nil  storage key of the source connection
function M.open(conn_id, path, title, conn_key)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  Loading…" })
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "grannos://diagram/" .. title)

  vim.cmd("tabnew")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_hl_ns(win, hl.NS_ID)

  vim.keymap.set("n", "q", function() pcall(vim.cmd, "tabclose") end,
    { buffer = buf, silent = true, nowait = true })

  if conn_key then
    require("grannos").set_buf_conn(buf, conn_key, { silent = true })
  end

  local regions      = {}
  local table_colors = {}

  --- Handle the hover key: resolve the region(s) under the cursor and describe
  --- them. When the cursor sits on more than one distinct relationship at once
  --- (e.g. a shared trunk column at a branch point), describes all of them and
  --- opens a browsable picker instead of arbitrarily picking one.
  local function on_hover()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row, col = cursor[1] - 1, cursor[2]

    local edges = edge_paths_at(regions, row, col)
    if #edges > 1 then
      local remaining              = #edges
      local rels, colors, paths    = {}, {}, {}
      for i, edge_path in ipairs(edges) do
        colors[i] = region_hl_group({ kind = "edge", path = edge_path }, table_colors)
        paths[i]  = edge_path
        client.request("explore.describe", { connection_id = conn_id, path = edge_path }, function(err, result)
          vim.schedule(function()
            if not err and result and result.details and result.details ~= vim.NIL then
              rels[i] = result.details
            end
            remaining = remaining - 1
            if remaining == 0 then
              -- Re-pack, dropping any index whose describe call failed or
              -- resolved to nothing, so rels/colors/paths stay aligned pairwise.
              local final_rels, final_colors, final_paths = {}, {}, {}
              for j = 1, #edges do
                if rels[j] then
                  final_rels[#final_rels + 1]   = rels[j]
                  final_colors[#final_colors + 1] = colors[j]
                  final_paths[#final_paths + 1] = paths[j]
                end
              end
              if #final_rels == 0 then
                vim.notify("grannos: nothing to describe here", vim.log.levels.WARN)
              elseif #final_rels == 1 then
                require("grannos.ui.relationship").open_single(final_rels[1], final_colors[1], conn_id, final_paths[1])
              else
                require("grannos.ui.relationship").open(final_rels, final_colors, conn_id, final_paths)
              end
            end
          end)
        end)
      end
      return
    end

    local region = region_at(regions, row, col)
    if not region then return end

    client.request("explore.describe", { connection_id = conn_id, path = region.path }, function(err, result)
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
          require("grannos.ui.column").open_single(details, conn_id, region.path)
        elseif details.type == "relationship" then
          require("grannos.ui.relationship").open_single(details, region_hl_group(region, table_colors), conn_id, region.path)
        else
          require("grannos.ui.explorer").open_describe_float(
            details, { name = region.path[#region.path], type = "table" }, conn_id, region.path)
        end
      end)
    end)
  end
  vim.keymap.set("n", config.options.keymaps.hover_key, on_hover,
    { buffer = buf, silent = true, nowait = true })

  client.request("explore.diagram", { connection_id = conn_id, path = path }, function(err, result)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then return end
      local lines = err and { "  " .. err } or vim.split(result and result.diagram or "", "\n")
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
      if not err then
        apply_border_highlight(buf, lines)
        if result and result.regions then
          regions      = result.regions
          table_colors = assign_table_colors(regions, path)
          apply_regions(buf, regions, table_colors)
        end
      end
    end)
  end)
end

return M
