-- Splits Elasticsearch Dev Tools (Kibana Console) buffers into requests.
--
-- A Dev Tools connection's buffers carry the driver's `lucene` filetype, whose
-- grammar cannot parse `METHOD /path` + JSON body, so treesitter finds no
-- statement in them. This module stands in for ts_queries' statement API on
-- such buffers, splitting textually the way Console does: a request starts at
-- a line opening with an HTTP method and a path, and runs until the next one.
-- `#` and `//` line comments and `/* */` block comments never start a request,
-- and trailing blank or comment lines do not belong to the one before them.

local M = {}

local METHODS = { GET = true, POST = true, PUT = true, DELETE = true, PATCH = true, HEAD = true }

--- Return true when `conn` is an Elasticsearch connection in Dev Tools mode.
--- @param conn { driver: string, key: string }|nil  the open connection, if any
--- @return boolean
function M.applies(conn)
  if not conn or conn.driver ~= "elasticsearch" then return false end
  local params = require("grannos.connections").get(conn.key)
  return params ~= nil and params.query_mode == "dev_tools"
end

--- Classify each line of `lines`: "request" when it opens a request, "code"
--- when it holds anything else outside comments, "blank" otherwise. A block
--- comment is tracked across lines; a quoted string is not (JSON strings end
--- on their line), and `/*` inside one does not open a comment.
--- @param lines string[]
--- @return string[]
local function classify(lines)
  local kinds, in_block = {}, false
  for i, line in ipairs(lines) do
    local code, pos, in_str = {}, 1, false
    while pos <= #line do
      local c = line:sub(pos, pos)
      if in_block then
        if line:sub(pos, pos + 1) == "*/" then in_block = false; pos = pos + 1 end
      elseif in_str then
        table.insert(code, c)
        if c == "\\" then table.insert(code, line:sub(pos + 1, pos + 1)); pos = pos + 1
        elseif c == '"' then in_str = false end
      elseif c == '"' then
        in_str = true
        table.insert(code, c)
      elseif line:sub(pos, pos + 1) == "/*" then
        in_block = true; pos = pos + 1
      elseif c == "#" or line:sub(pos, pos + 1) == "//" then
        break
      else
        table.insert(code, c)
      end
      pos = pos + 1
    end
    local text = table.concat(code)
    local method = text:match("^%s*(%a+)%s+%S")
    if method and METHODS[method:upper()] then
      kinds[i] = "request"
    elseif text:match("%S") then
      kinds[i] = "code"
    else
      kinds[i] = "blank"
    end
  end
  return kinds
end

--- Return every request of `bufnr`, in buffer order.
--- @param bufnr integer
--- @return SqlStatement[]
local function requests(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local kinds = classify(lines)
  local out, start, last = {}, nil, nil

  --- Close the request open since `start`, ending at its last code line.
  local function close()
    if not start then return end
    local text = vim.trim(table.concat(lines, "\n", start, last))
    table.insert(out, {
      text      = text,
      start_row = start - 1,
      start_col = (lines[start]:find("%S") or 1) - 1,
      end_row   = last - 1,
      end_col   = #lines[last],
    })
  end

  for i, kind in ipairs(kinds) do
    if kind == "request" then
      close()
      start, last = i, i
    elseif kind == "code" and start then
      last = i
    end
  end
  close()
  return out
end

--- Return every request that overlaps [start_row, end_row] (0-indexed inclusive),
--- or nil when there is none.
--- @param bufnr     integer
--- @param start_row integer  0-indexed
--- @param end_row   integer  0-indexed
--- @return SqlStatement[]|nil
function M.statements_in_range(bufnr, start_row, end_row)
  local stmts = {}
  for _, s in ipairs(requests(bufnr)) do
    if s.start_row <= end_row and s.end_row >= start_row then table.insert(stmts, s) end
  end
  return #stmts > 0 and stmts or nil
end

--- Return the request whose lines contain the cursor, or nil.
--- @param bufnr integer
--- @return SqlStatement|nil
function M.statement_at_cursor(bufnr)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  for _, s in ipairs(requests(bufnr)) do
    if s.start_row <= row and row <= s.end_row then return s end
  end
  return nil
end

return M
