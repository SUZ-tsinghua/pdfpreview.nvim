return {
	{
		"SUZ-tsinghua/pdfpreview.nvim",
		main = "pdfpreview",
		lazy = false,
		build = vim.fn.has("mac") == 1 and "make native" or nil,
		opts = { auto_open = true },
	},
	{
		"folke/snacks.nvim",
		opts = function(_, opts)
			opts.image = opts.image or {}
			local formats = opts.image.formats or require("snacks").config.image.formats
			opts.image.formats = vim.tbl_filter(function(format)
				return format:lower() ~= "pdf"
			end, formats)
		end,
	},
}
