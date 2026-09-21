local M = {}
local text = require("pdfpreview.text")
local graphics = require("pdfpreview.graphics")
local layout = require("pdfpreview.layout")

local function obscured(s, origin)
	local top, left = origin.row - 1, origin.col - 1
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local config = vim.api.nvim_win_get_config(win)
		if win ~= s.win and config.relative ~= "" and not config.hide then
			local pos = vim.api.nvim_win_get_position(win)
			local width, height = config.width, config.height
			local border = config.border or {}
			local function edge(index)
				local value = border[index]
				if type(value) == "table" then
					value = value[1]
				end
				return value and value ~= "" and 1 or 0
			end
			width, height = width + edge(4) + edge(8), height + edge(2) + edge(6)
			if
				pos[1] < top + s.frame.height
				and pos[1] + height > top
				and pos[2] < left + s.frame.width
				and pos[2] + width > left
			then
				return true
			end
		end
	end
	return false
end

function M.rectangles(frame, pages, first, last)
	local rects = {}
	for n = first.page, last.page do
		local page, geometry = pages[n], frame.layout.pages[n]
		if page and geometry and geometry.top < frame.y + frame.height and geometry.top + geometry.height > frame.y then
			local left, top = text.left(frame, geometry), geometry.top - frame.y
			local lines = {}
			for i = n == first.page and first.index or 1, n == last.page and last.index or #page.words do
				local word = page.words[i]
				local rect = lines[word.line]
				if not rect then
					rect = { x1 = 1, y1 = 1, x2 = 0, y2 = 0 }
					lines[word.line] = rect
				end
				rect.x1, rect.y1 = math.min(rect.x1, word.x1), math.min(rect.y1, word.y1)
				rect.x2, rect.y2 = math.max(rect.x2, word.x2), math.max(rect.y2, word.y2)
			end
			local order = vim.tbl_keys(lines)
			table.sort(order)
			for _, line in ipairs(order) do
				local rect = lines[line]
				rect.x1, rect.y1 =
					math.max(0, left + rect.x1 * geometry.width), math.max(0, top + rect.y1 * geometry.height)
				rect.x2, rect.y2 =
					math.min(frame.width, left + rect.x2 * geometry.width),
					math.min(frame.height, top + rect.y2 * geometry.height)
				if rect.x2 > rect.x1 and rect.y2 > rect.y1 then
					rects[#rects + 1] = rect
				end
			end
		end
	end
	return rects
end

function M.new(s, config, active, repaint)
	local self = { pages = {}, requested = {}, overlays = {}, generation = 0, version = 0 }
	local function changed()
		self.version = self.version + 1
		if repaint and s.renderer == "surface" and active(s) then
			repaint(s)
		end
	end
	local function notice(value, level)
		vim.notify("pdfpreview: " .. value, level or vim.log.levels.INFO)
	end
	function self:hide()
		self.redraw_ticket = nil
		for _, image in ipairs(self.overlays) do
			graphics.delete(image)
		end
		self.overlays = {}
	end
	function self:clear()
		self:hide()
		self.generation = self.generation + 1
		self.pages, self.requested = {}, {}
		self.start, self.finish, self.first, self.last = nil, nil, nil, nil
		self.dragging, self.copy_pending, self.error = false, nil, nil
		changed()
	end
	function self:redraw()
		self.redraw_ticket = nil
		if not active(s) or not s.frame or not self.first or vim.fn.getcmdtype() ~= "" then
			return self:hide()
		end
		-- Surface selections are part of the PDF pixels, so they share its
		-- positioning, clipping and lifetime even when terminal windows change.
		if s.renderer == "surface" then
			return self:hide()
		end
		vim.cmd.redraw()
		local origin = vim.fn.screenpos(s.win, vim.fn.line("w0", s.win), 1)
		if origin.row == 0 or origin.col == 0 then
			return self:hide()
		end
		-- Only popups covering this viewport need protection from positive-z
		-- images. Sidebar UIs such as Snacks Explorer also use floating windows.
		if obscured(s, origin) then
			return self:hide()
		end
		local frame, previous = s.frame, self.overlays
		local available, wanted, retained, changed = {}, {}, {}, false
		for _, image in ipairs(previous) do
			available[image.selection_key] = image
		end
		for _, rect in ipairs(M.rectangles(frame, self.pages, self.first, self.last)) do
			local key =
				table.concat({ origin.row, origin.col, frame.cw, frame.ch, rect.x1, rect.y1, rect.x2, rect.y2 }, ":")
			local image = available[key]
			wanted[#wanted + 1] = { key = key, rect = rect, image = image }
			if image then
				retained[image], available[key] = true, nil
			else
				changed = true
			end
		end
		if not changed and next(available) == nil then
			return
		end
		-- Extending a range changes only its end lines. Reuse unchanged rectangles
		-- instead of uploading the entire selected area on every mouse movement.
		self.overlays = {}
		local ok, err = pcall(graphics.synchronized, function()
			for _, image in ipairs(previous) do
				if not retained[image] then
					graphics.delete(image)
				end
			end
			for _, item in ipairs(wanted) do
				local image = item.image or graphics.selection_rectangle(item.rect, origin, frame.cw, frame.ch)
				image.selection_key = item.key
				self.overlays[#self.overlays + 1] = image
			end
		end)
		if not ok then
			for _, image in ipairs(previous) do
				pcall(graphics.delete, image)
			end
			self:hide()
			notice(tostring(err), vim.log.levels.WARN)
		end
	end
	function self:schedule()
		if self.redraw_ticket or (not self.first and #self.overlays == 0) then
			return
		end
		local ticket = {}
		self.redraw_ticket = ticket
		vim.defer_fn(function()
			if self.redraw_ticket == ticket then
				self:redraw()
			end
		end, 16)
	end
	function self:resolve()
		local a = self.start and self.pages[self.start.page]
		local b = self.finish and self.pages[self.finish.page]
		local first, last = text.range(a and text.hit(a, self.start, true), b and text.hit(b, self.finish))
		if not vim.deep_equal(first, self.first) or not vim.deep_equal(last, self.last) then
			self.first, self.last = first, last
			changed()
		end
		if self.first then
			-- Only visible intermediate pages are needed for feedback. Copy loads
			-- the remaining pages in the range through the same serialized worker.
			local frame = s.frame
			if frame then
				for _, n in ipairs(layout.visible(frame.layout, frame.y, frame.height)) do
					if n >= self.first.page and n <= self.last.page then
						self:load(n)
					end
				end
			end
		end
		self:schedule()
		if self.copy_pending then
			self:copy(self.copy_pending)
		end
	end
	function self:load(n)
		if self.requested[n] or self.pages[n] then
			return
		end
		self.requested[n] = true
		local generation = self.generation
		self.source = self.source or text.new(s.path, config.pdftotext, s.pages)
		self.source:get(n, function(page, err)
			if s.closed or self.generation ~= generation then
				return
			end
			if not page then
				self.error, self.copy_pending = err, nil
				notice(err, vim.log.levels.ERROR)
				return
			end
			self.pages[n] = page
			changed()
			if self.start and n == self.start.page and #page.words == 0 then
				notice("This page has no selectable text (scanned PDFs need OCR).")
				self.copy_pending = nil
			end
			self:resolve()
		end)
	end
	function self:mouse(kind, mouse)
		mouse = mouse or vim.fn.getmousepos()
		if kind == "release" then
			self.dragging = false
		end
		if mouse.winid ~= s.win or not active(s) or not s.frame then
			return
		end
		if kind ~= "press" and kind ~= "release" and not self.dragging then
			return
		end
		if kind == "release" and not self.start then
			return
		end
		local origin = vim.fn.screenpos(s.win, vim.fn.line("w0", s.win), 1)
		local point = text.point(s.frame, mouse.screencol - origin.col + 0.5, mouse.screenrow - origin.row + 0.5)
		if kind == "press" then
			self:clear()
			if not point then
				return
			end
			if vim.fn.executable(config.pdftotext) ~= 1 then
				notice("Missing pdftotext; install Poppler to select PDF text.", vim.log.levels.ERROR)
				return
			end
			self.start, self.dragging = point, true
		end
		if not point or not self.start then
			return
		end
		self.finish = point
		self:load(point.page)
		self:resolve()
	end
	function self:copy(register)
		register = register or "+"
		if self.error then
			return
		end
		if not self.first then
			if self.start and self.finish and (not self.pages[self.start.page] or not self.pages[self.finish.page]) then
				self.copy_pending = register
			else
				notice("Select PDF text with the left mouse button first.")
				self.copy_pending = nil
			end
			return
		end
		self.copy_pending = register
		for n = self.first.page, self.last.page do
			self:load(n)
		end
		local value = text.extract(self.pages, self.first, self.last)
		if not value or value == "" then
			return
		end
		self.copy_pending = nil
		if register == "_" then
			return value
		end
		vim.fn.setreg('"', value, "v")
		vim.fn.setreg("0", value, "v")
		if register ~= '"' and register ~= "0" then
			if (register == "+" or register == "*") and vim.fn.has("clipboard") ~= 1 then
				notice(
					"Copied to the unnamed register; no system clipboard provider is available.",
					vim.log.levels.WARN
				)
			else
				vim.fn.setreg(register, value, "v")
			end
		end
		return value
	end
	function self:close()
		self:clear()
		if self.source then
			self.source:close()
		end
	end
	return self
end

return M
