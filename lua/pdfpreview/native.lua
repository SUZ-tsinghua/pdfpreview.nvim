local M = {}
M.protocol = 3
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")

function M.executable(opts)
	return opts.native_renderer or (root .. "/.build/pdfpreview-native")
end

function M.available(opts)
	return vim.fn.has("mac") == 1 and vim.fn.executable(M.executable(opts)) == 1
end

function M.new(path, opts, on_exit)
	local self = { queue = {}, serial = 0, closed = false, exited = false, stderr = "", buffer = "" }
	local function finish(job, result)
		if job.done then
			return
		end
		job.done = true
		-- Callbacks are always deferred, including queued cancellation and spawn failure.
		vim.schedule(function()
			job.callback(result)
		end)
	end
	local function fail(reason)
		self.error = reason
		if self.process then
			pcall(self.process.kill, self.process, 15)
		end
	end
	function self:pump()
		if self.running or self.closed or self.error or not self.process then
			return
		end
		while #self.queue > 0 do
			local job = table.remove(self.queue, 1)
			if not job.done then
				self.running = job
				local ok, err = pcall(self.process.write, self.process, vim.json.encode(job.request) .. "\n")
				if not ok then
					fail(tostring(err))
				end
				return
			end
		end
	end
	local function receive(data)
		self.buffer = self.buffer .. data
		while true do
			local ending = self.buffer:find("\n", 1, true)
			if not ending then
				return
			end
			local line = self.buffer:sub(1, ending - 1)
			self.buffer = self.buffer:sub(ending + 1)
			local ok, result = pcall(vim.json.decode, line)
			local job = self.running
			if not ok or type(result) ~= "table" or not job or result.id ~= job.request.id then
				fail("Invalid native renderer response")
				return
			end
			self.running = nil
			self.cache_bytes = result.cache_bytes or 0
			self.gpu_cache_bytes = result.gpu_cache_bytes or 0
			self.output_cache_bytes = result.output_cache_bytes or 0
			self.selection_cache_bytes = result.selection_cache_bytes or 0
			if job.request.action == "info" and result.protocol ~= M.protocol then
				result.error = "Native helper protocol mismatch; run make native in the plugin directory"
			end
			if result.surface ~= nil then
				self.has_surface = result.surface
			end
			finish(job, {
				code = result.error and 1 or 0,
				stderr = result.error,
				render_ms = result.render_ms,
				pages = result.pages,
			})
			self:pump()
		end
	end
	local function exited(result)
		self.exited = true
		local error = self.error or (self.stderr ~= "" and self.stderr) or "Native renderer exited"
		if self.running then
			finish(self.running, { code = -1, stderr = error })
			self.running = nil
		end
		for _, job in ipairs(self.queue) do
			finish(job, { code = -1, stderr = error })
		end
		self.queue = {}
		self.error = error
		on_exit(result)
	end
	local ok, process = pcall(vim.system, { M.executable(opts), path }, {
		stdin = true,
		stdout = function(err, data)
			vim.schedule(function()
				if err then
					fail(tostring(err))
				elseif data then
					receive(data)
				end
			end)
		end,
		stderr = function(_, data)
			if data then
				self.stderr = (self.stderr .. data):sub(-2000)
			end
		end,
	}, function(result)
		vim.schedule(function()
			exited(result)
		end)
	end)
	if ok then
		self.process = process
	else
		self.error = tostring(process)
		vim.schedule(function()
			exited({ code = -1 })
		end)
	end
	function self:request(entry, callback)
		self.serial = self.serial + 1
		local payload
		if entry.refine then
			payload = vim.tbl_extend("force", entry.refine, { id = self.serial, action = "refine" })
		elseif entry.compose then
			payload = vim.tbl_extend("force", entry.compose, { id = self.serial, action = "compose" })
		elseif entry.info then
			payload = { id = self.serial, action = "info" }
		else
			local crop = entry.crop or { x = 0, y = 0, width = entry.px, height = entry.py }
			payload = {
				id = self.serial,
				page = entry.page,
				px = entry.px,
				py = entry.py,
				format = entry.format,
				x = crop.x,
				y = crop.y,
				width = crop.width,
				height = crop.height,
				file = entry.file,
				-- Reusable resolution levels and capped renders share source
				-- pixels. Uncached crop requests draw only their visible region.
				cache = entry.reuse_pixels or math.max(entry.px, entry.py) >= (opts.max_dimension or 4096),
			}
		end
		local job = { callback = callback, request = payload }
		-- A Quartz draw cannot be interrupted safely. Only its current crop may
		-- finish; queued obsolete crops are discarded without rasterization.
		job.kill = function()
			if self.running ~= job then
				finish(job, { code = 143, stderr = "Cancelled" })
			end
		end
		if self.closed or self.exited then
			finish(job, { code = -1, stderr = self.error or "Native renderer closed" })
		else
			self.queue[#self.queue + 1] = job
			self:pump()
		end
		return job
	end
	function self:close()
		if self.closed then
			return
		end
		self.closed = true
		for _, job in ipairs(self.queue) do
			finish(job, { code = 143, stderr = "Cancelled" })
		end
		self.queue = {}
		if self.process and not self.exited then
			pcall(self.process.kill, self.process, 15)
		end
	end
	return self
end

return M
