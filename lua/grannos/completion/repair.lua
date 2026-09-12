--- The placeholder trick every language's completion context is built on.
---
--- A symbol extractor reads a *finished* identifier, and mid-keystroke there
--- usually isn't one: `SELECT u.| FROM users u` has no column to parse, and
--- `MATCH (n:|)` no label. So the buffer is not parsed as written. The partial
--- word is replaced with a placeholder identifier and that repaired *copy* is
--- parsed instead, which turns almost every mid-typing state back into a tree
--- the ordinary symbol analysis understands.
local M = {}

--- Stands in for the word being typed. Lexes as a plain identifier in every
--- grammar completed against, and is unlikely enough to collide with a real
--- name that a match means our own.
M.PLACEHOLDER = "grannos_ph_"

--- Return `bufnr`'s text with [start_col, end_col) on `row` replaced by the
--- placeholder, plus the byte column the placeholder starts at.
--- @param bufnr     integer
--- @param row       integer  0-indexed
--- @param start_col integer  0-indexed byte column
--- @param end_col   integer  0-indexed byte column
--- @return string, integer
function M.repaired(bufnr, row, start_col, end_col)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local line  = lines[row + 1] or ""
  lines[row + 1] = line:sub(1, start_col) .. M.PLACEHOLDER .. line:sub(end_col + 1)
  return table.concat(lines, "\n"), start_col
end

--- Parse the repaired buffer as `lang` and return the deepest named node at
--- the placeholder, along with the repaired text it was parsed from. The text
--- is what node text must be read against — never the buffer, whose word at
--- that position is the half-typed one.
--- @param bufnr     integer
--- @param lang      string   treesitter language
--- @param row       integer  0-indexed
--- @param start_col integer  0-indexed byte column
--- @param end_col   integer  0-indexed byte column
--- @return userdata|nil, string
function M.placeholder_node(bufnr, lang, row, start_col, end_col)
  local text, col = M.repaired(bufnr, row, start_col, end_col)
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok or not parser then return nil, text end
  local tree = parser:parse()[1]
  if not tree then return nil, text end
  return tree:root():named_descendant_for_range(row, col, row, col), text
end

--- Return the index of the placeholder among `parts`, or nil.
--- @param parts string[]
--- @return integer|nil
function M.placeholder_index(parts)
  for i, p in ipairs(parts) do
    if p == M.PLACEHOLDER then return i end
  end
end

return M
