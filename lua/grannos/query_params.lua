-- Query parameters: `{{name}}` placeholders in a SQL query, filled in through
-- a prompt at execution time and sent as real bind parameters.
--
-- `{{name}}` is a scalar, bound once per occurrence. `{{name[]}}` is a list,
-- expanded to one bind per item so it can stand inside `IN (...)`; an empty
-- list becomes `NULL`, which `IN (NULL)` matches nothing against rather than
-- failing as `IN ()` would. Every value is bound as a string: each SQL driver
-- coerces a string bind to the column's type (Postgres binds it as `unknown`).
--
-- The braces are no SQL dialect's syntax, so a placeholder never shadows a
-- real bind marker, and the SQL grammar recovers around one without losing
-- the statement it sits in. Placeholders inside string literals, quoted
-- identifiers, dollar-quoted strings and comments are left alone.
--
-- Elasticsearch Dev Tools requests take placeholders too, but Elasticsearch
-- has no bind parameters: the value is written into the request text, encoded
-- for where the placeholder stands. The `esconsole` grammar tells where: a
-- `parameter` node in a path or query string is URL-encoded, one standing as
-- a JSON value becomes a JSON literal (a number, boolean or null as typed,
-- anything else a string; a list an array), and one inside a JSON string is
-- escaped as string content (a list joined with commas).
--
-- A comment line (`--`, `#` or `//`) that starts with a placeholder declares
-- it instead:
--
--   -- {{status}}: Order status = active | shipped | cancelled
--
-- Everything after the placeholder (and an optional colon) describes it; a
-- trailing `= a | b | c` lists the values its prompt offers in a dropdown.
local M = {}

--- The bind marker each SQL driver's DB-API module expects, given the
--- 1-indexed position of the bind. Drivers absent here take no parameters.
--- @type table<string, fun(i: integer): string>
local MARKERS = {
  postgres  = function() return "%s" end,
  sqlite    = function() return "?" end,
  duckdb    = function() return "?" end,
  sqlserver = function() return "?" end,
  oracle    = function(i) return ":" .. i end,
}

--- Drivers whose module reads the query as a format string once binds are
--- given, so every literal `%` must be doubled.
local PERCENT_ESCAPED = { postgres = true }

--- Drivers whose placeholders are substituted into the request text, which
--- is in the `esconsole` dialect. Only in Dev Tools mode (see `M.dialect`).
local CONSOLE_DRIVERS = { elasticsearch = true }

--- Values last submitted, per connection key then parameter name, to prefill
--- the next prompt.
--- @type table<string, table<string, string|string[]>>
local last_values = {}

--- @class QueryParam
--- @field name string
--- @field list boolean  true for `{{name[]}}`

--- @class ParamDeclaration
--- @field description string|nil
--- @field choices     string[]|nil  the values the prompt offers, in order

--- @class ParamToken
--- @field s       integer  1-indexed byte where the placeholder starts
--- @field e       integer  1-indexed byte where it ends (inclusive)
--- @field name    string
--- @field list    boolean
--- @field context "path"|"value"|"string"|nil  where an esconsole placeholder stands

--- Return every placeholder in `sql`, in order, skipping quoted text and comments.
--- @param sql string
--- @return ParamToken[]
local function scan(sql)
  local tokens = {}
  local i, n = 1, #sql
  while i <= n do
    local c  = sql:sub(i, i)
    local c2 = sql:sub(i, i + 1)
    if c == "'" or c == '"' or c == "`" then
      -- '' (or "") inside the quotes is an escaped quote: the scan just closes
      -- and reopens, which skips the same text.
      local close = sql:find(c, i + 1, true)
      i = close and close + 1 or n + 1
    elseif c2 == "--" then
      local nl = sql:find("\n", i, true)
      i = nl and nl + 1 or n + 1
    elseif c2 == "/*" then
      local close = sql:find("*/", i + 2, true)
      i = close and close + 2 or n + 1
    elseif c == "$" and sql:match("^%$[%a_]*[%w_]*%$", i) then
      local tag   = sql:match("^%$[%a_]*[%w_]*%$", i)
      local close = sql:find(tag, i + #tag, true)
      i = close and close + #tag or n + 1
    elseif c2 == "{{" then
      local s, e, name, brackets = sql:find("^{{%s*([%a_][%w_]*)(%[?%]?)%s*}}", i)
      if s and (brackets == "" or brackets == "[]") then
        tokens[#tokens + 1] = { s = s, e = e, name = name, list = brackets == "[]" }
        i = e + 1
      else
        i = i + 2
      end
    else
      i = i + 1
    end
  end
  return tokens
end

--- Placeholder pattern anchored at its opening braces: captures the name and
--- the list marker (`[]`, or "" for a scalar).
local PLACEHOLDER = "{{%s*([%a_][%w_]*)(%[?%]?)%s*}}"

--- Where a `parameter` node's parent puts it, for encoding its value.
local CONSOLE_CONTEXT = {
  segment        = "path",
  param_value    = "path",
  string_content = "string",
}

--- Return every placeholder in Console request text `text`, in order, from
--- the `esconsole` grammar's `parameter` nodes — so ones in comments are
--- skipped and ones inside JSON strings are found. Nil when the parser is
--- not installed.
--- @param text string
--- @return ParamToken[]|nil
local function scan_console(text)
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, "esconsole")
  if not ok or not parser then return nil end
  local tree = parser:parse()[1]
  if not tree then return nil end
  local tokens = {}
  --- Collect the parameter nodes under `node`, depth first.
  --- @param node userdata
  local function walk(node)
    for child in node:iter_children() do
      if child:type() == "parameter" then
        local _, _, sb = child:start()
        local _, _, eb = child:end_()
        local name, brackets = text:sub(sb + 1, eb):match("^" .. PLACEHOLDER .. "$")
        if name then
          tokens[#tokens + 1] = {
            s = sb + 1, e = eb, name = name, list = brackets == "[]",
            context = CONSOLE_CONTEXT[node:type()] or "value",
          }
        end
      else
        walk(child)
      end
    end
  end
  walk(tree:root())
  return tokens
end

--- Return the placeholders of `text` in `dialect`.
--- @param text    string
--- @param dialect "sql"|"esconsole"|nil  nil is "sql"
--- @return ParamToken[]|nil  nil when the dialect's parser is not installed
local function tokens_of(text, dialect)
  if dialect == "esconsole" then return scan_console(text) end
  return scan(text)
end

--- Strip one pair of matching quotes around `value`, so a choice written the
--- way SQL quotes a string (`'active'`) offers the bare value.
--- @param value string
--- @return string
local function unquote(value)
  local q = value:sub(1, 1)
  if #value >= 2 and (q == "'" or q == '"') and value:sub(-1) == q then
    return value:sub(2, -2)
  end
  return value
end

--- Parse the text a declaration comment carries after its placeholder.
--- `= a | b` at the end lists choices; it only counts as such when there are
--- at least two, so a description like "rows where x = 1" stays a description.
--- @param rest string
--- @return ParamDeclaration
local function parse_declaration(rest)
  rest = vim.trim((rest:gsub("^%s*:", "")))
  local desc, list = rest:match("^(.-)%s*=%s*([^=]*|[^=]*)$")
  local decl = {}
  if desc then
    local choices = {}
    for _, item in ipairs(vim.split(list, "|", { plain = true })) do
      item = unquote(vim.trim(item))
      if item ~= "" then choices[#choices + 1] = item end
    end
    if #choices >= 2 then
      decl.choices = choices
      rest = desc
    end
  end
  if rest ~= "" then decl.description = rest end
  return decl
end

--- Comment openers a declaration line may start with, as Lua patterns: SQL's
--- and Lucene's `--`, Console's `#` and `//`.
local DECLARATION_PREFIXES = { "%-%-", "#", "//" }

--- Return the declarations `text`'s comment lines make: each comment line
--- (`--`, `#` or `//`) that starts with a placeholder. A later declaration of a name replaces an
--- earlier one's description and choices where it gives them.
--- @param text string
--- @return table<string, ParamDeclaration>
function M.declarations(text)
  local decls = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local name, brackets, rest
    for _, prefix in ipairs(DECLARATION_PREFIXES) do
      name, brackets, rest = line:match("^%s*" .. prefix .. "%s*" .. PLACEHOLDER .. "(.*)$")
      if name then break end
    end
    if name and (brackets == "" or brackets == "[]") then
      local decl = parse_declaration(rest)
      local prev = decls[name] or {}
      decls[name] = {
        description = decl.description or prev.description,
        choices     = decl.choices or prev.choices,
      }
    end
  end
  return decls
end

--- Return the placeholder `line` has under byte column `col` (0-indexed), or
--- nil. Textual, so it finds one in a declaration comment too.
--- @param line string
--- @param col  integer
--- @return { name: string, list: boolean, s: integer, e: integer }|nil  s/e are 0-indexed, e exclusive
function M.placeholder_at(line, col)
  local init = 1
  while true do
    local s, e, name, brackets = line:find(PLACEHOLDER, init)
    if not s then return nil end
    if col >= s - 1 and col < e and (brackets == "" or brackets == "[]") then
      return { name = name, list = brackets == "[]", s = s - 1, e = e }
    end
    init = e + 1
  end
end

--- Return the value last submitted for `name` on `conn_key`, or nil.
--- @param conn_key string
--- @param name     string
--- @return string|string[]|nil
function M.last_value(conn_key, name)
  return (last_values[conn_key] or {})[name]
end

--- @class LoggedParam
--- @field name  string
--- @field list  boolean
--- @field value string|string[]

--- Return the values `sql` was run with, in order of first appearance and
--- limited to the parameters it uses — a batch binds one set of values into
--- every statement — or nil when it uses none.
--- @param sql     string
--- @param values  table<string, string|string[]>|nil
--- @param dialect "sql"|"esconsole"|nil  the query's dialect (see `M.dialect`)
--- @return LoggedParam[]|nil
function M.used_values(sql, values, dialect)
  if not values then return nil end
  local params = M.find(sql, dialect)
  if not params or #params == 0 then return nil end
  local out = {}
  for _, p in ipairs(params) do
    local v = values[p.name]
    if v == nil then v = p.list and {} or "" end
    out[#out + 1] = { name = p.name, list = p.list, value = v }
  end
  return out
end

--- Turn logged parameters back into the values table `bind` and the results
--- pane take.
--- @param logged LoggedParam[]|nil
--- @return table<string, string|string[]>|nil
function M.values_of(logged)
  if not logged then return nil end
  local values = {}
  for _, p in ipairs(logged) do values[p.name] = p.value end
  return values
end

--- Lay out logged parameters as comment lines, to show under the query they
--- ran with: a header, then one `name = value` line each, a scalar quoted
--- the way SQL quotes a string and a list as its items.
--- @param logged  LoggedParam[]
--- @param comment string|nil  the line-comment opener; "--" when nil
--- @return string[]
function M.format_logged(logged, comment)
  comment = comment or "--"
  --- Quote `v` as a SQL string literal.
  --- @param v string
  --- @return string
  local function quote(v) return "'" .. v:gsub("'", "''") .. "'" end
  local width = 0
  for _, p in ipairs(logged) do width = math.max(width, #p.name + (p.list and 2 or 0)) end
  local lines = { comment .. " parameters:" }
  for _, p in ipairs(logged) do
    local label = p.name .. (p.list and "[]" or "")
    local shown
    if p.list then
      local items = type(p.value) == "table" and p.value or {}
      shown = #items == 0 and "(empty)" or table.concat(vim.tbl_map(quote, items), ", ")
    else
      shown = quote(type(p.value) == "string" and p.value or "")
    end
    lines[#lines + 1] = ("%s   %s%s = %s"):format(comment, label, (" "):rep(width - #label), shown)
  end
  return lines
end

--- Lay out the hover for placeholder `name`: its kind, its declaration and
--- the value it last ran with on the buffer's connection.
--- @param name string
--- @param list boolean
--- @param decl ParamDeclaration|nil
--- @param last string|string[]|nil
--- @return string[] lines
--- @return { [1]: string, [2]: integer, [3]: integer, [4]: integer }[] hls  group, row, col_start, col_end
function M.hover_lines(name, list, decl, last)
  decl = decl or {}
  local head = ("{{%s%s}}"):format(name, list and "[]" or "")
  local lines = { head .. "  " .. (list and "list parameter" or "query parameter") }
  local hls = { { "Title", 0, 0, #head }, { "Comment", 0, #head, -1 } }
  if decl.description then lines[#lines + 1] = decl.description end
  if decl.choices then
    lines[#lines + 1] = "choices: " .. table.concat(decl.choices, " | ")
    hls[#hls + 1] = { "Comment", #lines - 1, 0, 8 }
  end
  if last ~= nil then
    local shown = type(last) == "table" and table.concat(last, ", ") or last
    lines[#lines + 1] = "last value: " .. (shown == "" and "(empty)" or shown)
    hls[#hls + 1] = { "Comment", #lines - 1, 0, 11 }
  elseif not decl.description and not decl.choices then
    lines[#lines + 1] = "prompted for when the query runs"
    hls[#hls + 1] = { "Comment", #lines - 1, 0, -1 }
  end
  return lines, hls
end

--- Return the placeholder dialect of `conn`'s queries: "sql" for the drivers
--- that bind parameters, "esconsole" for an Elasticsearch connection in Dev
--- Tools mode, nil for a connection whose queries take none.
--- @param conn { driver: string, key: string }|nil
--- @return "sql"|"esconsole"|nil
function M.dialect(conn)
  if not conn then return nil end
  if MARKERS[conn.driver] then return "sql" end
  if CONSOLE_DRIVERS[conn.driver] and require("grannos.devtools").applies(conn) then
    return "esconsole"
  end
  return nil
end

--- Whether `conn`'s queries take query parameters.
--- @param conn { driver: string, key: string }|nil
--- @return boolean
function M.supports(conn)
  return M.dialect(conn) ~= nil
end

--- Return the distinct parameters `sql` names, in order of first appearance.
--- Errors when one name is used both as a scalar and as a list, or when the
--- dialect's parser is not installed.
--- @param sql     string
--- @param dialect "sql"|"esconsole"|nil  nil is "sql"
--- @return QueryParam[]|nil params
--- @return string|nil err
function M.find(sql, dialect)
  local tokens = tokens_of(sql, dialect)
  if not tokens then
    return nil, ("the %s treesitter parser is not installed: see :checkhealth grannos"):format(dialect)
  end
  local params, seen = {}, {}
  for _, tok in ipairs(tokens) do
    local prev = seen[tok.name]
    if not prev then
      prev = { name = tok.name, list = tok.list }
      seen[tok.name] = prev
      params[#params + 1] = prev
    elseif prev.list ~= tok.list then
      return nil, ("parameter %q is used both as {{%s}} and {{%s[]}}"):format(tok.name, tok.name, tok.name)
    end
  end
  return params
end

--- Rewrite `sql`'s placeholders into `driver`'s bind markers.
--- @param sql    string
--- @param driver string
--- @param values table<string, string|string[]>  a string per scalar, a list per list parameter
--- @return string query  the text to execute
--- @return string[] binds  positional bind values, in marker order
function M.bind(sql, driver, values)
  if CONSOLE_DRIVERS[driver] then return M.substitute(sql, values), {} end
  local marker = MARKERS[driver]
  local tokens = scan(sql)
  if not marker or #tokens == 0 then return sql, {} end

  local binds, pieces, pos = {}, {}, 1
  --- Record `value` as the next bind and return its marker.
  --- @param value string
  --- @return string
  local function add(value)
    binds[#binds + 1] = value
    return marker(#binds)
  end

  local literal = {}  -- indexes into `pieces` of text copied from the query
  for _, tok in ipairs(tokens) do
    pieces[#pieces + 1] = sql:sub(pos, tok.s - 1)
    literal[#pieces] = true
    local value = values[tok.name]
    if tok.list then
      local items = type(value) == "table" and value or {}
      if #items == 0 then
        pieces[#pieces + 1] = "NULL"
      else
        local markers = {}
        for _, item in ipairs(items) do markers[#markers + 1] = add(item) end
        pieces[#pieces + 1] = table.concat(markers, ", ")
      end
    else
      pieces[#pieces + 1] = add(type(value) == "string" and value or "")
    end
    pos = tok.e + 1
  end
  pieces[#pieces + 1] = sql:sub(pos)
  literal[#pieces] = true

  if PERCENT_ESCAPED[driver] and #binds > 0 then
    for idx in pairs(literal) do pieces[idx] = pieces[idx]:gsub("%%", "%%%%") end
  end
  return table.concat(pieces), binds
end

--- Percent-encode `s` for a URL path segment or query value. Unreserved
--- characters stay, and so do `*` and `,`, which Elasticsearch reads in an
--- index pattern or list (`logs-*,metrics-*`).
--- @param s string
--- @return string
local function url_encode(s)
  return (s:gsub("[^%w%-._~*,]", function(c) return ("%%%02X"):format(c:byte()) end))
end

--- Return true when `s` is a JSON number as JSON writes one: no leading
--- zero, `+` or bare dot, which `vim.json.decode` would accept but
--- Elasticsearch's parser would not.
--- @param s string
--- @return boolean
local function is_json_number(s)
  local rest = s:match("^%-?0(.*)$") or s:match("^%-?[1-9]%d*(.*)$")
  if not rest then return false end
  rest = rest:gsub("^%.%d+", "", 1)
  rest = rest:gsub("^[eE][%+%-]?%d+", "", 1)
  return rest == ""
end

--- Return `s` as a JSON literal: itself when it already is a number, boolean
--- or null, else a JSON string.
--- @param s string
--- @return string
local function json_literal(s)
  if s == "true" or s == "false" or s == "null" or is_json_number(s) then return s end
  return vim.json.encode(s)
end

--- Return `s` escaped as the content of a JSON string.
--- @param s string
--- @return string
local function json_content(s)
  return vim.json.encode(s):sub(2, -2)
end

--- The encoder of a placeholder value, per place it stands.
local ENCODERS = { path = url_encode, string = json_content, value = json_literal }

--- Write `values` into Console request text `text` in place of its
--- placeholders, each encoded for where it stands (see the module header).
--- A list joins its encoded items with commas, and as a JSON value is
--- bracketed into an array. Text with no placeholders, or whose parser is not
--- installed, is returned unchanged.
--- @param text   string
--- @param values table<string, string|string[]>  a string per scalar, a list per list parameter
--- @return string
function M.substitute(text, values)
  local tokens = scan_console(text)
  if not tokens or #tokens == 0 then return text end
  local pieces, pos = {}, 1
  for _, tok in ipairs(tokens) do
    pieces[#pieces + 1] = text:sub(pos, tok.s - 1)
    local encode = ENCODERS[tok.context]
    local value  = values[tok.name]
    if tok.list then
      local items = vim.tbl_map(encode, type(value) == "table" and value or {})
      local joined = table.concat(items, ",")
      pieces[#pieces + 1] = tok.context == "value" and ("[" .. joined .. "]") or joined
    else
      pieces[#pieces + 1] = encode(type(value) == "string" and value or "")
    end
    pos = tok.e + 1
  end
  pieces[#pieces + 1] = text:sub(pos)
  return table.concat(pieces)
end

--- Split a list parameter's free text into its items: one per non-blank line,
--- trimmed.
--- @param text string
--- @return string[]
function M.parse_list(text)
  local items = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    local item = vim.trim(line)
    if item ~= "" then items[#items + 1] = item end
  end
  return items
end

--- Prompt for every parameter in `params`, prefilled with the values last
--- submitted on `conn_key`, and hand the submitted values to `on_submit`.
--- A declared description shows beside its field; declared choices make a
--- scalar a dropdown (with free text still allowed) and a list a multi-select.
--- Cancelling calls nothing.
--- @param conn_key  string
--- @param params    QueryParam[]
--- @param on_submit fun(values: table<string, string|string[]>)
--- @param decls     table<string, ParamDeclaration>|nil  see `declarations`
function M.prompt(conn_key, params, on_submit, decls)
  decls = decls or {}
  local remembered = last_values[conn_key] or {}
  local current    = {}
  local fields     = {}
  for _, p in ipairs(params) do
    local prev    = remembered[p.name]
    local decl    = decls[p.name] or {}
    local choices = decl.choices
    local field
    if p.list then
      current[p.name] = type(prev) == "table" and vim.deepcopy(prev) or {}
      field = {
        kind         = choices and "multichoice" or "multiline",
        label        = p.name .. "[]",
        display      = function()
          local items = current[p.name]
          if #items == 0 then
            return choices and "(none selected)" or "(empty — one item per line)"
          end
          return ("%d item%s: %s"):format(#items, #items == 1 and "" or "s", table.concat(items, ", "))
        end,
        edit_prefill = function() return table.concat(current[p.name], "\n") end,
        commit_text  = function(text) current[p.name] = M.parse_list(text) end,
        clear        = function() current[p.name] = {} end,
        choices      = choices,
        commit_selection = function(items) current[p.name] = items end,
      }
    else
      current[p.name] = type(prev) == "string" and prev or (choices and choices[1] or "")
      field = {
        kind         = choices and "choice" or "text",
        label        = p.name,
        display      = function() return current[p.name] end,
        edit_prefill = function() return current[p.name] end,
        commit_text  = function(text) current[p.name] = text end,
        clear        = function() current[p.name] = "" end,
      }
      if choices then
        field.options = function()
          local items = {}
          for _, c in ipairs(choices) do items[#items + 1] = { label = c, value = c } end
          items[#items + 1] = { label = "other…", is_new = true }
          return items
        end
        field.commit_choice = function(item) current[p.name] = item.value end
      end
    end
    field.key  = p.name
    field.get  = function() return current[p.name] end
    field.hint = decl.description
    fields[#fields + 1] = field
  end

  require("grannos.ui.conn_form").open({
    title        = "Query Parameters",
    fields       = fields,
    submit_label = "run",
    on_cancel    = function() vim.notify("grannos: execution aborted", vim.log.levels.WARN) end,
    on_submit    = function(values, done)
      last_values[conn_key] = vim.deepcopy(values)
      done(nil)
      on_submit(values)
    end,
  })
end

return M
