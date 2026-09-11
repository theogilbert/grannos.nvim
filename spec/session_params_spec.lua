local session_params = require("grannos.session_params")
local connections    = require("grannos.connections")

local tmp_dir, tmp_file

local KEY_A = connections.conn_key("srv", "prometheus", "", "prod")
local KEY_B = connections.conn_key("srv", "prometheus", "team", "staging")

describe("session_params", function()
  before_each(function()
    tmp_dir  = vim.fn.tempname()
    tmp_file = tmp_dir .. "/nested/session_params.json"
    session_params.file = tmp_file
    session_params.clear_cache()
  end)

  after_each(function()
    session_params.file = nil
    session_params.clear_cache()
    vim.fn.delete(tmp_dir, "rf")
  end)

  it("returns nil for an unknown connection", function()
    assert.is_nil(session_params.get(KEY_A))
  end)

  it("round-trips saved values through the file", function()
    session_params.save(KEY_A, { query_mode = "range", step = 30 })
    session_params.clear_cache()
    assert.same({ query_mode = "range", step = 30 }, session_params.get(KEY_A))
    assert.equals(1, vim.fn.filereadable(tmp_file))
  end)

  it("keeps connections in different groups apart", function()
    session_params.save(KEY_A, { query_mode = "range" })
    session_params.save(KEY_B, { query_mode = "instant" })
    session_params.clear_cache()
    assert.same({ query_mode = "range" },   session_params.get(KEY_A))
    assert.same({ query_mode = "instant" }, session_params.get(KEY_B))
  end)

  it("replaces the previous entry on save", function()
    session_params.save(KEY_A, { query_mode = "range", step = 30 })
    session_params.save(KEY_A, { query_mode = "instant" })
    session_params.clear_cache()
    assert.same({ query_mode = "instant" }, session_params.get(KEY_A))
  end)

  it("deletes a single connection's entry", function()
    session_params.save(KEY_A, { query_mode = "range" })
    session_params.save(KEY_B, { query_mode = "instant" })
    session_params.delete(KEY_A)
    session_params.clear_cache()
    assert.is_nil(session_params.get(KEY_A))
    assert.same({ query_mode = "instant" }, session_params.get(KEY_B))
  end)

  it("deletes every entry of a group", function()
    session_params.save(KEY_A, { query_mode = "range" })
    session_params.save(KEY_B, { query_mode = "instant" })
    session_params.delete_group("srv", "prometheus", "team")
    session_params.clear_cache()
    assert.same({ query_mode = "range" }, session_params.get(KEY_A))
    assert.is_nil(session_params.get(KEY_B))
  end)

  it("moves an entry on rename", function()
    session_params.save(KEY_A, { query_mode = "range" })
    session_params.rename(KEY_A, KEY_B)
    session_params.clear_cache()
    assert.is_nil(session_params.get(KEY_A))
    assert.same({ query_mode = "range" }, session_params.get(KEY_B))
  end)

  it("treats an unreadable file as an empty store", function()
    vim.fn.mkdir(vim.fn.fnamemodify(tmp_file, ":h"), "p")
    vim.fn.writefile({ "not json" }, tmp_file)
    assert.is_nil(session_params.get(KEY_A))
    session_params.save(KEY_A, { query_mode = "range" })
    session_params.clear_cache()
    assert.same({ query_mode = "range" }, session_params.get(KEY_A))
  end)
end)
