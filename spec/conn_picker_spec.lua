require("grannos.hl").setup()
require("grannos.config").setup()

local picker      = require("grannos.ui.conn_picker")

--- Press `keys` synchronously in the current window.
--- @param keys string
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

--- Append `text` to the picker's search box (the focused window) and let the
--- filter run, without depending on insert-mode typeahead in a headless run.
--- @param text string
local function type_filter(text)
  local buf  = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { line .. text })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
end

--- Lines currently shown in the picker's list window.
--- @return string[]
local function list_lines()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative ~= "" and cfg.height > 1 then
      return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
    end
  end
  return {}
end

local ROWS = {
  { key = "alpha", label = "  prod/alpha  (PostgreSQL)" },
  { key = "beta",  label = "● prod/beta  (PostgreSQL)", hl = "GrannosConnection" },
  { key = "gamma", label = "  prod/gamma  (PostgreSQL)" },
}

--- Open the picker over ROWS, recording the selected row's key or a cancel.
--- @return table  { chosen: string|nil, cancelled: boolean }
local function open(rows)
  local out = { chosen = nil, cancelled = false }
  picker.open({
    rows      = rows or ROWS,
    title     = " Connections ",
    on_select = function(row) out.chosen = row.key end,
    on_cancel = function() out.cancelled = true end,
  })
  return out
end

describe("ui.conn_picker", function()
  after_each(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    vim.cmd("silent! only")
  end)

  -- The list pane indents every row by two columns.
  it("lists every row's label in order", function()
    open()

    assert.same({
      "    prod/alpha  (PostgreSQL)",
      "  ● prod/beta  (PostgreSQL)",
      "    prod/gamma  (PostgreSQL)",
    }, list_lines())
  end)

  it("filters the list as the search text is typed", function()
    open()
    type_filter("amm")

    assert.same({ "    prod/gamma  (PostgreSQL)" }, list_lines())
  end)

  it("<CR> selects the highlighted row and closes the float", function()
    vim.cmd("new")
    local origin = vim.api.nvim_get_current_win()

    local out = open()
    local input_win = vim.api.nvim_get_current_win()

    type_filter("beta")
    feed("<CR>")

    assert.equals("beta", out.chosen)
    assert.is_false(out.cancelled)
    assert.is_false(vim.api.nvim_win_is_valid(input_win))
    assert.equals(origin, vim.api.nvim_get_current_win())
  end)

  it("<C-c> cancels without selecting", function()
    local out = open()
    local input_win = vim.api.nvim_get_current_win()

    feed("<C-c>")

    assert.is_nil(out.chosen)
    assert.is_true(out.cancelled)
    assert.is_false(vim.api.nvim_win_is_valid(input_win))
  end)

  it("does nothing when there are no rows", function()
    local out = open({})

    local floats = vim.tbl_filter(function(w)
      return vim.api.nvim_win_get_config(w).relative ~= ""
    end, vim.api.nvim_list_wins())
    assert.equals(0, #floats)
    assert.is_false(out.cancelled)
  end)
end)
