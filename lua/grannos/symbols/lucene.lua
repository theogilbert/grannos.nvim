--- Symbol extraction for Lucene queries, grannos' Elasticsearch form
--- `<index> | <query_string>`.
---
--- An `index_name` ahead of the pipe names an index or an alias — the query
--- cannot tell which, and Elasticsearch forbids one name for both, so it is
--- searched as an `index`, which the driver finds under either group. A
--- `field_name` (`status` in `status:open`), and the value of `_exists_`,
--- name a field of the indices the query reads.
---
--- A pattern (`logs-*`) names no single node and resolves to nothing; a
--- leading `-` excludes an index but still names it.
local util = require("grannos.symbols.util")

local M = {}

--- The field whose value names a field rather than a value.
local EXISTS = "_exists_"

--- Return `name` with an exclusion's leading `-` dropped, or nil when it is
--- a pattern or empty, naming no single index.
--- @param name string
--- @return string|nil
function M.target_name(name)
  name = name:gsub("^%-", "")
  if name == "" or name:find("[*?]") then return nil end
  return name
end

--- Return the `index` scopes of the targets `names` lists — alternatives,
--- since a field may live in any of them — patterns left out. Exclusions
--- are left out too: their fields are exactly the ones the query cannot see.
--- @param names string[]
--- @return SearchScope[]
function M.target_scopes(names)
  local scopes = {}
  for _, name in ipairs(names) do
    if not name:find("^%-") then
      local target = M.target_name(name)
      if target then scopes[#scopes + 1] = { name = target, type = "index" } end
    end
  end
  return scopes
end

--- Return the index names of the statement `node` is in.
--- @param node  userdata
--- @param bufnr integer
--- @return string[]
local function statement_indices(node, bufnr)
  local stmt = util.ancestor(node, { statement = true })
  local pattern = stmt and stmt:field("index")[1]
  return pattern and util.descendant_texts(pattern, "index_name", bufnr) or {}
end

--- Describe the symbol at `node` as an explore.find query, or nil.
--- @param node  userdata  the named node under the cursor
--- @param bufnr integer
--- @return SymbolQuery|nil
function M.extract(node, bufnr)
  local kind = node:type()
  if kind == "index_name" then
    local name = M.target_name(util.text(node, bufnr))
    return name and { name = name, type = "index", scope = {} } or nil
  end

  local field
  if kind == "field_name" then
    field = util.text(node, bufnr)
  elseif kind == "term" then
    -- `_exists_:user.name` names `user.name`.
    local clause = node:parent()
    local name = clause and clause:type() == "clause" and clause:field("field")[1]
    local value = clause and clause:field("value")[1]
    if name and value and value:id() == node:id() and util.text(name, bufnr) == EXISTS then
      field = util.text(node, bufnr)
    end
  end
  if not field or field == EXISTS or field:find("[*?]") then return nil end
  return {
    name  = field,
    type  = "field",
    scope = M.target_scopes(statement_indices(node, bufnr)),
  }
end

return M
