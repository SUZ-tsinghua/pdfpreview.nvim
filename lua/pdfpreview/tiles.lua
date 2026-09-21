local M = {}
local function axis(cells, pixels, limit, reusable, reference, pixel_limit)
	local step = limit
	if reusable then
		step = 1
		local minimum_cells = math.max(1, math.floor((reference or cells) / 2))
		while
			(step * 2 <= pixel_limit or step * minimum_cells < pixels)
			and math.ceil(step * 2 * (reference or cells) / pixels) <= limit
		do
			step = step * 2
		end
	end
	if reusable and (reference or cells) <= limit and pixels <= pixel_limit then
		step = pixels
	end
	local out = {}
	local total = reusable and pixels or cells
	local last_start = math.floor((total - 1) / step) * step
	local last_boundary = last_start
	if reusable and last_start > 0 then
		local minimum = math.max(1, math.floor((reference or cells) / 2))
		if (total - last_start) * minimum / pixels <= 0.5 then
			-- Decide using the entire display level, before projecting to this
			-- frame. Otherwise a subcell tail changes source keys during zoom.
			local previous = last_start - step
			if math.ceil((total - previous) * (reference or cells) / pixels) <= limit then
				last_boundary = total
			else
				-- A merge would exceed the coordinate budget at maximum scale.
				-- Balance the final pair instead; both remain visible and bounded.
				last_boundary = math.floor((previous + total) / 2)
			end
		end
	end
	local start = 0
	while start < total do
		local finish = math.min(total, start + step)
		if finish == last_start then
			finish = last_boundary
		end
		local first_cell = reusable and math.floor(start * cells / pixels + 0.5) or start
		local end_cell = reusable and math.floor(finish * cells / pixels + 0.5) or finish
		local tile = {
			first = first_cell,
			size = end_cell - first_cell,
			pixel = reusable and start or math.floor(start * pixels / cells),
			pixels = reusable and finish - start
				or math.floor(finish * pixels / cells) - math.floor(start * pixels / cells),
		}
		if tile.size > 0 then
			out[#out + 1] = tile
		elseif #out > 0 then
			-- The final source sliver can be smaller than one cell. Include it
			-- in the preceding tile instead of creating a zero-cell placement.
			out[#out].pixels = out[#out].pixels + tile.pixels
		end
		start = finish
	end
	return out
end
function M.build(p, px, py, coordinate_limit, reference, max_columns)
	coordinate_limit = coordinate_limit or 128
	local columns = math.min(coordinate_limit, max_columns or coordinate_limit)
	-- Otty rescales virtual images wider than the terminal. Keep source
	-- boundaries stable within a level while respecting its column bound.
	local rows = coordinate_limit
	reference = reference or p
	local reusable = reference.width <= math.min(128, columns) * px and reference.height <= math.min(64, rows) * py
	return {
		x = axis(p.width, px, math.min(reusable and 128 or 64, columns), reusable, reference.width, 4096),
		y = axis(p.height, py, math.min(reusable and 64 or 32, rows), reusable, reference.height, 512),
		reusable = reusable,
		pixel_width = px,
		pixel_height = py,
	}
end

-- Reproject an existing source grid without changing any raster boundaries.
-- This is only useful while every visible source tile is already uploaded.
function M.project(source, page, limit, max_columns)
	if not source.reusable then
		return
	end
	limit = math.min(limit or 128, 128)
	local function project_axis(old, cells, pixels, bound)
		local out = {}
		for _, tile in ipairs(old) do
			local first = math.floor(tile.pixel * cells / pixels + 0.5)
			local finish = math.floor((tile.pixel + tile.pixels) * cells / pixels + 0.5)
			local size = finish - first
			if size > bound then
				return
			elseif size > 0 then
				out[#out + 1] = { first = first, size = size, pixel = tile.pixel, pixels = tile.pixels }
			end
		end
		return out
	end
	local x = project_axis(source.x, page.width, source.pixel_width, math.min(limit, max_columns or limit))
	local y = project_axis(source.y, page.height, source.pixel_height, limit)
	if x and y then
		return { x = x, y = y, reusable = true, pixel_width = source.pixel_width, pixel_height = source.pixel_height }
	end
end
function M.range(axis, first, finish)
	local lo, hi
	for i, t in ipairs(axis) do
		if t.first < finish and t.first + t.size > first then
			lo = lo or i
			hi = i
		end
	end
	return lo, hi
end
return M
