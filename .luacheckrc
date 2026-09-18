-- mpv 의 Lua 환경 (LuaJIT, mp 전역 제공)
std = "luajit"
read_globals = { "mp" }
max_line_length = 120
unused_args = false
self = false

files["scripts/**/*.lua"] = {
    -- mpv 스크립트는 모듈을 require 로 불러온다
    read_globals = { "mp" },
}
