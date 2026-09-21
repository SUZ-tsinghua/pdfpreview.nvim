local M = {}
local graphics = require("pdfpreview.graphics")
local selection = require("pdfpreview.selection")
local uv = vim.uv

local function state(s)
	if not s.surface_state then
		s.surface_state = { entries = {}, retiring = {}, files = {}, generation = 0, sequence = 0 }
	end
	return s.surface_state
end

function M.scroll(s, duration)
	local p = state(s)
	if duration > 0 and s.frame and s.frame.zoom == s.zoom then
		p.animation = {
			started = uv.hrtime(),
			duration = duration,
			x = p.render_x or s.frame.x,
			y = p.render_y or s.frame.y,
		}
	end
end

local function reclaim(p, keep)
	for file in pairs(p.files) do
		if not keep[file] then
			uv.fs_unlink(file)
			p.files[file] = nil
		end
	end
end

local function stop_read_timer(p, closing)
	if p.read_timer then
		p.read_timer:stop()
		if closing then
			p.read_timer:close()
			p.read_timer, p.read_timeout = nil, nil
		end
	end
end

local function stop_response(p)
	stop_read_timer(p, true)
	if p.response then
		vim.api.nvim_del_autocmd(p.response)
		p.response = nil
	end
end

local function arm_read(s, p, waiting, hooks)
	if p.awaiting == waiting then
		if not p.read_timer then
			local timer = assert(uv.new_timer())
			p.read_timer = timer
			p.read_timeout = function()
				-- Capture the expired read before entering Neovim's main loop.
				-- Its ACK can arrive and a newer read can begin before we run.
				local expired = p.awaiting
				vim.schedule(function()
					if not expired or p.read_timer ~= timer or p.awaiting ~= expired then
						return
					end
					p.awaiting = nil
					if p.hidden then
						reclaim(p, {})
						p.previous_files = nil
						stop_response(p)
					elseif hooks.active(s) then
						hooks.fallback(s, "Terminal image acknowledgment timed out")
					end
				end)
			end
		end
		p.read_timer:start(1000, 0, p.read_timeout)
	end
end

local function cancel_refinement(s, closing)
	local p = s.surface_state
	if not p then
		return
	end
	p.refine_frame, p.refined_source = nil, nil
	if p.refine_timer then
		p.refine_timer:stop()
		if closing then
			p.refine_timer:close()
			p.refine_timer = nil
		end
	end
	if p.refine_job then
		p.refine_job.kill()
	end
end

local function refinement_request(source, scale)
	local request = vim.deepcopy(source)
	local width = 0
	for _, part in ipairs(source.parts) do
		width = math.max(width, part.offset + part.width)
	end
	-- Supersample only the settled viewport. Motion keeps its smaller reusable
	-- outputs; refinement uses at most 64 MiB, including on large displays.
	scale = math.min(scale, 8192 / width, 8192 / source.height, math.sqrt(16 * 1024 * 1024 / (width * source.height)))
	local sx = math.floor(width * scale) / width
	request.height = math.floor(source.height * scale)
	local sy = request.height / source.height
	for _, part in ipairs(request.parts) do
		local left = math.floor(part.offset * sx + 0.5)
		local right = math.floor((part.offset + part.width) * sx + 0.5)
		part.offset, part.width = left, right - left
	end
	-- Use each output axis's actual scale so integer raster rounding cannot
	-- stretch the PDF when the terminal fits it back into the same cell grid.
	for _, page in ipairs(request.pages) do
		page.left, page.width = page.left * sx, page.width * sx
		page.top, page.height = page.top * sy, page.height * sy
	end
	for _, rect in ipairs(request.selections or {}) do
		rect.x1, rect.x2 = rect.x1 * sx, rect.x2 * sx
		rect.y1, rect.y2 = rect.y1 * sy, rect.y2 * sy
	end
	return request, math.min(sx, sy)
end

local function refinement_files(s, p, request)
	p.refine_sequence = (p.refine_sequence or 0) + 1
	local files = {}
	for index, part in ipairs(request.parts) do
		part.file = s.backend.dir .. "/refine-" .. p.refine_sequence .. "-" .. index .. ".rgba"
		files[#files + 1] = part.file
	end
	return files
end

local function publish_refined(s, p, hooks, target, request, files, scale, result)
	-- Upload files live until the ACK; the native worker retains clean pixels.
	local waiting = { ids = {}, files = files, keep = vim.tbl_extend("force", {}, p.files) }
	for _, file in ipairs(files) do
		p.files[file] = true
	end
	p.awaiting = waiting
	local refined = vim.tbl_extend("force", {}, target)
	refined.refining, refined.refined, refined.compose_ms = false, true, result.render_ms
	refined.refinement_scale = scale
	local ok, err = pcall(graphics.synchronized, function()
		for index, part in ipairs(request.parts) do
			local image = p.entries[index].image
			graphics.replace(image, part.file, image.cols, image.rows, {
				format = 32,
				quiet = 0,
				crop = { width = part.width, height = request.height },
			})
			waiting.ids[image.id] = true
		end
		p.refine_frame = refined
		p.displayed_request = request
		hooks.commit(s, refined, p.grid.lines, p.grid.marks)
	end)
	if not ok then
		p.awaiting = nil
		return hooks.fallback(s, tostring(err))
	end
	arm_read(s, p, waiting, hooks)
end

local function repaint_selection(s, p, hooks)
	local source, target = p.refined_source, s.frame
	if
		not source
		or source.worker ~= s.backend.refiner
		or (source.worker and (source.worker.closed or source.worker.exited))
	then
		return false
	end
	-- Coalesce drag events while keeping the last sharp frame on screen.
	if p.refine_job then
		return true
	end
	local request = vim.deepcopy(source.request)
	request.reuse, request.selections = true, nil
	if s.selection and s.selection.first then
		request.selections = selection.rectangles(target, s.selection.pages, s.selection.first, s.selection.last)
		local width = 0
		for _, part in ipairs(request.parts) do
			width = math.max(width, part.offset + part.width)
		end
		local motion_width = 0
		for _, part in ipairs(p.last_request.parts) do
			motion_width = math.max(motion_width, part.offset + part.width)
		end
		local sx, sy = target.cw * width / motion_width, target.ch * request.height / p.last_request.height
		for _, rect in ipairs(request.selections) do
			rect.x1, rect.x2 = rect.x1 * sx, rect.x2 * sx
			rect.y1, rect.y2 = rect.y1 * sy, rect.y2 * sy
		end
	end
	local files = refinement_files(s, p, request)
	local version, generation = s.selection and s.selection.version, p.generation
	local job
	job = s.backend:refine(request, function(result)
		if p.refine_job == job then
			p.refine_job = nil
		end
		local current = hooks.active(s)
			and not p.hidden
			and p.generation == generation
			and p.refined_source == source
			and s.frame == target
			and target.key == table.concat({ s.geometry_key, s.x, s.y }, ":")
			and target.surface == table.concat({ s.win, s.width, s.height, s.cw, s.ch, s.columns }, ":")
		if not current or result.code ~= 0 then
			for _, file in ipairs(files) do
				uv.fs_unlink(file)
			end
			if current and result.code ~= 0 then
				p.refined_source = nil
			end
			if hooks.active(s) then
				hooks.schedule(s, true)
			end
			return
		end
		-- Publish completed snapshots during a continuous drag. The read ACK
		-- schedules the newest range; discarding every older range would starve
		-- feedback when mouse events arrive faster than a full raster transfer.
		local frame = vim.tbl_extend("force", {}, target, { selection_version = version })
		publish_refined(s, p, hooks, frame, request, files, source.scale, result)
	end)
	p.refine_job = job
	return true
end

local function schedule_refinement(s, p, config, hooks)
	local frame = s.frame
	if (config.surface_refine_ms or 0) <= 0 then
		cancel_refinement(s)
		if frame then
			frame.refining = false
		end
		return
	end
	if
		not frame
		or frame.refined
		or p.refine_error
		or p.refine_job
		or p.refine_frame == frame
		or not p.last_request
	then
		return
	end
	local function eligible(target)
		return hooks.active(s)
			and not p.hidden
			and s.renderer == "surface"
			and target == s.frame
			and p.refine_frame == target
			and target.zoom == s.zoom
			and target.x == s.x
			and target.y == s.y
			and target.selection_version == (s.selection and s.selection.version)
			and not s.zoom_target
			and not s.pending
			and not p.animation
			and not p.running
			and not p.awaiting
	end
	p.refine_frame = frame
	frame.refining = true
	if not p.refine_timer then
		local timer = assert(uv.new_timer())
		p.refine_timer = timer
		p.refine_timeout = function()
			local target = p.refine_frame
			vim.schedule(function()
				if p.refine_timer ~= timer or not target then
					return
				end
				if not eligible(target) then
					if p.refine_frame == target then
						p.refine_frame = nil
						if hooks.active(s) then
							hooks.schedule(s, true)
						end
					end
					return
				end
				local worker = s.backend.refiner
				if worker and worker.closed and not worker.exited then
					-- Rapid hide/return can beat the old worker's exit callback.
					-- Retry after another idle interval without overlapping workers.
					p.refine_frame = nil
					hooks.schedule(s, true)
					return
				end
				local request, scale = refinement_request(p.last_request, config.surface_refine_scale or 1)
				local files = refinement_files(s, p, request)
				request.selection_cache = tostring(p.generation) .. ":" .. p.refine_sequence
				local job
				job = s.backend:refine(request, function(result)
					if p.refine_job == job then
						p.refine_job = nil
					end
					if not eligible(target) or result.code ~= 0 then
						for _, file in ipairs(files) do
							uv.fs_unlink(file)
						end
						if eligible(target) then
							p.refine_error = result.stderr or "Viewport refinement failed"
							target.refining = false
							if s.backend.refiner then
								s.backend.refiner:close()
							end
						elseif hooks.active(s) then
							if p.refine_frame == target then
								p.refine_frame = nil
							end
							hooks.schedule(s, true)
						end
						return
					end
					p.refined_source = { request = request, scale = scale, worker = s.backend.refiner }
					publish_refined(s, p, hooks, target, request, files, scale, result)
				end)
				p.refine_job = job
			end)
		end
	end
	p.refine_timer:start(config.surface_refine_ms, 0, p.refine_timeout)
end

function M.hide(s, closing)
	local p = s.surface_state
	if not p then
		return
	end
	cancel_refinement(s, true)
	if s.backend.refiner then
		s.backend.refiner:close()
	end
	p.generation = p.generation + 1
	p.timer, p.animation, p.render_x, p.render_y, p.hidden = nil, nil, nil, nil, true
	-- A buffer switch must still receive the outstanding file-read reply.
	-- Returning waits for that reply before starting another generation.
	local keep = {}
	if p.awaiting and not closing then
		for _, file in ipairs(p.awaiting.files) do
			keep[file] = true
		end
	end
	reclaim(p, keep)
	p.previous_files = nil
	if closing then
		p.awaiting = nil
	end
	if not p.awaiting then
		stop_response(p)
	end
	if p.job then
		p.job.kill()
	end
	for _, entry in ipairs(p.entries) do
		graphics.delete(entry.image)
	end
	for _, entry in ipairs(p.retiring) do
		graphics.delete(entry.image)
	end
	p.entries, p.retiring, p.surface, p.grid, p.last_request = {}, {}, nil, nil, nil
	p.displayed_request = nil
end

function M.stats(s)
	local count, bytes = 0, 0
	local p = s.surface_state
	local entries = p and vim.list_extend(vim.list_extend({}, p.entries), p.retiring) or {}
	for _, entry in ipairs(entries) do
		if entry.image and not entry.image.deleted then
			count = count + 1
			bytes = bytes + entry.image.width * entry.image.height * 4
		end
	end
	return count, bytes
end

function M.paint(s, config, hooks)
	local p = state(s)
	p.hidden = false
	if p.running or p.awaiting then
		return
	end
	if not p.response then
		p.response = vim.api.nvim_create_autocmd("TermResponse", {
			callback = function(event)
				local sequence = event.data and event.data.sequence or vim.v.termresponse
				local id = sequence and tonumber(sequence:match("i=(%d+)"))
				local waiting = p.awaiting
				if not waiting or not id or not waiting.ids[id] then
					return
				end
				local response = sequence:match(";(.+)$")
				if response ~= "OK" then
					stop_read_timer(p)
					p.awaiting = nil
					if p.hidden then
						reclaim(p, {})
						return stop_response(p)
					end
					return hooks.fallback(s, "Terminal image transfer failed: " .. tostring(response))
				end
				waiting.ids[id] = nil
				if not next(waiting.ids) then
					stop_read_timer(p)
					p.awaiting = nil
					local keep = {}
					if waiting.keep and not p.hidden then
						keep = waiting.keep
					elseif not p.hidden then
						for _, file in ipairs(waiting.files) do
							keep[file] = true
						end
						for _, file in ipairs(p.previous_files or {}) do
							keep[file] = true
						end
						p.previous_files = waiting.files
					end
					reclaim(p, keep)
					if p.hidden then
						stop_response(p)
					elseif hooks.active(s) then
						hooks.schedule(s, true)
					end
				end
			end,
		})
	end
	local surface = table.concat({ s.win, s.width, s.height, s.cw, s.ch, s.columns }, ":")
	local key = table.concat({ s.geometry_key, s.x, s.y }, ":")
	local selection_version = s.selection and s.selection.version
	-- A selection change must keep the settled PDF's pixel density. Only
	-- actual viewport movement returns to the smaller motion renderer.
	if
		not p.animation
		and s.frame
		and s.frame.key == key
		and s.frame.x == s.x
		and s.frame.y == s.y
		and p.surface == surface
	then
		if s.frame.selection_version == selection_version then
			s.input_ns = nil
			schedule_refinement(s, p, config, hooks)
			return
		elseif s.frame.refined and repaint_selection(s, p, hooks) then
			return
		end
	end
	cancel_refinement(s)
	local now = uv.hrtime()
	local function later(delay)
		if p.timer then
			return
		end
		local ticket, generation = {}, p.generation
		p.timer = ticket
		vim.defer_fn(function()
			if p.timer == ticket and p.generation == generation then
				p.timer = nil
				if hooks.active(s) then
					hooks.schedule(s, true)
				end
			end
		end, math.max(1, math.ceil(delay)))
	end
	if p.last_started then
		local elapsed = (now - p.last_started) / 1e6
		local interval = p.animation and 16 or 8
		-- Timer granularity must not turn an 8 ms input stream into a
		-- sequence of just-missed deadlines. ACK backpressure still applies.
		if elapsed < interval - (p.animation and 0 or 2) then
			return later(interval - elapsed)
		end
	end
	local x, y = s.x, s.y
	if p.animation then
		local animation = p.animation
		local fraction = math.min(1, math.max(0.1, (now - animation.started) / 1e6 / animation.duration))
		local progress = 1 - (1 - fraction) ^ 3
		x = animation.x + (s.x - animation.x) * progress
		y = animation.y + (s.y - animation.y) * progress
		if fraction == 1 then
			p.animation = nil
		end
	end
	key = table.concat({ s.geometry_key, x, y }, ":")
	if
		s.frame
		and s.frame.key == key
		and s.frame.x == x
		and s.frame.y == y
		and p.surface == surface
		and s.frame.selection_version == selection_version
	then
		s.input_ns = nil
		return
	end
	local width, height = math.floor(s.width * s.cw + 0.5), math.floor(s.height * s.ch + 0.5)
	if s.height > 256 or width > 8192 or height > 8192 or width * height > 8 * 1024 * 1024 then
		return hooks.fallback(s, "Viewport exceeds the Metal composition limits")
	end
	local request = { height = height, parts = {}, pages = {} }
	local desired = {}
	local sequence = p.sequence + 1
	for col = 0, s.width - 1, 256 do
		local columns = math.min(256, s.width - col)
		local left, right = math.floor(col * s.cw + 0.5), math.floor((col + columns) * s.cw + 0.5)
		local file = s.backend.dir .. "/surface-" .. (sequence % 2) .. "-" .. col .. ".rgba"
		p.files[file] = true
		request.parts[#request.parts + 1] = { width = right - left, offset = left, file = file }
		desired[#desired + 1] = { file = file, columns = columns, width = right - left }
	end
	-- Discard stripes left over from an older viewport shape before allocating
	-- the next frame. Only the previous confirmed frame and this request remain.
	local keep = {}
	for _, target in ipairs(desired) do
		keep[target.file] = true
	end
	for _, file in ipairs(p.previous_files or {}) do
		keep[file] = true
	end
	reclaim(p, keep)
	for n, page in ipairs(s.layout.pages) do
		if page.top < y + s.height and page.top + page.height > y then
			local info = s.pages[n]
			-- Ordinary reading scales keep one sharp source while the viewport
			-- moves. Smaller pages use a lower level to bound multi-page views.
			local edge = math.max(page.pixel_width, page.pixel_height)
			local level = math.min(
				config.max_dimension,
				4096,
				s.zoom >= 0.5 and 4096 or 2 ^ math.ceil(math.log(edge) / math.log(2))
			)
			local ratio = level / math.max(info.width, info.height)
			request.pages[#request.pages + 1] = {
				page = n,
				px = math.max(1, math.floor(info.width * ratio + 0.5)),
				py = math.max(1, math.floor(info.height * ratio + 0.5)),
				width = page.pixel_width,
				height = page.pixel_height,
				left = ((math.max(s.width, s.layout.width) - page.width) / 2 - x) * s.cw,
				top = (page.top - y) * s.ch,
			}
		end
	end
	if #request.pages == 0 or #request.pages > 16 then
		return hooks.fallback(s, "Visible page count exceeds the Metal composition limits")
	end
	p.running, p.sequence, p.last_started = true, sequence, now
	p.render_x, p.render_y = x, y
	local generation, input_ns = p.generation, s.input_ns
	local frame = {
		key = key,
		selection_version = selection_version,
		layout = s.layout,
		width = s.width,
		height = s.height,
		cw = s.cw,
		ch = s.ch,
		surface = surface,
		zoom = s.zoom,
		x = x,
		y = y,
		compact = false,
		keys = {},
		resizes = {},
		refining = (config.surface_refine_ms or 0) > 0 and not p.refine_error or false,
	}
	if s.selection and s.selection.first then
		request.selections = selection.rectangles(frame, s.selection.pages, s.selection.first, s.selection.last)
		for _, rect in ipairs(request.selections) do
			rect.x1, rect.x2 = rect.x1 * s.cw, rect.x2 * s.cw
			rect.y1, rect.y2 = rect.y1 * s.ch, rect.y2 * s.ch
		end
	end
	p.job = s.backend:compose(request, function(result)
		p.running, p.job, p.render_x, p.render_y = false, nil, nil, nil
		if not hooks.active(s) or p.generation ~= generation then
			for _, part in ipairs(request.parts) do
				uv.fs_unlink(part.file)
				p.files[part.file] = nil
			end
			if hooks.active(s) then
				hooks.schedule(s, true)
			end
			return
		end
		if surface ~= table.concat({ s.win, s.width, s.height, s.cw, s.ch, s.columns }, ":") then
			for _, part in ipairs(request.parts) do
				uv.fs_unlink(part.file)
				p.files[part.file] = nil
			end
			return hooks.schedule(s, true)
		end
		if result.code ~= 0 then
			for _, part in ipairs(request.parts) do
				uv.fs_unlink(part.file)
				p.files[part.file] = nil
			end
			return hooks.fallback(s, result.stderr or "Viewport composition failed")
		end
		local waiting = { ids = {}, files = {} }
		p.awaiting = waiting
		local ok, err = pcall(graphics.synchronized, function()
			local grid = p.surface == surface and p.grid
			local rebuild = not grid
			if rebuild then
				grid = { lines = {}, marks = {} }
				for row = 0, s.height - 1 do
					grid.lines[row + 1] = ""
					grid.marks[row + 1] = { row = row, chunks = {} }
				end
			end
			for index, target in ipairs(desired) do
				local entry = p.entries[index]
				local raster = { format = 32, quiet = 0, crop = { width = target.width, height = height } }
				if not entry then
					entry = { image = graphics.upload(target.file, target.columns, s.height, "surface", raster) }
					p.entries[index] = entry
				else
					graphics.replace(entry.image, target.file, target.columns, s.height, raster)
				end
				waiting.ids[entry.image.id] = true
				waiting.files[#waiting.files + 1] = target.file
				if rebuild then
					for row = 0, s.height - 1 do
						local chunks = grid.marks[row + 1].chunks
						chunks[#chunks + 1] = graphics.viewport_row(entry.image, row, 0, target.columns, false)
					end
				end
			end
			p.surface, p.grid, p.last_request = surface, grid, request
			p.displayed_request = request
			hooks.status(s, false)
			local latest_input = s.input_ns
			s.input_ns = input_ns
			hooks.commit(s, frame, grid.lines, grid.marks)
			if latest_input ~= input_ns then
				s.input_ns = latest_input
			end
			frame.compose_ms = result.render_ms
			-- Shrinking the viewport can remove a whole stripe. Retire it only
			-- after its replacement grid has reached the terminal.
			local retired = {}
			while #p.entries > #desired do
				local entry = table.remove(p.entries)
				retired[#retired + 1] = entry
				p.retiring[#p.retiring + 1] = entry
			end
			if #retired > 0 then
				vim.defer_fn(function()
					if p.generation ~= generation then
						return
					end
					for _, entry in ipairs(retired) do
						graphics.delete(entry.image)
					end
					p.retiring = vim.tbl_filter(function(entry)
						return not entry.image.deleted
					end, p.retiring)
				end, 40)
			end
		end)
		if not ok then
			p.awaiting = nil
			return hooks.fallback(s, tostring(err))
		end
		arm_read(s, p, waiting, hooks)
		if
			frame.zoom ~= s.zoom
			or frame.x ~= s.x
			or frame.y ~= s.y
			or frame.selection_version ~= (s.selection and s.selection.version)
		then
			if p.animation then
				later(16 - (uv.hrtime() - p.last_started) / 1e6)
			else
				hooks.schedule(s, true)
			end
		end
	end)
end
return M
