--- Symbol extraction for PromQL buffers. See `grannos.symbols` for the contract.
local util = require("grannos.symbols.util")

local M = {}

-- The label whose value names a scrape job rather than an arbitrary string, so
-- hovering it resolves to the job node instead of nothing.
local JOB_LABEL = "job"

--- Node types that end the search for the expression a grouping list
--- modifies: an unfinished query's error node holds nothing the list can
--- apply to, and the file root would only ever offer unrelated queries.
local SCOPE_STOP = { ERROR = true, source_file = true }

--- Return the metrics a label belongs to, as scopes.
---
--- A label inside a selector's braces, `up{job="api"}`, belongs to that
--- selector's metric and nothing else; a bare `{...}` selector gives it none.
--- A label in a grouping list — `sum by (job) (…)`, `a / on (job) b` —
--- belongs to every metric of the expression the list modifies, which is the
--- nearest enclosing one that names any: `explore.find` treats scopes of one
--- type as alternatives, so `sum by (job) (a + b)` may resolve under either.
--- @param node  userdata  the label's identifier node
--- @param bufnr integer|string  buffer, or the text the node was parsed from
--- @return SearchScope[]
local function metric_scope(node, bufnr)
  local list = util.ancestor(node, { label_matchers = true, label_list_paren = true })
  if not list then return {} end
  local names = {}
  if list:type() == "label_matchers" then
    local selector = list:parent()
    local metric   = selector and selector:field("metric")[1]
    if metric then names = { util.text(metric, bufnr) } end
  else
    local n = list:parent()
    while n and #names == 0 and not SCOPE_STOP[n:type()] do
      names = util.descendant_texts(n, "metric_identifier", bufnr)
      n = n:parent()
    end
  end
  local scopes = {}
  for _, name in ipairs(names) do
    scopes[#scopes + 1] = { name = name, type = "metric" }
  end
  return scopes
end

--- Return a quoted PromQL string's contents.
--- @param text string
--- @return string
local function unquote(text)
  return text:match('^"(.*)"$') or text:match("^'(.*)'$") or text
end

--- Describe the PromQL metric/label/job reference under the cursor. Handles:
---   - a metric name, bare or inside a call: `up`, `rate(http_requests_total[5m])`
---   - a label name in a selector or an aggregation modifier, scoped to its metric
---   - the value of a `job="…"` matcher, which names a scrape job
--- @param node  userdata  the named node under the cursor
--- @param bufnr integer|string  buffer, or the text the node was parsed from
--- @return SymbolQuery|nil
function M.extract(node, bufnr)
  local ntype = node:type()

  if ntype == "metric_identifier" then
    return { name = util.text(node, bufnr), type = "metric", scope = {} }
  end

  local parent = node:parent()
  if not parent then return nil end

  if ntype == "identifier" and parent:type() == "label_name" then
    return {
      name  = util.text(node, bufnr),
      type  = "label",
      scope = metric_scope(node, bufnr),
    }
  end

  if ntype == "string_literal" and parent:type() == "label_matcher" then
    local name_node = parent:field("name")[1]
    if name_node and util.text(name_node, bufnr) == JOB_LABEL then
      return { name = unquote(util.text(node, bufnr)), type = "job", scope = {} }
    end
  end

  return nil
end

return M
