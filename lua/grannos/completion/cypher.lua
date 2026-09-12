--- Candidates for Cypher buffers: labels after `(n:`, relationship types
--- after `-[r:`, property names after `n.` or inside a pattern's map literal,
--- and the variables a statement binds anywhere an expression starts. See
--- `grannos.completion` for the language-module contract.
---
--- The repaired buffer is parsed with the cypher treesitter grammar, and the
--- placeholder's node is handed to `grannos.symbols.cypher` — the same tree
--- walk that resolves a hover — which names what the placeholder is and which
--- label or relationship type its variable binds to. Only the variable
--- position is decided here, because on a placeholder the extractor has
--- nothing to bind.
local cache   = require("grannos.completion.cache")
local config  = require("grannos.config")
local repair  = require("grannos.completion.repair")
local symbols = require("grannos.symbols.cypher")

local M = {}

--- ":" opens a label or relationship type, where there is no word character
--- for an engine to fire on; "." opens a property access.
M.TRIGGER_CHARACTERS = { ".", ":" }

--- Explore-tree group each scope type lives under. A Neo4j tree is fixed —
--- `entities` → label → `properties`, `relationships` → type → `properties` —
--- so the group names are assumed rather than discovered, as `cache.columns`
--- assumes "columns" for SQL.
local GROUPS = {
  label             = "entities",
  relationship_type = "relationships",
}

--- Scope types in the order an unscoped sweep visits them, so a property name
--- two owners share is annotated with the same one every time.
local SWEEP_ORDER = { "label", "relationship_type" }

--- Labels and relationship types are what a pattern completes first, and the
--- two listings are a catalog call each, so fetch them on attach.
--- @param conn_id any
function M.prime(conn_id)
  cache.children(conn_id, { GROUPS.label })
  cache.children(conn_id, { GROUPS.relationship_type })
end

--- @class CypherCompletionContext
--- @field kind      "label"|"relationship_type"|"property"|"variable"
--- @field scopes    SearchScope[]|nil               property kind: what the owning variable binds to; empty when unknown
--- @field variables table<string, SearchScope[]>|nil variable kind: every variable the statement binds

--- Describe what should be completed at [start_col, end_col) on `row`.
--- Returns nil when the position names nothing the graph can answer.
--- @param bufnr     integer
--- @param row       integer  0-indexed
--- @param start_col integer  0-indexed byte column of the word being completed
--- @param end_col   integer  0-indexed byte column of the cursor
--- @return CypherCompletionContext|nil
function M.at_cursor(bufnr, row, start_col, end_col)
  local node, text = repair.placeholder_node(bufnr, "cypher", row, start_col, end_col)
  if not node or node:type() ~= "identifier" then return nil end

  -- A bare word where an expression starts — RETURN |, WHERE |, the variable
  -- half of a pattern — is a variable position. The extractor would only try
  -- to resolve the placeholder to whatever it binds, which is nothing.
  local parent = node:parent()
  if parent and parent:type() == "variable" then
    local variables = symbols.bindings(node, text)
    variables[repair.PLACEHOLDER] = nil
    return { kind = "variable", variables = variables }
  end

  local sym = symbols.extract(node, text)
  if not sym then return nil end
  if sym.type == "property" then
    return { kind = "property", scopes = sym.scope }
  end
  if GROUPS[sym.type] then
    return { kind = sym.type }
  end
  return nil
end

--- Collect property candidates for the scopes a variable binds to.
---
--- A variable no pattern labels — `MATCH (n)`, or one WITH brought in — binds
--- nothing, and then every label and relationship type is a candidate owner.
--- Sweeping them is bounded the way unqualified SQL tables are, since each
--- property listing is a catalog query of its own.
--- @param conn_id  any
--- @param ctx      CypherCompletionContext
--- @param add      fun(word: string, kind: string, menu: string)
--- @param on_ready fun()|nil
local function property_candidates(conn_id, ctx, add, on_ready)
  local scopes = ctx.scopes
  if #scopes == 0 then
    scopes = {}
    for _, kind in ipairs(SWEEP_ORDER) do
      -- Both listings must be in before the bound means anything; a nil here
      -- is a fetch in flight, and its arrival refills the popup.
      local owners = cache.children(conn_id, { GROUPS[kind] }, on_ready)
      if not owners then return end
      for _, item in ipairs(owners) do
        scopes[#scopes + 1] = { name = item.name, type = kind }
      end
    end
    if #scopes > config.options.completion.max_label_scan then return end
  end

  for _, scope in ipairs(scopes) do
    local group = GROUPS[scope.type]
    if group then
      for _, item in ipairs(cache.children(conn_id, { group, scope.name, "properties" }, on_ready) or {}) do
        add(item.name, "p", scope.name)
      end
    end
  end
end

--- Feed the candidates for `ctx` to `add`, starting any fetch it needs.
--- @param conn_id  any
--- @param ctx      CypherCompletionContext
--- @param add      fun(word: string, kind: string, menu: string)
--- @param on_ready fun()|nil  called once per fetch that completes
function M.candidates(conn_id, ctx, add, on_ready)
  if ctx.kind == "variable" then
    for name, scopes in pairs(ctx.variables) do
      local names = {}
      for _, scope in ipairs(scopes) do names[#names + 1] = scope.name end
      add(name, "v", table.concat(names, ", "))
    end
  elseif ctx.kind == "property" then
    property_candidates(conn_id, ctx, add, on_ready)
  else
    for _, item in ipairs(cache.children(conn_id, { GROUPS[ctx.kind] }, on_ready) or {}) do
      add(item.name, ctx.kind == "label" and "l" or "r", item.type)
    end
  end
end

return M
