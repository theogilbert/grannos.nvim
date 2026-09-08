local symbol_busy = require("grannos.ui.symbol_busy")

local NS = vim.api.nvim_create_namespace("GrannosSymbolBusy")

--- Return the virtual-text chunks of every indicator mark in `bufnr`.
--- @param bufnr integer
--- @return table[]  { row, text, hl } per mark, in row order
local function marks(bufnr)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })) do
    local chunk = m[4].virt_text and m[4].virt_text[1]
    out[#out + 1] = { row = m[2], text = chunk and chunk[1], hl = chunk and chunk[2] }
  end
  table.sort(out, function(a, b) return a.row < b.row end)
  return out
end

--- Create a scratch buffer with `n` blank lines.
--- @param n integer
--- @return integer
local function scratch(n)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, n do lines[i] = "line " .. i end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

describe("ui.symbol_busy", function()
  after_each(function() symbol_busy.reset() end)

  it("shows a dim spinner and label at the requested row", function()
    local buf = scratch(3)
    symbol_busy.start(buf, 1, "finding users")

    local m = marks(buf)
    assert.equals(1, #m)
    assert.equals(1, m[1].row)
    assert.equals("GrannosExplorerDim", m[1].hl)
    assert.truthy(m[1].text:find("finding users", 1, true))
    -- A braille frame precedes the label.
    assert.truthy(vim.tbl_contains(require("grannos.ui.spinner").FRAMES, m[1].text:match("(%S+) finding")))
  end)

  it("removes the indicator on stop", function()
    local buf = scratch(3)
    local token = symbol_busy.start(buf, 0, "finding orders")
    symbol_busy.stop(token)
    assert.same({}, marks(buf))
  end)

  it("is a no-op when stopped twice or with nil", function()
    local buf = scratch(3)
    local token = symbol_busy.start(buf, 0, "finding orders")
    symbol_busy.stop(token)
    symbol_busy.stop(token)
    symbol_busy.stop(nil)
    assert.same({}, marks(buf))
  end)

  it("tracks several lookups at once, each stopping independently", function()
    local buf = scratch(3)
    local a = symbol_busy.start(buf, 0, "finding a")
    symbol_busy.start(buf, 2, "describing b")
    assert.equals(2, #marks(buf))

    symbol_busy.stop(a)
    local m = marks(buf)
    assert.equals(1, #m)
    assert.equals(2, m[1].row)
    assert.truthy(m[1].text:find("describing b", 1, true))
  end)

  it("follows the line through edits above it", function()
    local buf = scratch(3)
    symbol_busy.start(buf, 2, "finding users")
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "inserted" })
    assert.equals(3, marks(buf)[1].row)
  end)

  it("returns nil and stays quiet for an invalid buffer", function()
    local buf = scratch(1)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.is_nil(symbol_busy.start(buf, 0, "finding users"))
  end)

  it("drops every indicator on reset", function()
    local buf = scratch(3)
    symbol_busy.start(buf, 0, "finding a")
    symbol_busy.start(buf, 1, "finding b")
    symbol_busy.reset()
    assert.same({}, marks(buf))
  end)

  it("animates the label in place without adding marks", function()
    local buf = scratch(3)
    symbol_busy.start(buf, 0, "finding users")
    local first = marks(buf)[1].text
    -- The spinner ticks every 80ms; wait for the glyph to advance.
    vim.wait(500, function() return marks(buf)[1].text ~= first end)
    local m = marks(buf)
    assert.equals(1, #m)
    assert.are_not.equals(first, m[1].text)
    assert.truthy(m[1].text:find("finding users", 1, true))
  end)
end)
