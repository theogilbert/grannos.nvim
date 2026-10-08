local export = require("grannos.export")

describe("export.to_json", function()
  it("renders rows as a pretty-printed array of objects in column order", function()
    local out = export.render("json", { "id", "name" }, { { 1, "a" }, { 2, "b" } })
    assert.equals([==[[
  {
    "id": 1,
    "name": "a"
  },
  {
    "id": 2,
    "name": "b"
  }
]]==], out)
  end)

  it("maps NULL to json null", function()
    local out = export.render("json", { "id", "name" }, { { 1, vim.NIL } })
    assert.equals([==[[
  {
    "id": 1,
    "name": null
  }
]]==], out)
  end)

  it("renders an empty row set as []", function()
    assert.equals("[]", export.render("json", { "id" }, {}))
  end)
end)

describe("export.to_csv", function()
  it("renders a header row and data rows", function()
    local out = export.render("csv", { "id", "name" }, { { 1, "a" }, { 2, "b" } })
    assert.equals("id,name\n1,a\n2,b", out)
  end)

  it("maps NULL to an empty field", function()
    local out = export.render("csv", { "id", "name" }, { { 1, vim.NIL } })
    assert.equals("id,name\n1,", out)
  end)

  it("quotes fields containing commas, quotes, or newlines", function()
    local out = export.render("csv", { "name" }, { { 'a,b "c"\nd' } })
    assert.equals('name\n"a,b ""c""\nd"', out)
  end)

  it("renders a LobPlaceholder cell as its placeholder text", function()
    local out = export.render("csv", { "body" }, { { { type = "lob", text = "CLOB (3423 chars)" } } })
    assert.equals("body\nCLOB (3423 chars)", out)
  end)

  it("renders a SpecialFloat cell as its display text", function()
    local out = export.render("csv", { "value" }, { { { type = "special_float", text = "NaN" } } })
    assert.equals("value\nNaN", out)
  end)
end)

describe("export.to_markdown", function()
  it("renders a header, separator, and column-aligned data rows", function()
    local out = export.render("markdown", { "id", "name" }, { { 1, "a" } })
    assert.equals("| id  | name |\n| --- | ---- |\n| 1   | a    |", out)
  end)

  it("escapes pipes and strips newlines from cells, widening the column to fit", function()
    local out = export.render("markdown", { "name" }, { { "a|b\nc" } })
    assert.equals("| name   |\n| ------ |\n| a\\|b c |", out)
  end)

  it("maps NULL to an empty cell padded to the column width", function()
    local out = export.render("markdown", { "name" }, { { vim.NIL } })
    assert.equals("| name |\n| ---- |\n|      |", out)
  end)

  it("renders a LobPlaceholder cell as its placeholder text", function()
    local out = export.render("markdown", { "body" }, { { { type = "lob", text = "CLOB" } } })
    assert.equals("| body |\n| ---- |\n| CLOB |", out)
  end)

  it("renders a SpecialFloat cell as its display text", function()
    local out = export.render("markdown", { "value" }, { { { type = "special_float", text = "+Inf" } } })
    assert.equals("| value |\n| ----- |\n| +Inf  |", out)
  end)
end)

describe("export.to_pretty", function()
  it("renders the same box-drawing table as the results pane", function()
    local out = export.render("pretty", { "id", "name" }, { { 1, "a" } })
    assert.is_true(out:find("id", 1, true) ~= nil)
    assert.is_true(out:find("name", 1, true) ~= nil)
    assert.is_true(out:find("│", 1, true) ~= nil)
  end)
end)

describe("export.to_json_structured", function()
  --- Render and decode, so assertions compare documents, not whitespace.
  --- @param columns string[]
  --- @param rows    any[][]
  --- @return table
  local function docs(columns, rows)
    return vim.json.decode(export.render("json_structured", columns, rows), { luanil = { object = false } })
  end

  it("unfolds dotted columns into nested objects", function()
    assert.same({ { _id = "1", address = { city = "Paris", geo = { lat = "48.8" } } } },
      docs({ "_id", "address.city", "address.geo.lat" }, { { "1", "Paris", "48.8" } }))
  end)

  it("unfolds indexed columns into arrays of objects", function()
    assert.same({ { items = { { sku = "a", qty = "1" }, { sku = "b", qty = "2" } } } },
      docs({ "items[0].sku", "items[0].qty", "items[1].sku", "items[1].qty" },
        { { "a", "1", "b", "2" } }))
  end)

  it("keeps keys in column order, indented like the flattened export", function()
    local out = export.render("json_structured", { "id", "a.y", "a.x" }, { { 1, 2, 3 } })
    assert.equals([==[[
  {
    "id": 1,
    "a": {
      "y": 2,
      "x": 3
    }
  }
]]==], out)
  end)

  it("leaves a column without path syntax as a plain key", function()
    assert.same({ { id = 1, name = "a" } }, docs({ "id", "name" }, { { 1, "a" } }))
  end)

  it("keeps a null sub-field of a document that has the object", function()
    local out = docs({ "a.x", "a.y" }, { { "1", vim.NIL } })
    assert.equals("1", out[1].a.x)
    assert.equals(vim.NIL, out[1].a.y)
  end)

  it("lets a value win over the nulls a document lacking the object gets", function()
    -- Row 1 had `a` as an object, row 2 as a value: the flattened columns
    -- are the union, each row null where it has no such field.
    local out = docs({ "a.b", "a" }, { { "1", vim.NIL }, { vim.NIL, "5" } })
    assert.same({ b = "1" }, out[1].a)
    assert.equals("5", out[2].a)
  end)

  it("lets an object win over a null in column order the other way round", function()
    local out = docs({ "a", "a.b" }, { { vim.NIL, "1" }, { "5", vim.NIL } })
    assert.same({ b = "1" }, out[1].a)
    assert.equals("5", out[2].a)
    assert.is_nil(out[2]["a.b"])
  end)

  it("pads a sparse array with nulls", function()
    local out = docs({ "xs[1].v" }, { { "1" } })
    assert.equals(2, #out[1].xs)
    assert.equals(vim.NIL, out[1].xs[1])
    assert.same({ v = "1" }, out[1].xs[2])
  end)

  it("keeps a real clash flat rather than dropping a value", function()
    local out = docs({ "a", "a.b" }, { { "5", "1" } })
    assert.equals("5", out[1].a)
    assert.equals("1", out[1]["a.b"])
  end)

  it("renders an empty row set as []", function()
    assert.equals("[]", export.render("json_structured", { "a.b" }, {}))
  end)
end)
