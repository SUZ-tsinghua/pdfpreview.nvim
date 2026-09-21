-- Deterministic geometry, transport and resource-ownership regressions.

-- Layout and metadata
do
	vim.opt.rtp:prepend(vim.fn.getcwd())
	vim.o.termguicolors = true
	vim.o.lines = 35
	vim.o.columns = 90
	local layout = require("pdfpreview.layout")
	local backend = require("pdfpreview.backend")
	local gfx = require("pdfpreview.graphics")
	local viewer = require("pdfpreview")
	local packets = {}
	gfx.sink = function(data)
		packets[#packets + 1] = data
	end
	local assertions = 0
	local function check(value, label)
		assertions = assertions + 1
		assert(value, label)
	end
	local function wait(fn, label)
		check(vim.wait(15000, fn, 20), label)
	end
	local pages = { { width = 400, height = 600 }, { width = 500, height = 350 }, { width = 300, height = 700 } }
	local l = layout.build(pages, 90, 10, 20, 1, 2)
	check(l.pages[2].top == l.pages[1].height + 2, "Pages separated by exact gap")
	local vis = layout.visible(l, l.pages[1].height - 3, 10)
	check(#vis == 2 and vis[1] == 1 and vis[2] == 2, "Viewport crosses page boundary")
	local big = layout.build(pages, 90, 10, 20, 2, 2)
	local anchor = layout.reanchor(l, big, 10, 20)
	local n, f = layout.at(l, 20)
	local n2, f2 = layout.at(big, anchor + 10)
	check(n == n2 and math.abs(f - f2) < 0.02, "Zoom preserves page and fractional reading position")
	local narrow = layout.build(pages, 90, 10, 20, 0.5, 2)
	check(
		layout.reanchor_x(narrow, big, 0, 90) == math.floor((big.width - 90) / 2 + 0.5),
		"Zoom subtracts centered page padding"
	)
	check(layout.reanchor_x(big, narrow, 30, 90) == 0, "Zooming below fit width restores centered pages")
	local resized = layout.build(pages, 70, 10, 20, 3, 2)
	local horizontal = layout.reanchor_x(big, resized, 50, 70, 90)
	check(
		math.abs((horizontal + 35) / resized.width - 95 / big.width) < 0.01,
		"Split resize preserves the old horizontal center"
	)
	local vertical = layout.reanchor(big, resized, 30, 12, 20)
	local before_page, before_fraction = layout.at(big, 40)
	local after_page, after_fraction = layout.at(resized, vertical + 6)
	check(
		before_page == after_page and math.abs(before_fraction - after_fraction) < 0.02,
		"Resize uses both viewport heights"
	)
	local cache_geometry = backend.new("unused.pdf", viewer.config, function() end)
	local last_px, last_py
	for _, zoom in ipairs({ 4, 4.15, 4.37, 5.8, 8 }) do
		local capped = layout.build(pages, 148, 15, 35, zoom, 2)
		local _, px, py = cache_geometry:key(1, capped.pages[1], 15, 35)
		check(not last_px or (px == last_px and py == last_py), "Capped raster dimensions remain stable across zooms")
		last_px, last_py = px, py
	end
	cache_geometry:close()
	local parsed, err = backend.parse_info(
		"Pages: 2\nPage 1 size: 400 x 600 pts\nPage 1 rot: 0\nPage 2 size: 400 x 600 pts\nPage 2 rot: 90\n"
	)
	check(parsed and parsed[2].width == 600 and parsed[2].height == 400, err or "Rotated page geometry")
	check(not backend.parse_info("broken"), "Invalid metadata rejected")
end

-- Tile coverage at coordinate and pixel limits
do
	vim.opt.rtp:prepend(vim.fn.getcwd())
	local t = require("pdfpreview.tiles")
	local cases = 0
	for _, cells in ipairs({ 1, 2, 17, 31, 32, 33, 64, 127, 128, 148, 219, 337, 1168, 2049 }) do
		for _, pixels in ipairs({ 1, 19, 127, 128, 1024, 2048, 3073, 3165, 4096, 8192 }) do
			local grid = t.build({ width = cells, height = cells }, pixels, pixels)
			for _, axis in ipairs({ grid.x, grid.y }) do
				local expected_cell, expected_pixel = 0, 0
				for _, tile in ipairs(axis) do
					assert(tile.first == expected_cell, "Cells have no gaps or overlaps")
					if grid.reusable then
						assert(tile.pixel == expected_pixel, "Source pixels have no gaps or overlaps")
					end
					assert(
						tile.size > 0 and tile.size <= 128 and (not grid.reusable or tile.pixels > 0),
						"Every placement has valid bounded geometry"
					)
					expected_cell = expected_cell + tile.size
					expected_pixel = expected_pixel + tile.pixels
				end
				assert(expected_cell == cells, "The whole page is covered")
				if grid.reusable then
					assert(expected_pixel == pixels, "All source pixels are covered")
				end
				for first = 0, cells - 1, math.max(1, math.floor(cells / 20)) do
					local finish = math.min(cells, first + 47)
					local lo, hi = t.range(axis, first, finish)
					assert(lo and hi, "Visible cell range finds tiles")
					assert(
						axis[lo].first <= first and axis[hi].first + axis[hi].size >= finish,
						"Visible tiles cover the full viewport"
					)
				end
			end
			cases = cases + 1
		end
	end

	-- A tiny final source strip must not appear/disappear midway through a level.
	-- Include both safe merges and cases requiring a rebalanced last pair to keep
	-- the widest projected placement within its coordinate budget.
	for _, pixels in ipairs({ 1025, 1032, 2049, 2056, 3080, 4090 }) do
		for _, cell_pixels in ipairs({ 8, 9, 10, 15, 15.5, 16, 20, 30 }) do
			local reference = math.ceil(pixels / cell_pixels)
			local previous
			for scale = 50, 100 do
				local cells = math.max(1, math.floor(reference * scale / 100 + 0.5))
				local grid = t.build(
					{ width = cells, height = cells },
					pixels,
					pixels,
					128,
					{ width = reference, height = reference }
				)
				local keys = {}
				for n, axis in ipairs({ grid.x, grid.y }) do
					local cell_end, pixel_end = 0, 0
					for _, tile in ipairs(axis) do
						assert(
							tile.first == cell_end and tile.pixel == pixel_end,
							"Small tails preserve contiguous coverage"
						)
						assert(tile.size > 0 and tile.size <= (n == 1 and 128 or 64), "Rebalanced tails fit placements")
						cell_end, pixel_end = cell_end + tile.size, pixel_end + tile.pixels
						keys[#keys + 1] = n .. ":" .. tile.pixel .. ":" .. tile.pixels
					end
					assert(cell_end == cells and pixel_end == pixels, "Small tails lose no cells or pixels")
				end
				assert(not previous or vim.deep_equal(keys, previous), "Tiny source tails stay fixed throughout zoom")
				previous = keys
			end
		end
	end

	-- A resolution level spans a factor of two in scale. Keep source boundaries
	-- fixed throughout that interval, even as their cell sizes change.
	for _, reference in ipairs({ { width = 211, height = 118 }, { width = 565, height = 313 } }) do
		local previous
		for scale = 51, 100 do
			local p = {
				width = math.floor(reference.width * scale / 100 + 0.5),
				height = math.floor(reference.height * scale / 100 + 0.5),
			}
			local grid = t.build(p, 3165, 4096, 128, reference)
			local keys = {}
			for n, axis in ipairs({ grid.x, grid.y }) do
				for _, tile in ipairs(axis) do
					assert(
						tile.size > 0 and tile.size <= (n == 1 and 128 or 64),
						"Level bounds respect coordinate limits"
					)
					keys[#keys + 1] = tile.pixel .. ":" .. tile.pixels
				end
			end
			if previous then
				assert(vim.deep_equal(keys, previous), "Source boundaries remain fixed inside one resolution level")
			end
			previous = keys
		end
	end
	-- Terminal column limits are independent of source resolution and page width.
	for _, columns in ipairs({ 8, 17, 64, 80, 127 }) do
		for _, cells in ipairs({ 19, 128, 219, 1168 }) do
			local grid = t.build({ width = cells, height = 77 }, 3165, 4096, 128, nil, columns)
			local edge = 0
			for _, tile in ipairs(grid.x) do
				assert(tile.first == edge and tile.size <= columns, "Every horizontal placement fits terminal columns")
				edge = edge + tile.size
			end
			assert(edge == cells, "Column bounds never discard page content")
		end
	end
	local source = t.build({ width = 120, height = 80 }, 1600, 2000, 128)
	local projected = assert(t.project(source, { width = 96, height = 72 }, 128, 100))
	for n, axis in ipairs({ projected.x, projected.y }) do
		local edge = 0
		for _, tile in ipairs(axis) do
			assert(tile.first == edge and tile.size > 0, "Projected source covers every current cell without gaps")
			edge = edge + tile.size
		end
		assert(edge == (n == 1 and 96 or 72), "Projected geometry covers the complete page")
	end
	assert(
		not t.project(source, { width = 120, height = 80 }, 128, 100),
		"Reject a provisional image wider than the terminal"
	)
	print("PASS: source-aligned tiling, coordinate bounds, tiny edge slivers, and viewport coverage; cases=" .. cases)
end

-- Image identifier lifetimes
do
	vim.opt.rtp:prepend(vim.fn.getcwd())
	local g = require("pdfpreview.graphics")
	local packets = {}
	g.sink = function(data)
		packets[#packets + 1] = data
	end
	local file = vim.fn.tempname() .. ".rgba"
	vim.fn.writefile({ string.rep("x", 4) }, file, "b")
	local function upload()
		return g.upload(file, 1, 1, "viewport", { format = 32, crop = { width = 1, height = 1 } })
	end
	local visible = upload()
	local ids, retired = {}, {}
	local first
	for n = 1, 70000 do
		local im = upload()
		assert(im.id ~= visible.id, "Displayed ID remains exclusively leased")
		ids[im.id] = true
		if not first then
			first = im
		end
		if n % 37 == 0 then
			retired[#retired + 1] = im
			if #retired > 12 then
				g.delete(table.remove(retired, 1))
			end
		else
			g.delete(im)
		end
		if n % 97 == 0 then
			package.loaded["pdfpreview.graphics"] = nil
			g = require("pdfpreview.graphics")
			g.sink = function() end
		end
	end
	assert(vim.tbl_count(ids) <= 64, "Identifier colors stay bounded across 70,000 replacements")
	assert(
		vim.api.nvim_get_hl(0, { name = visible.tiles[1].hl }).fg == visible.id,
		"Retirement and reload preserve the displayed image"
	)
	local live = upload()
	g.delete(first)
	local other = upload()
	assert(live.id ~= other.id, "Repeated deletion cannot release another generation")
	for _, im in ipairs(retired) do
		g.delete(im)
	end
	g.delete(visible)
	g.delete(live)
	g.delete(other)
	-- Fail a combined transmission; cleanup must return its lease.
	local fail = true
	g.sink = function(data)
		if fail and data:find("a=T", 1, true) then
			fail = false
			error("Injected upload failure")
		end
	end
	local ok, err = pcall(upload)
	assert(not ok and tostring(err):find("Injected upload failure", 1, true), "Exercise partial-upload cleanup")
	local recovered = upload()
	assert(ids[recovered.id] or recovered.id == visible.id, "Failure does not expand the identifier pool")
	g.delete(recovered)
	vim.fn.delete(file)
	print(
		"PASS: 70,000 replacements use at most 64 image colors; live/retiring leases, reload and repeated deletion remain isolated"
	)
end

-- Synchronized output failure recovery
do
	vim.opt.rtp:prepend(vim.fn.getcwd())
	local g = require("pdfpreview.graphics")
	local saved = vim.o.termsync
	local packets = {}
	g.sink = function(data)
		packets[#packets + 1] = data
	end
	for _, initial in ipairs({ false, true }) do
		vim.o.termsync = initial
		packets = {}
		g.synchronized(function()
			assert(not vim.o.termsync, "Neovim's own TUI flush cannot end the outer transaction")
			g.synchronized(function()
				g.raw("payload")
			end)
			assert(not vim.o.termsync, "Nested calls preserve the outer option scope")
		end)
		assert(
			vim.deep_equal(packets, { "\27[?2026h", "payload", "\27[?2026l" }),
			"Nested transactions have exactly one begin and end"
		)
		assert(vim.o.termsync == initial, "Restore the caller's original synchronization setting")
		packets = {}
		local ok, err = pcall(g.synchronized, function()
			g.synchronized(function()
				error("nested failure")
			end)
		end)
		assert(not ok and tostring(err):find("nested failure", 1, true), "Report a nested callback failure")
		assert(
			packets[#packets] == "\27[?2026l" and vim.o.termsync == initial,
			"Callback failure still ends output and restores options"
		)
	end
	vim.o.termsync = true
	local failing = true
	g.sink = function(data)
		packets[#packets + 1] = data
		if data == "\27[?2026l" and failing then
			failing = false
			error("end failed")
		end
	end
	local ok, err = pcall(g.synchronized, function() end)
	assert(
		not ok and tostring(err):find("end failed", 1, true) and vim.o.termsync,
		"Transport failure restores the TUI setting"
	)
	-- A failed transaction cannot leave the next call permanently nested.
	packets = {}
	g.synchronized(function()
		g.raw("retry")
	end)
	assert(vim.deep_equal(packets, { "\27[?2026h", "retry", "\27[?2026l" }), "The next transaction starts normally")
	vim.o.termsync = saved
	print("PASS: nested synchronized output, option preservation, callback/transport failure cleanup, and recovery")
end
print("PASS: core geometry, identifiers and graphics transactions")
