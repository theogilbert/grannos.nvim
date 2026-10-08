require("grannos.hl").setup()
require("grannos.config").setup()

local col_picker = require("grannos.ui.col_picker")

local COLS = { "id", "name", "email", "created_at", "updated_at" }

--- Press `keys` synchronously in the picker window.
--- @param keys string
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

--- Open the picker, recording each on_change.
--- @param visible string[]|nil  defaults to every column
--- @return { last: string[]|nil, calls: integer }
local function open(visible)
  local out = { last = nil, calls = 0 }
  col_picker.open(COLS, visible or vim.list_extend({}, COLS), function(sel)
    out.last  = sel
    out.calls = out.calls + 1
  end)
  return out
end

--- The picker buffer's lines: the column names, in list order.
--- @return string[]
local function lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

--- The sign beside each line, in line order.
--- @return string[]
local function signs()
  local out = {}
  local ns = vim.api.nvim_get_namespaces()["grannos_col_picker"]
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
    out[m[2] + 1] = vim.trim(m[4].sign_text)
  end
  return out
end

--- The picker window's title text.
--- @return string
local function title()
  local parts = {}
  for _, chunk in ipairs(vim.api.nvim_win_get_config(0).title or {}) do table.insert(parts, chunk[1]) end
  return table.concat(parts)
end

describe("ui.col_picker", function()
  after_each(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    vim.fn.setreg("/", "")
    vim.cmd("silent! only")
  end)

  describe("layout", function()
    it("lists bare names, one per line, with the state in the sign column", function()
      open({ "id", "email" })
      assert.same(COLS, lines())
      assert.same({ "󰄲", "󰄱", "󰄲", "󰄱", "󰄱" }, signs())
      assert.equal(" Columns  2 of 5 shown ", title())
    end)

    it("slots a hidden column after the column it follows in the result", function()
      open({ "email", "id" })
      assert.same({ "email", "created_at", "updated_at", "id", "name" }, lines())
      assert.same({ "󰄲", "󰄱", "󰄱", "󰄲", "󰄱" }, signs())
    end)

    it("a hidden first column opens at the top", function()
      open({ "name", "email" })
      assert.same({ "id", "name", "email", "created_at", "updated_at" }, lines())
    end)

    it("is not modifiable", function()
      open()
      assert.is_false(vim.bo.modifiable)
    end)
  end)

  describe("toggling", function()
    it("Space toggles the column under the cursor, in place", function()
      local out = open()
      feed("j<Space>")
      assert.same({ "id", "email", "created_at", "updated_at" }, out.last)
      assert.same(COLS, lines())
      assert.equal(2, vim.fn.line("."))
      feed("<Space>")
      assert.same(COLS, out.last)
    end)

    it("visual Space toggles every selected line", function()
      local out = open()
      feed("jVj<Space>")
      assert.same({ "id", "created_at", "updated_at" }, out.last)
      assert.equal("n", vim.fn.mode())
    end)

    it("a mixed range is shown, not flipped line by line", function()
      local out = open({ "id", "email" })
      feed("Vjj<Space>")
      assert.same({ "id", "name", "email" }, out.last)
    end)

    it("g/ toggles every column the last search matches", function()
      local out = open()
      feed("/_at$<CR>")
      assert.equal(4, vim.fn.line("."))
      feed("g/")
      assert.same({ "id", "name", "email" }, out.last)
      feed("g/")
      assert.same(COLS, out.last)
    end)

    it("search matches names, not the shown/hidden state", function()
      open({ "id" })
      feed("/^name<CR>")
      assert.equal(2, vim.fn.line("."))
    end)

    it("> and < show and hide every column", function()
      local out = open({ "id" })
      feed(">")
      assert.same(COLS, out.last)
      feed("<lt>")
      assert.same({}, out.last)
      assert.equal(" Columns  0 of 5 shown ", title())
    end)
  end)

  describe("reordering", function()
    it("J/K move the column and the cursor follows", function()
      local out = open()
      feed("J")
      assert.same({ "name", "id", "email", "created_at", "updated_at" }, out.last)
      assert.equal(2, vim.fn.line("."))
      feed("2J")
      assert.same({ "name", "email", "created_at", "id", "updated_at" }, out.last)
      assert.equal(4, vim.fn.line("."))
      feed("K")
      assert.same({ "name", "email", "id", "created_at", "updated_at" }, out.last)
    end)

    it("a hidden column keeps its place when moved", function()
      local out = open()
      feed("<Space>J")
      assert.same({ "name", "id", "email", "created_at", "updated_at" }, lines())
      assert.same({ "name", "email", "created_at", "updated_at" }, out.last)
    end)

    it("moving past an end is no change", function()
      local out = open()
      feed("K")
      assert.equal(0, out.calls)
    end)
  end)

  describe("undo", function()
    it("takes back a hide-all", function()
      local out = open({ "id", "name" })
      feed("<lt>")
      assert.same({}, out.last)
      feed("u")
      assert.same({ "id", "name" }, out.last)
    end)

    it("walks back one change at a time, and redo goes forward again", function()
      local out = open({})
      feed("<Space>j<Space>")
      assert.same({ "id", "name" }, out.last)
      feed("u")
      assert.same({ "id" }, out.last)
      feed("u")
      assert.same({}, out.last)
      local calls = out.calls
      feed("u")                -- nothing left: no change, no call
      assert.equal(calls, out.calls)
      feed("<C-r>")
      assert.same({ "id" }, out.last)
    end)

    it("covers reordering and reset", function()
      local out = open({ "id", "name" })
      feed("J")
      assert.same({ "name", "id" }, out.last)
      feed("r")
      assert.same({ "id", "name" }, out.last)
      feed("u")
      assert.same({ "name", "id" }, out.last)
    end)
  end)

  it("draws a gap between the sign and the name", function()
    open({ "name" })
    local col = vim.api.nvim_eval_statusline(vim.wo.statuscolumn,
      { winid = 0, use_statuscol_lnum = 2 }).str
    -- The sign cell, its padding cell, then the gap.
    assert.equal("󰄲  ", col)
  end)

  it("q closes", function()
    open()
    feed("q")
    assert.equal("", vim.api.nvim_win_get_config(0).relative)
  end)

  it("Esc does not close", function()
    open()
    feed("/name<CR><Esc>")
    assert.is_true(vim.api.nvim_win_get_config(0).relative ~= "")
    feed("V<Esc><Esc>")
    assert.is_true(vim.api.nvim_win_get_config(0).relative ~= "")
  end)
end)
