.PHONY: native test test-native clean

PYTHON ?= python3

native: .build/pdfpreview-native

.build/pdfpreview-native: native/renderer.m
	@mkdir -p .build
	@set -e; native_tmp=$$(mktemp .build/pdfpreview-native.XXXXXX); \
	trap 'rm -f "$$native_tmp"' EXIT; \
	xcrun clang -O2 -fobjc-arc -Wall -Wextra -Werror -framework Foundation -framework CoreGraphics -framework ImageIO -framework Metal -framework PDFKit "$<" -o "$$native_tmp"; \
	chmod 755 "$$native_tmp"; \
	mv -f "$$native_tmp" "$@"

test:
	$(PYTHON) tests/run.py

test-native: native
	$(PYTHON) tests/run.py --native

clean:
	rm -f .build/pdfpreview-native
