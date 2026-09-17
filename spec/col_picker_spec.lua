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

  describe("marks", function()
    it("m marks columns and Tab moves every marked one at once", function()
      local out = open({})
      feed("mjm")             -- id, email (m steps down: id, then skip name, then email)
      assert.equal(" Columns  2 marked ", title())
      assert.same({ "• id", "name", "• email", "created_at", "updated_at" }, available_shown())
      feed("<Tab>")
      assert.same({ "id", "email" }, out.last)
      assert.equal(1, out.calls)
      assert.equal(" Columns ", title())
      assert.same({ "name", "created_at", "updated_at" }, available_shown())
    end)

    it("m again unmarks, and M clears every mark", function()
      local out = open({})
      feed("mkm")             -- mark id, back up, unmark it
      assert.equal(" Columns ", title())
      feed("mmM")             -- mark name and email, then clear; cursor on created_at
      assert.equal(" Columns ", title())
      feed("<Tab>")           -- nothing marked: the cursor's item alone
      assert.same({ "created_at" }, out.last)
    end)

    it("marks on the selected panel move those columns back", function()
      local out = open({ "id", "name", "email" })
      feed("lmjm<Tab>")       -- selected panel: mark id and email
      assert.same({ "name" }, out.last)
      assert.same({ "id", "email", "created_at", "updated_at" }, available_shown())
    end)

    it("v starts a range that j extends and Tab moves", function()
      local out = open({})
      feed("jvjj<Tab>")       -- name..created_at
      assert.same({ "name", "email", "created_at" }, out.last)
      assert.same({ "id", "updated_at" }, available_shown())
    end)

    it("a range runs either way from its anchor", function()
      local out = open({})
      feed("jjjvkk<Tab>")     -- created_at back to name
      assert.same({ "name", "email", "created_at" }, out.last)
    end)

    it("Esc drops the range before the filter, and v again drops it too", function()
      local out = open({})
      feed("vj<Esc><Tab>")    -- range dropped: name alone moves; cursor lands on email
      assert.same({ "name" }, out.last)
      feed("vjv<Tab>")        -- range email..created_at dropped: created_at alone moves
      assert.same({ "name", "created_at" }, out.last)
      assert.is_true(vim.api.nvim_win_get_config(0).relative ~= "")
    end)

    it("moves marked columns in one undoable step", function()
      local out = open({})
      feed("mmm<Tab>")
      assert.same({ "id", "name", "email" }, out.last)
      feed("u")
      assert.same({}, out.last)
    end)

    it("a filter's Tab picks the highlighted match, marks or not", function()
      local out = open({})
      feed("m/nam<Tab><Esc>")
      assert.same({ "name" }, out.last)
      assert.same({ "• id", "email", "created_at", "updated_at" }, available_shown())
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

    it("keeps the divider running to the bottom of the window when filtered", function()
      open({})
      feed("/nam<CR>")
      local height = vim.api.nvim_win_get_height(0)
      local lines  = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      assert.is_true(#lines >= height)
      for i = 3, height do
        assert.truthy(lines[i]:find("│", 1, true), "row " .. i .. " has no divider")
      end
    end)

    it("ignores special keys instead of typing their bytes into the filter", function()
      open({})
      feed("/na<F5><M-x><C-a>m<CR>")
      assert.same({ "name" }, available_shown())
      assert.equal(" Columns  /nam  1 of 5 ", title())
    end)

    it("/ starts a fresh filter rather than extending the kept one", function()
      open({})
      feed("/at<CR>/nam<CR>")
      assert.same({ "name" }, available_shown())
      assert.equal(" Columns  /nam  1 of 5 ", title())
    end)
  end)
end)
