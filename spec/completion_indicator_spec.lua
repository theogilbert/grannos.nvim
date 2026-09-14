-- The fetch indicator: end-of-line virtual text on the cursor line while a
-- completion listing is in flight for the current buffer's connection.
-- Stubs must be installed before the modules under test require them.

--- Callbacks of requests the stub has received but not answered yet.
local held = {}

package.loaded["grannos.client"] = {
  request = function(_method, params, cb)
    held[#held + 1] = { path = params.path, cb = cb }
  end,
}
package.loaded["grannos"] = {
  get_conn = function() return { conn_id = "0" } end,
}

local completion = require("grannos.completion")
local indicator  = require("grannos.completion.indicator")
local config     = require("grannos.config")

local NS = vim.api.nvim_create_namespace("GrannosCompletionFetch")

--- Answer every held request with an empty listing.
local function release_all()
  local pending = held
  held = {}
  for _, req in ipairs(pending) do req.cb(nil, { items = {} }) end
  vim.wait(20, function() return false end)
end

--- Create a SQL buffer holding `lines`, attached for completion, with the
--- cursor on the first line.
--- @param lines string[]
--- @return integer
local function sql_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "sql"
  vim.api.nvim_set_current_buf(buf)
  completion.attach(buf, "conn")
  return buf
end

--- Return the virtual text the indicator has on `row` of `buf`, or nil.
--- @param buf integer
--- @param row integer  0-indexed
--- @return string|nil
local function virt_text_at(buf, row)
  local marks = vim.api.nvim_buf_get_extmarks(buf, NS, { row, 0 }, { row, -1 }, { details = true })
  local mark = marks[1]
  if not mark then return nil end
  return mark[4].virt_text[1][1]
end

describe("completion.indicator", function()
  before_each(function()
    config.setup({})
    completion.setup()
    completion.invalidate()
    held = {}
  end)

  after_each(release_all)

  it("shows nothing while no fetch is in flight", function()
    sql_buf({ "SELECT 1" })
    release_all()
    assert.is_false(indicator.is_shown())
  end)

  it("marks the cursor line while the attach-time priming is in flight", function()
    local buf = sql_buf({ "SELECT 1" })
    assert.is_true(indicator.is_shown())
    assert.is_truthy((virt_text_at(buf, 0) or ""):find("fetching completions", 1, true))
  end)

  it("removes the mark once the last fetch lands, and not before", function()
    local buf = sql_buf({ "SELECT 1" })
    assert.equals(1, #held)
    -- A second listing joins the first in flight.
    require("grannos.completion.cache").children("0", { "public" })
    assert.equals(2, #held)

    local first = table.remove(held, 1)
    first.cb(nil, { items = {} })
    vim.wait(20, function() return false end)
    assert.is_true(indicator.is_shown())

    release_all()
    assert.is_false(indicator.is_shown())
    assert.is_nil(virt_text_at(buf, 0))
  end)

  it("follows the cursor between spinner ticks", function()
    local buf = sql_buf({ "SELECT 1", "SELECT 2" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    -- Long enough for at least one 80ms tick to redraw the mark.
    vim.wait(200, function() return virt_text_at(buf, 1) ~= nil end)
    assert.is_not_nil(virt_text_at(buf, 1))
    assert.is_nil(virt_text_at(buf, 0))
  end)

  it("shows nothing in a buffer that has no connection, even while another fetches", function()
    sql_buf({ "SELECT 1" })
    assert.is_true(indicator.is_shown())
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(other)
    vim.wait(200, function() return not indicator.is_shown() end)
    assert.is_false(indicator.is_shown())
  end)
end)
