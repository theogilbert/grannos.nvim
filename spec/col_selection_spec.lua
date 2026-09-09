local col_selection = require("grannos.col_selection")

local COLS = { "id", "name", "email", "created_at" }

local tmp_root, proj_a, proj_b, orig_cwd

--- Point the module at a scratch storage root and start from an empty store.
local function reset_storage()
  col_selection.root = tmp_root
  col_selection.clear_cache()
  vim.fn.delete(tmp_root, "rf")
end

--- Switch the global working directory, which is what scopes a selection.
--- @param dir string
local function cd(dir)
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
end

describe("col_selection", function()
  before_each(function()
    orig_cwd = vim.fn.getcwd(-1, -1)
    tmp_root = vim.fn.tempname()
    proj_a   = vim.fn.tempname()
    proj_b   = vim.fn.tempname()
    vim.fn.mkdir(proj_a, "p")
    vim.fn.mkdir(proj_b, "p")
    reset_storage()
    cd(proj_a)
  end)

  after_each(function()
    cd(orig_cwd)
    col_selection.root = nil
    col_selection.clear_cache()
    vim.fn.delete(tmp_root, "rf")
    vim.fn.delete(proj_a, "rf")
    vim.fn.delete(proj_b, "rf")
  end)

  it("returns nil when nothing was ever saved", function()
    assert.is_nil(col_selection.load(COLS))
  end)

  it("returns nil for an empty column list", function()
    assert.is_nil(col_selection.load({}))
  end)

  it("round-trips a selection, preserving display order", function()
    col_selection.save(COLS, { "name", "id" })
    assert.same({ "name", "id" }, col_selection.load(COLS))
  end)

  it("survives a restart: the selection is read back from disk", function()
    col_selection.save(COLS, { "email" })
    col_selection.clear_cache()
    assert.same({ "email" }, col_selection.load(COLS))
  end)

  it("keeps a selection of no columns", function()
    col_selection.save(COLS, {})
    col_selection.clear_cache()
    assert.same({}, col_selection.load(COLS))
  end)

  it("scopes a selection to its project", function()
    col_selection.save(COLS, { "id" })
    cd(proj_b)
    assert.is_nil(col_selection.load(COLS))
    col_selection.save(COLS, { "name" })
    assert.same({ "name" }, col_selection.load(COLS))
    cd(proj_a)
    assert.same({ "id" }, col_selection.load(COLS))
  end)

  it("scopes a selection to its column list", function()
    col_selection.save(COLS, { "id" })
    assert.is_nil(col_selection.load({ "a", "b" }))
    -- Same names, different order: a different result shape.
    assert.is_nil(col_selection.load({ "name", "id", "email", "created_at" }))
  end)

  it("overwrites an earlier selection for the same columns", function()
    col_selection.save(COLS, { "id" })
    col_selection.save(COLS, { "email", "name" })
    col_selection.clear_cache()
    assert.same({ "email", "name" }, col_selection.load(COLS))
  end)

  it("clears the stored selection when every column is selected again", function()
    col_selection.save(COLS, { "id" })
    col_selection.save(COLS, vim.list_extend({}, COLS))
    col_selection.clear_cache()
    assert.is_nil(col_selection.load(COLS))
  end)

  it("does not store a full selection in the first place", function()
    col_selection.save(COLS, vim.list_extend({}, COLS))
    col_selection.clear_cache()
    assert.is_nil(col_selection.load(COLS))
  end)

  it("drops stored names that the result no longer has", function()
    col_selection.save(COLS, { "name", "id" })

    -- Simulate a hand-edited or stale file: same key, a name that is gone.
    local file = vim.fn.glob(tmp_root .. "/*.json", false, true)[1]
    local decoded = vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
    for _, entry in pairs(decoded.selections) do
      entry.visible = { "name", "gone", "id" }
    end
    vim.fn.writefile({ vim.json.encode(decoded) }, file)
    col_selection.clear_cache()

    assert.same({ "name", "id" }, col_selection.load(COLS))
  end)

  it("ignores an unparsable store rather than erroring", function()
    col_selection.save(COLS, { "id" })
    local file = vim.fn.glob(tmp_root .. "/*.json", false, true)[1]
    vim.fn.writefile({ "not json {" }, file)
    col_selection.clear_cache()

    assert.is_nil(col_selection.load(COLS))
  end)

  it("mutating the saved lists afterwards does not change the store", function()
    local cols    = vim.list_extend({}, COLS)
    local visible = { "id" }
    col_selection.save(cols, visible)
    table.insert(visible, "name")
    cols[1] = "mutated"
    col_selection.clear_cache()

    assert.same({ "id" }, col_selection.load(COLS))
  end)
end)
