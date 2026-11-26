-- A small animated braille spinner driven by a libuv timer (common.spinner).
--
-- Refcounted: every :start() must be matched by a :stop(); the timer only runs
-- while at least one start is outstanding.  This supports both a single spinner
-- shared by several concurrent loads (explorer) and one spinner per item
-- (connections panel).
local spinner = require("common.spinner")

local M = {}

M.FRAMES = spinner.FRAMES

--- Create and return a new Spinner: :glyph(), :start(), :stop(), :reset().
--- @param on_tick fun()  called on the main loop each time the frame advances
--- @return table
function M.new(on_tick)
  return spinner.new(on_tick, { interval = 80 })
end

return M
