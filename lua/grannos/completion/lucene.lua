--- Candidates for Lucene buffers — grannos' Elasticsearch query form,
--- `<index> | <query_string>`: index names ahead of the pipe, and the fields
--- of those indices wherever a clause may start after it. See
--- `grannos.completion` for the language-module contract.
---
--- The two halves are told apart textually, on the cut the driver itself
--- makes: everything before the first pipe of the query is the index part.
--- That also serves the half where the tree is no help — an index typed
--- alone has no pipe yet, and the grammar can only report an error for it.
--- After the pipe the repaired buffer is parsed with the lucene treesitter
--- grammar and the placeholder's clause decides: a bare term is where a field
--- may be named (`sta` on its way to `status:open`), the term ahead of a
--- colon is one, and so is the value of `_exists_`; the value of any other
--- field is free text the tree has no listing for, and offers nothing.
local cache  = require("grannos.completion.cache")
local repair = require("grannos.completion.repair")

local M = {}

--- ":" ends a field name — nothing an engine fires on follows it, but after
--- `_exists_:` a field is what comes next. "(" opens a group and "," the
--- next index of a pattern list, neither a word character.
M.TRIGGER_CHARACTERS = { ":", "(", "," }

--- Line-comment token, for `repair.close_open`.
local COMMENT = "--"

--- Explore-tree group holding an index's fields. The Elasticsearch tree is
--- fixed — index → `mappings` → field — so the name is assumed rather than
--- discovered, as `cache.columns` assumes "columns" for SQL.
local MAPPINGS = "mappings"

--- The field whose value names a field rather than a value.
local EXISTS = "_exists_"

--- Index names are what every query starts with and one listing away, so
--- fetch them on attach. Fields need an index first.
--- @param conn_id any
function M.prime(conn_id)
  cache.children(conn_id, {})
end

--- Return the byte column where the word ending at `col` starts.
---
--- A field path is dotted (`user.name`), a time field starts with `@`, and
--- an index name carries dashes, dots and a wildcard (`logs-2024.*`), so all
--- of those are word characters. A dash *leading* the word is not: it is the
--- prohibit modifier on a clause, or an exclusion in an index list, and
--- `-fie` should complete `fie`.
--- @param line string
--- @param col  integer  0-indexed byte column of the cursor
--- @return integer
function M.word_start(line, col)
  local start = col
  while start > 0 and line:sub(start, start):match("[%w_.@*%-]") do
    start = start - 1
  end
  while start < col and line:sub(start + 1, start + 1) == "-" do
    start = start + 1
  end
  return start
end

--- Return the first and last row of the query `row` is in: Lucene has no
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

--- Return the index part of the query spanning `lines`, and whether
--- (`row`, `col`) sits inside it: the text ahead of the query's first pipe,
--- comment lines skipped. The whole query is the index part when it has no
--- pipe yet.
--- @param lines string[]
--- @param row   integer  0-indexed, relative to `lines`
--- @param col   integer  0-indexed byte column
--- @return string, boolean
local function index_part(lines, row, col)
  local parts = {}
  for i, line in ipairs(lines) do
    if not line:match("^%s*" .. vim.pesc(COMMENT)) then
      local pipe = line:find("|", 1, true)
      if pipe then
        parts[#parts + 1] = line:sub(1, pipe - 1)
        local inside = row < i - 1 or (row == i - 1 and col < pipe)
        return table.concat(parts, " "), inside
      end
      parts[#parts + 1] = line
    end
  end
  return table.concat(parts, " "), true
end

--- Return the index names an index part lists, wildcards and all, an
--- exclusion left out: there is nothing to list under one.
--- @param text string
--- @return string[]
local function index_names(text)
  local names = {}
  for name in text:gmatch("[^%s,]+") do
    if name:sub(1, 1) ~= "-" then names[#names + 1] = name end
  end
  return names
end

--- @class LuceneCompletionContext
--- @field kind    "index"|"field"
--- @field indices string[]|nil  field kind: the indices the query reads; empty when none is named yet

--- Return the clause `node` is the value of, or nil when it is something
--- else — a field name, a range bound, a group's inner clause.
--- @param node userdata
--- @return userdata|nil
local function clause_of_value(node)
  local parent = node:parent()
  if not parent or parent:type() ~= "clause" then return nil end
  local value = parent:field("value")[1]
  return value and value:id() == node:id() and parent or nil
end

--- Return the name of the field `clause` restricts, or nil when it has none.
--- @param clause userdata
--- @param text   string  the text `clause` was parsed from
--- @return string|nil
local function field_of(clause, text)
  local name = clause:field("field")[1]
  return name and vim.treesitter.get_node_text(name, text) or nil
end

--- Return true when `node` sits inside the value of a field clause, at any
--- depth: `title:(quick OR |)` completes a value of `title`, not a field.
--- @param node userdata
--- @param text string
--- @return boolean
local function inside_field_value(node, text)
  local n = node:parent()
  while n do
    if n:type() == "clause" and field_of(n, text) then return true end
    n = n:parent()
  end
  return false
end

--- Return true when the placeholder at `node` is where a field may be named.
--- @param node userdata  the deepest named node at the placeholder
--- @param text string    the repaired text it was parsed from
--- @return boolean
local function names_field(node, text)
  if node:type() == "field_name" then return true end
  if node:type() ~= "term" then return false end
  local clause = clause_of_value(node)
  if not clause then return false end
  local field = field_of(clause, text)
  if field then return field == EXISTS end
  return not inside_field_value(clause, text)
end

--- Describe what should be completed at [start_col, end_col) on `row`.
--- Returns nil when the position names nothing the server can answer.
--- @param bufnr     integer
--- @param row       integer  0-indexed
--- @param start_col integer  0-indexed byte column of the word being completed
--- @param end_col   integer  0-indexed byte column of the cursor
--- @return LuceneCompletionContext|nil
function M.at_cursor(bufnr, row, start_col, end_col)
  -- The cursor's query alone: a closer appended past its end would land in
  -- the next query rather than close this one.
  local first, last = query_rows(bufnr, row)
  local lines = vim.api.nvim_buf_get_lines(bufnr, first, last + 1, false)
  local index, inside = index_part(lines, row - first, start_col)
  if inside then return { kind = "index" } end

  local text, col = repair.repaired(bufnr, row, start_col, end_col, first, last)
  text = repair.close_open(text, COMMENT)
  local node = repair.node_at(text, "lucene", row - first, col)
  if not node or not names_field(node, text) then return nil end
  return { kind = "field", indices = index_names(index) }
end

--- Feed the candidates for `ctx` to `add`, starting any fetch it needs.
---
--- Fields come from the mappings of every index the query names, a pattern
--- or alias passed through as written — the server merges what it matches.
--- @param conn_id  any
--- @param ctx      LuceneCompletionContext
--- @param add      fun(word: string, kind: string, menu: string, info: string|nil)
--- @param on_ready fun()|nil  called once per fetch that completes
function M.candidates(conn_id, ctx, add, on_ready)
  if ctx.kind == "index" then
    for _, item in ipairs(cache.children(conn_id, {}, on_ready) or {}) do
      add(item.name, "i", item.type)
    end
  else
    for _, index in ipairs(ctx.indices) do
      for _, item in ipairs(cache.children(conn_id, { index, MAPPINGS }, on_ready) or {}) do
        add(item.name, "f", item.type)
      end
    end
  end
end

return M
