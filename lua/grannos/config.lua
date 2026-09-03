local M = {}

--- Return the XDG-aware default path for connections.json.
--- @return string
local function default_connections_file()
  local xdg = vim.env.XDG_CONFIG_HOME or vim.fn.expand("~/.config")
  return xdg .. "/grannos/connections.json"
end

--- Return the XDG-aware default directory for saved queries.
--- @return string
local function default_queries_dir()
  local xdg = vim.env.XDG_DATA_HOME or vim.fn.expand("~/.local/share")
  return xdg .. "/grannos/queries"
end

M.defaults = {
  -- Command used to launch the server backend.
  server_cmd = "grannos",  -- or "python -m grannos"

  -- Path to the JSON file that stores named connections.
  -- Defaults to $XDG_CONFIG_HOME/grannos/connections.json
  connections_file = nil,  -- populated in setup() so the function runs at call time

  -- Directory that stores saved queries (one file per query).
  -- Defaults to $XDG_DATA_HOME/grannos/queries/
  queries_dir = nil,

  keymaps = {
    -- Describe the symbol (or panel item) under the cursor.
    hover_key = "K",

    -- Show execution info for the query under the cursor, in query buffers.
    query_info_key = "gK",

    -- Reveal the symbol under the cursor in the schema explorer, in query buffers.
    goto_symbol_key = "<C-]>",
  },

  -- When a driver has at most this many connections total, skip the group step
  -- and show all connections as "group/name" in a flat list.
  flat_conn_threshold = 5,

  completion = {
    -- Set 'omnifunc' on connected SQL buffers, so <C-x><C-o> completes table
    -- and column names. Only `explore.list` is ever sent, and the server
    -- caches each listing permanently, so a database sees one catalog query
    -- per schema/table touched and nothing thereafter.
    enabled = true,

    -- Upper bound on schemas swept to offer *unqualified* table names. A
    -- connection with more schemas than this offers schema names instead, so
    -- one keystroke can never turn into a listing per schema; qualifying the
    -- reference (`schema.`) always lists just that one.
    max_schema_scan = 5,
  },

  -- Results window options.
  results = {
    split     = "below",  -- "below" | "right"
    height    = 15,
    page_size = 500,

    -- Character inserted between digit groups in numeric cells (e.g. "1_234_567").
    -- Off by default for every column; press `t` on a results-pane cell to toggle
    -- it for that column. Set to false or "" to disable the feature entirely.
    thousands_separator = "_",

    -- Character used as the decimal point in numeric cells (e.g. "1234.56").
    -- Set to false or "" to display numbers with a literal "." decimal point.
    decimal_separator = ".",
  },
}

M.options = {}

--- Merge user options into defaults and populate path fields that require runtime evaluation.
--- @param user_opts table|nil
function M.setup(user_opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, user_opts or {})
  if not M.options.connections_file then
    M.options.connections_file = default_connections_file()
  end
  if not M.options.queries_dir then
    M.options.queries_dir = default_queries_dir()
  end
end

return M
