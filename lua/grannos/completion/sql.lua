--- Candidates for SQL buffers: table names after FROM/JOIN/INTO, and column
--- names in every position that resolves against them, including through
--- aliases. See `grannos.completion` for the language-module contract.
local cache   = require("grannos.completion.cache")
local config  = require("grannos.config")
local context = require("grannos.completion.context")

local M = {}

--- After `alias.` there is no word character for an engine's own keyword
--- matching to fire on, and that is exactly the position where the qualified
--- column list is most wanted.
M.TRIGGER_CHARACTERS = { "." }

--- One list call, so the tree's shape and its top level are known before the
--- first keystroke that needs them.
--- @param conn_id any
function M.prime(conn_id)
  cache.children(conn_id, {})
end

--- Describe what should be completed at [start_col, end_col) on `row`.
--- @param bufnr     integer
--- @param row       integer  0-indexed
--- @param start_col integer  0-indexed byte column of the word being completed
--- @param end_col   integer  0-indexed byte column of the cursor
--- @return SqlCompletionContext|nil
function M.at_cursor(bufnr, row, start_col, end_col)
  return context.at_cursor(bufnr, row, start_col, end_col)
end

--- Resolve a source's query-text path to a full explore-tree path.
---
--- A query naming a table without its schema (`FROM users`) doesn't say where
--- the table lives, so on a driver with schemas the schemas are searched for
--- it. An unambiguous single hit wins; anything else yields nil rather than a
--- guess, and the position simply offers nothing.
---
--- The search lists every schema, so it is bounded by `max_schema_scan` as
--- the unqualified table sweep is: past the bound an unqualified table is not
--- resolved — qualifying it (`schema.table`) lists just the one — because one
--- keystroke must never turn into a listing per schema.
--- @param conn_id  any
--- @param path     string[]  1 or 2 parts, as written in the query
--- @param on_ready fun()|nil
--- @return string[]|nil
local function resolve_table_path(conn_id, path, on_ready)
  local has_schemas = cache.has_schemas(conn_id, on_ready)
  if has_schemas == nil then return nil end
  if #path >= 2 or not has_schemas then return path end

  local root = cache.children(conn_id, {}, on_ready) or {}
  if #root > config.options.completion.max_schema_scan then return nil end

  local wanted, found = path[1]:lower(), nil
  for _, schema in ipairs(root) do
    for _, item in ipairs(cache.children(conn_id, { schema.name }, on_ready) or {}) do
      if item.name:lower() == wanted then
        if found then return nil end  -- same table name in two schemas
        found = { schema.name, item.name }
      end
    end
  end
  return found
end

--- Collect table-name candidates for a FROM/JOIN/INTO position.
--- @param conn_id  any
--- @param ctx      SqlCompletionContext
--- @param add      fun(word: string, kind: string, menu: string)
--- @param on_ready fun()|nil
local function table_candidates(conn_id, ctx, add, on_ready)
  if ctx.schema then
    for _, item in ipairs(cache.children(conn_id, { ctx.schema }, on_ready) or {}) do
      add(item.name, "t", item.type)
    end
    return
  end

  local has_schemas = cache.has_schemas(conn_id, on_ready)
  if has_schemas == nil then return end

  local root = cache.children(conn_id, {}, on_ready) or {}
  if not has_schemas then
    -- SQLite: the root listing is the table list.
    for _, item in ipairs(root) do
      add(item.name, "t", item.type)
    end
    return
  end

  for _, schema in ipairs(root) do
    add(schema.name, "s", "schema")
  end
  -- Unqualified table names are only worth listing when the schemas can be
  -- swept without turning one keystroke into a query per schema. Past the
  -- bound, the schema names above are the offer, and qualifying narrows it to
  -- a single listing.
  if #root <= config.options.completion.max_schema_scan then
    for _, schema in ipairs(root) do
      for _, item in ipairs(cache.children(conn_id, { schema.name }, on_ready) or {}) do
        add(item.name, "t", schema.name)
      end
    end
  end
end

--- Collect column-name candidates for a position that resolves against the
--- statement's FROM/JOIN sources.
--- @param conn_id  any
--- @param ctx      SqlCompletionContext
--- @param add      fun(word: string, kind: string, menu: string)
--- @param on_ready fun()|nil
local function column_candidates(conn_id, ctx, add, on_ready)
  local wanted = {}
  if ctx.qualifier then
    local src = require("grannos.symbols.sql_sources").find_source(ctx.sources, ctx.qualifier)
    if src and src.path then wanted[1] = src end
  else
    -- An alias is itself worth completing here: it is what the user types
    -- before the dot that then narrows to one table.
    for _, src in ipairs(ctx.sources) do
      if src.alias then add(src.alias, "a", src.path and table.concat(src.path, ".") or "subquery") end
      if src.path then wanted[#wanted + 1] = src end
    end
  end

  for _, src in ipairs(wanted) do
    local path = resolve_table_path(conn_id, src.path, on_ready)
    if path then
      local label = src.alias or path[#path]
      for _, item in ipairs(cache.columns(conn_id, path, on_ready) or {}) do
        -- explore.list reports a field's *data* type in `type`, not "column".
        add(item.name, "c", ("%s · %s"):format(item.type, label))
      end
    end
  end
end

--- Feed the candidates for `ctx` to `add`, starting any fetch it needs.
--- @param conn_id  any
--- @param ctx      SqlCompletionContext
--- @param add      fun(word: string, kind: string, menu: string)
--- @param on_ready fun()|nil  called once per fetch that completes
function M.candidates(conn_id, ctx, add, on_ready)
  if ctx.kind == "table" then
    table_candidates(conn_id, ctx, add, on_ready)
  else
    column_candidates(conn_id, ctx, add, on_ready)
  end
end

return M
