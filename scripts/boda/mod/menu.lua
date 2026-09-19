-- Context menu.
--
-- mpv 0.41 shows a native window menu when you put a tree in the menu-data
-- property and call the context-menu command. Submenus, check marks, shortcut
-- labels and keyboard navigation all come for free, so nothing is drawn here.
-- Where that is missing, the same tree is walked with mp.input.select instead.
local mp = require("mp")
local util = require("lib.util")
local playlist = require("lib.playlist")
local ui = require("lib.ui")
local opts = require("lib.options")
local state = require("lib.state")
local t = require("lib.i18n").t

local M = {}

local has_input, input = pcall(require, "mp.input")
local native_ok = nil -- nil = not known yet

-- ── tree helpers ──────────────────────────────────────────────────
local SEP = { type = "separator" }

local function item(title, cmd, o)
    o = o or {}
    local st = {}
    if o.checked then st[#st + 1] = "checked" end
    if o.disabled then st[#st + 1] = "disabled" end
    return { title = title, cmd = cmd, shortcut = o.key, state = st }
end

local function submenu(title, items, o)
    o = o or {}
    if #items == 0 then
        items = { item(t("menu_none"), "", { disabled = true }) }
        o.disabled = true
    end
    return {
        type = "submenu",
        title = title,
        submenu = items,
        state = o.disabled and { "disabled" } or {},
    }
end

local function bind(name) return "script-binding boda/" .. name end

local function message(name, ...)
    local parts = { "script-message", "boda-" .. name }
    for _, v in ipairs({ ... }) do parts[#parts + 1] = tostring(v) end
    return table.concat(parts, " ")
end

local function has_file()
    return mp.get_property("path") ~= nil
end

local function near(a, b)
    return a and b and math.abs(a - b) < 0.01
end

-- ── pieces ────────────────────────────────────────────────────────
local function tracks_of(kind, prop)
    local items = {}
    local cur = mp.get_property(prop)
    if kind == "sub" then
        items[#items + 1] = item(t("sub_off"), "set sid no", { checked = cur == "no" })
    end
    for _, tr in ipairs(mp.get_property_native("track-list") or {}) do
        if tr.type == kind then
            local label = tr.title or tr.codec or t("track_n", tostring(tr.id))
            if tr.lang then label = "[" .. tr.lang .. "] " .. label end
            if tr.external then label = label .. "  (" .. t("track_external") .. ")" end
            items[#items + 1] = item(label, "set " .. prop .. " " .. tostring(tr.id),
                { checked = tr.selected })
        end
    end
    return items
end

local function audio_devices()
    local items = {}
    local cur = mp.get_property("audio-device")
    for _, d in ipairs(mp.get_property_native("audio-device-list") or {}) do
        items[#items + 1] = item(d.description or d.name,
            string.format('set audio-device "%s"', d.name), { checked = d.name == cur })
        if #items >= 12 then break end
    end
    return items
end

local function recent_folders()
    local items = {}
    for i, dir in ipairs(state.recent or {}) do
        items[#items + 1] = item(dir, message("open-recent", i))
        if i >= 8 then break end
    end
    return items
end

local function history_items()
    local items = {}
    for i, h in ipairs(state.history or {}) do
        local pct = (h.dur and h.dur > 0) and math.floor((h.pos or 0) / h.dur * 100) or 0
        items[#items + 1] = item(string.format("%s  (%d%%)", util.basename(h.path), pct),
            message("play-history", i))
        if i >= 8 then break end
    end
    return items
end

-- A playlist can be long, so only show what is around the current entry.
local function playlist_items()
    local pl = mp.get_property_native("playlist") or {}
    local cur = (mp.get_property_number("playlist-pos") or 0) + 1
    local first = math.max(1, cur - 10)
    local last = math.min(#pl, first + 29)
    local items = {}
    for i = first, last do
        local e = pl[i]
        items[#items + 1] = item(playlist.name(e),
            "playlist-play-index " .. (i - 1), { checked = e.current })
    end
    if #pl > last then
        items[#items + 1] = item(t("menu_more_items", #pl - last),
            bind("panel-pl"))
    end
    return items
end

local function sort_items()
    local defs = {
        { "none", "sort_none" }, { "name", "sort_name" }, { "size", "sort_size" },
        { "quality", "sort_quality" }, { "duration", "sort_duration" }, { "mtime", "sort_mtime" },
    }
    local items = {}
    for _, d in ipairs(defs) do
        local on = state.prefs.sort == d[1]
        local label = t(d[2])
        if on and d[1] ~= "none" then
            label = label .. (state.prefs.sort_desc and "  ↓" or "  ↑")
        end
        items[#items + 1] = item(label, message("sort", d[1]), { checked = on })
    end
    return items
end

local function favorite_items()
    local path = mp.get_property("path")
    local items = {}
    for i, f in ipairs(state.favorites_of(path)) do
        local label = f.name or t("clip_n", i)
        if f.b then
            label = string.format("%s  (%s ~ %s)", label, util.fmt_time(f.a), util.fmt_time(f.b))
        else
            label = string.format("%s  (%s)", label, util.fmt_time(f.a))
        end
        items[#items + 1] = submenu(label, {
            item(t("menu_clip_goto"), message("favorite-play", i)),
            item(t("menu_clip_loop"), message("favorite-loop", i), { disabled = not f.b }),
            item(t("menu_clip_delete"), message("favorite-remove", i)),
        })
        if i >= 20 then break end
    end
    return items
end

local function chapter_items()
    local items = {}
    local cur = mp.get_property_number("chapter") or -1
    for i, ch in ipairs(mp.get_property_native("chapter-list") or {}) do
        items[#items + 1] = item(ch.title or t("chapter_n", i), "set chapter " .. (i - 1),
            { checked = (i - 1) == cur })
        if i >= 30 then break end
    end
    local path = mp.get_property("path")
    local marks = state.bookmarks_of(path)
    if #marks > 0 then
        items[#items + 1] = SEP
        for i, sec in ipairs(marks) do
            items[#items + 1] = item(t("bookmark_n", i) .. "  (" .. util.fmt_time(sec) .. ")",
                "seek " .. string.format("%.3f", sec) .. " absolute")
            if i >= 20 then break end
        end
    end
    return items
end

local function speed_items()
    local cur = mp.get_property_number("speed") or 1
    local items = {}
    for _, v in ipairs({ 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2 }) do
        items[#items + 1] = item(string.format("%.2fx", v), "set speed " .. v,
            { checked = near(cur, v) })
    end
    items[#items + 1] = SEP
    items[#items + 1] = item(t("menu_slower"), bind("speed-down"), { key = "X" })
    items[#items + 1] = item(t("menu_faster"), bind("speed-up"), { key = "C" })
    items[#items + 1] = item(t("menu_speed_toggle"), bind("speed-toggle"), { key = "Z" })
    return items
end

-- How far the arrow keys seek. Each step is its own submenu of presets, with a
-- prompt at the end for anything else.
local SEEK_PRESETS = { 3, 5, 8, 10, 15, 30, 60, 100, 300, 600 }

local function seek_label(v)
    return v < 60 and t("seek_seconds", v) or util.fmt_time(v)
end

local function seek_items()
    local steps = state.prefs.seek or {}
    local items = {}
    for _, which in ipairs({ "arrow", "ctrl", "shift", "alt" }) do
        local cur = tonumber(steps[which]) or 0
        local choices = {}
        local listed = false
        for _, v in ipairs(SEEK_PRESETS) do
            if v == cur then listed = true end
            choices[#choices + 1] = item(seek_label(v),
                "script-message boda-seek-step " .. which .. " " .. v,
                { checked = v == cur })
        end
        if not listed and cur > 0 then
            choices[#choices + 1] = SEP
            choices[#choices + 1] = item(seek_label(cur), "", { checked = true, disabled = true })
        end
        choices[#choices + 1] = SEP
        choices[#choices + 1] = item(t("menu_seek_custom"),
            "script-message boda-seek-ask " .. which)
        items[#items + 1] = submenu(t("seek_" .. which) .. "   " .. seek_label(cur), choices)
    end
    return items
end

local function vf_on(label)
    return (mp.get_property("vf") or ""):find("@" .. label, 1, true) ~= nil
end

local function af_on(label)
    return (mp.get_property("af") or ""):find("@" .. label, 1, true) ~= nil
end

local function aspect_items()
    local cur = mp.get_property("video-aspect-override") or "-1"
    local defs = { { "-1", t("menu_aspect_default") }, { "16:9", "16:9" }, { "4:3", "4:3" },
        { "2.35:1", "2.35:1" }, { "1.85:1", "1.85:1" } }
    local items = {}
    for _, d in ipairs(defs) do
        items[#items + 1] = item(d[2], "set video-aspect-override " .. d[1],
            { checked = tostring(cur):find(d[1], 1, true) ~= nil })
    end
    return items
end

-- ── sections ──────────────────────────────────────────────────────
local sections = {}

sections.open = function(out)
    out[#out + 1] = submenu(t("menu_open"), {
        item(t("menu_open_file"), bind("open-file"), { key = "F3" }),
        item(t("menu_open_folder"), bind("open-folder"), { key = "F2" }),
        item(t("menu_open_url"), bind("open-url"), { key = "Ctrl+U" }),
        item(t("menu_open_clipboard"), bind("open-clipboard"), { key = "Ctrl+V" }),
        SEP,
        submenu(t("menu_recent_folders"), recent_folders()),
        item(t("menu_reopen"), bind("reopen"), { key = "Ctrl+Y", disabled = not has_file() }),
    })
end

sections.resume = function(out)
    out[#out + 1] = submenu(t("menu_resume"), history_items())
end

sections.playlist = function(out)
    out[#out + 1] = submenu(t("menu_playlist"), {
        submenu(t("menu_items"), playlist_items()),
        submenu(t("menu_sort"), sort_items()),
        SEP,
        item(t("menu_open_panel"), bind("panel-pl"), { key = "F6" }),
        item(t("menu_save_playlist"), bind("save-m3u"), { key = "Ctrl+Shift+M" }),
        item(t("menu_load_playlist"), bind("load-m3u"), { key = "Ctrl+Shift+O" }),
        item(t("menu_remove_item"), bind("playlist-remove"), { key = "Del", disabled = not has_file() }),
    })
end

sections.fav = function(out)
    out[#out + 1] = submenu(t("menu_clips"), {
        item(t("menu_clip_add"), bind("favorite-add"), { key = "+", disabled = not has_file() }),
        item(t("menu_clip_start"), bind("ab-a"), { key = "[", disabled = not has_file() }),
        item(t("menu_clip_end"), bind("ab-b"), { key = "]", disabled = not has_file() }),
        SEP,
        submenu(t("menu_clip_saved"), favorite_items()),
        item(t("menu_clip_clear"), bind("favorite-clear"), { disabled = not has_file() }),
    })
end

sections.chapter = function(out)
    out[#out + 1] = submenu(t("menu_chapters"), {
        submenu(t("menu_goto"), chapter_items()),
        SEP,
        item(t("menu_bookmark_add"), bind("bookmark-add"), { key = "P", disabled = not has_file() }),
        item(t("menu_bookmark_prev"), bind("bookmark-prev"), { key = "Shift+PgUp" }),
        item(t("menu_bookmark_next"), bind("bookmark-next"), { key = "Shift+PgDn" }),
    })
end

sections.speed = function(out)
    out[#out + 1] = submenu(t("menu_speed"), speed_items())
end

sections.seek = function(out)
    out[#out + 1] = submenu(t("menu_seek"), seek_items())
end

sections.loop = function(out)
    local a = mp.get_property("ab-loop-a")
    local b = mp.get_property("ab-loop-b")
    out[#out + 1] = submenu(t("menu_loop"), {
        item(t("menu_loop_a"), bind("ab-a"), { key = "[" }),
        item(t("menu_loop_b"), bind("ab-b"), { key = "]" }),
        item(t("menu_loop_clear"), bind("ab-clear"), { disabled = (a == "no" and b == "no") }),
        SEP,
        item(t("menu_loop_save"), bind("favorite-add"), { key = "+" }),
        item(t("menu_loop_file"), "cycle-values loop-file inf no",
            { checked = tostring(mp.get_property("loop-file")) ~= "no" }),
        item(t("menu_loop_playlist"), "cycle-values loop-playlist inf no",
            { checked = tostring(mp.get_property("loop-playlist")) ~= "no" }),
    })
end

sections.skip = function(out)
    local skip = state.skip_of(mp.get_property("path"))
    out[#out + 1] = submenu(t("menu_skip"), {
        item(t("menu_skip_intro"), bind("mark-intro"), { key = "Ctrl+I" }),
        item(t("menu_skip_outro"), bind("mark-outro"), { key = "Ctrl+O" }),
        item(t("menu_skip_clear"), bind("clear-skip"), { key = "Ctrl+Shift+I", disabled = skip == nil }),
    })
end

sections.video = function(out)
    out[#out + 1] = submenu(t("menu_video"), {
        submenu(t("menu_tracks"), tracks_of("video", "vid")),
        submenu(t("menu_aspect"), aspect_items()),
        SEP,
        item(t("menu_flip_h"), bind("flip-h"), { key = "Ctrl+Z", checked = vf_on("hflip") }),
        item(t("menu_flip_v"), bind("flip-v"), { key = "Ctrl+P", checked = vf_on("vflip") }),
        item(t("menu_rotate"), bind("rotate"), { key = "Alt+K" }),
        SEP,
        submenu(t("menu_quality"), {
            item(t("menu_upscale"), bind("upscale-toggle"),
                { key = "F9", checked = mp.get_property("scale") == "ewa_lanczossharp" }),
            item(t("menu_sharpen"), bind("sharpen"), { key = "Ctrl+R", checked = vf_on("sharp") }),
            item(t("menu_blur"), bind("blur"), { key = "Ctrl+B", checked = vf_on("blur") }),
            item(t("menu_denoise"), bind("denoise"), { key = "Ctrl+N", checked = vf_on("dn") }),
            item(t("menu_deblock"), bind("deblock"), { key = "Ctrl+H", checked = vf_on("deblock") }),
            item(t("menu_deinterlace"), "cycle deinterlace",
                { key = "Ctrl+Shift+D", checked = mp.get_property("deinterlace") == "yes" }),
            SEP,
            item(t("menu_filters_clear"), bind("filters-clear"), { key = "Ctrl+Alt+F" }),
        }),
    }, { disabled = not has_file() })
end

sections.audio = function(out)
    out[#out + 1] = submenu(t("menu_audio"), {
        submenu(t("menu_tracks"), tracks_of("audio", "aid")),
        submenu(t("menu_devices"), audio_devices()),
        SEP,
        item(t("menu_mute"), "cycle mute", { key = "M", checked = mp.get_property_bool("mute") }),
        item(t("menu_norm"), bind("audio-norm"), { key = "N", checked = af_on("norm") }),
        item(t("menu_swap"), bind("stereo-swap"), { key = "T", checked = af_on("swap") }),
        item(t("menu_voice"), bind("voice-remove"),
            { key = "Ctrl+Shift+V", checked = af_on("voice") }),
        SEP,
        item(t("menu_delay_earlier"), "add audio-delay -0.05", { key = "<" }),
        item(t("menu_delay_later"), "add audio-delay 0.05", { key = ">" }),
        item(t("menu_audio_reset"), bind("audio-reset"), { key = "Ctrl+Alt+N" }),
    })
end

sections.sub = function(out)
    out[#out + 1] = submenu(t("menu_sub"), {
        submenu(t("menu_tracks"), tracks_of("sub", "sid")),
        item(t("menu_sub_visible"), "cycle sub-visibility",
            { key = "Alt+H", checked = mp.get_property_bool("sub-visibility") }),
        SEP,
        item(t("menu_sub_open"), bind("open-sub"), { key = "Alt+O" }),
        item(t("menu_sub_reload"), bind("reload-sub"), { key = "Ctrl+Alt+Y" }),
        item(t("menu_sub_dual"), bind("dual-sub"), { key = "F8" }),
        SEP,
        item(t("menu_bigger"), "add sub-font-size 2", { key = "Alt+PgUp" }),
        item(t("menu_smaller"), "add sub-font-size -2", { key = "Alt+PgDn" }),
        item(t("menu_sub_earlier"), "add sub-delay -0.5", { key = "," }),
        item(t("menu_sub_later"), "add sub-delay 0.5", { key = "." }),
        item(t("menu_sub_reset"), "set sub-delay 0", { key = "/" }),
    })
end

sections.color = function(out)
    out[#out + 1] = submenu(t("menu_color"), {
        item(t("menu_color_panel"), bind("panel-color"), { key = "F7" }),
        item(t("menu_auto_color"), bind("auto-color-toggle"),
            { key = "Ctrl+Alt+A", checked = state.prefs.auto_color == true }),
        item(t("menu_color_compare"), bind("eq-toggle"), { key = "Q" }),
        item(t("menu_color_reset"), bind("eq-reset"), { key = "Ctrl+Alt+R" }),
        SEP,
        item(t("menu_brightness_up"), "add brightness 1", { key = "E" }),
        item(t("menu_brightness_down"), "add brightness -1", { key = "W" }),
        item(t("menu_contrast_up"), "add contrast 1", { key = "T" }),
        item(t("menu_contrast_down"), "add contrast -1", { key = "R" }),
        item(t("menu_saturation_up"), "add saturation 1", { key = "U" }),
        item(t("menu_saturation_down"), "add saturation -1", { key = "Y" }),
    })
end

sections.window = function(out)
    out[#out + 1] = submenu(t("menu_window"), {
        item(t("menu_fullscreen"), "cycle fullscreen",
            { key = "Enter", checked = mp.get_property_bool("fullscreen") }),
        item(t("menu_ontop"), "cycle ontop", { key = "Ctrl+T", checked = mp.get_property_bool("ontop") }),
        item(t("menu_pip"), bind("pip"), { key = "F10" }),
        SEP,
        item("0.5x", message("window-scale", 0.5), { key = "Alt+1" }),
        item("1x", message("window-scale", 1), { key = "Alt+2" }),
        item("1.5x", message("window-scale", 1.5), { key = "Alt+3" }),
        item("2x", message("window-scale", 2), { key = "Alt+4" }),
        item(t("menu_maximise"), bind("window-max"), { key = "Alt+5" }),
    })
end

sections.capture = function(out)
    out[#out + 1] = submenu(t("menu_capture"), {
        item(t("menu_shot"), "screenshot", { key = "Ctrl+S" }),
        item(t("menu_shot_video"), "screenshot video", { key = "K" }),
        item(t("menu_shot_window"), "screenshot window", { key = "Alt+N" }),
        item(t("menu_shot_clip"), bind("shot-clipboard"), { key = "Ctrl+C" }),
        SEP,
        item(t("menu_record"), bind("record"), { key = "Ctrl+Shift+R" }),
    }, { disabled = not has_file() })
end

sections.copy = function(out)
    out[#out + 1] = submenu(t("menu_copy"), {
        item(t("menu_copy_path"), "set clipboard/text ${path}"),
        item(t("menu_copy_name"), "set clipboard/text ${filename}"),
        item(t("menu_copy_title"), "set clipboard/text ${media-title}"),
        item(t("menu_copy_time"), "set clipboard/text ${time-pos}"),
        item(t("menu_copy_sub"), "set clipboard/text ${sub-text}"),
    }, { disabled = not has_file() })
end

sections.panel = function(out)
    out[#out + 1] = submenu(t("menu_panel"), {
        item(t("tab_playlist"), bind("panel-pl"), { key = "F6" }),
        item(t("tab_audio"), bind("panel-audio"), { key = "A" }),
        item(t("tab_sub"), bind("panel-sub"), { key = "L" }),
        item(t("tab_video"), bind("panel-video"), { key = "V" }),
        item(t("tab_chapter"), bind("panel-chapter"), { key = "H" }),
        item(t("tab_fav"), bind("panel-fav"), { key = "Ctrl+Insert" }),
        item(t("tab_color"), bind("panel-color"), { key = "F7" }),
    })
end

sections.settings = function(out)
    out[#out + 1] = submenu(t("menu_settings"), {
        item(t("menu_config_folder"), bind("open-config"), { key = "F5" }),
        item(t("menu_stats"), "script-binding stats/display-stats-toggle", { key = "Ctrl+F1" }),
        item(t("menu_console"), "script-binding console/enable", { key = "Ctrl+F12" }),
        SEP,
        item(t("menu_about"), bind("about"), { key = "F1" }),
    })
end

local DEFAULT_ORDER = {
    "open", "resume", "-", "playlist", "fav", "chapter", "-",
    "speed", "seek", "loop", "skip", "-", "video", "audio", "sub", "color", "-",
    "window", "capture", "copy", "-", "panel", "settings",
}

local function wanted_order()
    local conf = tostring(opts.menu_sections or ""):gsub("%s", "")
    if conf == "" then return DEFAULT_ORDER end
    local out = {}
    for name in conf:gmatch("[^,]+") do out[#out + 1] = name end
    return out
end

-- ── menus per context ──────────────────────────────────────────────
local function main_menu()
    local paused = mp.get_property_bool("pause")
    local out = {
        item(paused and t("menu_play") or t("menu_pause"), "cycle pause",
            { key = "Space", disabled = not has_file() }),
        item(t("menu_stop"), "stop", { key = "Ctrl+F4", disabled = not has_file() }),
        item(t("menu_prev_file"), "playlist-prev", { key = "PgUp" }),
        item(t("menu_next_file"), "playlist-next", { key = "PgDn" }),
        SEP,
    }
    for _, name in ipairs(wanted_order()) do
        if name == "-" then
            out[#out + 1] = SEP
        elseif sections[name] then
            sections[name](out)
        end
    end
    out[#out + 1] = SEP
    out[#out + 1] = item(t("menu_quit"), "quit", { key = "Alt+F4" })
    return out
end

-- Pressed over a playlist row: a menu for that row
local function playlist_menu(index)
    local pl = mp.get_property_native("playlist") or {}
    local e = pl[index + 1]
    local name = e and playlist.name(e) or t("menu_items")
    return {
        item(name, "", { disabled = true }),
        SEP,
        item(t("menu_this_item"), "playlist-play-index " .. index),
        item(t("menu_remove"), "playlist-remove " .. index),
        SEP,
        submenu(t("menu_sort"), sort_items()),
        item(t("menu_idle_folder"), bind("open-folder"), { key = "F2" }),
        item(t("menu_save_playlist"), bind("save-m3u")),
        SEP,
        item(t("menu_close_panel"), bind("panel-toggle"), { key = "F6" }),
    }
end

local function idle_menu()
    return {
        item(t("menu_idle_file"), bind("open-file"), { key = "F3" }),
        item(t("menu_idle_folder"), bind("open-folder"), { key = "F2" }),
        item(t("menu_open_url"), bind("open-url"), { key = "Ctrl+U" }),
        item(t("menu_open_clipboard"), bind("open-clipboard"), { key = "Ctrl+V" }),
        SEP,
        submenu(t("menu_resume"), history_items()),
        submenu(t("menu_recent_folders"), recent_folders()),
        SEP,
        item(t("menu_config_folder"), bind("open-config"), { key = "F5" }),
        item(t("menu_quit"), "quit", { key = "Alt+F4" }),
    }
end

-- Choose which menu to show.
-- Only look under the cursor for mouse presses; a key (F4) always gets the main menu.
local function pick_menu(from_mouse)
    if not has_file() then return idle_menu(), "idle" end
    local x, y
    if from_mouse then x, y = ui.mouse_pos() end
    if x and y then
        local r = ui.region_at(x, y)
        local id = r and r.id or ""
        local row = id:match("^panel/row(%d+)$")
        if row then
            local info = mp.get_property_native("user-data/boda/panel") or {}
            if info.tab == "pl" then
                return playlist_menu((info.scroll or 0) + tonumber(row) - 1), "playlist"
            end
        end
    end
    return main_menu(), "main"
end

-- ── fallback when there is no native menu ─────────────────────────
local function show_fallback(items, title)
    if not (has_input and input and input.select) then
        mp.osd_message(t("menu_unavailable"), 2)
        return
    end
    local labels, acts = {}, {}
    for _, it in ipairs(items) do
        if it.type ~= "separator" then
            local disabled = false
            for _, s in ipairs(it.state or {}) do
                if s == "disabled" then disabled = true end
            end
            local mark = ""
            for _, s in ipairs(it.state or {}) do
                if s == "checked" then mark = "● " end
            end
            if not disabled then
                if it.type == "submenu" then
                    labels[#labels + 1] = mark .. it.title .. "  ▸"
                    acts[#acts + 1] = { sub = it.submenu, title = it.title }
                else
                    labels[#labels + 1] = mark .. it.title
                    acts[#acts + 1] = { cmd = it.cmd }
                end
            end
        end
    end
    if #labels == 0 then return end
    input.select({
        prompt = title or t("menu_title"),
        items = labels,
        default_item = 1,
        submit = function(i)
            local a = acts[i]
            if not a then return end
            if a.sub then
                show_fallback(a.sub, a.title)
            elseif a.cmd and a.cmd ~= "" then
                mp.command(a.cmd)
            end
        end,
    })
end

-- ── showing it ─────────────────────────────────────────────────────
local function show(from_mouse)
    local items, kind = pick_menu(from_mouse)
    M.last_kind = kind
    M.last_items = items
    if native_ok ~= false then
        local ok = pcall(mp.set_property_native, "menu-data", items)
        if ok then
            local res = mp.command_native({ "context-menu" })
            if res ~= nil or native_ok == true then
                native_ok = true
                return
            end
            -- if the command fails, fall through to the list below
            native_ok = false
        else
            native_ok = false
        end
    end
    show_fallback(items, t("menu_title"))
end

function M.init()
    -- complex bindings tell us whether a mouse button or a key triggered this
    mp.add_key_binding(nil, "menu", function(e)
        if e and e.event and e.event ~= "down" and e.event ~= "press" then return end
        show(e and e.is_mouse == true)
    end, { complex = true })
    mp.register_script_message("boda-menu", function() show(false) end)

    -- For tests and debugging: build the tree and publish it without showing a menu.
    -- (calling context-menu for real blocks until the user dismisses the menu)
    mp.register_script_message("boda-menu-build", function(which)
        local items, kind
        if which == "idle" then
            items, kind = idle_menu(), "idle"
        elseif which == "playlist" then
            local info = mp.get_property_native("user-data/boda/panel") or {}
            items, kind = playlist_menu(info.scroll or 0), "playlist"
        elseif which == "auto" then
            items, kind = pick_menu(true)
        elseif which == "auto-key" then
            items, kind = pick_menu(false)
        else
            items, kind = main_menu(), "main"
        end
        pcall(mp.set_property_native, "menu-data", items)
        -- mpv's own default menu may overwrite menu-data, so publish our tree separately
        pcall(mp.set_property_native, "user-data/boda/menu",
            { kind = kind, count = #items, tree = items })
    end)

    -- Show just the fallback list, the way a machine without the native menu would
    mp.register_script_message("boda-menu-fallback", function()
        local items = select(1, pick_menu(true))
        show_fallback(items, t("menu_title"))
    end)
end

return M
