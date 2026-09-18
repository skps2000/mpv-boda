-- Save and restore playback position locally (file switch, quit, history click).

local mp = require("mp")
local utils = require("mp.utils")

local hist_path = mp.command_native({"expand-path", "~~/history.txt"})
local MAX = 40
local hist = {}
local resume_pending = nil
local last_path = nil

local function load()
    hist = {}
    local f = io.open(hist_path, "r")
    if not f then return end
    for line in f:lines() do
        local p, pos, dur, seen = line:match("^(.-)|([^|]*)|([^|]*)|([^|]*)$")
        if p and p ~= "" then
            hist[#hist + 1] = {
                path = p,
                pos = tonumber(pos) or 0,
                dur = tonumber(dur) or 0,
                seen = tonumber(seen) or 0
            }
        end
    end
    f:close()
end

local function save()
    local f = io.open(hist_path, "w")
    if not f then return end
    for i = 1, math.min(MAX, #hist) do
        local h = hist[i]
        f:write(h.path, "|", string.format("%.2f", h.pos or 0), "|",
            string.format("%.2f", h.dur or 0), "|", tostring(h.seen or 0), "\n")
    end
    f:close()
end

local function find(path)
    if not path then return nil end
    for _, h in ipairs(hist) do
        if h.path == path then return h end
    end
    return nil
end

local function publish()
    pcall(function()
        mp.set_property_native("user-data/pp-history", hist)
    end)
end

local function upsert_path(path, pos, dur)
    if not path or path:match("^https?://") then return end
    pos = pos or 0
    dur = dur or 0
    local out = {{path = path, pos = pos, dur = dur, seen = os.time()}}
    for _, h in ipairs(hist) do
        if h.path ~= path then out[#out + 1] = h end
        if #out >= MAX then break end
    end
    hist = out
    save()
    publish()
end

local function snapshot()
    local path = mp.get_property("path")
    if not path then return end
    local pos = mp.get_property_number("time-pos") or 0
    local dur = mp.get_property_number("duration") or 0
    if pos < 1 then
        local h = find(path)
        if h then pos = h.pos end
    end
    upsert_path(path, pos, dur)
    if dur > 0 and pos >= dur * 0.92 then
        pcall(function() mp.commandv("delete-watch-later-config") end)
        upsert_path(path, dur, dur)
    else
        pcall(function() mp.command("write-watch-later-config") end)
    end
    last_path = path
end

local function fmt(t)
    t = math.max(0, math.floor(t or 0))
    return string.format("%d:%02d", math.floor(t / 60), t % 60)
end

mp.register_event("start-file", function()
    if last_path and last_path ~= mp.get_property("path") then
        -- previous file already snapshotted on end-file
    end
    local path = mp.get_property("path")
    local h = find(path)
    if h and h.pos and h.pos > 3 then
        local dur = h.dur or 0
        if dur <= 0 or h.pos < dur - 8 then
            resume_pending = h.pos
        else
            resume_pending = nil
        end
    else
        resume_pending = nil
    end
end)

mp.register_event("file-loaded", function()
    local path = mp.get_property("path")
    local dur = mp.get_property_number("duration") or 0
    local cur = mp.get_property_number("time-pos") or 0
    local h = find(path)
    local target = resume_pending
    if not target and h and h.pos and h.pos > 3 then
        if dur <= 0 or h.pos < dur * 0.92 then target = h.pos end
    end
    resume_pending = nil
    if target and target > 3 and cur < 2 then
        mp.add_timeout(0.05, function()
            mp.commandv("seek", target, "absolute")
            mp.osd_message("이어보기 " .. fmt(target), 1.5)
        end)
    elseif cur > 2 then
        mp.osd_message("이어보기 " .. fmt(cur), 1.2)
    end
    mp.add_timeout(1.2, snapshot)
end)

mp.register_event("end-file", function(ev)
    snapshot()
    last_path = nil
end)

mp.register_event("shutdown", snapshot)
mp.add_periodic_timer(8, function()
    if mp.get_property("path") then snapshot() end
end)

mp.observe_property("pause", "bool", function(_, paused)
    if paused then snapshot() end
end)

load()
publish()
