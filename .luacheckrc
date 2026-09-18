-- mpv's Lua environment (LuaJIT, with mp as a global)
std = "luajit"
read_globals = { "mp" }
unused_args = false
self = false

-- A Korean character is three bytes in UTF-8, so a byte count says nothing about
-- how wide a line looks. Only code lines are measured, comments and strings are not.
max_line_length = false
max_code_line_length = 140
