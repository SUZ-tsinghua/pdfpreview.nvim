-- Controlled asynchronous motion and refinement; no Metal device required.

-- Motion, backpressure and output ownership
do
	vim.opt.rtp:prepend(vim.fn.getcwd())
	vim.o.termguicolors = true
	local surface = require("pdfpreview.surface")
	local graphics = require("pdfpreview.graphics")
	local packets, queued, timers = {}, {}, {}
	graphics.sink = function(data)
		packets[#packets + 1] = data
	end
	local original_defer, original_clock = vim.defer_fn, vim.uv.hrtime
	local now = 1000000000
	vim.uv.hrtime = function()
		return now
	end
	vim.defer_fn = function(callback, delay)
		timers[#timers + 1] = { callback = callback, delay = delay }
	end
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local active, scheduled, fallback = true, 0, nil
	local s = {
		win = 1,
		width = 8,
		height = 4,
		cw = 2,
		ch = 2,
		columns = 300,
		zoom = 1,
		x = 0,
		y = 0,
		geometry_key = "test",
		renderer = "surface",
		pages = { { width = 600, height = 800 } },
		layout = { width = 8, pages = { { top = 0, width = 8, height = 16, pixel_width = 16, pixel_height = 32 } } },
	}
	s.backend = {
		dir = dir,
		compose = function(_, request, callback)
			local job = { kill = function() end }
			queued[#queued + 1] = { request = request, callback = callback, job = job }
			return job
		end,
	}
	local hooks = {
		active = function()
			return active
		end,
		schedule = function()
			scheduled = scheduled + 1
		end,
		status = function() end,
		fallback = function(_, reason)
			fallback = reason
		end,
		commit = function(_, frame)
			s.frame = frame
		end,
	}
	local config = { max_dimension = 4096 }
	local function paint()
		now = now + 20000000
		surface.paint(s, config, hooks)
	end
	local function finish()
		local job = assert(table.remove(queued, 1))
		for _, part in ipairs(job.request.parts) do
			local fd = assert(io.open(part.file, "wb"))
			fd:write(string.rep("\255", part.width * job.request.height * 4))
			fd:close()
		end
		job.callback({ code = 0, render_ms = 1 })
		return job.request
	end
	local function acknowledge(id, response)
		vim.api.nvim_exec_autocmds(
			"TermResponse",
			{ data = { sequence = "\27_Gi=" .. id .. ";" .. (response or "OK") } }
		)
	end
	paint()
	local first = finish()
	local id = s.surface_state.entries[1].image.id
	assert(
		s.surface_state.awaiting and vim.uv.fs_stat(first.parts[1].file),
		"Output survives until the terminal reads it"
	)
	paint()
	assert(#queued == 0, "Unacknowledged output applies backpressure")
	acknowledge(id)
	assert(
		not s.surface_state.awaiting and vim.uv.fs_stat(first.parts[1].file),
		"Confirmed output remains available for reuse"
	)
	local read_timer = assert(s.surface_state.read_timer)
	assert(not read_timer:is_active(), "A completed read stops its watchdog immediately")
	local idle_timers, idle_packets = #timers, #packets
	now = s.surface_state.last_started + 5000000
	surface.paint(s, config, hooks)
	assert(
		#timers == idle_timers and #packets == idle_packets and #queued == 0,
		"An early acknowledgment of the current target needs no pacing timer or additional work"
	)
	s.y = 0.5
	paint()
	finish()
	assert(s.surface_state.entries[1].image.id == id, "New pixels retain the same placement identifier")
	local replacement
	for _, packet in ipairs(packets) do
		if packet:find("a=T", 1, true) then
			replacement = packet
		end
	end
	assert(replacement and replacement:find("q=0", 1, true), "Replacement requests confirmation")
	acknowledge(id)
	assert(s.surface_state.read_timer == read_timer, "Consecutive frames reuse one watchdog")
	-- A timeout may already be queued on the main loop when its ACK arrives.
	s.y = s.y + 0.1
	paint()
	finish()
	s.surface_state.read_timeout()
	acknowledge(id)
	s.y = s.y + 0.1
	paint()
	finish()
	local newer_read = s.surface_state.awaiting
	vim.wait(10, function()
		return false
	end, 1)
	assert(not fallback and s.surface_state.awaiting == newer_read, "A stale timeout cannot abandon the newer read")
	acknowledge(id)
	s.width, s.cw = 300, 1
	paint()
	finish()
	local other = s.surface_state.entries[2].image.id
	acknowledge(id)
	assert(
		s.surface_state.awaiting and s.surface_state.read_timer:is_active(),
		"Every viewport stripe must finish before its watchdog stops"
	)
	acknowledge(other)
	assert(not s.surface_state.awaiting)
	s.width = 8
	paint()
	finish()
	acknowledge(id)
	assert(#s.surface_state.retiring == 1, "Removed stripes keep their display grace period")
	surface.hide(s)
	assert(
		select(1, surface.stats(s)) == 0 and #s.surface_state.retiring == 0,
		"Hide drains current and retiring images"
	)
	assert(not s.surface_state.read_timer and read_timer:is_closing(), "An idle hidden reader releases its watchdog")
	local count = #packets
	for _, timer in ipairs(timers) do
		timer.callback()
	end
	assert(#packets == count, "Retirement and acknowledgment timers do nothing after hide")
	s.frame = nil
	paint()
	active = false
	surface.hide(s)
	active = true
	local before = scheduled
	local obsolete = finish()
	assert(
		scheduled > before and not vim.uv.fs_stat(obsolete.parts[1].file),
		"Returning during an old job schedules a fresh frame and removes stale pixels"
	)
	paint()
	finish()
	id = s.surface_state.entries[1].image.id
	acknowledge(id)
	local start = s.frame.y
	surface.scroll(s, 40)
	s.y = start + 1
	paint()
	finish()
	acknowledge(id)
	assert(s.frame.y > start and s.frame.y < s.y, "Scrolling produces a fractional intermediate position")
	now = now + 50000000
	paint()
	finish()
	acknowledge(id)
	assert(s.frame.y == s.y, "Animation reaches the exact requested position")
	s.y = s.y + 1
	paint()
	finish()
	acknowledge(id, "ERROR")
	assert(fallback and not s.surface_state.awaiting, "A failed transfer exits the surface path")
	surface.hide(s)
	fallback = nil
	s.y = s.y + 1
	paint()
	local hidden = finish()
	id = s.surface_state.entries[1].image.id
	surface.hide(s)
	assert(s.surface_state.awaiting and s.surface_state.response, "Hide retains the pending file-read reply")
	assert(vim.uv.fs_stat(hidden.parts[1].file), "An unconfirmed file survives hide")
	acknowledge(id)
	assert(not s.surface_state.awaiting and not s.surface_state.response, "Hidden reply removes its listener")
	assert(not vim.uv.fs_stat(hidden.parts[1].file), "Hidden acknowledged output is reclaimed")
	s.frame = nil
	paint()
	finish()
	s.surface_state.read_timeout()
	surface.hide(s, true)
	vim.wait(10, function()
		return false
	end, 1)
	assert(
		not s.surface_state.awaiting and not s.surface_state.response and not s.surface_state.read_timer,
		"Close cancels pending replies and queued watchdog callbacks"
	)
	s.frame = nil
	paint()
	finish()
	fallback = nil
	assert(s.surface_state.read_timer:is_active(), "An unconfirmed read has an armed watchdog")
	assert(
		vim.wait(1400, function()
			return fallback ~= nil
		end, 5),
		"The armed watchdog expires on the main loop"
	)
	assert(
		fallback and fallback:find("timed out", 1, true) and not s.surface_state.awaiting,
		"A missing reply exits the surface path"
	)
	surface.hide(s, true)
	-- Retain two generations across striped output and geometry changes.
	s.frame = nil
	s.width = 300
	paint()
	local retained_first = finish()
	local function acknowledge_all()
		local ids = vim.tbl_keys(s.surface_state.awaiting.ids)
		for _, pending_id in ipairs(ids) do
			acknowledge(pending_id)
		end
	end
	acknowledge_all()
	assert(#vim.fn.glob(dir .. "/surface-*.rgba", false, true) == 2, "Confirmed stripes remain reusable")
	s.y = s.y + 0.1
	paint()
	local retained_second = finish()
	paint()
	assert(#queued == 0, "Retained slots cannot be overwritten before their read replies")
	acknowledge_all()
	assert(#vim.fn.glob(dir .. "/surface-*.rgba", false, true) == 4, "Two striped generations stay bounded")
	s.width = 8
	s.y = s.y + 0.1
	paint()
	assert(not vim.uv.fs_stat(retained_first.parts[2].file), "Obsolete older stripes are removed before allocation")
	assert(vim.uv.fs_stat(retained_second.parts[2].file), "The previous confirmed generation remains available")
	finish()
	acknowledge_all()
	s.y = s.y + 0.1
	paint()
	finish()
	acknowledge_all()
	assert(#vim.fn.glob(dir .. "/surface-*.rgba", false, true) == 2, "Resize returns to two current-sized slots")
	-- Allow timer jitter without lifting the single-compose/read backpressure.
	s.y = s.y + 0.1
	now = s.surface_state.last_started + 7000000
	surface.paint(s, config, hooks)
	assert(#queued == 1, "A 7 ms elapsed interval does not miss the next 8 ms target")
	finish()
	acknowledge_all()
	s.y = s.y + 0.1
	paint()
	local hidden_reuse = finish()
	id = s.surface_state.entries[1].image.id
	surface.hide(s)
	assert(#vim.fn.glob(dir .. "/surface-*.rgba", false, true) == 1, "Hide keeps only unconfirmed output")
	acknowledge(id, "ERROR")
	assert(not vim.uv.fs_stat(hidden_reuse.parts[1].file), "A hidden read failure releases the abandoned output")
	s.frame = nil
	paint()
	finish()
	surface.hide(s)
	assert(s.surface_state.read_timer:is_active(), "A hidden pending read retains its watchdog")
	assert(
		vim.wait(1400, function()
			return not s.surface_state.read_timer
		end, 5),
		"Hidden timeout releases its watchdog"
	)
	assert(#vim.fn.glob(dir .. "/surface-*.rgba", false, true) == 0, "Hidden timeout releases retained files")
	surface.hide(s, true)
	vim.defer_fn, vim.uv.hrtime = original_defer, original_clock
	vim.fn.delete(dir, "rf")
	print(
		"PASS: surface acknowledgments, backpressure, stable IDs, resize retirement, hidden jobs, fractional scroll, exact target, retained output bounds, jitter tolerance, reused watchdog, stale timeout races, and failure cleanup"
	)
end

-- Idle refinement and cancellation
do
	-- Control refinement completion to exercise motion/close races without a GPU.
	vim.opt.rtp:prepend(vim.fn.getcwd())
	vim.o.termguicolors = true
	local surface, graphics = require("pdfpreview.surface"), require("pdfpreview.graphics")
	local uv = vim.uv
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local compose, refine, packets = {}, {}, {}
	graphics.sink = function(data)
		packets[#packets + 1] = data
	end
	local active, fallback = true, nil
	local s = {
		win = 1,
		width = 300,
		height = 4,
		cw = 1,
		ch = 2,
		columns = 300,
		zoom = 1,
		x = 0,
		y = 0,
		geometry_key = "test",
		renderer = "surface",
		pages = { { width = 600, height = 800 } },
		layout = {
			width = 300,
			pages = { { top = 0, width = 300, height = 400, pixel_width = 300, pixel_height = 800 } },
		},
	}
	local function queue(list, request, callback)
		local item = { request = request, callback = callback }
		item.job = {
			kill = function()
				item.cancelled = true
			end,
		}
		list[#list + 1] = item
		return item.job
	end
	s.backend = {
		dir = dir,
		native = { has_surface = true },
		compose = function(_, request, callback)
			return queue(compose, request, callback)
		end,
		refine = function(_, request, callback)
			return queue(refine, request, callback)
		end,
	}
	local hooks = {
		active = function()
			return active
		end,
		schedule = function() end,
		status = function() end,
		commit = function(_, frame)
			s.frame = frame
		end,
		fallback = function(_, reason)
			fallback = reason
		end,
	}
	local config = { max_dimension = 4096, surface_refine_ms = 5, surface_refine_scale = 2 }
	local function paint()
		if s.surface_state then
			s.surface_state.last_started = nil
		end
		surface.paint(s, config, hooks)
	end
	local function finish(item, code)
		for _, part in ipairs(item.request.parts) do
			local file = assert(io.open(part.file, "wb"))
			file:write(string.rep("\255", part.width * item.request.height * 4))
			file:close()
		end
		item.callback({ code = code or 0, render_ms = 2, stderr = code and "Injected refinement failure" or nil })
	end
	local function ack(id)
		vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=" .. id .. ";OK" } })
	end
	local function ack_all()
		for id in pairs(vim.deepcopy(assert(s.surface_state.awaiting).ids)) do
			ack(id)
		end
	end
	local function wait_refine()
		paint()
		assert(
			vim.wait(500, function()
				return #refine > 0
			end, 1),
			"Idle input starts one refinement"
		)
		return table.remove(refine, 1)
	end
	local function no_files(item)
		for _, part in ipairs(item.request.parts) do
			assert(not uv.fs_stat(part.file), "Obsolete refinement files are removed")
		end
	end
	paint()
	finish(table.remove(compose, 1))
	ack_all()
	s.backend.refiner = { closed = true, exited = false }
	paint()
	vim.wait(20, function()
		return false
	end, 1)
	assert(#refine == 0 and not s.surface_state.refine_error, "Returning waits for the closed worker's actual exit")
	s.backend.refiner = nil
	local motion = vim.deepcopy(s.surface_state.last_request)
	local old = wait_refine()
	assert(vim.deep_equal(motion, s.surface_state.last_request), "Refinement preserves the reusable motion request")
	assert(old.request.height == motion.height * 2, "Idle refinement doubles the raster height")
	for index, part in ipairs(old.request.parts) do
		assert(part.width == motion.parts[index].width * 2 and part.offset == motion.parts[index].offset * 2)
	end
	for index, page in ipairs(old.request.pages) do
		for _, axis in ipairs({ "left", "top", "width", "height" }) do
			assert(
				page[axis] == motion.pages[index][axis] * 2,
				"Supersampling preserves PDF placement and aspect ratio"
			)
		end
	end
	assert(
		not s.surface_state.running and not s.surface_state.awaiting,
		"Independent refinement does not occupy motion slots"
	)
	s.y = 1
	paint()
	assert(old.cancelled and #compose == 1, "New motion immediately cancels refinement and starts composing")
	finish(table.remove(compose, 1))
	ack_all()
	local current = s.frame
	finish(old)
	assert(s.frame == current and not s.surface_state.awaiting, "A late refinement cannot replace the new viewport")
	no_files(old)
	local fresh = wait_refine()
	local retained = vim.deepcopy(s.surface_state.files)
	local images = vim.tbl_map(function(entry)
		return entry.image.id
	end, s.surface_state.entries)
	finish(fresh)
	assert(
		s.frame.refined and s.frame.refinement_scale == 2 and not s.frame.refining and s.surface_state.awaiting,
		"Idle refinement publishes a final-quality frame"
	)
	assert(s.surface_state.read_timer:is_active(), "Refinement file reads have the same watchdog as motion")
	ack(images[1])
	assert(s.surface_state.awaiting, "Every stripe must acknowledge refined pixels")
	for _, part in ipairs(fresh.request.parts) do
		assert(uv.fs_stat(part.file), "Unconfirmed refinement stays readable")
	end
	ack(images[2])
	no_files(fresh)
	for file in pairs(retained) do
		assert(uv.fs_stat(file), "Refinement ACK preserves reusable Metal outputs")
	end
	local count = #packets
	paint()
	vim.wait(20, function()
		return false
	end, 1)
	assert(
		#refine == 0 and #packets == count and not s.surface_state.refine_timer:is_active(),
		"A refined idle frame does no more work"
	)

	-- Expired timers queued on the main loop must not start after a newer input.
	s.y = 2
	paint()
	finish(table.remove(compose, 1))
	ack_all()
	paint()
	s.surface_state.refine_timeout()
	s.y = 3
	paint()
	vim.wait(10, function()
		return false
	end, 1)
	assert(#refine == 0, "A queued refinement timer cannot run against a newer target")
	finish(table.remove(compose, 1))
	ack_all()
	config.surface_refine_scale = 1
	local failed = wait_refine()
	assert(failed.request.height == s.surface_state.last_request.height, "Scale 1 keeps the lower-memory pixel density")
	finish(failed, 1)
	assert(
		not fallback and s.surface_state.refine_error and not s.frame.refining,
		"Refinement failure retains the fast readable frame"
	)
	no_files(failed)
	paint()
	vim.wait(15, function()
		return false
	end, 1)
	assert(#refine == 0, "A failed refinement does not retry in an idle loop")

	s.surface_state.refine_error = nil
	s.surface_state.refine_frame = nil
	local hidden = wait_refine()
	active = false
	surface.hide(s)
	assert(hidden.cancelled and not s.surface_state.refine_timer, "Hide stops the refinement worker and timer")
	finish(hidden)
	no_files(hidden)
	assert(not s.surface_state.awaiting, "Late hidden output is never uploaded")

	active, s.frame = true, nil
	paint()
	finish(table.remove(compose, 1))
	ack_all()
	local hidden_read = wait_refine()
	finish(hidden_read)
	local ids = vim.deepcopy(s.surface_state.awaiting.ids)
	active = false
	surface.hide(s)
	for _, part in ipairs(hidden_read.request.parts) do
		assert(uv.fs_stat(part.file), "Hide preserves unconfirmed refined output")
	end
	for id in pairs(ids) do
		ack(id)
	end
	assert(#vim.fn.glob(dir .. "/*.rgba", false, true) == 0, "Hidden final ACK releases refinement and motion files")

	-- Exercise fractional caps without allocating large fake raster files.
	active = true
	config.surface_refine_scale = 2
	for _, size in ipairs({ { 4001, 1901 }, { 7001, 901 }, { 901, 7001 } }) do
		s.frame, s.surface_state.surface = nil, nil
		paint()
		finish(table.remove(compose, 1))
		ack_all()
		local source = s.surface_state.last_request
		source.height = size[2]
		source.parts[1].width = math.floor(size[1] / 2)
		source.parts[2].offset = source.parts[1].width
		source.parts[2].width = size[1] - source.parts[1].width
		local capped = wait_refine()
		local output = capped.request
		local width = output.parts[1].width + output.parts[2].width
		assert(width <= 8192 and output.height <= 8192 and width * output.height <= 16 * 1024 * 1024)
		assert(output.parts[2].offset == output.parts[1].width, "Fractional scaling keeps stripes adjacent")
		local before, after = source.pages[1], output.pages[1]
		assert(math.abs(after.width / width - before.width / size[1]) < 1e-12)
		assert(math.abs(after.height / output.height - before.height / size[2]) < 1e-12)
		active = false
		surface.hide(s)
		assert(capped.cancelled, "Capped refinement still cancels without blocking movement")
		capped.callback({ code = 1 })
		active = true
	end

	surface.hide(s, true)
	vim.fn.delete(dir, "rf")
	print(
		"PASS: bounded supersampling, aspect ratio, refinement cancellation, late results, all-stripe ACKs, output reuse, idle suppression, queued timer races, failure isolation, and hide cleanup"
	)
end
