-- Rendering for the `messages` array on an `execute` response: out-of-band text a
-- statement produced alongside its result (Oracle DBMS_OUTPUT lines, PL/SQL
-- compilation errors, and the equivalents other drivers grow later).
--
-- A message is not an error — the statement succeeded. Errors still arrive in the
-- response's `error` field and go through results.show_error.
--
-- Pure: no Neovim API calls, so this is unit-testable on its own.
local M = {}

--- Highlight group per message level. Unknown levels fall back to info, so a
--- server that grows a new level renders as plain output instead of vanishing.
local HIGROUP = {
  info    = "GrannosMessageInfo",
  warning = "GrannosMessageWarning",
}

--- Glyph prefixed to each message, per level. Deliberately not "│": info lines
--- sit directly above the table, and a vertical bar there reads as a broken
--- table row against the box-drawing border underneath.
local ICON = {
  info    = "› ",
  warning = "⚠ ",
}

--- Format the `line`/`col` of a message as a source position prefix.
--- The server sends position as structured fields precisely so it never has to
--- be parsed back out of `text`; this is the one place it gets rendered.
--- @param msg table  ExecuteMessage
--- @return string  e.g. "4:5  ", "4  ", or "" when unpositioned
local function position_prefix(msg)
  if not msg.line then return "" end
  if msg.col then return ("%d:%d  "):format(msg.line, msg.col) end
  return ("%d  "):format(msg.line)
end

--- Render `messages` into buffer lines plus highlight rules.
---
--- Rules are 0-indexed relative to the first returned line, matching the
--- convention the results pane's other builders use; callers shift them by
--- wherever the block lands in the buffer.
---
--- A message whose `text` spans several lines becomes several buffer lines, all
--- carrying the level's highlight. Only the first gets the icon and position
--- prefix; continuation lines are indented to line up under it.
--- @param messages table[]|nil  ExecuteMessage objects from an execute response
--- @return string[] lines
--- @return table[]  hl_rules  { higroup, start = {row, col}, finish = {row, col} }
function M.render(messages)
  local lines, rules = {}, {}
  if not messages then return lines, rules end

  for _, msg in ipairs(messages) do
    local level  = HIGROUP[msg.level] and msg.level or "info"
    local icon   = ICON[level]
    local head   = icon .. position_prefix(msg)
    local indent = string.rep(" ", vim.fn.strchars(head))
    local text   = msg.text or ""
    for i, part in ipairs(vim.split(text, "\n", { plain = true })) do
      table.insert(lines, (i == 1 and head or indent) .. part)
      table.insert(rules, {
        higroup = HIGROUP[level],
        start   = { #lines - 1, 0 },
        finish  = { #lines - 1, -1 },
      })
    end
  end

  return lines, rules
end

--- Render `messages` as a block to sit above other content: the message lines
--- followed by one blank separator line. Empty (no separator) when there are no
--- messages, so callers can splice the result in unconditionally.
--- @param messages table[]|nil
--- @return string[] lines
--- @return table[]  hl_rules
function M.render_block(messages)
  local lines, rules = M.render(messages)
  if #lines > 0 then table.insert(lines, "") end
  return lines, rules
end

return M
