--- FROM/JOIN source analysis for SQL, shared by symbol extraction and completion.
---
--- Both answer the same question — "which tables can a column reference here
--- resolve against, and what does each alias bind to?" — one for the identifier
--- under the cursor, the other for a half-typed word. Keeping one
--- implementation means an alias that hovers correctly also completes
--- correctly.
---
--- Every function takes a treesitter `source`: a bufnr, or the string the tree
--- was parsed from. Completion parses a repaired *copy* of the buffer, so it
--- always passes a string.
local util = require("grannos.symbols.util")

local M = {}

--- Node types whose FROM/JOIN sources form a fresh column-resolution scope:
--- a bare or qualified column reference only resolves against the sources
--- collected from the nearest ancestor of one of these types.
M.SCOPE_NODE_TYPES = {
  select_core = true, update_statement = true, delete_statement = true,
}

--- Node types that expose "table" and "alias" fields naming a FROM/JOIN source.
M.SOURCE_NODE_TYPES = {
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
--- @param source    integer|string
--- @return string[]|nil
function M.table_ref_path(table_ref, source)
  local parts = {}
  for child in table_ref:iter_children() do
    if child:named() then table.insert(parts, util.text(child, source)) end
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
--- @param source  integer|string
local function add_source(sources, item, source)
  local table_ref  = item:field("table")[1]
  local alias_node = item:field("alias")[1]
  local alias = alias_node and util.text(alias_node, source) or nil
  if table_ref and table_ref:type() == "table_ref" then
    local path = M.table_ref_path(table_ref, source)
    table.insert(sources, { alias = alias, name = path and path[#path], path = path })
  elseif alias then
    table.insert(sources, { alias = alias, name = nil, path = nil })
  end
end

--- Collect every FROM/JOIN source visible within `scope` (a select_core,
--- update_statement, or delete_statement).
--- @param scope  userdata
--- @param source integer|string
--- @return TableSource[]
function M.collect_sources(scope, source)
  local sources = {}
  if scope:type() == "select_core" then
    for from in scope:iter_children() do
      if from:type() == "from_clause" then
        add_source(sources, from, source)
        for child in from:iter_children() do
          if child:type() == "join_clause" then add_source(sources, child, source) end
        end
        break
      end
    end
  else
    add_source(sources, scope, source)
    for child in scope:iter_children() do
      if child:type() == "from_clause" then
        add_source(sources, child, source)
        for gchild in child:iter_children() do
          if gchild:type() == "join_clause" then add_source(sources, gchild, source) end
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
function M.find_source(sources, name)
  for _, s in ipairs(sources) do
    if s.alias == name or (not s.alias and s.name == name) then return s end
  end
end

--- Return the node whose FROM/JOIN sources `node` resolves against, or nil.
---
--- Usually the nearest SCOPE_NODE_TYPES ancestor. ORDER BY is the exception:
--- the grammar hangs `order_by_clause` off the select_statement rather than the
--- select_core, so a column there has no select_core ancestor at all and is
--- resolved against the statement's first select_core instead.
--- @param node userdata
--- @return userdata|nil
function M.scope_for(node)
  local n = node
  while n do
    if M.SCOPE_NODE_TYPES[n:type()] then return n end
    if n:type() == "select_statement" then
      for child in n:iter_children() do
        if child:type() == "select_core" then return child end
      end
      return nil
    end
    n = n:parent()
  end
end

return M
