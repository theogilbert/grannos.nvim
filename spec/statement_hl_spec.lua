-- The statement `execute` would run from the cursor is highlighted in connected
-- buffers, and the highlight and `execute` agree on what that is.

--- Requests the stub client has received, by method.
--- @type table<string, table[]>
local requests = {}

local CAPS = { server = "srv", drivers = { { driver = "pg", label = "Postgres", params = {} } } }

package.loaded["grannos.client"] = {
  is_running          = function() return true end,
  set_exit_handler    = function() end,
  capabilities        = function() return CAPS end,
  ensure_capabilities = function(cb) cb(CAPS) end,
  request = function(method, params, cb)
    requests[method] = requests[method] or {}
    table.insert(requests[method], params)
    if method == "connect" and cb then cb(nil, { connection_id = 1 }) end
    return 1
  end,
  cancel      = function() end,
  get_session = function(_, cb) cb(nil, {}) end,
  set_session = function(_, _, cb) cb(nil) end,
}

local grannos      = require("grannos")
local config       = require("grannos.config")

local NS  = vim.api.nvim_create_namespace("GrannosStatementHl")
local KEY = "srv\0pg\0\0prod"

local SQL = {
  "SELECT 1",       -- 0
  "FROM a;",        -- 1
  "",               -- 2
  "SELECT 2",       -- 3
  "FROM b;",        -- 4
  "",               -- 5
}

--- Return the highlighted range of `bufnr` as { start_row, start_col, end_row, end_col }, or nil.
--- @param bufnr integer
--- @return integer[]|nil
local function mark(bufnr)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })
  assert.is_true(#marks <= 1)
  if not marks[1] then return nil end
  return { marks[1][2], marks[1][3], marks[1][4].end_row, marks[1][4].end_col }
end

--- Move the cursor to the 0-indexed `row` and let CursorMoved run.
--- @param row integer
local function goto_row(row)
  vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
end

describe("statement highlight", function()
  local bufnr

  before_each(function()
    grannos.setup({ auto_attach = false })
    requests = {}
    vim.cmd("silent! only!")
    vim.cmd("enew!")
    bufnr = vim.api.nvim_get_current_buf()
    vim.bo[bufnr].filetype = "sql"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, SQL)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
  end)

  after_each(function()
    grannos.set_buf_conn(bufnr, nil)
  end)

  it("follows the cursor, and shows nothing where nothing would run", function()
    grannos._do_connect(KEY, {}, function() end)
    grannos.set_buf_conn(bufnr, KEY)
    assert.same({ 0, 0, 1, 7 }, mark(bufnr))
    goto_row(4)
    assert.same({ 3, 0, 4, 7 }, mark(bufnr))
    goto_row(2)
    assert.is_nil(mark(bufnr))
  end)

  it("marks what execute runs", function()
    grannos._do_connect(KEY, {}, function() end)
    grannos.set_buf_conn(bufnr, KEY)
    goto_row(4)
    grannos.execute()
    local sent = requests["execute"][1]
    assert.equals("SELECT 2\nFROM b", sent.query or sent.sql)
    assert.same({ 3, 0, 4, 7 }, mark(bufnr))
  end)

  it("marks the current line when it is outside every statement", function()
    vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, { "-- note" })
    grannos._do_connect(KEY, {}, function() end)
    grannos.set_buf_conn(bufnr, KEY)
    goto_row(2)
    assert.same({ 2, 0, 2, 7 }, mark(bufnr))
  end)

  it("follows edits that leave the cursor in place", function()
    grannos._do_connect(KEY, {}, function() end)
    grannos.set_buf_conn(bufnr, KEY)
    vim.api.nvim_buf_set_lines(bufnr, 0, 2, false, { "SELECT 1;" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
    assert.same({ 0, 0, 0, 9 }, mark(bufnr))
  end)

  it("clears in visual and insert mode, and comes back in normal mode", function()
    grannos._do_connect(KEY, {}, function() end)
    grannos.set_buf_conn(bufnr, KEY)
    assert.is_not_nil(mark(bufnr))
    vim.cmd("normal! v")
    assert.is_nil(mark(bufnr))
    vim.cmd("normal! \27")
    assert.is_not_nil(mark(bufnr))
    -- Insert mode only lasts while keys are being processed, so look from inside it.
    _G.statement_hl_insert_mark = "unset"
    _G.statement_hl_probe = function() _G.statement_hl_insert_mark = mark(bufnr) or "none" end
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("i<Cmd>lua statement_hl_probe()<CR><Esc>", true, false, true), "x", false)
    assert.equals("none", _G.statement_hl_insert_mark)
    assert.is_not_nil(mark(bufnr))
  end)

  it("clears when the cursor leaves the buffer", function()
    grannos._do_connect(KEY, {}, function() end)
    grannos.set_buf_conn(bufnr, KEY)
    vim.cmd("new")
    assert.is_nil(mark(bufnr))
    vim.cmd("close")
    assert.is_not_nil(mark(bufnr))
  end)

  it("stops when the buffer is detached", function()
    grannos._do_connect(KEY, {}, function() end)
    grannos.set_buf_conn(bufnr, KEY)
    grannos.set_buf_conn(bufnr, nil)
    assert.is_nil(mark(bufnr))
    goto_row(4)
    assert.is_nil(mark(bufnr))
  end)

  it("stays off when disabled", function()
    config.setup({ auto_attach = false, statement_highlight = false })
    grannos._do_connect(KEY, {}, function() end)
    grannos.set_buf_conn(bufnr, KEY)
    assert.is_nil(mark(bufnr))
    goto_row(4)
    assert.is_nil(mark(bufnr))
  end)
end)
