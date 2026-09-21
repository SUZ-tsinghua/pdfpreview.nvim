local M = {}

local function unescape(value)
	local entities = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }
	return (
		value:gsub("&([#%w]+);", function(entity)
			local code = entity:match("^#x(%x+)$")
			code = code and tonumber(code, 16) or tonumber(entity:match("^#(%d+)$"))
			if code and code > 0 and code <= 0x10ffff and not (code >= 0xd800 and code <= 0xdfff) then
				return vim.fn.nr2char(code)
			end
			return entities[entity] or ("&" .. entity .. ";")
		end)
	)
end

local function number(attributes, key)
	local value = tonumber(attributes:match(key .. '="([^"]+)"'))
	return value and value == value and math.abs(value) < math.huge and value or nil
end

-- pdftotext's boxes are already rotated and relative to the CropBox, but its
-- <page> dimensions are NOT rotated. Use the renderer's displayed geometry.
function M.parse(xml, geometry)
	local attributes, body = xml:match("<page%s+([^>]+)>(.-)</page>")
	if not attributes then
		return nil, "pdftotext returned no page geometry"
	end
	local width = geometry and geometry.width or number(attributes, "width")
	local height = geometry and geometry.height or number(attributes, "height")
	if not width or not height or width <= 0 or height <= 0 then
		return nil, "Invalid text page geometry"
	end
	local words, line = {}, 0
	for contents in body:gmatch("<line%s+[^>]*>(.-)</line>") do
		line = line + 1
		for box, value in contents:gmatch("<word%s+([^>]+)>(.-)</word>") do
			local x1, y1 = number(box, "xMin"), number(box, "yMin")
			local x2, y2 = number(box, "xMax"), number(box, "yMax")
			if not x1 or not y1 or not x2 or not y2 or x2 < x1 or y2 < y1 then
				return nil, "Invalid PDF text bounds"
			end
			value = unescape(value)
			if value ~= "" and x2 > 0 and y2 > 0 and x1 < width and y1 < height then
				words[#words + 1] = {
					text = value,
					line = line,
					x1 = math.max(0, x1 / width),
					y1 = math.max(0, y1 / height),
					x2 = math.min(1, x2 / width),
					y2 = math.min(1, y2 / height),
				}
			end
		end
	end
	return { words = words }
end

function M.left(frame, page)
	local left = (math.max(frame.width, frame.layout.width) - page.width) / 2
	return (frame.layout.precise and left or math.floor(left)) - frame.x
end

-- Mouse coordinates are viewport cells, never buffer columns: the latter
-- describe image placeholders and can be thousands of rows from the origin.
function M.point(frame, x, y)
	if not frame or x < 0 or y < 0 or x >= frame.width or y >= frame.height then
		return
	end
	for n, page in ipairs(frame.layout.pages) do
		local left, top = M.left(frame, page), page.top - frame.y
		if x >= left and x < left + page.width and y >= top and y < top + page.height then
			return {
				page = n,
				x = (x - left) / page.width,
				y = (y - top) / page.height,
				tx = 0.5 / page.width,
				ty = 0.5 / page.height,
			}
		end
	end
end

function M.hit(page, point, strict)
	local best, distance
	for index, word in ipairs(page.words) do
		local dx = math.max(word.x1 - point.x, 0, point.x - word.x2) / point.tx
		local dy = math.max(word.y1 - point.y, 0, point.y - word.y2) / point.ty
		local d = dx * dx + dy * dy
		if (not strict or (dx <= 1 and dy <= 1)) and (not distance or d < distance) then
			best, distance = index, d
		end
	end
	return best and { page = point.page, index = best } or nil
end

function M.range(a, b)
	if not a or not b then
		return
	end
	if a.page > b.page or (a.page == b.page and a.index > b.index) then
		return b, a
	end
	return a, b
end

local function cjk(character)
	local code = vim.fn.char2nr(character)
	return (code >= 0x2e80 and code <= 0x9fff)
		or (code >= 0xf900 and code <= 0xfaff)
		or (code >= 0x20000 and code <= 0x323af)
end

function M.extract(pages, first, last)
	local result, previous, previous_page = {}, nil, nil
	for n = first.page, last.page do
		local page = pages[n]
		if not page then
			return
		end
		for i = n == first.page and first.index or 1, n == last.page and last.index or #page.words do
			local word = page.words[i]
			if previous then
				local separator = previous_page ~= n and "\n\n" or previous.line ~= word.line and "\n" or " "
				if
					separator == " "
					and cjk(vim.fn.strcharpart(previous.text, vim.fn.strchars(previous.text) - 1))
					and cjk(word.text)
				then
					separator = ""
				end
				result[#result + 1] = separator
			end
			result[#result + 1] = word.text
			previous, previous_page = word, n
		end
	end
	return table.concat(result)
end

-- Extraction is lazy, serialized and bounded independently of raster work.
-- The selection owns any pages it needs after they leave this small LRU.
function M.new(path, executable, geometry)
	local self = { cache = {}, queue = {}, pending = {}, tick = 0, closed = false }
	function self:pump()
		if self.closed or self.running or #self.queue == 0 then
			return
		end
		local n = table.remove(self.queue, 1)
		self.running = n
		local function finish(result)
			vim.schedule(function()
				self.running, self.process = nil, nil
				if self.closed then
					return
				end
				local page, err
				if result.code == 0 then
					page, err = M.parse(result.stdout or "", geometry[n])
				else
					local detail = vim.trim(result.stderr or "")
					if detail == "" then
						detail = result.code == 124 and "pdftotext timed out"
							or "pdftotext exited with code " .. tostring(result.code)
					end
					err = "Text extraction failed: " .. detail:sub(1, 500)
				end
				self.tick = self.tick + 1
				self.cache[n] = { page = page, error = err, used = self.tick }
				if vim.tbl_count(self.cache) > 8 then
					local oldest
					for key, entry in pairs(self.cache) do
						if not oldest or entry.used < self.cache[oldest].used then
							oldest = key
						end
					end
					self.cache[oldest] = nil
				end
				local callbacks = self.pending[n]
				self.pending[n] = nil
				for _, callback in ipairs(callbacks) do
					if self.closed then
						return
					end
					callback(page, err)
				end
				self:pump()
			end)
		end
		local ok, process = pcall(vim.system, {
			executable,
			"-f",
			tostring(n),
			"-l",
			tostring(n),
			"-bbox-layout",
			"-cropbox",
			"-enc",
			"UTF-8",
			path,
			"-",
		}, { text = true, timeout = 15000 }, finish)
		if ok then
			self.process = process
		else
			finish({ code = -1, stderr = tostring(process) })
		end
	end
	function self:get(n, callback)
		if self.closed then
			return
		end
		local cached = self.cache[n]
		if cached then
			self.tick = self.tick + 1
			cached.used = self.tick
			vim.schedule(function()
				if not self.closed then
					callback(cached.page, cached.error)
				end
			end)
			return
		end
		if not self.pending[n] then
			self.pending[n] = {}
			self.queue[#self.queue + 1] = n
		end
		self.pending[n][#self.pending[n] + 1] = callback
		self:pump()
	end
	function self:close()
		self.closed = true
		self.queue, self.pending, self.cache = {}, {}, {}
		if self.process then
			pcall(self.process.kill, self.process, 15)
		end
	end
	return self
end

return M
