local M = {}
function M.clamp(n, lo, hi)
	return math.max(lo, math.min(n, math.max(lo, hi)))
end

-- Layout units are terminal cells. Page geometry is in PDF points.
function M.build(pages, width, cw, ch, zoom, gap, precise)
	local function cells(value)
		return precise and value or math.floor(value + 0.5)
	end
	local widest = 1
	for _, p in ipairs(pages) do
		widest = math.max(widest, p.width)
	end
	local scale = math.max(1, width - 2) * cw / widest * zoom
	local out, y, maxw = {}, 0, 0
	for n, p in ipairs(pages) do
		local w = math.max(1, cells(p.width * scale / cw))
		local h = math.max(1, cells(p.height * scale / ch))
		out[n] = {
			page = n,
			top = y,
			width = w,
			height = h,
			pixel_width = p.width * scale,
			pixel_height = p.height * scale,
		}
		y, maxw = y + h + gap, math.max(maxw, w)
	end
	return { pages = out, height = math.max(0, y - gap), width = maxw, precise = precise or nil }
end

function M.at(layout, y)
	for n, p in ipairs(layout.pages) do
		if y < p.top + p.height then
			return n, M.clamp((y - p.top) / p.height, 0, 1)
		end
	end
	return #layout.pages, 1
end

function M.visible(layout, y, height)
	local out = {}
	for n, p in ipairs(layout.pages) do
		if p.top < y + height and p.top + p.height > y then
			out[#out + 1] = n
		end
	end
	return out
end

function M.reanchor(old, new, y, height, old_height)
	local n, fraction = M.at(old, y + (old_height or height) / 2)
	local p = new.pages[n]
	local position = p.top + fraction * p.height - height / 2
	return M.clamp(new.precise and position or math.floor(position + 0.5), 0, new.height - height)
end

function M.reanchor_x(old, new, x, width, old_width)
	old_width = old_width or width
	local padding = math.max(0, (old_width - old.width) / 2)
	local anchor = (x + old_width / 2 - padding) / math.max(1, old.width)
	local next_padding = math.max(0, (width - new.width) / 2)
	local position = anchor * new.width + next_padding - width / 2
	return M.clamp(new.precise and position or math.floor(position + 0.5), 0, new.width - width)
end
return M
