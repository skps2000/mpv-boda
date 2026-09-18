-- mpv 의 Lua 환경 (LuaJIT, mp 전역 제공)
std = "luajit"
read_globals = { "mp" }
unused_args = false
self = false

-- 한국어 주석은 UTF-8 에서 한 글자가 3바이트라, 바이트 기준 줄 길이가 실제 화면 너비와
-- 맞지 않는다. 그래서 주석/문자열 줄은 재지 않고 코드 줄만 제한한다.
max_line_length = false
max_code_line_length = 140
