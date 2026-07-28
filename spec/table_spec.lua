local table_fmt = require("grannos.table")

describe("table.from_structured_data thousands separator", function()
  local rows = { { "id", "amount" }, { 1, 1234567 }, { 2, 999 } }

  it("is disabled when sep is nil, false, or empty", function()
    for _, sep in ipairs({ nil, false, "" }) do
      local tbl = table_fmt.from_structured_data(rows, 1, sep, ".")
      assert.is_nil(tbl.sep)
      assert.is_nil(table.concat(tbl.text, "\n"):find("_", 1, true))
    end
  end)

  it("applies a uniform separator to every numeric column when sep is a string", function()
    local tbl = table_fmt.from_structured_data(rows, 1, "_", ".")
    assert.equals("_", tbl.sep[1])
    assert.equals("_", tbl.sep[2])
    local text = table.concat(tbl.text, "\n")
    assert.is_not_nil(text:find("1_234_567", 1, true))
  end)

  it("applies the separator only to the given column when sep is a per-column array", function()
    local tbl = table_fmt.from_structured_data(rows, 1, { [2] = "_" }, ".")
    assert.is_nil(tbl.sep[1])
    assert.equals("_", tbl.sep[2])
    local text = table.concat(tbl.text, "\n")
    assert.is_not_nil(text:find("1_234_567", 1, true))
    -- column 1 ("id") never groups since its values are single digits, so this
    -- only confirms column 2 formatting rather than column 1's exclusion; assert
    -- via thousands_hl_rules below for a precise per-column check.
  end)

  it("produces highlight ranges only for enabled numeric columns", function()
    local tbl = table_fmt.from_structured_data(rows, 1, { [2] = "_" }, ".")
    local rules = table_fmt.thousands_hl_rules(tbl)
    -- "1_234_567" has 2 separators, "999" groups to nothing (<=3 digits) -> 2 rules total.
    assert.equals(2, #rules)
    for _, r in ipairs(rules) do
      assert.equals("GrannosThousandsSeparator", r.higroup)
    end
  end)

  it("produces no highlight ranges when nothing is enabled", function()
    local tbl = table_fmt.from_structured_data(rows, 1, nil, ".")
    assert.same({}, table_fmt.thousands_hl_rules(tbl))
  end)
end)

describe("table.from_structured_data decimal separator", function()
  it("swaps the decimal point independently of the thousands separator", function()
    local tbl = table_fmt.from_structured_data({ { "amount" }, { 1234.5 } }, 1, nil, ",")
    assert.is_nil(tbl.sep)
    local text = table.concat(tbl.text, "\n")
    assert.is_not_nil(text:find("1234,5", 1, true))
    assert.is_nil(text:find("1234.5", 1, true))
  end)
end)

describe("table.from_structured_data NULL handling", function()
  it("renders vim.NIL cells as NULL and flags them via null_hl_rules", function()
    local tbl = table_fmt.from_structured_data({ { "name" }, { vim.NIL } }, 1, nil, ".")
    local text = table.concat(tbl.text, "\n")
    assert.is_not_nil(text:find("NULL", 1, true))
    local rules = table_fmt.null_hl_rules(tbl)
    assert.equals(1, #rules)
    assert.equals("GrannosNull", rules[1].higroup)
  end)
end)

describe("table.from_structured_data LOB handling", function()
  it("renders LobPlaceholder cells as their text and flags them via lob_hl_rules", function()
    local cell = { type = "lob", text = "CLOB (3423 chars)" }
    local tbl = table_fmt.from_structured_data({ { "body" }, { cell } }, 1, nil, ".")
    local text = table.concat(tbl.text, "\n")
    assert.is_not_nil(text:find("CLOB (3423 chars)", 1, true))
    local rules = table_fmt.lob_hl_rules(tbl)
    assert.equals(1, #rules)
    assert.equals("GrannosLob", rules[1].higroup)
  end)
end)

describe("table.from_structured_data SpecialFloat handling", function()
  it("renders SpecialFloat cells as their text and flags them via special_float_hl_rules", function()
    local cell = { type = "special_float", text = "NaN" }
    local tbl = table_fmt.from_structured_data({ { "value" }, { cell } }, 1, nil, ".")
    local text = table.concat(tbl.text, "\n")
    assert.is_not_nil(text:find("NaN", 1, true))
    local rules = table_fmt.special_float_hl_rules(tbl)
    assert.equals(1, #rules)
    assert.equals("GrannosSpecialFloat", rules[1].higroup)
  end)
end)

describe("table.get_column_at_cursor", function()
  it("resolves the column at a given virtual cursor position, and nil on separators", function()
    local widths = { 5, 4 }  -- │<5 cols>│<4 cols>│
    assert.equals(1, table_fmt.get_column_at_cursor(widths, 2))   -- first char of col 1
    assert.equals(1, table_fmt.get_column_at_cursor(widths, 6))   -- last char of col 1
    assert.is_nil(table_fmt.get_column_at_cursor(widths, 7))      -- on the │ between columns
    assert.equals(2, table_fmt.get_column_at_cursor(widths, 8))   -- first char of col 2
    assert.equals(2, table_fmt.get_column_at_cursor(widths, 11))  -- last char of col 2
    assert.is_nil(table_fmt.get_column_at_cursor(widths, 12))     -- past the last column
  end)
end)
