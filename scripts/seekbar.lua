-- YouTube-like player chrome (local overlay only).

local mp = require("mp")
local utils = require("mp.utils")

local ov = mp.create_osd_overlay("ass-events")
ov.z = 70
local BAR_H = 76
local TOP_H = 56
local thumb_id = 20
local ffmpeg = nil
local hover_t = nil
local last_thumb_sec = -1
local gen_busy = false
local visible = false
local hide_timer = nil
local last_mx, last_my = -1, -1
local bar_armed = false
local vol_open = false
local tmp_bgra = mp.command_native({"expand-path", "~~/thumb.bgra"})
local TW, TH = 160, 90
local hits = {}

local function find_ffmpeg()
    local dir = mp.command_native({"expand-path", "~~exe_dir/"})
    for _, n in ipairs({"ffmpeg.exe", "ffmpeg"}) do
        local p = dir .. n
        local fi = utils.file_info(p)
        if fi then return p end
    end
    return nil
end

local function esc(s)
    return tostring(s or ""):gsub("\\", "\\\\"):gsub("{", "("):gsub("}", ")")
end

local function osd_size()
    return mp.get_property_number("osd-width") or 1280, mp.get_property_number("osd-height") or 720
end

local function fmt(t)
    t = math.max(0, math.floor(t or 0))
    local s = t % 60
    local m = math.floor(t / 60) % 60
    local h = math.floor(t / 3600)
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

local function rect(x, y, w, h, col, al)
    return string.format(
        "{\\an7\\pos(%.0f,%.0f)\\bord0\\shad0\\p1\\1c&H%s&\\1a&H%s&}m 0 0 l %.0f 0 l %.0f %.0f l 0 %.0f{\\p0}",
        x, y, col, al or "00", w, w, h, h)
end

local function label(x, y, size, col, align, s)
    return string.format(
        "{\\an%d\\pos(%.0f,%.0f)\\fnMalgun Gothic\\fs%d\\b0\\bord0\\shad0\\1c&H%s&}%s",
        align or 7, x, y, size, col, esc(s))
end

local function add_hit(x, y, w, h, kind)
    hits[#hits + 1] = {x = x, y = y, w = w, h = h, kind = kind}
end

local function hit_at(mx, my)
    for i = #hits, 1, -1 do
        local h = hits[i]
        if mx >= h.x and mx <= h.x + h.w and my >= h.y and my <= h.y + h.h then
            return h.kind
        end
    end
    return nil
end

local function hide_thumb()
    mp.command_native({"overlay-remove", thumb_id})
    last_thumb_sec = -1
end

local function show_thumb(x, y)
    local fi = utils.file_info(tmp_bgra)
    if not fi then return end
    mp.command_native({
        "overlay-add", thumb_id, math.floor(x), math.floor(y),
        tmp_bgra, 0, "bgra", TW, TH, TW * 4
    })
end

local function progress_geom()
    local ow, oh = osd_size()
    return 16, ow - 32, oh - 54
end

local function request_thumb(sec)
    if not ffmpeg or gen_busy then return end
    local path = mp.get_property("path")
    if not path or path:match("^https?://") then return end
    sec = math.floor(sec)
    if sec == last_thumb_sec then return end
    last_thumb_sec = sec
    gen_busy = true
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        args = {
            ffmpeg, "-hide_banner", "-loglevel", "error",
            "-ss", tostring(sec), "-i", path,
            "-frames:v", "1", "-an",
            "-vf", string.format("scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2", TW, TH, TW, TH),
            "-pix_fmt", "bgra", "-f", "rawvideo", "-y", tmp_bgra
        }
    }, function()
        gen_busy = false
        if hover_t and visible then
            local ow, oh = osd_size()
            local dur = mp.get_property_number("duration") or 1
            local x0, bw, y0 = progress_geom()
            local ratio = math.max(0, math.min(1, hover_t / dur))
            local bx = x0 + bw * ratio
            show_thumb(bx - TW / 2, y0 - TH - 14)
        end
    end)
end

local function seek_at(mx)
    local dur = mp.get_property_number("duration") or 0
    if dur <= 0 then return nil end
    local x0, bw = progress_geom()
    local t = (mx - x0) / bw
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return t * dur
end

local function progress_hit(mx, my)
    local ow, oh = osd_size()
    local x0, bw, y0 = progress_geom()
    if my < y0 - 10 or my > y0 + 14 then return nil end
    if mx < x0 - 4 or mx > x0 + bw + 4 then return nil end
    return seek_at(mx)
end

local function hide_bar()
    visible = false
    hover_t = nil
    vol_open = false
    hide_thumb()
    ov.data = ""
    ov:update()
    if bar_armed then
        mp.remove_key_binding("yt-click")
        bar_armed = false
    end
end

local function schedule_hide()
    if hide_timer then hide_timer:kill() end
    hide_timer = mp.add_timeout(1.6, function()
        if hover_t then return end
        if mp.get_property_bool("pause") then return end
        hide_bar()
    end)
end

local function draw()
    hits = {}
    local path = mp.get_property("path")
    local ow, oh = osd_size()
    ov.res_x, ov.res_y = ow, oh
    if not path or ow < 80 or not visible then
        ov.data = ""
        ov:update()
        if not visible then hide_thumb() end
        return
    end
    local pos = mp.get_property_number("time-pos") or 0
    local dur = mp.get_property_number("duration") or 0
    if dur <= 0 then dur = 1 end
    local paused = mp.get_property_bool("pause")
    local muted = mp.get_property_bool("mute")
    local vol = mp.get_property_number("volume") or 0
    local fs = mp.get_property_bool("fullscreen")
    local title = mp.get_property("media-title") or ""
    local a, b = mp.get_property("ab-loop-a"), mp.get_property("ab-loop-b")
    local x0, bw, y0 = progress_geom()
    local thick = hover_t and 5 or 3
    local parts = {}

    -- YouTube-style bottom / top scrims
    for i = 0, 7 do
        local al = string.format("%02X", 20 + i * 12)
        parts[#parts + 1] = rect(0, oh - BAR_H + i * (BAR_H / 8), ow, BAR_H / 8 + 1, "000000", al)
    end
    for i = 0, 5 do
        local al = string.format("%02X", 70 - i * 11)
        parts[#parts + 1] = rect(0, i * (TOP_H / 6), ow, TOP_H / 6 + 1, "000000", al)
    end
    parts[#parts + 1] = label(20, 14, 16, "FFFFFF", 7, title)

    -- progress (YouTube red)
    parts[#parts + 1] = rect(x0, y0, bw, thick, "FFFFFF", "C0")
    local played = math.max(2, bw * (pos / dur))
    parts[#parts + 1] = rect(x0, y0, played, thick, "0000FF", "00")
    local knobx = x0 + played - 6
    parts[#parts + 1] = rect(knobx, y0 - 4, 12, thick + 8, "FFFFFF", "00")
    if a and a ~= "no" then
        parts[#parts + 1] = rect(x0 + bw * (tonumber(a) / dur), y0 - 6, 2, thick + 12, "FFFFFF", "00")
    end
    if b and b ~= "no" then
        parts[#parts + 1] = rect(x0 + bw * (tonumber(b) / dur), y0 - 6, 2, thick + 12, "FFFFFF", "00")
    end
    if hover_t then
        local hx = x0 + bw * (hover_t / dur)
        parts[#parts + 1] = label(hx, y0 - 10, 12, "FFFFFF", 2, fmt(hover_t))
    end
    add_hit(x0, y0 - 10, bw, 20, "seek")

    -- icon row
    local iy = oh - 38
    local play = paused and "▶" or "❚❚"
    parts[#parts + 1] = label(28, iy, 18, "FFFFFF", 7, play)
    add_hit(12, oh - 48, 44, 40, "play")
    parts[#parts + 1] = label(68, iy, 16, "FFFFFF", 7, "⏭")
    add_hit(56, oh - 48, 36, 40, "next")
    parts[#parts + 1] = label(108, iy, 16, "FFFFFF", 7, muted and "🔇" or "🔊")
    add_hit(96, oh - 48, 36, 40, "mute")
    if vol_open then
        parts[#parts + 1] = rect(140, iy + 8, 72, 4, "FFFFFF", "A0")
        parts[#parts + 1] = rect(140, iy + 8, math.max(2, 72 * (vol / 150)), 4, "FFFFFF", "00")
        add_hit(140, iy, 80, 24, "vol")
    end
    local tx = vol_open and 230 or 148
    parts[#parts + 1] = label(tx, iy + 2, 13, "FFFFFF", 7, fmt(pos) .. " / " .. fmt(dur))

    parts[#parts + 1] = label(ow - 28, iy, 16, "FFFFFF", 9, fs and "⛶" or "⛶")
    add_hit(ow - 52, oh - 48, 44, 40, "fs")
    parts[#parts + 1] = label(ow - 72, iy, 13, "FFFFFF", 9, "CC")
    add_hit(ow - 100, oh - 48, 40, 40, "sub")

    if paused then
        parts[#parts + 1] = rect(ow / 2 - 34, oh / 2 - 34, 68, 68, "000000", "70")
        parts[#parts + 1] = label(ow / 2, oh / 2 - 16, 28, "FFFFFF", 8, "▶")
        add_hit(ow / 2 - 34, oh / 2 - 34, 68, 68, "play")
    end

    ov.data = table.concat(parts, "\n")
    ov:update()
end

local function over_side_panel(mx)
    local ow = select(1, osd_size())
    local r = mp.get_property_number("video-margin-ratio-right") or 0
    local l = mp.get_property_number("video-margin-ratio-left") or 0
    if r > 0.02 and mx >= ow * (1 - r) then return true end
    if l > 0.02 and mx <= ow * l then return true end
    return false
end

local function in_chrome(mx, my)
    if over_side_panel(mx) then return false end
    local ow, oh = osd_size()
    if my >= oh - BAR_H then return true end
    if my <= TOP_H then return true end
    local paused = mp.get_property_bool("pause")
    if paused and mx >= ow / 2 - 34 and mx <= ow / 2 + 34 and my >= oh / 2 - 34 and my <= oh / 2 + 34 then
        return true
    end
    return false
end

local function handle_click()
    local m = mp.get_property_native("mouse-pos")
    if not m then return end
    local kind = hit_at(m.x, m.y)
    if kind == "play" then
        mp.command("cycle pause")
    elseif kind == "next" then
        mp.command("playlist-next")
        mp.set_property_bool("pause", false)
    elseif kind == "mute" then
        vol_open = not vol_open
        if not vol_open then mp.command("cycle mute") end
        draw()
    elseif kind == "vol" then
        local v = (m.x - 140) / 72
        if v < 0 then v = 0 elseif v > 1 then v = 1 end
        mp.set_property_number("volume", v * 150)
        mp.set_property_bool("mute", false)
        draw()
    elseif kind == "fs" then
        mp.command("cycle fullscreen")
    elseif kind == "sub" then
        mp.command("cycle sub-visibility")
    elseif kind == "seek" then
        local t = seek_at(m.x)
        if t then mp.commandv("seek", t, "absolute") end
    end
end

local function arm_click(on)
    if on and not bar_armed then
        bar_armed = true
        mp.add_forced_key_binding("MBTN_LEFT", "yt-click", handle_click)
    elseif (not on) and bar_armed then
        mp.remove_key_binding("yt-click")
        bar_armed = false
    end
end

mp.observe_property("mouse-pos", "native", function(_, m)
    if not m or not mp.get_property("path") then return end
    if m.x == last_mx and m.y == last_my then return end
    last_mx, last_my = m.x, m.y
    visible = true
    local t = progress_hit(m.x, m.y)
    if t then
        hover_t = t
        request_thumb(t)
        if hide_timer then hide_timer:kill() hide_timer = nil end
    else
        if hover_t then
            hover_t = nil
            hide_thumb()
        end
        if in_chrome(m.x, m.y) then
            if hide_timer then hide_timer:kill() hide_timer = nil end
        else
            schedule_hide()
        end
    end
    arm_click(in_chrome(m.x, m.y) or mp.get_property_bool("pause"))
    draw()
end)

mp.observe_property("pause", "bool", function(_, paused)
    if paused then
        visible = true
        if hide_timer then hide_timer:kill() hide_timer = nil end
        arm_click(true)
        draw()
    else
        schedule_hide()
    end
end)

mp.observe_property("time-pos", "number", function() if visible then draw() end end)
mp.observe_property("osd-width", "number", function() if visible then draw() end end)
mp.observe_property("volume", "number", function() if visible then draw() end end)
mp.observe_property("mute", "bool", function() if visible then draw() end end)
mp.observe_property("ab-loop-a", "native", function() if visible then draw() end end)
mp.observe_property("ab-loop-b", "native", function() if visible then draw() end end)
mp.register_event("end-file", function()
    if hide_timer then hide_timer:kill() hide_timer = nil end
    hide_bar()
end)

ffmpeg = find_ffmpeg()
