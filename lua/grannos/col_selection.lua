-- Persisted results-pane column selections, scoped to a project.
--
-- Storage: one JSON file per project under
--   $XDG_DATA_HOME/grannos/col_selections/{sha256(project)[:16]}.json
--
-- "Project" is the working directory (the global one, so a window-local :lcd
-- does not silently split a project in two). Two checkouts of the same schema
-- therefore keep separate selections, which is the point: hiding a column is a
-- statement about the work at hand, not about the database.
--
-- A selection is keyed by the result's column list, so the same query — or any
-- query returning the same columns in the same order — comes back with the
-- columns the user last chose for it. The column names are stored alongside the
-- key so the file stays readable and a stale entry can be filtered on load.
--
-- A selection identical to the full column list is not a customisation: it is
-- deleted rather than stored, so the file only ever holds real choices.
local M = {}

--- Maximum stored selections per project; the least recently saved are dropped.
local MAX_ENTRIES = 200

--- Storage root override. `nil` means the XDG default. Tests set this.
--- @type string|nil
M.root = nil

-- [project] = { cwd = string, selections = { [key] = entry } }
local cache = {}

--- Return the storage root directory for per-project selection files.
--- @return string
local function root()
  if M.root then return M.root end
  local xdg = vim.env.XDG_DATA_HOME or vim.fn.expand("~/.local/share")
  return xdg .. "/grannos/col_selections"
end

--- Return the current project: the global working directory, without a trailing slash.
--- @return string
local function project()
  local cwd = vim.fn.fnamemodify(vim.fn.getcwd(-1, -1), ":p")
  return (cwd:gsub("/+$", ""))
end

--- Return the JSON file path holding `proj`'s selections.
--- @param proj string
--- @return string
local function file_for(proj)
  return root() .. "/" .. vim.fn.sha256(proj):sub(1, 16) .. ".json"
end

--- Return the storage key for a result's column list.
--- @param columns string[]
--- @return string
local function key_for(columns)
  return vim.fn.sha256(table.concat(columns, "\0"))
end

--- Return true when both lists hold the same strings in the same order.
--- @param a string[]
--- @param b string[]
--- @return boolean
local function same_list(a, b)
  if #a ~= #b then return false end
  for i, v in ipairs(a) do if v ~= b[i] then return false end end
  return true
end

--- Read `proj`'s store from disk (once per project per session) and cache it.
--- A missing or unparsable file yields an empty store rather than an error:
--- these are preferences, and losing them costs nothing but convenience.
--- @param proj string
--- @return { cwd: string, selections: table<string, table> }
local function load_store(proj)
  if cache[proj] then return cache[proj] end

  local store = { cwd = proj, selections = {} }
  local f = io.open(file_for(proj), "r")
  if f then
    local content = f:read("*a")
    f:close()
    local ok, decoded = pcall(vim.json.decode, content)
    if ok and type(decoded) == "table" and type(decoded.selections) == "table" then
      store.selections = decoded.selections
    end
  end

  cache[proj] = store
  return store
end

--- Drop the least recently saved entries until at most MAX_ENTRIES remain.
--- @param store { selections: table<string, table> }
local function prune(store)
  local keys = {}
  for k in pairs(store.selections) do table.insert(keys, k) end
  if #keys <= MAX_ENTRIES then return end
  table.sort(keys, function(a, b)
    return (store.selections[a].saved_at or 0) > (store.selections[b].saved_at or 0)
  end)
  for i = MAX_ENTRIES + 1, #keys do store.selections[keys[i]] = nil end
end

--- Write `store` to `proj`'s file, creating the storage root if needed.
--- @param proj  string
--- @param store table
local function write_store(proj, store)
  vim.fn.mkdir(root(), "p")
  local f = io.open(file_for(proj), "w")
  if not f then return end
  f:write(vim.json.encode(store))
  f:close()
end

--- Return the saved visible-column list for a result with these columns, or nil
--- when this project has no selection for them. An empty list is a valid answer:
--- the user hid every column.
--- @param columns string[]  the result's full column list, in original order
--- @return string[]|nil
function M.load(columns)
  if not columns or #columns == 0 then return nil end

  local entry = load_store(project()).selections[key_for(columns)]
  if type(entry) ~= "table" or type(entry.visible) ~= "table" then return nil end

  local present = {}
  for _, c in ipairs(columns) do present[c] = true end

  local visible = {}
  for _, c in ipairs(entry.visible) do
    if present[c] then table.insert(visible, c) end
  end
  return visible
end

--- Save the visible-column selection for a result with these columns, under the
--- current project. Saving the full column list clears any stored selection.
--- @param columns string[]  the result's full column list, in original order
--- @param visible string[]  visible column names, in display order
function M.save(columns, visible)
  if not columns or #columns == 0 or not visible then return end

  local proj  = project()
  local store = load_store(proj)
  local key   = key_for(columns)

  if same_list(columns, visible) then
    if store.selections[key] == nil then return end
    store.selections[key] = nil
  else
    store.selections[key] = {
      columns  = vim.list_extend({}, columns),
      visible  = vim.list_extend({}, visible),
      saved_at = os.time(),
    }
  end

  prune(store)
  write_store(proj, store)
end

--- Forget every store read this session, so the next call re-reads from disk.
--- Only needed by tests and after the storage root changes.
function M.clear_cache()
  cache = {}
end

return M
