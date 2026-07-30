local generic_record = require("grannos.ui.generic_record")

local function rec(name, fields)
  return { type = "generic_record", kind = "prometheus.target", name = name, fields = fields }
end

local function field(label, value)
  return { label = label, value = value }
end

describe("generic_record.field_value", function()
  it("returns the value for a matching label", function()
    local r = rec("a", { field("Health", "up") })
    assert.equal("up", generic_record.field_value(r, "Health"))
  end)

  it("returns nil when the record has no such field", function()
    local r = rec("a", { field("Health", "up") })
    assert.is_nil(generic_record.field_value(r, "Missing"))
  end)

  it("returns nil when the record has no fields at all", function()
    assert.is_nil(generic_record.field_value({ name = "a" }, "Health"))
  end)
end)

describe("generic_record.field_labels", function()
  it("collects labels across records in first-seen order, without duplicates", function()
    local records = {
      rec("a", { field("Z", "same"), field("A", "1") }),
      rec("b", { field("Z", "same"), field("A", "2"), field("Label: shard", "1") }),
    }
    local labels = generic_record.field_labels(records)
    assert.same({ "Z", "A", "Label: shard" }, labels)
  end)

  it("returns every field for a single record", function()
    local records = { rec("a", { field("Health", "up"), field("Scrape Interval", "15s") }) }
    assert.same({ "Health", "Scrape Interval" }, generic_record.field_labels(records))
  end)

  it("returns an empty list for zero records", function()
    assert.same({}, generic_record.field_labels({}))
  end)
end)

describe("generic_record.bool_value", function()
  it("classifies 'true'/'false' case-insensitively", function()
    assert.is_true(generic_record.bool_value("true"))
    assert.is_true(generic_record.bool_value("True"))
    assert.is_true(generic_record.bool_value("TRUE"))
    assert.is_false(generic_record.bool_value("false"))
    assert.is_false(generic_record.bool_value("False"))
  end)

  it("does not classify yes/no, 1/0, or arbitrary strings as boolean", function()
    assert.is_nil(generic_record.bool_value("yes"))
    assert.is_nil(generic_record.bool_value("no"))
    assert.is_nil(generic_record.bool_value("1"))
    assert.is_nil(generic_record.bool_value("0"))
    assert.is_nil(generic_record.bool_value("up"))
  end)

  it("returns nil for nil", function()
    assert.is_nil(generic_record.bool_value(nil))
  end)
end)

describe("generic_record.format_value", function()
  it("renders a true-like value as a green checkmark", function()
    local text, hl_group = generic_record.format_value("True")
    assert.equal("✓", text)
    assert.equal("GrannosBoolTrue", hl_group)
  end)

  it("renders a false-like value as a red cross", function()
    local text, hl_group = generic_record.format_value("False")
    assert.equal("✗", text)
    assert.equal("GrannosBoolFalse", hl_group)
  end)

  it("passes non-boolean values through unhighlighted", function()
    local text, hl_group = generic_record.format_value("up")
    assert.equal("up", text)
    assert.is_nil(hl_group)
  end)
end)
