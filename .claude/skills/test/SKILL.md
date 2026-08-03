---
name: test
description: Run grannos.nvim's plenary.nvim spec files headlessly from the CLI, without needing to open Neovim and run :PlenaryBustedFile by hand. Use when asked to run tests, run the test suite, run a spec file, or verify a change against the tests.
---

Run the plenary specs in `spec/` headlessly.

1. The whole suite is just:

   ```
   make ci
   ```

2. A single file (when an argument names a spec, e.g. `$ARGUMENTS` = `spec/connections_spec.lua`):

   ```
   nvim --headless -u NONE \
     -c "set rtp^=." \
     -c "runtime! plugin/plenary.vim" \
     -c "lua require('plenary.test_harness').test_directory('$ARGUMENTS', { minimal_init = 'spec/minimal_init.lua' })" \
     -c "qa!"
   ```

3. Always pass `minimal_init = 'spec/minimal_init.lua'`, and never fall back to
   plain `PlenaryBustedDirectory`/`PlenaryBustedFile`. Plenary spawns a child
   process per spec file that appends `rtp+=.`, so an installed copy of
   grannos.nvim under `site/pack` — a plugin-manager checkout of the same
   plugin — sits *ahead* of the working tree. Module resolution then splits:
   newly added files load from the working tree while edited ones load from the
   installed copy, so a spec run can report passes against code that isn't the
   code being edited. `spec/minimal_init.lua` prepends the working tree in the
   child, which is what makes the run trustworthy.

4. `-u NONE` skips the user's vimrc and plugin manager entirely, so
   `runtime! plugin/plenary.vim` must be sourced explicitly to register the
   `Plenary*` commands in the outer process.

5. Report results from plenary's own output: list failing test names with their `file:line`, and quote the "Passed in / Expected" diff plenary prints — don't just say "tests failed." Exit code is 1 if any test failed.
