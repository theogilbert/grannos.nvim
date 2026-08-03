.PHONY: ci

# `minimal_init` is what puts this working tree ahead of any installed copy of
# the plugin in the child processes plenary spawns — see spec/minimal_init.lua.
ci:
	nvim --headless -u NONE \
		-c "set rtp^=." \
		-c "runtime! plugin/plenary.vim" \
		-c "lua require('plenary.test_harness').test_directory('spec/', { minimal_init = 'spec/minimal_init.lua' })" \
		-c "qa!"
