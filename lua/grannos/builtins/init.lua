--- A language's built-ins — PromQL's functions and aggregation operators —
--- documented for the hover key and offered by completion.
---
--- Every name, signature and description is generated from the language's own
--- repository (`scripts/gen_promql_builtins.py`); nothing here decides what a
--- function does. This module only knows which node names one, and how to lay
--- a docstring out.
local pane = require("grannos.ui.detail_pane")

local M = {}

--- @class Builtin : PromqlBuiltin
--- @field name string
--- @field lang string  treesitter language

--- Per treesitter language: where the generated table lives, and which node
--- refers to a built-in by name.
local LANGUAGES = {
  promql = {
    data = "grannos.builtins.promql",
    --- A call's function name, or an aggregation operator.
    --- @param node   userdata
    --- @param source integer|string
    --- @return string|nil
    name_of = function(node, source)
      local ntype = node:type()
      if ntype == "aggr_op" then
        return vim.treesitter.get_node_text(node, source)
      end
      local parent = node:parent()
      if ntype == "identifier" and parent and parent:type() == "call_expr" then
        local fn = parent:field("function")[1]
        if fn and fn:equal(node) then return vim.treesitter.get_node_text(node, source) end
      end
      return nil
    end,
  },
}

--- Return the built-in `name` of `lang`, or nil.
--- @param lang string  treesitter language
--- @param name string
--- @return Builtin|nil
function M.lookup(lang, name)
  local spec = LANGUAGES[lang]
  if not spec then return nil end
  local entry = require(spec.data).entries[name]
  if not entry then return nil end
  return vim.tbl_extend("force", { name = name, lang = lang }, entry)
end

--- Return every built-in of `lang`, in name order.
--- @param lang string  treesitter language
--- @return Builtin[]
function M.all(lang)
  local spec = LANGUAGES[lang]
  if not spec then return {} end
  local out = {}
  for name, entry in pairs(require(spec.data).entries) do
    out[#out + 1] = vim.tbl_extend("force", { name = name, lang = lang }, entry)
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

--- Return the built-in under the cursor in `bufnr`, or nil when the cursor is
--- not on one — or the buffer's language has none.
--- @param bufnr integer
--- @return Builtin|nil
function M.at_cursor(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then return nil end
  local lang = parser:lang()
  if not LANGUAGES[lang] then return nil end

  local tree = parser:parse()[1]
  if not tree then return nil end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local node = tree:root():named_descendant_for_range(row - 1, col, row - 1, col)
  if not node then return nil end

  local name = LANGUAGES[lang].name_of(node, bufnr)
  return name and M.lookup(lang, name) or nil
end

--- Line shown under a built-in that needs a feature flag.
local EXPERIMENTAL = "experimental — needs --enable-feature=promql-experimental-functions"

--- Lay a built-in out as docstring lines for the hover float: the signature,
--- the description wrapped, an aggregation's general syntax, and the feature
--- flag it needs, if any.
--- @param builtin Builtin
--- @return string[] lines, DetailHlRule[] hls
function M.hover_lines(builtin)
  local lines = { builtin.signature }
  local hls   = { { "GrannosHeaderRow", 0, 0, #builtin.name } }
  if builtin.doc ~= "" then
    lines[#lines + 1] = ""
    vim.list_extend(lines, pane.wrap_lines(builtin.doc, pane.COMMENT_WRAP_WIDTH))
  end
  if builtin.kind == "aggregation" then
    local syntax = require(LANGUAGES[builtin.lang].data).aggregation_syntax
    lines[#lines + 1] = ""
    lines[#lines + 1] = (syntax:gsub("^<aggr%-op>", builtin.name))
  end
  if builtin.experimental then
    lines[#lines + 1] = ""
    lines[#lines + 1] = EXPERIMENTAL
    hls[#hls + 1] = { "GrannosExplorerDim", #lines - 1, 0, #EXPERIMENTAL }
  end
  return lines, hls
end

return M
