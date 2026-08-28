# grannos.nvim

A Neovim database client. Communicates with an external server backend over newline-delimited JSON on stdio — see the [protocol spec](docs/protocol.md).

## Requirements

- Neovim 0.9+
- A server backend implementing the [belvedere protocol](docs/protocol.md)

[belvedere-py](https://github.com/theogilbert/dbelveder-py) is a reference server implementation.

## Installation

Install a server backend, then install the plugin with your plugin manager:

**lazy.nvim**
```lua
{
  "you/grannos.nvim",
  config = function()
    require("grannos").setup()
  end,
}
```

### Example configuration

```lua
-- plugins.lua
require("grannos").setup({
  server_cmd = "belvedere --log -v"
})

-- keymaps.lua
local grannos = require("grannos")
vim.keymap.set("n", "<leader>bC", grannos.open_connections, { desc = "Data[b]ase - [c]onnections" })
vim.keymap.set("n", "<leader>ba", grannos.attach, { desc = "Data[b]ase - [a]ttach" })
vim.keymap.set("n", "<leader>bh", function() grannos.open_current_driver_help({ position = "bottom" }) end, { desc = "Data[b]ase [h]elp" })
vim.keymap.set("n", "<leader>bx", grannos.open_explorer, { desc = "Data[b]ase - open e[x]plorer" })
vim.keymap.set({"n", "v"}, "<leader>be", grannos.execute,        { desc = "Data[b]ase - [e]xecute" })
vim.keymap.set("n", "<leader>bA", grannos.cancel_query, { desc = "Data[b]ase - [a]bort current query" })
vim.keymap.set("n", "<leader>bL", grannos.query_log, { desc = "Data[b]ase - view query [L]ogs" })
vim.keymap.set({"n", "v"}, "<leader>bs", grannos.save_query, { desc = "Data[b]ase - [s]ave query" })
vim.keymap.set({"n", "v"}, "<leader>bl", grannos.load_query, { desc = "Data[b]ase - [l]oad query" })
```

## Setup

`setup()` is required. All options have defaults:

```lua
require("grannos").setup({
  -- Command used to launch the server backend.
  -- Default: "belvedere" (assumes it is on $PATH).
  server_cmd = "belvedere",

  -- Override the path to the connections file.
  -- Default: $XDG_CONFIG_HOME/grannos/connections.json
  --          (~/.config/grannos/connections.json on most systems)
  -- connections_file = vim.fn.expand("~/.config/grannos/connections.json"),

  -- Override the directory where saved queries are stored.
  -- Default: $XDG_DATA_HOME/grannos/queries/
  --          (~/.local/share/grannos/queries/ on most systems)
  -- queries_dir = vim.fn.expand("~/.local/share/grannos/queries"),

  keymaps = {
    -- Describe the symbol (or panel item) under the cursor. In the connections
    -- panel this shows the connection details / error float.
    hover_key = "K",

    -- Show execution info for the query under the cursor, in query buffers.
    query_info_key = "gK",

    -- Reveal the symbol under the cursor in the schema explorer, in query buffers.
    goto_symbol_key = "<C-]>",
  },

  -- Results window appearance.
  results = {
    split     = "below",  -- "below" | "right"
    height    = 15,
    page_size = 500,
  },
})
```

## Workflow

### 1. Manage connections

Open the connections panel with `:DbConnections`. Connections are grouped by driver and persist across sessions in `~/.config/grannos/connections.json`.

| Key | Action |
|-----|--------|
| `<CR>` | Expand/collapse a driver group, or connect to the database under the cursor |
| `b` | Jump to the buffer associated with the connection under the cursor |
| `n` | Create a new connection (guided wizard) |
| `G` | Create a new group |
| `e` | Edit the connection under the cursor |
| `c` | Clone the connection under the cursor |
| `D` | Delete the saved connection under the cursor |
| `d` | Disconnect from the database under the cursor |
| `x` | Open the explorer for the connected database under the cursor |
| `l` | List saved queries for the connection or group under the cursor |
| `K` | Show connection details or error in a float (press `K` again to enter it) |
| `?` | Show driver help |
| `R` | Refresh the panel |
| `q` | Close the panel |
| `g?` | Show keymap reference |

Status indicators next to each connection name:

| Symbol | Meaning |
|--------|---------|
| `✓` | Connected (green) |
| `✗` | Last connection attempt failed (red) — press `K` for details |
| `⠋…` | Connecting (animated spinner) |

### 2. Associate a buffer

Once a connection is open, associate it with the buffer you want to query:

```
:DbAssociate
```

A picker lists all currently open connections. Select one — the buffer is now linked and a "Connected to name (driver)" label appears at the bottom of the window.

### 3. Execute queries

Write SQL in the associated buffer and run:

| Command | What it executes |
|---------|-----------------|
| `:DbExecute` | Current line |
| `:'<,'>DbExecute` | Visual selection |
| `:%DbExecute` | Whole buffer |

The plugin sets no keymaps on your buffers — add your own as needed, e.g.:

```lua
vim.keymap.set("n", "<leader>e", ":DbExecute<CR>")
vim.keymap.set("x", "<leader>e", ":'<,'>DbExecute<CR>")
```


Results appear in a split window with aligned columns and a row count. For DML queries (`INSERT`, `UPDATE`, `DELETE`) the affected row count is shown instead of a table.

| Key | Action |
|-----|--------|
| `H` / `L` | Scroll left / right one column |
| `c` | Select which columns to display |
| `[` / `]` | Previous / next page |
| `q` | Close the results window |
| `g?` | Show keymap reference |

**Multiple queries:** if the SQL contains `;`, each statement is sent as a separate request and results are shown as labelled sections (`── Query 1 / 3 ──`, etc.). This does not apply to MongoDB-style drivers.

### 4. Query log

Run `:DbQueryLog` (or `db.query_log()`) to open a history of all queries executed on the current buffer's connection.

The log opens as a floating four-panel UI:

- **Left top** — live search input (type to filter).
- **Left bottom** — filtered list of past queries, each showing status, time, source line, and a truncated SQL preview.
- **Right top** — full SQL of the highlighted entry.
- **Right bottom** — result of the highlighted entry (rows, row count, or error).

| Key | Action |
|-----|--------|
| (type) | Filter the list in real time |
| `<CR>` (in search) | Move focus to the list |
| `<Esc>` (in search) | Clear the filter, or close if already empty |
| `<CR>` (in list) | Close the log, jump to the source line, and restore the result in the results window |
| `/` | Return to the search input |
| `q` / `<Esc>` (in list) | Close the log |

Status indicators in the list:

| Symbol | Meaning |
|--------|---------|
| (none) | Completed successfully |
| `✗` | Error (highlighted in red) |
| `…` | Still running |

### 5. Save queries


Select text in visual mode (or position the cursor on a single line), then run:

```
:'<,'>DbSaveQuery
```

Or from a Lua keymap:

```lua
vim.keymap.set({"n", "v"}, "<leader>bq", db.save_query, { desc = "Data[b]ase - save [q]uery" })
```

A preview of the selected text appears in a floating window. You are then prompted for:

1. **A name** — a short label for the query.
2. **A scope** — where the query should be saved:
   - *Driver* — available for any connection using this driver.
   - *Group* — available for all connections in the current group.
   - *Connection* — specific to the current connection only.

If the current buffer has an associated connection the scope picker lets you choose a level of that connection's hierarchy directly. Otherwise you are walked through picking a driver, group, and connection from your saved connections.

Duplicate names within the same scope are rejected with a warning and you are re-prompted for the name.

Queries are stored as plain files under `~/.local/share/grannos/queries/` and inherit the file extension of the source buffer (e.g. `.sql`, `.cypher`).

### 6. Load saved queries

From a buffer associated with a connection, run:

```
:DbLoadQueries
```

Or press `l` on a connection or group entry in the connections panel.

A picker (fzf-lua if available, otherwise `vim.ui.select`) lists all queries in scope — connection-specific entries appear first, then group-level, then driver-level. Searching matches both name and content simultaneously.

On `<CR>` the query opens in a new buffer (`grannos://queries/…`) associated with the connection, so `:DbExecute` works immediately. The buffer is editable — a comment at the top reminds you that edits do not update the saved query file. On `<C-d>` the selected query is deleted (with confirmation).

### 7. Explore the schema

Press `e` on a connected database in the connections panel, or run `:DbExplore`.

| Key | Action |
|-----|--------|
| `<CR>` | Expand / collapse a node |
| `K` | Describe the item under the cursor |
| `R` | Refresh the tree, bypassing the server-side schema cache |
| `g?` | Show keymap reference |

The window title bar shows the connection name and driver. A spinner is shown while a node's children are loading.

---

## Commands

| Command | Description |
|---------|-------------|
| `:DbConnections` | Toggle the connections panel |
| `:DbAssociate` | Associate the current buffer with an open connection |
| `:DbAttach [name]` | Connect to a saved connection by name (or open a picker) |
| `:DbNewConnection` | Open the new-connection wizard |
| `:DbDeleteConnection <name>` | Remove a saved connection |
| `:DbDisconnect [name]` | Disconnect a named connection, or the current buffer's connection |
| `:[range]DbExecute` | Execute SQL (range, selection, or current line) |
| `:[range]DbSaveQuery` | Save the selected/current-line query with a name and scope |
| `:DbLoadQueries` | Open the saved-queries picker for the current buffer's connection |
| `:DbQueryLog` | Open the query log for the current buffer's connection |
| `:DbCancelQuery` | Cancel the running query whose gutter icon is on the cursor line |
| `:DbExplore` | Open the schema explorer |
| `:DbStop` | Kill the backend process |
| `:DbRestart` | Restart the backend process (clears all state) |

---

## Connections file

Connections are stored in `~/.config/grannos/connections.json` (XDG-compliant). The file is created automatically on first save. Passwords are not stored — you are prompted at connect time.

### Write protection

By default, grannos detects write operations (DML and DDL) in SQL and Cypher buffers before executing and prompts for confirmation. The prompt offers three choices:

- **Abort** — cancel the execution
- **Execute** — run this time, keep prompting on future writes
- **Always allow writes** — run and permanently disable the prompt for this connection

The per-connection `allow_writes` flag is stored in `connections.json`. When set to `true`, no prompt is shown. This can be toggled via the edit-connection wizard in the connections panel (planned).

### File format

```json
{
  "belvedere": {
    "sqlite": {
      "label": "SQLite",
      "groups": {
        "": {
          "local-sqlite": { "database": "/home/user/data.db" }
        }
      }
    },
    "sqlserver": {
      "label": "SQL Server",
      "groups": {
        "": {
          "prod-mssql": { "host": "db.example.com", "port": 1433, "database": "myapp", "user": "readonly", "allow_writes": true }
        }
      }
    }
  }
}
```

---

## Queries directory

Saved queries live under `~/.local/share/grannos/queries/` (XDG-compliant). The directory is created automatically on first save. Each query is stored as a plain text file whose extension matches the source buffer:

```
~/.local/share/grannos/queries/
  driver/<server>/<driver>/
    <name>.<ext>              ← applies to any connection using this driver
  group/<server>/<driver>/<group>/
    <name>.<ext>              ← applies to all connections in the group
  connection/<server>/<driver>/<group>/<conn>/
    <name>.<ext>              ← specific to one connection
```

Files can be edited or deleted directly from the filesystem.

---

## Lua API

```lua
local db = require("grannos")

-- Configure (call once at startup).
db.setup(opts)

-- Open the connections panel.
db.open_connections()

-- Connect via picker, or directly by name.
db.attach()
db.attach("prod-mssql")

-- Associate the current buffer with an open connection (shows a picker).
db.associate()

-- Disconnect from a named connection.
db.disconnect("prod-mssql")

-- Execute: mode-aware (visual selection or current line). For Lua keymaps.
db.execute()

-- Execute lines line1..line2 from the current buffer (1-based).
db.execute_range(line1, line2)

-- Open the explorer for a specific connection by name.
db.open_explorer_for("prod-mssql")

-- Kill the backend process and clear all state.
db.stop()

-- Restart the backend process (stop + start, clears all state).
db.restart()

-- Save a query with a name and scope picker.
-- Reads the visual selection when in visual mode, otherwise the current line.
-- The file extension is taken from the current buffer.
db.save_query()

-- Open the saved-queries picker for conn_key, or the current buffer's connection if omitted.
db.load_query()
db.load_query("prod-mssql")

-- Open the query log for conn_key, or the current buffer's connection if omitted.
db.query_log()
db.query_log("prod-mssql")

-- Cancel the in-flight query whose gutter running icon sits on the cursor line.
-- Warns if the cursor is not over a running query.
db.cancel_query()
```

```lua
local conns = require("grannos.connections")

-- Load the full connections file: returns { server -> { driver -> { label, groups -> { group -> { name -> params } } } } }
conns.load_all()

-- Load connections for a specific server name.
conns.load("belvedere")

-- Delete a connection by its internal key.
conns.delete(key)

-- Open the new-connection wizard (caps from ensure_backend_with_caps).
conns.create(caps, function(key, params) ... end)
```
