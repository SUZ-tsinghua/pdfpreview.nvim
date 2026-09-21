-- Unicode graphics encode image IDs as RGB colors. Recycling only highlight
-- names still creates a new terminal style for every image ever displayed.
-- Keep live leases and available identifiers across graphics-module reloads.
local M = {}
local free, released, leased = {}, {}, {}
local allocated = 0
local minimum = 64

function M.acquire()
	local id
	if allocated >= minimum then
		if #free == 0 then
			-- Two stacks form a FIFO without unbounded queue indices or shifting
			-- every free identifier on each allocation.
			for i = #released, 1, -1 do
				free[#free + 1], released[i] = released[i], nil
			end
		end
		id = table.remove(free)
	end
	if not id then
		local next_id = vim.g.pdfpreview_next_image_id or (0x600000 + (vim.uv.os_getpid() % 0x1000) * 256)
		id = next_id + 1
		assert(id < 0xFFFFFF, "Image identifier range exhausted")
		vim.g.pdfpreview_next_image_id = id
		allocated = allocated + 1
	end
	assert(not leased[id], "Image identifier is already leased")
	local lease = { id = id }
	leased[id] = lease
	return lease
end

function M.release(lease)
	if not lease or leased[lease.id] ~= lease then
		return
	end
	leased[lease.id] = nil
	released[#released + 1] = lease.id
end

return M
