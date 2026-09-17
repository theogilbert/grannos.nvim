# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Running tests

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim). Run a single spec file from within Neovim:

```
:PlenaryBustedFile spec/connections_spec.lua
```

To run the suite headlessly from the CLI (no Neovim UI needed): `make ci`, or the `test` skill (`/test`) for a single spec file.

Both go through `spec/minimal_init.lua`, which prepends this working tree to the runtimepath. That matters: an installed copy of grannos.nvim under `site/pack` otherwise sits ahead of the working tree in the child processes plenary spawns, and a spec run silently resolves some modules from each. Never run the specs without it.

There is no build step for the Lua code. The precompiled treesitter parsers (`parser/sql.so`, `parser/cypher.so`, `parser/promql.so`, `parser/lucene.so`, `parser/mongo.so`) are built from the grammars in `../treesitters/` and copied here; never edit them by hand. To change one, edit its `grammar.js`, run `tree-sitter generate && tree-sitter test && tree-sitter build -o parser.so .` in the grammar directory, and copy `parser.so` over the matching `parser/<lang>.so` (keeping `queries/<lang>/highlights.scm` in sync with the grammar's `queries/highlights.scm`).

## Architecture

grannos.nvim is a Neovim database-client plugin that delegates all database work to an external backend process. The client and server communicate over **newline-delimited JSON on stdio** — one JSON object per line in each direction. See `docs/protocol.md` for the full wire format.

### Module map

| Module | Role |
|--------|------|
| `plugin/grannos.lua` | All `:DbXxx` user commands; entry point that Neovim loads |
| `lua/grannos/init.lua` | Public Lua API (`require("grannos")`); owns session state |
| `lua/grannos/client.lua` | Spawns the backend process; speaks the JSON protocol |
| `lua/grannos/connections.lua` | Reads/writes `connections.json`; connection CRUD wizards |
| `lua/grannos/executor.lua` | Sends queries, dispatches results, manages gutter marks and log entries |
| `lua/grannos/config.lua` | Plugin options with defaults |
| `lua/grannos/health.lua` | `:checkhealth grannos`: verifies setup, backend install, protocol version, parsers |
| `lua/grannos/buffer.lua` | Generic buffer class: content, keymaps, `g?` help float |
| `lua/grannos/ui/connections.lua` | Connections panel (right sidebar) |
| `lua/grannos/ui/explorer.lua` | Schema explorer (left sidebar) |
| `lua/grannos/ui/results.lua` | Query results panel (split) |
| `lua/grannos/ui/spinner.lua` | Refcounted braille spinner driven by a libuv timer |
| `lua/grannos/ui/gutter.lua` | Gutter extmarks: running/success/error icons |
| `lua/grannos/ui/conn_label.lua` | Winbar connection label per window |
| `lua/grannos/ui/query_log.lua` | 4-pane query history float |
| `lua/grannos/ui/conn_picker.lua` | Single-pane search-and-list float over caller-supplied rows; `connections.pick` builds the saved-connection rows for `:DbAttach` |
| `lua/grannos/ui/query_picker.lua` | Saved-query picker (fzf-lua or `vim.ui.select`) |
| `lua/grannos/ui/save_query.lua` | Save-query wizard |
| `lua/grannos/ui/col_picker.lua` | Column-visibility picker for the results panel |
| `lua/grannos/ui/detail_pane.lua` | Shared two-pane and single-item detail float infrastructure |
| `lua/grannos/ui/indices.lua` | Index-description float (uses detail_pane) |
| `lua/grannos/ui/column.lua` | Column-description float (uses detail_pane) |
| `lua/grannos/ui/relationship.lua` | Foreign-key relationship detail float, opened by hovering a diagram edge (uses detail_pane) |
| `lua/grannos/ui/diagram.lua` | ASCII schema diagram viewer (new tab); tracks highlight regions for hover |
| `lua/grannos/ui/hover.lua` | Generic non-focusable hover float near the cursor |
| `lua/grannos/ui/histogram.lua` | Pure renderer for an `execute.histogram` result: documents over time as a block-glyph column chart, toggled by `gh` in the results pane |
| `lua/grannos/ui/content_buffer.lua` | Opens `explore.download` content (base64) in a scratch buffer; shared by the explorer and (later) results-pane LOB downloads |
| `lua/grannos/ui/window.lua` | Sidebar window helper |
| `lua/grannos/log.lua` | In-memory query log (per connection) |
| `lua/grannos/selection.lua` | Visual selection extraction |
| `lua/grannos/ts_queries.lua` | Treesitter helpers: statement at cursor, statements in range |
| `lua/grannos/symbols/` | Per-language extraction of the symbol under the cursor into an `explore.find` query |
| `lua/grannos/completion/` | Per-language name completion in query buffers: `init.lua` serves 'omnifunc' and dispatches on treesitter language, `sql.lua` (with `context.lua` classifying the cursor position), `cypher.lua`, `promql.lua`, `lucene.lua` and `mongo.lua` are the language modules, `repair.lua` the placeholder-parse trick they share, `cache.lua` holds `explore.list` results, `indicator.lua` shows a spinner on the cursor line while a listing is in flight, `cmp.lua` is the nvim-cmp source |
| `lua/grannos/hl.lua` | Highlight group definitions |
| `lua/grannos/table.lua` | Column-aligned table rendering for results |
| `lua/grannos/messages.lua` | Pure renderer for an execute response's `messages` (DBMS_OUTPUT, compilation warnings) |
| `lua/grannos/queries.lua` | Saved-queries filesystem helpers |
| `lua/grannos/session_params.lua` | Per-connection persistence of `session.set` values, replayed after every connect so runtime-only settings survive backend and Neovim restarts |
| `lua/grannos/col_selection.lua` | Per-connection persistence of the results-pane column selection last made: its visible names in order and its hidden names, applied to every later result on that connection |
| `lua/grannos/export.lua` | Pure serializers for exporting query results (json/csv/pretty/markdown) |

### Resolving the symbol under the cursor

`symbols.at_cursor` is **purely syntactic**: it reports what the symbol is called, what kind of node it names, and every ancestor the query text pins down. It never decides which database node that is — it emits an `explore.find` query and the backend resolves it, since only the backend knows what exists, where each driver keeps each kind of node, and how the catalog cases its identifiers.

One extractor per treesitter language, in `lua/grannos/symbols/`, dispatched on `parser:lang()`:

| Language | Symbols it names | Scopes it can infer |
|----------|------------------|---------------------|
| `sql` | table, column | the schema a reference is qualified with; the table an alias binds to; every FROM/JOIN source a bare column could belong to |
| `cypher` | label, relationship_type, property | the label(s) or relationship type a variable's pattern binds it to |
| `promql` | metric, label, job | the metric a label's selector names; every metric of the expression a `by`/`without`/`on`/`ignoring`/`group_*` list modifies |
| `mongo` | collection, database, field | the collection an operation names, and its database — MongoDB queries are Extended JSON command objects; the `mongo` grammar is the JSON tree with a `statement` per command, so the same extractor is registered for `json` too and a `.json` query file from before `.mongo` existed still resolves |

A language absent from that table simply never resolves, which is the same outcome as a cursor on a keyword. Adding one means adding a module with an `extract(node, bufnr)` function and registering it in `symbols/init.lua`; nothing else changes, because the backend already knows where every kind of node lives.

Do not reintroduce client-side resolution against the explorer's cached tree. It was removed because it could only ever see what the user had already expanded in the sidebar, so the same hover resolved or didn't depending on unrelated browsing history.

### Completion

`lua/grannos/completion/` sets 'omnifunc' on connected SQL, Cypher, PromQL, Lucene and MongoDB buffers. Two rules govern it:

**It never sends `explore.describe`.** A describe costs ~11 round trips per table and reads user data (every driver samples column values; DuckDB does one `SELECT DISTINCT` *per column*). `explore.list [schema, table, "columns"]` returns the same names and types in one catalog query that touches no user table. Completion is only ever allowed the latter — the same reason it must not use `explore.find`, whose walker fans out across the tree.

**It never blocks.** Omnifunc is synchronous and the backend is not, so a lookup returns what `completion/cache.lua` already holds and starts a fetch for the rest; when that lands the popup is refilled in place via `vim.fn.complete`. Resolution is chained (root listing → a schema's tables → a table's columns), so each refill arms the next round, bounded by `MAX_ROUNDS`. Every re-request — omnifunc's `_refiller` and the nvim-cmp source's `on_ready` alike — fires **at most once per call**, however many listings that call left in flight: a re-request registers afresh on every path still pending, so one that fired on every landing would fire 2^n callbacks by the n-th, and a position listing one path per schema pinned Neovim in re-parses until the backend was killed (`spec/completion_storm_spec.lua` guards this). For the same reason no position may list a path per schema past `max_schema_scan` — the unqualified-table sweep and `resolve_table_path` both stop there. Because an empty popup on a cold cache is indistinguishable from "nothing to offer", `cache.lua` reports every fetch's start and landing through `on_fetch`, and `completion/indicator.lua` shows a spinner plus "fetching completions" as end-of-line virtual text on the cursor line while any is in flight for the current buffer's connection.

One module per treesitter language, dispatched from `completion/init.lua` on `parser:lang()`. Each exposes `TRIGGER_CHARACTERS`, `prime(conn_id)` (listings to warm on attach), `at_cursor(...)` → a language-specific context, and `candidates(conn_id, ctx, add, on_ready)`; the shared `add` handles prefix filtering and dedup. A module may also expose `word_start(line, col)` when its words are not `[%w_]+` — PromQL's keeps colons (recording rule names) and, inside a string, everything since the opening quote (a job name is free text). Adding a language means adding a module and registering it in `LANGUAGES`.

No language parses the buffer as written — mid-keystroke there is usually no finished identifier to read. `completion/repair.lua` replaces the partial word with a placeholder identifier and parses that repaired copy, which recovers every clause a query buffer completes in. For SQL, `completion/context.lua` classifies the placeholder; the one shape the grammar cannot recover is an INSERT column list (`INSERT INTO t (`), matched textually instead. The FROM/JOIN source analysis itself is shared with symbol extraction in `symbols/sql_sources.lua` so an alias resolves identically whether hovered or completed. Cypher goes further and hands the placeholder straight to `symbols/cypher.lua`'s `extract`, which already names a label, relationship type or property and the scope its variable binds to; only the variable position (a bare word where an expression starts, offered the way SQL offers aliases) is decided in `completion/cypher.lua`. The Neo4j tree's group names (`entities`, `relationships`, `properties`) are assumed there rather than discovered, as `cache.columns` assumes `columns` for SQL. An unlabelled variable's property sweep across every label and relationship type is bounded by `completion.max_label_scan`, the counterpart of `max_schema_scan`.

PromQL is completed inside constructs that are usually still open — `up{`, `sum by (`, `job="` — and the grammar recovers a placeholder at the ragged end of one far worse than inside a closed one (`up{grannos_ph_` is a stray error with no selector around it). So `completion/promql.lua` runs the repaired text through `repair.close_open`, which appends the closer of every string and bracket still open (skipping strings and `#` comments), before parsing; the position then goes to `symbols/promql.lua`'s `extract` like Cypher's does. Its `metric_scope` is shared with hover: a label in `{…}` belongs to that selector's metric alone, one in a grouping list to every metric of the nearest enclosing expression that names any, stopping at an error node or the root so an unfinished `sum by (` never borrows metrics from the rest of the file. There is no sweep: a label with no metric in scope offers nothing, because Prometheus exposes no per-label-name listing through the tree and sweeping metrics for one is unbounded.

Lucene is grannos' own Elasticsearch query form, `<index> | <query_string>` (grammar in `../treesitters/treesitter-lucene`, filetype `lucene` for `.lucene` files, `--` line comments the grammar adds so saved-query headers parse). `completion/lucene.lua` splits the query textually on its first pipe — the cut the driver makes — because an index typed alone has no pipe yet and the grammar can only report an error for it: ahead of the pipe it offers the root listing (index names), after it the `[index, "mappings"]` listing of every index named, a pattern passed through as written since the server merges what it matches. The tree decides the rest: the placeholder's clause is a field position when it is a bare term, the term ahead of a colon, or the value of `_exists_`; the value of any other field offers nothing, since the mapping lists no values. There is no symbol extractor for it.

MongoDB queries are Extended JSON command objects (grammar in `../treesitters/treesitter-mongo`, filetype `mongo` for `.mongo` files, `//` and `/* */` comments as extras — the driver strips them). The grammar is tree-sitter-json's tree with a `statement` around each top-level object, so `ts_queries` finds the command under the cursor by extent, `has_write_statement` tells a write by the command's operation key, and `symbols/mongo.lua` reads JSON nodes unchanged. Every name in a command is a string, so `completion/mongo.lua` completes only inside quotes and its `word_start` is the opening quote (a field path is dotted, an operator or field reference starts with `$`). The cursor's command is bounded from the buffer's own tree, but a command still open swallows the next one in that tree, so past the cursor a line opening `{` at column 0 ends a command that has errors; the repaired copy then goes through the module's own `close_open`, which closes the string the placeholder is in right after it (closing it any later would swallow a `},` typed after it) and completes it to a `"key": null` pair when it opened where an object expects one, so a half-typed key parses as a pair of its object. The string's place in the tree then decides: a key of the command object offers the operations and arguments less those present; the value of `db` the root listing; the value of the operation the named database's collections (or every database's, bounded by `max_schema_scan`, when none is named), plus `gridfs.<bucket>` for a `find`; a nested key the collection's `fields` listing and the static `$` operator list its argument takes (query, update, stage or expression operators — every operator starts with `$` and no field does, so the typed prefix tells them apart); a `$` value, or any value in a pipeline, field references. `symbols/mongo.lua` exports `command_object`, `command_target` and `OPERATIONS` for this.

### Session state and connection identity

`init.lua` owns two runtime tables:
- `state.conns` — `{ [conn_key] = { conn_id, driver, driver_label, key } }` — connections opened this session.
- `state.buf_conns` — `{ [bufnr] = conn_key }` — which connection each buffer queries against.

Connection keys are **NUL-separated composite strings**: `server\0driver\0group\0name`. Use `connections.conn_key()` / `connections.conn_parts()` to build and split them. Never construct or parse these strings by hand.

### Client/server protocol

`client.lua` is the only module that touches the backend process. It maintains a `state.pending` table mapping request IDs to callbacks. Responses may arrive out of order; `_dispatch` correlates them by `id`. Progress messages (for long-running methods like `execute`) carry a `progress` field instead of `result`/`error`; they invoke `on_progress` without resolving the pending entry.

`client.request(method, params, callback, on_progress)` returns the integer request ID, which callers pass to `client.cancel` when needed.

### Spinner

`ui/spinner.lua` exports `Spinner.new(on_tick)`. The spinner is **refcounted**: every `start()` must be paired with a `stop()`; the underlying libuv timer only runs while at least one `start()` is outstanding. This lets multiple concurrent node loads in the explorer share a single timer. Call `reset()` only for forced teardown (e.g., on backend restart).

### Known circular dependency

`init.lua` requires `ui/connections.lua` at the top level, and `ui/connections.lua` in turn needs `require("grannos")` in almost every handler. To avoid a circular-require error, `ui/connections.lua` does all of those requires **lazily** (inside function bodies), not at the top of the file. Preserve this pattern when adding new cross-module calls between these two files.

### Documentation

All public and private functions must have LuaDoc annotations (`---` comments). This includes:
- `@param` for every parameter, including table-typed params whose fields must be listed inline (e.g. `--- @param conn { conn_id: any, driver: string, key: string }`)
- `@return` for every return value
- A one-line description above the annotations

### Buffer abstraction

All sidebar and log panels use the `Buffer` class (`lua/grannos/buffer.lua`). It wraps a scratch buffer, tracks registered keymaps, and provides a `g?` help float automatically. Register keymaps via `buffer:set_keymap(mode, key, fn, opts)` rather than `vim.keymap.set` directly so they appear in the help float. Pass `opts.group` (a string) to group related keys under a section header in the help float.
