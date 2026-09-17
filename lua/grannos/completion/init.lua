--- Context-aware completion for query buffers, per language: table and
--- column names in SQL, labels, relationship types and properties in Cypher,
--- metrics, labels and jobs in PromQL, index and field names in Lucene,
--- databases, collections, fields and operators in MongoDB commands.
---
--- Exposed as 'omnifunc', so <C-x><C-o> works with no completion plugin
--- installed and any engine that wraps omnifunc picks it up for free.
---
--- Omnifunc is synchronous and the backend is not, so nothing here ever waits:
--- candidates are served from `grannos.completion.cache` as they stand, and a
--- lookup that has to go to the server refills the popup in place when it
--- lands. The cost of that server round trip is one catalog query per path,
--- once per connection, forever — see the cache module.
---
--- Each language is a module under `grannos.completion` exposing:
---   `TRIGGER_CHARACTERS`  punctuation an engine should fire on, besides words
---   `prime(conn_id)`      listings worth fetching on attach
---   `at_cursor(bufnr, row, start_col, end_col)` → context or nil
---   `candidates(conn_id, ctx, add, on_ready)`   feed candidates to `add`
---   `word_start(line, col)`                     optional: where the word ending
---                                               at the cursor starts, when the
---                                               language's words are not `[%w_]+`
--- A buffer whose treesitter language is absent here has no completion.
local cache  = require("grannos.completion.cache")
local config = require("grannos.config")

local M = {}

--- treesitter language → module name.
local LANGUAGES = {
  sql    = "grannos.completion.sql",
  cypher = "grannos.completion.cypher",
  promql = "grannos.completion.promql",
  lucene = "grannos.completion.lucene",
  mongo  = "grannos.completion.mongo",
}

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
--- Stops at "." so a qualified reference completes the part after the dot —
--- unless `lang` draws its own word boundaries.
--- @param lang table   language module
--- @param line string
--- @param col  integer  0-indexed byte column of the cursor
--- @return integer
local function word_start(lang, line, col)
  if lang.word_start then return lang.word_start(line, col) end
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
--- @param info string|nil documentation, for the preview a built-in carries
local function add(out, seen, base, word, kind, menu, info)
  if word == nil or word == "" or seen[word] or not matches(word, base) then return end
  seen[word] = true
  out[#out + 1] = { word = word, kind = kind, menu = menu, info = info }
end

--- Build the candidate list for `ctx`, starting any fetch it needs.
--- @param lang     table   language module
--- @param conn_id  any
--- @param ctx      table   the language's context
--- @param base     string
--- @param on_ready fun()|nil  called once per fetch that completes
--- @return table[]
local function candidates(lang, conn_id, ctx, base, on_ready)
  local out, seen = {}, {}
  lang.candidates(conn_id, ctx, function(word, kind, menu, info)
    add(out, seen, base, word, kind, menu, info)
  end, on_ready)
  table.sort(out, function(a, b) return a.word:lower() < b.word:lower() end)
  return out
end

--- Return the language module for `bufnr`, or nil when its treesitter
--- language is not one this completes.
--- @param bufnr integer
--- @return table|nil
local function language_for(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return nil end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then return nil end
  local name = LANGUAGES[parser:lang()]
  return name and require(name) or nil
end

--- Return the connection id backing `bufnr`, or nil when it has none.
--- Public so a completion engine's source can gate itself on it.
--- @param bufnr integer
--- @return any|nil
function M.conn_id(bufnr)
  return conn_id_for(bufnr)
end

--- Return the punctuation a completion engine should fire on besides word
--- characters: the union over every language, since an engine asks once for
--- the source rather than per buffer. A character one language triggers on
--- and another does not simply yields no context, and so no candidates, there.
--- @return string[]
function M.trigger_characters()
  local out, seen = {}, {}
  for _, name in pairs(LANGUAGES) do
    for _, ch in ipairs(require(name).TRIGGER_CHARACTERS) do
      if not seen[ch] then seen[ch] = true; out[#out + 1] = ch end
    end
  end
  table.sort(out)
  return out
end

--- Return the candidates for a cursor position, engine-agnostically.
---
--- The same list `omnifunc` serves, exposed so an engine that does its own
--- filtering and rendering can ask for a position directly. Pass an empty
--- `base` to get everything the position offers and filter it yourself.
--- @param bufnr    integer
--- @param row      integer       0-indexed
--- @param col      integer       0-indexed byte column of the cursor
--- @param base     string|nil    typed prefix to filter by; "" or nil for all
--- @param on_ready fun()|nil     called when a listing this position needed arrives
--- @return table[]  { word, kind, menu, info } entries
function M.candidates_at(bufnr, row, col, base, on_ready)
  local conn_id = conn_id_for(bufnr)
  local lang    = language_for(bufnr)
  if not conn_id or not lang then return {} end
  local line      = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local start_col = word_start(lang, line, col)
  local ctx       = lang.at_cursor(bufnr, row, start_col, col)
  if not ctx then return {} end
  return candidates(lang, conn_id, ctx, base or "", on_ready)
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
--- @param lang      table   language module
--- @param conn_id   any
--- @param ctx       table   the language's context
--- @param round     integer
--- @return fun()|nil
function M._refiller(bufnr, row, start_col, lang, conn_id, ctx, round)
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
      local next_round = M._refiller(bufnr, row, start_col, lang, conn_id, ctx, round + 1)
      vim.fn.complete(start_col + 1, candidates(lang, conn_id, ctx, line:sub(start_col + 1, c), next_round))
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

  local conn_id = conn_id_for(bufnr)
  local lang    = language_for(bufnr)

  if findstart == 1 then
    if not conn_id or not lang then return -3 end  -- -3: cancel silently
    return word_start(lang, line, col)
  end
  if not conn_id or not lang then return {} end

  local start_col = word_start(lang, line, col)
  local ctx = lang.at_cursor(bufnr, row, start_col, col)
  if not ctx then return {} end

  return candidates(lang, conn_id, ctx, base, M._refiller(bufnr, row, start_col, lang, conn_id, ctx, 1))
end

local OMNIFUNC = "v:lua.require'grannos.completion'.omnifunc"

--- Claim 'omnifunc' for `bufnr` when its language is one this completes, and
--- fetch the listings that language wants warm before the first keystroke.
--- Separate from `attach` because a buffer can gain a connection before it has
--- a filetype — a scratch query buffer is associated and only then set to
--- `sql` — and because Vim's own ftplugin points 'omnifunc' at
--- `sqlcomplete#Complete` every time the filetype is set, which would
--- otherwise take the slot back and quietly answer with keyword completion.
--- @param bufnr integer
--- @return boolean  whether omnifunc is now ours
local function enable(bufnr)
  local lang = language_for(bufnr)
  if not lang then return false end
  vim.bo[bufnr].omnifunc = OMNIFUNC
  local conn_id = conn_id_for(bufnr)
  if conn_id then lang.prime(conn_id) end
  return true
end

--- Attach completion to `bufnr` for connection `conn_key`.
--- The association is recorded even when 'omnifunc' cannot be claimed yet; the
--- FileType handler registered by `setup` claims it as soon as the buffer
--- gains a language this completes. A no-op when completion is disabled.
--- @param bufnr    integer
--- @param conn_key string
function M.attach(bufnr, conn_key)
  if not config.options.completion.enabled then return end
  attached[bufnr] = conn_key
  enable(bufnr)
end

--- Register the FileType handler that re-claims 'omnifunc' on connected
--- buffers. Called once from `grannos.setup()`.
---
--- The claim is deferred rather than made inline. FileType handlers run in
--- registration order, and Vim's own ftplugin/sql.vim sets 'omnifunc' to
--- `sqlcomplete#Complete` from one of them — so whether we win depends on
--- whether the user's `setup()` call happened before or after `filetype plugin
--- on`, which is not something to leave to chance. Scheduling puts the claim
--- after every handler in the cycle, whatever the order.
function M.setup()
  -- Registers the nvim-cmp source when cmp is already loaded. A lazy-loaded
  -- cmp is not here yet, which is why its own config can call
  -- `require("grannos.completion.cmp").setup()` instead.
  pcall(function() require("grannos.completion.cmp").setup() end)
  require("grannos.completion.indicator").setup(conn_id_for)

  vim.api.nvim_create_autocmd("FileType", {
    group    = vim.api.nvim_create_augroup("GrannosCompletion", { clear = true }),
    callback = function(args)
      if not attached[args.buf] then return end
      vim.schedule(function()
        if attached[args.buf] and vim.bo[args.buf].omnifunc ~= OMNIFUNC then
          enable(args.buf)
        end
      end)
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
