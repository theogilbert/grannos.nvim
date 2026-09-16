require("grannos.hl").setup()
require("grannos.config").setup()

local col_picker = require("grannos.ui.col_picker")

local COLS = { "id", "name", "email", "created_at", "updated_at" }

--- Press `keys` synchronously in the picker window. The filter prompt reads
--- its keys with getcharstr(), which drains the same typeahead, so a filter
--- can be typed as `/nam<CR>`.
--- @param keys string
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

--- Open the picker with every column visible, recording each on_change.
--- @param visible string[]|nil
--- @return { last: string[]|nil, calls: integer }
local function open(visible)
  local out = { last = nil, calls = 0 }
  col_picker.open(COLS, visible or vim.list_extend({}, COLS), function(sel)
    out.last  = sel
    out.calls = out.calls + 1
  end)
  return out
end

--- The left (available) column of the picker's item rows.
--- @return string[]
local function available_shown()
  local lines = vim.api.nvim_buf_get_lines(0, 2, -1, false)
  local names = {}
  for _, l in ipairs(lines) do
    local left = vim.split(l, "│", { plain = true })[1]
    local name = vim.trim(left)
    if name ~= "" then table.insert(names, name) end
  end
  return names
end

--- The picker window's title text.
--- @return string
local function title()
  local t = vim.api.nvim_win_get_config(0).title
  local parts = {}
  for _, chunk in ipairs(t or {}) do table.insert(parts, chunk[1]) end
  return table.concat(parts)
end

describe("ui.col_picker", function()
  after_each(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    vim.cmd("silent! only")
  end)

  describe("undo", function()
    it("takes back a deselect-all", function()
      local out = open({ "id", "name" })
      feed("<lt>")
      assert.same({}, out.last)
      feed("u")
      assert.same({ "id", "name" }, out.last)
    end)

    it("walks back one change at a time, and redo goes forward again", function()
      local out = open({})
      feed("<Tab>")           -- id
      feed("<Tab>")           -- name
      assert.same({ "id", "name" }, out.last)
      feed("u")
      assert.same({ "id" }, out.last)
      feed("u")
      assert.same({}, out.last)
      feed("u")               -- nothing left: no change, no call
      local calls = out.calls
      feed("u")
      assert.equal(calls, out.calls)
      feed("<C-r>")
      assert.same({ "id" }, out.last)
    end)

    it("covers reordering and reset", function()
      local out = open({ "id", "name" })
      feed("l")               -- selected panel
      feed("J")               -- id below name
      assert.same({ "name", "id" }, out.last)
      feed("r")
      assert.same({ "id", "name" }, out.last)
      feed("u")
      assert.same({ "name", "id" }, out.last)
    end)
  end)

  describe("filter", function()
    it("narrows the available panel and shows the match count in the title", function()
      open({})
      feed("/at<CR>")
      assert.same({ "created_at", "updated_at" }, available_shown())
      assert.equal(" Columns  /at  2 of 5 ", title())
    end)

    it("Tab picks the highlighted match", function()
      local out = open({})
      feed("/nam<CR><Tab>")
      assert.same({ "name" }, out.last)
      assert.same({}, available_shown())  -- nothing else matches
    end)

    it("> selects only the matches", function()
      local out = open({})
      feed("/_at<CR>>")
      assert.same({ "created_at", "updated_at" }, out.last)
      feed("<Esc>")           -- clears the filter rather than closing
      assert.same({ "id", "name", "email" }, available_shown())
      assert.equal(" Columns ", title())
      assert.is_true(vim.api.nvim_win_get_config(0).relative ~= "")
    end)

    it("Esc while typing drops the filter", function()
      open({})
      feed("/nam<Esc>")
      assert.same(COLS, available_shown())
      assert.equal(" Columns ", title())
    end)

    it("Backspace edits the filter", function()
      open({})
      feed("/namx<BS><CR>")
      assert.same({ "name" }, available_shown())
    end)

    it("Tab while typing picks the match, clears the filter and keeps the prompt", function()
      local out = open({})
      feed("/nam<Tab>ema<Tab><Esc>")
      assert.same({ "name", "email" }, out.last)
      assert.same({ "id", "created_at", "updated_at" }, available_shown())
      assert.equal(" Columns ", title())
      assert.is_true(vim.api.nvim_win_get_config(0).relative ~= "")
    end)

    it("Down and Up while typing move among the matches", function()
      local out = open({})
      feed("/at<Down><Tab><Esc>")
      assert.same({ "updated_at" }, out.last)
      feed("/at<Down><Up><Tab><Esc>")
      assert.same({ "updated_at", "created_at" }, out.last)
    end)

    it("/ starts a fresh filter rather than extending the kept one", function()
      open({})
      feed("/at<CR>/nam<CR>")
      assert.same({ "name" }, available_shown())
      assert.equal(" Columns  /nam  1 of 5 ", title())
    end)
  end)
end)
