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

describe("generic_record.split_common_and_varying", function()
  it("treats a field as common when every record has the same value", function()
    local records = {
      rec("a", { field("Scrape Interval", "15s"), field("Health", "up") }),
      rec("b", { field("Scrape Interval", "15s"), field("Health", "down") }),
    }
    local common, varying = generic_record.split_common_and_varying(records)
    assert.same({ { label = "Scrape Interval", value = "15s" } }, common)
    assert.same({ "Health" }, varying)
  end)

  it("treats a field as varying when values differ across records", function()
    local records = {
      rec("a", { field("Health", "up") }),
      rec("b", { field("Health", "down") }),
    }
    local common, varying = generic_record.split_common_and_varying(records)
    assert.same({}, common)
    assert.same({ "Health" }, varying)
  end)

  it("treats a field as varying when missing from some records, even if equal elsewhere", function()
    local records = {
      rec("a", { field("Health", "up"), field("Label: shard", "1") }),
      rec("b", { field("Health", "up") }),
    }
    local common, varying = generic_record.split_common_and_varying(records)
    assert.same({ { label = "Health", value = "up" } }, common)
    assert.same({ "Label: shard" }, varying)
  end)

  it("preserves first-seen field order across both common and varying", function()
    local records = {
      rec("a", { field("Z", "same"), field("A", "1") }),
      rec("b", { field("Z", "same"), field("A", "2") }),
    }
    local common, varying = generic_record.split_common_and_varying(records)
    assert.same({ { label = "Z", value = "same" } }, common)
    assert.same({ "A" }, varying)
  end)

  it("treats every field as varying for a single record — nothing to hoist as \"common\" with only one", function()
    local records = { rec("a", { field("Health", "up"), field("Scrape Interval", "15s") }) }
    local common, varying = generic_record.split_common_and_varying(records)
    assert.same({}, common)
    assert.same({ "Health", "Scrape Interval" }, varying)
  end)

  it("treats every field as varying for zero records", function()
    local common, varying = generic_record.split_common_and_varying({})
    assert.same({}, common)
    assert.same({}, varying)
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
