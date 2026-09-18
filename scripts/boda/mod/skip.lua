-- Remembers intro and outro points per file and skips them next time.
local mp = require("mp")
local util = require("lib.util")
local state = require("lib.state")
local t = require("lib.i18n").t

local M = {}

local watching = false
local done = false

local function check(_, pos)
    if not pos or done then return end
    local path = mp.get_property("path")
    local s = state.skip_of(path)
    if not s or (s.outro or 0) <= 0 then return end
    if pos < s.outro then return end
    done = true
    local count = mp.get_property_number("playlist-count") or 1
    local pos = mp.get_property_number("playlist-pos") or 0
    if pos + 1 < count then
        mp.commandv("playlist-next")
        mp.set_property_bool("pause", false)
        mp.osd_message(t("skip_outro"))
    end
end

-- Watch time-pos only for files that have an outro, to avoid a per-frame callback.
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
    local pos = mp.get_property_number("time-pos")
    if not path or not pos then return end
    local s = state.skip_of(path) or {}
    if kind == "intro" then
        s.intro = pos
    else
        s.outro = pos
    end
    state.set_skip(path, s.intro, s.outro)
    watch((s.outro or 0) > 0)
    done = false
    mp.osd_message(kind == "intro" and t("intro_marked", util.fmt_time(pos))
        or t("outro_marked", util.fmt_time(pos)))
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
        mp.osd_message(t("skip_cleared"))
    end
    mp.add_key_binding(nil, "clear-skip", clear)
    mp.register_script_message("boda-clear-skip", clear)

    mp.register_event("file-loaded", function()
        done = false
        local s = state.skip_of(mp.get_property("path"))
        watch(s ~= nil and (s.outro or 0) > 0)
        if not s or (s.intro or 0) <= 1 then return end
        -- Skip only when starting from the beginning, so resume positions survive.
        mp.add_timeout(0.35, function()
            local now = mp.get_property_number("time-pos") or 0
            if now < 2 then
                mp.commandv("seek", s.intro, "absolute")
                mp.osd_message(t("skip_intro"))
            end
        end)
    end)

    mp.register_event("end-file", function() watch(false) end)
end

return M
