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

--- Values last submitted, per connection key then parameter name, to prefill
--- the next prompt.
--- @type table<string, table<string, string|string[]>>
local last_values = {}

--- @class QueryParam
--- @field name string
--- @field list boolean  true for `{{name[]}}`

--- @class ParamToken
--- @field s    integer  1-indexed byte where the placeholder starts
--- @field e    integer  1-indexed byte where it ends (inclusive)
--- @field name string
--- @field list boolean

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

--- Whether `driver` takes query parameters.
--- @param driver string
--- @return boolean
function M.supports(driver)
  return MARKERS[driver] ~= nil
end

--- Return the distinct parameters `sql` names, in order of first appearance.
--- Errors when one name is used both as a scalar and as a list.
--- @param sql string
--- @return QueryParam[]|nil params
--- @return string|nil err
function M.find(sql)
  local params, seen = {}, {}
  for _, tok in ipairs(scan(sql)) do
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
--- Cancelling calls nothing.
--- @param conn_key  string
--- @param params    QueryParam[]
--- @param on_submit fun(values: table<string, string|string[]>)
function M.prompt(conn_key, params, on_submit)
  local remembered = last_values[conn_key] or {}
  local current    = {}
  local fields     = {}
  for _, p in ipairs(params) do
    local prev = remembered[p.name]
    if p.list then
      current[p.name] = type(prev) == "table" and vim.deepcopy(prev) or {}
      fields[#fields + 1] = {
        key          = p.name,
        label        = p.name .. "[]",
        kind         = "multiline",
        get          = function() return current[p.name] end,
        display      = function()
          local items = current[p.name]
          if #items == 0 then return "(empty — one item per line)" end
          return ("%d item%s: %s"):format(#items, #items == 1 and "" or "s", table.concat(items, ", "))
        end,
        edit_prefill = function() return table.concat(current[p.name], "\n") end,
        commit_text  = function(text) current[p.name] = M.parse_list(text) end,
        clear        = function() current[p.name] = {} end,
      }
    else
      current[p.name] = type(prev) == "string" and prev or ""
      fields[#fields + 1] = {
        key          = p.name,
        label        = p.name,
        kind         = "text",
        get          = function() return current[p.name] end,
        display      = function() return current[p.name] end,
        edit_prefill = function() return current[p.name] end,
        commit_text  = function(text) current[p.name] = text end,
        clear        = function() current[p.name] = "" end,
      }
    end
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
