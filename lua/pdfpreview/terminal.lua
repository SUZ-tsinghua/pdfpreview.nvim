local M = {}
local read_size
do
	local ok, ffi = pcall(require, "ffi")
	if ok and (ffi.os == "OSX" or ffi.os == "BSD" or ffi.os == "Linux") then
		-- Reuse the named type across module reloads; allocate no FFI types per frame.
		if not pcall(ffi.typeof, "pdfpreview_winsize") then
			pcall(
				ffi.cdef,
				[[
        typedef struct { unsigned short row, col, xpixel, ypixel; } pdfpreview_winsize;
        int ioctl(int, unsigned long, ...);
      ]]
			)
		end
		local allocated, buffer = pcall(ffi.new, "pdfpreview_winsize[1]")
		if allocated then
			local code = ffi.os == "Linux" and 0x5413 or 0x40087468 -- TIOCGWINSZ
			local descriptors = { 1, 0, 2 }
			read_size = function()
				for _, fd in ipairs(descriptors) do
					if ffi.C.ioctl(fd, code, buffer) == 0 then
						local size = buffer[0]
						if size.col > 0 and size.row > 0 and size.xpixel > 0 and size.ypixel > 0 then
							return size.xpixel / size.col, size.ypixel / size.row
						end
					end
				end
			end
		end
	end
end

-- Query the kernel, not terminal input: Neovim does not forward CSI 14t/16t
-- replies through TermResponse. Pixel totals are integers, and some terminals
-- derive them from rounded cell sizes. Division cannot recover that precision.
function M.cell_size(config)
	config = config or {}
	local width, height
	if read_size then
		local ok, cw, ch = pcall(read_size)
		if ok then
			width, height = cw, ch
		end
	end
	local source = width and "ioctl" or "fallback"
	return config.cell_width or width or 9,
		config.cell_height or height or 18,
		{
			detected_width = width,
			detected_height = height,
			width_source = config.cell_width and "manual" or source,
			height_source = config.cell_height and "manual" or source,
		}
end

return M
