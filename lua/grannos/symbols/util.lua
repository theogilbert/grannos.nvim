local M = {}

--- Return the trimmed text of `node`.
--- @param node  userdata
--- @param bufnr integer
--- @return string
function M.text(node, bufnr)
  return vim.trim(vim.treesitter.get_node_text(node, bufnr) or "")
end

--- Return `node` or its nearest ancestor whose type is a key of `types`, or nil.
--- @param node  userdata
--- @param types table<string, boolean>
--- @return userdata|nil
function M.ancestor(node, types)
  local n = node
  while n do
    if types[n:type()] then return n end
    n = n:parent()
  end
end

--- Return the first node of type `wanted` in `node`'s subtree (depth-first,
--- `node` itself included), or nil.
--- @param node   userdata|nil
--- @param wanted string
--- @return userdata|nil
function M.descendant(node, wanted)
  if not node then return nil end
  if node:type() == wanted then return node end
  for child in node:iter_children() do
    local found = M.descendant(child, wanted)
    if found then return found end
  end
end

--- Return the text of every node of type `wanted` in `node`'s subtree.
--- @param node   userdata
--- @param wanted string
--- @param bufnr  integer
--- @return string[]
function M.descendant_texts(node, wanted, bufnr)
  local out = {}
  local function walk(n)
    if n:type() == wanted then table.insert(out, M.text(n, bufnr)) end
    for child in n:iter_children() do walk(child) end
  end
  walk(node)
  return out
end

return M
