local M = {}
M.defaults = { provider = "google", source = "en", target = "zh-CN", timeout = 10, fallback = true }
local cache, order = {}, {}

local function google_result(data)
	if type(data) ~= "table" or type(data[1]) ~= "table" then
		return
	end
	local chunks = {}
	for _, part in ipairs(data[1]) do
		if type(part) == "table" and type(part[1]) == "string" then
			chunks[#chunks + 1] = part[1]
		end
	end
	return table.concat(chunks)
end

function M.request(value, options, callback)
	local opts = vim.tbl_extend("force", M.defaults, options or {})
	local job = {}
	job.kill = function()
		job.cancelled = true
		if job.process then
			pcall(job.process.kill, job.process, 15)
		end
	end
	local key = table.concat({ opts.provider, opts.source, opts.target, tostring(opts.fallback), value }, "\0")
	local function finish(result, err)
		vim.schedule(function()
			if job.cancelled or job.done then
				return
			end
			job.done = true
			if result and result ~= "" then
				if not cache[key] then
					order[#order + 1] = key
				end
				cache[key] = result
				if #order > 32 then
					cache[table.remove(order, 1)] = nil
				end
			else
				result, err = nil, err or "服务没有返回译文"
			end
			callback(result, err)
		end)
	end
	if cache[key] then
		finish(cache[key])
		return job
	end
	if #value > 5000 then
		finish(nil, "请缩短选区后重试（最多 5000 字节）")
		return job
	end
	local function query(provider)
		if job.cancelled then
			return
		end
		if provider == "mymemory" and #value > 500 then
			finish(nil, "免费备用服务一次最多 500 字节，请缩短选区后重试")
			return
		end
		local args = {
			"curl",
			"--silent",
			"--show-error",
			"--fail",
			"--get",
			"--connect-timeout",
			"5",
			"--max-time",
			tostring(opts.timeout),
			"--max-filesize",
			"65536",
		}
		local function param(parameter)
			vim.list_extend(args, { "--data-urlencode", parameter })
		end
		if provider == "google" then
			for _, parameter in ipairs({ "client=gtx", "sl=" .. opts.source, "tl=" .. opts.target, "dt=t" }) do
				param(parameter)
			end
			args[#args + 1] = "https://translate.googleapis.com/translate_a/single"
		else
			param("langpair=" .. opts.source .. "|" .. opts.target)
			args[#args + 1] = "https://api.mymemory.translated.net/get"
		end
		-- Text travels on stdin; PDF content is never interpolated into a shell
		-- command, written to disk, or exposed in process arguments.
		param("q@-")
		local ok, proc = pcall(
			vim.system,
			args,
			{ stdin = value, text = true, timeout = opts.timeout * 1000 + 1000 },
			function(response)
				vim.schedule(function()
					if job.cancelled then
						return
					end
					job.process = nil
					local valid, data = pcall(vim.json.decode, response.stdout or "")
					local result
					if response.code == 0 and valid and type(data) == "table" then
						if provider == "google" then
							result = google_result(data)
						elseif tonumber(data.responseStatus) == 200 and type(data.responseData) == "table" then
							result = data.responseData.translatedText
						end
					end
					if type(result) == "string" and vim.trim(result) ~= "" then
						return finish(vim.trim(result))
					end
					if provider == "google" and opts.fallback and opts.source ~= "auto" then
						return query("mymemory")
					end
					finish(nil, "免费翻译暂时不可用，请检查网络或稍后重试")
				end)
			end
		)
		if ok then
			job.process = proc
		else
			finish(nil, "无法启动 curl，请先安装 curl")
		end
	end
	query(opts.provider)
	return job
end

return M
