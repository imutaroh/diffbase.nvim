NVIM ?= nvim

.PHONY: test lint

test:
	$(NVIM) --headless --clean -l tests/run.lua $(FILTER)

lint:
	@if command -v stylua >/dev/null 2>&1; then \
		stylua --check lua plugin tests; \
	else \
		echo "stylua not installed, skipping lint"; \
	fi
