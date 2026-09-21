vim.opt.rtp:prepend(vim.fn.getcwd())
vim.o.termguicolors = true
vim.env.TERM_PROGRAM = "Otty"
local viewer = require("pdfpreview")
local graphics = require("pdfpreview.graphics")
local backend = require("pdfpreview.backend")
-- Reject a stale helper instead of maintaining multiple private protocols.
local helper = vim.fn.tempname()
vim.fn.writefile({
	"#!/bin/sh",
	"read -r request",
	[[printf '%s\n' '{"id":1,"protocol":0,"pages":[{"width":400,"height":600}]}' ]],
	"cat >/dev/null",
}, helper)
assert(vim.uv.fs_chmod(helper, 448))
for _, mode in ipairs({ "auto", "native" }) do
	local b = backend.new(
		vim.fn.getcwd() .. "/tests/sample.pdf",
		vim.tbl_extend("force", viewer.config, {
			rasterizer = mode,
			native_renderer = helper,
		}),
		function() end
	)
	local done, pages, error = false, nil, nil
	b:info(function(value, err)
		pages, error, done = value, err, true
	end)
	assert(
		vim.wait(5000, function()
			return done
		end, 1),
		"Protocol validation completes"
	)
	if mode == "auto" then
		assert(pages and #pages == 3 and b.rasterizer == "poppler", "Auto mode recovers through Poppler")
	else
		assert(not pages and error:find("make native", 1, true), "Explicit native mode explains how to rebuild")
	end
	b:close()
	assert(
		vim.wait(5000, function()
			return not vim.uv.fs_stat(b.dir)
		end, 1),
		"Rejected workers exit before their directory is removed"
	)
end
vim.fn.delete(helper)
local uploads = 0
graphics.sink = function(data)
	if data:find("a=T", 1, true) and data:find("q=0", 1, true) then
		uploads = uploads + 1
		local id = assert(tonumber(data:match("i=(%d+)")))
		vim.schedule(function()
			vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=" .. id .. ";OK" } })
		end)
	end
end
viewer.setup({
	auto_open = true,
	renderer = "auto",
	rasterizer = "native",
	cell_width = 15.6,
	cell_height = 35,
	scroll_animation_ms = 40,
})
vim.cmd.edit(vim.fn.getcwd() .. "/tests/sample.pdf")
local s = assert(viewer._states[vim.api.nvim_get_current_buf()], "Direct edit opens the surface reader")
local function settled()
	local p = s.surface_state
	return s.frame
		and not s.frame.refining
		and s.frame.zoom == s.zoom
		and s.frame.x == s.x
		and s.frame.y == s.y
		and not s.pending
		and not s.zoom_target
		and s.backend.active == 0
		and (not p or (not p.running and not p.awaiting))
end
local function settle()
	assert(vim.wait(10000, settled, 1), "The latest requested viewport completes")
end
settle()
if s.renderer ~= "surface" then
	viewer.close()
	print("SKIP: surface integration needs Neovim 0.12+ and a unified-memory Metal device")
	vim.cmd("qa!")
	return
end
assert(s.layout.precise, "Surface geometry is fractional")
assert(s.frame.refined and s.backend.refiner, "Idle output is redrawn from PDF at the final viewport resolution")
assert(s.frame.refinement_scale == 2, "Ordinary viewports use the default 2x idle detail scale")
for index, entry in ipairs(s.surface_state.entries) do
	local request = s.surface_state.last_request
	assert(entry.image.width == request.parts[index].width * 2 and entry.image.height == request.height * 2)
	assert(entry.image.rows == s.height, "Higher pixel density preserves the terminal placement")
end
assert(s.backend.refiner.process.pid ~= s.backend.native.process.pid, "Refinement uses an independent document worker")
assert(
	s.backend.refiner.cache_bytes == 0
		and s.backend.refiner.gpu_cache_bytes == 0
		and s.backend.refiner.output_cache_bytes == 0,
	"Refinement retains no source pixels, textures or output mappings"
)
local ns = vim.api.nvim_get_namespaces().pdfpreview
local function grid()
	assert(vim.api.nvim_buf_line_count(s.buf) == s.height, "Surface backing text stays bounded by window height")
	local marks = vim.api.nvim_buf_get_extmarks(s.buf, ns, 0, -1, { details = true })
	assert(#marks == s.height, "Each surface row has one marker")
	for index, mark in ipairs(marks) do
		assert(mark[2] == index - 1, "Surface rows start at the top of the backing buffer")
		local width = 0
		for _, chunk in ipairs(mark[4].virt_text) do
			width = width + vim.fn.strdisplaywidth(chunk[1])
			assert(
				vim.fn.strchars(chunk[1]) == 3 * vim.fn.strdisplaywidth(chunk[1]),
				"Every surface cell has explicit coordinates"
			)
		end
		assert(width == s.width, "Surface placeholders exactly cover the current window width")
	end
	return marks
end
local initial_grid, initial_tick = grid(), vim.api.nvim_buf_get_changedtick(s.buf)
local idle_sequence, idle_requests, idle_uploads = s.surface_state.sequence, s.backend.native.serial, uploads
vim.wait(1200, function()
	return false
end, 20)
assert(
	s.surface_state.sequence == idle_sequence and s.backend.native.serial == idle_requests and uploads == idle_uploads,
	"An idle reader performs no extra composition, native request, or image transfer"
)
local watchdog = assert(s.surface_state.read_timer)
assert(not watchdog:is_active(), "An acknowledged idle surface has no active read timer")
local redraw = vim.cmd.redraw
local redraws = 0
vim.cmd.redraw = function(...)
	redraws = redraws + 1
	return redraw(...)
end
local image = s.surface_state.entries[1].image
local start = s.y
viewer.scroll(1)
local fractional = false
assert(
	vim.wait(10000, function()
		if s.frame and s.frame.y > start and s.frame.y < s.y then
			fractional = true
		end
		return settled()
	end, 1),
	"Scrolling settles"
)
assert(fractional and s.frame.y == start + 1, "Scroll interpolation advances pixels and reaches the exact target")
assert(redraws == 0, "Warm same-page pixel motion does not explicitly redraw an unchanged text grid")
viewer.zoom(145)
settle()
assert(redraws > 0, "Zoom flushes its changed window bar")
vim.cmd.redraw = redraw
assert(s.surface_state.entries[1].image == image, "Zoom retains the terminal image")
assert(
	s.surface_state.read_timer == watchdog and not watchdog:is_active(),
	"Warm motion reuses and disarms one watchdog"
)
assert(vim.deep_equal(grid(), initial_grid), "Warm scroll and zoom preserve every placeholder and marker ID")
assert(vim.api.nvim_buf_get_changedtick(s.buf) == initial_tick, "Warm motion does not rewrite backing text")
local function positioned()
	local view = vim.api.nvim_win_call(s.win, vim.fn.winsaveview)
	assert(view.lnum == 1 and view.col == 0 and view.coladd == 0, "The backing cursor remains at the origin")
	assert(
		view.topline == 1 and view.leftcol == 0 and view.skipcol == 0 and view.topfill == 0,
		"The entire placeholder grid remains visible"
	)
end
vim.api.nvim_win_set_cursor(s.win, { 3, 0 })
vim.cmd("normal! zt")
assert(vim.fn.winsaveview().topline > 1, "Exercise an externally scrolled backing viewport")
viewer.scroll(1)
settle()
positioned()
local virtualedit = vim.wo.virtualedit
vim.wo.virtualedit = "all"
vim.cmd("normal! 9l")
assert(vim.fn.winsaveview().coladd > 0, "Exercise an external virtual-column cursor offset")
viewer.scroll(1)
settle()
positioned()
vim.wo.virtualedit = virtualedit
local initial_width, initial_height = s.width, s.height
local resize_buf = vim.api.nvim_create_buf(false, true)
local right = vim.api.nvim_open_win(resize_buf, false, { split = "right", win = s.win, width = 20 })
local below = vim.api.nvim_open_win(resize_buf, false, { split = "below", win = s.win, height = 8 })
viewer._paint(s)
settle()
assert(s.width < initial_width and s.height < initial_height, "Exercise real horizontal and vertical window resizing")
grid()
vim.api.nvim_set_current_win(right)
local other_view = vim.fn.winsaveview()
vim.api.nvim_win_set_cursor(s.win, { 3, 0 })
s.y = s.y + 1
viewer._paint(s)
settle()
positioned()
assert(vim.api.nvim_get_current_win() == right, "Restoring a visible reader does not focus its window")
assert(vim.deep_equal(vim.fn.winsaveview(), other_view), "The focused text window keeps its own view")
vim.api.nvim_set_current_win(s.win)
vim.api.nvim_win_close(below, true)
vim.api.nvim_win_close(right, true)
vim.api.nvim_buf_delete(resize_buf, { force = true })
viewer._paint(s)
settle()
assert(s.width == initial_width and s.height == initial_height, "Closing splits restores the original geometry")
assert(
	s.surface_state.entries[1].image == image and image.cols == s.width,
	"Resize replaces pixels without dropping the image identifier"
)
grid()
-- A paused refinement worker must not block a new fast motion frame.
local refiner, motion_worker = s.backend.refiner, s.backend.native.process.pid
assert(vim.uv.kill(refiner.process.pid, "sigstop") == 0)
local animation = viewer.config.scroll_animation_ms
local resumed, resume_error = pcall(function()
	viewer.config.scroll_animation_ms = 0
	viewer.scroll(1)
	assert(
		vim.wait(2000, function()
			return s.surface_state.refine_job ~= nil
		end, 1),
		"The paused worker owns a refinement request"
	)
	viewer.scroll(1)
	assert(
		vim.wait(2000, function()
			local p, frame = s.surface_state, s.frame
			return frame and frame.y == s.y and not p.running and not p.awaiting
		end, 1),
		"Metal motion completes while the independent refinement worker remains stopped"
	)
	assert(
		s.backend.native.process.pid == motion_worker and refiner.closed,
		"Cancelling quality work preserves the motion worker"
	)
end)
vim.uv.kill(refiner.process.pid, "sigcont")
assert(resumed, resume_error)
settle()
assert(
	refiner.exited and s.backend.refiner ~= refiner and s.frame.refined,
	"A cancelled quality worker is replaced safely"
)
viewer.config.scroll_animation_ms = animation
assert(
	viewer.stats().terminal_image_bytes == image.width * image.height * 4,
	"Surface bytes are included in diagnostics"
)
viewer.scroll(1)
viewer._paint(s)
local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(scratch)
assert(viewer._states[s.buf] == s and not s.frame)
local after_hide = uploads
vim.api.nvim_set_current_buf(s.buf)
settle()
assert(uploads > after_hide and s.renderer == "surface", "Returning during composition restores without extra input")
assert(watchdog:is_closing() and s.surface_state.read_timer ~= watchdog, "Hide releases the old watchdog before return")
grid()
local names = vim.fn.glob(s.backend.dir .. "/surface-*.rgba", false, true)
assert(#names > 0 and #names <= 2, "At most two confirmed output slots remain")
for index = 1, 40 do
	viewer.zoom(100 + index % 8)
	settle()
	assert(#vim.fn.glob(s.backend.dir .. "/surface-*.rgba", false, true) <= 2)
	assert(s.backend.native.output_cache_bytes <= 64 * 1024 * 1024)
end
vim.api.nvim_set_current_buf(scratch)
assert(#vim.fn.glob(s.backend.dir .. "/surface-*.rgba", false, true) == 0, "Hide releases idle output slots")
vim.api.nvim_set_current_buf(s.buf)
settle()
local compose = s.backend.compose
s.backend.compose = function(_, _, callback)
	vim.schedule(function()
		callback({ code = 1, stderr = "Injected compositor failure" })
	end)
	return { kill = function() end }
end
viewer.scroll(1)
assert(
	vim.wait(10000, function()
		return s.renderer == "viewport" and settled()
	end, 1),
	"Composition failure falls back to the tile renderer"
)
s.backend.compose = compose
assert(vim.api.nvim_buf_line_count(s.buf) > s.height, "Tile fallback restores its document-coordinate backing buffer")
assert(
	vim.wait(1000, function()
		return select(1, require("pdfpreview.surface").stats(s)) == 0
	end, 1),
	"Fallback releases the previous surface after replacement"
)
viewer.close()
assert(
	vim.wait(10000, function()
		return not vim.uv.fs_stat(s.backend.dir)
	end, 1),
	"Close drains the worker and all files"
)
vim.api.nvim_buf_delete(scratch, { force = true })
viewer.setup({ renderer = "surface", rasterizer = "poppler", cell_width = 15, cell_height = 35 })
s = assert(viewer.open(vim.fn.getcwd() .. "/tests/sample.pdf"))
settle()
assert(s.renderer == "viewport" and s.surface_fallback, "Explicit surface requests fall back without Metal")
viewer.close()
assert(
	vim.wait(10000, function()
		return not vim.uv.fs_stat(s.backend.dir)
	end, 1),
	"Poppler fallback cleans up"
)
viewer.setup({ renderer = "auto", rasterizer = "auto", cell_width = 15, cell_height = 35 })
s = assert(viewer.open(vim.fn.getcwd() .. "/tests/sample.pdf"))
settle()
assert(s.renderer == "surface", "Automatic composition is selected again")
s.backend.native.process:kill(15)
viewer.scroll(1)
assert(
	vim.wait(10000, function()
		return s.renderer == "viewport" and s.backend.rasterizer == "poppler" and settled()
	end, 1),
	"Worker exit restores the reader through Poppler tiles"
)
viewer.close()
assert(
	vim.wait(10000, function()
		return not vim.uv.fs_stat(s.backend.dir)
	end, 1),
	"Crashed worker cleanup completes"
)
print(
	"PASS: actual Metal worker, bounded backing grid, stable markers, reusable read watchdog, idle suppression, fractional scrolling, same-ID zoom/resize, byte stats, hide/restore race, file reclamation, Poppler and worker-crash fallback, and cleanup"
)
vim.cmd("qa!")
