# pdfpreview.nvim

A PDF reader inside Neovim with continuous scrolling, arbitrary zoom and horizontal panning. It uses the Kitty graphics protocol for display, a persistent Core Graphics helper on macOS, and Poppler on other systems. No image plugin is required.

On supported Macs, a Metal compositor moves cached pages at fractional pixel positions. After scrolling or zooming stops, the visible area is redrawn directly from the PDF for sharper text and vector detail. The terminal receives raster images in both cases.

## Requirements

- Neovim 0.11+ in a local terminal. The Metal compositor requires Neovim 0.12+.
- Poppler: `pdfinfo` and `pdftoppm` on `PATH` (`brew install poppler` on macOS, `sudo apt install poppler-utils` on Debian/Ubuntu).
- A terminal supporting Kitty graphics, Unicode image placeholders and local file transmission. Otty on macOS has been tested; Kitty and Ghostty are protocol targets awaiting visual verification.
- `termguicolors` enabled; `mouse = "a"` for wheel input.
- Optional on macOS: Apple's Command Line Tools to build the native helper. Metal composition requires a unified-memory Metal device.

SSH, tmux, Zellij and graphical Neovim clients are not supported.

## Installation

### lazy.nvim / LazyVim

lazy.nvim downloads the plugin into its managed directory and runs the macOS build on installation and updates. No manual clone or fixed checkout location is required. Install the dependencies above first.

In LazyVim, save this as `~/.config/nvim/lua/plugins/pdfpreview.lua`; with plain lazy.nvim, add the inner plugin entry to your existing spec:

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

Restart Neovim and run `:Lazy install pdfpreview.nvim`. After installation finishes, restart once more and run `:checkhealth pdfpreview`, then `:edit document.pdf`. Future `:Lazy update pdfpreview.nvim` runs also rebuild changed native code. To retry a failed build after installing Apple's Command Line Tools, run `:Lazy build pdfpreview.nvim`.

The macOS build uses system frameworks and keeps its helper inside the plugin directory. A missing or incompatible helper falls back to Poppler when `rasterizer = "auto"`; explicitly selecting `"native"` reports the error instead. `:PdfStats` in an open reader reports the selected renderer and rasterizer. See the [lazy.nvim spec documentation](https://lazy.folke.io/spec) for build and setup behavior.

If Snacks handles PDF files, remove `pdf` from its image formats to avoid competing `BufReadCmd` handlers. [examples/lazyvim.lua](examples/lazyvim.lua) includes that configuration. Alternatively, use `auto_open = false` and open documents explicitly with `:PdfOpen`.

### Local development

An unpublished or development checkout can live anywhere. Replace `"SUZ-tsinghua/pdfpreview.nvim"` in the spec with `dir = "/absolute/path/to/pdfpreview.nvim"`. On macOS, run `make native` in that checkout after changing native code.

## Usage

```vim
:PdfOpen /path/to/document.pdf
:PdfZoom 137.5
:PdfPage 12
:PdfReload
:PdfStats
:PdfClose
```

With `auto_open = true`, `:edit document.pdf` opens the reader. `:PdfOpen` without an argument uses the current file path. Paths containing spaces can be passed directly without quotes.

| Input | Action |
| --- | --- |
| Wheel / trackpad scroll | Scroll across page boundaries |
| `j` / `k`, Up / Down | Scroll one row; counts supported |
| `h` / `l`, Left / Right | Pan horizontally; counts supported |
| Ctrl-D / Ctrl-U, PageDown / PageUp | Scroll most of the viewport |
| `+` / `=` / `-` | Zoom in / out |
| Ctrl-wheel | Zoom if the terminal forwards it |
| `0` | Fit the widest page to the window |
| `gg` / `G` | Start / end of document |
| `12G` / `:PdfPage 12` | Go to page 12 |
| `R` | Reload from disk |
| `q` | Close the PDF buffer |

Zoom is relative to fit width: 100% fits the widest page, and the default range is 10%–800%. Zoom and resize preserve the approximate reading position at the viewport center.

True pinch-to-zoom is not supported. The plugin receives discrete wheel events; the surface renderer interpolates their movement over 40 ms by default.

## Configuration

Common options, shown with their defaults:

```lua
require("pdfpreview").setup({
  auto_open = false,
  renderer = "auto",       -- auto, surface, viewport, unicode
  rasterizer = "auto",     -- auto, native, poppler
  scroll_step = 1,          -- Rows per wheel event
  scroll_animation_ms = 40, -- Surface interpolation; 0 disables it
  surface_refine_ms = 100,  -- Idle detail redraw; 0 disables it
  zoom_step = 1.15,
  min_zoom = 0.1,
  max_zoom = 8,
  max_dimension = 4096,    -- Cached page edge limit in pixels
})
```

See `:help pdfpreview-options` for all options. Terminal cell dimensions are detected automatically, with a 9×18 pixel fallback. Set `cell_width` and `cell_height` if the page appears stretched.

## Rendering and resource use

`renderer = "auto"` selects the Metal `surface` renderer in Otty when supported, otherwise `viewport` tiles. Other terminals use whole-page `unicode` placements. `renderer = "viewport"` can explicitly select the tile path.

Surface motion reuses cached page pixels and two output buffers. Terminal read acknowledgments prevent overwriting files still being read. Once motion settles, a separate worker redraws visible PDF text and paths at the final pixel scale. New input cancels obsolete refinement work. Embedded bitmap images remain limited by their original resolution.

The native source cache is capped at 128 MiB and reusable Metal output mappings at 64 MiB. Surface output files hold at most three viewports, capped at 96 MiB including refinement. These are cache/file limits, not total process-memory limits. Hiding a reader removes terminal images and stops refinement; closing terminates its workers and removes temporary files.

Setting `surface_refine_ms = 0` reduces idle CPU and memory use at the cost of fine detail at high zoom. `scroll_animation_ms = 0` reduces intermediate frames. Tile rendering reuses source tiles across scrolling and nearby zoom levels; `prefetch_zoom = false` reduces speculative work. Its page/image cache limits are soft because visible and in-flight images must remain available.

Oversized viewports, compositor errors or missing terminal acknowledgments fall back to tiles. `:PdfStats` reports the active path, fallback reason, cache usage and refinement state. Its input-to-frame timing ends at submission and does not measure screen latency.

## Limitations

- One viewport per document buffer; multiple splits do not have independent positions.
- No PDF text selection, search, links, annotations, outline or SyncTeX.
- No password-protected documents.
- Tile and Unicode paths can look softer at high zoom because their raster size is capped.
- Terminal compatibility and physical input still require manual visual checks.

## Development

Keep the small regression suite in version control. It uses a synthetic PDF and temporary files, without access to a running user session.

```sh
# Neovim, Poppler and Python 3; no Python packages needed
make test

# macOS native checks, including pixel comparisons
python3 -m venv .venv
.venv/bin/python -m pip install -r tests/requirements.txt
make test-native PYTHON=.venv/bin/python
```

`NVIM=/path/to/nvim` selects a different Neovim executable. Native checks build the helper first. Metal-specific checks report a skip when the device or required Neovim API is unavailable; Core Graphics raster/refinement checks still run.

| Suite | Essential coverage |
| --- | --- |
| `core.lua` | Layout, tile coverage, image IDs and synchronized output recovery |
| `reader.lua` | Poppler readers, page boundaries, zoom, split resize and cleanup |
| `surface.lua` | Acknowledgments, cancellation, stale results and bounded file lifetimes |
| `native.lua` | Actual native workers, idle refinement, protocol validation and fallback |
| `ui.lua` | Embedded Neovim image transport, nested waits and stable grids |
| `pixels.py` | Rotation/cropping, Metal pixels, cache eviction and vector detail |

GitHub Actions runs the portable suite on Linux and native checks on macOS. Pixel dependencies are only needed for development. Build products, logs and local benchmark output are ignored.

## License

[MIT](LICENSE).
