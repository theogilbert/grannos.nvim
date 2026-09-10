require("grannos.hl").setup()
require("grannos.config").setup()

local connections = require("grannos.connections")
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

local function key(name) return connections.conn_key("srv", "postgres", "prod", name) end

local CONNS = {
  [key("alpha")] = { driver_label = "PostgreSQL" },
  [key("beta")]  = { driver_label = "PostgreSQL" },
  [key("gamma")] = { driver_label = "PostgreSQL" },
}

describe("ui.conn_picker", function()
  after_each(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    vim.cmd("silent! only")
  end)

  it("lists every open connection, sorted, with its driver label", function()
    picker.open(CONNS, nil, function() end)

    assert.same({
      "    prod/alpha  (PostgreSQL)",
      "    prod/beta  (PostgreSQL)",
      "    prod/gamma  (PostgreSQL)",
    }, list_lines())
  end)

  it("marks the connection the caller is already on", function()
    picker.open(CONNS, key("beta"), function() end)

    assert.same({
      "    prod/alpha  (PostgreSQL)",
      "  ● prod/beta  (PostgreSQL)",
      "    prod/gamma  (PostgreSQL)",
    }, list_lines())
  end)

  it("filters the list as the search text is typed", function()
    picker.open(CONNS, nil, function() end)
    type_filter("amm")

    assert.same({ "    prod/gamma  (PostgreSQL)" }, list_lines())
  end)

  it("<CR> selects the highlighted connection and closes the float", function()
    vim.cmd("new")
    local origin = vim.api.nvim_get_current_win()

    local chosen
    picker.open(CONNS, nil, function(k) chosen = k end)
    local input_win = vim.api.nvim_get_current_win()

    type_filter("beta")
    feed("<CR>")

    assert.equals(key("beta"), chosen)
    assert.is_false(vim.api.nvim_win_is_valid(input_win))
    assert.equals(origin, vim.api.nvim_get_current_win())
  end)

  it("<C-c> cancels without selecting", function()
    local chosen
    picker.open(CONNS, nil, function(k) chosen = k end)
    local input_win = vim.api.nvim_get_current_win()

    feed("<C-c>")

    assert.is_nil(chosen)
    assert.is_false(vim.api.nvim_win_is_valid(input_win))
  end)

  it("does nothing when there are no open connections", function()
    picker.open({}, nil, function() end)

    local floats = vim.tbl_filter(function(w)
      return vim.api.nvim_win_get_config(w).relative ~= ""
    end, vim.api.nvim_list_wins())
    assert.equals(0, #floats)
  end)
end)
