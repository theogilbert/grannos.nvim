-- Test bootstrap, used for both the runner and the child processes plenary
-- spawns per spec file.
--
-- Its whole job is to put this working tree at the *front* of the runtimepath.
-- An installed copy of grannos.nvim under site/pack is loaded automatically and
-- sits ahead of the `rtp+=.` that plenary's child processes add, so without this
-- a spec run resolves each module from whichever copy lists it first: new files
-- come from the working tree while edited ones come from the installed copy,
-- silently testing a mix of two versions.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

-- common.nvim, the UI library grannos is built on: where it was asked
-- for (GRANNOS_COMMON), else a checkout beside this one -- the copy
-- being worked on, when both are -- else whatever is installed, which
-- the runtimepath already holds.
local common = vim.env.GRANNOS_COMMON
if not common then
  for _, dir in ipairs({ root .. "/../common.nvim", root .. "/../../common.nvim" }) do
    if vim.fn.isdirectory(dir .. "/lua/common") == 1 then
      common = vim.fn.fnamemodify(dir, ":p")
      break
    end
  end
end
if common then vim.opt.runtimepath:append(common) end
