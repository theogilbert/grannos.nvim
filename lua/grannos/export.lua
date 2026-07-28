-- Pure serializers for exporting query results in various formats.
-- No nvim API calls beyond what table_fmt.from_structured_data already uses.
local table_fmt = require("grannos.table")

local M = {}

--- Export formats offered to the user, in display order.
M.FORMATS = { "pretty", "json", "csv", "markdown" }

--- Neovim filetype to assign to the scratch buffer for each format ("" = none).
M.FILETYPES = {
  json     = "json",
  csv      = "csv",
  pretty   = "",
  markdown = "markdown",
}

local to_json      -- forward declarations; defined below
local to_csv
local to_pretty
local to_markdown

-- Row count between cooperative yields in the row-serialization loops below.
-- Only takes effect when running inside a coroutine (see M.run_async): a plain
-- synchronous M.render() call is unaffected since coroutine.isyieldable() is
-- false outside one.
M.CHUNK_SIZE = 1000

--- Yield to the event loop every M.CHUNK_SIZE-th call, if running inside a
--- coroutine driven by M.run_async. A no-op when called synchronously (e.g.
--- from tests calling M.render directly), so it's safe to sprinkle into any
--- row-processing loop without changing that loop's synchronous behaviour.
--- @param i integer  current 1-based row index
local function maybe_yield(i)
  if coroutine.isyieldable() and i % M.CHUNK_SIZE == 0 then coroutine.yield() end
end

--- Serialize `rows` (with `columns` as field names) into the given export format.
--- @param format  string    one of M.FORMATS
--- @param columns string[]
--- @param rows    any[][]
--- @return string
function M.render(format, columns, rows)
  if format == "json"     then return to_json(columns, rows) end
  if format == "csv"      then return to_csv(columns, rows) end
  if format == "pretty"   then return to_pretty(columns, rows) end
  if format == "markdown" then return to_markdown(columns, rows) end
  error("unknown export format: " .. tostring(format))
end

--- Run `fn` to completion across multiple event-loop ticks instead of one long
--- synchronous call, so CPU-heavy work (e.g. serializing a huge result set)
--- doesn't freeze Neovim's UI for its full duration. `fn` must periodically
--- call coroutine.yield() (see maybe_yield above) to hand control back; this
--- driver resumes it via vim.schedule between yields. Calls `on_done` with
--- fn's return value once it finishes.
--- @param fn      fun(): any
--- @param on_done fun(result: any)
function M.run_async(fn, on_done)
  local co = coroutine.create(fn)
  local function step()
    local ok, result = coroutine.resume(co)
    if not ok then error(result, 0) end
    if coroutine.status(co) == "dead" then
      on_done(result)
    else
      vim.schedule(step)
    end
  end
  step()
end

--- Serialize `rows` like M.render, without blocking the UI thread: the work is
--- chunked and yielded back to the event loop periodically via M.run_async.
--- @param format  string    one of M.FORMATS
--- @param columns string[]
--- @param rows    any[][]
--- @param on_done fun(content: string)
function M.render_async(format, columns, rows, on_done)
  M.run_async(function() return M.render(format, columns, rows) end, on_done)
end

--- Return the display string for a cell value, mapping NULL (nil/vim.NIL) to ""
--- and a LobPlaceholder or SpecialFloat object to its server-formatted `text`.
--- @param cell any
--- @return string
local function plain_cell(cell)
  if cell == nil or cell == vim.NIL then return "" end
  if type(cell) == "table" and (cell.type == "lob" or cell.type == "special_float") then
    return cell.text
  end
  return tostring(cell)
end

--- Quote a CSV field if it contains a comma, quote, or newline.
--- @param s string
--- @return string
local function csv_escape(s)
  if s:find('[,"\n]') then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

--- Escape a markdown table cell: pipes break columns, newlines break rows.
--- @param s string
--- @return string
local function md_escape(s)
  return (s:gsub("|", "\\|"):gsub("\n", " "))
end

--- Right-pad `s` with spaces so its display width equals `width`.
--- @param s     string
--- @param width integer
--- @return string
local function pad(s, width)
  return s .. string.rep(" ", width - vim.api.nvim_strwidth(s))
end

--- Serialize rows as a pretty-printed JSON array of objects, columns in order.
--- @param columns string[]
--- @param rows    any[][]
--- @return string
to_json = function(columns, rows)
  local row_strs = {}
  for ri, row in ipairs(rows) do
    local field_strs = {}
    for i, col in ipairs(columns) do
      local key = vim.json.encode(col)
      local val = vim.json.encode(row[i] == nil and vim.NIL or row[i])
      table.insert(field_strs, "    " .. key .. ": " .. val)
    end
    table.insert(row_strs, "  {\n" .. table.concat(field_strs, ",\n") .. "\n  }")
    maybe_yield(ri)
  end
  if #row_strs == 0 then return "[]" end
  return "[\n" .. table.concat(row_strs, ",\n") .. "\n]"
end

--- Serialize rows as RFC4180-style CSV with a header row; NULL becomes an empty field.
--- @param columns string[]
--- @param rows    any[][]
--- @return string
to_csv = function(columns, rows)
  local lines  = {}
  local header = {}
  for _, c in ipairs(columns) do table.insert(header, csv_escape(c)) end
  table.insert(lines, table.concat(header, ","))

  for ri, row in ipairs(rows) do
    local cells = {}
    for i = 1, #columns do
      table.insert(cells, csv_escape(plain_cell(row[i])))
    end
    table.insert(lines, table.concat(cells, ","))
    maybe_yield(ri)
  end
  return table.concat(lines, "\n")
end

--- Serialize rows as the same box-drawing table rendered in the results pane.
--- @param columns string[]
--- @param rows    any[][]
--- @return string
to_pretty = function(columns, rows)
  local display = { columns }
  for _, row in ipairs(rows) do table.insert(display, row) end
  local tbl = table_fmt.from_structured_data(display, 1)
  return table.concat(tbl.text, "\n")
end

--- Serialize rows as a column-aligned GitHub-flavored markdown table.
--- @param columns string[]
--- @param rows    any[][]
--- @return string
to_markdown = function(columns, rows)
  local header_cells = {}
  for _, c in ipairs(columns) do table.insert(header_cells, md_escape(c)) end

  local data_rows = {}
  for ri, row in ipairs(rows) do
    local cells = {}
    for i = 1, #columns do
      table.insert(cells, md_escape(plain_cell(row[i])))
    end
    table.insert(data_rows, cells)
    maybe_yield(ri)
  end

  -- GFM requires at least 3 dashes per separator cell.
  local widths = {}
  for i, c in ipairs(header_cells) do widths[i] = math.max(3, vim.api.nvim_strwidth(c)) end
  for ri, cells in ipairs(data_rows) do
    for i, c in ipairs(cells) do widths[i] = math.max(widths[i], vim.api.nvim_strwidth(c)) end
    maybe_yield(ri)
  end

  --- Render one row of already-escaped cells as a padded markdown table line.
  --- @param cells string[]
  --- @return string
  local function render_row(cells)
    local padded = {}
    for i, c in ipairs(cells) do table.insert(padded, pad(c, widths[i])) end
    return "| " .. table.concat(padded, " | ") .. " |"
  end

  local seps = {}
  for i = 1, #columns do table.insert(seps, string.rep("-", widths[i])) end

  local lines = { render_row(header_cells), render_row(seps) }
  for ri, cells in ipairs(data_rows) do
    table.insert(lines, render_row(cells))
    maybe_yield(ri)
  end
  return table.concat(lines, "\n")
end

return M
