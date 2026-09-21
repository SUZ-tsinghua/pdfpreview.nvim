# pdfpreview.nvim

A PDF reader inside Neovim with continuous scrolling, arbitrary zoom, horizontal panning, text selection and translation. It uses Kitty graphics for display, Core Graphics and PDFKit on macOS, and Poppler on other systems. No image plugin is required.

On supported Macs, a Metal compositor moves cached pages while scrolling or zooming. Once movement stops, the visible area is redrawn directly from the PDF for sharper text and vector detail. Selecting text preserves that resolution.

## Requirements

- Neovim 0.11+ in a local terminal; Metal composition requires 0.12+.
- Poppler (`brew install poppler` on macOS, `sudo apt install poppler-utils` on Debian/Ubuntu). Rendering requires `pdfinfo` and `pdftoppm`; word selection and the text fallback use `pdftotext`.
- A terminal supporting Kitty graphics, Unicode image placeholders and local file transmission. Otty on macOS has been tested; Kitty and Ghostty await visual verification.
- `termguicolors` enabled and `mouse = "a"` for mouse input.
- Optional on macOS: Apple's Command Line Tools to build the native helper. Metal composition also requires a unified-memory Metal device.
- Optional for translation: `curl` and internet access. System clipboard copying needs a Neovim clipboard provider; yanking to registers works without one.

SSH, tmux, Zellij and graphical Neovim clients are not supported.

## Installation

In LazyVim, save this as `~/.config/nvim/lua/plugins/pdfpreview.lua`. With plain lazy.nvim, add the plugin entry to your existing spec:

```lua
return {
	{
		"SUZ-tsinghua/pdfpreview.nvim",
		main = "pdfpreview",
		lazy = false,
		build = vim.fn.has("mac") == 1 and "make native" or nil,
		opts = { auto_open = true },
	},
}
```

Install the dependencies first, restart Neovim and run `:Lazy install pdfpreview.nvim`. After installation finishes, restart and run `:checkhealth pdfpreview`, then `:edit document.pdf`.

lazy.nvim builds the macOS helper inside its managed plugin directory on installation and updates. To retry a failed build, run `:Lazy build pdfpreview.nvim`. The automatic rasterizer falls back to Poppler if the helper is unavailable or incompatible; explicitly choosing `rasterizer = "native"` reports the error instead.

If Snacks also handles PDFs, remove `pdf` from its image formats to avoid competing handlers. [examples/lazyvim.lua](examples/lazyvim.lua) includes that configuration. Alternatively, set `auto_open = false` and use `:PdfOpen`.

For a development checkout, replace `"SUZ-tsinghua/pdfpreview.nvim"` with `dir = "/absolute/path/to/pdfpreview.nvim"`. Run `make native` in that checkout after changing native code.

## Usage

Open a document with `:PdfOpen /path/to/document.pdf`, or `:edit document.pdf` when `auto_open` is enabled. `:PdfOpen` without an argument uses the current file. Paths containing spaces do not need quotes.

| Input | Action |
| --- | --- |
| Left click / drag | Select PDF text |
| Double-click | Select a whole word |
| `y` / `"ay` | Copy to the unnamed / named register |
| Ctrl-C / `:PdfCopy` | Copy to the system clipboard |
| Right click / `:PdfTranslate` | Open Copy / Translate menu / translate the selection |
| Escape | Clear selection |
| Wheel, `j` / `k` | Scroll across page boundaries |
| `h` / `l` | Pan horizontally |
| `+` / `-`, `:PdfZoom 137.5` | Zoom relative to fit width |
| `0` | Fit the widest page to the window |
| `12G` / `:PdfPage 12` | Go to page 12 |
| `R` / `:PdfReload` | Reload from disk |
| `q` / `:PdfClose` | Close the PDF buffer |

The macOS helper selects individual characters through PDFKit; Poppler selects whole words. Text extraction is local and requires an existing text layer, with no OCR. Mouse positions use terminal cells, so zooming in helps select small letters. Hold the mouse button and scroll to extend across pages. See `:help pdfpreview-selection` and `:help pdfpreview-mappings` for details.

Translation appears in a Neovim float. Click outside, press `q` or Escape to close the menu or result. The default is English → Simplified Chinese through Google's free web endpoint, with MyMemory as a fallback for short selections. No account or API key is needed. Choosing Translate sends the selected text to the service; selecting and copying remain local. See `:help pdfpreview-translation` for limits and options.

## Configuration

A few defaults:

```lua
require("pdfpreview").setup({
	auto_open = false,
	renderer = "auto", -- auto, surface, viewport, unicode
	rasterizer = "auto", -- auto, native, poppler
	text_backend = "auto", -- auto, pdfkit (characters), poppler (words)
	scroll_animation_ms = 40, -- 0 disables interpolation
	surface_refine_ms = 100, -- 0 disables the idle detail redraw
	surface_refine_scale = 2, -- Idle pixel density multiplier (1–2)
})
```

The complete reference is in [doc/pdfpreview.txt](doc/pdfpreview.txt), available as `:help pdfpreview`:

- `pdfpreview-options`: all defaults, renderer selection and resource controls.
- `pdfpreview-translation`: language, provider, fallback and timeout settings.
- `pdfpreview-cell-size`: automatic detection and manual calibration when proportions look wrong.
- `pdfpreview-rendering`: rendering paths, refinement, cache limits and fallback behavior.

Use `:checkhealth pdfpreview` for dependencies and terminal dimensions, and `:PdfStats` for the active renderer, rasterizer, text backend and cache usage. Timing statistics stop at frame submission; they do not measure screen latency.

There is one viewport per document buffer. OCR, PDF search, links, annotations, outlines, SyncTeX, password-protected documents and true pinch-to-zoom are not supported. Terminal compatibility and physical input still need visual checks.

## Development

Formatting and linting use StyLua and Luacheck for Lua, Ruff for Python, and clang-format for Objective-C. The native build also enables `-Wall -Wextra -Werror`. Install Luacheck (`brew install luacheck` or `sudo apt install lua-check`) and the pinned tools with Python 3.10+:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements-dev.txt
make format
make check

# Optional: run the same quick checks before each commit.
pre-commit install
```

The hook uses `make check`, so the development tools must be on `PATH` when committing. CI runs the same check. Formatting is explicit; checks report changes without rewriting files.

Tests use synthetic PDFs, isolated Neovim processes and temporary files. They do not access a running user session or call translation services.

```sh
# Neovim, Poppler and Python 3.9+; no Python packages needed.
make test

# macOS native checks, including PDFKit, Metal and pixel comparisons.
python -m pip install -r tests/requirements.txt
make test-native PYTHON=python
```

`NVIM=/path/to/nvim` selects a Neovim executable; `PYTHON=/path/to/python` selects Python. Native checks build the helper first. Metal checks report a skip if the device or Neovim API is unavailable; Core Graphics and PDFKit checks still run. Full tests stay separate from the commit hook.

| Suite | Coverage |
| --- | --- |
| `core.lua` | Cell detection, layout, tile coverage, image IDs and output recovery |
| `reader.lua` | Poppler readers, scrolling, zoom, dimension changes and cleanup |
| `surface.lua` | Acknowledgments, cancellation, stale results and file lifetimes |
| `selection.lua` | Poppler extraction, selection geometry, mouse/yank mappings, clipboard and context menus |
| `pdfkit.lua` | Character extraction, partial-word copying, word expansion and text fallback |
| `translate.lua` | Response parsing, stdin transport, caching, fallback, errors and cancellation |
| `native.lua` | Native workers, refinement, protocol validation and rendering fallback |
| `ui.lua` | Embedded Neovim image transport, nested waits and stable grids |
| `pixels.py` | Character bounds, rotation/cropping, selection pixels, cache eviction and vector detail |

GitHub Actions runs portable tests on Linux with Neovim 0.11 and stable, and native tests on macOS. Development tools and pixel-test packages are not runtime dependencies.

## License

[MIT](LICENSE).
