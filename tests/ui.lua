-- Image replies must progress inside a nested vim.wait with an unchanged grid.
-- This embedded UI acknowledges only packets actually received over RPC.
local uv = vim.uv
local stdin, stdout = uv.new_pipe(false), uv.new_pipe(false)
local replies, serial, packets, grid_cells = {}, 0, 0, 0
local unpacker = vim.mpack.Unpacker()
local exited = false
local child = assert(uv.spawn(vim.v.progpath, {
	args = { "--embed", "-u", "NONE", "-i", "NONE" },
	stdio = { stdin, stdout, nil },
}, function()
	exited = true
end))
stdout:read_start(function(err, data)
	assert(not err, err)
	if not data then
		return
	end
	local position = 1
	while position <= #data do
		local message
		message, position = unpacker(data, position)
		if message and message[1] == 1 then
			replies[message[2]] = message
		elseif message and message[1] == 2 and message[2] == "redraw" then
			for _, event in ipairs(message[3]) do
				if event[1] == "ui_send" then
					for index = 2, #event do
						local packet = event[index][1]
						if packet == "\27[?2026l" then
							stdin:write(vim.mpack.encode({
								2,
								"nvim_exec_lua",
								{ "vim.g.surface_ui_complete = ...", { packets } },
							}))
						end
						if packet:find("a=T", 1, true) and packet:find("q=0", 1, true) then
							packets = packets + 1
							local id = assert(tonumber(packet:match("i=(%d+)")))
							stdin:write(vim.mpack.encode({
								2,
								"nvim_exec_lua",
								{
									[[local id,serial=...; vim.g.surface_ui_acked=serial; vim.api.nvim_exec_autocmds('TermResponse', {data={sequence='\27_Gi=' .. id .. ';OK'}})]],
									{ id, packets },
								},
							}))
						end
					end
				elseif event[1] == "grid_line" then
					for index = 2, #event do
						for _, cell in ipairs(event[index][4]) do
							grid_cells = grid_cells + (cell[3] or 1)
						end
					end
				end
			end
		end
	end
end)
local function request(method, args)
	serial = serial + 1
	stdin:write(vim.mpack.encode({ 0, serial, method, args }))
	assert(
		vim.wait(15000, function()
			return replies[serial] ~= nil
		end, 1),
		"Embedded UI request completes"
	)
	local reply = replies[serial]
	replies[serial] = nil
	assert(reply[3] == vim.NIL, vim.inspect(reply[3]))
	return reply[4]
end
local ok, err = pcall(function()
	request("nvim_ui_attach", { 100, 35, { ext_linegrid = true, stdout_tty = true } })
	request("nvim_exec_lua", {
		[[
    local root = ...
    vim.opt.rtp:prepend(root)
    vim.o.termguicolors = true
    local viewer = require('pdfpreview')
    viewer.setup({renderer='surface', rasterizer='native', cell_width=15, cell_height=35,
      scroll_animation_ms=0, surface_refine_ms=0})
    local s = assert(viewer.open(root .. '/tests/sample.pdf'))
    local function settle()
      assert(vim.wait(10000, function()
        local p, f = s.surface_state, s.frame
        return f and f.zoom == s.zoom and f.x == s.x and f.y == s.y
          and not s.pending and not s.zoom_target and p and not p.running and not p.awaiting
      end, 1), 'Image acknowledgment completes inside vim.wait')
      assert(s.renderer == 'surface', s.surface_fallback)
    end
    settle()
    viewer.zoom(150)
    settle()
    _G.surface_ui = {viewer=viewer, s=s, settle=settle}
  ]],
		{ vim.fn.getcwd() },
	})
	local prior_packets = packets
	grid_cells = 0
	request("nvim_exec_lua", {
		[[
    local t = surface_ui
    for _=1,3 do
      t.viewer.scroll(1)
      t.settle()
      assert(vim.wait(500,function()
        return (vim.g.surface_ui_complete or 0) >= vim.g.surface_ui_acked
      end,1),'The acknowledged frame releases synchronized output without another input')
    end
  ]],
		{},
	})
	assert(packets - prior_packets == 3, "The UI receives each warm image without a benchmark redraw or query")
	assert(grid_cells < 100, "Warm pixel movement preserves the placeholder grid")
	request("nvim_exec_lua", {
		[[
    local t = surface_ui
    local directory = t.s.backend.dir
    t.viewer.close()
    assert(vim.wait(5000, function() return vim.uv.fs_stat(directory) == nil end, 1))
  ]],
		{},
	})
end)
stdin:write(vim.mpack.encode({ 2, "nvim_command", { "qa!" } }))
if not vim.wait(5000, function()
	return exited
end, 1) then
	child:kill("sigterm")
	vim.wait(2000, function()
		return exited
	end, 1)
end
stdin:close()
stdout:close()
child:close()
assert(ok, err)
print("PASS: nested UI transport flush, real received-image replies, unchanged grid, and worker cleanup")
