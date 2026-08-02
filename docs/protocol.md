# belvedere protocol

Communication between the **client** and the **server** uses newline-delimited JSON over stdio. The client spawns the server as a child process and communicates through its stdin/stdout pipes.

Multiple connections can be open simultaneously. Each `connect` call returns a `connection_id` that must be passed to all subsequent methods operating on that connection.

## Wire format

Each message is a single JSON object serialized on one line, terminated by `\n`. There is no envelope, framing header, or length prefix — a line boundary is a message boundary.

```
{"id":1,"method":"connect","params":{"driver":"sqlite","database":"/tmp/test.db"}}\n
{"id":1,"result":{"connection_id":"0"},"error":null}\n
```

## Message structure

### Request (client → server)

| Field    | Type            | Description                          |
|----------|-----------------|--------------------------------------|
| `id`     | integer         | Caller-chosen ID, echoed in response |
| `method` | string          | Method name (see below)              |
| `params` | object          | Method-specific parameters           |

### Response (server → client)

| Field    | Type            | Description                                  |
|----------|-----------------|----------------------------------------------|
| `id`     | integer or null | Matches the request `id`                     |
| `result` | any or null     | Return value on success; null on error       |
| `error`  | string or null  | Error message on failure; null on success    |

Requests are handled concurrently. Responses may arrive out of order — clients must correlate them by `id`.

---

## Protocol versioning

The server reports its wire-protocol version as `protocol_version` in the [`capabilities`](#capabilities) result, as a `"<major>.<minor>"` string (e.g. `"1.0"`).

- **`major`** bumps on any backward-incompatible change to an existing method's params or result shape (removed/renamed fields, changed semantics).
- **`minor`** bumps on additive, backward-compatible changes (new optional fields, new methods).

Clients should call `capabilities` once after starting the server and compare only the `major` component against the version they were built for. A `major` mismatch means the client and server disagree on the shape of the wire protocol and are not guaranteed to work together; a `minor` difference is always safe to ignore. A server that predates protocol versioning omits `protocol_version` entirely — treat that the same as a `major` mismatch.

---

## Progress notifications

Long-running methods may send one or more progress messages before the final response. A progress message carries a `progress` object and shares the same `id` as the originating request. The pending request stays open until the final `result`/`error` message arrives.

### Progress message (server → client)

| Field      | Type    | Description                             |
|------------|---------|-----------------------------------------|
| `id`       | integer | Matches the originating request `id`    |
| `progress` | object  | Status update (see below)               |

### Progress object

| Field     | Type   | Description                                                             |
|-----------|--------|-------------------------------------------------------------------------|
| `status`  | string | Machine-readable key (e.g. `"reconnecting"`, `"executing"`)            |
| `message` | string | Human-readable description                                              |

### Example

```
client → {"id":2,"method":"execute","params":{"connection_id":"0","query":"SELECT ..."}}
server → {"id":2,"progress":{"status":"reconnecting","message":"Connection lost, reconnecting…"}}
server → {"id":2,"progress":{"status":"executing","message":"Retrying query…"}}
server → {"id":2,"result":{"columns":[…],"rows":[…]},"error":null}
```

Methods that currently support progress: `execute`.

---

## Methods

### `capabilities`

Returns the server's name and the full list of drivers it supports, including the connection parameters each driver accepts. Clients should call this once after starting the server and use the result to drive connection wizards instead of hard-coding driver lists.

Only drivers whose dependencies are installed appear in the response.

**params** — none (`{}`)

**result**

| Field              | Type                       | Description                                          |
|--------------------|----------------------------|-------------------------------------------------------|
| `server`           | string                     | Human-readable server name (e.g. `"belvedere"`)      |
| `protocol_version` | string                     | Wire-protocol version as `"<major>.<minor>"` — see [Protocol versioning](#protocol-versioning) |
| `drivers`          | array of [Driver](#driver) | Supported drivers                                     |

**example**

```json
{"id":1,"method":"capabilities","params":{}}
```
```json
{
  "id": 1,
  "result": {
    "server": "belvedere",
    "protocol_version": "1.0",
    "drivers": [
      {
        "driver": "mydriver",
        "label": "My Driver",
        "params": [
          {"key": "host",     "type": "string",  "label": "Host",     "required": true},
          {"key": "port",     "type": "integer", "label": "Port",     "default": 5432},
          {"key": "password", "type": "string",  "label": "Password", "secret": true}
        ]
      }
    ]
  },
  "error": null
}
```

---

### `connect`

Opens a new database connection. Multiple connections can be open at the same time.

**params**

| Field          | Type             | Description                                                           |
|----------------|------------------|-----------------------------------------------------------------------|
| `driver`       | string           | See [Drivers](#drivers)                                               |
| `idle_timeout` | number (optional)| Seconds of inactivity before the server auto-closes the connection (default: `600`) |
| …              | …                | Driver-specific fields (see below)                                    |

**result**

| Field           | Type   | Description                              |
|-----------------|--------|------------------------------------------|
| `connection_id` | string | Opaque handle to pass to other methods   |

```json
{"connection_id": "0"}
```

---

### `disconnect`

Closes the specified connection.

**params**

| Field           | Type   | Description                        |
|-----------------|--------|------------------------------------|
| `connection_id` | string | Connection to close                |

**result**

```json
{"ok": true}
```

---

### `execute`

Runs a query and returns the result set.

The query language and bind parameter syntax depend on the driver — see [Drivers](#drivers).

**params**

| Field           | Type             | Description                        |
|-----------------|------------------|------------------------------------|
| `connection_id` | string           | Connection to execute on           |
| `query`         | string           | Query to execute                   |
| `params`        | array (optional) | Positional bind parameters         |

**result — SELECT / RETURN**

| Field         | Type              | Description                                        |
|---------------|-------------------|----------------------------------------------------|
| `columns`     | array of strings  | Column names, in order                             |
| `rows`        | array of arrays   | Each row is an array of values                     |
| `rows_total`  | integer           | Total number of rows matching the query            |
| `duration_ms` | number            | Wall-clock execution time in milliseconds          |

**result — INSERT / UPDATE / DELETE / write statements**

| Field           | Type    | Description                                 |
|-----------------|---------|---------------------------------------------|
| `rows_affected` | integer | Number of rows/nodes/relationships affected |
| `duration_ms`   | number  | Wall-clock execution time in milliseconds   |

**examples**

```json
{"id":2,"method":"execute","params":{"connection_id":"0","query":"SELECT id, name FROM users WHERE active = ?","params":[1]}}
{"id":2,"result":{"columns":["id","name"],"rows":[[1,"Alice"],[2,"Bob"]],"rows_total":2,"duration_ms":3.142},"error":null}
```

```json
{"id":3,"method":"execute","params":{"connection_id":"0","query":"DELETE FROM users WHERE active = 0"}}
{"id":3,"result":{"rows_affected":4,"duration_ms":1.05},"error":null}
```

#### Cell values

Each entry in a `rows` array is a plain JSON scalar (string, number, boolean), JSON `null` for
SQL `NULL`, a [LobPlaceholder](#lobplaceholder) object standing in for a large object value
(CLOB/BLOB/etc.) the server did not inline into the result set, or a
[SpecialFloat](#specialfloat) object standing in for a non-finite float value (NaN, +Inf, -Inf)
plain JSON cannot represent (e.g. from a Prometheus query like `1/0`).

---

### `cancel`

Cancels an in-flight request. The targeted request receives an error response with `"cancelled"` as the error message. If the request has already completed, or the `request_id` is not recognised, the call is a no-op and still returns `{"ok": true}`.

**params**

| Field        | Type    | Description                        |
|--------------|---------|------------------------------------|
| `request_id` | integer | `id` of the request to cancel      |

**result**

```json
{"ok": true}
```

**example**

```
client → {"id":4,"method":"cancel","params":{"request_id":2}}
server → {"id":4,"result":{"ok":true},"error":null}
server → {"id":2,"result":null,"error":"cancelled"}
```

The `cancel` response and the cancelled request's error response may arrive in either order.

---

### `explore.list`

Returns the children of a node in the database object tree. The tree is navigated by a `path` — an ordered list of node names from the root.

**params**

| Field           | Type             | Description                                    |
|-----------------|------------------|------------------------------------------------|
| `connection_id` | string           | Connection to explore                          |
| `path`          | array of strings | Path to the node whose children are requested  |
| `reset_cache`   | boolean (optional, default `false`) | Evict cached explore data for `path` and all nodes below it before fetching |

**result**

| Field   | Type              | Description             |
|---------|-------------------|-------------------------|
| `items` | array of [ExploreItem](#exploreitem) | Child nodes |

**example**

```json
{"id":3,"method":"explore.list","params":{"connection_id":"0","path":[]}}
```
```json
{"id":3,"result":{"items":[{"name":"public","type":"schema","expandable":true}]},"error":null}
```

---

### `explore.describe`

Returns detailed metadata about a specific node.

**params**

| Field           | Type             | Description            |
|-----------------|------------------|------------------------|
| `connection_id` | string           | Connection to query    |
| `path`          | array of strings | Path to the node       |
| `reset_cache`   | boolean (optional, default `false`) | Evict cached explore data for `path` and all nodes below it before fetching |

**result**

| Field     | Type                       | Description                    |
|-----------|----------------------------|---------------------------------|
| `details` | object, array, or null     | Description, or null if the path does not resolve to a describable node. A path that names a *group* of items (e.g. an indexes group `["public", "users", "indexes"]`, or a driver-specific group like a Prometheus job's targets) returns a bare array of the singular type instead of a wrapper object — a group's element type depends on which group it is. Either way, discriminate each object on its own `type` field: `"entity"` → [EntityDescription](#entitydescription), `"field"` → [FieldDescription](#fielddescription), `"index"` → [IndexDescription](#indexdescription), `"relationship"` → [TableReference](#tablereference), `"document"` → [RawDocument](#rawdocument), `"generic_record"` → [GenericRecordDescription](#genericrecorddescription). |

A field's own detail — samples, comments, index membership, FK references — is already embedded in its parent [EntityDescription](#entitydescription)'s `properties`; describing `[..., "columns", field_name]` (or the equivalent per-driver field-group segment) re-fetches that same field standalone, e.g. to refresh a single field without re-describing the whole entity. There is no group-level "list all fields" path — that's redundant with the parent entity's own `properties`.

---

### `explore.preview`

Returns a sample of up to 10 rows from the node at the given path. Only supported for table, view, collection, and GridFS bucket nodes; returns null fields for unsupported node types.

**params**

| Field           | Type             | Description            |
|-----------------|------------------|------------------------|
| `connection_id` | string           | Connection to query    |
| `path`          | array of strings | Path to the node       |

**result**

| Field         | Type              | Description                                        |
|---------------|-------------------|----------------------------------------------------|
| `columns`     | array of strings or null | Column names, in order; null if not supported |
| `rows`        | array of arrays or null  | Up to 10 rows; null if not supported         |
| `rows_total`  | integer or null   | Total rows returned                                |
| `duration_ms` | number            | Wall-clock execution time in milliseconds          |

**example**

```json
{"id":6,"method":"explore.preview","params":{"connection_id":"0","path":["public","users"]}}
{"id":6,"result":{"columns":["id","name"],"rows":[[1,"Alice"],[2,"Bob"]],"rows_total":2,"duration_ms":1.5},"error":null}
```

---

### `explore.diagram`

Returns an ASCII diagram of the table at the given path and every table connected to it, recursively, via foreign keys (both outgoing and incoming). Connected tables that are themselves connected to further tables are expanded too, so the diagram can cover an entire connected region of the schema, not just the immediate neighbours of `path`.

The diagram is rendered as a vertical tree: the root table's box is printed first, and each related table is nested underneath it, indented, and connected to its parent by a line naming the join columns. A table that is reachable by more than one path (a cycle, or a table referenced from two places) is only drawn once — later references to it appear as a plain text pointer instead of a duplicate box. The text has no line-wrap applied and assumes the client will render it without wrapping; boxes are sized to their content and the tree aims for roughly 120 columns wide, but width is not capped.

Only supported for table/view nodes; if `path` does not resolve to a table, the request returns an error.

**params**

| Field           | Type             | Description            |
|-----------------|------------------|-------------------------|
| `connection_id` | string           | Connection to query     |
| `path`          | array of strings | Path to the table       |

**result**

| Field     | Type                                    | Description                                                     |
|-----------|------------------------------------------|-------------------------------------------------------------------|
| `diagram` | string                                   | ASCII diagram, as a multi-line string                             |
| `regions` | array of [DiagramRegion](#diagramregion) | Byte-offset spans identifying the table, column, or relationship drawn at each point in `diagram`, so a client can resolve a cursor position to an `explore.describe` path without parsing the diagram text itself |

**example**

```json
{"id":7,"method":"explore.diagram","params":{"connection_id":"0","path":["users"]}}
```
```json
{
  "id": 7,
  "result": {
    "diagram": "┌─ users ───────────┐\n│ id    INTEGER  PK │\n│ name  TEXT        │\n└───────────────────┘\n└── orders.user_id → id\n    ┌─ orders ─────────────┐\n    │ id       INTEGER  PK │\n    │ user_id  INTEGER  FK │\n    │ total    REAL        │\n    └──────────────────────┘",
    "regions": [
      { "row": 0, "col_start": 0,  "col_end": 49, "kind": "table",  "path": ["users"] },
      { "row": 1, "col_start": 0,  "col_end": 3,  "kind": "table",  "path": ["users"] },
      { "row": 1, "col_start": 4,  "col_end": 6,  "kind": "column", "path": ["users", "columns", "id"] },
      { "row": 1, "col_start": 22, "col_end": 25, "kind": "table",  "path": ["users"] },
      { "row": 2, "col_start": 0,  "col_end": 3,  "kind": "table",  "path": ["users"] },
      { "row": 2, "col_start": 22, "col_end": 25, "kind": "table",  "path": ["users"] },
      { "row": 3, "col_start": 0,  "col_end": 63, "kind": "table",  "path": ["users"] },
      { "row": 4, "col_start": 0,  "col_end": 3,  "kind": "edge",   "path": ["orders", "relationships", "user_id"] },
      { "row": 4, "col_start": 3,  "col_end": 20, "kind": "edge",   "path": ["orders", "relationships", "user_id"] },
      { "row": 4, "col_start": 10, "col_end": 16, "kind": "table",  "path": ["orders"] },
      { "row": 5, "col_start": 0,  "col_end": 60, "kind": "table",  "path": ["orders"] },
      { "row": 6, "col_start": 4,  "col_end": 7,  "kind": "table",  "path": ["orders"] },
      { "row": 6, "col_start": 29, "col_end": 32, "kind": "table",  "path": ["orders"] },
      { "row": 7, "col_start": 4,  "col_end": 7,  "kind": "table",  "path": ["orders"] },
      { "row": 7, "col_start": 29, "col_end": 32, "kind": "table",  "path": ["orders"] },
      { "row": 8, "col_start": 4,  "col_end": 7,  "kind": "table",  "path": ["orders"] },
      { "row": 8, "col_start": 29, "col_end": 32, "kind": "table",  "path": ["orders"] },
      { "row": 9, "col_start": 0,  "col_end": 76, "kind": "table",  "path": ["orders"] }
    ]
  },
  "error": null
}
```

The two `kind: "edge"` regions above both carry the identical `path` — they're the two halves of the same join-label line (`└──` and `orders.user_id → id`). A relationship spanning several rows (e.g. a vertical trunk bar connecting a branch point to a sibling several lines below) emits one region per row it touches, all sharing that same `path`; a client can group regions by `path` to treat them as a single edge (for highlighting or hover) without parsing the tree layout itself.

A table is covered by more than one `kind: "table"` region the same way: its name, plus its box's top and bottom border rows in full (rows 0 and 3 for `users` above), plus — on **every** interior row — a region for just the left border character and another for just the right border character (never the whole row, so they never overlap that row's `kind: "column"` region — see rows 1, 2, 6, 7, and 8 above, each contributing two narrow `kind: "table"` regions). Skipping these interior-row pairs is the most common implementation gap: without them, a client that colors each table's box per-`path` will render the header and footer correctly but leave every column row's `│ │` uncolored. All of a table's regions share that table's `path`, letting a client group them to treat the whole box outline as belonging to one table (e.g. to color each table's box distinctly) without re-deriving box geometry from the diagram text itself.

(truncated for columns/relationships elsewhere — but every row of the `users` and `orders` boxes above is now fully enumerated as a concrete, complete example of the table-region convention)

---

### `explore.download`

Fetches the full content of a node — e.g. an S3 object, a GridFS file, or a LOB cell from a previous `execute` result — for a client to either load into a buffer or have written straight to a local file. Unlike `explore.list`/`explore.describe`, results are never cached: every call re-fetches from the driver.

**params**

| Field           | Type             | Description                                                                 |
|-----------------|------------------|-------------------------------------------------------------------------------|
| `connection_id` | string           | Connection to query                                                          |
| `path`          | array of strings (optional) | Path to a tree node (e.g. an S3 object or GridFS file). Exactly one of `path`/`ref` must be given. |
| `ref`           | string (optional) | A [LobPlaceholder](#lobplaceholder)'s `ref` value, for downloading a LOB cell from an earlier result row. Exactly one of `path`/`ref` must be given. |
| `dest_path`     | string (optional) | Local filesystem path. When given, the driver writes content directly to this path — the backend is always a local subprocess (spawned by the client, no network hop), so this needs no round trip through the client. When omitted, content comes back inline as `content_base64`. |

**result**

| Field            | Type    | Description                                                              |
|------------------|---------|----------------------------------------------------------------------------|
| `content_base64` | string or null | Full content, base64-encoded (content may be binary). Set when `dest_path` was omitted; null otherwise. |
| `written_to`     | string or null | Echoes `dest_path`. Set when `dest_path` was given; null otherwise.  |
| `filename`       | string  | Suggested filename, e.g. the S3 object's key basename                     |
| `content_type`   | string  | MIME type as reported by the driver, e.g. `"text/plain"`, `"application/octet-stream"` |
| `size`           | integer | Size of the content in bytes                                              |

Exactly one of `content_base64`/`written_to` is non-null in any response, matching whether the request carried `dest_path`.

**examples**

```json
{"id":8,"method":"explore.download","params":{"connection_id":"0","path":["my-bucket","logs","2024","access.log"]}}
{"id":8,"result":{"content_base64":"SGVsbG8sIHdvcmxkIQ==","written_to":null,"filename":"access.log","content_type":"text/plain","size":13},"error":null}
```

```json
{"id":9,"method":"explore.download","params":{"connection_id":"0","ref":"3f2a1c9e...","dest_path":"/home/user/downloads/report.pdf"}}
{"id":9,"result":{"content_base64":null,"written_to":"/home/user/downloads/report.pdf","filename":"report.pdf","content_type":"application/pdf","size":483920},"error":null}
```

A driver returning `content_base64` (no `dest_path`) should reject content above some size threshold with an error rather than inlining an arbitrarily large payload — clients loading the result into a Neovim buffer are not equipped to page a multi-gigabyte download. No such limit applies when `dest_path` is given, since content is streamed to disk rather than held in memory as a whole.

---

### `driver.help`

Returns documentation for a specific driver as a markdown string. Clients should display this in a help buffer when the user requests driver-specific documentation.

**params**

| Field    | Type   | Description                                          |
|----------|--------|------------------------------------------------------|
| `driver` | string | Driver identifier (as returned by `capabilities`)    |

**result**

| Field     | Type   | Description                        |
|-----------|--------|------------------------------------|
| `content` | string | Driver documentation in Markdown   |

**example**

```json
{"id":5,"method":"driver.help","params":{"driver":"mydriver"}}
```
```json
{"id":5,"result":{"content":"# My Driver\n\nQuery language: ..."},"error":null}
```

---

### `session.set`

Changes one or more of a live connection's [session_params](#driver) values. Unlike `connect.params`, these are held only in memory on the server — never written to a saved connection — and take effect immediately without reconnecting. A driver with no `session_params` rejects this call with an error.

**params**

| Field           | Type   | Description                                                    |
|-----------------|--------|------------------------------------------------------------------|
| `connection_id` | string | Connection to update                                              |
| …               | …      | Driver-specific fields, per that driver's `session_params`        |

**result**

```json
{"ok": true}
```

**example**

```json
{"id":6,"method":"session.set","params":{"connection_id":"0","query_mode":"range"}}
```
```json
{"id":6,"result":{"ok":true},"error":null}
```

---

### `session.get`

Returns a live connection's current `session_params` values — e.g. to restore UI state after reopening the connections panel, since these settings aren't persisted anywhere the client already holds them.

**params**

| Field           | Type   | Description             |
|-----------------|--------|--------------------------|
| `connection_id` | string | Connection to query      |

**result**

Driver-specific fields, per that driver's `session_params`.

**example**

```json
{"id":7,"method":"session.get","params":{"connection_id":"0"}}
```
```json
{"id":7,"result":{"query_mode":"range"},"error":null}
```

---

## Driver

Each entry in the `capabilities.drivers` array:

| Field       | Type                              | Description                                     |
|-------------|-----------------------------------|-------------------------------------------------|
| `driver`    | string                            | Driver identifier; passed as `driver` in `connect.params` |
| `label`     | string                            | Human-readable display name (e.g. `"SQLite"`, `"SQL Server"`) |
| `params`    | array of [DriverParam](#driverparam) | Connection parameters, in display order      |
| `session_params` | array of [DriverParam](#driverparam) | Runtime-only settings changeable on a live connection via [`session.set`](#sessionset)/[`session.get`](#sessionget) — never sent as part of `connect.params` and never persisted alongside a saved connection. Empty when the driver has no such settings. |
| `supports_writes` | boolean                          | Whether this driver's query language can express write operations. `false` for a genuinely read-only driver (e.g. Prometheus/PromQL) — clients should hide write-related connection settings (e.g. "always allow writes") for such drivers. Defaults to `true`. |
| `languages` | array of [Language](#language)    | Query languages this driver supports. Empty when the driver has no language affinity. |

## Language

String enum of standard query-language identifiers used in `Driver.languages`:

| Value      | Language                |
|------------|-------------------------|
| `"sql"`    | Structured Query Language (SQL) |
| `"cypher"` | Cypher graph query language (Neo4j) |
| `"promql"` | Prometheus Query Language (PromQL) |

Mapping these to editor-specific concepts (e.g. Vim filetypes) is the client's responsibility.

## DriverParam

| Field      | Type    | Required | Description                                                        |
|------------|---------|----------|--------------------------------------------------------------------|
| `key`      | string  | yes      | Parameter key sent in `connect.params`                             |
| `type`     | string  | yes      | `"string"`, `"integer"`, or `"enum"`                               |
| `label`    | string  | yes      | Human-readable label for UI display                                |
| `required` | boolean | no       | Whether a non-empty value is required (default `true`)             |
| `default`  | string or integer | no | Default value pre-filled in the UI                       |
| `choices`  | array of [DriverParamChoice](#driverparamchoice) | for `"enum"` | Allowed options |
| `secret`   | boolean | no       | Mask input in the UI (e.g. for passwords); never persisted to disk |

## DriverParamChoice

| Field   | Type   | Description                                    |
|---------|--------|------------------------------------------------|
| `value` | string | Machine-readable value sent in `connect.params` |
| `label` | string | Human-readable display name shown in the UI    |

---

## ExploreItem

Each item returned by `explore.list` has this shape:

| Field        | Type    | Description                                      |
|--------------|---------|--------------------------------------------------|
| `name`       | string  | Display name of the node                         |
| `type`       | string  | Node kind (e.g. `"schema"`, `"table"`, `"group"`, `"index"`) |
| `expandable` | boolean | Whether the node has children                    |

The `"group"` type is used for intermediate organisational nodes that bundle sub-categories (e.g. `columns`, `indices`). These nodes are not database objects themselves.

---

## TableReference

One foreign key, read as `table.column -> ref_table.ref_column`: `table`/`column` always name the side that **owns** the FK constraint, `ref_table`/`ref_column` always name the side it points at — regardless of which direction the reference was reached from. This same shape is used three ways:

- Standalone, as `details` for a path ending in `["relationships", <column>]` (a path emitted by [`explore.diagram`](#explorediagram)'s `regions`, e.g. `["public", "orders", "relationships", "user_id"]`) — `type` is `"relationship"` there.
- Embedded in a [FieldDescription](#fielddescription)'s `outgoing_references`, where `table`/`schema` restate the embedding field's own entity (since it owns the FK).
- Embedded in a [FieldDescription](#fielddescription)'s `incoming_references`, where `ref_table`/`ref_schema` restate the embedding field's own entity instead (since some other entity owns the FK there).

| Field             | Type            | Description                                                     |
|-------------------|-----------------|-------------------------------------------------------------------|
| `type`            | string          | Always `"relationship"` — use to discriminate description types |
| `table`           | string          | Name of the table that owns the FK constraint                   |
| `column`          | string          | The owning table's own FK column                                 |
| `ref_table`       | string          | Name of the referenced table                                     |
| `ref_column`      | string          | Column on the referenced table                                   |
| `schema`          | string or null  | Schema of the owning table, or null for databases without schema support |
| `ref_schema`      | string or null  | Schema of the referenced table, or null for databases without schema support |
| `unique`          | boolean         | Whether `column` is itself constrained to unique values on `table` (by a PK or a single-column UNIQUE index), making the relationship one-to-one rather than many-to-one (default `false`) |
| `constraint_name` | string or null  | Foreign key constraint name, or null if unnamed/unsupported      |

---

## Connection

Graph databases only (e.g. Neo4j): one observed `(relationship type, start label, end label)` triple, embedded in an [EntityDescription](#entitydescription)'s `connections`. Unlike [TableReference](#tablereference), a graph relationship isn't anchored to any field — it's a free-floating typed edge between node instances — so this has no per-field home and is never independently describable on its own path.

| Field        | Type   | Description                              |
|--------------|--------|--------------------------------------------|
| `rel_type`   | string | Relationship type name                     |
| `from_label` | string | Label of the relationship's start node     |
| `to_label`   | string | Label of the relationship's end node       |

---

## EntityDescription

Returned as `details` by `explore.describe` for a table/view node (SQL drivers) or a node label / relationship type (graph drivers):

| Field         | Type                                          | Description                                              |
|---------------|------------------------------------------------|----------------------------------------------------------|
| `type`        | string                                        | Always `"entity"` — use to discriminate description types |
| `name`        | string                                        | Entity name (table name, node label, or relationship type) |
| `kind`        | string                                        | Domain-specific classification (e.g. `"table"`, `"view"`, `"node"`, `"relationship"`, `"document"`), for clients that want a domain-appropriate icon/label. Not a wire discriminator — use `type` for that. |
| `properties`  | array of [FieldDescription](#fielddescription) | Full metadata for every field on this entity            |
| `schema`      | string or null                                | Schema name, or null for databases without schema support |
| `comment`     | string or null                                | Entity comment as stored in the database; null if unsupported or not set |
| `connections` | array of [Connection](#connection)            | Graph databases only: relationship types touching this entity and the label(s) they connect to/from. Empty for non-graph entities. |

---

## IndexKeyField

One field in an index key, used inside [IndexDescription](#indexdescription):

| Field       | Type   | Description                                                                 |
|-------------|--------|-----------------------------------------------------------------------------|
| `name`      | string | Field name                                                                  |
| `direction` | string | Sort direction or index kind (`"asc"`, `"desc"`, `"text"`, `"hashed"`, …)  |

---

## IndexDescription

Returned as `details` by `explore.describe` for a single index node, or as an element of the bare array returned for an indexes group node (e.g. `["public", "users", "indexes"]`), and embedded in a [FieldDescription](#fielddescription)'s `exclusive_indices`/`composite_indices`:

| Field               | Type                                     | Description                                                                                              |
|---------------------|------------------------------------------|----------------------------------------------------------------------------------------------------------|
| `type`              | string                                   | Always `"index"` — use to discriminate description types                                                 |
| `name`              | string                                   | Index name                                                                                               |
| `fields`            | array of [IndexKeyField](#indexkeyfield) | Ordered list of key fields                                                                               |
| `unique`            | boolean                                  | Whether the index enforces uniqueness (default `false`)                                                  |
| `tables`            | array of strings                         | Tables (or labels/collections) the index operates on. Typically one entry; multiple for Oracle cluster indexes and SQL Server indexed views |
| `index_type`        | string or null                           | Storage type as reported by the driver (e.g. `"btree"`, `"hash"`, `"bitmap"`, `"text"`, `"hashed"`); `null` if unknown |
| `clustered`         | boolean                                  | Whether the index defines the physical row order of the table (default `false`)                          |
| `visible`           | boolean                                  | Whether the query optimiser considers this index (default `true`); `false` for Oracle `INVISIBLE` or SQL Server `DISABLED` indexes |
| `included_columns`  | array of strings                         | Non-key columns stored in index leaf pages for covering queries (PostgreSQL / SQL Server `INCLUDE`); empty when not supported |
| `ddl`               | string or null                           | `CREATE INDEX` statement as stored by the database, or the partial filter expression for drivers without DDL (e.g. MongoDB); `null` when the driver cannot produce it |

---

## FieldDescription

Full metadata for a single field (column, property, …) — either embedded in an [EntityDescription](#entitydescription)'s `properties`, or returned as `details` standalone for a path ending in `["columns", <field_name>]` (or the equivalent per-driver field-group segment, e.g. `["public", "users", "columns", "id"]`). One shape for both; no lighter embedded variant.

| Field                  | Type                                           | Description                                                              |
|------------------------|-------------------------------------------------|---------------------------------------------------------------------------|
| `type`                 | string                                         | Always `"field"` — use to discriminate description types                 |
| `name`                 | string                                         | Field name                                                               |
| `types`                | array of strings                               | Data type(s) as reported by the database. Single-element for SQL columns; schemaless stores (e.g. Neo4j properties) may report more than one when the same key holds different types across instances. |
| `nullable`             | boolean or null                                | Whether the field allows a missing/NULL value; null if unknown           |
| `pk`                   | boolean                                        | Whether the field is part of the primary key. Always `false` where not applicable. |
| `default`              | string or null                                 | Default expression, or null if not set/not applicable                    |
| `exclusive_indices`    | array of [IndexDescription](#indexdescription) | Indices that cover only this field                                       |
| `composite_indices`    | array of [IndexDescription](#indexdescription) | Indices that cover this field and at least one other field               |
| `comment`              | string or null                                 | Field comment as stored in the database; null if unsupported or not set  |
| `sample`               | array                                          | Up to 3 distinct non-null representative values sampled from the field   |
| `outgoing_references`  | array of [TableReference](#tablereference)     | Foreign keys defined on this field that reference another entity. Empty if this field is not a foreign key. A field can carry more than one entry — either because it participates in more than one single-column FK constraint (each naming a different target), or because it is one leg of multiple composite FK constraints. |
| `incoming_references`  | array of [TableReference](#tablereference)     | Foreign keys on other entities that reference this field. Empty if nothing references this field. |

---

## RawDocument

Returned as `details` by `explore.describe` for a node whose natural representation is a single opaque text document rather than tabular metadata — e.g. a driver's running configuration file.

| Field      | Type   | Description                                                              |
|------------|--------|---------------------------------------------------------------------------|
| `type`     | string | Always `"document"` — use to discriminate description types              |
| `filetype` | string | Content's format, as a lowercase language/filetype hint (e.g. `"yaml"`, `"json"`, `"ini"`). Free-form, not a fixed enum — drivers surface whatever format their backend natively produces. Clients can use it to pick a syntax highlighter. |
| `content`  | string | The document's full text content                                         |

```json
{"type": "document", "filetype": "yaml", "content": "global:\n  scrape_interval: 15s\n"}
```

---

## GenericRecordDescription

Returned as `details` by `explore.describe` — either standalone, or as an element of the bare array returned for a group node — for a node whose natural representation is a flat set of driver-specific fields that don't fit any of the other description shapes (e.g. a Prometheus scrape target's URL, health, and last-scrape duration). This is the escape hatch for driver-specific detail views: unlike `entity`/`field`/`index`/`relationship`/`document`, the wire protocol makes no shape guarantee beyond a label/value list, so it never requires a protocol version bump to introduce a new kind of record.

| Field   | Type                        | Description                                                                 |
|---------|-----------------------------|-------------------------------------------------------------------------------|
| `type`  | string                      | Always `"generic_record"` — use to discriminate description types            |
| `kind`  | string                      | Namespaced, driver-owned label identifying what this record represents (e.g. `"prometheus.target"`). Clients may key an optional dedicated renderer off this; unrecognized kinds should fall back to a generic label/value rendering of `fields`. |
| `name`  | string                      | Display name for this record (e.g. the target's instance label)              |
| `fields`| array of [RecordField](#recordfield) | Ordered list of label/value pairs                                    |

```json
{"type": "generic_record", "kind": "prometheus.target", "name": "10.0.0.12:9100", "fields": [
  {"label": "Scrape URL", "value": "http://10.0.0.12:9100/metrics"},
  {"label": "Health", "value": "up"},
  {"label": "Last Scrape Duration", "value": "12.4ms"}
]}
```

---

## RecordField

One label/value pair in a [GenericRecordDescription](#genericrecorddescription)'s `fields`:

| Field   | Type   | Description                          |
|---------|--------|---------------------------------------|
| `label` | string | Display label (e.g. `"Scrape URL"`)  |
| `value` | string | Display value, pre-formatted by the driver |

---

## LobPlaceholder

Stands in for a large object value (CLOB, BLOB, etc.) inside a `rows` cell when the server elects
not to inline the full value into the result set. Tagging the value with an object — rather than
returning a formatted string like `"CLOB (3423 chars)"` — lets clients distinguish it from a real
string value on the wire, instead of pattern-matching cell contents.

| Field  | Type           | Description                                                              |
|--------|----------------|---------------------------------------------------------------------------|
| `type` | string         | Always `"lob"` — discriminates this value from a plain string cell       |
| `text` | string         | Server-formatted placeholder text to display (e.g. `"CLOB (3423 chars)"`) |
| `ref`  | string or null | Opaque token a client can pass as [`explore.download`](#exploredownload)'s `ref` param to fetch this cell's full content later, without re-running the query. Null when the driver can't support re-fetching it (e.g. a LOB locator that becomes invalid once its cursor closes) — the cell is then purely informational. |

```json
{"type": "lob", "text": "CLOB (3423 chars)", "ref": "3f2a1c9e8b7d4f6a9c0e1b2d3a4f5e6c"}
```

```json
{"type": "lob", "text": "CLOB (3423 chars)", "ref": null}
```

---

## SpecialFloat

Stands in for a non-finite float value (NaN, +Inf, -Inf) inside a `rows` cell. Plain JSON has no
way to represent these — `json.dumps` would otherwise emit the non-standard `NaN`/`Infinity`/
`-Infinity` tokens, which strict decoders (including this client's `vim.json.decode`) reject
outright. Tagging the value with an object — rather than a bare string like `"NaN"` — also lets
clients distinguish it from a real string cell without pattern-matching cell contents. Currently
only produced by the Prometheus driver (e.g. a PromQL expression like `1/0`).

| Field  | Type   | Description                                                    |
|--------|--------|-----------------------------------------------------------------|
| `type` | string | Always `"special_float"` — discriminates this value from a plain string cell |
| `text` | string | Display text, e.g. `"NaN"`, `"+Inf"`, `"-Inf"`                  |

```json
{"type": "special_float", "text": "NaN"}
```

## DiagramRegion

One span in the `diagram` string returned by [`explore.diagram`](#explorediagram) that names a table, column, or relationship — in a box header, a box border row/character, a join-label line, a connector/trunk character, or a plain-text pointer. Lets a client resolve a cursor position to an `explore.describe` path without parsing the diagram text itself.

`row` and `col_start`/`col_end` are all **0-indexed**. `row` counts lines of `diagram` as split on `\n`, starting from `0`. `col_start`/`col_end` are byte offsets into that line (not codepoints or display columns), also starting from `0`; `col_end` is exclusive. Note this differs from `nvim_win_get_cursor()`, whose row is 1-indexed — clients must subtract 1 from the cursor row before comparing against `row`.

A relationship (`kind: "edge"`) is typically covered by several regions — one per row its connector characters touch, including any vertical trunk bars linking a branch point to a sibling box further down — all sharing the same `path`. Clients should group edge regions by `path` to treat them as one edge (e.g. for highlighting or hover), rather than assuming one region per edge.

A table (`kind: "table"`) is likewise typically covered by several regions: its name, its box's top and bottom border rows in full, and — on **every** interior row, not just some — a region for the left border character and a separate region for the right border character (never the whole row, so these never overlap that row's `kind: "column"` region). Omitting the interior-row pair on any row is a common implementation mistake: it leaves that row's `│ │` uncolored even though the header/footer render correctly. All of a table's regions share the table's `path`, so clients can group by `path` to treat the box outline as one unit (e.g. to color each table's box distinctly), without parsing box geometry out of the diagram text.

| Field       | Type             | Description                                                                 |
|-------------|------------------|-------------------------------------------------------------------------------|
| `row`       | integer          | 0-indexed line number within `diagram`                                       |
| `col_start` | integer          | 0-indexed byte offset where the span starts                                  |
| `col_end`   | integer          | 0-indexed byte offset where the span ends (exclusive)                        |
| `kind`      | string           | `"table"`, `"column"`, or `"edge"` — discriminates what `path` names, without the client having to infer it from `path`'s shape |
| `path`      | array of strings | Path to pass as `explore.describe`'s `path` param to describe this table, column, or relationship |

---

## Drivers

The `driver` field in `connect.params` selects the backend. Connection parameters accepted by each driver are announced at runtime via [`capabilities`](#capabilities). Query language, bind syntax, and explore tree structure are driver-specific and documented by the server implementation.
