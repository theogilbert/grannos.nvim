--- Symbol extraction for Elasticsearch Console (Dev Tools) requests.
---
--- The first path segment, when it is not an endpoint (`_search`, `_cat`),
--- is the request's target: a comma-separated list of indices and aliases,
--- of which the one under the cursor is searched as an `index` (the driver
--- finds an alias under that kind too; see `symbols/lucene.lua`).
---
--- In the body, a field is named where Query DSL keys one: the key of a
--- leaf query (`{"match": {"status": …}}`), of a sort clause, or of a
--- mapping's `properties`; and the value of `field`, `default_field`,
--- `fields` and `_source`. Its scopes are the request's targets.
local util   = require("grannos.symbols.util")
local lucene = require("grannos.symbols.lucene")

local M = {}

--- Keys whose object value is keyed by field name.
local FIELD_KEYED = {
  match = true, match_phrase = true, match_phrase_prefix = true,
  match_bool_prefix = true, term = true, terms = true, terms_set = true,
  range = true, prefix = true, wildcard = true, regexp = true, fuzzy = true,
  intervals = true, geo_distance = true, geo_bounding_box = true,
  geo_shape = true, properties = true,
}

--- Keys whose string value names a field.
local FIELD_VALUED = { field = true, default_field = true }

--- Keys whose array of strings names fields.
local FIELDS_LISTED = { fields = true, _source = true }

--- Return the first path segment of `stmt` when it is a target rather than
--- an endpoint, or nil.
--- @param stmt  userdata  a `statement` node
--- @param bufnr integer
--- @return userdata|nil
local function target_segment(stmt, bufnr)
  local path = stmt:field("path")[1]
  local seg = path and path:named_child(0)
  if not seg or seg:type() ~= "segment" then return nil end
  return util.text(seg, bufnr):sub(1, 1) ~= "_" and seg or nil
end

--- Return the text of a JSON `string` node's content, or "" when empty.
--- @param str   userdata|nil
--- @param bufnr integer
--- @return string
local function string_text(str, bufnr)
  local content = str and str:named_child(0)
  return content and util.text(content, bufnr) or ""
end

--- Return the key text of the pair holding `node` as its value, looking
--- through one array (`"fields": ["a", "b"]`), and whether it went through
--- one. Nil when `node` is no pair's value.
--- @param node  userdata  an `object`, `array` or `string`
--- @param bufnr integer
--- @return string|nil, boolean
local function owning_key(node, bufnr)
  local parent, in_array = node:parent(), false
  if parent and parent:type() == "array" then
    node, parent, in_array = parent, parent:parent(), true
  end
  if not parent or parent:type() ~= "pair" then return nil, false end
  local value = parent:field("value")[1]
  if not value or value:id() ~= node:id() then return nil, false end
  return string_text(parent:field("key")[1], bufnr), in_array
end

--- Return the field a JSON `string` node names, or nil.
--- @param str   userdata
--- @param bufnr integer
--- @return string|nil
local function body_field(str, bufnr)
  local pair = str:parent()
  local key_node = pair and pair:type() == "pair" and pair:field("key")[1]
  if key_node and key_node:id() == str:id() then
    -- A key: a field when the object holding it is keyed by field name, or
    -- is one element of a `sort` array.
    local key, in_array = owning_key(pair:parent(), bufnr)
    if (FIELD_KEYED[key] and not in_array) or (key == "sort" and in_array) then
      return string_text(str, bufnr)
    end
    return nil
  end
  local key, in_array = owning_key(str, bufnr)
  if (FIELD_VALUED[key] and not in_array) or (FIELDS_LISTED[key] and in_array) then
    return string_text(str, bufnr)
  end
  return nil
end

--- Return the comma-separated item of segment `seg` under the cursor.
--- @param seg   userdata
--- @param bufnr integer
--- @return string|nil
local function item_at_cursor(seg, bufnr)
  local text = util.text(seg, bufnr)
  local _, scol = seg:start()
  local col = vim.api.nvim_win_get_cursor(0)[2] - scol
  local pos = 0
  for item in (text .. ","):gmatch("([^,]*),") do
    if col <= pos + #item then return item end
    pos = pos + #item + 1
  end
  return nil
end

--- Describe the symbol at `node` as an explore.find query, or nil.
--- @param node  userdata  the named node under the cursor
--- @param bufnr integer
--- @return SymbolQuery|nil
function M.extract(node, bufnr)
  local stmt = util.ancestor(node, { statement = true })
  if not stmt then return nil end
  local target = target_segment(stmt, bufnr)

  local seg = util.ancestor(node, { segment = true })
  if seg then
    if not target or seg:id() ~= target:id() or util.descendant(seg, "parameter") then return nil end
    local item = item_at_cursor(seg, bufnr)
    local name = item and lucene.target_name(item)
    return name and { name = name, type = "index", scope = {} } or nil
  end

  local str = util.ancestor(node, { string = true, pair = true })
  if not str or str:type() ~= "string" or util.descendant(str, "parameter") then return nil end
  local field = body_field(str, bufnr)
  if not field or field == "" or field:find("[*?]") then return nil end
  local names = target and vim.split(util.text(target, bufnr), ",", { plain = true }) or {}
  return { name = field, type = "field", scope = lucene.target_scopes(names) }
end

return M
