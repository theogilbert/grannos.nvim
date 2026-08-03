local messages = require("grannos.messages")

describe("messages.render", function()
  it("returns nothing for nil or an empty list", function()
    for _, input in ipairs({ { nil }, { {} } }) do
      local lines, rules = messages.render(input[1])
      assert.same({}, lines)
      assert.same({}, rules)
    end
  end)

  it("renders an info message as one line with no position", function()
    local lines = messages.render({ { level = "info", text = "hello" } })
    assert.equals(1, #lines)
    assert.equals("› hello", lines[1])
  end)

  it("highlights info and warning with distinct groups", function()
    local _, rules = messages.render({
      { level = "info",    text = "out" },
      { level = "warning", text = "careful" },
    })
    assert.equals("GrannosMessageInfo", rules[1].higroup)
    assert.equals("GrannosMessageWarning", rules[2].higroup)
  end)

  it("prefixes a warning with its line and column", function()
    local lines = messages.render({
      { level = "warning", text = "PLS-00201: identifier must be declared", line = 4, col = 5 },
    })
    assert.equals("⚠ 4:5  PLS-00201: identifier must be declared", lines[1])
  end)

  it("prefixes with the line alone when col is absent", function()
    local lines = messages.render({ { level = "warning", text = "boom", line = 7 } })
    assert.equals("⚠ 7  boom", lines[1])
  end)

  it("omits the position entirely when line is absent", function()
    local lines = messages.render({ { level = "warning", text = "boom", col = 3 } })
    assert.equals("⚠ boom", lines[1])
  end)

  it("splits multi-line text and indents the continuation under the first line", function()
    local lines, rules = messages.render({
      { level = "warning", text = "first\nsecond", line = 2, col = 1 },
    })
    assert.equals(2, #lines)
    assert.equals("⚠ 2:1  first", lines[1])
    assert.equals("       second", lines[2])
    -- both lines carry the level's highlight
    assert.equals(2, #rules)
    assert.equals("GrannosMessageWarning", rules[2].higroup)
  end)

  it("numbers highlight rules 0-indexed from the first line", function()
    local _, rules = messages.render({
      { level = "info", text = "a" },
      { level = "info", text = "b" },
    })
    assert.equals(0, rules[1].start[1])
    assert.equals(1, rules[2].start[1])
    assert.equals(-1, rules[1].finish[2])
  end)

  it("falls back to info styling for an unknown level", function()
    local lines, rules = messages.render({ { level = "notice", text = "hm" } })
    assert.equals("› hm", lines[1])
    assert.equals("GrannosMessageInfo", rules[1].higroup)
  end)

  it("tolerates a message with no text", function()
    local lines = messages.render({ { level = "info" } })
    assert.equals("› ", lines[1])
  end)
end)

describe("messages.render_block", function()
  it("appends a blank separator line when there are messages", function()
    local lines = messages.render_block({ { level = "info", text = "x" } })
    assert.same({ "› x", "" }, lines)
  end)

  it("stays empty when there are no messages, so callers can splice unconditionally", function()
    assert.same({}, (messages.render_block(nil)))
    assert.same({}, (messages.render_block({})))
  end)

  it("leaves highlight rows unshifted by the separator", function()
    local _, rules = messages.render_block({ { level = "warning", text = "x" } })
    assert.equals(0, rules[1].start[1])
  end)
end)
