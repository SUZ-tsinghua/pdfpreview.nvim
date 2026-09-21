.PHONY: native format check test test-native clean

PYTHON ?= python3
STYLUA ?= stylua
LUACHECK ?= luacheck
RUFF ?= ruff
CLANG_FORMAT ?= clang-format

LUA_SOURCES = lua tests examples
PYTHON_SOURCES = tests
NATIVE_SOURCES = native/renderer.m

native: .build/pdfpreview-native

.build/pdfpreview-native: native/renderer.m
	@mkdir -p .build
	@set -e; native_tmp=$$(mktemp .build/pdfpreview-native.XXXXXX); \
	trap 'rm -f "$$native_tmp"' EXIT; \
	xcrun clang -O2 -fobjc-arc -Wall -Wextra -Werror \
		-framework Foundation -framework CoreGraphics -framework ImageIO \
		-framework Metal -framework PDFKit "$<" -o "$$native_tmp"; \
	chmod 755 "$$native_tmp"; \
	mv -f "$$native_tmp" "$@"

format:
	$(STYLUA) $(LUA_SOURCES)
	$(RUFF) check --fix $(PYTHON_SOURCES)
	$(RUFF) format $(PYTHON_SOURCES)
	$(CLANG_FORMAT) -i $(NATIVE_SOURCES)

check:
	$(STYLUA) --check $(LUA_SOURCES)
	$(LUACHECK) $(LUA_SOURCES)
	$(RUFF) check $(PYTHON_SOURCES)
	$(RUFF) format --check $(PYTHON_SOURCES)
	$(CLANG_FORMAT) --dry-run --Werror $(NATIVE_SOURCES)

test:
	$(PYTHON) tests/run.py

test-native: native
	$(PYTHON) tests/run.py --native

clean:
	rm -f .build/pdfpreview-native
