-- Two-pane float for browsing all indexes of a table (bare array of
-- IndexDescription), and a single-index detail float (IndexDescription).
-- Window management is handled by detail_pane; this module contains only
-- index-specific content rendering.
local M = {}

local pane = require("grannos.ui.detail_pane")
local ICON = "󰒻 "

--- @param v any
--- @return boolean
local function is_nil(v) return pane.is_nil(v) end

--- Return the estimated rendered line count for a single index detail view.
--- @param idx table  IndexDescription
--- @return integer
local function estimate_lines(idx)
  local n       = 2  -- one-liner + blank
  local tables   = type(idx.tables)           == "table" and idx.tables           or {}
  local fields   = type(idx.fields)           == "table" and idx.fields           or {}
  local included = type(idx.included_columns) == "table" and idx.included_columns or {}
  if #tables > 1 then n = n + 4 end
  if #fields   > 0 then n = n + 3 + #fields end
  if #included > 0 then n = n + 4 end
  if not is_nil(idx.ddl) and idx.ddl ~= "" then
    n = n + 2 + #vim.split(idx.ddl, "\n", { plain = true })
  end
  return n
end

--- Populate `buf` with the detail view for a single index.
--- @param buf integer
--- @param idx table  IndexDescription
local function render(buf, idx)
  local lines = {}
  local hls   = {}

  -- One-liner: type · unique/non-unique · [clustered] · [invisible/disabled]
  local tagged = {}
  if not is_nil(idx.index_type) and idx.index_type ~= "" then
    tagged[#tagged + 1] = { idx.index_type, "GrannosExplorerIndex" }
  end
  tagged[#tagged + 1] = idx.unique
    and { "unique",     "GrannosQuerySuccess" }
    or  { "non-unique", "GrannosExplorerDim"  }
  if idx.clustered then
    tagged[#tagged + 1] = { "clustered", "GrannosExplorerSchema" }
  end
  if not is_nil(idx.visible) and not idx.visible then
    tagged[#tagged + 1] = { "invisible", "GrannosError" }
  end

  local row0 = #lines
  local line, specs = pane.tag_line(tagged)
  lines[#lines + 1] = line
  for _, s in ipairs(specs) do hls[#hls + 1] = { s[1], row0, s[2], s[3] } end
  lines[#lines + 1] = ""

  if type(idx.tables) == "table" and #idx.tables > 1 then
    pane.section(lines, hls, "Tables")
    lines[#lines + 1] = "  " .. table.concat(idx.tables, ", ")
    lines[#lines + 1] = ""
  end

  local fields = type(idx.fields) == "table" and idx.fields or {}
  if #fields > 0 then
    pane.section(lines, hls, "Fields")
    for _, f in ipairs(fields) do
      local dir = f.direction == "asc"  and " ↑"
               or f.direction == "desc" and " ↓"
               or (f.direction and ("  " .. f.direction) or "")
      local frow = #lines
      lines[#lines + 1] = "  " .. f.name .. dir
      if dir ~= "" then
        hls[#hls + 1] = { "GrannosExplorerDim", frow, 2 + #f.name, -1 }
      end
    end
    lines[#lines + 1] = ""
  end

  local included = type(idx.included_columns) == "table" and idx.included_columns or {}
  if #included > 0 then
    pane.section(lines, hls, "Included columns")
    lines[#lines + 1] = "  " .. table.concat(included, ", ")
    lines[#lines + 1] = ""
  end

  if not is_nil(idx.ddl) and idx.ddl ~= "" then
    pane.section(lines, hls, "DDL")
    for _, dline in ipairs(vim.split(idx.ddl, "\n", { plain = true })) do
      local drow = #lines
      lines[#lines + 1] = "  " .. dline
      hls[#hls + 1] = { "GrannosExplorerDim", drow, 2, -1 }
    end
  end

  pane.apply(buf, lines, hls)
end

--- Open the two-pane indices browser.
--- @param details    table      Bare array of IndexDescription, as decoded from the
---                               server response (group paths return a plain array now,
---                               not a wrapper object)
--- @param title      string     Left pane window title (caller derives from the request path)
--- @param conn_id    any|nil    connection to refetch from; with `group_path`, enables "r" to
---                               refresh the focused index
--- @param group_path string[]|nil  path to the indices group node; a focused index's own
---                               leaf path is `group_path .. {name}`
function M.open(details, title, conn_id, group_path)
  local indices = type(details) == "table" and details or {}
  if #indices == 0 then
    vim.notify("grannos: no indices found for this table", vim.log.levels.WARN)
    return
  end
  pane.open_searchable_two_pane({
    items      = indices,
    left_title = title or " Indices ",
    get_label  = function(idx) return idx.name end,
    get_title  = function(idx) return ICON .. idx.name end,
    render     = render,
    estimate   = estimate_lines,
    conn_id    = conn_id,
    item_path  = group_path and function(idx) return vim.list_extend(vim.list_slice(group_path), { idx.name }) end or nil,
  })
end

--- Open a single-index detail float.
--- @param idx     table       IndexDescription as decoded from the server response
--- @param conn_id any|nil     connection to refetch from; with `path`, enables "r" to refresh
--- @param path    string[]|nil  leaf path this index was described at
function M.open_single(idx, conn_id, path)
  pane.open_single({
    item     = idx,
    title    = ICON .. idx.name,
    render   = render,
    estimate = estimate_lines,
    conn_id  = conn_id,
    path     = path,
  })
end

return M
