--- Symbol extraction for Cypher buffers. See `grannos.symbols` for the contract.
local util = require("grannos.symbols.util")

local M = {}

-- Pattern nodes that bind a variable, and the node type naming what it binds to.
-- `(n:Person)` binds n to the label Person; `[r:ACTED_IN]` binds r to the
-- relationship type ACTED_IN.
local BINDERS = {
  node_pattern        = { holder = "label_name",        kind = "label" },
  relationship_detail = { holder = "relationship_type", kind = "relationship_type" },
}

local BINDER_TYPES = { node_pattern = true, relationship_detail = true }
local STATEMENT_TYPES = { statement = true }

--- Return the scopes a pattern binds: one per label (or relationship type) it
--- carries. A pattern with no label at all binds nothing, which is not an error
--- — `MATCH (n)` is a perfectly good query, it just cannot narrow a property
--- search to any one label.
--- @param pattern userdata  a node_pattern or relationship_detail
--- @param bufnr   integer
--- @return SearchScope[]
local function pattern_scopes(pattern, bufnr)
  local binder = BINDERS[pattern:type()]
  if not binder then return {} end
  local scopes = {}
  for _, name in ipairs(util.descendant_texts(pattern, binder.holder, bufnr)) do
    table.insert(scopes, { name = name, type = binder.kind })
  end
  return scopes
end

--- Map every variable bound anywhere in `node`'s statement to the scopes its
--- pattern carries — Cypher's equivalent of SQL's alias-to-table bindings.
--- @param node  userdata
--- @param bufnr integer
--- @return table<string, SearchScope[]>
local function bindings(node, bufnr)
  local root = util.ancestor(node, STATEMENT_TYPES) or node:tree():root()
  local out = {}
  local function walk(n)
    if BINDER_TYPES[n:type()] then
      local variable = util.descendant(n, "variable")
      if variable then
        local name = util.text(variable, bufnr)
        local scopes = out[name] or {}
        vim.list_extend(scopes, pattern_scopes(n, bufnr))
        out[name] = scopes
      end
    end
    for child in n:iter_children() do walk(child) end
  end
  walk(root)
  return out
end

--- Return the scopes bound to the variable that owns a property access —
--- `n` in `n.name`. An unbound or unlabelled variable yields no scopes, leaving
--- the backend to search every label; graphs carry few enough labels for that to
--- be a reasonable question to ask, unlike scanning every table in a database.
--- @param owner userdata|nil  the node holding the variable half of the access
--- @param binds table<string, SearchScope[]>
--- @param bufnr integer
--- @return SearchScope[]
local function owner_scopes(owner, binds, bufnr)
  local variable = util.descendant(owner, "variable")
  if not variable then return {} end
  return binds[util.text(variable, bufnr)] or {}
end

--- Describe the Cypher label/relationship-type/property reference under the
--- cursor. Handles:
---   - a label in a node pattern, `(n:Person)`
---   - a relationship type, `-[r:ACTED_IN]->`
---   - a variable, which resolves to whatever its pattern binds it to
---   - a property access, `n.name` or `SET n.age = …`, scoped to the label or
---     relationship type its variable binds to
---   - a property key inside a pattern's map literal, `(n:Person {name: "x"})`
--- @param node  userdata  the named node under the cursor
--- @param bufnr integer
--- @return SymbolQuery|nil
function M.extract(node, bufnr)
  if node:type() ~= "identifier" then return nil end
  local parent = node:parent()
  if not parent then return nil end
  local ptype = parent:type()

  if ptype == "label_name" then
    return { name = util.text(node, bufnr), type = "label", scope = {} }
  end

  if ptype == "relationship_type" then
    return { name = util.text(node, bufnr), type = "relationship_type", scope = {} }
  end

  local binds = bindings(node, bufnr)

  -- On a variable: describe what it binds to, the way a SQL alias resolves to
  -- its table. Ambiguous when its pattern carries several labels.
  if ptype == "variable" then
    local scopes = binds[util.text(node, bufnr)] or {}
    if #scopes ~= 1 then return nil end
    return { name = scopes[1].name, type = scopes[1].type, scope = {} }
  end

  -- A property key in a pattern's map literal — its owner is the pattern itself.
  if ptype == "map_key" then
    local owner = util.ancestor(parent, BINDER_TYPES)
    if not owner then return nil end
    return {
      name  = util.text(node, bufnr),
      type  = "property",
      scope = pattern_scopes(owner, bufnr),
    }
  end

  -- A property access: the property is the identifier following the expression
  -- that names the variable, so an identifier in first position is the variable
  -- half and not a property at all.
  if ptype == "property_expression" or ptype == "expression" then
    local first = parent:named_child(0)
    if not first or first == node then return nil end
    return {
      name  = util.text(node, bufnr),
      type  = "property",
      scope = owner_scopes(first, binds, bufnr),
    }
  end

  return nil
end

return M
