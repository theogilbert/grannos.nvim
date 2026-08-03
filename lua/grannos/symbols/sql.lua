--- Symbol extraction for SQL buffers. See `grannos.symbols` for the contract.
local util = require("grannos.symbols.util")

local M = {}

-- Node types whose FROM/JOIN sources form a fresh column-resolution scope:
-- a bare or qualified column reference only resolves against the sources
-- collected from the nearest ancestor of one of these types.
local SCOPE_NODE_TYPES = {
  select_core = true, update_statement = true, delete_statement = true,
}

-- Node types that expose "table" and "alias" fields naming a FROM/JOIN source.
local SOURCE_NODE_TYPES = {
  from_clause = true, join_clause = true,
  update_statement = true, delete_statement = true,
}

--- @class TableSource
--- @field alias string|nil    alias bound to this FROM/JOIN item, if any
--- @field name  string|nil    the source's own name, when it has no alias
--- @field path  string[]|nil  `{schema, table}` or `{table}`, or nil when this
---                             source is a derived subquery rather than a real
---                             table — kept so its alias still shadows a bare
---                             column instead of resolving to another table

--- Return the schema/table parts named by `table_ref` (1 or 2 anonymous
--- identifier children: `table` or `schema.table`), or nil for an unsupported shape.
--- @param table_ref userdata
--- @param bufnr     integer
--- @return string[]|nil
local function table_ref_path(table_ref, bufnr)
  local parts = {}
  for child in table_ref:iter_children() do
    if child:named() then table.insert(parts, util.text(child, bufnr)) end
  end
  if #parts == 1 or #parts == 2 then return parts end
  return nil
end

--- Append the source named by `item`'s "table"/"alias" fields to `sources`.
--- When the table field isn't a plain table_ref (a derived subquery), the source
--- is still recorded under its alias, but with `path = nil`, so it correctly
--- shadows rather than resolves.
--- @param sources TableSource[]
--- @param item    userdata  a node exposing "table" and "alias" fields
--- @param bufnr   integer
local function add_source(sources, item, bufnr)
  local table_ref = item:field("table")[1]
  local alias_node = item:field("alias")[1]
  local alias = alias_node and util.text(alias_node, bufnr) or nil
  if table_ref and table_ref:type() == "table_ref" then
    local path = table_ref_path(table_ref, bufnr)
    table.insert(sources, { alias = alias, name = path and path[#path], path = path })
  elseif alias then
    table.insert(sources, { alias = alias, name = nil, path = nil })
  end
end

--- Collect every FROM/JOIN source visible within `scope` (a select_core,
--- update_statement, or delete_statement).
--- @param scope userdata
--- @param bufnr integer
--- @return TableSource[]
local function collect_sources(scope, bufnr)
  local sources = {}
  if scope:type() == "select_core" then
    for from in scope:iter_children() do
      if from:type() == "from_clause" then
        add_source(sources, from, bufnr)
        for child in from:iter_children() do
          if child:type() == "join_clause" then add_source(sources, child, bufnr) end
        end
        break
      end
    end
  else
    add_source(sources, scope, bufnr)
    for child in scope:iter_children() do
      if child:type() == "from_clause" then
        add_source(sources, child, bufnr)
        for gchild in child:iter_children() do
          if gchild:type() == "join_clause" then add_source(sources, gchild, bufnr) end
        end
      end
    end
  end
  return sources
end

--- Return the source in `sources` referred to by qualifier text `name`
--- (matched against its alias, or its own name when it has none).
--- @param sources TableSource[]
--- @param name    string
--- @return TableSource|nil
local function find_source(sources, name)
  for _, s in ipairs(sources) do
    if s.alias == name or (not s.alias and s.name == name) then return s end
  end
end

--- Append the scopes implied by a source's 1- or 2-part path: always its table,
--- plus its schema when the query spells one out.
--- @param path   string[]
--- @param scopes SearchScope[]  appended to in place
local function add_scopes(path, scopes)
  table.insert(scopes, { name = path[#path], type = "table" })
  if #path == 2 then table.insert(scopes, { name = path[1], type = "schema" }) end
end

--- Build a table query from a source's path — either identifier of a
--- `schema.table` reference names the table, scoped by its schema.
--- @param path string[]|nil
--- @return SymbolQuery|nil
local function table_query(path)
  if not path then return nil end
  local scopes = {}
  if #path == 2 then table.insert(scopes, { name = path[1], type = "schema" }) end
  return { name = path[#path], type = "table", scope = scopes }
end

--- Describe the SQL table/column reference under the cursor. Handles:
---   - an identifier naming a table in a FROM/JOIN/INSERT/UPDATE/DELETE target,
---     with or without a schema
---   - an alias identifier on any of those
---   - a qualified column (`alias.col`), scoped to the table its qualifier binds to
---   - a bare column, scoped to every FROM/JOIN source in its statement
---
--- CTEs are not tracked, so a reference to a CTE name is reported as an ordinary
--- table and simply won't be found.
--- @param node  userdata  the named node under the cursor
--- @param bufnr integer
--- @return SymbolQuery|nil
function M.extract(node, bufnr)
  if node:type() ~= "identifier" then return nil end
  local parent = node:parent()
  if not parent then return nil end

  -- Directly on a table/schema identifier of a statement's table reference.
  if parent:type() == "table_ref" then
    return table_query(table_ref_path(parent, bufnr))
  end

  -- On the alias of a FROM/JOIN source or an UPDATE/DELETE target.
  local ptype = parent:type()
  if SOURCE_NODE_TYPES[ptype] then
    if node == parent:field("alias")[1] then
      local table_ref = parent:field("table")[1]
      return table_ref and table_ref:type() == "table_ref"
          and table_query(table_ref_path(table_ref, bufnr)) or nil
    end
    return nil
  end

  if ptype ~= "column_ref" then return nil end

  local scope = util.ancestor(node, SCOPE_NODE_TYPES)
  if not scope then return nil end
  local sources = collect_sources(scope, bufnr)

  local qualifier = parent:field("table")[1]
  if qualifier == node then
    local src = find_source(sources, util.text(node, bufnr))
    return src and table_query(src.path) or nil
  end

  local column_name = util.text(node, bufnr)

  if qualifier then
    local src = find_source(sources, util.text(qualifier, bufnr))
    if not src or not src.path then return nil end
    local scopes = {}
    add_scopes(src.path, scopes)
    return { name = column_name, type = "column", scope = scopes }
  end

  -- Bare column: every FROM/JOIN source is a candidate. Sources in different
  -- schemas widen both scope lists independently, so the backend searches a
  -- superset of the pairs actually written — the extra pairs simply don't
  -- exist, and it reports what it finds.
  if #sources == 0 then return nil end
  local scopes = {}
  for _, s in ipairs(sources) do
    if not s.path then return nil end  -- a derived table/CTE in the mix
    add_scopes(s.path, scopes)
  end
  return { name = column_name, type = "column", scope = scopes }
end

return M
