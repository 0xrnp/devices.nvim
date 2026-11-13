NVIM ?= nvim

.PHONY: test fmt lint

# Run the whole suite, or one file: make test FILE=tests/test_process.lua
test:
	$(NVIM) -l tests/run.lua $(FILE)

fmt:
	stylua lua tests plugin

lint:
	stylua --check lua tests plugin
