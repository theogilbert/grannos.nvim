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
