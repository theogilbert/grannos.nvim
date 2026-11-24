-- zo / zc in the explorer open and close tree nodes the way they open and
-- close folds. Stubs must be installed before the explorer requires them.
local TREE = {
  [""]                = { { name = "aliases", type = "group", expandable = true },
                          { name = "indices", type = "group", expandable = true } },
  ["indices"]         = { { name = "orders", type = "index", expandable = true } },
  ["indices\0orders"] = { { name = "mappings", type = "group", expandable = true },
                          { name = "status", type = "keyword", expandable = false } },
}

package.loaded["grannos.client"] = {
  request = function(_, params, cb)
    cb(nil, { items = TREE[table.concat(params.path or {}, "\0")] or {} })
    return 1
  end,
  cancel = function() end,
  capabilities = function() return { drivers = {} } end,
}

local explorer = require("grannos.ui.explorer")
require("grannos.config").setup({})
require("grannos.hl").setup()

--- Let scheduled renders run.
local function settle() vim.wait(30, function() return false end) end

--- The explorer's lines with the chevrons and icons stripped to names, indented.
--- @return string[]
local function tree()
  local out = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    local indent = l:match("^(%s*)")
    out[#out + 1] = indent .. l:match("[%w%.]+")
  end
  return out
end

--- Put the cursor on the line naming `name` and press `keys`.
--- @param name string
--- @param keys string
local function press_on(name, keys)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l:match("[%w%.]+") == name then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      break
    end
  end
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
  settle()
end

--- The name on the cursor's line.
--- @return string
local function cursor_name()
  return vim.api.nvim_get_current_line():match("[%w%.]+")
end

describe("explorer zo / zc", function()
  before_each(function()
    explorer.reset()
    vim.cmd("silent! %bwipeout!")
    vim.cmd("enew")
    vim.api.nvim_buf_set_name(0, "q.esconsole")
    settle()  -- the wipe's scheduled teardown, before the new explorer opens
    explorer.open("c", "es", "elasticsearch", "srv\0elasticsearch\0g\0es", "Elasticsearch")
    settle()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find("grannos://explorer", 1, true) then
        vim.api.nvim_set_current_win(w)
      end
    end
  end)

  it("zo expands the node under the cursor, and does nothing on an open one", function()
    press_on("indices", "zo")
    assert.same({ "aliases", "indices", "orders" }, vim.tbl_map(vim.trim, tree()))
    press_on("indices", "zo")
    assert.same({ "aliases", "indices", "orders" }, vim.tbl_map(vim.trim, tree()))
  end)

  it("zo does nothing on a leaf", function()
    press_on("indices", "zo")
    press_on("orders", "zo")
    press_on("status", "zo")
    assert.same({ "aliases", "indices", "orders", "mappings", "status" }, vim.tbl_map(vim.trim, tree()))
  end)

  it("zc collapses an open node and keeps the cursor on it", function()
    press_on("indices", "zo")
    press_on("indices", "zc")
    assert.same({ "aliases", "indices" }, vim.tbl_map(vim.trim, tree()))
    assert.equals("indices", cursor_name())
  end)

  it("zc on a leaf or a closed node collapses its parent and moves onto it", function()
    press_on("indices", "zo")
    press_on("orders", "zo")
    press_on("status", "zc")
    assert.same({ "aliases", "indices", "orders" }, vim.tbl_map(vim.trim, tree()))
    assert.equals("orders", cursor_name())
    press_on("orders", "zc")
    assert.same({ "aliases", "indices" }, vim.tbl_map(vim.trim, tree()))
    assert.equals("indices", cursor_name())
  end)

  it("zc on a closed top-level node does nothing", function()
    press_on("aliases", "zc")
    assert.same({ "aliases", "indices" }, vim.tbl_map(vim.trim, tree()))
  end)
end)
