local conn_pane   = require("grannos.ui.connections")
local connections = require("grannos.connections")

local LABELS = {
  host              = "Host",
  port              = "Port",
  password          = "Password",
  secret_access_key = "Secret access key",
}

describe("connections pane detail_lines", function()
  it("renders one aligned label/value line per param", function()
    local lines = conn_pane.detail_lines({ host = "db.local", port = 5432 }, LABELS, "password")
    assert.same({
      "Host  db.local",
      "Port  5432",
    }, lines)
  end)

  it("reports a saved password as a masked line", function()
    local lines = conn_pane.detail_lines(
      { host = "db.local", password = "hunter2" }, LABELS, "password")
    assert.same({
      "Host      db.local",
      "Password  " .. connections.PW_MASK,
    }, lines)
  end)

  it("never leaks the stored password", function()
    local lines = conn_pane.detail_lines(
      { host = "db.local", password = "hunter2" }, LABELS, "password")
    assert.is_nil(table.concat(lines, "\n"):find("hunter2", 1, true))
  end)

  it("masks a driver's own secret param, not just `password`", function()
    local lines = conn_pane.detail_lines(
      { region = "eu-west-1", secret_access_key = "abc123" }, LABELS, "secret_access_key")
    -- Lines are ordered by param key, so the secret sits where its key sorts.
    assert.same({
      "region             eu-west-1",
      "Secret access key  " .. connections.PW_MASK,
    }, lines)
  end)

  it("omits the password line when the connection only prompts for one", function()
    local lines = conn_pane.detail_lines(
      { host = "db.local", requires_password = true }, LABELS, "password")
    assert.same({ "Host  db.local" }, lines)
  end)

  it("omits the password line when the stored password is empty", function()
    local lines = conn_pane.detail_lines({ host = "db.local", password = "" }, LABELS, "password")
    assert.same({ "Host  db.local" }, lines)
  end)

  it("masks `password` when capabilities never named a secret key", function()
    local lines = conn_pane.detail_lines({ host = "db.local", password = "hunter2" }, LABELS, nil)
    assert.same({
      "Host      db.local",
      "Password  " .. connections.PW_MASK,
    }, lines)
  end)

  it("falls back to the raw key when the driver supplied no label", function()
    local lines = conn_pane.detail_lines({ warehouse = "wh1", password = "x" }, {}, "password")
    assert.same({
      "password   " .. connections.PW_MASK,
      "warehouse  wh1",
    }, lines)
  end)
end)
