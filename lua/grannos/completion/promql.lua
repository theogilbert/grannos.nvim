--- Candidates for PromQL buffers: metric names wherever a selector can start,
--- label names inside a selector's braces and in a `by`, `without`, `on`,
--- `ignoring`, `group_left` or `group_right` list, and scrape job names as the
--- value of a `job` matcher. See `grannos.completion` for the language-module
--- contract.
---
--- The repaired buffer is parsed with the promql treesitter grammar and the
--- placeholder's node handed to `grannos.symbols.promql` — the same walk that
--- resolves a hover — which names what the placeholder is and which metrics
--- a label belongs to. Beyond the placeholder, every bracket and string still
--- open is closed before parsing: a selector is completed inside braces that
--- are not closed yet far more often than not, and the grammar only keeps a
--- label under its metric when they are.
local cache   = require("grannos.completion.cache")
local repair  = require("grannos.completion.repair")
local symbols = require("grannos.symbols.promql")

local M = {}

--- "{" opens a selector's matchers and "(" a grouping list or a call's
--- arguments, "," the next entry of either, and a quote a matcher's value —
--- none of them a word character for an engine to fire on.
M.TRIGGER_CHARACTERS = { "{", "(", ",", '"' }

--- Line-comment token, for `repair.close_open`.
local COMMENT = "#"

--- Explore-tree groups. A Prometheus tree is fixed — `metrics` → metric →
--- label, `jobs` → job — so the names are assumed rather than discovered, as
--- `cache.columns` assumes "columns" for SQL.
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

--- @class PromqlCompletionContext
--- @field kind    "metric"|"label"|"job"
--- @field metrics string[]|nil  label kind: the metrics whose labels apply; empty when none is known

--- Describe what should be completed at [start_col, end_col) on `row`.
--- Returns nil when the position names nothing the server can answer.
--- @param bufnr     integer
--- @param row       integer  0-indexed
--- @param start_col integer  0-indexed byte column of the word being completed
--- @param end_col   integer  0-indexed byte column of the cursor
--- @return PromqlCompletionContext|nil
function M.at_cursor(bufnr, row, start_col, end_col)
  local text, col = repair.repaired(bufnr, row, start_col, end_col)
  text = repair.close_open(text, COMMENT)
  local node = repair.node_at(text, "promql", row, col)
  if not node then return nil end

  local sym = symbols.extract(node, text)
  if not sym then return nil end
  if sym.type == "metric" then return { kind = "metric" } end
  if sym.type == "job" then return { kind = "job" } end

  local metrics = {}
  for _, scope in ipairs(sym.scope) do metrics[#metrics + 1] = scope.name end
  return { kind = "label", metrics = metrics }
end

--- Feed the candidates for `ctx` to `add`, starting any fetch it needs.
---
--- A label position with no metric in scope — a bare `{…}` selector, or a
--- grouping list typed before the expression it modifies — offers nothing:
--- Prometheus has no listing of label names across every metric that the
--- tree exposes, and sweeping metrics for one is unbounded.
--- @param conn_id  any
--- @param ctx      PromqlCompletionContext
--- @param add      fun(word: string, kind: string, menu: string)
--- @param on_ready fun()|nil  called once per fetch that completes
function M.candidates(conn_id, ctx, add, on_ready)
  if ctx.kind == "metric" then
    for _, item in ipairs(cache.children(conn_id, { METRICS }, on_ready) or {}) do
      add(item.name, "m", item.type)
    end
  elseif ctx.kind == "job" then
    for _, item in ipairs(cache.children(conn_id, { JOBS }, on_ready) or {}) do
      add(item.name, "j", item.type)
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
