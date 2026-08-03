--- Symbol extraction for PromQL buffers. See `grannos.symbols` for the contract.
local util = require("grannos.symbols.util")

local M = {}

-- The label whose value names a scrape job rather than an arbitrary string, so
-- hovering it resolves to the job node instead of nothing.
local JOB_LABEL = "job"

--- Return the metric a label sits under, by walking outward to the nearest
--- enclosing expression that names one. Covers a label inside a selector's
--- braces, `up{job="api"}`, as well as one in an aggregation modifier,
--- `sum by (job) (up)`, where the metric is a sibling subtree rather than an
--- ancestor's own child.
--- @param node  userdata
--- @param bufnr integer
--- @return SearchScope[]
local function metric_scope(node, bufnr)
  local n = node:parent()
  while n do
    local metric = util.descendant(n, "metric_identifier")
    if metric then return { { name = util.text(metric, bufnr), type = "metric" } } end
    n = n:parent()
  end
  return {}
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
--- @param bufnr integer
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
