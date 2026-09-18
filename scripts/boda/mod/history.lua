-- Watch history. Timing matters: at end-file and shutdown the path and time-pos
-- are already gone, so the on_unload hook does the saving instead.
local mp = require("mp")
local util = require("lib.util")
local state = require("lib.state")
local opts = require("lib.options")
local t = require("lib.i18n").t

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
    if not util.is_url(path) then state.remember_folder(util.dirname(path)) end

    if opts.resume then
        local h = find(path)
        local cur = mp.get_property_number("time-pos") or 0
        local dur = mp.get_property_number("duration") or 0
        if h and (h.pos or 0) > 3 and cur < 2 and (dur <= 0 or h.pos < dur * 0.92) then
            mp.commandv("seek", h.pos, "absolute")
            mp.osd_message(t("resume_at", util.fmt_time(h.pos)), 1.5)
        elseif cur > 2 then
            mp.osd_message(t("resume_at", util.fmt_time(cur)), 1.2)
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

    -- Open an entry by index (used by the menu and the idle screen)
    mp.register_script_message("boda-play-history", function(n)
        local h = (state.history or {})[tonumber(n) or 0]
        if not h or not h.path then return end
        mp.commandv("loadfile", h.path, "replace")
        mp.set_property_bool("pause", false)
    end)

    mp.add_key_binding(nil, "history-clear", function()
        state.history = {}
        state.mark("history")
        state.flush()
        mp.osd_message(t("history_cleared"))
    end)
end

return M
