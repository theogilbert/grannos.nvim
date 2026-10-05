--- A language's built-ins — PromQL's functions and aggregation operators,
--- MongoDB's stages and operators — documented for the hover key and offered
--- by completion.
---
--- Every name, signature and description is generated from the language's own
--- repository (`scripts/gen_promql_builtins.py`, `scripts/gen_mongo_builtins.py`);
--- nothing here decides what a function does. This module only knows which
--- node names one, and how to lay a docstring out.
---
--- A language whose names mean different things in different places (Mongo's
--- `$set` is a stage and an update operator) keys its table by category; the
--- node then says which categories it may name, most specific first.
local pane    = require("grannos.ui.detail_pane")
local symbols = require("grannos.symbols.mongo")

local M = {}

--- @class Builtin : PromqlBuiltin, MongoBuiltin
--- @field name     string
--- @field lang     string       treesitter language
--- @field category string|nil  for a language keyed by category: the one it came from

--- Line shown under a PromQL built-in that needs a feature flag.
local EXPERIMENTAL = "experimental — needs --enable-feature=promql-experimental-functions"

--- Return the key under the cursor's `string_content` node when it names a
--- Mongo operator — a `$` key nested in a command's argument — and the
--- categories it may name there; nil otherwise. Mirrors `symbols.mongo.extract`
--- in requiring an operation key, so a `.json` file that is no Mongo command
--- names nothing.
--- @param node   userdata
--- @param source integer|string
--- @return string|nil name, string[]|nil categories
local function mongo_operator(node, source)
  if node:type() ~= "string_content" then return nil end
  local name = vim.treesitter.get_node_text(node, source)
  if name:sub(1, 1) ~= "$" then return nil end
  local str  = node:parent()
  local pair = str and str:parent()
  if not pair or pair:type() ~= "pair" or not pair:field("key")[1]:equal(str) then return nil end

  local object  = pair:parent()
  local command = symbols.command_object(object)
  if not command or select(2, symbols.command_target(command, source)) == nil then return nil end
  local argument = symbols.argument_pair(object, command)
  if not argument then return nil end
  local categories = symbols.key_categories(object, argument, source)
  if not categories or #categories == 0 then return nil end
  return name, categories
end

--- Lay a Mongo operator out: its signature, the description, each documented
--- argument with its description indented under it, and a dim footer naming
--- the category and the first MongoDB version that has it.
--- @param builtin Builtin
--- @return string[] lines, DetailHlRule[] hls
local function mongo_hover_lines(builtin)
  local lines = { builtin.signature }
  local hls   = { { "GrannosHeaderRow", 0, 0, #builtin.name } }
  if builtin.doc ~= "" then
    lines[#lines + 1] = ""
    vim.list_extend(lines, pane.wrap_lines(builtin.doc, pane.COMMENT_WRAP_WIDTH))
  end
  for _, arg in ipairs(builtin.args) do
    lines[#lines + 1] = ""
    local label = arg.name .. (arg.optional and " (optional)" or "")
    lines[#lines + 1] = label
    hls[#hls + 1] = { "GrannosHeaderRow", #lines - 1, 0, #arg.name }
    for _, line in ipairs(pane.wrap_lines(arg.doc, pane.COMMENT_WRAP_WIDTH - 2)) do
      lines[#lines + 1] = line == "" and "" or "  " .. line
    end
  end
  local footer = builtin.category .. " · MongoDB " .. builtin.min_version .. "+"
  lines[#lines + 1] = ""
  lines[#lines + 1] = footer
  hls[#hls + 1] = { "GrannosExplorerDim", #lines - 1, 0, #footer }
  return lines, hls
end

--- Lay a PromQL built-in out: the signature, the description wrapped, an
--- aggregation's general syntax, and the feature flag it needs, if any.
--- @param builtin Builtin
--- @return string[] lines, DetailHlRule[] hls
local function promql_hover_lines(builtin)
  local lines = { builtin.signature }
  local hls   = { { "GrannosHeaderRow", 0, 0, #builtin.name } }
  if builtin.doc ~= "" then
    lines[#lines + 1] = ""
    vim.list_extend(lines, pane.wrap_lines(builtin.doc, pane.COMMENT_WRAP_WIDTH))
  end
  if builtin.kind == "aggregation" then
    local syntax = require("grannos.builtins.promql").aggregation_syntax
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

--- The Mongo spec: `.mongo` buffers, and `.json` query files from before
--- `.mongo` existed (as `grannos.symbols` registers them).
local MONGO = {
  data        = "grannos.builtins.mongo",
  name_of     = mongo_operator,
  hover_lines = mongo_hover_lines,
}

--- Per treesitter language: where the generated table lives (a flat
--- `entries` table, or `categories` of them), which node refers to a
--- built-in by name — and, for a categorized table, which categories that
--- node may name — and how to lay its docstring out.
local LANGUAGES = {
  mongo = MONGO,
  json  = MONGO,
  promql = {
    data        = "grannos.builtins.promql",
    hover_lines = promql_hover_lines,
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

--- Return the built-in `name` of `lang`, or nil. For a language keyed by
--- category, the first of `categories` (default: every one) that has it.
--- @param lang       string         treesitter language
--- @param name       string
--- @param categories string[]|nil
--- @return Builtin|nil
function M.lookup(lang, name, categories)
  local spec = LANGUAGES[lang]
  if not spec then return nil end
  local data = require(spec.data)
  if not data.categories then
    local entry = data.entries[name]
    return entry and vim.tbl_extend("force", { name = name, lang = lang }, entry) or nil
  end
  for _, category in ipairs(categories or vim.tbl_keys(data.categories)) do
    local entry = (data.categories[category] or {})[name]
    if entry then
      return vim.tbl_extend("force", { name = name, lang = lang, category = category }, entry)
    end
  end
  return nil
end

--- Return every built-in of `lang` — of its `category`, for a language keyed
--- by category — in name order.
--- @param lang     string       treesitter language
--- @param category string|nil
--- @return Builtin[]
function M.all(lang, category)
  local spec = LANGUAGES[lang]
  if not spec then return {} end
  local data = require(spec.data)
  local entries = data.categories and (data.categories[category] or {}) or data.entries
  local out = {}
  for name, entry in pairs(entries) do
    out[#out + 1] = vim.tbl_extend("force", { name = name, lang = lang, category = category }, entry)
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

  local name, categories = LANGUAGES[lang].name_of(node, bufnr)
  return name and M.lookup(lang, name, categories) or nil
end

--- Lay a built-in out as docstring lines for the hover float, in its
--- language's layout.
--- @param builtin Builtin
--- @return string[] lines, DetailHlRule[] hls
function M.hover_lines(builtin)
  return LANGUAGES[builtin.lang].hover_lines(builtin)
end

return M
