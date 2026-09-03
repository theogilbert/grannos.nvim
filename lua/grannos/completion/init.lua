--- Context-aware completion for SQL query buffers: table names after
--- FROM/JOIN/INTO, and column names in every position that resolves against
--- them, including through aliases.
---
--- Exposed as 'omnifunc', so <C-x><C-o> works with no completion plugin
--- installed and any engine that wraps omnifunc picks it up for free.
---
--- Omnifunc is synchronous and the backend is not, so nothing here ever waits:
--- candidates are served from `grannos.completion.cache` as they stand, and a
--- lookup that has to go to the server refills the popup in place when it
--- lands. The cost of that server round trip is one catalog query per path,
--- once per connection, forever — see the cache module.
local cache   = require("grannos.completion.cache")
local config  = require("grannos.config")
local context = require("grannos.completion.context")

local M = {}

--- bufnr → connection key, for buffers this module is attached to.
local attached = {}

--- Return the connection id for `bufnr`, or nil when it has none.
--- Resolved through the public API at call time rather than at load time, so
--- this module and `grannos` can require each other.
--- @param bufnr integer
--- @return any|nil
local function conn_id_for(bufnr)
  local key = attached[bufnr]
  if not key then return nil end
  local conn = require("grannos").get_conn(key)
  return conn and conn.conn_id or nil
end

--- Return the byte column where the word ending at the cursor starts.
--- Stops at "." so a qualified reference completes the part after the dot.
--- @param line string
--- @param col  integer  0-indexed byte column of the cursor
--- @return integer
local function word_start(line, col)
  local start = col
  while start > 0 and line:sub(start, start):match("[%w_]") do
    start = start - 1
  end
  return start
end

--- Return true when `name` should be offered for the typed prefix `base`.
--- @param name string
--- @param base string
--- @return boolean
local function matches(name, base)
  if base == "" then return true end
  return name:lower():sub(1, #base) == base:lower()
end

--- Append a candidate to `out` when it matches `base` and isn't already there.
--- @param out  table[]
--- @param seen table<string, boolean>
--- @param base string
--- @param word string
--- @param kind string    single-letter 'kind' column in the popup
--- @param menu string    right-hand annotation
local function add(out, seen, base, word, kind, menu)
  if word == nil or word == "" or seen[word] or not matches(word, base) then return end
  seen[word] = true
  out[#out + 1] = { word = word, kind = kind, menu = menu }
end

--- Resolve a source's query-text path to a full explore-tree path.
---
--- A query naming a table without its schema (`FROM users`) doesn't say where
--- the table lives, so on a driver with schemas the already-listed schemas are
--- searched for it. An unambiguous single hit wins; anything else yields nil
--- rather than a guess, and the position simply offers nothing.
--- @param conn_id  any
--- @param path     string[]  1 or 2 parts, as written in the query
--- @param on_ready fun()|nil
--- @return string[]|nil
local function resolve_table_path(conn_id, path, on_ready)
  local has_schemas = cache.has_schemas(conn_id, on_ready)
  if has_schemas == nil then return nil end
  if #path >= 2 or not has_schemas then return path end

  local wanted, found = path[1]:lower(), nil
  for _, schema in ipairs(cache.children(conn_id, {}, on_ready) or {}) do
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
--- @param ctx      CompletionContext
--- @param base     string
--- @param out      table[]
--- @param seen     table<string, boolean>
--- @param on_ready fun()|nil
local function table_candidates(conn_id, ctx, base, out, seen, on_ready)
  if ctx.schema then
    for _, item in ipairs(cache.children(conn_id, { ctx.schema }, on_ready) or {}) do
      add(out, seen, base, item.name, "t", item.type)
    end
    return
  end

  local has_schemas = cache.has_schemas(conn_id, on_ready)
  if has_schemas == nil then return end

  local root = cache.children(conn_id, {}, on_ready) or {}
  if not has_schemas then
    -- SQLite: the root listing is the table list.
    for _, item in ipairs(root) do
      add(out, seen, base, item.name, "t", item.type)
    end
    return
  end

  for _, schema in ipairs(root) do
    add(out, seen, base, schema.name, "s", "schema")
  end
  -- Unqualified table names are only worth listing when the schemas can be
  -- swept without turning one keystroke into a query per schema. Past the
  -- bound, the schema names above are the offer, and qualifying narrows it to
  -- a single listing.
  if #root <= config.options.completion.max_schema_scan then
    for _, schema in ipairs(root) do
      for _, item in ipairs(cache.children(conn_id, { schema.name }, on_ready) or {}) do
        add(out, seen, base, item.name, "t", schema.name)
      end
    end
  end
end

--- Collect column-name candidates for a position that resolves against the
--- statement's FROM/JOIN sources.
--- @param conn_id  any
--- @param ctx      CompletionContext
--- @param base     string
--- @param out      table[]
--- @param seen     table<string, boolean>
--- @param on_ready fun()|nil
local function column_candidates(conn_id, ctx, base, out, seen, on_ready)
  local wanted = {}
  if ctx.qualifier then
    local src = require("grannos.symbols.sql_sources").find_source(ctx.sources, ctx.qualifier)
    if src and src.path then wanted[1] = src end
  else
    -- An alias is itself worth completing here: it is what the user types
    -- before the dot that then narrows to one table.
    for _, src in ipairs(ctx.sources) do
      if src.alias then add(out, seen, base, src.alias, "a", src.path and table.concat(src.path, ".") or "subquery") end
      if src.path then wanted[#wanted + 1] = src end
    end
  end

  for _, src in ipairs(wanted) do
    local path = resolve_table_path(conn_id, src.path, on_ready)
    if path then
      local label = src.alias or path[#path]
      for _, item in ipairs(cache.columns(conn_id, path, on_ready) or {}) do
        -- explore.list reports a field's *data* type in `type`, not "column".
        add(out, seen, base, item.name, "c", ("%s · %s"):format(item.type, label))
      end
    end
  end
end

--- Build the candidate list for `ctx`, starting any fetch it needs.
--- @param conn_id  any
--- @param ctx      CompletionContext
--- @param base     string
--- @param on_ready fun()|nil  called once per fetch that completes
--- @return table[]
local function candidates(conn_id, ctx, base, on_ready)
  local out, seen = {}, {}
  if ctx.kind == "table" then
    table_candidates(conn_id, ctx, base, out, seen, on_ready)
  else
    column_candidates(conn_id, ctx, base, out, seen, on_ready)
  end
  table.sort(out, function(a, b) return a.word:lower() < b.word:lower() end)
  return out
end

--- Resolving a position can take several rounds: knowing the tree's shape is
--- what tells us to list a schema's tables, and finding the table there is what
--- tells us to list its columns. Each round therefore arms a fresh callback for
--- whatever the previous round's arrivals made newly fetchable, redrawing the
--- popup in place each time until nothing new is asked for.
---
--- Bounded by MAX_ROUNDS, which is one more than the deepest chain (root →
--- tables → columns), so a driver that answers unexpectedly can't spin.
local MAX_ROUNDS = 4

--- Return a one-shot `on_ready` callback that refills the open popup.
--- Fires at most once per round however many paths landed in it.
--- @param bufnr     integer
--- @param row       integer
--- @param start_col integer
--- @param conn_id   any
--- @param ctx       CompletionContext
--- @param round     integer
--- @return fun()|nil
function M._refiller(bufnr, row, start_col, conn_id, ctx, round)
  if round > MAX_ROUNDS then return nil end
  local fired = false
  return function()
    if fired then return end
    fired = true
    vim.schedule(function()
      if vim.api.nvim_get_current_buf() ~= bufnr then return end
      if not vim.fn.mode():match("^i") then return end
      local r, c = unpack(vim.api.nvim_win_get_cursor(0))
      if r - 1 ~= row or c < start_col then return end
      local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
      local next_round = M._refiller(bufnr, row, start_col, conn_id, ctx, round + 1)
      vim.fn.complete(start_col + 1, candidates(conn_id, ctx, line:sub(start_col + 1, c), next_round))
    end)
  end
end

--- 'omnifunc' implementation. See `:h complete-functions`.
--- @param findstart integer
--- @param base      string
--- @return integer|table[]
function M.omnifunc(findstart, base)
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""

  if findstart == 1 then
    if not conn_id_for(bufnr) then return -3 end  -- -3: cancel silently
    return word_start(line, col)
  end

  local conn_id = conn_id_for(bufnr)
  if not conn_id then return {} end

  local start_col = word_start(line, col)
  local ctx = context.at_cursor(bufnr, row, start_col, col)
  if not ctx then return {} end

  return candidates(conn_id, ctx, base, M._refiller(bufnr, row, start_col, conn_id, ctx, 1))
end

local OMNIFUNC = "v:lua.require'grannos.completion'.omnifunc"

--- Claim 'omnifunc' for `bufnr` when its language is one this completes.
--- Separate from `attach` because a buffer can gain a connection before it has
--- a filetype — a scratch query buffer is associated and only then set to
--- `sql` — and because Vim's own ftplugin points 'omnifunc' at
--- `sqlcomplete#Complete` every time the filetype is set, which would
--- otherwise take the slot back and quietly answer with keyword completion.
--- @param bufnr integer
--- @return boolean  whether omnifunc is now ours
local function enable(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser or parser:lang() ~= "sql" then return false end
  vim.bo[bufnr].omnifunc = OMNIFUNC
  return true
end

--- Attach completion to `bufnr` for connection `conn_key`.
--- The association is recorded even when 'omnifunc' cannot be claimed yet; the
--- FileType handler registered by `setup` claims it as soon as the buffer
--- becomes SQL. A no-op when completion is disabled in config.
--- @param bufnr    integer
--- @param conn_key string
function M.attach(bufnr, conn_key)
  if not config.options.completion.enabled then return end
  attached[bufnr] = conn_key
  if not enable(bufnr) then return end

  -- One list call, so the tree's shape and its top level are known before the
  -- first keystroke that needs them.
  local conn = require("grannos").get_conn(conn_key)
  if conn then cache.children(conn.conn_id, {}) end
end

--- Register the FileType handler that re-claims 'omnifunc' on connected
--- buffers. Called once from `grannos.setup()`.
function M.setup()
  vim.api.nvim_create_autocmd("FileType", {
    group    = vim.api.nvim_create_augroup("GrannosCompletion", { clear = true }),
    callback = function(args)
      if attached[args.buf] and vim.bo[args.buf].omnifunc ~= OMNIFUNC then
        enable(args.buf)
      end
    end,
  })
end

--- Detach completion from `bufnr`.
--- @param bufnr integer
function M.detach(bufnr)
  if attached[bufnr] == nil then return end
  attached[bufnr] = nil
  if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].omnifunc == OMNIFUNC then
    vim.bo[bufnr].omnifunc = ""
  end
end

--- Drop cached tree data for `conn_id`, or for every connection when nil.
--- @param conn_id any|nil
function M.invalidate(conn_id)
  cache.invalidate(conn_id)
end

return M
