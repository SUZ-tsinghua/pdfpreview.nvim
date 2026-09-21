local M = {}
local uv = vim.uv
local function pixel_key(n, px, py, crop)
	return table.concat({ n, "pixels", px, py, crop.x, crop.y, crop.width, crop.height }, ":")
end

function M.parse_info(text)
	local count = tonumber(text:match("Pages:%s*(%d+)"))
	if not count or count < 1 then
		return nil, "pdfinfo returned no pages"
	end
	local default_w, default_h = text:match("Page size:%s*([%d%.]+)%s*x%s*([%d%.]+)")
	local pages = {}
	for line in text:gmatch("[^\r\n]+") do
		local n, w, h = line:match("Page%s+(%d+)%s+size:%s*([%d%.]+)%s*x%s*([%d%.]+)")
		if n then
			pages[tonumber(n)] = { width = tonumber(w), height = tonumber(h) }
		end
	end
	for line in text:gmatch("[^\r\n]+") do
		local n, rot = line:match("Page%s+(%d+)%s+rot:%s*(%-?%d+)")
		if n and pages[tonumber(n)] and tonumber(rot) % 180 ~= 0 then
			local p = pages[tonumber(n)]
			p.width, p.height = p.height, p.width
		end
	end
	for n = 1, count do
		pages[n] = pages[n] or (default_w and { width = tonumber(default_w), height = tonumber(default_h) })
		if not pages[n] or pages[n].width <= 0 or pages[n].height <= 0 then
			return nil, "Missing page geometry for page " .. n
		end
	end
	return pages
end

function M.new(path, opts, changed)
	local native = require("pdfpreview.native")
	local self = {
		path = path,
		opts = opts,
		changed = changed,
		jobs = {},
		entries = {},
		wanted = {},
		retained = {},
		prefetch = {},
		retiring = {},
		rasterizer = opts.rasterizer ~= "poppler" and native.available(opts) and "native" or "poppler",
		active = 0,
		closed = false,
		tick = 0,
		dir = vim.fn.tempname() .. "-pdfpreview",
	}
	vim.fn.mkdir(self.dir, "p", 448)
	local function release(entry)
		if entry.image then
			require("pdfpreview.graphics").delete(entry.image)
			entry.image = nil
		end
		uv.fs_unlink(entry.file)
	end
	local function reap()
		local now, remaining, deadline = uv.hrtime(), {}, nil
		local freed_image = false
		for _, entry in ipairs(self.retiring) do
			if entry.retire_ns <= now then
				freed_image = freed_image or entry.image ~= nil
				release(entry)
			else
				remaining[#remaining + 1] = entry
				deadline = math.min(deadline or entry.retire_ns, entry.retire_ns)
			end
		end
		self.retiring = remaining
		if freed_image and not self.closed then
			self.changed()
		end
		if deadline then
			local ticket = {}
			self.retire_timer = ticket
			vim.defer_fn(function()
				if self.retire_timer == ticket then
					self.retire_timer = nil
					reap()
				end
			end, math.max(1, math.ceil((deadline - now) / 1e6)))
		end
	end
	local function retire(entry)
		if not entry.image or (entry.image_until_ns or 0) <= uv.hrtime() then
			return release(entry)
		end
		-- Only recently displayed images need compositor grace. Speculative
		-- uploads and already expired frames can release their storage now.
		entry.retire_ns = entry.image_until_ns
		self.retiring[#self.retiring + 1] = entry
		if not self.retire_timer then
			reap()
		end
	end
	local function cleanup()
		if
			self.closed
			and not next(self.jobs)
			and (not self.native or self.native.exited)
			and (not self.refiner or self.refiner.exited)
		then
			vim.fn.delete(self.dir, "rf")
		end
	end
	local function command(args, cb)
		local proc
		local ok, err = pcall(function()
			proc = vim.system(args, { text = true, env = { LC_ALL = "C" } }, function(result)
				vim.schedule(function()
					self.jobs[proc] = nil
					cb(result)
					cleanup()
				end)
			end)
			self.jobs[proc] = true
		end)
		if not ok then
			vim.schedule(function()
				cb({ code = -1, stderr = tostring(err) })
				cleanup()
			end)
		end
		return proc
	end
	local function native_command(entry, cb)
		if not self.native then
			self.native = native.new(self.path, self.opts, function()
				if not self.closed and self.opts.rasterizer == "auto" then
					self.rasterizer = "poppler"
				end
				cleanup()
			end)
		end
		local job
		job = self.native:request(entry, function(result)
			self.jobs[job] = nil
			result.retry = self.rasterizer == "poppler"
			cb(result)
			cleanup()
		end)
		self.jobs[job] = true
		return job
	end

	local function poppler_info(cb)
		command({ self.opts.pdfinfo, self.path }, function(first)
			if self.closed then
				return
			end
			if first.code ~= 0 then
				return cb(nil, first.stderr)
			end
			local count = tonumber(first.stdout:match("Pages:%s*(%d+)"))
			if not count or count > 100000 then
				return cb(nil, "Invalid or excessive PDF page count")
			end
			command({ self.opts.pdfinfo, "-f", "1", "-l", tostring(count), "-box", self.path }, function(result)
				if self.closed then
					return
				end
				if result.code ~= 0 then
					return cb(nil, result.stderr)
				end
				local pages, err = M.parse_info(result.stdout)
				cb(pages, err)
			end)
		end)
	end

	function self:info(cb)
		if self.rasterizer ~= "native" then
			return poppler_info(cb)
		end
		-- Geometry and crops share a document worker and protocol version.
		native_command({ info = true }, function(result)
			if self.closed then
				return
			end
			local pages = result.pages
			local valid = result.code == 0 and type(pages) == "table" and #pages > 0 and #pages <= 100000
			for _, page in ipairs(valid and pages or {}) do
				valid = valid
					and type(page) == "table"
					and type(page.width) == "number"
					and type(page.height) == "number"
				valid = valid
					and page.width > 0
					and page.width < math.huge
					and page.height > 0
					and page.height < math.huge
			end
			if not valid then
				self.native:close()
				if self.opts.rasterizer == "auto" then
					self.rasterizer = "poppler"
					return poppler_info(cb)
				end
				return cb(nil, result.stderr or "Invalid native page geometry")
			end
			cb(pages)
		end)
	end

	function self:compose(request, callback)
		if self.closed or not self.native or not self.native.has_surface then
			vim.schedule(function()
				callback({ code = 1, stderr = "Metal viewport composition is unavailable" })
			end)
			return
		end
		self.active = self.active + 1
		local job
		job = self.native:request({ compose = request }, function(result)
			self.active = self.active - 1
			self.jobs[job] = nil
			callback(result)
			cleanup()
		end)
		self.jobs[job] = true
		return job
	end

	function self:refine(request, callback)
		-- A separate document worker keeps an expensive vector redraw from
		-- blocking cached Metal motion when input resumes halfway through it.
		assert(not self.closed and not self.refinement_active, "Only one visible refinement may run")
		if not self.refiner or self.refiner.exited then
			self.refiner = native.new(self.path, self.opts, cleanup)
		end
		local worker, job = self.refiner, nil
		self.refinement_active = true
		job = worker:request({ refine = request }, function(result)
			self.jobs[job], self.refinement_active = nil, nil
			callback(result)
			cleanup()
		end)
		job.kill = function()
			-- This worker has no motion requests or shared source textures.
			worker:close()
		end
		self.jobs[job] = true
		return job
	end

	function self:key(n, p, cw, ch, reuse)
		-- Preserve the PDF's pixel aspect ratio before terminal-cell rounding.
		-- Above the raster cap, different zooms then share one source resolution.
		local px = math.max(1, p.pixel_width or math.ceil(p.width * cw))
		local py = math.max(1, p.pixel_height or math.ceil(p.height * ch))
		local reduction = math.min(1, self.opts.max_dimension / math.max(px, py))
		local level
		if reuse then
			local edge = math.max(px, py)
			-- Quarter-octave levels avoid oversampling the visible pixels,
			-- reducing transient terminal memory while source generations overlap.
			local raster_level = 2 ^ (math.floor(4 * math.log(edge) / math.log(2)) / 4)
			level = raster_level * 2 ^ 0.25
			reduction = math.min(raster_level, self.opts.max_dimension) / edge
		end
		px, py = math.max(1, math.floor(px * reduction + 0.5)), math.max(1, math.floor(py * reduction + 0.5))
		return table.concat({ n, p.width, p.height, px, py }, ":"), px, py, level
	end

	function self:request(n, p, cw, ch, clip, speculative)
		local key, px, py = self:key(n, p, cw, ch, clip and clip.source ~= nil)
		local crop
		if clip then
			local x, y = math.floor(clip.left * px / p.width), math.floor(clip.top * py / p.height)
			local right = math.floor((clip.left + clip.width) * px / p.width)
			local bottom = math.floor((clip.top + clip.height) * py / p.height)
			crop = { x = x, y = y, width = math.max(1, right - x), height = math.max(1, bottom - y) }
			-- At tiny raster caps, differently sized cell tiles can project to
			-- the same source pixel. Cell-aligned fallback tiles need distinct keys.
			key = key .. ":" .. table.concat({ x, y, crop.width, crop.height, clip.width, clip.height }, ":")
		end
		if clip and clip.source then
			crop = clip.source
			key = pixel_key(n, px, py, crop)
		end
		local e = self.entries[key]
		self.tick = self.tick + 1
		if not e then
			-- A scale can be requested again while its previous images retire.
			-- Unique generations prevent delayed cleanup unlinking a new raster.
			local stem = self.dir .. "/" .. key:gsub(":", "-") .. "-" .. self.tick
			local raw = self.rasterizer == "native" and crop ~= nil
			e = {
				key = key,
				page = n,
				width = clip and clip.width or p.width,
				height = clip and clip.height or p.height,
				crop = crop,
				px = px,
				py = py,
				file = stem .. (raw and ".rgba" or ".png"),
				format = raw and 32 or 100,
				reuse_pixels = clip and clip.source ~= nil,
				stem = stem,
				status = "queued",
			}
			self.entries[key] = e
		end
		if clip and not speculative then
			e.width, e.height = clip.width, clip.height
		end
		e.used = self.tick
		self.wanted[key] = true
		return e
	end

	-- Inspect existing pixels without changing demand or scheduling more work.
	function self:cached_tile(n, px, py, crop)
		return self.entries[pixel_key(n, px, py, crop)]
	end

	function self:image_bytes()
		local total = 0
		for _, collection in ipairs({ self.entries, self.retiring }) do
			for _, e in pairs(collection) do
				if e.image and not e.image.deleted then
					total = total + e.image.width * e.image.height * 4
				end
			end
		end
		return total
	end

	function self:image_size(e)
		return e.crop and e.crop.width * e.crop.height * 4 or e.px * e.py * 4
	end

	function self:room_for_image(e)
		return self:image_bytes() + self:image_size(e) <= self.opts.image_cache_bytes
	end

	-- Called inside the frame transaction. Raster files remain available for
	-- later reuse; only terminal storage is reclaimed here.
	function self:set_retained(keys)
		local until_ns = uv.hrtime() + 40 * 1e6
		for key in pairs(self.retained) do
			local entry = self.entries[key]
			if not keys[key] and entry and entry.image then
				entry.image_until_ns = until_ns
			end
		end
		self.retained = keys
	end

	function self:reserve_images(keys)
		local missing, candidates, deadline = 0, {}, nil
		local now = uv.hrtime()
		for key in pairs(keys) do
			local e = self.entries[key]
			if e and e.status == "ready" and not e.image then
				missing = missing + self:image_size(e)
			end
		end
		-- A warm frame allocates nothing. Retirement must never delay its
		-- scroll or placement resize merely because the working set is large.
		if missing == 0 then
			return true
		end
		local total = self:image_bytes() + missing
		for _, collection in ipairs({ self.entries, self.retiring }) do
			for _, e in pairs(collection) do
				if e.image and not e.image.deleted and not (keys[e.key] and self.entries[e.key] == e) then
					local until_ns = math.max(e.image_until_ns or 0, e.retire_ns or 0)
					if until_ns > now then
						deadline = math.min(deadline or until_ns, until_ns)
					else
						candidates[#candidates + 1] = e
					end
				end
			end
		end
		table.sort(candidates, function(a, b)
			return (a.used or 0) < (b.used or 0)
		end)
		for _, e in ipairs(candidates) do
			if total <= self.opts.image_cache_bytes then
				break
			end
			total = total - e.image.width * e.image.height * 4
			require("pdfpreview.graphics").delete(e.image)
			e.image = nil
		end
		if total > self.opts.image_cache_bytes and deadline then
			return false, math.max(1, math.ceil((deadline - now) / 1e6))
		end
		return true
	end

	function self:visible_pending()
		for key in pairs(self.wanted) do
			local entry = self.entries[key]
			if not self.prefetch[key] and entry and entry.status ~= "ready" and entry.status ~= "error" then
				return true
			end
		end
		return false
	end

	function self:prune()
		local candidates, count = {}, 0
		for key, e in pairs(self.entries) do
			count = count + 1
			if
				not self.wanted[key]
				and not self.retained[key]
				and e.status ~= "running"
				and e.status ~= "cancelling"
			then
				candidates[#candidates + 1] = e
			end
		end
		table.sort(candidates, function(a, b)
			return a.used < b.used
		end)
		for _, e in ipairs(candidates) do
			if count <= self.opts.cache_pages then
				break
			end
			retire(e)
			self.entries[e.key] = nil
			count = count - 1
		end
	end

	function self:cancel_stale()
		local visible_waiting = false
		for key, e in pairs(self.entries) do
			if self.wanted[key] and not self.prefetch[key] and e.status == "queued" then
				visible_waiting = true
			end
		end
		for key, e in pairs(self.entries) do
			if not self.wanted[key] then
				if e.status == "queued" then
					self.entries[key] = nil
				end
			end
			if e.status == "running" and (not self.wanted[key] or (visible_waiting and self.prefetch[key])) then
				e.status = "cancelling"
				if e.process then
					pcall(e.process.kill, e.process, 15)
				end
			end
		end
	end

	function self:pump()
		if self.closed then
			return
		end
		self:cancel_stale()
		local todo = {}
		for key, e in pairs(self.entries) do
			if self.wanted[key] and e.status == "queued" then
				todo[#todo + 1] = e
			end
		end
		table.sort(todo, function(a, b)
			if (not self.prefetch[a.key]) ~= not self.prefetch[b.key] then
				return not self.prefetch[a.key]
			end
			return a.used < b.used
		end)
		for _, e in ipairs(todo) do
			if self.active >= self.opts.jobs then
				break
			end
			self.active = self.active + 1
			e.status = "running"
			if self.rasterizer == "poppler" and e.format ~= 100 then
				uv.fs_unlink(e.file)
				e.file, e.format = e.stem .. ".png", 100
			end
			local args = {
				self.opts.pdftoppm,
				"-f",
				tostring(e.page),
				"-l",
				tostring(e.page),
				"-singlefile",
				"-cropbox",
				"-scale-dimension-before-rotation",
				"-png",
				"-scale-to-x",
				tostring(e.px),
				"-scale-to-y",
				tostring(e.py),
				self.path,
				e.stem,
			}
			if e.crop then
				local c = e.crop
				local extra =
					{ "-x", tostring(c.x), "-y", tostring(c.y), "-W", tostring(c.width), "-H", tostring(c.height) }
				for i = #extra, 1, -1 do
					table.insert(args, 2, extra[i])
				end
			end
			local function rendered(result)
				self.active = self.active - 1
				e.process = nil
				if self.closed then
					return
				end
				if e.status == "cancelling" then
					-- Never reuse partial output, even when the process exited successfully
					-- before its termination signal arrived. A newer request may want it again.
					uv.fs_unlink(e.file)
					e.status = "queued"
					if not self.wanted[e.key] then
						self.entries[e.key] = nil
					end
				elseif result.retry then
					uv.fs_unlink(e.file)
					e.file, e.format = e.stem .. ".png", 100
					e.status = "queued"
				elseif result.code == 0 and uv.fs_stat(e.file) then
					e.status = "ready"
					e.render_ms = result.render_ms
				else
					e.status = "error"
					e.error = (result.stderr or "PDF rendering failed"):sub(1, 1000)
				end
				self:prune()
				if self.wanted[e.key] and e.status ~= "queued" then
					self.changed()
				end
				self:pump()
			end
			e.process = self.rasterizer == "native" and native_command(e, rendered) or command(args, rendered)
		end
		self:prune()
	end

	function self:hide()
		if self.refiner then
			self.refiner:close()
		end
		self.retire_timer = nil
		for _, entry in ipairs(self.retiring) do
			release(entry)
		end
		self.retiring = {}
		self.wanted = {}
		self.retained = {}
		self:cancel_stale()
		for _, e in pairs(self.entries) do
			if e.image then
				require("pdfpreview.graphics").delete(e.image)
				e.image = nil
			end
		end
		self:prune()
	end

	function self:close()
		if self.closed then
			return
		end
		self.closed = true
		self:hide()
		for proc in pairs(self.jobs) do
			pcall(proc.kill, proc, 15)
		end
		if self.refiner then
			self.refiner:close()
		end
		if self.native then
			self.native:close()
		end
		-- Keep output paths alive until every subprocess has actually exited.
		cleanup()
	end
	return self
end
return M
