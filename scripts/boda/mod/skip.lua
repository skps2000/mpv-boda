-- 파일별 오프닝/엔딩 구간 기억과 자동 넘기기.
local mp = require("mp")
local util = require("lib.util")
local state = require("lib.state")

local M = {}

local watching = false
local done = false

local function check(_, t)
    if not t or done then return end
    local path = mp.get_property("path")
    local s = state.skip_of(path)
    if not s or (s.outro or 0) <= 0 then return end
    if t < s.outro then return end
    done = true
    local count = mp.get_property_number("playlist-count") or 1
    local pos = mp.get_property_number("playlist-pos") or 0
    if pos + 1 < count then
        mp.commandv("playlist-next")
        mp.set_property_bool("pause", false)
        mp.osd_message("엔딩 스킵")
    end
end

-- 엔딩 지점이 있는 파일에서만 time-pos 를 관찰한다 (매 프레임 콜백을 아끼려고).
local function watch(on)
    if on == watching then return end
    watching = on
    if on then
        mp.observe_property("time-pos", "number", check)
    else
        mp.unobserve_property(check)
    end
end

local function mark(kind)
    local path = mp.get_property("path")
    local t = mp.get_property_number("time-pos")
    if not path or not t then return end
    local s = state.skip_of(path) or {}
    if kind == "intro" then
        s.intro = t
    else
        s.outro = t
    end
    state.set_skip(path, s.intro, s.outro)
    watch((s.outro or 0) > 0)
    done = false
    mp.osd_message((kind == "intro" and "오프닝 끝: " or "엔딩 시작: ") .. util.fmt_time(t))
end

function M.init()
    for _, def in ipairs({ { "mark-intro", "intro" }, { "mark-outro", "outro" } }) do
        local name, kind = def[1], def[2]
        local fn = function() mark(kind) end
        mp.add_key_binding(nil, name, fn)
        mp.register_script_message("boda-" .. name, fn)
    end

    local clear = function()
        local path = mp.get_property("path")
        if path then state.set_skip(path, 0, 0) end
        watch(false)
        mp.osd_message("스킵 구간을 지웠습니다")
    end
    mp.add_key_binding(nil, "clear-skip", clear)
    mp.register_script_message("boda-clear-skip", clear)

    mp.register_event("file-loaded", function()
        done = false
        local s = state.skip_of(mp.get_property("path"))
        watch(s ~= nil and (s.outro or 0) > 0)
        if not s or (s.intro or 0) <= 1 then return end
        -- 이어보기 위치를 덮어쓰지 않도록, 처음부터 시작할 때만 넘긴다.
        mp.add_timeout(0.35, function()
            local t = mp.get_property_number("time-pos") or 0
            if t < 2 then
                mp.commandv("seek", s.intro, "absolute")
                mp.osd_message("오프닝 스킵")
            end
        end)
    end)

    mp.register_event("end-file", function() watch(false) end)
end

return M
