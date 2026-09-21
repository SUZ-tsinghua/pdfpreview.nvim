local M = {}

function M.wait(predicate, label)
	assert(vim.wait(15000, predicate, 2), label)
end

function M.acknowledge(data)
	if data:find("a=T", 1, true) and data:find("q=0", 1, true) then
		local id = assert(tonumber(data:match("i=(%d+)")))
		vim.schedule(function()
			vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=" .. id .. ";OK" } })
		end)
	end
end

-- A child event loop processes actual mouse input and buffer mappings.
function M.with_child(callback)
	local channel = vim.fn.jobstart(
		{ vim.v.progpath, "--embed", "--headless", "-u", "NONE", "-i", "NONE" },
		{ rpc = true }
	)
	assert(channel > 0, "Embedded Neovim starts")
	local ok, err = xpcall(function()
		callback(function(method, ...)
			return vim.rpcrequest(channel, method, ...)
		end)
	end, debug.traceback)
	vim.fn.jobstop(channel)
	assert(ok, err)
end

function M.mouse_reader(request, options, indices)
	return request(
		"nvim_exec_lua",
		[[
		local root, options, indices = ...
		vim.opt.rtp:prepend(root)
		vim.o.mouse = "a"
		vim.o.termguicolors = true
		vim.o.lines, vim.o.columns = 40, 100
		require("pdfpreview.graphics").sink = function() end
		viewer = require("pdfpreview")
		viewer.setup(vim.tbl_extend("force", {
			rasterizer = "poppler", cell_width = 10, cell_height = 20,
		}, options))
		s = assert(viewer.open(root .. "/tests/sample.pdf"))
		assert(vim.wait(15000, function() return s.frame and not s.pending end, 2))
		s.selection:load(1)
		assert(vim.wait(15000, function() return s.selection.pages[1] ~= nil end, 2))
		vim.cmd.redraw()
		local text = require("pdfpreview.text")
		local origin = vim.fn.screenpos(s.win, vim.fn.line("w0", s.win), 1)
		local page, positions = s.frame.layout.pages[1], {}
		for _, index in ipairs(indices) do
			local unit = text.units(s.selection.pages[1])[index]
			positions[#positions + 1] = {
				origin.row - 1 + math.floor(page.top - s.frame.y + (unit.y1 + unit.y2) * page.height / 2),
				origin.col - 1 + math.floor(text.left(s.frame, page) + (unit.x1 + unit.x2) * page.width / 2),
			}
		end
		return positions
	]],
		{ vim.fn.getcwd(), options, indices }
	)
end

return M
