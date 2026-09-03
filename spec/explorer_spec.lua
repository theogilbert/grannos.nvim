local explorer = require("grannos.ui.explorer")

--- Build a FieldDescription with the shape the server sends.
--- @param name      string
--- @param overrides table|nil
--- @return table
local function field(name, overrides)
  local col = {
    type              = "field",
    name              = name,
    types             = { "INTEGER" },
    nullable          = false,
    pk                = false,
    default           = vim.NIL,
    exclusive_indices = {},
    composite_indices = {},
    comment           = vim.NIL,
    sample            = {},
  }
  return vim.tbl_extend("force", col, overrides or {})
end

--- Build an EntityDescription around `properties`.
--- @param properties table[]
--- @return table
local function entity(properties)
  return {
    type        = "entity",
    name        = "users",
    kind        = "table",
    schema      = "public",
    comment     = vim.NIL,
    connections = {},
    properties  = properties,
  }
end

local NODE = { name = "users", type = "table" }

--- Return col_rows as a row-ordered list of { row, name } pairs.
--- @param col_rows table<integer, table>
--- @return table[]
local function ordered(col_rows)
  local out = {}
  for row, col in pairs(col_rows) do out[#out + 1] = { row = row, name = col.name } end
  table.sort(out, function(a, b) return a.row < b.row end)
  return out
end

describe("explorer.render_describe", function()
  it("maps each properties row to the field rendered on it", function()
    local details = entity({ field("id", { pk = true }), field("email", { types = { "TEXT" } }) })
    local lines, _, _, col_rows = explorer.render_describe(details, NODE)

    local mapped = ordered(col_rows)
    assert.equals(2, #mapped)
    assert.equals("id",    mapped[1].name)
    assert.equals("email", mapped[2].name)
    -- The mapped row is the line that actually renders that column, so a cursor
    -- there resolves to what the user is looking at.
    for _, m in ipairs(mapped) do
      assert.is_truthy(lines[m.row]:find(m.name, 1, true))
    end
  end)

  it("leaves the header, separator, and reference rows unmapped", function()
    local details = entity({
      field("user_id", {
        outgoing_references = {
          { table = "orders", column = "user_id", ref_table = "users", ref_column = "id", ref_schema = vim.NIL },
        },
      }),
    })
    local lines, _, _, col_rows = explorer.render_describe(details, NODE)

    assert.equals(1, #ordered(col_rows))
    for row, line in ipairs(lines) do
      if line:find("Name", 1, true) or line:find("─", 1, true) or line:find("Foreign keys", 1, true) then
        assert.is_nil(col_rows[row])
      end
    end
  end)

  it("maps nothing when the entity has no properties", function()
    local _, _, _, col_rows = explorer.render_describe(entity({}), NODE)
    assert.same({}, col_rows)
  end)
end)
