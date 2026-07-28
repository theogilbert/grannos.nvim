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
