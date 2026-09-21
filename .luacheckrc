std = "luajit"
globals = { "vim" }
-- Factory methods intentionally bind their own implicit receiver.
self = false
ignore = { "431/self" }
-- Formatting is checked by StyLua.
max_line_length = false
