local col_selection = require("grannos.col_selection")
local connections   = require("grannos.connections")

local COLS = { "id", "name", "email", "created_at" }
local KEY_A = connections.conn_key("srv", "postgres", "prod", "alpha")
local KEY_B = connections.conn_key("srv", "postgres", "prod", "beta")

local tmp

describe("col_selection", function()
  before_each(function()
    tmp = vim.fn.tempname() .. ".json"
    col_selection.file = tmp
    col_selection.clear_cache()
  end)

  after_each(function()
    col_selection.file = nil
    col_selection.clear_cache()
    vim.fn.delete(tmp)
  end)

  it("returns nil when nothing was ever saved, or without a connection", function()
    assert.is_nil(col_selection.load(KEY_A, COLS))
    assert.is_nil(col_selection.load(nil, COLS))
    assert.is_nil(col_selection.load(KEY_A, {}))
  end)

  it("round-trips a selection, preserving display order", function()
    col_selection.save(KEY_A, COLS, { "name", "id" })
    assert.same({ "name", "id" }, col_selection.load(KEY_A, COLS))
  end)

  it("survives a restart: the selection is read back from disk", function()
    col_selection.save(KEY_A, COLS, { "email" })
    col_selection.clear_cache()
    assert.same({ "email" }, col_selection.load(KEY_A, COLS))
  end)

  it("keeps a selection of no columns", function()
    col_selection.save(KEY_A, COLS, {})
    assert.same({}, col_selection.load(KEY_A, COLS))
  end)

  it("scopes a selection to its connection", function()
    col_selection.save(KEY_A, COLS, { "id" })
    assert.is_nil(col_selection.load(KEY_B, COLS))
  end)

  it("applies the last selection to a result with other columns", function()
    col_selection.save(KEY_A, COLS, { "name", "id" })
    -- an edited query: hidden names dropped, chosen order kept, the new column appended
    assert.same({ "name", "id", "total" },
      col_selection.load(KEY_A, { "id", "total", "name", "email" }))
    -- an unrelated query sharing no names: everything, in its own order
    assert.same({ "b", "a" }, col_selection.load(KEY_A, { "b", "a" }))
  end)

  it("replaces the previous selection rather than accumulating it", function()
    col_selection.save(KEY_A, COLS, { "id" })
    col_selection.save(KEY_A, { "x", "y" }, { "y" })
    -- `name`, `email` and `created_at` are no longer hidden: that was the older selection
    assert.same({ "id", "name", "email", "created_at" }, col_selection.load(KEY_A, COLS))
    assert.same({ "y" }, col_selection.load(KEY_A, { "x", "y" }))
  end)

  it("forgets the entry when every column is selected again in its own order", function()
    col_selection.save(KEY_A, COLS, { "id" })
    col_selection.save(KEY_A, COLS, vim.list_extend({}, COLS))
    assert.is_nil(col_selection.load(KEY_A, COLS))
    col_selection.clear_cache()
    assert.is_nil(col_selection.load(KEY_A, COLS))
  end)

  it("keeps a reordering of every column", function()
    col_selection.save(KEY_A, COLS, { "email", "id", "name", "created_at" })
    assert.same({ "email", "id", "name", "created_at" }, col_selection.load(KEY_A, COLS))
  end)

  it("follows the connection through delete, delete_group and rename", function()
    col_selection.save(KEY_A, COLS, { "id" })
    col_selection.rename(KEY_A, KEY_B)
    assert.is_nil(col_selection.load(KEY_A, COLS))
    assert.same({ "id" }, col_selection.load(KEY_B, COLS))
    col_selection.delete(KEY_B)
    assert.is_nil(col_selection.load(KEY_B, COLS))
    col_selection.save(KEY_A, COLS, { "id" })
    col_selection.delete_group("srv", "postgres", "prod")
    assert.is_nil(col_selection.load(KEY_A, COLS))
  end)

  it("ignores an unparsable store rather than erroring", function()
    vim.fn.writefile({ "{not json" }, tmp)
    col_selection.clear_cache()
    assert.is_nil(col_selection.load(KEY_A, COLS))
    col_selection.save(KEY_A, COLS, { "id" })
    assert.same({ "id" }, col_selection.load(KEY_A, COLS))
  end)

  it("mutating the saved lists afterwards does not change the store", function()
    local visible = { "id", "name" }
    col_selection.save(KEY_A, COLS, visible)
    table.insert(visible, "email")
    assert.same({ "id", "name" }, col_selection.load(KEY_A, COLS))
  end)
end)
