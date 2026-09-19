-- Bottom seek bar with the title and buttons; scales with the window.
local mp = require("mp")
local util = require("lib.util")
local ui = require("lib.ui")
local icons = require("lib.icons")
local opts = require("lib.options")
local state = require("lib.state")

local M = {}

local layer
local visible = false
local hide_timer = nil
local hover_time = nil
local vol_open = false
local thumb_path, ffmpeg = nil, nil
local thumb_id = 21
local thumb_shown = false
local thumb_want, thumb_busy, thumb_last = nil, false, -1
local TW, TH = 192, 108

-- The seek bar sits well above the control row: with the two almost touching,
-- the eye read them as one strip and a click meant for a button could land on
-- the track.
local function geom()
    local ow, oh = ui.osd_size()
    local s = ui.scale()
    local right = math.max(0, ui.reserved_right)
    local pad = 18 * s
    local x0 = pad
    local w = math.max(40, ow - right - pad * 2)
    return x0, w, oh - 58 * s, s, ow - right, oh
end

-- ── thumbnails ─────────────────────────────────────────────────────
local function hide_thumb()
    if not thumb_shown then return end
    mp.command_native({ "overlay-remove", thumb_id })
    thumb_shown = false
end

-- Where the preview sits: lifted above the time label so it does not cover it,
-- and clamped left and right so it never leaves the window.
local function thumb_pos()
    local x0, bw, y0, s, vw = geom()
    local dur = mp.get_property_number("duration") or 0
    if not hover_time or dur <= 0 then return nil end
    local bx = x0 + bw * util.clamp(hover_time / dur, 0, 1)
    local x = util.clamp(bx - TW / 2, 8 * s, math.max(8 * s, vw - TW - 8 * s))
    return x, y0 - TH - 34 * s
end

local function show_thumb()
    if not util.exists(thumb_path) then return end
    local x, y = thumb_pos()
    if not x then return end
    mp.command_native({ "overlay-add", thumb_id, math.floor(x), math.floor(y),
        thumb_path, 0, "bgra", TW, TH, TW * 4 })
    thumb_shown = true
end

local function make_thumb()
    if thumb_busy or not thumb_want or not ffmpeg then return end
    local path = mp.get_property("path")
    if not path or util.is_url(path) then return end
    local sec = math.floor(thumb_want)
    if sec == thumb_last then return end
    thumb_busy, thumb_last = true, sec
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        args = { ffmpeg, "-hide_banner", "-loglevel", "error", "-ss", tostring(sec),
            "-i", path, "-frames:v", "1", "-an", "-vf",
            string.format("scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2",
                TW, TH, TW, TH),
            "-pix_fmt", "bgra", "-f", "rawvideo", "-y", thumb_path },
    }, function()
        thumb_busy = false
        if hover_time and visible then
            show_thumb()
            M.draw()
            make_thumb() -- run again if the cursor moved meanwhile
        end
    end)
end

-- Look for the file instead of running it, so a missing ffmpeg logs no error.
local function find_ffmpeg()
    if not opts.thumbnails then return end
    local cands = {}
    if opts.ffmpeg ~= "" then cands[#cands + 1] = opts.ffmpeg end
    local dir = mp.command_native({ "expand-path", "~~exe_dir/" })
    if dir and dir ~= "" then cands[#cands + 1] = dir .. "/ffmpeg.exe" end
    for entry in (os.getenv("PATH") or ""):gmatch("[^;]+") do
        cands[#cands + 1] = entry:gsub("[\\/]+$", "") .. "\\ffmpeg.exe"
    end
    for _, c in ipairs(cands) do
        if util.exists(c) then
            ffmpeg = c
            return
        end
    end
end

-- ── drawing ───────────────────────────────────────────────────────
local draw -- wrapped with ui.guard below
local function draw_impl()
    if not visible or not mp.get_property("path") or not ui.ready() then
        layer:hide()
        hide_thumb()
        return
    end
    local _, oh = layer:start()
    local x0, bw, y0, s, vw = geom()
    local t = ui.theme

    local pos = mp.get_property_number("time-pos") or 0
    local dur = mp.get_property_number("duration") or 0
    if dur <= 0 then dur = math.max(pos, 1) end
    local paused = mp.get_property_bool("pause")
    local muted = mp.get_property_bool("mute")
    local vol = mp.get_property_number("volume") or 0
    local vmax = mp.get_property_number("volume-max") or 130

    -- top and bottom scrims
    local bar_h = 86 * s
    local top_h = 52 * s
    for i = 0, 7 do
        layer:rect(0, oh - bar_h + i * (bar_h / 8), vw, bar_h / 8 + 1, "000000", 32 + i * 18)
    end
    for i = 0, 5 do
        layer:rect(0, i * (top_h / 6), vw, top_h / 6 + 1, "000000", 110 - i * 18)
    end

    local title = mp.get_property("media-title") or ""
    layer:text_fit(20 * s, 13 * s, 16 * s, t.text, 7, title, vw - 40 * s)

    -- progress bar, translucent white so it reads over bright video
    local thick = (hover_time and 5 or 3) * s
    layer:rect(x0, y0, bw, thick, t.text, 120)
    local played = util.clamp(bw * (pos / dur), 0, bw)
    layer:rect(x0, y0, math.max(2, played), thick, t.accent, 255)

    for _, ch in ipairs(mp.get_property_native("chapter-list") or {}) do
        local cx = x0 + bw * util.clamp((ch.time or 0) / dur, 0, 1)
        layer:rect(cx, y0 - 1, math.max(1, 2 * s), thick + 2, t.text, 150)
    end
    for _, key in ipairs({ "ab-loop-a", "ab-loop-b" }) do
        local v = tonumber(mp.get_property(key))
        if v then
            layer:rect(x0 + bw * util.clamp(v / dur, 0, 1), y0 - 5 * s, math.max(2, 2 * s),
                thick + 10 * s, t.text, 230)
        end
    end
    layer:rect(x0 + played - 6 * s, y0 - 4 * s, 12 * s, thick + 8 * s, t.text, 255)

    if hover_time then
        local hx = x0 + bw * util.clamp(hover_time / dur, 0, 1)
        local label = util.fmt_time(hover_time)
        local lw = util.text_width(label, 12 * s) + 14 * s
        local lx = util.clamp(hx - lw / 2, x0, x0 + bw - lw)
        -- border behind the preview (the image itself comes from overlay-add)
        if thumb_shown then
            local tx, ty = thumb_pos()
            if tx then layer:rect(tx - 2 * s, ty - 2 * s, TW + 4 * s, TH + 4 * s, "000000", 210) end
        end
        layer:rect(lx, y0 - 28 * s, lw, 20 * s, "000000", 200)
        layer:text(lx + lw / 2, y0 - 26 * s, 12 * s, t.text, 8, label)
    end

    layer:hit(x0 - 4 * s, y0 - 11 * s, bw + 8 * s, 22 * s, {
        id = "seek",
        press = function(mx)
            local target = util.clamp((mx - x0) / bw, 0, 1) * dur
            mp.commandv("seek", target, "absolute")
        end,
        drag = function(mx)
            local target = util.clamp((mx - x0) / bw, 0, 1) * dur
            mp.commandv("seek", target, "absolute")
        end,
    })

    -- button row
    local iy = oh - 28 * s
    local isz = 16 * s
    local x = x0

    local function button(id, path, w, on_click, color)
        local hot = layer:hovered(id)
        layer:draw(x, iy - isz / 2, color or t.text, hot and ui.alpha.icon_hot or ui.alpha.icon, path)
        layer:hit(x - 10 * s, iy - 18 * s, w + 20 * s, 36 * s, { id = id, click = on_click })
        x = x + w + 20 * s
    end

    button("play", paused and icons.play(isz) or icons.pause(isz), isz,
        function() mp.command("cycle pause") end)
    button("prev", icons.prev(isz), isz, function()
        mp.command("playlist-prev")
        mp.set_property_bool("pause", false)
    end)
    button("next", icons.next(isz), isz, function()
        mp.command("playlist-next")
        mp.set_property_bool("pause", false)
    end)

    local vx = x
    button("mute", icons.speaker(isz, muted), isz, function() mp.command("cycle mute") end)
    if vol_open or layer:hovered("mute") or layer:hovered("vol") then
        local vw2 = 70 * s
        layer:rect(vx + isz + 14 * s, iy - 2 * s, vw2, 4 * s, t.track, 190)
        layer:rect(vx + isz + 14 * s, iy - 2 * s,
            math.max(2, vw2 * util.clamp(vol / vmax, 0, 1)), 4 * s, t.text, 255)
        layer:hit(vx + isz + 10 * s, iy - 16 * s, vw2 + 12 * s, 32 * s, {
            id = "vol",
            press = function(mx)
                local v = util.clamp((mx - (vx + isz + 14 * s)) / vw2, 0, 1) * vmax
                mp.set_property_number("volume", util.round(v))
                mp.set_property_bool("mute", false)
            end,
            drag = function(mx)
                local v = util.clamp((mx - (vx + isz + 14 * s)) / vw2, 0, 1) * vmax
                mp.set_property_number("volume", util.round(v))
            end,
            scroll = function(dir) mp.commandv("add", "volume", dir * opts.wheel_volume) end,
        })
        x = x + vw2 + 16 * s
    end

    local clock = util.fmt_time(pos) .. " / " .. util.fmt_time(dur)
    layer:text(x, iy - 7 * s, 13 * s, t.text, 7, clock)

    -- buttons on the right
    local rx = vw - 20 * s
    local function rbutton(id, path, w, on_click, dim)
        rx = rx - w
        local hot = layer:hovered(id)
        layer:draw(rx, iy - isz / 2, t.text,
            hot and ui.alpha.icon_hot or (dim and ui.alpha.icon_off or ui.alpha.icon), path)
        layer:hit(rx - 10 * s, iy - 18 * s, w + 20 * s, 36 * s, { id = id, click = on_click })
        rx = rx - 20 * s
    end

    rbutton("fs", icons.fullscreen(isz), isz, function() mp.command("cycle fullscreen") end)
    rbutton("list", icons.list(isz), isz, function()
        mp.commandv("script-message", "boda-panel", "toggle")
    end)
    local subs_on = mp.get_property_bool("sub-visibility") and mp.get_property("sid") ~= "no"
    rbutton("sub", icons.subtitle(isz), isz, function()
        mp.command("cycle sub-visibility")
    end, not subs_on)

    -- big play button in the middle while paused
    if paused then
        local c = 34 * s
        layer:rect(vw / 2 - c, oh / 2 - c, c * 2, c * 2, "000000", 110)
        layer:draw(vw / 2 - c * 0.3, oh / 2 - c * 0.5, t.text, 255, icons.play(c))
        layer:hit(vw / 2 - c, oh / 2 - c, c * 2, c * 2,
            { id = "bigplay", click = function() mp.command("cycle pause") end })
    end

    layer:flush()
end

draw = ui.guard("seek bar", draw_impl)
M.draw = draw

-- ── show and hide ─────────────────────────────────────────────────
local function cancel_hide()
    if hide_timer then
        hide_timer:kill()
        hide_timer = nil
    end
end

local function schedule_hide()
    cancel_hide()
    hide_timer = mp.add_timeout(1.6, function()
        hide_timer = nil
        if hover_time or mp.get_property_bool("pause") then return end
        visible = false
        hover_time = nil
        vol_open = false
        draw()
    end)
end

local function over_bar(x, y)
    local _, _, y0, s, vw, oh = geom()
    if x > vw then return false end
    return y >= oh - 86 * s or y <= 52 * s or (y >= y0 - 20 * s)
end

function M.init()
    layer = ui.layer("seekbar", 70)
    layer.redraw = draw
    thumb_path = (state.dir or mp.command_native({ "expand-path", "~~state/boda" })) .. "/thumb.bgra"
    find_ffmpeg()

    ui.on_mouse(function(x, y, inside)
        if not mp.get_property("path") then return end
        if inside == false then
            hover_time = nil
            hide_thumb()
            schedule_hide()
            return
        end
        visible = true
        local x0, bw, y0, s = geom()
        local on_track = y >= y0 - 12 * s and y <= y0 + 12 * s and x >= x0 - 6 * s and x <= x0 + bw + 6 * s
        local dur = mp.get_property_number("duration") or 0
        if on_track and dur > 0 then
            hover_time = util.clamp((x - x0) / bw, 0, 1) * dur
            cancel_hide()
            if ffmpeg then
                thumb_want = hover_time
                make_thumb()
                if thumb_last >= 0 then show_thumb() end
            end
        else
            if hover_time then
                hover_time = nil
                hide_thumb()
            end
            if over_bar(x, y) or mp.get_property_bool("pause") then
                cancel_hide()
            else
                schedule_hide()
            end
        end
        draw()
    end)

    mp.observe_property("pause", "bool", function(_, paused)
        if paused then
            visible = true
            cancel_hide()
        else
            schedule_hide()
        end
        draw()
    end)

    for _, prop in ipairs({ "time-pos", "volume", "mute", "sid", "sub-visibility",
        "ab-loop-a", "ab-loop-b", "chapter-list", "video-margin-ratio-right" }) do
        mp.observe_property(prop, "native", function()
            if visible then draw() end
        end)
    end

    mp.register_event("end-file", function()
        visible = false
        hover_time = nil
        cancel_hide()
        hide_thumb()
        layer:hide()
    end)

    mp.register_event("file-loaded", function()
        thumb_last = -1
        visible = true
        schedule_hide()
        draw()
    end)

    -- reachable from a key as well
    mp.add_key_binding(nil, "osd-toggle", function()
        visible = not visible
        if visible then schedule_hide() end
        draw()
    end)
end

return M
