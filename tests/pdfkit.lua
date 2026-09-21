vim.opt.rtp:prepend(vim.fn.getcwd())
vim.o.termguicolors = true
vim.o.mouse = "a"
vim.o.lines, vim.o.columns = 40, 100
local api = vim.api
local text = require("pdfpreview.text")
local viewer = require("pdfpreview")
local native = require("pdfpreview.native")
assert(native.available(viewer.config), "PDFKit checks require the compiled macOS helper")
local notices = {}
vim.notify = function(value)
	notices[#notices + 1] = value
end
require("pdfpreview.graphics").sink = function(data)
	if data:find("a=T", 1, true) and data:find("q=0", 1, true) then
		local id = assert(tonumber(data:match("i=(%d+)")))
		vim.schedule(function()
			api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=" .. id .. ";OK" } })
		end)
	end
end
local function wait(predicate, label)
	assert(vim.wait(15000, predicate, 2), label)
end
local file = vim.fn.tempname() .. " space ; $ literal.pdf"
assert(vim.uv.fs_copyfile(vim.fn.getcwd() .. "/tests/sample.pdf", file))
local geometry = { { width = 400, height = 600 }, { width = 400, height = 600 } }
local opts = { text_backend = "pdfkit", pdftotext = "/missing/pdftotext" }
assert(text.available(opts) == "pdfkit", "Native characters do not depend on pdftotext")
local loader = text.new(file, opts.pdftotext, geometry, opts)
local pages, callbacks = {}, 0
for _, n in ipairs({ 1, 1, 2 }) do
	loader:get(n, function(page, err)
		pages[n], callbacks = assert(page, err), callbacks + 1
	end)
end
wait(function()
	return callbacks == 3
end, "Concurrent PDFKit requests finish through the serialized loader")
local first, last = { page = 1, index = 5 }, { page = 1, index = 7 }
assert(text.extract(pages, first, last) == "REV", "A range can copy only the middle of a word")
assert(text.extract(pages, text.range(last, first)) == "REV", "Reverse ranges retain reading order")
local expected = { "PDF PREVIEW - PAGE 1" }
for n = 1, 12 do
	expected[#expected + 1] = "Continuous scrolling test - line " .. n
end
assert(
	text.extract(pages, { page = 1, index = 1 }, { page = 1, index = #pages[1].characters })
		== table.concat(expected, "\n"),
	"Every line and space survives native extraction without shifted character indices"
)
assert(
	text.extract(pages, { page = 1, index = #pages[1].characters }, { page = 2, index = 2 }) == "2\n\nPD",
	"Cross-page ranges include only the selected endpoint characters"
)
assert(
	text.extract(pages, text.expand(pages[1], first, -1), text.expand(pages[1], last, 1)) == "PREVIEW",
	"Word expansion includes the full word and excludes adjacent spaces"
)
local cached
loader:get(1, function(page)
	cached = page
end)
assert(not loader.running, "Cached pages do not launch another helper")
wait(function()
	return cached ~= nil
end, "Cached delivery remains asynchronous")
assert(cached == pages[1])
loader:close()

for _, closing_in_callback in ipairs({ false, true }) do
	local closing = text.new(file, opts.pdftotext, geometry, opts)
	local delivered = false
	closing:get(1, function(page, err)
		assert(closing_in_callback, "Closing a running helper suppresses delivery")
		assert(page, err)
		closing:close()
		delivered = true
	end)
	closing:get(1, function()
		error("Closing cancels subsequent consumers too")
	end)
	if not closing_in_callback then
		closing:close()
	end
	wait(function()
		return not closing.process and (not closing_in_callback or delivered)
	end, "Closing cancels native text work")
end

local old_helper = vim.fn.tempname()
vim.fn.writefile(
	{ "#!/bin/sh", "cat >/dev/null", [[printf '%s\n' '{"id":1,"error":"Unsupported action"}']] },
	old_helper
)
assert(vim.uv.fs_chmod(old_helper, 448))
for _, mode in ipairs({ "auto", "pdfkit" }) do
	local source = text.new(file, "pdftotext", geometry, { text_backend = mode, native_renderer = old_helper })
	local done
	source:get(1, function(page, err)
		if mode == "auto" then
			assert(page and page.words[1].text == "PDF" and source.backend == "poppler", err)
			assert(source.fallback:find("Unsupported action", 1, true), "Fallback reason is inspectable")
		else
			assert(not page and err:find("Unsupported action", 1, true), "Explicit PDFKit reports helper errors")
		end
		done = true
	end)
	wait(function()
		return done
	end, "Old helpers fall back only in automatic mode")
	source:close()
end
vim.fn.delete(old_helper)
for _, output in ipairs({ "broken", '{"id":2}', '{"id":1,"text_page":{"characters":{}}}' }) do
	assert(not text.parse_native(output), "Malformed native text is rejected")
end
local bad = vim.deepcopy(pages[1])
bad.characters[1].x1 = -1
assert(not text.parse_native(vim.json.encode({ id = 1, text_page = bad })))

viewer.setup({
	renderer = "surface",
	rasterizer = "native",
	text_backend = "pdfkit",
	pdftotext = "/missing/pdftotext",
	cell_width = 10,
	cell_height = 20,
	scroll_animation_ms = 0,
	surface_refine_ms = 30,
})
local s = assert(viewer.open(file))
local function settle()
	wait(function()
		local f, p = s.frame, s.surface_state
		return f
			and not f.refining
			and f.zoom == s.zoom
			and f.x == s.x
			and f.y == s.y
			and (s.renderer ~= "surface" or f.selection_version == s.selection.version)
			and not s.pending
			and not s.zoom_target
			and (not p or (not p.running and not p.awaiting))
	end, "Character selection display settles")
	vim.cmd.redraw()
end
local function mouse(index)
	local page, char = s.frame.layout.pages[1], pages[1].characters[index]
	local origin = vim.fn.screenpos(s.win, vim.fn.line("w0", s.win), 1)
	local x = text.left(s.frame, page) + (char.x1 + char.x2) * page.width / 2
	local y = page.top - s.frame.y + (char.y1 + char.y2) * page.height / 2
	return { winid = s.win, screencol = origin.col + math.floor(x), screenrow = origin.row + math.floor(y) }
end
settle()
local compositions = s.surface_state and s.surface_state.sequence
s.selection:mouse("press", mouse(5))
s.selection:mouse("drag", mouse(7))
s.selection:mouse("release", mouse(7))
viewer.copy("a")
wait(function()
	return vim.fn.getreg("a") == "REV"
end, "A real mouse drag and pending yank copy part of a word")
settle()
assert(viewer.stats().text_backend == "pdfkit")
assert(s.selection.first.index == 5 and s.selection.last.index == 7)
if s.renderer == "surface" then
	assert(s.frame.refined and s.frame.refinement_scale == 2, "Character dragging retains full-resolution refinement")
	assert(s.surface_state.sequence == compositions and s.surface_state.displayed_request.reuse)
	local rects =
		require("pdfpreview.selection").rectangles(s.frame, s.selection.pages, s.selection.first, s.selection.last)
	local page = s.frame.layout.pages[1]
	assert(
		#rects == 1 and math.abs(rects[1].x1 - text.left(s.frame, page) - pages[1].characters[5].x1 * page.width) < 1e-8
	)
	assert(math.abs(rects[1].x2 - text.left(s.frame, page) - pages[1].characters[7].x2 * page.width) < 1e-8)
end
s.selection:mouse("press", mouse(6), "word")
s.selection:mouse("release", mouse(6))
wait(function()
	return s.selection.first and s.selection:value() == "PREVIEW"
end, "Double-click mode selects the whole word")
s.selection:clear()
s.context:open(mouse(6))
wait(function()
	return s.selection.first and s.selection:value() == "PREVIEW"
end, "Right-click without a selection selects a whole word for translation")
s.context:close()
viewer.close()
vim.fn.delete(file)

-- Real Neovim mouse input must reach the character selection and double-click
-- mappings, independently of which rasterizer draws the PDF.
local channel = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "-u", "NONE", "-i", "NONE" }, { rpc = true })
assert(channel > 0)
local function request(method, ...)
	return vim.rpcrequest(channel, method, ...)
end
local ok, err = pcall(function()
	local positions = request(
		"nvim_exec_lua",
		[[
		local root = ...
		vim.opt.rtp:prepend(root)
		vim.o.mouse = 'a'
		vim.o.termguicolors = true
		vim.o.lines, vim.o.columns = 40, 100
		require('pdfpreview.graphics').sink = function() end
		viewer = require('pdfpreview')
		viewer.setup({renderer='viewport', rasterizer='poppler', text_backend='pdfkit', cell_width=10, cell_height=20})
		s = assert(viewer.open(root .. '/tests/sample.pdf'))
		assert(vim.wait(15000, function() return s.frame and not s.pending end, 2))
		s.selection:load(1)
		assert(vim.wait(15000, function() return s.selection.pages[1] ~= nil end, 2))
		vim.cmd.redraw()
		local origin = vim.fn.screenpos(s.win, vim.fn.line('w0', s.win), 1)
		local page, positions = s.frame.layout.pages[1], {}
		for _, i in ipairs({5, 7}) do
			local c = s.selection.pages[1].characters[i]
			positions[#positions+1] = {
				origin.row - 1 + math.floor(page.top - s.frame.y + (c.y1+c.y2)*page.height/2),
				origin.col - 1 + math.floor(require('pdfpreview.text').left(s.frame, page) + (c.x1+c.x2)*page.width/2),
			}
		end
		return positions
	]],
		{ vim.fn.getcwd() }
	)
	request("nvim_input_mouse", "left", "press", "", 0, positions[1][1], positions[1][2])
	wait(function()
		return request("nvim_exec_lua", "return s.selection.first and s.selection.first.index == 5", {})
	end, "Mapped press chooses one letter")
	request("nvim_input_mouse", "left", "drag", "", 0, positions[2][1], positions[2][2])
	wait(function()
		return request("nvim_exec_lua", "return s.selection.last and s.selection.last.index == 7", {})
	end, "Mapped drag extends by characters")
	request("nvim_input_mouse", "left", "release", "", 0, positions[2][1], positions[2][2])
	wait(function()
		return request("nvim_exec_lua", "return not s.selection.dragging", {})
	end, "Mapped release finishes character selection")
	request("nvim_input", '"by')
	wait(function()
		return request("nvim_exec_lua", "return vim.fn.getreg('b')", {}) == "REV"
	end, "The actual yank mapping copies a partial word")
	request("nvim_input", "<2-LeftMouse>")
	wait(function()
		return request("nvim_exec_lua", "return s.selection:value()", {}) == "PREVIEW"
	end, "The actual double-click mapping selects the whole word")
	request("nvim_input", "<2-LeftRelease>")
	request("nvim_exec_lua", "viewer.close()", {})
end)
vim.fn.jobstop(channel)
assert(ok, err)
print(
	"PASS: PDFKit partial-word selection, exact multiline copy, cross-page ranges, word expansion, sharp feedback, fallback and cancellation"
)
vim.cmd("qa!")
