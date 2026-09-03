# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Running tests

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim). Run a single spec file from within Neovim:

```
:PlenaryBustedFile spec/connections_spec.lua
```

To run the suite headlessly from the CLI (no Neovim UI needed): `make ci`, or the `test` skill (`/test`) for a single spec file.

Both go through `spec/minimal_init.lua`, which prepends this working tree to the runtimepath. That matters: an installed copy of grannos.nvim under `site/pack` otherwise sits ahead of the working tree in the child processes plenary spawns, and a spec run silently resolves some modules from each. Never run the specs without it.

There is no build step for the Lua code. The precompiled treesitter parsers (`parser/sql.so`, `parser/cypher.so`, `parser/promql.so`) are binary and should not be regenerated manually.

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
| `lua/grannos/ui/query_picker.lua` | Saved-query picker (fzf-lua or `vim.ui.select`) |
| `lua/grannos/ui/save_query.lua` | Save-query wizard |
| `lua/grannos/ui/col_picker.lua` | Column-visibility picker for the results panel |
| `lua/grannos/ui/detail_pane.lua` | Shared two-pane and single-item detail float infrastructure |
| `lua/grannos/ui/indices.lua` | Index-description float (uses detail_pane) |
| `lua/grannos/ui/column.lua` | Column-description float (uses detail_pane) |
| `lua/grannos/ui/relationship.lua` | Foreign-key relationship detail float, opened by hovering a diagram edge (uses detail_pane) |
| `lua/grannos/ui/diagram.lua` | ASCII schema diagram viewer (new tab); tracks highlight regions for hover |
| `lua/grannos/ui/hover.lua` | Generic non-focusable hover float near the cursor |
| `lua/grannos/ui/content_buffer.lua` | Opens `explore.download` content (base64) in a scratch buffer; shared by the explorer and (later) results-pane LOB downloads |
| `lua/grannos/ui/window.lua` | Sidebar window helper |
| `lua/grannos/log.lua` | In-memory query log (per connection) |
| `lua/grannos/selection.lua` | Visual selection extraction |
| `lua/grannos/ts_queries.lua` | Treesitter helpers: statement at cursor, statements in range |
| `lua/grannos/symbols/` | Per-language extraction of the symbol under the cursor into an `explore.find` query |
| `lua/grannos/completion/` | Table/column completion for SQL buffers: `context.lua` classifies the cursor position, `cache.lua` holds `explore.list` results, `init.lua` serves 'omnifunc', `cmp.lua` is the nvim-cmp source |
| `lua/grannos/hl.lua` | Highlight group definitions |
| `lua/grannos/table.lua` | Column-aligned table rendering for results |
| `lua/grannos/messages.lua` | Pure renderer for an execute response's `messages` (DBMS_OUTPUT, compilation warnings) |
| `lua/grannos/queries.lua` | Saved-queries filesystem helpers |
| `lua/grannos/export.lua` | Pure serializers for exporting query results (json/csv/pretty/markdown) |

### Resolving the symbol under the cursor

`symbols.at_cursor` is **purely syntactic**: it reports what the symbol is called, what kind of node it names, and every ancestor the query text pins down. It never decides which database node that is — it emits an `explore.find` query and the backend resolves it, since only the backend knows what exists, where each driver keeps each kind of node, and how the catalog cases its identifiers.

One extractor per treesitter language, in `lua/grannos/symbols/`, dispatched on `parser:lang()`:

| Language | Symbols it names | Scopes it can infer |
|----------|------------------|---------------------|
| `sql` | table, column | the schema a reference is qualified with; the table an alias binds to; every FROM/JOIN source a bare column could belong to |
| `cypher` | label, relationship_type, property | the label(s) or relationship type a variable's pattern binds it to |
| `promql` | metric, label, job | the metric a label sits under, including across an aggregation modifier |
| `json` | collection, database, field | the collection an operation names, and its database — MongoDB queries are Extended JSON, so they parse as `json` rather than a language of their own |

A language absent from that table simply never resolves, which is the same outcome as a cursor on a keyword. Adding one means adding a module with an `extract(node, bufnr)` function and registering it in `symbols/init.lua`; nothing else changes, because the backend already knows where every kind of node lives.

Do not reintroduce client-side resolution against the explorer's cached tree. It was removed because it could only ever see what the user had already expanded in the sidebar, so the same hover resolved or didn't depending on unrelated browsing history.

### Completion

`lua/grannos/completion/` sets 'omnifunc' on connected SQL buffers. Two rules govern it:

**It never sends `explore.describe`.** A describe costs ~11 round trips per table and reads user data (every driver samples column values; DuckDB does one `SELECT DISTINCT` *per column*). `explore.list [schema, table, "columns"]` returns the same names and types in one catalog query that touches no user table. Completion is only ever allowed the latter — the same reason it must not use `explore.find`, whose walker fans out across the tree.

**It never blocks.** Omnifunc is synchronous and the backend is not, so a lookup returns what `completion/cache.lua` already holds and starts a fetch for the rest; when that lands the popup is refilled in place via `vim.fn.complete`. Resolution is chained (root listing → a schema's tables → a table's columns), so each refill arms the next round, bounded by `MAX_ROUNDS`.

`completion/context.lua` does not parse the buffer as written — mid-keystroke there is usually no `column_ref` to read. It replaces the partial word with a placeholder identifier and parses that repaired copy, which recovers every clause a query buffer completes in. The one shape the grammar cannot recover is an INSERT column list (`INSERT INTO t (`), matched textually instead. The FROM/JOIN source analysis itself is shared with symbol extraction in `symbols/sql_sources.lua` so an alias resolves identically whether hovered or completed.

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
