--- Candidates for PromQL buffers: metric names, functions and aggregation
--- operators wherever an expression can start, label names inside a
--- selector's braces and in a `by`, `without`, `on`, `ignoring`, `group_left`
--- or `group_right` list, and a matcher's value: the label's values for the
--- selector's metric, or scrape job names for a `job` matcher with no metric
--- to scope it. See `grannos.completion` for the language-module contract.
---
--- The repaired buffer is parsed with the promql treesitter grammar and the
--- placeholder's node handed to `grannos.symbols.promql` — the same walk that
--- resolves a hover — which names what the placeholder is and which metrics
--- a label belongs to. Beyond the placeholder, every bracket and string still
--- open is closed before parsing: a selector is completed inside braces that
--- are not closed yet far more often than not, and the grammar only keeps a
--- label under its metric when they are.
local builtins = require("grannos.builtins")
local cache    = require("grannos.completion.cache")
local repair   = require("grannos.completion.repair")
local symbols  = require("grannos.symbols.promql")

local M = {}

--- "{" opens a selector's matchers and "(" a grouping list or a call's
--- arguments, "," the next entry of either, and a quote a matcher's value —
--- none of them a word character for an engine to fire on.
M.TRIGGER_CHARACTERS = { "{", "(", ",", '"' }

--- Line-comment token, for `repair.close_open`.
local COMMENT = "#"

--- Explore-tree groups. A Prometheus tree is fixed — `metrics` → metric →
--- label → value, `jobs` → job — so the names are assumed rather than
--- discovered, as `cache.columns` assumes "columns" for SQL.
local METRICS = "metrics"
local JOBS    = "jobs"

--- Metrics are what nearly every position completes and jobs the one label
--- value that can be, and each listing is a single API call, so fetch both
--- on attach.
--- @param conn_id any
function M.prime(conn_id)
  cache.children(conn_id, { METRICS })
  cache.children(conn_id, { JOBS })
end

--- Return the byte column just past the quote opening the string `col` sits
--- inside on `line`, or nil when it sits in none. A comment ends the scan:
--- nothing after it is code.
--- @param line string
--- @param col  integer  0-indexed byte column of the cursor
--- @return integer|nil
local function string_start(line, col)
  local quote, start, i = nil, nil, 1
  while i <= col do
    local ch = line:sub(i, i)
    if quote then
      if ch == "\\" and quote ~= "`" then i = i + 1
      elseif ch == quote then quote = nil end
    elseif ch == '"' or ch == "'" or ch == "`" then
      quote, start = ch, i
    elseif ch == COMMENT then
      return nil
    end
    i = i + 1
  end
  return quote and start or nil
end

--- Return the byte column where the word ending at `col` starts.
---
--- Colons are word characters: a recording rule's name carries them
--- (`node:cpu:rate5m`) and completing only the part after the last would
--- match nothing. Inside a string the word is everything since the opening
--- quote, because a job name is free text — `node-exporter` — and a prefix cut
--- at its hyphen would filter every candidate out.
--- @param line string
--- @param col  integer  0-indexed byte column of the cursor
--- @return integer
function M.word_start(line, col)
  local start = string_start(line, col)
  if start then return start end
  start = col
  while start > 0 and line:sub(start, start):match("[%w_:]") do
    start = start - 1
  end
  return start
end

--- Return the first and last row of the query `row` is in: PromQL has no
--- statement terminator, so a query is the block of lines between blank
--- (whitespace-only) lines, as the grammar's separator defines it.
--- @param bufnr integer
--- @param row   integer  0-indexed
--- @return integer, integer  0-indexed, inclusive
local function query_rows(bufnr, row)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local first, last = row, row
  while first > 0 and lines[first]:match("%S") do first = first - 1 end
  while last < #lines - 1 and lines[last + 2]:match("%S") do last = last + 1 end
  return first, last
end

--- Built-in functions and aggregation operators as candidates, laid out once:
--- the list is static and every metric position offers it.
local BUILTIN_ITEMS = nil

--- @return { word: string, kind: string, menu: string, info: string }[]
local function builtin_items()
  if not BUILTIN_ITEMS then
    BUILTIN_ITEMS = {}
    for _, b in ipairs(builtins.all("promql")) do
      BUILTIN_ITEMS[#BUILTIN_ITEMS + 1] = {
        word = b.name,
        kind = b.kind == "function" and "f" or "o",
        menu = b.kind,
        info = table.concat((builtins.hover_lines(b)), "\n"),
      }
    end
  end
  return BUILTIN_ITEMS
end

--- @class PromqlCompletionContext
--- @field kind    "metric"|"label"|"label_value"|"job"   metric: anywhere an expression starts, built-ins included
--- @field metrics string[]|nil  label and label_value kinds: the metrics in scope; empty when none is known
--- @field label   string|nil    label_value kind: the label whose value is typed

--- Return the names of `scopes`.
--- @param scopes SearchScope[]
--- @return string[]
local function names(scopes)
  local out = {}
  for _, scope in ipairs(scopes) do out[#out + 1] = scope.name end
  return out
end

--- Describe what should be completed at [start_col, end_col) on `row`.
--- Returns nil when the position names nothing the server can answer.
--- @param bufnr     integer
--- @param row       integer  0-indexed
--- @param start_col integer  0-indexed byte column of the word being completed
--- @param end_col   integer  0-indexed byte column of the cursor
--- @return PromqlCompletionContext|nil
function M.at_cursor(bufnr, row, start_col, end_col)
  -- The cursor's query alone: a closer appended past its end would land in
  -- the next query rather than close this one.
  local first, last = query_rows(bufnr, row)
  local text, col = repair.repaired(bufnr, row, start_col, end_col, first, last)
  text = repair.close_open(text, COMMENT)
  local node = repair.node_at(text, "promql", row - first, col)
  if not node then return nil end

  -- A matcher's value. The tree lists a label's values under its metric, so
  -- with one in scope those are offered whatever the label; the `jobs` group
  -- — every scrape job — is the fallback for a `job` matcher with none.
  local parent = node:parent()
  if node:type() == "string_literal" and parent and parent:type() == "label_matcher" then
    local name_node = parent:field("name")[1]
    local label     = name_node and vim.treesitter.get_node_text(name_node, text)
    if not label then return nil end
    local metrics = names(symbols.metric_scope(node, text))
    if #metrics > 0 then return { kind = "label_value", label = label, metrics = metrics } end
    local sym = symbols.extract(node, text)
    return sym and sym.type == "job" and { kind = "job" } or nil
  end

  local sym = symbols.extract(node, text)
  if not sym then return nil end
  if sym.type == "metric" then return { kind = "metric" } end
  return { kind = "label", metrics = names(sym.scope) }
end

--- Feed the candidates for `ctx` to `add`, starting any fetch it needs.
---
--- A label position with no metric in scope — a bare `{…}` selector, or a
--- grouping list typed before the expression it modifies — offers nothing:
--- Prometheus has no listing of label names across every metric that the
--- tree exposes, and sweeping metrics for one is unbounded.
--- @param conn_id  any
--- @param ctx      PromqlCompletionContext
--- @param add      fun(word: string, kind: string, menu: string, info: string|nil)
--- @param on_ready fun()|nil  called once per fetch that completes
function M.candidates(conn_id, ctx, add, on_ready)
  if ctx.kind == "metric" then
    for _, item in ipairs(cache.children(conn_id, { METRICS }, on_ready) or {}) do
      add(item.name, "m", item.type)
    end
    -- A function or aggregation is written where a metric is, and its
    -- documentation rides along as the popup's preview.
    for _, b in ipairs(builtin_items()) do add(b.word, b.kind, b.menu, b.info) end
  elseif ctx.kind == "job" then
    for _, item in ipairs(cache.children(conn_id, { JOBS }, on_ready) or {}) do
      add(item.name, "j", item.type)
    end
  elseif ctx.kind == "label_value" then
    for _, metric in ipairs(ctx.metrics) do
      for _, item in ipairs(cache.children(conn_id, { METRICS, metric, ctx.label }, on_ready) or {}) do
        add(item.name, "e", ctx.label)
      end
    end
  else
    for _, metric in ipairs(ctx.metrics) do
      for _, item in ipairs(cache.children(conn_id, { METRICS, metric }, on_ready) or {}) do
        add(item.name, "l", metric)
      end
    end
  end
end

return M
