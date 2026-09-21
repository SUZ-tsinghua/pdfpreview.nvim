local M = {}
local api = vim.api
local layout = require("pdfpreview.layout")
local graphics = require("pdfpreview.graphics")
local terminal = require("pdfpreview.terminal")
local backend = require("pdfpreview.backend")
local tiles = require("pdfpreview.tiles")
local surface = require("pdfpreview.surface")
local selection = require("pdfpreview.selection")
local context = require("pdfpreview.context")
local ns = api.nvim_create_namespace("pdfpreview")
local states = {}
M.defaults = {
	auto_open = false,
	renderer = "auto",
	rasterizer = "auto", -- Persistent Quartz worker when built on macOS; Poppler otherwise.
	native_renderer = nil,
	compact_placeholders = false,
	prefetch_zoom = true,
	progressive_zoom = true,
	pdfinfo = "pdfinfo",
	pdftoppm = "pdftoppm",
	pdftotext = "pdftotext",
	text_backend = "auto", -- PDFKit characters on macOS; Poppler words otherwise.
	translation = { provider = "google", source = "en", target = "zh-CN", timeout = 10, fallback = true },
	scroll_step = 1,
	scroll_animation_ms = 40,
	surface_refine_ms = 100,
	surface_refine_scale = 2,
	zoom_step = 1.15,
	min_zoom = 0.1,
	max_zoom = 8,
	page_gap = 2,
	cache_pages = 8,
	image_cache_bytes = 16 * 1024 * 1024,
	jobs = 2,
	max_dimension = 4096,
	cell_width = nil,
	cell_height = nil,
}
M.config = vim.deepcopy(M.defaults)
local window_options = {
	number = false,
	relativenumber = false,
	signcolumn = "no",
	foldcolumn = "0",
	wrap = false,
	spell = false,
	list = false,
	cursorline = false,
	cursorcolumn = false,
	colorcolumn = "",
	scrolloff = 0,
	sidescrolloff = 0,
	statuscolumn = "",
	conceallevel = 0,
	winhighlight = "Normal:PdfPreviewBackground,EndOfBuffer:PdfPreviewBackground",
	fillchars = "eob: ",
	winbar = "",
}

local function message(text)
	vim.notify("pdfpreview: " .. text, vim.log.levels.ERROR)
end
local function active(s)
	return not s.closed
		and api.nvim_buf_is_valid(s.buf)
		and s.win
		and api.nvim_win_is_valid(s.win)
		and api.nvim_win_get_buf(s.win) == s.buf
		and api.nvim_win_get_tabpage(s.win) == api.nvim_get_current_tabpage()
end

local function prepare(s, entry)
	if entry.status ~= "ready" or entry.image then
		return
	end
	local ok, image = pcall(graphics.upload, entry.file, entry.width, entry.height, s.renderer, entry)
	if ok then
		entry.image = image
	else
		entry.status, entry.error = "error", tostring(image)
	end
end

local function preload(s)
	if not active(s) or not s.frame then
		return
	end
	local function candidate()
		local fallback
		for key, kind in pairs(s.backend.prefetch) do
			local entry = s.backend.entries[key]
			if
				s.backend.wanted[key]
				and entry
				and entry.status == "ready"
				and not entry.image
				and s.backend:room_for_image(entry)
			then
				if kind == "zoom" then
					return entry, kind
				end
				fallback = fallback or entry
			end
		end
		return fallback
	end
	local initial, kind = candidate()
	if not initial then
		return
	end
	if s.preloading and (kind ~= "zoom" or s.preloading.kind == "zoom") then
		return
	end
	-- A ready forecast must not sit behind an ordinary offscreen upload's
	-- 64 ms idle delay. Replacing its ticket invalidates the older callback.
	local ticket = { kind = kind }
	s.preloading = ticket
	local function zoom_idle_ms()
		return s.zoom_input_ns and (vim.uv.hrtime() - s.zoom_input_ns) / 1e6 or 64
	end
	-- Upload one offscreen tile per idle turn. Its virtual placement has no
	-- placeholders yet, so it cannot cover the currently displayed frame.
	vim.defer_fn(function()
		if s.preloading ~= ticket then
			return
		end
		s.preloading = nil
		local frame = s.frame
		if not active(s) or s.pending or not frame or frame.zoom ~= s.zoom or frame.x ~= s.x or frame.y ~= s.y then
			return
		end
		-- Continuous zoom invalidates offscreen images almost immediately.
		-- Keep transfer bandwidth for visible tiles until zoom input settles.
		local entry, reason = candidate()
		if zoom_idle_ms() < 64 and reason ~= "zoom" then
			return preload(s)
		end
		if entry then
			prepare(s, entry)
			preload(s)
		end
	end, kind == "zoom" and 2 or math.max(8, math.ceil(64 - zoom_idle_ms())))
end

local function restore(s)
	if s.saved and s.win and api.nvim_win_is_valid(s.win) then
		for key, value in pairs(s.saved) do
			pcall(api.nvim_set_option_value, key, value, { win = s.win, scope = "local" })
		end
	end
	s.saved = nil
end

local function attach(s, win)
	if s.win ~= win then
		restore(s)
	end
	s.win = win
	if not s.saved then
		s.saved = {}
		for key, value in pairs(window_options) do
			s.saved[key] = api.nvim_get_option_value(key, { win = win, scope = "local" })
			api.nvim_set_option_value(key, value, { win = win, scope = "local" })
		end
		s.status_text = nil
		api.nvim_set_option_value("winbar", " PDF — loading…", { win = win, scope = "local" })
	end
end

local function same_chunks(a, b)
	if #a ~= #b then
		return false
	end
	for i, chunk in ipairs(a) do
		if chunk[1] ~= b[i][1] or chunk[2] ~= b[i][2] then
			return false
		end
	end
	return true
end

local function write(s, lines, marks, view_y)
	if not active(s) then
		return
	end
	local topline, replace, append_from = 1, false, nil
	if view_y then
		-- Let Neovim scroll its grid instead of rewriting every placeholder cell.
		-- A bounded blank buffer holds document coordinates around the viewport.
		local maximum = math.max(8192, 3 * s.height)
		local needed = math.max(s.height, math.min(s.layout.height, maximum))
		local count = math.max(s.height, math.min(s.text_lines or 0, maximum))
		if count < needed then
			-- Small zoom changes must not rewrite thousands of blank lines and
			-- invalidate every marker. Grow capacity in bounded batches instead.
			count = math.max(count, 256)
			while count < needed do
				count = math.min(maximum, count * 2)
			end
		end
		local base = s.text_base or 0
		if view_y < base or view_y + s.height > base + count then
			base = layout.clamp(view_y - math.floor((count - s.height) / 2), 0, s.layout.height - count)
		end
		s.text_base = base
		topline = view_y - base + 1
		if s.text_lines ~= count then
			-- Extending at EOF keeps the displayed rows intact until the new
			-- image grid commits, including any intermediate UI redraw.
			append_from = s.text_lines and s.text_lines < count and s.text_lines or nil
			lines = {}
			for row = 1, count - (append_from or 0) do
				lines[row] = ""
			end
			replace = true
		end
		s.text_lines, s.lines = count, nil
	else
		replace = s.text_lines ~= nil or not vim.deep_equal(s.lines, lines)
		s.text_lines, s.text_base, s.lines = nil, nil, lines
	end
	if replace then
		if not append_from then
			api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
			s.marks = nil
		end
		vim.bo[s.buf].modifiable = true
		api.nvim_buf_set_lines(s.buf, append_from or 0, -1, false, lines)
		vim.bo[s.buf].modifiable = false
		vim.bo[s.buf].modified = false
	end
	local changed = replace
	if s.mark_specs ~= marks or s.mark_topline ~= topline or not s.marks then
		changed = true
		-- A failed partial update must invalidate the previously committed identity.
		s.mark_specs = nil
		local current, wanted = s.marks or {}, {}
		s.marks = current
		for _, m in ipairs(marks or {}) do
			local row = m.row + topline - 1
			local old = current[row]
			wanted[row] = true
			if not old or not same_chunks(old.chunks, m.chunks) then
				local id = api.nvim_buf_set_extmark(s.buf, ns, row, 0, {
					id = old and old.id,
					virt_text = m.chunks,
					virt_text_win_col = 0,
					virt_text_pos = "overlay",
					priority = 200,
					hl_mode = "replace",
				})
				current[row] = { id = id, chunks = m.chunks }
			end
		end
		for row, old in pairs(current) do
			if not wanted[row] then
				api.nvim_buf_del_extmark(s.buf, ns, old.id)
				current[row] = nil
			end
		end
		s.mark_specs, s.mark_topline = marks, topline
	end
	local positioned = false
	if s.renderer == "surface" then
		-- Surface pixels move inside a fixed grid. Check the actual window so
		-- external cursor or view changes are still repaired on the next frame.
		local view = api.nvim_get_current_win() == s.win and vim.fn.winsaveview()
			or api.nvim_win_call(s.win, vim.fn.winsaveview)
		positioned = view.lnum == topline
			and view.col == 0
			and view.coladd == 0
			and view.curswant == 0
			and view.topline == topline
			and view.leftcol == 0
			and view.skipcol == 0
			and view.topfill == 0
	end
	if not positioned then
		api.nvim_win_set_cursor(s.win, { topline, 0 })
		api.nvim_win_call(s.win, function()
			-- winrestview() invalidates the whole grid and prevents terminal scrolling.
			vim.cmd("normal! zt")
		end)
		changed = true
	end
	return changed
end

local paint
local function schedule(s, immediate)
	if s.closed or (s.pending and not immediate) then
		return
	end
	local ticket = {}
	s.pending = ticket
	local function run()
		if s.pending ~= ticket then
			return
		end
		s.pending = nil
		if active(s) then
			paint(s)
		end
	end
	if immediate or (s.backend and s.backend.rasterizer == "native") or s.renderer == "viewport" then
		vim.schedule(run)
	else
		vim.defer_fn(run, 12)
	end
end

local function geometry(s)
	local cw, ch, metrics = terminal.cell_size(M.config)
	s.cell_metrics = metrics
	local info = vim.fn.getwininfo(s.win)[1]
	local w, h = info.width - info.textoff, info.height
	local key = table.concat({ w, h, cw, ch, s.zoom, vim.o.columns, s.renderer }, ":")
	if key ~= s.geometry_key then
		local previous = s.layout
		local next_layout = layout.build(s.pages, w, cw, ch, s.zoom, M.config.page_gap, s.renderer == "surface")
		s.y = previous and layout.reanchor(previous, next_layout, s.y, h, s.height) or s.y
		if previous then
			s.x = layout.reanchor_x(previous, next_layout, s.x, w, s.width)
		end
		s.layout, s.geometry_key = next_layout, key
	end
	s.width, s.height, s.cw, s.ch, s.columns = w, h, cw, ch, vim.o.columns
	s.y = layout.clamp(s.y, 0, s.layout.height - h)
	s.x = layout.clamp(s.x, 0, s.layout.width - w)
end

local function status(s, waiting)
	local page = layout.at(s.layout, s.y + s.height / 2)
	local text = string.format(
		" PDF  %d/%d  ·  %.1f%%%% fit-width%s  ·  drag select  y copy  +/− zoom  q close",
		page,
		#s.pages,
		s.zoom * 100,
		waiting and "  ·  rendering…" or ""
	)
	if s.status_text ~= text then
		api.nvim_set_option_value("winbar", text, { win = s.win, scope = "local" })
		s.status_text = text
	end
end

local function frame_ready(s, entries, preview)
	local surface = table.concat({ s.win, s.width, s.height, s.cw, s.ch, s.columns }, ":")
	local key = table.concat({ s.geometry_key, s.x, s.y, s.compact and "compact" or "explicit" }, ":")
	-- Holding an old zoom is safe only while the drawable window stays the same.
	if s.frame and s.frame.surface ~= surface then
		s.frame = nil
		s.backend:set_retained({})
	end
	local keys, waiting = {}, false
	for _, e in pairs(entries) do
		keys[e.key] = true
		waiting = waiting or (e.status ~= "ready" and e.status ~= "error")
	end
	if not waiting then
		local protected = vim.tbl_extend("force", keys, s.backend.retained)
		for key in pairs(preview and preview.entries or {}) do
			protected[key] = true
		end
		local ready, delay = s.backend:reserve_images(protected)
		if ready then
			s.image_wait = nil
		end
		waiting = not ready
		if waiting and not s.image_wait then
			local ticket = {}
			s.image_wait = ticket
			vim.defer_fn(function()
				if s.image_wait == ticket then
					s.image_wait = nil
					if active(s) then
						schedule(s, true)
					end
				end
			end, delay)
		end
	end
	status(s, waiting and not preview)
	if waiting and preview then
		key = key .. ":preview"
		keys = {}
		for entry_key, e in pairs(preview.entries) do
			local size = preview.sizes[entry_key]
			e.width, e.height = size.width, size.height
			s.backend.wanted[entry_key], s.backend.prefetch[entry_key] = true, nil
			keys[entry_key] = true
		end
	elseif waiting then
		if not s.frame and s.loading_surface ~= surface then
			write(s, { "Rendering PDF…" })
			s.loading_surface = surface
		end
		s.backend:pump()
		return
	else
		preview = nil
		for _, e in pairs(entries) do
			prepare(s, e)
		end
	end
	if s.frame and s.frame.key == key then
		s.input_ns = nil
		s.backend:pump()
		preload(s)
		return
	end
	return {
		key = key,
		layout = s.layout,
		width = s.width,
		height = s.height,
		cw = s.cw,
		ch = s.ch,
		surface = surface,
		keys = keys,
		zoom = s.zoom,
		x = s.x,
		y = s.y,
		compact = s.compact,
		refining = preview ~= nil,
	},
		preview
end

local function commit(s, frame, lines, marks)
	local retiring = false
	for key in pairs(s.backend.retained) do
		if not frame.keys[key] then
			retiring = true
			break
		end
	end
	local function publish()
		s.selection:hide()
		graphics.resize_many(frame.resizes or {})
		local view_y
		if s.renderer ~= "surface" then
			view_y = frame.y
		end
		local changed = write(s, lines, marks, view_y)
		local flush = retiring or frame.resizes
		if s.renderer == "surface" then
			-- Pixel replacements keep their image IDs and placeholder grid.
			-- Flush text only when the view, markers or window bar changed.
			flush = retiring or changed or not s.frame or s.frame.status_text ~= s.status_text
		end
		if flush then
			-- ui_send bypasses the TUI's buffered grid output. Flush replacement
			-- placeholders before resizing ends or old images can be retired.
			vim.cmd.redraw()
		elseif s.renderer == "surface" then
			-- Raw image events still need a UI flush inside nested event loops
			-- (for example vim.wait), even when no text was invalidated.
			api.nvim__redraw({ flush = true })
		end
	end
	-- New image IDs also need an atomic grid replacement, even when every
	-- placement was uploaded at its final size and needs no resize command.
	if retiring or frame.resizes then
		graphics.synchronized(publish)
	else
		publish()
	end
	frame.status_text = s.status_text
	frame.submitted_ns = vim.uv.hrtime()
	frame.input_to_submit_ms = s.input_ns and (frame.submitted_ns - s.input_ns) / 1e6 or nil
	s.input_ns = nil
	s.frame = frame
	s.selection:resolve()
	s.loading_surface = nil
	-- The displayed images must survive cache eviction while their replacements run.
	s.backend:set_retained(frame.keys)
	s.backend:pump()
	preload(s)
	if s.surface_retire then
		s.surface_retire = nil
		vim.defer_fn(function()
			surface.hide(s)
		end, 40)
	end
end

local function paint_viewport(s)
	local visible = layout.visible(s.layout, s.y, s.height)
	local fragments, entries, grids, sources = {}, {}, {}, {}
	s.backend.wanted, s.backend.prefetch = {}, {}
	local function grid(n, document)
		local p = (document or s.layout).pages[n]
		if not grids[p] then
			local _, px, py, level = s.backend:key(n, p, s.cw, s.ch, true)
			local page = s.pages[n]
			local ratio = level and level / math.max(page.width, page.height)
			local reference = ratio
				and {
					width = math.ceil(page.width * ratio / s.cw),
					height = math.ceil(page.height * ratio / s.ch),
				}
			grids[p] = tiles.build(p, px, py, graphics.tile_size, reference, s.columns)
		end
		if not document then
			sources[n] = grids[p]
		end
		return grids[p]
	end
	local function fragment(e, x, y, bounds)
		local left, top = math.max(bounds.left, x.first), math.max(bounds.top, y.first)
		return {
			entry = e,
			row = bounds.screen_top + top - bounds.top,
			col = bounds.padding + left - bounds.left,
			left = left - x.first,
			top = top - y.first,
			width = math.min(x.first + x.size, bounds.right) - left,
			height = math.min(y.first + y.size, bounds.bottom) - top,
		}
	end
	local function request(n, ix, iy, visible_tile, bounds, document)
		local p = (document or s.layout).pages[n]
		local g = grid(n, document)
		local x, y = g.x[ix], g.y[iy]
		local clip = { left = x.first, top = y.first, width = x.size, height = y.size }
		if g.reusable then
			clip.source = { x = x.pixel, y = y.pixel, width = x.pixels, height = y.pixels }
		end
		local e = s.backend:request(n, p, s.cw, s.ch, clip, document ~= nil)
		if not visible_tile then
			if not entries[e.key] then
				s.backend.prefetch[e.key] = document and "zoom" or true
			end
			return
		end
		entries[e.key] = e
		fragments[#fragments + 1] = fragment(e, x, y, bounds)
	end
	local function horizontal(n, document, position)
		document = document or s.layout
		local p = document.pages[n]
		local offset = math.floor((math.max(s.width, document.width) - p.width) / 2) - (position or s.x)
		return math.max(0, -offset), math.min(p.width, s.width - offset), math.max(0, offset)
	end
	for _, n in ipairs(visible) do
		local p = s.layout.pages[n]
		local g = grid(n)
		local left, right, padding = horizontal(n)
		local top, bottom = math.max(0, s.y - p.top), math.min(p.height, s.y + s.height - p.top)
		local x1, x2 = tiles.range(g.x, left, right)
		local y1, y2 = tiles.range(g.y, top, bottom)
		if x1 and y1 then
			local bounds = {
				left = left,
				right = right,
				top = top,
				bottom = bottom,
				padding = padding,
				screen_top = math.max(0, p.top - s.y),
			}
			for iy = y1, y2 do
				for ix = x1, x2 do
					request(n, ix, iy, true, bounds)
				end
			end
			for _, iy in ipairs({ y1 - 1, y2 + 1 }) do
				if g.y[iy] then
					for ix = x1, x2 do
						request(n, ix, iy, false)
					end
				end
			end
		end
	end
	if #visible > 0 then
		for _, adjacent in ipairs({ { visible[1] - 1, true }, { visible[#visible] + 1, false } }) do
			local n = adjacent[1]
			if s.layout.pages[n] then
				local g = grid(n)
				local left, right = horizontal(n)
				local x1, x2 = tiles.range(g.x, left, right)
				if x1 then
					for ix = x1, x2 do
						request(n, ix, adjacent[2] and #g.y or 1, false)
					end
				end
			end
		end
	end
	-- Prepare only the next likely resolution boundary. These crops are never
	-- allowed to change the geometry of images in the current frame.
	if M.config.prefetch_zoom then
		local center = layout.at(s.layout, s.y + s.height / 2)
		local page = s.layout.pages[center]
		local edge = math.max(page.pixel_width, page.pixel_height)
		local _, _, _, level = s.backend:key(center, page, s.cw, s.ch, true)
		local fraction = edge / level
		local next_zoom
		if (s.zoom_direction or 1) >= 0 and fraction >= 0.92 then
			next_zoom = s.zoom * level / edge * 1.005
		elseif s.zoom_direction == -1 and fraction <= 0.87 then
			next_zoom = s.zoom * (level / 2 ^ 0.25) / edge * 0.995
		end
		if next_zoom and next_zoom >= M.config.min_zoom and next_zoom <= M.config.max_zoom then
			local document = layout.build(s.pages, s.width, s.cw, s.ch, next_zoom, M.config.page_gap)
			local next_x = layout.reanchor_x(s.layout, document, s.x, s.width)
			local next_y = layout.reanchor(s.layout, document, s.y, s.height)
			for _, n in ipairs(layout.visible(document, next_y, s.height)) do
				local p, g = document.pages[n], grid(n, document)
				local left, right = horizontal(n, document, next_x)
				local top, bottom = math.max(0, next_y - p.top), math.min(p.height, next_y + s.height - p.top)
				local x1, x2 = tiles.range(g.x, left, right)
				local y1, y2 = tiles.range(g.y, top, bottom)
				if x1 and y1 then
					for iy = y1, y2 do
						for ix = x1, x2 do
							request(n, ix, iy, false, nil, document)
						end
					end
				end
			end
		end
	end
	local function cached_preview()
		if not M.config.progressive_zoom or not s.frame or not s.frame.sources then
			return
		end
		if s.frame.surface ~= table.concat({ s.win, s.width, s.height, s.cw, s.ch, s.columns }, ":") then
			return
		end
		local waiting = false
		for _, e in pairs(entries) do
			waiting = waiting or not e.image or (e.status ~= "ready" and e.status ~= "error")
		end
		if not waiting then
			return
		end
		local preview = { entries = {}, sizes = {}, fragments = {}, sources = s.frame.sources }
		for _, n in ipairs(visible) do
			local p = s.layout.pages[n]
			local source = preview.sources[n]
			local g = source and tiles.project(source, p, graphics.tile_size, s.columns)
			if not g then
				return
			end
			local left, right, padding = horizontal(n)
			local top, bottom = math.max(0, s.y - p.top), math.min(p.height, s.y + s.height - p.top)
			local x1, x2 = tiles.range(g.x, left, right)
			local y1, y2 = tiles.range(g.y, top, bottom)
			if x1 and y1 then
				local bounds = {
					left = left,
					right = right,
					top = top,
					bottom = bottom,
					padding = padding,
					screen_top = math.max(0, p.top - s.y),
				}
				for iy = y1, y2 do
					for ix = x1, x2 do
						local x, y = g.x[ix], g.y[iy]
						local e = s.backend:cached_tile(n, g.pixel_width, g.pixel_height, {
							x = x.pixel,
							y = y.pixel,
							width = x.pixels,
							height = y.pixels,
						})
						if not e or e.status ~= "ready" or not e.image or e.image.deleted then
							return
						end
						preview.entries[e.key] = e
						preview.sizes[e.key] = { width = x.size, height = y.size }
						preview.fragments[#preview.fragments + 1] = fragment(e, x, y, bounds)
					end
				end
			end
		end
		return preview
	end
	local frame, preview = frame_ready(s, entries, cached_preview())
	if not frame then
		return
	end
	if preview then
		entries, fragments, sources = preview.entries, preview.fragments, preview.sources
	end
	frame.sources = sources
	for _, e in pairs(entries) do
		local image = e.image
		if image and (image.cols ~= e.width or image.rows ~= e.height) then
			frame.resizes = frame.resizes or {}
			frame.resizes[#frame.resizes + 1] = { image = image, width = e.width, height = e.height }
		end
	end
	local lines, rows, ends = {}, {}, {}
	for row = 0, s.height - 1 do
		lines[row + 1], rows[row], ends[row] = "", {}, 0
	end
	local function append(row, col, text, hl, width)
		local chunks = rows[row]
		if col > ends[row] then
			chunks[#chunks + 1] = { string.rep(" ", col - ends[row]), "PdfPreviewBackground" }
		end
		chunks[#chunks + 1] = { text, hl }
		ends[row] = col + width
	end
	for _, fragment in ipairs(fragments) do
		local e = fragment.entry
		if e.image then
			for r = 0, fragment.height - 1 do
				local chunk = graphics.viewport_row(e.image, fragment.top + r, fragment.left, fragment.width, s.compact)
				append(fragment.row + r, fragment.col, chunk[1], chunk[2], fragment.width)
			end
		else
			local label = (e.error or "Render failed"):gsub("[\r\n]", " "):sub(1, fragment.width)
			append(fragment.row, fragment.col, label, "Comment", #label)
		end
	end
	local marks = {}
	for row = 0, s.height - 1 do
		if #rows[row] > 0 then
			marks[#marks + 1] = { row = row, chunks = rows[row] }
		end
	end
	commit(s, frame, lines, marks)
end

local function surface_fallback(s, reason)
	local pending = s.surface_state
	if pending then
		pending.animation = nil
	end
	s.renderer = "viewport"
	s.geometry_key = nil
	s.surface_fallback = reason
	-- Keep the last complete surface until the replacement tile grid commits.
	s.surface_retire = pending ~= nil
	schedule(s, true)
end

paint = function(s)
	if not active(s) or not s.pages then
		return
	end
	geometry(s)
	s.compact = M.config.compact_placeholders and s.renderer == "viewport"
	if s.compact then
		-- A float can cover a row's anchor, breaking coordinate inheritance.
		-- Use independent coordinates until all floating overlays are gone.
		for _, win in ipairs(api.nvim_tabpage_list_wins(api.nvim_win_get_tabpage(s.win))) do
			if win ~= s.win and api.nvim_win_get_config(win).relative ~= "" then
				s.compact = false
				break
			end
		end
	end
	if s.renderer == "surface" then
		return surface.paint(
			s,
			M.config,
			{ active = active, schedule = schedule, status = status, commit = commit, fallback = surface_fallback }
		)
	end
	if s.renderer == "viewport" then
		return graphics.synchronized(function()
			return paint_viewport(s)
		end)
	end
	local visible = layout.visible(s.layout, s.y, s.height)
	local entries = {}
	s.backend.wanted, s.backend.prefetch = {}, {}
	for _, n in ipairs(visible) do
		local p = s.layout.pages[n]
		local e = s.backend:request(n, p, s.cw, s.ch)
		entries[n] = e
	end
	-- Preload the neighboring pages, after the visible pages.
	if #visible > 0 then
		for _, n in ipairs({ visible[1] - 1, visible[#visible] + 1 }) do
			if s.layout.pages[n] then
				local e = s.backend:request(n, s.layout.pages[n], s.cw, s.ch)
				s.backend.prefetch[e.key] = true
			end
		end
	end
	local frame = frame_ready(s, entries)
	if not frame then
		return
	end
	local lines, marks = {}, {}
	for row = 0, s.height - 1 do
		lines[row + 1] = ""
		local y = s.y + row
		local chunks
		for _, n in ipairs(visible) do
			local p = s.layout.pages[n]
			if y >= p.top and y < p.top + p.height then
				local e = entries[n]
				local offset = math.floor((math.max(s.width, s.layout.width) - p.width) / 2) - s.x
				local left = math.max(0, -offset)
				local padding = math.max(0, offset)
				local count = math.max(0, math.min(p.width - left, s.width - padding))
				if e.image and count > 0 then
					chunks = { { string.rep(" ", padding), "PdfPreviewBackground" } }
					vim.list_extend(chunks, graphics.row(e.image, y - p.top, left, count))
				elseif row == 0 or y == p.top then
					local label = e.status == "error"
							and ("Page " .. n .. ": " .. (e.error or "render error"):gsub("[\r\n]", " "))
						or ("Rendering page " .. n .. "…")
					chunks = { { label:sub(1, s.width), "Comment" } }
				end
				break
			end
		end
		if chunks then
			marks[#marks + 1] = { row = row, chunks = chunks }
		end
	end
	commit(s, frame, lines, marks)
end

local function current()
	local s = states[api.nvim_get_current_buf()]
	if not s then
		message("Open a document with :PdfOpen first")
	end
	return s
end

function M.copy(register)
	local s = current()
	if s then
		return s.selection:copy(register)
	end
end

function M.clear_selection()
	local s = current()
	if s then
		s.selection:clear()
	end
end

function M.translate()
	local s = current()
	if s then
		s.context:translate()
	end
end

function M.scroll(dy, dx)
	local s = current()
	if not s or not s.pages then
		return
	end
	geometry(s)
	if s.renderer == "surface" then
		surface.scroll(s, M.config.scroll_animation_ms)
	end
	s.y = layout.clamp(s.y + dy, 0, s.layout.height - s.height)
	s.x = layout.clamp(s.x + (dx or 0), 0, s.layout.width - s.width)
	s.input_ns = vim.uv.hrtime()
	schedule(s)
end

local function apply_zoom(s)
	if s.surface_state then
		s.surface_state.animation = nil
	end
	s.zoom, s.zoom_target, s.zoom_timer = s.zoom_target, nil, nil
	s.zoom_started_ns = vim.uv.hrtime()
	s.input_ns = s.zoom_input_ns
	schedule(s)
end

function M.zoom(percent)
	local s = current()
	if not s or not s.pages then
		return
	end
	percent = tonumber(percent)
	if not percent or percent ~= percent or percent == math.huge or percent == -math.huge then
		return message("Zoom must be a finite percentage")
	end
	local target = layout.clamp(percent / 100, M.config.min_zoom, M.config.max_zoom)
	local prior = s.zoom_target or s.zoom
	if target ~= prior then
		s.zoom_direction = target > prior and 1 or -1
	end
	s.zoom_target = target
	s.zoom_input_ns = vim.uv.hrtime()
	local interval = (s.renderer == "surface" or s.renderer == "viewport")
			and s.frame
			and not s.backend:visible_pending()
			and 8
		or 16
	local elapsed = s.zoom_started_ns and (s.zoom_input_ns - s.zoom_started_ns) / 1e6 or interval
	if s.backend.rasterizer == "native" and elapsed < interval - 2 then
		-- Warm source pixels can follow 120 Hz input. Give outstanding raster
		-- work a 60 Hz budget, with 2 ms of timer jitter, to avoid starving it.
		if not s.zoom_timer then
			local ticket = {}
			s.zoom_timer = ticket
			vim.defer_fn(function()
				if not s.closed and s.zoom_timer == ticket then
					apply_zoom(s)
				end
			end, math.ceil(interval - elapsed))
		end
	else
		apply_zoom(s)
	end
end

function M.goto_page(page)
	local s = current()
	if not s or not s.pages then
		return
	end
	geometry(s)
	page = tonumber(page)
	if not page or page % 1 ~= 0 or not s.layout.pages[page] then
		return message("Invalid page number")
	end
	if s.surface_state then
		s.surface_state.animation = nil
	end
	s.y = layout.clamp(s.layout.pages[page].top, 0, s.layout.height - s.height)
	s.input_ns = vim.uv.hrtime()
	schedule(s)
end

function M.close()
	local s = states[api.nvim_get_current_buf()]
	if s then
		api.nvim_buf_delete(s.buf, { force = true })
	end
end

function M.reload()
	local s = current()
	if not s then
		return
	end
	local file = s.path
	M.close()
	M.open(file)
end

-- Timings end at Neovim's frame submission; the terminal does not report
-- when the images have actually reached the display.
function M.stats()
	local s = current()
	if not s then
		return
	end
	local uploaded = 0
	for _, entry in pairs(s.backend.entries) do
		if entry.image then
			uploaded = uploaded + 1
		end
	end
	local surface_count, surface_bytes = surface.stats(s)
	local metrics = s.cell_metrics or {}
	return {
		renderer = s.renderer,
		rasterizer = s.backend.rasterizer,
		text_backend = s.selection.source and s.selection.source.backend
			or require("pdfpreview.text").available(M.config),
		text_fallback = s.selection.source and s.selection.source.fallback,
		zoom = (s.zoom_target or s.zoom) * 100,
		displayed_zoom = s.frame and s.frame.zoom * 100 or nil,
		refining = s.frame and s.frame.refining or false,
		surface_refined = s.renderer == "surface" and s.frame and s.frame.refined or false,
		refinement_active = s.backend.refinement_active or false,
		refinement_error = s.surface_state and s.surface_state.refine_error,
		refinement_scale = s.frame and s.frame.refinement_scale,
		cell_width = s.cw,
		cell_height = s.ch,
		cell_width_source = metrics.width_source,
		cell_height_source = metrics.height_source,
		detected_cell_width = metrics.detected_width,
		detected_cell_height = metrics.detected_height,
		input_to_submit_ms = s.frame and s.frame.input_to_submit_ms or nil,
		active_jobs = s.backend.active,
		cached_renders = vim.tbl_count(s.backend.entries),
		uploaded_images = uploaded + surface_count,
		retiring_images = #s.backend.retiring + (s.surface_state and #s.surface_state.retiring or 0),
		terminal_image_bytes = s.backend:image_bytes() + surface_bytes,
		displayed_y = s.frame and s.frame.y,
		compose_ms = s.frame and s.frame.compose_ms,
		surface_fallback = s.surface_fallback,
		native_output_cache_bytes = s.backend.native
				and not s.backend.native.exited
				and s.backend.native.output_cache_bytes
			or 0,
		native_selection_cache_bytes = s.backend.refiner
				and not s.backend.refiner.exited
				and s.backend.refiner.selection_cache_bytes
			or 0,
		native_gpu_cache_bytes = s.backend.native and not s.backend.native.exited and s.backend.native.gpu_cache_bytes
			or 0,
		image_cache_bytes = s.backend.opts.image_cache_bytes,
		native_pixel_cache_bytes = s.backend.native and not s.backend.native.exited and s.backend.native.cache_bytes
			or 0,
		compact_placeholders = s.frame and s.frame.compact or false,
	}
end

local function mappings(s)
	local function map(keys, fn, desc)
		for _, key in ipairs(type(keys) == "table" and keys or { keys }) do
			vim.keymap.set("n", key, fn, { buffer = s.buf, silent = true, desc = desc })
		end
	end
	for key, kind in pairs({ ["<LeftMouse>"] = "press", ["<LeftDrag>"] = "drag", ["<LeftRelease>"] = "release" }) do
		for _, prefix in ipairs({ "", "2-", "3-", "4-" }) do
			local lhs = key:gsub("<", "<" .. prefix)
			vim.keymap.set("n", lhs, function()
				local mouse = vim.fn.getmousepos()
				s.selection:mouse(kind, mouse, prefix ~= "" and "word" or nil)
				return mouse.winid == s.win and "" or lhs
			end, { buffer = s.buf, silent = true, expr = true, desc = "Select PDF text" })
		end
	end
	for _, prefix in ipairs({ "", "2-", "3-", "4-" }) do
		local key = "<" .. prefix .. "RightMouse>"
		vim.keymap.set("n", key, function()
			local mouse = vim.fn.getmousepos()
			if mouse.winid ~= s.win then
				return key
			end
			vim.schedule(function()
				if active(s) then
					s.context:open(mouse)
				end
			end)
			return ""
		end, { buffer = s.buf, silent = true, expr = true, desc = "PDF copy and translation menu" })
	end
	map({ "<RightRelease>", "<RightDrag>" }, function() end, "PDF context menu")
	map("y", function()
		M.copy(vim.v.register)
	end, "Yank selected PDF text")
	map({ "<C-c>", "<D-c>" }, function()
		M.copy("+")
	end, "Copy PDF text to clipboard")
	map("<Esc>", M.clear_selection, "Clear PDF text selection")
	map({ "j", "<Down>" }, function()
		M.scroll(vim.v.count1)
	end, "Scroll PDF down")
	map({ "k", "<Up>" }, function()
		M.scroll(-vim.v.count1)
	end, "Scroll PDF up")
	map("<ScrollWheelDown>", function()
		M.scroll(M.config.scroll_step)
	end, "Scroll PDF down")
	map("<ScrollWheelUp>", function()
		M.scroll(-M.config.scroll_step)
	end, "Scroll PDF up")
	map({ "h", "<Left>", "<ScrollWheelLeft>" }, function()
		M.scroll(0, -3 * vim.v.count1)
	end, "Pan PDF left")
	map({ "l", "<Right>", "<ScrollWheelRight>" }, function()
		M.scroll(0, 3 * vim.v.count1)
	end, "Pan PDF right")
	map({ "<C-d>", "<PageDown>", "<Space>" }, function()
		M.scroll(math.max(1, math.floor((s.height or 20) * 0.8)))
	end, "Scroll PDF down")
	map({ "<C-u>", "<PageUp>" }, function()
		M.scroll(-math.max(1, math.floor((s.height or 20) * 0.8)))
	end, "Scroll PDF up")
	map({ "<C-e>" }, function()
		M.scroll(1)
	end, "Scroll PDF down")
	map({ "<C-y>" }, function()
		M.scroll(-1)
	end, "Scroll PDF up")
	map({ "+", "=", "<C-ScrollWheelUp>" }, function()
		M.zoom((s.zoom_target or s.zoom) * 100 * M.config.zoom_step)
	end, "Zoom PDF in")
	map({ "-", "<C-ScrollWheelDown>" }, function()
		M.zoom((s.zoom_target or s.zoom) * 100 / M.config.zoom_step)
	end, "Zoom PDF out")
	map("0", function()
		s.x = 0
		M.zoom(100)
	end, "Fit PDF width")
	map("gg", function()
		M.goto_page(1)
	end, "First PDF page")
	map("G", function()
		if vim.v.count > 0 then
			M.goto_page(vim.v.count)
		elseif s.layout then
			s.y = math.max(0, s.layout.height - s.height)
			s.input_ns = vim.uv.hrtime()
			schedule(s)
		end
	end, "Last PDF page or [count]G")
	map("q", M.close, "Close PDF")
	map("R", M.reload, "Reload PDF")
end

local function hide(s)
	s.context:close()
	s.selection:hide()
	s.selection.dragging = false
	surface.hide(s)
	s.frame, s.loading_surface, s.pending, s.input_ns = nil, nil, nil, nil
	s.zoom, s.zoom_target, s.zoom_timer = s.zoom_target or s.zoom, nil, nil
	s.preloading, s.image_wait = nil, nil
	s.marks, s.mark_specs, s.mark_topline = nil, nil, nil
	if api.nvim_buf_is_valid(s.buf) then
		api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
	end
	s.backend:hide()
end

local function dispose(s)
	if s.closed then
		return
	end
	s.context:close()
	surface.hide(s, true)
	s.selection:close()
	s.closed = true
	restore(s)
	s.backend:close()
	states[s.buf] = nil
end

function M.open(file, buf)
	file = file and vim.fn.fnamemodify(file:gsub("^~", vim.env.HOME or ""), ":p") or ""
	if file == "" or vim.fn.filereadable(file) ~= 1 then
		return message("PDF file is not readable: " .. file)
	end
	for _, name in ipairs({ "pdfinfo", "pdftoppm" }) do
		if vim.fn.executable(M.config[name]) ~= 1 then
			return message("Missing " .. name .. "; install Poppler (brew install poppler)")
		end
	end
	if M.config.rasterizer == "native" and not require("pdfpreview.native").available(M.config) then
		return message(
			"Native renderer is unavailable; run make native in the plugin directory, or use rasterizer='poppler'"
		)
	end
	if not vim.o.termguicolors then
		return message("Enable termguicolors before opening a PDF")
	end
	if vim.env.TMUX or vim.env.ZELLIJ then
		return message("This version needs Neovim directly inside the terminal, without tmux/Zellij")
	end
	for _, s in pairs(states) do
		if s.path == file then
			api.nvim_set_current_buf(s.buf)
			attach(s, api.nvim_get_current_win())
			schedule(s)
			return s
		end
	end
	buf = buf or api.nvim_create_buf(true, true)
	if states[buf] then
		dispose(states[buf])
	end
	-- The reader owns its document-aligned viewport. A second scroll animator
	-- visits blank backing rows between frames and causes visible flashes.
	vim.b[buf].snacks_scroll = false
	api.nvim_set_current_buf(buf)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].undolevels = -1
	vim.bo[buf].filetype = "pdfpreview"
	local renderer = M.config.renderer
	if renderer == "auto" then
		renderer = (vim.env.TERM_PROGRAM or ""):lower():find("otty", 1, true) and "viewport" or "unicode"
	end
	local s = { buf = buf, path = file, zoom = 1, x = 0, y = 0, renderer = renderer }
	s.selection = selection.new(s, M.config, active, schedule)
	s.context = context.new(s, M.config)
	states[buf] = s
	s.backend = backend.new(file, M.config, function()
		schedule(s, true)
	end)
	attach(s, api.nvim_get_current_win())
	if api.nvim_buf_get_name(buf) == "" then
		api.nvim_buf_set_name(buf, "pdfpreview://" .. file)
	end
	write(s, { "Loading " .. vim.fn.fnamemodify(file, ":t") .. "…" })
	mappings(s)
	api.nvim_create_autocmd("BufWinLeave", {
		buffer = buf,
		callback = function()
			restore(s)
			hide(s)
		end,
	})
	api.nvim_create_autocmd("BufWinEnter", {
		buffer = buf,
		callback = function()
			attach(s, api.nvim_get_current_win())
			schedule(s)
		end,
	})
	api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			dispose(s)
		end,
	})
	s.backend:info(function(pages, err)
		if s.closed then
			return
		end
		if not pages then
			s.error = err or "Could not read PDF"
			write(s, { "Unable to open PDF:", s.error:gsub("[\r\n]+", " ") })
			message(s.error)
			return
		end
		s.pages = pages
		local can_compose = api.nvim_ui_send and s.backend.native and s.backend.native.has_surface
		if M.config.renderer == "auto" and s.renderer == "viewport" and can_compose then
			s.renderer = "surface"
		end
		if s.renderer == "surface" and not can_compose then
			s.renderer = "viewport"
			s.surface_fallback = "Metal viewport composition requires a supported device and Neovim 0.12"
		end
		schedule(s)
	end)
	return s
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
	assert(M.config.jobs >= 1 and M.config.cache_pages >= 1, "jobs and cache_pages must be positive")
	assert(vim.tbl_contains({ "auto", "unicode", "viewport", "surface" }, M.config.renderer), "Invalid renderer")
	assert(vim.tbl_contains({ "auto", "native", "poppler" }, M.config.rasterizer), "Invalid rasterizer")
	assert(vim.tbl_contains({ "auto", "pdfkit", "poppler" }, M.config.text_backend), "Invalid text_backend")
	assert(type(M.config.compact_placeholders) == "boolean", "compact_placeholders must be boolean")
	assert(type(M.config.prefetch_zoom) == "boolean", "prefetch_zoom must be boolean")
	local translation = M.config.translation
	assert(vim.tbl_contains({ "google", "mymemory" }, translation.provider), "Invalid translation provider")
	assert(type(translation.source) == "string" and translation.source:match("^[%a%-]+$"), "Invalid translation source")
	assert(type(translation.target) == "string" and translation.target:match("^[%a%-]+$"), "Invalid translation target")
	assert(
		type(translation.timeout) == "number" and translation.timeout >= 1 and translation.timeout <= 60,
		"Translation timeout must be between 1 and 60 seconds"
	)
	assert(type(translation.fallback) == "boolean", "translation.fallback must be boolean")
	assert(
		type(M.config.image_cache_bytes) == "number"
			and M.config.image_cache_bytes >= 1024
			and M.config.image_cache_bytes < math.huge,
		"image_cache_bytes must be finite and at least 1024"
	)
	assert(
		type(M.config.scroll_animation_ms) == "number"
			and M.config.scroll_animation_ms >= 0
			and M.config.scroll_animation_ms <= 200,
		"scroll_animation_ms must be between 0 and 200"
	)
	assert(type(M.config.progressive_zoom) == "boolean", "progressive_zoom must be boolean")
	assert(
		type(M.config.surface_refine_ms) == "number"
			and M.config.surface_refine_ms >= 0
			and M.config.surface_refine_ms <= 2000,
		"surface_refine_ms must be between 0 (disabled) and 2000"
	)
	assert(
		type(M.config.surface_refine_scale) == "number"
			and M.config.surface_refine_scale >= 1
			and M.config.surface_refine_scale <= 2,
		"surface_refine_scale must be between 1 and 2"
	)
	for _, name in ipairs({ "cell_width", "cell_height" }) do
		local value = M.config[name]
		assert(
			value == nil or (type(value) == "number" and value > 0 and value < math.huge),
			name .. " must be a finite positive number or nil (automatic)"
		)
	end
	local group = api.nvim_create_augroup("pdfpreview", { clear = true })
	api.nvim_set_hl(0, "PdfPreviewBackground", { bg = "#20242c", fg = "#a0a8b8" })
	api.nvim_create_user_command("PdfOpen", function(o)
		M.open(o.args ~= "" and o.args or vim.fn.expand("%:p"))
	end, { nargs = "?", complete = "file", force = true })
	api.nvim_create_user_command("PdfZoom", function(o)
		M.zoom(o.args)
	end, { nargs = 1, force = true })
	api.nvim_create_user_command("PdfPage", function(o)
		M.goto_page(o.args)
	end, { nargs = 1, force = true })
	api.nvim_create_user_command("PdfClose", M.close, { force = true })
	api.nvim_create_user_command("PdfCopy", function()
		M.copy("+")
	end, { force = true })
	api.nvim_create_user_command("PdfTranslate", M.translate, { force = true })
	api.nvim_create_user_command("PdfReload", M.reload, { force = true })
	api.nvim_create_user_command("PdfStats", function()
		local stats = M.stats()
		if stats then
			vim.notify(
				vim.inspect(stats),
				vim.log.levels.INFO,
				{ title = "pdfpreview: frame submission (not display)" }
			)
		end
	end, { force = true })
	if M.config.auto_open then
		api.nvim_create_autocmd("BufReadCmd", {
			group = group,
			pattern = { "*.pdf", "*.PDF" },
			callback = function(e)
				M.open(e.file, e.buf)
			end,
		})
	end
	api.nvim_create_autocmd({ "VimResized", "WinResized", "WinNew", "WinClosed" }, {
		group = group,
		callback = function()
			for _, s in pairs(states) do
				s.selection:hide()
				s.selection:schedule()
				schedule(s)
			end
		end,
	})
	api.nvim_create_autocmd({ "UIEnter", "FocusGained" }, {
		group = group,
		callback = function()
			local cw, ch, metrics
			for _, s in pairs(states) do
				if active(s) then
					if not cw then
						cw, ch, metrics = terminal.cell_size(M.config)
					end
					s.cell_metrics = metrics
					-- Font/display changes can leave the row and column counts intact.
					-- Unchanged metrics need no redraw or idle rendering work.
					if s.cw ~= cw or s.ch ~= ch then
						s.selection:hide()
						schedule(s)
					end
				end
			end
		end,
	})
	api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineLeave" }, {
		group = group,
		callback = function(event)
			for _, s in pairs(states) do
				if event.event == "CmdlineEnter" then
					s.selection:hide()
				else
					s.selection:schedule()
				end
			end
		end,
	})
	api.nvim_create_autocmd("TabLeave", {
		group = group,
		callback = function()
			for _, s in pairs(states) do
				if active(s) then
					hide(s)
				end
			end
		end,
	})
	api.nvim_create_autocmd("TabEnter", {
		group = group,
		callback = function()
			for _, s in pairs(states) do
				schedule(s)
			end
		end,
	})
	api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = function()
			api.nvim_set_hl(0, "PdfPreviewBackground", { bg = "#20242c", fg = "#a0a8b8" })
			for _, s in pairs(states) do
				hide(s)
				schedule(s)
			end
		end,
	})
	api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			for _, s in pairs(states) do
				s.selection:close()
				s.backend:close()
			end
		end,
	})
end

M._states = states
M._paint = paint
return M
