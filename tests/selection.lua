vim.opt.rtp:prepend(vim.fn.getcwd())
vim.o.termguicolors = true
vim.o.mouse = "a"
vim.o.lines, vim.o.columns = 40, 100
local api = vim.api
local text = require("pdfpreview.text")
local selection = require("pdfpreview.selection")
local graphics = require("pdfpreview.graphics")
local viewer = require("pdfpreview")
local packets, notices = {}, {}
vim.notify = function(value)
	notices[#notices + 1] = value
end
graphics.sink = function(data)
	packets[#packets + 1] = data
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
local function xml(words)
	return '<page width="400" height="600"><flow><block><line xMin="0">' .. words .. "</line></block></flow></page>"
end
local function word(value, x1, y1, x2, y2)
	return ('<word xMin="%s" yMin="%s" xMax="%s" yMax="%s">%s</word>'):format(x1, y1, x2, y2, value)
end

local parsed = assert(text.parse(xml(word("A&amp;B &lt;tag&gt; &#x4e2d;&#25991; &amp;lt;", 10, 20, 200, 40))))
assert(parsed.words[1].text == "A&B <tag> 中文 &lt;", "XML decoding is Unicode-safe and occurs only once")
assert(not text.parse("broken"), "Invalid extraction output is rejected")
assert(not text.parse(xml(word("broken", "nan", 1, 2, 3))), "Invalid bounds are rejected")
assert(#assert(text.parse('<page width="400" height="600"></page>')).words == 0, "Scans have an empty text layer")
local chinese = assert(text.parse(xml(word("中", 10, 20, 30, 40) .. word("文", 30, 20, 50, 40))))
assert(
	text.extract({ chinese }, { page = 1, index = 1 }, { page = 1, index = 2 }) == "中文",
	"CJK words do not acquire spaces"
)
local rotated = assert(text.parse(xml(word("rotated", 410, 40, 435, 150)), { width = 600, height = 400 }))
assert(#rotated.words == 1 and rotated.words[1].x2 == 435 / 600, "Rotated text uses displayed dimensions")
local a, b = text.range({ page = 2, index = 1 }, { page = 1, index = 3 })
assert(a.page == 1 and a.index == 3 and b.page == 2, "Reverse drags retain document reading order")

local layout = require("pdfpreview.layout")
for _, precise in ipairs({ false, true }) do
	for _, zoom in ipairs({ 0.5, 1.375, 4 }) do
		local document = layout.build(
			{ { width = 400, height = 600 }, { width = 600, height = 400 } },
			101,
			10.5,
			21,
			zoom,
			2,
			precise
		)
		local frame = { layout = document, x = zoom > 1 and 20.25 or 0, y = 2.25, width = 101, height = 40 }
		local page = document.pages[1]
		local fx, fy = zoom == 4 and 0.12 or 0.45, zoom == 4 and 0.08 or 0.2
		local x, y = text.left(frame, page) + page.width * fx, page.top - frame.y + page.height * fy
		local point = assert(text.point(frame, x, y))
		assert(
			math.abs(point.x - fx) < 1e-12 and math.abs(point.y - fy) < 1e-12,
			"Hit testing accounts for pan, centering and fractional scroll"
		)
		local rects = selection.rectangles(frame, { parsed }, { page = 1, index = 1 }, { page = 1, index = 1 })
		for _, rect in ipairs(rects) do
			assert(
				rect.x1 >= 0 and rect.y1 >= 0 and rect.x2 <= frame.width and rect.y2 <= frame.height,
				"Selection is clipped to the PDF viewport"
			)
		end
	end
end

local file = vim.fn.tempname() .. " space ; $ literal.pdf"
assert(vim.uv.fs_copyfile(vim.fn.getcwd() .. "/tests/sample.pdf", file))
local loader = text.new(file, "pdftotext", { { width = 400, height = 600 } })
local loaded, callbacks = nil, 0
for _ = 1, 2 do
	loader:get(1, function(page, err)
		loaded, callbacks = assert(page, err), callbacks + 1
	end)
end
wait(function()
	return callbacks == 2
end, "Concurrent consumers share real pdftotext extraction")
assert(
	loaded.words[1].text == "PDF" and loaded.words[2].text == "PREVIEW",
	"Extract original text with shell-special paths"
)
loader:close()
local closing = text.new(file, "pdftotext", { { width = 400, height = 600 } })
local closed_from_callback = false
closing:get(1, function(page, err)
	assert(page, err)
	closing:close()
	closed_from_callback = true
end)
closing:get(1, function()
	error("Closing during delivery must cancel later consumers")
end)
wait(function()
	return closed_from_callback
end, "Closing during result delivery suppresses remaining callbacks")
local failed = text.new(file, "/nonexistent/pdfpreview-pdftotext", {})
local failure
failed:get(1, function(page, err)
	assert(not page)
	failure = err
end)
wait(function()
	return failure ~= nil
end, "Unavailable extractors report a recoverable error")
failed:close()
local cancelled = text.new(file, "pdftotext", { { width = 400, height = 600 } })
cancelled:get(1, function()
	error("Closed extraction called its consumer")
end)
cancelled:close()
wait(function()
	return cancelled.process == nil
end, "Close terminates extraction and ignores stale results")

-- A test clipboard prevents these checks touching the user's real clipboard.
local clipboard
vim.g.clipboard = {
	name = "pdfpreview-test",
	cache_enabled = 0,
	copy = {
		["+"] = function(lines)
			clipboard = table.concat(lines, "\n")
		end,
		["*"] = function(lines)
			clipboard = table.concat(lines, "\n")
		end,
	},
	paste = {
		["+"] = function()
			return { { clipboard or "" }, "v" }
		end,
		["*"] = function()
			return { { clipboard or "" }, "v" }
		end,
	},
}
local renderers = { "unicode", "viewport" }
if require("pdfpreview.native").available(viewer.config) then
	renderers[#renderers + 1] = "surface"
end
for _, renderer in ipairs(renderers) do
	viewer.setup({
		renderer = renderer,
		rasterizer = renderer == "surface" and "native" or "poppler",
		text_backend = "poppler",
		cell_width = 10,
		cell_height = 20,
		scroll_animation_ms = 0,
		surface_refine_ms = renderer == "surface" and 30 or 0,
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
		end, "Selection reader settles: " .. renderer)
		vim.cmd.redraw()
	end
	local function feedback()
		if s.renderer == "surface" then
			local request = s.surface_state.displayed_request
			return s.frame.selection_version == s.selection.version
				and request
				and request.selections
				and #request.selections > 0
		end
		return #s.selection.overlays > 0
	end
	settle()
	local initial_compositions = s.surface_state and s.surface_state.sequence
	local function mouse(kind, n, index)
		local page = assert(s.frame.layout.pages[n])
		local words = s.selection.pages[n] or loaded
		local w = assert(words.words[index])
		local origin = vim.fn.screenpos(s.win, vim.fn.line("w0", s.win), 1)
		local x = text.left(s.frame, page) + (w.x1 + w.x2) * page.width / 2
		local y = page.top - s.frame.y + (w.y1 + w.y2) * page.height / 2
		assert(x >= 0 and x < s.frame.width and y >= 0 and y < s.frame.height, "Test mouse targets visible PDF text")
		s.selection:mouse(
			kind,
			{ winid = s.win, screencol = origin.col + math.floor(x), screenrow = origin.row + math.floor(y) }
		)
	end
	mouse("press", 1, 1)
	mouse("drag", 1, 2)
	mouse("release", 1, 2)
	viewer.copy("a") -- deliberately before the asynchronous layer is ready
	wait(function()
		return vim.fn.getreg("a") == "PDF PREVIEW"
	end, "Pending drag and copy resolve after extraction")
	settle()
	wait(feedback, "A visible selection gets highlighted")
	assert(not s.selection.dragging, "Releasing the button stops dragging")
	assert(
		vim.fn.getreg('"') == "PDF PREVIEW" and vim.fn.getreg("0") == "PDF PREVIEW",
		"Yank preserves actual PDF text"
	)
	assert(
		viewer.copy("+") == "PDF PREVIEW" and clipboard == "PDF PREVIEW",
		"Explicit copy uses the system clipboard provider"
	)
	local unnamed = vim.fn.getreg('"')
	assert(viewer.copy("_") == "PDF PREVIEW" and vim.fn.getreg('"') == unnamed, "Black-hole yanks preserve registers")
	local overlay = s.selection.overlays[1]
	local sent = #packets
	s.selection:redraw()
	assert(
		#packets == sent and s.selection.overlays[1] == overlay,
		"Movement within a selected word does not retransmit highlights"
	)
	if s.renderer == "surface" then
		assert(s.frame.refined and s.frame.refinement_scale == 2, "Select on main's 2x refined surface")
		assert(
			s.surface_state.sequence == initial_compositions and s.surface_state.displayed_request.reuse,
			"Real native selection updates reuse sharp pixels without any lower-resolution composition"
		)
		local page = s.frame.layout.pages[1]
		local left = text.left(s.frame, page)
		local first, last = loaded.words[1], loaded.words[2]
		local displayed = s.surface_state.displayed_request
		local part = displayed.parts[#displayed.parts]
		local density = (part.offset + part.width) / s.frame.width
		local expected = math.ceil((left + last.x2 * page.width) * density)
			- math.floor((left + first.x1 * page.width) * density)
		local rect = displayed.selections[1]
		assert(math.ceil(rect.x2) - math.floor(rect.x1) == expected, "Selection uses displayed viewport pixels")
		assert(not overlay, "Surface feedback needs no cursor-positioned images")
	end
	local above, positioned = false, false
	for _, packet in ipairs(packets) do
		if overlay and packet:find("a=p", 1, true) and packet:find("i=" .. overlay.id .. ",", 1, true) then
			above = packet:find("z=1", 1, true) and not packet:find("P=", 1, true)
			positioned = packet:match("^\27" .. "7\27%[%d+;%d+H\27_G") and packet:sub(-2) == "\27" .. "8"
		end
	end
	assert(not overlay or above, "Highlights appear above the PDF without requiring relative placements")
	assert(not overlay or positioned, "Cursor positioning and placement cannot be split by a TUI redraw")
	local float = api.nvim_open_win(
		api.nvim_create_buf(false, true),
		false,
		{ relative = "editor", row = 3, col = 3, width = 20, height = 3, style = "minimal" }
	)
	wait(function()
		return #s.selection.overlays == 0
	end, "Floats hide positive-z selection graphics")
	assert(viewer.copy("a") == "PDF PREVIEW", "A popup preserves the logical selection")
	api.nvim_win_close(float, true)
	wait(feedback, "Closing a popup restores feedback")

	-- Snacks Explorer uses floats inside a separate sidebar split. They must
	-- not suppress feedback in an unobstructed PDF window beside it.
	vim.cmd("topleft 20vnew")
	local sidebar = api.nvim_get_current_win()
	api.nvim_set_current_win(s.win)
	settle()
	local sidebar_float = api.nvim_open_win(api.nvim_create_buf(false, true), false, {
		relative = "win",
		win = sidebar,
		row = 0,
		col = 0,
		width = 18,
		height = 4,
		border = "rounded",
		style = "minimal",
	})
	s.selection:redraw()
	assert(feedback(), "Sidebar floats do not hide PDF selections")
	local origin = vim.fn.screenpos(s.win, vim.fn.line("w0", s.win), 1)
	api.nvim_win_set_config(sidebar_float, {
		relative = "editor",
		row = origin.row,
		col = origin.col - 3,
		width = 1,
		height = 4,
	})
	s.selection:redraw()
	assert(#s.selection.overlays == 0, "A popup border overlapping the PDF also hides feedback")
	api.nvim_win_close(sidebar_float, true)
	api.nvim_win_close(sidebar, true)
	viewer.goto_page(1)
	settle()
	wait(feedback, "Closing the sidebar restores the original selection geometry")

	-- Main can change terminal pixel dimensions without changing its cell grid.
	local old_overlays = s.selection.overlays
	viewer.config.cell_width, viewer.config.cell_height = 12.5, 23.5
	api.nvim_exec_autocmds("FocusGained", {})
	for _, image in ipairs(old_overlays) do
		assert(image.deleted, "Font changes immediately retire highlights with outdated pixel dimensions")
	end
	settle()
	assert(s.frame.cw == 12.5 and s.frame.ch == 23.5, "Displayed selection geometry follows terminal metrics")
	assert(viewer.copy("a") == "PDF PREVIEW", "Font changes preserve selected text")
	mouse("press", 1, 1)
	mouse("drag", 1, 2)
	mouse("release", 1, 2)
	viewer.copy("a")
	wait(function()
		return s.selection.first ~= nil and not s.selection.text_pending
	end, "Mouse coordinates resolve after a font change")
	assert(vim.fn.getreg("a") == "PDF PREVIEW")
	viewer.config.cell_width, viewer.config.cell_height = 10, 20
	api.nvim_exec_autocmds("FocusGained", {})
	settle()

	viewer.zoom(150)
	settle()
	assert(viewer.copy("a") == "PDF PREVIEW", "Zoom retains selection in PDF coordinates")
	viewer.scroll(2, 3)
	settle()
	assert(viewer.copy("a") == "PDF PREVIEW", "Scroll and pan retain the selected text")

	-- Drag backward across lines, then forward onto another page after scrolling.
	viewer.zoom(100)
	viewer.goto_page(1)
	settle()
	mouse("press", 1, 8)
	mouse("drag", 1, 1)
	mouse("release", 1, 1)
	wait(function()
		return s.selection.first ~= nil
	end, "Reverse selection resolves")
	assert(
		viewer.copy("a") == "PDF PREVIEW - PAGE 1\nContinuous scrolling test",
		"Reverse multiline selection follows reading order"
	)
	mouse("press", 1, 1)
	viewer.goto_page(2)
	settle()
	mouse("drag", 2, 2)
	mouse("release", 2, 2)
	viewer.copy("a")
	wait(function()
		return vim.fn.getreg("a"):find("line 12\n\nPDF PREVIEW", 1, true)
	end, "Cross-page copy waits for an unloaded endpoint")
	local value = vim.fn.getreg("a")
	assert(value:find("line 12\n\nPDF PREVIEW", 1, true), "Cross-page copy retains all intermediate text")

	local old = s.selection.overlays
	local scratch = api.nvim_create_buf(false, true)
	api.nvim_set_current_buf(scratch)
	for _, image in ipairs(old) do
		assert(image.deleted, "Leaving removes highlights")
	end
	assert(#s.selection.overlays == 0, "Hidden readers have no overlays")
	api.nvim_set_current_buf(s.buf)
	settle()
	api.nvim_buf_delete(scratch, { force = true })
	assert(viewer.copy("a") == value, "Returning retains the logical selection")
	viewer.clear_selection()
	assert(not s.selection.first and #s.selection.overlays == 0, "Escape removes selection and images")
	if s.renderer == "surface" then
		settle()
		assert(not s.surface_state.displayed_request.selections, "Clearing a selection restores untinted pixels")
	end
	local before = vim.fn.getreg('"')
	viewer.copy("a")
	assert(vim.fn.getreg('"') == before, "Empty selection cannot overwrite a register")
	viewer.goto_page(1)
	settle()
	vim.fn.setreg("c", "unchanged")
	mouse("press", 1, 1)
	viewer.copy("c")
	viewer.clear_selection()
	local drained = false
	vim.schedule(function()
		drained = true
	end)
	wait(function()
		return drained
	end, "Drain cached extraction callbacks after clearing")
	assert(
		not s.selection.first and vim.fn.getreg("c") == "unchanged",
		"Clearing cancels a pending copy and ignores stale extraction"
	)
	local extractor = viewer.config.pdftotext
	viewer.config.pdftotext = "/nonexistent/pdfpreview-pdftotext"
	mouse("press", 1, 1)
	assert(
		not s.selection.start and s.frame and notices[#notices]:find("Missing pdftotext", 1, true),
		"A missing text extractor leaves the PDF reader usable"
	)
	viewer.config.pdftotext = extractor
	viewer.close()
	wait(function()
		return not vim.uv.fs_stat(s.backend.dir)
	end, "Selection readers clean up all render work")
	assert(s.selection.source.closed, "Reader disposal closes the text worker")
end
vim.fn.delete(file)

-- A child event loop processes genuine Neovim mouse input and buffer mappings.
local channel = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "-u", "NONE", "-i", "NONE" }, { rpc = true })
assert(channel > 0)
local function request(method, ...)
	return vim.rpcrequest(channel, method, ...)
end
local ok, err = pcall(function()
	request(
		"nvim_exec_lua",
		[[
		vim.opt.rtp:prepend(...)
		vim.o.mouse = 'a'
		vim.o.termguicolors = true
		vim.o.lines, vim.o.columns = 40, 100
		require('pdfpreview.graphics').sink = function() end
		viewer = require('pdfpreview')
	]],
		{ vim.fn.getcwd() }
	)
	for _, renderer in ipairs({ "unicode", "viewport" }) do
		local positions = request(
			"nvim_exec_lua",
			[[
			local root, renderer = ...
			viewer.setup({renderer=renderer, rasterizer='poppler', text_backend='poppler', cell_width=10, cell_height=20})
			s = assert(viewer.open(root .. '/tests/sample.pdf'))
			assert(vim.wait(15000, function() return s.frame and not s.pending end, 2))
			s.selection:load(1)
			assert(vim.wait(15000, function() return s.selection.pages[1] ~= nil end, 2))
			vim.cmd.redraw()
			local origin = vim.fn.screenpos(s.win, vim.fn.line('w0', s.win), 1)
			local page, positions = s.frame.layout.pages[1], {}
			for i=1,2 do
				local w = s.selection.pages[1].words[i]
				positions[i] = {
					origin.row - 1 + math.floor(page.top - s.frame.y + (w.y1 + w.y2) * page.height / 2),
					origin.col - 1 + math.floor(require('pdfpreview.text').left(s.frame, page) + (w.x1 + w.x2) * page.width / 2),
				}
			end
			return positions
		]],
			{ vim.fn.getcwd(), renderer }
		)
		request("nvim_input_mouse", "left", "press", "", 0, positions[1][1], positions[1][2])
		wait(function()
			return request("nvim_exec_lua", "return s.selection.start ~= nil", {})
		end, "Mouse press is processed before the next input position")
		request("nvim_input_mouse", "left", "drag", "", 0, positions[2][1], positions[2][2])
		wait(function()
			return request("nvim_exec_lua", "return s.selection.first and s.selection.last.index == 2", {})
		end, "Mouse drag extends the selection")
		request("nvim_input_mouse", "left", "release", "", 0, positions[2][1], positions[2][2])
		wait(function()
			return request("nvim_exec_lua", "return not s.selection.dragging", {})
		end, "Mouse release is processed")
		request("nvim_input", '"by')
		wait(function()
			return request("nvim_exec_lua", "return vim.fn.getreg('b')", {}) == "PDF PREVIEW"
		end, "Mouse mappings and a named yank register: " .. renderer)
		assert(
			request("nvim_exec_lua", "return vim.fn.mode() == 'n' and not s.selection.dragging", {}),
			"PDF dragging stays in normal mode and receives button release"
		)

		-- Exercise the context menu with real input, including popup-mode mouse.
		request(
			"nvim_exec_lua",
			[[
			vim.o.mousemodel = 'popup_setpos'
			translation_calls, translation_cancelled = 0, 0
			require('pdfpreview.translate').request = function(value, config, callback)
				assert(value == 'PDF PREVIEW')
				translation_calls = translation_calls + 1
				translation_callback = callback
				return {kill=function() translation_cancelled = translation_cancelled + 1 end}
			end
		]],
			{}
		)
		local function right_menu()
			request("nvim_input_mouse", "right", "press", "", 0, positions[2][1], positions[2][2])
			wait(function()
				return request("nvim_exec_lua", "return s.context.popup ~= nil", {})
			end, "Right click opens the PDF menu")
			request("nvim_input_mouse", "right", "release", "", 0, positions[2][1], positions[2][2])
			assert(
				request("nvim_exec_lua", "return s.selection:value() == 'PDF PREVIEW'", {}),
				"Right click preserves selected text"
			)
		end
		right_menu()
		assert(
			request("nvim_exec_lua", "return translation_calls == 0", {}),
			"Opening a menu never sends text to a service"
		)
		request("nvim_input_mouse", "left", "press", "", 0, 0, 0)
		wait(function()
			return request("nvim_exec_lua", "return s.context.popup == nil", {})
		end, "Clicking outside dismisses the menu")
		request("nvim_input_mouse", "left", "release", "", 0, 0, 0)
		for _, key in ipairs({ "q", "<Esc>" }) do
			right_menu()
			request("nvim_input", key)
			wait(function()
				return request("nvim_exec_lua", "return s.context.popup == nil", {})
			end, "Popup close key " .. key)
			assert(
				request("nvim_exec_lua", "return not s.closed and s.selection:value() == 'PDF PREVIEW'", {}),
				"Popup keys preserve reader and selection"
			)
		end
		right_menu()
		local menu = request("nvim_exec_lua", "return vim.api.nvim_win_get_position(s.context.popup.win)", {})
		request("nvim_input_mouse", "left", "press", "", 0, menu[1] + 2, menu[2] + 2)
		wait(function()
			return request("nvim_exec_lua", "return translation_calls == 1", {})
		end, "Clicking Translate starts one request")
		request(
			"nvim_exec_lua",
			"translation_callback('中文译文'); assert(vim.api.nvim_buf_get_lines(s.context.popup.buf,0,1,false)[1] == '中文译文')",
			{}
		)
		request("nvim_input_mouse", "left", "press", "", 0, 0, 0)
		wait(function()
			return request("nvim_exec_lua", "return s.context.popup == nil", {})
		end, "Translation float dismisses on outside click")
		right_menu()
		request("nvim_input", "j<CR>")
		wait(function()
			return request("nvim_exec_lua", "return translation_calls == 2", {})
		end, "Keyboard menu selection translates")
		request("nvim_input", "q")
		wait(function()
			return request("nvim_exec_lua", "return s.context.popup == nil and translation_cancelled == 1", {})
		end, "Closing a pending translation cancels it")
		request("nvim_exec_lua", "translation_callback('obsolete'); assert(not s.context.popup)", {})
		request(
			"nvim_exec_lua",
			[[
			local value = s.selection.value
			local extracted
			s.selection.value = function(_, callback) extracted = callback end
			s.context:translate()
			s.context:close()
			s.selection.value = value
			extracted('PDF PREVIEW')
			assert(not s.context.popup and translation_calls == 2,
				'Closing while text loads must not reopen a float or contact the service')
		]],
			{}
		)

		request("nvim_input", "<Esc>")
		wait(function()
			return request("nvim_exec_lua", "return s.selection.start == nil", {})
		end, "Escape mapping clears the selection")
		request("nvim_exec_lua", "viewer.close(); vim.fn.setreg('b', '')", {})
	end
end)
vim.fn.jobstop(channel)
assert(ok, err)
print(
	"PASS: PDF text parsing, Unicode, extraction, mouse/yank mappings, clipboard, font changes, refined surfaces, overlay reuse and cleanup"
)
