-- Real Poppler integration for both portable display paths.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.o.termguicolors = true
local viewer = require("pdfpreview")
local graphics = require("pdfpreview.graphics")
local api = vim.api
local packets = {}
graphics.sink = function(data)
	packets[#packets + 1] = data
end
local file = vim.fn.getcwd() .. "/tests/sample.pdf"
local function wait(predicate, label)
	assert(vim.wait(15000, predicate, 2), label)
end

for _, renderer in ipairs({ "unicode", "viewport" }) do
	viewer.setup({
		auto_open = true,
		renderer = renderer,
		rasterizer = "poppler",
		cell_width = 10,
		cell_height = 20,
		image_cache_bytes = 64 * 1024 * 1024,
	})
	local initial_number, initial_bar = vim.wo.number, vim.wo.winbar
	vim.cmd.edit(file)
	local s = assert(viewer._states[api.nvim_get_current_buf()])
	local function settle()
		wait(function()
			local f = s.frame
			return f
				and not f.refining
				and f.zoom == s.zoom
				and f.x == s.x
				and f.y == s.y
				and not s.pending
				and not s.zoom_target
				and s.backend.active == 0
		end, "The latest visible frame settles")
	end
	settle()
	assert(#s.pages == 3 and s.pages[2].width == 500, "Mixed PDF page sizes survive metadata parsing")
	assert(vim.b[s.buf].snacks_scroll == false, "The PDF reader owns its scrolling")
	viewer.zoom(137.5)
	settle()
	assert(s.frame.zoom == 1.375, "Decimal zoom reaches its exact target")
	viewer.goto_page(2)
	s.y = s.layout.pages[2].top - 3
	viewer._paint(s)
	settle()
	local visible = {}
	for key in pairs(s.frame.keys) do
		local entry = assert(s.backend.entries[key])
		assert(entry.image and not entry.image.deleted, "A complete frame owns every visible image")
		visible[entry.page] = true
	end
	assert(visible[1] and visible[2], "Both sides of a page boundary are rendered")

	local text = api.nvim_create_buf(false, true)
	local split = api.nvim_open_win(text, false, { split = "left", win = s.win, width = 20 })
	viewer._paint(s)
	settle()
	assert(s.width == api.nvim_win_get_width(s.win), "PDF layout follows split resizing")
	api.nvim_win_close(split, true)
	api.nvim_buf_delete(text, { force = true })
	viewer.zoom(800)
	viewer.scroll(100000, 100000)
	settle()
	assert(s.x <= math.max(0, s.layout.width - s.width), "Horizontal panning stays within the document")
	assert(s.y <= math.max(0, s.layout.height - s.height), "Vertical scrolling stays within the document")
	for _, percent in ipairs({ 120, 450, 70, 210, 100 }) do
		viewer.zoom(percent)
		assert(s.backend.active <= viewer.config.jobs, "Obsolete work retains its bounded process slots")
	end
	settle()
	assert(s.frame.zoom == 1, "Rapid input finishes at the newest target")

	local scratch = api.nvim_create_buf(false, true)
	api.nvim_set_current_buf(scratch)
	assert(vim.wo.number == initial_number and vim.wo.winbar == initial_bar, "Leaving restores text-window options")
	for _, entry in pairs(s.backend.entries) do
		assert(not entry.image, "Hidden PDF buffers release terminal images")
	end
	api.nvim_set_current_buf(s.buf)
	settle()
	api.nvim_buf_delete(scratch, { force = true })
	viewer.close()
	wait(function()
		return not vim.uv.fs_stat(s.backend.dir)
	end, "Closing drains workers and removes raster files")
	assert(not viewer._states[s.buf], "Closed readers release their state")
end

local closing = assert(viewer.open(file))
viewer.close()
wait(function()
	return not vim.uv.fs_stat(closing.backend.dir)
end, "Closing during metadata cannot restart work")
for _, packet in ipairs(packets) do
	if packet:find("a=p", 1, true) then
		assert(packet:find("U=1", 1, true) and packet:find("C=1", 1, true), "Placements remain text-bound")
	end
end
print("PASS: portable readers, page boundaries, zoom, split resizing, cancellation and cleanup")
