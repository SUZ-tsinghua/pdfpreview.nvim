vim.opt.rtp:prepend(vim.fn.getcwd())
local original, calls, queue = vim.system, {}, {}
vim.system = function(args, opts, callback)
	local call = { args = args, opts = opts, callback = callback }
	calls[#calls + 1], queue[#queue + 1] = call, call
	return {
		kill = function()
			call.killed = true
		end,
	}
end
local translate = require("pdfpreview.translate")
local function tick()
	vim.wait(10, function()
		return false
	end, 1)
end
local function reply(code, data)
	local call = assert(table.remove(queue, 1))
	call.callback({ code = code, stdout = type(data) == "string" and data or vim.json.encode(data) })
	tick()
	return call
end
local received, failure, count = nil, nil, 0
local function complete(value, err)
	received, failure, count = value, err, count + 1
end
local text = 'rigid body; $(touch SHOULD_NOT_EXIST) `literal` "quotes" & 中文'
translate.request(text, {}, complete)
assert(#calls == 1 and calls[1].opts.stdin == text, "Selection is supplied verbatim on stdin")
for _, arg in ipairs(calls[1].args) do
	assert(not arg:find("SHOULD_NOT_EXIST", 1, true), "Text never enters argv or a shell")
end
assert(calls[1].opts.timeout == 11000, "Requests have a process deadline")
reply(0, { { { "刚体" }, { "动力学" } } })
assert(received == "刚体动力学" and not failure and count == 1, "Unicode translation chunks retain order")
translate.request(text, {}, complete)
tick()
assert(#calls == 1 and count == 2, "Repeat translations use a bounded memory cache")
translate.request("a short sentence", {}, complete)
reply(22, "limited")
assert(
	#queue == 1 and vim.tbl_contains(queue[1].args, "https://api.mymemory.translated.net/get"),
	"A failed free endpoint uses the short-text fallback"
)
reply(0, { responseStatus = 200, responseData = { translatedText = "一句短句" } })
assert(received == "一句短句" and count == 3)
translate.request("fail on both", {}, complete)
reply(0, "<html>unavailable</html>")
reply(0, { responseStatus = 429, responseData = { translatedText = "quota" } })
assert(not received and failure and count == 4, "Service errors are not presented as translations")
translate.request("no fallback", { fallback = false }, complete)
reply(1, "")
assert(#queue == 0 and failure and count == 5, "Fallback can be disabled")
translate.request(string.rep("x", 501), {}, complete)
reply(22, "")
assert(
	#queue == 0 and failure:find("500", 1, true) and count == 6,
	"Overlong fallback text is never silently truncated"
)
local job = translate.request("cancel request", {}, complete)
local pending = queue[1]
job.kill()
reply(0, { { { "late" } } })
assert(pending.killed and count == 6, "Closing cancels the process and suppresses late results")
local cached = translate.request(text, {}, complete)
cached.kill()
tick()
assert(count == 6, "Cached results also respect popup cancellation")
vim.system = function()
	error("missing executable")
end
translate.request("no curl", {}, complete)
tick()
assert(failure:find("curl", 1, true) and count == 7, "Missing dependencies report an actionable error")
vim.system = original
print("PASS: free translation, Unicode, stdin isolation, deadlines, cache, fallback, quota errors and cancellation")
