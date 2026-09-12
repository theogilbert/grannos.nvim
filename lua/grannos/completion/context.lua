--- Decides what a half-typed word in a SQL buffer should complete to.
---
--- The buffer is parsed with the partial word swapped for a placeholder — see
--- `grannos.completion.repair` — which, measured against the bundled parser,
--- recovers every clause a query buffer completes in: SELECT/WHERE/ON/GROUP
--- BY/HAVING/ORDER BY, JOINs, subqueries, CTEs, UPDATE … SET — including
--- inside a statement whose remainder is still unparseable.
---
--- What it does not recover is an INSERT column list (`INSERT INTO t (|`),
--- which the grammar cannot piece together from a lone open paren; that one
--- shape is matched textually below instead of growing a second parser.
local repair      = require("grannos.completion.repair")
local sources_mod = require("grannos.symbols.sql_sources")
local util        = require("grannos.symbols.util")

local M = {}

--- @class SqlCompletionContext
--- @field kind      "table"|"column"
--- @field schema    string|nil       table kind: schema the reference is qualified with
--- @field qualifier string|nil       column kind: alias or table name before the dot
--- @field sources   TableSource[]    column kind: FROM/JOIN sources in scope

--- Describe a placeholder sitting inside a table reference: a table position,
--- qualified by the schema written to its left when there is one.
--- @param table_ref userdata
--- @param text      string
--- @return SqlCompletionContext
local function table_context(table_ref, text)
  local parts = sources_mod.table_ref_path(table_ref, text) or {}
  local idx   = repair.placeholder_index(parts)
  return { kind = "table", schema = (idx and idx > 1) and parts[idx - 1] or nil }
end

--- Describe a placeholder sitting inside a column reference: a column position,
--- qualified by whatever alias or table name precedes the dot.
--- @param node      userdata  the placeholder identifier
--- @param column_ref userdata
--- @param text      string
--- @return SqlCompletionContext
local function column_context(node, column_ref, text)
  local scope = sources_mod.scope_for(node)
  local srcs  = scope and sources_mod.collect_sources(scope, text) or {}

  -- The `table` field is `sep1(identifier, '.')`, so a fully qualified
  -- `schema.table.col` puts two identifiers in it. The last one names the
  -- source, which is what an alias or bare table name is matched against.
  local qualifier_nodes = column_ref:field("table")
  local qualifier
  for _, qn in ipairs(qualifier_nodes) do
    if qn == node then
      -- Typing the qualifier itself: offer the bare-column candidates, which
      -- include every alias in scope.
      return { kind = "column", qualifier = nil, sources = srcs }
    end
    qualifier = util.text(qn, text)
  end

  return { kind = "column", qualifier = qualifier, sources = srcs }
end

--- Match an INSERT column list ending at the cursor, returning the target
--- table's parts. The grammar cannot recover `INSERT INTO t (` on its own, and
--- this is the only completion position where that is true.
--- @param before string  buffer text up to the cursor
--- @return string[]|nil
local function insert_column_list(before)
  -- An unclosed "(" after INSERT INTO <ref>, containing only a column list.
  local ref, rest = before:match("[iI][nN][sS][eE][rR][tT]%s+[iI][nN][tT][oO]%s+([%w_%.\"]+)%s*%(([^()]*)$")
  if not ref then return nil end
  -- A VALUES/SELECT inside the parens means this is no longer the column list.
  if rest:match("[sS][eE][lL][eE][cC][tT]") then return nil end
  local parts = {}
  for part in ref:gmatch('[^%.]+') do parts[#parts + 1] = (part:gsub('"', "")) end
  return #parts > 0 and parts or nil
end

--- Describe what should be completed at [start_col, end_col) on `row`.
--- Returns nil when the position names neither a table nor a column.
--- @param bufnr     integer
--- @param row       integer  0-indexed
--- @param start_col integer  0-indexed byte column of the word being completed
--- @param end_col   integer  0-indexed byte column of the cursor
--- @return SqlCompletionContext|nil
function M.at_cursor(bufnr, row, start_col, end_col)
  local node, text = repair.placeholder_node(bufnr, "sql", row, start_col, end_col)
  if node then
    -- Walk up only as far as the reference the placeholder belongs to. A
    -- `table_ref` under an ERROR node still classifies correctly, which is
    -- what keeps `INSERT INTO |` working.
    local n = node
    for _ = 1, 3 do
      if not n then break end
      if n:type() == "table_ref" then return table_context(n, text) end
      if n:type() == "column_ref" then return column_context(node, n, text) end
      n = n:parent()
    end
  end

  local lines  = vim.api.nvim_buf_get_lines(bufnr, 0, row + 1, false)
  lines[#lines] = (lines[#lines] or ""):sub(1, start_col)
  local table_parts = insert_column_list(table.concat(lines, "\n"))
  if table_parts then
    local src = { alias = nil, name = table_parts[#table_parts], path = table_parts }
    return { kind = "column", qualifier = nil, sources = { src } }
  end

  return nil
end

return M
