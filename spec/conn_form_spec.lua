-- Rendering of the connection form itself (the wizard's field-list and
-- submit logic is covered by conn_form_wizard_spec, which stubs this module).
local conn_form = require("grannos.ui.conn_form")

require("grannos.config").setup({})
require("grannos.hl").setup()

--- Build a one-field form spec whose Test Connection button reports `err`.
--- @param err   string|nil  error handed to done(false, err); nil = success
--- @param value string|nil  the field's displayed value
--- @return table
local function form_opts(err, value)
  return {
    title  = "Test",
    fields = {
      { key = "host", label = "Host", kind = "text",
        get     = function() return value or "localhost" end,
        display = function() return value or "localhost" end },
    },
    on_submit = function(_, done) done(nil) end,
    on_cancel = function() end,
    on_test   = err and function(_, done) done(false, err) end
      or function(_, done) done(true, nil) end,
  }
end

--- Open a form, press <CR> on the Test Connection button, and return the
--- rendered buffer lines.
--- @param opts table
--- @return string[]
local function render_after_test(opts)
  conn_form.open(opts)
  local buf = vim.api.nvim_get_current_buf()
  -- The button is the row after the last field; move there and activate it.
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("j<CR>", true, false, true), "x", false)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

describe("conn_form rendering", function()
  it("splits a multi-line test error across buffer lines", function()
    local lines = render_after_test(form_opts("connection failed\nFATAL: role does not exist"))
    local first, second
    for i, l in ipairs(lines) do
      if l:find("connection failed", 1, true) then first, second = l, lines[i + 1] end
    end
    assert.is_truthy(first)
    assert.equals("  \xE2\x9C\x97 connection failed", first)
    assert.equals("    FATAL: role does not exist", second)
  end)

  it("renders a single-line test error unchanged", function()
    local lines = render_after_test(form_opts("could not connect"))
    local found = false
    for _, l in ipairs(lines) do
      if l == "  \xE2\x9C\x97 could not connect" then found = true end
    end
    assert.is_true(found)
  end)

  it("strips carriage returns a server error carries", function()
    local lines = render_after_test(form_opts("first\r\nsecond"))
    for _, l in ipairs(lines) do
      assert.is_nil(l:find("\r", 1, true))
    end
  end)

  it("never emits a line containing a newline, whatever a field displays", function()
    local lines = render_after_test(form_opts("boom", "pasted\nvalue"))
    for _, l in ipairs(lines) do
      assert.is_nil(l:find("\n", 1, true))
    end
  end)
end)
