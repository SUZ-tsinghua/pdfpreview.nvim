local M = {}
local uv = vim.uv
local highlights = require("pdfpreview.highlights")
local image_ids = require("pdfpreview.image_ids")
M.tile_size = 128
-- Unicode coordinates defined by the Kitty graphics protocol:
-- https://github.com/kovidgoyal/kitty/blob/master/gen/rowcolumn-diacritics.txt
local codes = {
	0x0305,
	0x030D,
	0x030E,
	0x0310,
	0x0312,
	0x033D,
	0x033E,
	0x033F,
	0x0346,
	0x034A,
	0x034B,
	0x034C,
	0x0350,
	0x0351,
	0x0352,
	0x0357,
	0x035B,
	0x0363,
	0x0364,
	0x0365,
	0x0366,
	0x0367,
	0x0368,
	0x0369,
	0x036A,
	0x036B,
	0x036C,
	0x036D,
	0x036E,
	0x036F,
	0x0483,
	0x0484,
	0x0485,
	0x0486,
	0x0487,
	0x0592,
	0x0593,
	0x0594,
	0x0595,
	0x0597,
	0x0598,
	0x0599,
	0x059C,
	0x059D,
	0x059E,
	0x059F,
	0x05A0,
	0x05A1,
	0x05A8,
	0x05A9,
	0x05AB,
	0x05AC,
	0x05AF,
	0x05C4,
	0x0610,
	0x0611,
	0x0612,
	0x0613,
	0x0614,
	0x0615,
	0x0616,
	0x0617,
	0x0657,
	0x0658,
	0x0659,
	0x065A,
	0x065B,
	0x065D,
	0x065E,
	0x06D6,
	0x06D7,
	0x06D8,
	0x06D9,
	0x06DA,
	0x06DB,
	0x06DC,
	0x06DF,
	0x06E0,
	0x06E1,
	0x06E2,
	0x06E4,
	0x06E7,
	0x06E8,
	0x06EB,
	0x06EC,
	0x0730,
	0x0732,
	0x0733,
	0x0735,
	0x0736,
	0x073A,
	0x073D,
	0x073F,
	0x0740,
	0x0741,
	0x0743,
	0x0745,
	0x0747,
	0x0749,
	0x074A,
	0x07EB,
	0x07EC,
	0x07ED,
	0x07EE,
	0x07EF,
	0x07F0,
	0x07F1,
	0x07F3,
	0x0816,
	0x0817,
	0x0818,
	0x0819,
	0x081B,
	0x081C,
	0x081D,
	0x081E,
	0x081F,
	0x0820,
	0x0821,
	0x0822,
	0x0823,
	0x0825,
	0x0826,
	0x0827,
	0x0829,
	0x082A,
	0x082B,
	0x082C,
	0x082D,
	0x0951,
	0x0953,
	0x0954,
	0x0F82,
	0x0F83,
	0x0F86,
	0x0F87,
	0x135D,
	0x135E,
	0x135F,
	0x17DD,
	0x193A,
	0x1A17,
	0x1A75,
	0x1A76,
	0x1A77,
	0x1A78,
	0x1A79,
	0x1A7A,
	0x1A7B,
	0x1A7C,
	0x1B6B,
	0x1B6D,
	0x1B6E,
	0x1B6F,
	0x1B70,
	0x1B71,
	0x1B72,
	0x1B73,
	0x1CD0,
	0x1CD1,
	0x1CD2,
	0x1CDA,
	0x1CDB,
	0x1CE0,
	0x1DC0,
	0x1DC1,
	0x1DC3,
	0x1DC4,
	0x1DC5,
	0x1DC6,
	0x1DC7,
	0x1DC8,
	0x1DC9,
	0x1DCB,
	0x1DCC,
	0x1DD1,
	0x1DD2,
	0x1DD3,
	0x1DD4,
	0x1DD5,
	0x1DD6,
	0x1DD7,
	0x1DD8,
	0x1DD9,
	0x1DDA,
	0x1DDB,
	0x1DDC,
	0x1DDD,
	0x1DDE,
	0x1DDF,
	0x1DE0,
	0x1DE1,
	0x1DE2,
	0x1DE3,
	0x1DE4,
	0x1DE5,
	0x1DE6,
	0x1DFE,
	0x20D0,
	0x20D1,
	0x20D4,
	0x20D5,
	0x20D6,
	0x20D7,
	0x20DB,
	0x20DC,
	0x20E1,
	0x20E7,
	0x20E9,
	0x20F0,
	0x2CEF,
	0x2CF0,
	0x2CF1,
	0x2DE0,
	0x2DE1,
	0x2DE2,
	0x2DE3,
	0x2DE4,
	0x2DE5,
	0x2DE6,
	0x2DE7,
	0x2DE8,
	0x2DE9,
	0x2DEA,
	0x2DEB,
	0x2DEC,
	0x2DED,
	0x2DEE,
	0x2DEF,
	0x2DF0,
	0x2DF1,
	0x2DF2,
	0x2DF3,
	0x2DF4,
	0x2DF5,
	0x2DF6,
	0x2DF7,
	0x2DF8,
	0x2DF9,
	0x2DFA,
	0x2DFB,
	0x2DFC,
	0x2DFD,
	0x2DFE,
	0x2DFF,
	0xA66F,
	0xA67C,
	0xA67D,
	0xA6F0,
	0xA6F1,
	0xA8E0,
	0xA8E1,
	0xA8E2,
	0xA8E3,
	0xA8E4,
	0xA8E5,
}
local marks = {}
for n, code in ipairs(codes) do
	marks[n] = vim.fn.nr2char(code)
end
local placeholder = vim.fn.nr2char(0x10EEEE)
local coordinate_rows = {}
local placeholder_runs = {}
local terminal_size
do
	local ok, ffi = pcall(require, "ffi")
	if ok then
		-- Re-declaring an anonymous struct consumes FFI type IDs even when the
		-- typedef already exists. Reuse its type across paints and hot reloads.
		if not pcall(ffi.typeof, "pdfpreview_winsize") then
			pcall(
				ffi.cdef,
				[[
        typedef struct { unsigned short row, col, xpixel, ypixel; } pdfpreview_winsize;
        int ioctl(int, unsigned long, ...);
      ]]
			)
		end
		local allocated, size = pcall(ffi.new, "pdfpreview_winsize")
		if allocated then
			terminal_size = { ffi = ffi, size = size, code = vim.fn.has("mac") == 1 and 0x40087468 or 0x5413 }
		end
	end
end

local function coordinates(row, first, last, compact)
	if compact then
		local count = last - first
		placeholder_runs[count] = placeholder_runs[count] or string.rep(placeholder, count)
		-- An explicit first cell makes every clipped fragment self-contained.
		-- Remaining cells inherit row and consecutive columns from the left.
		return placeholder .. marks[row] .. marks[first] .. placeholder_runs[count]
	end
	-- Placeholder text depends only on tile coordinates, not the image ID.
	-- Cache at most 256 rows and slice by byte offsets for variable-width UTF-8.
	local cached = coordinate_rows[row]
	if not cached then
		local parts, offsets, size = {}, {}, 0
		for col = 1, #marks do
			offsets[col] = size + 1
			parts[col] = placeholder .. marks[row] .. marks[col]
			size = size + #parts[col]
		end
		offsets[#marks + 1] = size + 1
		cached = { text = table.concat(parts), offsets = offsets }
		coordinate_rows[row] = cached
	end
	return cached.text:sub(cached.offsets[first], cached.offsets[last + 1] - 1)
end

local function encode(opts, payload)
	opts.q = opts.q or 2
	local keys = {}
	for k, v in pairs(opts) do
		keys[#keys + 1] = k .. "=" .. tostring(v)
	end
	table.sort(keys)
	local data = "\27_G" .. table.concat(keys, ",") .. (payload and ";" .. payload or "") .. "\27\\"
	return data
end

function M.send(opts, payload)
	return M.raw(encode(opts, payload))
end

function M.raw(data)
	if M.sink then
		return M.sink(data)
	end -- test transport
	if vim.api.nvim_ui_send then
		vim.api.nvim_ui_send(data)
	else
		io.stdout:write(data)
		io.stdout:flush()
	end
end

-- Resize placements and flush their replacement grid as one terminal frame.
-- Always release synchronized output, even when a redraw or transport fails.
local sync_depth = 0
function M.synchronized(callback)
	if sync_depth > 0 then
		return callback()
	end
	local termsync = vim.fn.exists("+termsync") == 1 and vim.o.termsync
	sync_depth = 1
	local ok, err = pcall(function()
		-- TUI buffer flushes must not end the surrounding image transaction.
		if termsync then
			vim.o.termsync = false
		end
		M.raw("\27[?2026h")
		callback()
	end)
	sync_depth = 0
	local ended, end_err = pcall(M.raw, "\27[?2026l")
	local restored, restore_err = pcall(function()
		if termsync then
			vim.o.termsync = true
		end
	end)
	if not ok then
		error(err, 0)
	end
	if not ended then
		error(end_err, 0)
	end
	if not restored then
		error(restore_err, 0)
	end
end

function M.cell_size()
	local cw, ch = 9, 18
	if terminal_size then
		pcall(function()
			local t, sz = terminal_size, terminal_size.size
			if t.ffi.C.ioctl(1, t.code, sz) == 0 and sz.col > 0 and sz.row > 0 and sz.xpixel > 0 and sz.ypixel > 0 then
				cw, ch = sz.xpixel / sz.col, sz.ypixel / sz.row
			end
		end)
	end
	return cw, ch
end

function M.upload(file, cols, rows, renderer, raster)
	local viewport = renderer == "viewport" or renderer == "surface"
	local limit = renderer == "surface" and 256 or M.tile_size
	if viewport then
		assert(cols > 0 and cols <= limit and rows > 0 and rows <= limit, "Viewport exceeds coordinate range")
	end
	local width, height, format = nil, nil, raster and raster.format or 100
	if format == 32 then
		width, height = raster.crop.width, raster.crop.height
		local stat = uv.fs_stat(file)
		assert(stat and stat.size == width * height * 4, "Invalid RGBA raster size")
	else
		local f = assert(io.open(file, "rb"))
		local header = f:read(24)
		f:close()
		assert(header and header:sub(1, 8) == "\137PNG\r\n\26\n", "Invalid PNG from renderer")
		local function u32(i)
			local a, b, c, d = header:byte(i, i + 3)
			return ((a * 256 + b) * 256 + c) * 256 + d
		end
		width, height = u32(17), u32(21)
	end
	local lease = image_ids.acquire()
	local image = { id = lease.id, lease = lease, cols = cols, rows = rows, width = width, height = height, tiles = {} }
	local ok, err = pcall(function()
		-- Local file transport is supported by Otty, unlike shared-memory transport.
		M.send({
			a = viewport and "T" or "t",
			q = raster and raster.quiet,
			U = viewport and 1 or nil,
			C = viewport and 1 or nil,
			p = viewport and 1 or nil,
			c = viewport and cols or nil,
			r = viewport and rows or nil,
			t = "f",
			f = format,
			i = image.id,
			s = format == 32 and width or nil,
			v = format == 32 and height or nil,
		}, vim.base64.encode(file))
		if viewport then
			assert(cols <= limit and rows <= limit, "Viewport fragment exceeds coordinate range")
			local hl = highlights.acquire(image.id, 1)
			image.tiles[1] = { row = 0, col = 0, width = cols, height = rows, hl = hl }
			return image
		end
		local index = 0
		for r = 0, rows - 1, M.tile_size do
			for c = 0, cols - 1, M.tile_size do
				index = index + 1
				local w, h = math.min(M.tile_size, cols - c), math.min(M.tile_size, rows - r)
				local x, y = math.floor(c * image.width / cols), math.floor(r * image.height / rows)
				local right, bottom =
					math.floor((c + w) * image.width / cols), math.floor((r + h) * image.height / rows)
				M.send({
					a = "p",
					U = 1,
					C = 1,
					i = image.id,
					p = index,
					c = w,
					r = h,
					x = x,
					y = y,
					w = right - x,
					h = bottom - y,
				})
				local hl = highlights.acquire(image.id, index)
				image.tiles[index] = { row = r, col = c, width = w, height = h, hl = hl }
			end
		end
	end)
	if not ok then
		-- A failed upload must not strand an identifier or partial placement.
		pcall(M.delete, image)
		error(err, 0)
	end
	return image
end

-- A fixed viewport keeps its identifier and coordinate grid while pixels change.
function M.replace(image, file, cols, rows, raster)
	assert(image and not image.deleted and #image.tiles == 1, "Replace requires a live single placement")
	assert(cols > 0 and cols <= 256 and rows > 0 and rows <= 256, "Invalid viewport geometry")
	local width, height = raster.crop.width, raster.crop.height
	local stat = uv.fs_stat(file)
	assert(raster.format == 32 and stat and stat.size == width * height * 4, "Invalid RGBA viewport")
	M.send({
		a = "T",
		q = raster.quiet,
		U = 1,
		C = 1,
		i = image.id,
		p = 1,
		c = cols,
		r = rows,
		t = "f",
		f = 32,
		s = width,
		v = height,
	}, vim.base64.encode(file))
	image.cols, image.rows, image.width, image.height = cols, rows, width, height
	image.tiles[1].width, image.tiles[1].height = cols, rows
end

function M.row(image, row, left, width, compact)
	local chunks = {}
	local across = math.ceil(image.cols / M.tile_size)
	local last = math.min(image.cols, left + width)
	while left < last do
		local tilecol, tilerow = math.floor(left / M.tile_size), math.floor(row / M.tile_size)
		local tile = image.tiles[tilerow * across + tilecol + 1]
		local stop = math.min(last, tile.col + tile.width)
		local text = coordinates(row - tile.row + 1, left - tile.col + 1, stop - tile.col, compact)
		chunks[#chunks + 1] = { text, tile.hl }
		left = stop
	end
	return chunks
end

-- Independent viewport rasters have one placement. Build coordinates for its
-- next size before changing the placement currently visible in the terminal.
function M.viewport_row(image, row, left, width, compact)
	return { coordinates(row + 1, left + 1, left + width, compact), image.tiles[1].hl }
end

function M.resize_many(resizes)
	local packets, changed = {}, {}
	for _, item in ipairs(resizes) do
		local image, cols, rows = item.image, item.width, item.height
		assert(not image.deleted and #image.tiles == 1, "Resize requires one live viewport placement")
		assert(cols > 0 and cols <= M.tile_size and rows > 0 and rows <= M.tile_size, "Invalid placement geometry")
		if image.cols ~= cols or image.rows ~= rows then
			packets[#packets + 1] = encode({ a = "p", U = 1, C = 1, i = image.id, p = 1, c = cols, r = rows })
			changed[#changed + 1] = item
		end
	end
	if #packets == 0 then
		return
	end
	M.raw(table.concat(packets))
	for _, item in ipairs(changed) do
		local image = item.image
		image.cols, image.rows = item.width, item.height
		image.tiles[1].width, image.tiles[1].height = item.width, item.height
	end
end

function M.resize(image, cols, rows)
	return M.resize_many({ { image = image, width = cols, height = rows } })
end

function M.delete(image)
	if not image or image.deleted then
		return
	end
	M.send({ a = "d", d = "I", i = image.id })
	image.deleted = true
	for _, tile in ipairs(image.tiles) do
		highlights.release(tile.hl)
	end
	image_ids.release(image.lease)
end
return M
