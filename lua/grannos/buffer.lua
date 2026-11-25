-- Generic buffer abstraction.
-- Ported from nvim-dap-df/lua/nvim-dap-df-pane/buffer.lua.
local hl = require("grannos.hl")

local Buffer = {}
Buffer.__index = Buffer

--- @param name string
--- @param filetype string
--- @param modifiable boolean
--- @param buftype string
--- @param bufhidden string|nil  defaults to "hide"
function Buffer:new(name, filetype, modifiable, buftype, bufhidden)
  local self = setmetatable({}, Buffer)
  self.keymaps    = {}
  self.modifiable = modifiable
  self.buf_id     = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_set_option_value("buftype",    buftype,           { buf = self.buf_id })
  vim.api.nvim_set_option_value("filetype",   filetype,          { buf = self.buf_id })
  vim.api.nvim_set_option_value("bufhidden",  bufhidden or "hide", { buf = self.buf_id })
  vim.api.nvim_set_option_value("swapfile",   false,             { buf = self.buf_id })
  vim.api.nvim_set_option_value("modifiable", modifiable,        { buf = self.buf_id })
  vim.api.nvim_buf_set_name(self.buf_id, name)
  self:set_keymap("n", "g?", function() self:show_help() end,
    { silent = true, desc = "Show keymaps" })
  return self
end

--- Replace the buffer content.
--- @param lines string[]|string
function Buffer:set_content(lines)
  if type(lines) == "string" then lines = vim.split(lines, "\n") end
  for i, line in ipairs(lines) do lines[i] = line:gsub("\n", "") end
  vim.bo[self.buf_id].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf_id, 0, -1, false, lines)
  vim.bo[self.buf_id].modifiable = self.modifiable
end

--- Apply highlight rules, clearing any previous ones.
--- Each rule: { higroup, start = {line, col}, finish = {line, col} }
function Buffer:apply_highlight(rules)
  vim.api.nvim_buf_clear_namespace(self.buf_id, hl.NS_ID, 0, -1)
  for _, rule in ipairs(rules) do
    vim.hl.range(self.buf_id, hl.NS_ID, rule.higroup, rule.start, rule.finish)
  end
end

--- Return true when the underlying buffer handle is still valid.
--- @return boolean
function Buffer:is_valid()
  return vim.api.nvim_buf_is_valid(self.buf_id)
end

--- Delete the underlying buffer (force=true), if valid.
function Buffer:close()
  if self:is_valid() then
    vim.api.nvim_buf_delete(self.buf_id, { force = true })
  end
end

--- Open a floating window listing `keymaps`. Keymaps with a non-empty `group`
--- are rendered under section headers. Closes on q/<Esc>/g?/<C-h>.
--- Shared by Buffer:show_help and any other keymap-tracking UI that isn't
--- built on a Buffer instance (e.g. detail_pane's floating panes).
--- @param keymaps { lhs: string, desc: string, group: string }[]
--- @return integer|nil win  the help float's window id, or nil if there was nothing to show
function Buffer.render_help_float(keymaps)
  local rows = {}
  for _, km in ipairs(keymaps) do
    rows[#rows + 1] = { key = km.lhs, desc = km.desc, group = km.group }
  end
  return require("common.help").float(rows, {
    at     = "cursor",
    title  = " keymaps ",
    close  = { "g?", "<C-h>" },
    hl     = { head = "GrannosHeaderRow" },
    win_ns = hl.NS_ID,
    -- Above any of the plugin's own floats (detail_pane's list window uses
    -- zindex=51 for its stitched-border trick).
    zindex = 200,
  })
end

--- Open a floating window listing all keymaps that have a desc.
--- Keymaps with a `group` field in their opts are rendered under section headers.
function Buffer:show_help()
  local keymaps = {}
  for _, km in ipairs(self.keymaps) do
    local opts = km[3] or {}
    local desc = opts.desc or ""
    if desc ~= "" then
      table.insert(keymaps, { lhs = km[2], desc = desc, group = opts.group or "" })
    end
  end
  Buffer.render_help_float(keymaps)
end

--- Register a buffer-local keymap and record it so it appears in the `g?` help float.
--- `opts.group` (string) groups the key under a named section header in the help float.
--- @param mode     string
--- @param key      string
--- @param callback fun()
--- @param opts     table|nil
function Buffer:set_keymap(mode, key, callback, opts)
  opts        = opts or {}
  local group = opts.group
  opts.group  = nil
  opts.buffer = self.buf_id
  vim.keymap.set(mode, key, callback, opts)
  table.insert(self.keymaps, { mode, key, vim.tbl_extend("force", opts, { group = group }) })
end

return Buffer
