-- Actions that keys can call. Each one is exposed both as a script-binding and
-- as a script-message. Default keys live in input.conf only, so the script never
-- grabs a key by itself.
local mp = require("mp")
local util = require("lib.util")
local state = require("lib.state")
local t = require("lib.i18n").t

local M = {}

local function osd(text, dur)
    mp.osd_message(text, dur or 1.2)
end

local function action(name, fn, flags)
    mp.add_key_binding(nil, name, fn, flags)
    mp.register_script_message("boda-" .. name, fn)
end

-- ── speed ───────────────────────────────────────────────────────────
local last_speed = 1.0

local function set_speed(v)
    v = util.clamp(v, 0.1, 8)
    mp.set_property_number("speed", v)
    osd(t("speed", v))
end

-- ── filters ─────────────────────────────────────────────────────────
-- Keeping on/off state in a Lua variable drifts from the real filter list.
-- Let mpv toggle it and read the list back, so a filter that failed to load is
-- never reported as "on".
local function toggle_filter(kind, label, filter, on_text, off_text)
    mp.commandv(kind, "toggle", "@" .. label .. ":" .. filter)
    local list = mp.get_property(kind) or ""
    local on = list:find("@" .. label, 1, true) ~= nil
    osd(on and on_text or off_text)
    return on
end

local function vf_action(name, label, filter, on_text, off_text)
    action(name, function() toggle_filter("vf", label, filter, on_text, off_text) end)
end

local function af_action(name, label, filter, on_text, off_text)
    action(name, function() toggle_filter("af", label, filter, on_text, off_text) end)
end

-- ── colour ──────────────────────────────────────────────────────────
local EQ = { "brightness", "contrast", "saturation", "gamma", "hue" }
local saved_eq, eq_off = nil, false

local function eq_text()
    return t("eq_values",
        mp.get_property_number("brightness") or 0,
        mp.get_property_number("contrast") or 0,
        mp.get_property_number("saturation") or 0,
        mp.get_property_number("gamma") or 0,
        mp.get_property_number("hue") or 0)
end

local function recommend()
    local transfer = tostring(mp.get_property("video-params/gamma") or "")
    local peak = mp.get_property_number("video-params/sig-peak") or 0
    if transfer:find("pq") or transfer:find("hlg") or peak > 1.2 then
        return nil, t("auto_hdr")
    end
    local h = mp.get_property_number("video-params/h") or 0
    if h >= 1440 then
        return { brightness = 0, contrast = 2, saturation = 2, gamma = 0 }, t("auto_high")
    elseif h >= 1000 then
        return { brightness = 1, contrast = 3, saturation = 3, gamma = 0 }, t("auto_fhd")
    elseif h > 0 then
        return { brightness = 2, contrast = 5, saturation = 4, gamma = -1 }, t("auto_low")
    end
    return nil, nil
end

local function apply_auto_color(quiet)
    if not state.prefs.auto_color then return end
    local eq, name = recommend()
    if not eq then
        if name and not quiet then osd(t("auto_applied", name), 1.0) end
        return
    end
    for k, v in pairs(eq) do mp.set_property_number(k, v) end
    if not quiet then osd(t("auto_applied", name), 1.0) end
end

-- ── window ──────────────────────────────────────────────────────────
local WIN_SCALES = { 0.5, 1, 1.5, 2 }
local pip_saved = nil
local boss_hidden = false

function M.init()
    -- speed
    action("speed-up", function()
        local s = mp.get_property_number("speed") or 1
        if math.abs(s - 1) > 0.01 then last_speed = s end
        set_speed(s + 0.1)
    end, { repeatable = true })
    action("speed-down", function()
        local s = mp.get_property_number("speed") or 1
        if math.abs(s - 1) > 0.01 then last_speed = s end
        set_speed(s - 0.1)
    end, { repeatable = true })
    action("speed-toggle", function()
        local s = mp.get_property_number("speed") or 1
        if math.abs(s - 1) < 0.01 then
            set_speed(last_speed)
        else
            last_speed = s
            set_speed(1)
        end
    end)
    action("speed-reset", function() set_speed(1) end)

    -- A-B loop
    local function show_ab()
        local function fmt(v)
            if not v or v == "no" then return "—" end
            return util.fmt_time(tonumber(v))
        end
        osd(t("ab_points", fmt(mp.get_property("ab-loop-a")),
            fmt(mp.get_property("ab-loop-b"))))
    end
    action("ab-a", function()
        mp.set_property_number("ab-loop-a", mp.get_property_number("time-pos") or 0)
        show_ab()
    end)
    action("ab-b", function()
        mp.set_property_number("ab-loop-b", mp.get_property_number("time-pos") or 0)
        show_ab()
    end)
    action("ab-clear-a", function()
        mp.set_property("ab-loop-a", "no")
        show_ab()
    end)
    action("ab-clear-b", function()
        mp.set_property("ab-loop-b", "no")
        show_ab()
    end)
    action("ab-clear", function()
        mp.set_property("ab-loop-a", "no")
        mp.set_property("ab-loop-b", "no")
        osd(t("ab_cleared"))
    end)
    action("ab-toggle", function()
        local a, b = mp.get_property("ab-loop-a"), mp.get_property("ab-loop-b")
        if a ~= "no" or b ~= "no" then
            mp.set_property("ab-loop-a", "no")
            mp.set_property("ab-loop-b", "no")
            osd(t("ab_cleared"))
        else
            osd(t("ab_none"))
        end
    end)
    local function nudge(which, delta)
        local v = tonumber(mp.get_property(which))
        if not v then return end
        mp.set_property_number(which, math.max(0, v + delta))
        show_ab()
    end
    mp.register_script_message("boda-ab-nudge", function(which, delta)
        nudge(which, tonumber(delta) or 0)
    end)
    mp.register_script_message("boda-ab-nudge-both", function(delta)
        local d = tonumber(delta) or 0
        nudge("ab-loop-a", d)
        nudge("ab-loop-b", d)
    end)

    -- bookmarks
    action("bookmark-add", function()
        local path = mp.get_property("path")
        local pos = mp.get_property_number("time-pos")
        if not path or not pos then return end
        local list = {}
        for i, v in ipairs(state.bookmarks_of(path)) do list[i] = v end
        list[#list + 1] = pos
        table.sort(list)
        state.set_bookmarks(path, list)
        osd(t("bookmark_added", #list, util.fmt_time(pos)))
    end)
    local function jump_bookmark(dir)
        local path = mp.get_property("path")
        local pos = mp.get_property_number("time-pos") or 0
        local best = nil
        for _, b in ipairs(state.bookmarks_of(path)) do
            if (dir > 0 and b > pos + 0.4) or (dir < 0 and b < pos - 0.4) then
                if not best or math.abs(b - pos) < math.abs(best - pos) then best = b end
            end
        end
        if best then
            mp.commandv("seek", best, "absolute")
            osd(t("bookmark_at", util.fmt_time(best)))
        else
            mp.commandv("add", "chapter", dir)
        end
    end
    action("bookmark-prev", function() jump_bookmark(-1) end)
    action("bookmark-next", function() jump_bookmark(1) end)
    action("bookmark-clear", function()
        local path = mp.get_property("path")
        if path then state.set_bookmarks(path, {}) end
        osd(t("bookmarks_cleared"))
    end)

    -- saved clips
    action("favorite-add", function()
        local path = mp.get_property("path")
        if not path then return end
        local a = tonumber(mp.get_property("ab-loop-a"))
        local b = tonumber(mp.get_property("ab-loop-b"))
        if not a then a = mp.get_property_number("time-pos") or 0 end
        if b and b < a then a, b = b, a end
        local list = {}
        for i, v in ipairs(state.favorites_of(path)) do list[i] = v end
        list[#list + 1] = { a = a, b = b, name = t("clip_n", #list + 1) }
        state.set_favorites(path, list)
        mp.commandv("script-message", "boda-refresh")
        if b then
            osd(t("fav_added_range", util.fmt_time(a), util.fmt_time(b)))
        else
            osd(t("fav_added_point", util.fmt_time(a)))
        end
    end)
    action("favorite-clear", function()
        local path = mp.get_property("path")
        if not path then return end
        state.set_favorites(path, {})
        mp.commandv("script-message", "boda-refresh")
        osd(t("fav_cleared"))
    end)

    local function favorite_at(n)
        local path = mp.get_property("path")
        local list = state.favorites_of(path)
        return path, list, list[tonumber(n) or 0]
    end
    mp.register_script_message("boda-favorite-play", function(n)
        local _, _, f = favorite_at(n)
        if not f then return end
        mp.commandv("seek", f.a, "absolute")
        mp.set_property_bool("pause", false)
    end)
    mp.register_script_message("boda-favorite-loop", function(n)
        local _, _, f = favorite_at(n)
        if not f or not f.b then return end
        mp.set_property_number("ab-loop-a", f.a)
        mp.set_property_number("ab-loop-b", f.b)
        mp.commandv("seek", f.a, "absolute")
        mp.set_property_bool("pause", false)
    end)
    mp.register_script_message("boda-favorite-remove", function(n)
        local path, list = favorite_at(n)
        local idx = tonumber(n)
        if not path or not idx or not list[idx] then return end
        local out = {}
        for i, v in ipairs(list) do
            if i ~= idx then out[#out + 1] = v end
        end
        state.set_favorites(path, out)
        mp.commandv("script-message", "boda-refresh")
        osd(t("fav_removed"))
    end)

    -- Seeking. How far each arrow-key step goes is a setting, so these go
    -- through the script instead of a plain `seek` line in input.conf.
    local function seek_by(which, dir)
        local step = tonumber((state.prefs.seek or {})[which]) or 5
        local pos = mp.get_property_number("time-pos")
        if not pos then return end
        local dur = mp.get_property_number("duration") or 0
        local target = pos + dir * step
        if dur > 0 then target = util.clamp(target, 0, dur) end
        mp.commandv("seek", target, "absolute")
        osd(util.fmt_time(target) .. (dur > 0 and (" / " .. util.fmt_time(dur)) or ""))
    end
    -- spelled out rather than built in a loop: input.conf names these, and CI
    -- cross-checks that every name it calls is registered somewhere
    local HELD = { repeatable = true }
    action("seek-back", function() seek_by("arrow", -1) end, HELD)
    action("seek-forward", function() seek_by("arrow", 1) end, HELD)
    action("seek-back-ctrl", function() seek_by("ctrl", -1) end, HELD)
    action("seek-forward-ctrl", function() seek_by("ctrl", 1) end, HELD)
    action("seek-back-shift", function() seek_by("shift", -1) end, HELD)
    action("seek-forward-shift", function() seek_by("shift", 1) end, HELD)
    action("seek-back-alt", function() seek_by("alt", -1) end, HELD)
    action("seek-forward-alt", function() seek_by("alt", 1) end, HELD)

    -- the menu sets these; kept in prefs so a change survives a restart
    mp.register_script_message("boda-seek-step", function(which, value)
        local n = tonumber(value)
        if not n or not state.prefs.seek or state.prefs.seek[which] == nil then return end
        state.prefs.seek[which] = util.clamp(math.floor(n + 0.5), 1, 36000)
        state.mark("prefs")
        state.flush()
        mp.commandv("script-message", "boda-refresh")
        osd(t("seek_step_set", t("seek_" .. which), util.fmt_time(state.prefs.seek[which])))
    end)

    -- jumping around
    action("jump-start", function()
        mp.commandv("seek", 0, "absolute")
        osd(t("jump_start"))
    end)
    action("jump-mid", function()
        local d = mp.get_property_number("duration") or 0
        if d > 0 then
            mp.commandv("seek", d / 2, "absolute")
            osd(t("jump_mid"))
        end
    end)
    action("jump-end", function()
        local d = mp.get_property_number("duration") or 0
        if d > 30 then
            mp.commandv("seek", d - 30, "absolute")
            osd(t("jump_end"))
        end
    end)

    -- colour
    action("eq-show", function() osd(eq_text()) end)
    action("eq-toggle", function()
        if not eq_off then
            saved_eq = {}
            for _, k in ipairs(EQ) do
                saved_eq[k] = mp.get_property_number(k) or 0
                mp.set_property_number(k, 0)
            end
            eq_off = true
            osd(t("eq_off"))
        else
            for _, k in ipairs(EQ) do
                mp.set_property_number(k, (saved_eq and saved_eq[k]) or 0)
            end
            eq_off = false
            osd(eq_text())
        end
    end)
    action("eq-reset", function()
        for _, k in ipairs(EQ) do mp.set_property_number(k, 0) end
        state.prefs.auto_color = false
        state.mark("prefs")
        osd(t("eq_reset"))
    end)
    action("auto-color-toggle", function()
        state.prefs.auto_color = not state.prefs.auto_color
        state.mark("prefs")
        if state.prefs.auto_color then
            apply_auto_color()
        else
            for _, k in ipairs(EQ) do mp.set_property_number(k, 0) end
            osd(t("auto_off"))
        end
    end)
    mp.register_script_message("boda-auto-color", function(mode)
        state.prefs.auto_color = (mode == "on")
        state.mark("prefs")
        if state.prefs.auto_color then
            apply_auto_color()
        else
            for _, k in ipairs(EQ) do mp.set_property_number(k, 0) end
        end
    end)

    -- video filters
    vf_action("flip-h", "hflip", "hflip", t("flip_h_on"), t("flip_h_off"))
    vf_action("flip-v", "vflip", "vflip", t("flip_v_on"), t("flip_v_off"))
    vf_action("blur", "blur", "lavfi=[gblur=sigma=1.2]", t("blur_on"), t("blur_off"))
    vf_action("sharpen", "sharp", "lavfi=[unsharp=5:5:0.8]", t("sharpen_on"), t("sharpen_off"))
    vf_action("denoise", "dn", "lavfi=[hqdn3d]", t("denoise_on"), t("denoise_off"))
    -- The old pp filter was dropped from FFmpeg; deblock replaces it.
    vf_action("deblock", "deblock", "lavfi=[deblock=filter=weak:block=4]",
        t("deblock_on"), t("deblock_off"))
    action("filters-clear", function()
        mp.commandv("vf", "clr", "")
        osd(t("filters_cleared"))
    end)

    -- Audio filters: toggle by label so scaletempo2 from mpv.conf survives.
    af_action("audio-norm", "norm", "lavfi=[dynaudnorm]", t("norm_on"), t("norm_off"))
    af_action("voice-remove", "voice", "lavfi=[stereotools=mlev=0]",
        t("voice_on"), t("voice_off"))
    af_action("stereo-swap", "swap", "lavfi=[pan=stereo|c0=c1|c1=c0]",
        t("swap_on"), t("swap_off"))
    action("audio-reset", function()
        for _, label in ipairs({ "norm", "voice", "swap" }) do
            mp.commandv("af", "remove", "@" .. label)
        end
        mp.set_property("audio-delay", 0)
        osd(t("audio_reset"))
    end)
    action("audio-delay-reset", function()
        mp.set_property("audio-delay", 0)
        osd(t("audio_delay_reset"))
    end)

    -- picture
    action("upscale-toggle", function()
        local sharp = mp.get_property("scale") == "ewa_lanczossharp"
        mp.set_property("scale", sharp and "bilinear" or "ewa_lanczossharp")
        mp.set_property("deband", sharp and "no" or "yes")
        osd(sharp and t("upscale_off") or t("upscale_on"))
    end)
    action("sub-pos-reset", function()
        mp.set_property("sub-pos", 100)
        mp.set_property("sub-scale", 1)
        osd(t("sub_pos_reset"))
    end)
    action("sub-delay-reset", function()
        mp.set_property("sub-delay", 0)
        osd(t("sub_delay_reset"))
    end)
    action("dual-sub", function()
        mp.command("cycle secondary-sid")
        osd(t("dual_sub", tostring(mp.get_property("sid")),
            tostring(mp.get_property("secondary-sid"))))
    end)
    action("rotate", function()
        local r = ((mp.get_property_number("video-rotate") or 0) + 90) % 360
        mp.set_property_number("video-rotate", r)
        osd(t("rotate", r))
    end)

    -- window
    action("window-cycle", function()
        if mp.get_property_bool("fullscreen") then mp.set_property_bool("fullscreen", false) end
        local cur = mp.get_property_number("window-scale") or 1
        local nxt = WIN_SCALES[1]
        for _, s in ipairs(WIN_SCALES) do
            if cur < s - 0.08 then
                nxt = s
                break
            end
        end
        mp.set_property_number("window-scale", nxt)
        osd(t("window_scale", string.format("%.1f", nxt)))
    end)
    action("window-reset", function()
        mp.set_property_number("window-scale", 1)
        for _, prop in ipairs({ "video-zoom", "video-pan-x", "video-pan-y" }) do
            mp.set_property_number(prop, 0)
        end
        osd(t("window_original"))
    end)
    action("window-max", function()
        local maxed = mp.get_property_bool("window-maximized")
        mp.set_property_bool("window-maximized", not maxed)
        osd(maxed and t("window_restore") or t("window_max"))
    end)
    mp.register_script_message("boda-window-scale", function(v)
        mp.set_property_bool("fullscreen", false)
        mp.set_property_number("window-scale", tonumber(v) or 1)
        osd(t("window_scale", tostring(v)))
    end)
    action("pip", function()
        if pip_saved then
            mp.set_property_bool("ontop", pip_saved.ontop)
            mp.set_property_number("window-scale", pip_saved.scale)
            pip_saved = nil
            osd(t("pip_off"))
        else
            pip_saved = {
                ontop = mp.get_property_bool("ontop") or false,
                scale = mp.get_property_number("window-scale") or 1,
            }
            mp.set_property_bool("fullscreen", false)
            mp.set_property_bool("ontop", true)
            mp.set_property_number("window-scale", 0.38)
            osd(t("pip_on"))
        end
    end)
    action("boss", function()
        boss_hidden = not boss_hidden
        if boss_hidden then
            mp.set_property_bool("pause", true)
            mp.set_property_bool("window-minimized", true)
        else
            mp.set_property_bool("window-minimized", false)
            mp.set_property_bool("pause", false)
        end
    end)

    -- capture and recording
    action("shot-clipboard", function()
        local dir = state.dir or os.getenv("TEMP") or "."
        local file = dir .. "/clipboard.png"
        mp.commandv("screenshot-to-file", file, "video")
        local script = "Add-Type -AssemblyName System.Windows.Forms,System.Drawing; " ..
            "$i=[System.Drawing.Image]::FromFile('" .. file:gsub("'", "''") .. "'); " ..
            "[System.Windows.Forms.Clipboard]::SetImage($i); $i.Dispose()"
        mp.command_native_async({
            name = "subprocess",
            playback_only = false,
            args = { "powershell", "-NoProfile", "-STA", "-WindowStyle", "Hidden", "-Command", script },
        }, function(ok, res)
            osd((ok and res and res.status == 0) and t("clip_copied") or t("clip_copy_failed"))
        end)
    end)
    action("record", function()
        if (mp.get_property("stream-record") or "") ~= "" then
            mp.set_property("stream-record", "")
            osd(t("record_stop"))
            return
        end
        local dest = mp.command_native({ "expand-path", "~~desktop/" }) ..
            "record-" .. os.date("%Y%m%d-%H%M%S") .. ".mkv"
        mp.set_property("stream-record", dest)
        osd(t("record_start", dest), 2.5)
    end)

    -- playlist files
    action("save-m3u", function()
        local list = mp.get_property_native("playlist") or {}
        if #list == 0 then
            osd(t("m3u_empty"))
            return
        end
        local path = mp.command_native({ "expand-path", "~~desktop/" }) ..
            "playlist-" .. os.date("%Y%m%d-%H%M%S") .. ".m3u8"
        local f = io.open(path, "wb")
        if not f then
            osd(t("m3u_failed"))
            return
        end
        f:write("#EXTM3U\n")
        for _, e in ipairs(list) do
            f:write(e.filename, "\n")
        end
        f:close()
        osd(t("m3u_saved", path), 2.5)
    end)

    -- misc
    action("stop", function() mp.command("stop") end)
    action("reopen", function()
        local path = mp.get_property("path")
        if path then mp.commandv("loadfile", path, "replace") end
    end)
    action("reload-sub", function()
        mp.command("rescan-external-files")
        osd(t("sub_rescan"))
    end)
    -- Show a file where it lives, in whatever the system calls its file manager.
    local function reveal(path)
        path = util.absolute(path)
        if not path or path == "" or util.is_url(path) then
            osd(t("reveal_none"))
            return
        end
        local args
        local platform = mp.get_property("platform") or ""
        if platform == "windows" then
            -- /select, wants the comma glued to a backslash path
            args = { "explorer.exe", "/select," .. path:gsub("/", "\\") }
        elseif platform == "darwin" then
            args = { "open", "-R", path }
        else
            args = { "xdg-open", util.dirname(path) or path }
        end
        mp.command_native_async({ name = "subprocess", playback_only = false,
            detach = true, args = args }, function() end)
    end

    action("reveal", function() reveal(mp.get_property("path")) end)

    -- the same, for a row of the playlist rather than what is playing
    mp.register_script_message("boda-reveal-index", function(index)
        local pl = mp.get_property_native("playlist") or {}
        local e = pl[(tonumber(index) or -1) + 1]
        reveal(e and e.filename)
    end)

    action("open-config", function()
        local dir = mp.command_native({ "expand-path", "~~/" })
        local platform = mp.get_property("platform") or ""
        local opener = (platform == "windows" and "explorer.exe")
            or (platform == "darwin" and "open") or "xdg-open"
        mp.command_native_async({
            name = "subprocess",
            playback_only = false,
            detach = true,
            args = { opener, dir },
        }, function() end)
    end)
    action("about", function()
        osd(t("about", mp.get_property("mpv-version") or "mpv", state.dir or ""), 4)
    end)
    -- input.conf passes an i18n key (na_dvd, ...); anything else is shown as it is
    mp.register_script_message("boda-na", function(what)
        osd(t("not_available", t(what or "?")))
    end)

    mp.register_event("file-loaded", function()
        eq_off = false
        mp.add_timeout(0.3, function() apply_auto_color(false) end)
    end)
end

return M
