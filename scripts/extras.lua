-- Skip intro/outro, PiP, boss key, upscale, dual-sub, m3u, bookmarks persist, record.
-- Local only.

local mp = require("mp")
local utils = require("mp.utils")

local skip_file = mp.command_native({"expand-path", "~~/skip-map.txt"})
local bm_file = mp.command_native({"expand-path", "~~/bookmarks.txt"})
local skip = {} -- path -> {intro=n, outro=n}
local pip_on = false
local sharp_on = true
local hid = false

local function load_kv(path, fn)
    local f = io.open(path, "r")
    if not f then return end
    for line in f:lines() do fn(line) end
    f:close()
end

load_kv(skip_file, function(line)
    local p, i, o = line:match("^(.-)|([^|]*)|([^|]*)$")
    if p then skip[p] = {intro = tonumber(i) or 0, outro = tonumber(o) or 0} end
end)

local function save_skip()
    local f = io.open(skip_file, "w")
    if not f then return end
    for p, s in pairs(skip) do
        f:write(p, "|", s.intro or 0, "|", s.outro or 0, "\n")
    end
    f:close()
end

local function cur_skip()
    local p = mp.get_property("path")
    if not p then return nil, nil end
    if not skip[p] then skip[p] = {intro = 0, outro = 0} end
    return skip[p], p
end

mp.register_script_message("pp-mark-intro", function()
    local s = cur_skip()
    if not s then return end
    s.intro = mp.get_property_number("time-pos") or 0
    save_skip()
    mp.osd_message(string.format("오프닝 끝: %.1fs", s.intro))
end)

mp.register_script_message("pp-mark-outro", function()
    local s = cur_skip()
    if not s then return end
    s.outro = mp.get_property_number("time-pos") or 0
    save_skip()
    mp.osd_message(string.format("엔딩 시작: %.1fs", s.outro))
end)

mp.register_script_message("pp-clear-skip", function()
    local p = mp.get_property("path")
    if p then skip[p] = {intro = 0, outro = 0} save_skip() end
    mp.osd_message("스킵 구간 삭제")
end)

mp.register_event("file-loaded", function()
    mp.add_timeout(0.4, function()
        local s = skip[mp.get_property("path") or ""]
        if not s or (s.intro or 0) <= 1 then return end
        local t = mp.get_property_number("time-pos") or 0
        -- do not override resume: only skip when still at the start
        if t < 2 then
            mp.commandv("seek", s.intro, "absolute")
            mp.osd_message("오프닝 스킵")
        end
    end)
end)

mp.observe_property("time-pos", "number", function(_, t)
    if not t then return end
    local s = skip[mp.get_property("path") or ""]
    if not s or not s.outro or s.outro <= 0 then return end
    local dur = mp.get_property_number("duration") or 0
    if t >= s.outro and t < s.outro + 1.2 then
        mp.commandv("playlist-next")
        mp.set_property_bool("pause", false)
        mp.osd_message("엔딩 스킵")
    end
end)

-- PiP
mp.register_script_message("pp-pip", function()
    pip_on = not pip_on
    if pip_on then
        mp.set_property_bool("fullscreen", false)
        mp.set_property_bool("ontop", true)
        mp.set_property_number("window-scale", 0.38)
        mp.osd_message("PiP 켜짐")
    else
        mp.set_property_bool("ontop", false)
        mp.set_property_number("window-scale", 1)
        mp.osd_message("PiP 꺼짐")
    end
end)

-- Boss key
mp.register_script_message("pp-boss", function()
    hid = not hid
    if hid then
        mp.set_property_bool("pause", true)
        mp.set_property_bool("window-minimized", true)
    else
        mp.set_property_bool("window-minimized", false)
        mp.set_property_bool("pause", false)
    end
end)

-- Built-in sharp upscale (no downloaded shaders)
mp.register_script_message("pp-upscale", function()
    sharp_on = not sharp_on
    if sharp_on then
        mp.set_property("scale", "ewa_lanczossharp")
        mp.set_property("deband", "yes")
        mp.osd_message("선명 업스케일 ON")
    else
        mp.set_property("scale", "bilinear")
        mp.set_property("deband", "no")
        mp.osd_message("업스케일 OFF")
    end
end)

-- Dual sub: make next subtitle track secondary
mp.register_script_message("pp-dual-sub", function()
    local sid = mp.get_property("sid")
    mp.command("cycle secondary-sid")
    local ss = mp.get_property("secondary-sid")
    mp.osd_message("듀얼 자막: 주=" .. tostring(sid) .. " 부=" .. tostring(ss))
end)

-- m3u save/load
mp.register_script_message("pp-save-m3u", function()
    local dir = mp.command_native({"expand-path", "~~desktop/"})
    local path = dir .. "playlist.m3u"
    local pl = mp.get_property_native("playlist") or {}
    local f = io.open(path, "w")
    if not f then mp.osd_message("저장 실패") return end
    f:write("#EXTM3U\n")
    for _, e in ipairs(pl) do
        f:write(e.filename, "\n")
    end
    f:close()
    mp.osd_message("재생목록 저장: " .. path)
end)

mp.register_script_message("pp-load-m3u", function()
    local r = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        args = {
            "powershell", "-NoProfile", "-STA", "-Command",
            [[Add-Type -AssemblyName System.Windows.Forms
$f=New-Object System.Windows.Forms.OpenFileDialog
$f.Filter='M3U|*.m3u;*.m3u8|All|*.*'
if($f.ShowDialog() -eq 'OK'){$f.FileName}]]
        }
    })
    if r and r.stdout then
        local p = r.stdout:gsub("%s+$", "")
        if p ~= "" then mp.commandv("loadlist", p, "replace") end
    end
end)

-- Stream record to desktop
mp.register_script_message("pp-record", function()
    local cur = mp.get_property("stream-record") or ""
    if cur ~= "" then
        mp.set_property("stream-record", "")
        mp.osd_message("녹화 중지")
        return
    end
    local dest = mp.command_native({"expand-path", "~~desktop/"}) .. "record-" .. os.date("%Y%m%d-%H%M%S") .. ".mkv"
    mp.set_property("stream-record", dest)
    mp.osd_message("녹화 시작: " .. dest)
end)

-- Theme (osd)
mp.register_script_message("pp-theme", function()
    mp.osd_message("오버레이는 어두운 테마 고정 (영상 영역은 원본)")
end)

-- Bookmarks persist
local bms = {}
load_kv(bm_file, function(line)
    local p, rest = line:match("^(.-)|(.+)$")
    if p then
        bms[p] = {}
        for t in rest:gmatch("[^,]+") do bms[p][#bms[p] + 1] = tonumber(t) end
    end
end)

local function save_bm()
    local f = io.open(bm_file, "w")
    if not f then return end
    for p, arr in pairs(bms) do
        f:write(p, "|", table.concat(arr, ","), "\n")
    end
    f:close()
end

mp.register_event("file-loaded", function()
    local p = mp.get_property("path")
    local arr = (p and bms[p]) or {}
    pcall(function() mp.set_property_native("user-data/pp-bookmarks", arr) end)
end)

mp.observe_property("user-data/pp-bookmarks", "native", function(_, v)
    local p = mp.get_property("path")
    if p and type(v) == "table" then
        bms[p] = v
        save_bm()
    end
end)
