-- Highlight names cannot be deleted from Neovim. Recycle a bounded set of
-- names instead of allocating one for every raster ever displayed. Keeping
-- this module separate also preserves leases across graphics-module reloads.
local M = {}
local free, leased, next_slot = {}, {}, 0

function M.acquire(image, placement)
	local name = table.remove(free)
	if not name then
		next_slot = next_slot + 1
		name = "PdfPreviewSlot" .. next_slot
	end
	vim.api.nvim_set_hl(0, name, { fg = image, sp = placement, nocombine = true })
	leased[name] = true
	return name
end

function M.release(name)
	if not leased[name] then
		return
	end
	vim.api.nvim_set_hl(0, name, {})
	leased[name] = nil
	free[#free + 1] = name
end

return M
