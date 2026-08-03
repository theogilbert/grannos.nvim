local M = {}

local client      = require("grannos.client")
local config      = require("grannos.config")
local connections = require("grannos.connections")
local results     = require("grannos.ui.results")
local gutter      = require("grannos.ui.gutter")
local log         = require("grannos.log")
local ts_queries  = require("grannos.ts_queries")

-- Past-tense verb shown for DML statements, keyed by leading keyword.
local DML_VERBS = {
  insert = "inserted",
  update = "updated",
  delete = "deleted",
  merge  = "merged",
}

--- Return the past-tense verb for a SQL statement (e.g. "inserted", "affected").
--- @param sql string
--- @return string
local function detect_operation(sql)
  local word = (vim.trim(sql):match("^(%a+)") or ""):lower()
  return DML_VERBS[word] or "affected"
end

--- Return true when `driver` is a MongoDB driver identifier.
--- @param driver string
--- @return boolean
local function is_mongo(driver)
  return driver == "mongodb" or driver == "mongo"
end

--- Route a single-query result to the results panel.
--- @param result table  server execute response
--- @param sql    string  the original query text
local function dispatch_result(result, sql)
  if result.rows_affected ~= nil then
    results.show_rows_affected(result.rows_affected, detect_operation(sql), result.duration_ms, result.messages)
  else
    local rows = result.rows or {}
    results.show_results(result.columns or {}, rows, #rows, result.rows_total, result.duration_ms, result.messages)
  end
end

--- Route one statement's result to the batch results panel.
--- @param idx    integer  1-indexed position in the batch
--- @param total  integer  total statements in the batch
--- @param result table    server execute response
--- @param sql    string   the statement text
local function dispatch_batch_result(idx, total, result, sql)
  if result.rows_affected ~= nil then
    results.append_batch_rows_affected(idx, total, result.rows_affected, detect_operation(sql), result.duration_ms, sql, result.messages)
  else
    local rows = result.rows or {}
    results.append_batch_result(idx, total, result.columns or {}, rows, #rows, result.rows_total, result.duration_ms, sql, result.messages)
  end
end

--- Send a single execute request to the backend and return its request id.
--- @param conn        ConnSession
--- @param sql         string
--- @param on_done     fun(err: string|nil, result: any)
--- @param on_progress fun(progress: table)|nil
--- @return integer|nil
local function execute(conn, sql, on_done, on_progress)
  return client.request(
    "execute",
    { connection_id = conn.conn_id, query = sql, params = {} },
    on_done,
    on_progress)
end

local update_log_from_result  -- forward declaration; defined below run_batch / run_single

--- Run statements one after another, each appended to the batch view.
--- Each statement gets its own gutter mark and log entry created as it starts.
--- @param queries    {sql: string, line: integer}[]  statements to run
--- @param conn       ConnSession
--- @param idx        integer  1-indexed position of the current statement
--- @param bufnr      integer|nil
--- @param first_line integer|nil  0-indexed first line of the batch in bufnr
--- @param had_error  boolean      true if any earlier statement already failed
local function run_batch(queries, conn, idx, bufnr, first_line, had_error)
  local q           = queries[idx]
  local source_line = (bufnr and first_line ~= nil) and (first_line + q.line) or nil
  local log_id      = log.add(conn.key, bufnr, source_line, q.sql)
  local gh          = (bufnr and first_line ~= nil)
      and gutter.show_running(bufnr, first_line + q.line) or nil
  local req_id = execute(conn, q.sql, function(err, result)
    vim.schedule(function()
      gutter.unregister_request(gh)
      if err then
        had_error = true
        results.append_batch_error(idx, #queries, err, q.sql)
        gutter.show_error(gh)
        log.update(conn.key, log_id, { err = err })
      else
        dispatch_batch_result(idx, #queries, result, q.sql)
        gutter.show_success(gh)
        update_log_from_result(conn.key, log_id, result, q.sql)
      end
      if idx < #queries then
        run_batch(queries, conn, idx + 1, bufnr, first_line, had_error)
      end
    end)
  end)
  local stmt_nlines = select(2, q.sql:gsub("\n", ""))
  local stmt_end    = (first_line ~= nil) and (first_line + q.line + stmt_nlines) or nil
  gutter.register_request(gh, req_id, stmt_end)
end

--- Persist a completed execution result into the query log.
--- @param conn_key string
--- @param log_id   string
--- @param result   table   server execute response
--- @param sql      string  original query text
update_log_from_result = function(conn_key, log_id, result, sql)
  if result.rows_affected ~= nil then
    log.update(conn_key, log_id, {
      rows_affected = result.rows_affected,
      verb          = detect_operation(sql),
      duration_ms   = result.duration_ms,
      messages      = result.messages,
    })
  else
    local rows = result.rows or {}
    log.update(conn_key, log_id, {
      columns       = result.columns or {},
      rows          = rows,
      rows_returned = #rows,
      rows_total    = result.rows_total,
      duration_ms   = result.duration_ms,
      messages      = result.messages,
    })
  end
end

--- Execute a single SQL statement, updating the results panel and gutter on completion.
--- @param conn     ConnSession
--- @param sql      string
--- @param gh       GutterHandle|nil
--- @param conn_key string
--- @param log_id   string
--- @param end_line integer|nil  0-indexed last line of the query in the source buffer
local function run_single(conn, sql, gh, conn_key, log_id, end_line)
  results.show_loading("Executing…")
  local req_id = execute(conn, sql,
    function(err, result)
      vim.schedule(function()
        gutter.unregister_request(gh)
        if err then
          results.show_error(err)
          gutter.show_error(gh)
          log.update(conn_key, log_id, { err = err })
          return
        end
        gutter.show_success(gh)
        update_log_from_result(conn_key, log_id, result, sql)
        if result.rows_affected ~= nil then
          dispatch_result(result, sql)
        else
          -- Response received; formatting/rendering a large row set can itself take
          -- a noticeable moment, so surface that as a distinct step from "waiting
          -- on the server". The outer vim.schedule lets this message actually paint
          -- before the (synchronous, blocking) render work below runs.
          results.show_loading("Processing…")
          vim.schedule(function() dispatch_result(result, sql) end)
        end
      end)
    end,
    function(progress)
      vim.schedule(function()
        results.show_loading(progress.message or progress.status or "…")
      end)
    end)
  gutter.register_request(gh, req_id, end_line)
end

--- Prompt the user when the query range contains write operations and `confirm_writes`
--- is not explicitly disabled for the connection.  Calls `callback(true)` to proceed
--- or `callback(false)` to abort.  Resolves synchronously when no prompt is needed.
--- @param conn       ConnSession
--- @param bufnr      integer|nil
--- @param first_line integer|nil  0-indexed
--- @param query      string
--- @param callback   fun(proceed: boolean)
local function check_confirm_writes(conn, bufnr, first_line, query, callback)
  local params = connections.get(conn.key) or {}
  if params.allow_writes then callback(true) return end
  if not bufnr or first_line == nil then callback(true) return end
  local nlines   = select(2, query:gsub("\n", ""))
  local has_write = ts_queries.has_write_statement(bufnr, first_line, first_line + nlines)
  if not has_write then callback(true) return end

  local choices = { "Abort", "Execute", "Always allow writes" }
  vim.ui.select(choices, { prompt = "Write operation detected:" }, function(choice)
    if not choice or choice == "Abort" then
      vim.notify("grannos: execution aborted", vim.log.levels.WARN)
      callback(false)
    elseif choice == "Always allow writes" then
      connections.set_allow_writes(conn.key)
      callback(true)
    else
      callback(true)
    end
  end)
end

--- Execute `query` against `conn`.
--- When treesitter is available and multiple statements are found in the buffer
--- range, they are run as a labelled batch.  MongoDB is always single-statement.
--- @param conn       ConnSession
--- @param query      string
--- @param bufnr      integer|nil       source buffer (for gutter marks and splitting)
--- @param first_line integer|nil       0-indexed first line of the query in bufnr
function M.run(conn, query, bufnr, first_line)
  check_confirm_writes(conn, bufnr, first_line, query, function(proceed)
    if not proceed then return end

    results.set_conn_name(conn.key, conn.driver_label, bufnr)
    local ft = (bufnr and vim.api.nvim_buf_is_valid(bufnr)) and vim.bo[bufnr].filetype or ""
    results.set_query(query, ft)

    local queries
    if not is_mongo(conn.driver) and bufnr and first_line ~= nil then
      local nlines   = select(2, query:gsub("\n", ""))
      local end_row  = first_line + nlines
      local stmts    = ts_queries.statements_in_range(bufnr, first_line, end_row)
      if stmts and #stmts > 1 then
        local first_s = stmts[1]
        local last_s  = stmts[#stmts]
        -- Only split when all statements are fully contained in the queried range.
        -- end_row is exclusive in treesitter, so allow off-by-one vs end_row.
        if first_s.start_row >= first_line and last_s.end_row <= end_row + 1 then
          queries = {}
          for _, s in ipairs(stmts) do
            table.insert(queries, { sql = s.text, line = s.start_row - first_line })
          end
        end
      end
    end

    if queries and #queries > 1 then
      results.begin_batch(#queries)
      run_batch(queries, conn, 1, bufnr, first_line, false)
    else
      local sql      = query
      local log_id   = log.add(conn.key, bufnr, first_line, sql)
      local gh       = (bufnr and first_line ~= nil) and gutter.show_running(bufnr, first_line) or nil
      local nlines   = select(2, sql:gsub("\n", ""))
      local end_line = (first_line ~= nil) and (first_line + nlines) or nil
      run_single(conn, sql, gh, conn.key, log_id, end_line)
    end
  end)
end

return M
