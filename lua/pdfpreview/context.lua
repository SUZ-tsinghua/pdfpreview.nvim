local M = {}
local api = vim.api

function M.new(s, config)
	local self = { generation = 0 }
	function self:close()
		self.generation = self.generation + 1
		local popup = self.popup
		self.popup = nil
		if not popup then
			return
		end
		if popup.job then
			popup.job.kill()
		end
		if popup.group then
			api.nvim_del_augroup_by_id(popup.group)
		end
		if api.nvim_win_is_valid(popup.win) then
			api.nvim_win_close(popup.win, true)
		end
		if api.nvim_buf_is_valid(popup.buf) then
			api.nvim_buf_delete(popup.buf, { force = true })
		end
		s.selection:schedule()
	end
	local function floating(lines, title, mouse, width, height, choose)
		self:close()
		local buf = api.nvim_create_buf(false, true)
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].filetype = "pdfpreview_popup"
		api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
		width = math.max(1, math.min(width, vim.o.columns - 4))
		height = math.max(1, math.min(height, vim.o.lines - 4))
		local row = math.max(0, math.min((mouse and mouse.screenrow or 2), vim.o.lines - height - 3))
		local col = math.max(0, math.min((mouse and mouse.screencol or 3) - 1, vim.o.columns - width - 2))
		local win = api.nvim_open_win(buf, true, {
			relative = "editor",
			row = row,
			col = col,
			width = width,
			height = height,
			style = "minimal",
			border = "rounded",
			title = title,
			title_pos = "center",
			zindex = 250,
		})
		vim.wo[win].wrap, vim.wo[win].linebreak = true, true
		vim.wo[win].cursorline = choose ~= nil
		vim.wo[win].winblend = 0
		local popup = { buf = buf, win = win }
		self.popup = popup
		local function close()
			if self.popup == popup then
				self:close()
			end
		end
		local function pick(index)
			close()
			if choose then
				choose(index)
			end
		end
		for _, key in ipairs({ "q", "<Esc>", "<C-c>", "<RightMouse>" }) do
			vim.keymap.set("n", key, close, { buffer = buf, silent = true })
		end
		local function click()
			local pos = vim.fn.getmousepos()
			local origin = api.nvim_win_get_position(win)
			local clicked_row, clicked_col = pos.screenrow - origin[1] - 1, pos.screencol - origin[2] - 1
			if
				clicked_row < 1
				or clicked_row > api.nvim_win_get_height(win)
				or clicked_col < 1
				or clicked_col > api.nvim_win_get_width(win)
			then
				close()
				if pos.winid ~= 0 and api.nvim_win_is_valid(pos.winid) then
					api.nvim_set_current_win(pos.winid)
				end
			elseif choose then
				pick(clicked_row)
			else
				-- Retain normal selection/yanking inside the translated text.
				api.nvim_feedkeys(api.nvim_replace_termcodes("<LeftMouse>", true, false, true), "n", false)
			end
		end
		for _, prefix in ipairs({ "", "2-", "3-", "4-" }) do
			vim.keymap.set("n", "<" .. prefix .. "LeftMouse>", click, { buffer = buf, silent = true })
			vim.keymap.set("n", "<" .. prefix .. "RightMouse>", close, { buffer = buf, silent = true })
		end
		vim.keymap.set("n", "<RightRelease>", "<Nop>", { buffer = buf })
		if choose then
			vim.keymap.set("n", "<CR>", function()
				pick(api.nvim_win_get_cursor(win)[1])
			end, { buffer = buf, silent = true })
		end
		popup.group = api.nvim_create_augroup("pdfpreview_popup_" .. buf, { clear = true })
		api.nvim_create_autocmd({ "WinLeave", "BufWipeout" }, {
			group = popup.group,
			buffer = buf,
			callback = function()
				vim.schedule(close)
			end,
		})
		api.nvim_create_autocmd({ "VimResized", "TabLeave" }, {
			group = popup.group,
			callback = close,
		})
		s.selection:schedule()
		return popup
	end
	function self:translate(mouse)
		if s.closed then
			return
		end
		self:close()
		local generation = self.generation
		s.selection:value(function(value)
			if s.closed or self.generation ~= generation then
				return
			end
			local popup = floating({ "正在翻译…" }, " 翻译 ", mouse, 64, 3)
			popup.job = require("pdfpreview.translate").request(value, config.translation, function(result, err)
				if self.popup ~= popup or not api.nvim_buf_is_valid(popup.buf) then
					return
				end
				popup.job = nil
				local lines =
					vim.split(result or ("翻译失败：" .. (err or "未知错误")), "\n", { plain = true })
				vim.bo[popup.buf].modifiable = true
				api.nvim_buf_set_lines(popup.buf, 0, -1, false, lines)
				vim.bo[popup.buf].modifiable = false
				local width = api.nvim_win_get_width(popup.win)
				local height = 0
				for _, line in ipairs(lines) do
					height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
				end
				local opts = api.nvim_win_get_config(popup.win)
				opts.height = math.min(math.max(2, height), 18, math.max(1, vim.o.lines - 4))
				opts.row = math.max(0, math.min(opts.row, vim.o.lines - opts.height - 3))
				api.nvim_win_set_config(popup.win, opts)
			end)
		end)
	end
	function self:open(mouse)
		if s.closed or mouse.winid ~= s.win or not s.frame then
			return
		end
		if not s.selection.start then
			s.selection:mouse("press", mouse, "word")
			s.selection:mouse("release", mouse)
		end
		floating({ " 复制", " 翻译" }, " PDF ", mouse, 16, 2, function(index)
			if index == 1 then
				s.selection:copy("+")
			elseif index == 2 then
				self:translate(mouse)
			end
		end)
	end
	return self
end

return M
