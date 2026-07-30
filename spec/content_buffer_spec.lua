local content_buffer = require("grannos.ui.content_buffer")

--- Buffers created by content_buffer.open (each call opens a new tab).
local function close_new_tabs(before_tabpages)
  local before = {}
  for _, t in ipairs(before_tabpages) do before[t] = true end
  for _, t in ipairs(vim.api.nvim_list_tabpages()) do
    if not before[t] and vim.api.nvim_tabpage_is_valid(t) then
      vim.api.nvim_win_close(vim.api.nvim_tabpage_get_win(t), true)
    end
  end
end

describe("content_buffer.open", function()
  local before_tabpages

  before_each(function()
    before_tabpages = vim.api.nvim_list_tabpages()
  end)

  after_each(function()
    close_new_tabs(before_tabpages)
  end)

  --- Return the buffer opened in the newest tab that didn't exist in `before`.
  local function newest_buf()
    for _, t in ipairs(vim.api.nvim_list_tabpages()) do
      local is_new = true
      for _, b in ipairs(before_tabpages) do
        if b == t then is_new = false end
      end
      if is_new then
        return vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(t))
      end
    end
    return nil
  end

  it("decodes base64 content into buffer lines", function()
    content_buffer.open(vim.base64.encode("hello\nworld"), "greeting.txt", "text/plain")
    local buf = newest_buf()
    assert.is_not_nil(buf)
    assert.same({ "hello", "world" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("sets filetype from the filename extension", function()
    content_buffer.open(vim.base64.encode("{}"), "data.json", "application/octet-stream")
    local buf = newest_buf()
    assert.equals("json", vim.bo[buf].filetype)
  end)

  it("falls back to content_type when filename has no recognisable extension", function()
    content_buffer.open(vim.base64.encode("{}"), "logs/2024/a", "application/json")
    local buf = newest_buf()
    assert.equals("json", vim.bo[buf].filetype)
  end)

  it("opens an unnamed buffer so :w always prompts for a path", function()
    content_buffer.open(vim.base64.encode("hi"), "a.txt", "text/plain")
    local buf = newest_buf()
    assert.equals("", vim.api.nvim_buf_get_name(buf))
  end)

  it("refuses content containing NUL bytes and opens no buffer", function()
    local before_count = #vim.api.nvim_list_tabpages()
    content_buffer.open(vim.base64.encode("bin\0ary"), "a.bin", "application/octet-stream")
    assert.equals(before_count, #vim.api.nvim_list_tabpages())
  end)
end)
