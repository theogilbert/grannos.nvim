require("grannos.hl").setup()
require("grannos.config").setup()

local pane = require("grannos.ui.detail_pane")

--- Press `keys` synchronously in the current window.
--- @param keys string
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

--- Open a scratch window holding `n` numbered lines and focus it.
--- @param n integer
--- @return integer, integer  winid, bufnr
local function scratch_win(n)
  vim.cmd("new")
  local buf = vim.api.nvim_get_current_buf()
  local lines = {}
  for i = 1, n do lines[i] = "line " .. i end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return vim.api.nvim_get_current_win(), buf
end

describe("ui.detail_pane origin restore", function()
  after_each(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    vim.cmd("silent! only")
  end)

  it("capture_origin puts focus and cursor back", function()
    local win = scratch_win(5)
    vim.api.nvim_win_set_cursor(win, { 4, 2 })
    local restore = pane.capture_origin()

    local other = scratch_win(3)
    restore()

    assert.equals(win, vim.api.nvim_get_current_win())
    assert.same({ 4, 2 }, vim.api.nvim_win_get_cursor(win))
    assert.is_true(vim.api.nvim_win_is_valid(other))
  end)

  it("capture_origin is a no-op once the origin window is gone", function()
    scratch_win(3)
    local restore = pane.capture_origin()
    vim.cmd("close")
    local survivor = vim.api.nvim_get_current_win()

    restore()
    assert.equals(survivor, vim.api.nvim_get_current_win())
  end)

  it("closing a single-item float returns to the window it was opened from", function()
    local win = scratch_win(9)
    vim.api.nvim_win_set_cursor(win, { 7, 0 })

    pane.open_single({
      item     = { "detail" },
      title    = "users",
      render   = function(buf, item)
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, item)
        vim.bo[buf].modifiable = false
      end,
      estimate = function() return 1 end,
    })
    local float = vim.api.nvim_get_current_win()
    assert.are_not.equals(win, float)

    feed("q")

    assert.is_false(vim.api.nvim_win_is_valid(float))
    assert.equals(win, vim.api.nvim_get_current_win())
    assert.same({ 7, 0 }, vim.api.nvim_win_get_cursor(win))
  end)

  it("leaving a two-pane float for another window does not drag focus back", function()
    local win = scratch_win(9)

    pane.open_searchable_two_pane({
      items      = { { name = "id" } },
      left_title = " Columns ",
      get_label  = function(item) return item.name end,
      get_title  = function(item) return item.name end,
      render     = function() end,
      estimate   = function() return 1 end,
    })
    local input_win = vim.api.nvim_get_current_win()

    -- The user deliberately moves elsewhere: the float closes itself, but the
    -- window they chose must keep focus.
    local elsewhere = scratch_win(3)
    vim.wait(500, function() return not vim.api.nvim_win_is_valid(input_win) end)

    assert.is_false(vim.api.nvim_win_is_valid(input_win))
    assert.equals(elsewhere, vim.api.nvim_get_current_win())
    assert.are_not.equals(win, vim.api.nvim_get_current_win())
  end)

  it("closing a two-pane float returns to the window it was opened from", function()
    local win = scratch_win(9)
    vim.api.nvim_win_set_cursor(win, { 5, 1 })

    pane.open_searchable_two_pane({
      items      = { { name = "id" }, { name = "email" } },
      left_title = " Columns ",
      get_label  = function(item) return item.name end,
      get_title  = function(item) return item.name end,
      render     = function(buf, item)
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { item.name })
        vim.bo[buf].modifiable = false
      end,
      estimate   = function() return 1 end,
    })
    local input_win = vim.api.nvim_get_current_win()
    assert.are_not.equals(win, input_win)

    feed("<C-c>")

    assert.is_false(vim.api.nvim_win_is_valid(input_win))
    assert.equals(win, vim.api.nvim_get_current_win())
    assert.same({ 5, 1 }, vim.api.nvim_win_get_cursor(win))
  end)
end)

describe("explorer describe float", function()
  after_each(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    vim.cmd("silent! only")
  end)

  it("closing returns to the window it was opened from", function()
    local explorer = require("grannos.ui.explorer")
    local win = scratch_win(9)
    vim.api.nvim_win_set_cursor(win, { 6, 3 })

    explorer.open_describe_float({
      type        = "entity",
      name        = "users",
      kind        = "table",
      schema      = "public",
      comment     = vim.NIL,
      connections = {},
      properties  = {},
    }, { name = "users", type = "table" })
    local float = vim.api.nvim_get_current_win()
    assert.are_not.equals(win, float)

    feed("q")

    assert.is_false(vim.api.nvim_win_is_valid(float))
    assert.equals(win, vim.api.nvim_get_current_win())
    assert.same({ 6, 3 }, vim.api.nvim_win_get_cursor(win))
  end)
end)
