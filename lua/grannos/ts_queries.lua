local M = {}

-- Node types that represent write operations across SQL and Cypher grammars.
local WRITE_NODE_TYPES = {
  insert_statement     = true, update_statement      = true,
  delete_statement     = true, merge_statement        = true,
  create_statement     = true, create_table           = true,
  create_table_as      = true, create_index           = true,
  create_view          = true, drop_statement         = true,
  drop_table           = true, drop_index             = true,
  drop_view            = true, alter_statement        = true,
  alter_table          = true, truncate_statement     = true,
  create_clause        = true, merge_clause           = true,
  delete_clause        = true, detach_delete_clause   = true,
  set_clause           = true, remove_clause          = true,
}

--- Recursively check whether `node` or any descendant is a write operation.
--- @param node userdata
--- @return boolean
local function node_has_write(node)
  if WRITE_NODE_TYPES[node:type()] then return true end
  for child in node:iter_children() do
    if node_has_write(child) then return true end
  end
  return false
end

--- @class SqlStatement
--- @field text      string   query text with trailing semicolons stripped
--- @field start_row integer  0-indexed start row
--- @field start_col integer  0-indexed start byte column
--- @field end_row   integer  0-indexed end row
--- @field end_col   integer  0-indexed end byte column

--- Return the treesitter parser for `bufnr`, or nil if one is not available.
--- @param bufnr integer
--- @return userdata|nil
local function get_parser(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  return ok and parser or nil
end

--- Return the trimmed text of `node` with trailing semicolons removed.
--- @param node userdata
--- @param bufnr integer
--- @return string
local function node_text(node, bufnr)
  local text = vim.treesitter.get_node_text(node, bufnr) or ""
  return vim.trim(text:gsub(";%s*$", ""))
end

--- Return true when any statement overlapping [start_row, end_row] contains a write node.
--- Returns false when treesitter is unavailable or no write is found.
--- @param bufnr     integer
--- @param start_row integer  0-indexed
--- @param end_row   integer  0-indexed
--- @return boolean
function M.has_write_statement(bufnr, start_row, end_row)
  local parser = get_parser(bufnr)
  if not parser then return false end
  local tree = parser:parse()[1]
  if not tree then return false end
  for node in tree:root():iter_children() do
    if node:type() == "statement" then
      local sr, _, er, _ = node:range()
      if sr <= end_row and er >= start_row then
        if node_has_write(node) then return true end
      end
    end
  end
  return false
end

--- Return the outermost statement node containing the cursor, or nil.
--- Result fields: text, start_row, start_col, end_row, end_col (all 0-indexed).
--- @param bufnr integer
--- @return SqlStatement|nil
function M.statement_at_cursor(bufnr)
  local parser = get_parser(bufnr)
  if not parser then return nil end
  local tree = parser:parse()[1]
  if not tree then return nil end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1  -- 0-indexed

  local node = tree:root():named_descendant_for_range(row, col, row, col)
  if not node then return nil end

  -- Walk up, keeping track of the highest 'statement' ancestor found.
  local stmt = nil
  local n = node
  while n do
    if n:type() == "statement" then stmt = n end
    n = n:parent()
  end
  if not stmt then return nil end

  local text = node_text(stmt, bufnr)
  if text == "" then return nil end

  local sr, sc, er, ec = stmt:range()
  return { text = text, start_row = sr, start_col = sc, end_row = er, end_col = ec }
end

--- Return every top-level statement that overlaps [start_row, end_row] (0-indexed inclusive).
--- Returns nil when treesitter is unavailable or the tree cannot be parsed.
--- @param bufnr    integer
--- @param start_row integer  0-indexed
--- @param end_row   integer  0-indexed
--- @return SqlStatement[]|nil
function M.statements_in_range(bufnr, start_row, end_row)
  local parser = get_parser(bufnr)
  if not parser then return nil end
  local tree = parser:parse()[1]
  if not tree then return nil end

  local stmts = {}
  for node in tree:root():iter_children() do
    if node:type() == "statement" then
      local sr, sc, er, ec = node:range()
      if sr <= end_row and er >= start_row then
        local text = node_text(node, bufnr)
        if text ~= "" then
          table.insert(stmts, { text = text, start_row = sr, start_col = sc, end_row = er, end_col = ec })
        end
      end
    end
  end

  return #stmts > 0 and stmts or nil
end

return M
