--- Describes the symbol under the cursor as an `explore.find` query.
---
--- Every extractor here is **purely syntactic**: it reports what the symbol is
--- called, what kind of node it names, and which ancestors the query text pins
--- down. Deciding which database node that actually is belongs to the backend,
--- which alone knows what exists, where each driver keeps each kind of node,
--- and how its catalog cases identifiers.
local M = {}

--- @class SearchScope
--- @field name string  the ancestor's name as written in the query
--- @field type string  node kind: "schema", "table", "database", "collection", "label", …

--- @class SymbolQuery
--- @field name  string         the symbol's name as written in the query
--- @field type  string         node kind being named: "table", "column", "collection", …
--- @field scope SearchScope[]  every ancestor the query text pins down

--- Extractor module per treesitter language. A buffer whose language is absent
--- here has no symbol support and simply never resolves — the same outcome as a
--- cursor sitting on a keyword.
---
--- `json` is MongoDB: its queries are Extended JSON command objects, not a
--- language of their own. Elasticsearch queries are JSON too, but describe no
--- collection or database, so the mongo extractor finds nothing in one and
--- returns nil rather than guessing.
local EXTRACTORS = {
  sql    = "grannos.symbols.sql",
  cypher = "grannos.symbols.cypher",
  promql = "grannos.symbols.promql",
  json   = "grannos.symbols.mongo",
}

--- Describe the symbol under the cursor in `bufnr` as an explore.find query.
--- Returns nil when the buffer has no parser (or none this knows), when the
--- cursor is not on a symbol, or when the query text leaves the symbol
--- genuinely unresolvable — an alias bound to a subquery names no database node.
--- @param bufnr integer
--- @return SymbolQuery|nil
function M.at_cursor(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then return nil end

  local extractor = EXTRACTORS[parser:lang()]
  if not extractor then return nil end

  local tree = parser:parse()[1]
  if not tree then return nil end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local node = tree:root():named_descendant_for_range(row - 1, col, row - 1, col)
  if not node then return nil end

  return require(extractor).extract(node, bufnr)
end

return M
