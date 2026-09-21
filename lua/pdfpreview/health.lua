local M = {}
function M.check()
	local health = vim.health
	local config = require("pdfpreview").config
	health.start("pdfpreview.nvim")
	if vim.fn.has("nvim-0.11") == 1 then
		health.ok("Neovim 0.11 or newer")
	else
		health.error("Neovim 0.11+ is required")
	end
	for _, name in ipairs({ "pdfinfo", "pdftoppm" }) do
		local executable = vim.fn.exepath(config[name])
		if executable ~= "" then
			health.ok(name .. ": " .. executable)
		else
			health.error(name .. " was not found", "Install Poppler, e.g. brew install poppler")
		end
	end
	local native = require("pdfpreview.native")
	if config.rasterizer == "poppler" then
		health.info("Rasterizer: Poppler (configured explicitly)")
	elseif native.available(config) then
		health.ok("Persistent macOS rasterizer: " .. native.executable(config))
	elseif config.rasterizer == "native" then
		health.error("Native rasterizer is unavailable", "Run make native in the plugin directory on macOS")
	elseif vim.fn.has("mac") == 1 then
		health.info("Rasterizer: Poppler; run make native in the plugin directory for faster macOS rendering")
	else
		health.info("Rasterizer: Poppler")
	end
	if vim.o.termguicolors then
		health.ok("True color enabled")
	else
		health.error("termguicolors must be enabled")
	end
	if vim.o.mouse:find("a") or vim.o.mouse:find("n") then
		health.ok("Mouse input enabled")
	else
		health.warn("Mouse input is disabled; enable it with :set mouse=a")
	end
	local name = (vim.env.TERM_PROGRAM or ""):lower()
	if name:find("otty") or name:find("ghostty") or vim.env.KITTY_WINDOW_ID then
		health.ok("Recognized terminal: " .. (name ~= "" and name or "kitty"))
	else
		health.warn(
			"Terminal not recognized",
			"Kitty graphics with image cropping and local file transmission is required"
		)
	end
	if vim.env.TMUX or vim.env.ZELLIJ then
		health.error("Multiplexers are not supported in this version")
	end
	if vim.env.SSH_CONNECTION then
		health.warn("SSH is not supported by the local file transport")
	end
	local viewer = require("pdfpreview")
	local stats = viewer._states[vim.api.nvim_get_current_buf()] and viewer.stats()
	if stats then
		health.info("Active renderer: " .. stats.renderer)
		if stats.surface_fallback then
			health.info("Surface fallback: " .. stats.surface_fallback)
		end
	elseif config.renderer == "surface" and not vim.api.nvim_ui_send then
		health.info("Surface rendering needs Neovim 0.12; the reader will use viewport tiles")
	end
	local cw, ch, metrics = require("pdfpreview.terminal").cell_size(config)
	health.info(
		string.format(
			"Cell dimensions: %.3f x %.3f px (width: %s; height: %s)",
			cw,
			ch,
			metrics.width_source,
			metrics.height_source
		)
	)
	if metrics.detected_width then
		health.info(
			string.format("Detected cell dimensions: %.3f x %.3f px", metrics.detected_width, metrics.detected_height)
		)
	elseif metrics.width_source == "fallback" or metrics.height_source == "fallback" then
		health.warn(
			"Terminal pixel dimensions unavailable; automatic axes use the 9 x 18 px fallback",
			"Set cell_width/cell_height if PDF proportions are incorrect"
		)
	end
	health.info(
		"Automatic sizes use integer terminal reports; exact fractional calibration requires manual overrides. See :help pdfpreview-cell-size"
	)
end
return M
