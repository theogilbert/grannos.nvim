--- Symbol extraction for SQL buffers. See `grannos.symbols` for the contract.
--- The FROM/JOIN source analysis lives in `grannos.symbols.sql_sources`, shared
--- with completion so an alias resolves identically in both.
local util    = require("grannos.symbols.util")
local sources = require("grannos.symbols.sql_sources")

local M = {}

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
    return table_query(sources.table_ref_path(parent, bufnr))
  end

  -- On the alias of a FROM/JOIN source or an UPDATE/DELETE target.
  local ptype = parent:type()
  if sources.SOURCE_NODE_TYPES[ptype] then
    if node == parent:field("alias")[1] then
      local table_ref = parent:field("table")[1]
      return table_ref and table_ref:type() == "table_ref"
          and table_query(sources.table_ref_path(table_ref, bufnr)) or nil
    end
    return nil
  end

  if ptype ~= "column_ref" then return nil end

  local scope = sources.scope_for(node)
  if not scope then return nil end
  local srcs = sources.collect_sources(scope, bufnr)

  local qualifier = parent:field("table")[1]
  if qualifier == node then
    local src = sources.find_source(srcs, util.text(node, bufnr))
    return src and table_query(src.path) or nil
  end

  local column_name = util.text(node, bufnr)

  if qualifier then
    local src = sources.find_source(srcs, util.text(qualifier, bufnr))
    if not src or not src.path then return nil end
    local scopes = {}
    add_scopes(src.path, scopes)
    return { name = column_name, type = "column", scope = scopes }
  end

  -- Bare column: every FROM/JOIN source is a candidate. Sources in different
  -- schemas widen both scope lists independently, so the backend searches a
  -- superset of the pairs actually written — the extra pairs simply don't
  -- exist, and it reports what it finds.
  if #srcs == 0 then return nil end
  local scopes = {}
  for _, s in ipairs(srcs) do
    if not s.path then return nil end  -- a derived table/CTE in the mix
    add_scopes(s.path, scopes)
  end
  return { name = column_name, type = "column", scope = scopes }
end

return M
