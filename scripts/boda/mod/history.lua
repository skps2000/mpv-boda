-- 이어보기 기록. 저장 시점이 중요한데, end-file/shutdown 에서는 이미 path 와
-- time-pos 를 읽을 수 없다. 그래서 파일이 내려가기 직전인 on_unload 훅을 쓴다.
local mp = require("mp")
local util = require("lib.util")
local state = require("lib.state")
local opts = require("lib.options")

local M = {}

local function find(path)
    for _, h in ipairs(state.history) do
        if h.path == path then return h end
    end
    return nil
end

M.find = find

local function upsert(path, pos, dur)
    if not path or util.is_url(path) then return end
    local out = { { path = path, pos = pos or 0, dur = dur or 0, seen = os.time() } }
    for _, h in ipairs(state.history) do
        if h.path ~= path and #out < opts.history_size then out[#out + 1] = h end
    end
    state.history = out
    state.mark("history")
end

local function snapshot()
    local path = mp.get_property("path")
    if not path then return end
    local pos = mp.get_property_number("time-pos")
    if not pos then return end
    local dur = mp.get_property_number("duration") or 0
    if dur > 0 and pos >= dur - 1 then pos = dur end
    upsert(path, pos, dur)
end

M.snapshot = snapshot

local function on_loaded()
    local path = mp.get_property("path")
    if not path then return end
    state.remember_folder(path)

    if opts.resume then
        local h = find(path)
        local cur = mp.get_property_number("time-pos") or 0
        local dur = mp.get_property_number("duration") or 0
        if h and (h.pos or 0) > 3 and cur < 2 and (dur <= 0 or h.pos < dur * 0.92) then
            mp.commandv("seek", h.pos, "absolute")
            mp.osd_message("이어보기 " .. util.fmt_time(h.pos), 1.5)
        elseif cur > 2 then
            mp.osd_message("이어보기 " .. util.fmt_time(cur), 1.2)
        end
    end
    snapshot()
end

function M.init()
    mp.add_hook("on_unload", 50, snapshot)
    mp.register_event("file-loaded", on_loaded)
    mp.add_periodic_timer(30, function()
        if mp.get_property("path") then snapshot() end
    end)
    mp.observe_property("pause", "bool", function(_, paused)
        if paused then snapshot() end
    end)

    mp.add_key_binding(nil, "history-clear", function()
        state.history = {}
        state.mark("history")
        state.flush()
        mp.osd_message("기록을 지웠습니다")
    end)
end

return M
