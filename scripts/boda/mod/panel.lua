-- Side panel: playlist / tracks / chapters / clips / colour.
-- Text is cut to fit, only the rows that fit are drawn, the rest scrolls.
local mp = require("mp")
local utils = require("mp.utils")
local util = require("lib.util")
local ui = require("lib.ui")
local opts = require("lib.options")
local state = require("lib.state")
local t = require("lib.i18n").t

local M = {}

local layer
local open = false
local tab = "pl"
local scroll = 0
local sorting = false
local meta = {}
local info = {} -- current state, published as user-data/boda/panel for tests
local follow = true -- pull the playing row into view (off once you scroll by hand)
local selected = nil -- last row clicked, zero based
local stats = { sort_ms = 0, move_ms = 0, moves = 0, meta_ms = 0, meta_done = 0 }
local draw -- wrapped with ui.guard below

local function publish()
    pcall(mp.set_property_native, "user-data/boda/panel", info)
end

local TABS = {
    { id = "pl", key = "tab_playlist" },
    { id = "audio", key = "tab_audio" },
    { id = "sub", key = "tab_sub" },
    { id = "video", key = "tab_video" },
    { id = "chapter", key = "tab_chapter" },
    { id = "fav", key = "tab_fav" },
    { id = "color", key = "tab_color" },
}

local SORTS = {
    { id = "none", key = "sort_none" },
    { id = "name", key = "sort_name" },
    { id = "size", key = "sort_size" },
    { id = "quality", key = "sort_quality" },
    { id = "duration", key = "sort_duration" },
    { id = "mtime", key = "sort_mtime" },
}

local COLORS = {
    { id = "brightness", key = "color_brightness", keys = "W / E" },
    { id = "contrast", key = "color_contrast", keys = "R / T" },
    { id = "saturation", key = "color_saturation", keys = "Y / U" },
    { id = "gamma", key = "color_gamma", keys = "Ctrl+Shift+W / E" },
    { id = "hue", key = "color_hue", keys = "I / O" },
}

local FAV_ACTIONS = {
    { key = "fav_act_start", msg = "ab-a" },
    { key = "fav_act_end", msg = "ab-b" },
    { key = "fav_act_add", msg = "favorite-add" },
    { key = "fav_act_clear", msg = "favorite-clear" },
}

local ACTIONS = {
    { key = "act_save", msg = "save-m3u" },
    { key = "act_open", msg = "load-m3u" },
    { key = "act_intro", msg = "mark-intro" },
    { key = "act_outro", msg = "mark-outro" },
    { key = "act_record", msg = "record" },
}

-- ── metadata used for sorting ──────────────────────────────────────
local function quality_guess(path)
    local low = path:lower()
    if low:find("2160", 1, true) or low:find("4k", 1, true) then return 3840 * 2160 end
    if low:find("1440", 1, true) then return 2560 * 1440 end
    if low:find("1080", 1, true) or low:find("fhd", 1, true) then return 1920 * 1080 end
    if low:find("720", 1, true) then return 1280 * 720 end
    if low:find("480", 1, true) then return 640 * 480 end
    return 0
end

local function meta_of(path)
    if not path then return { size = 0, mtime = 0, duration = 0, pixels = 0 } end
    local m = meta[path]
    if m then return m end
    m = { size = 0, mtime = 0, duration = 0, pixels = quality_guess(path) }
    local fi = (not util.is_url(path)) and utils.file_info(path) or nil
    if fi then
        m.size = fi.size or 0
        m.mtime = fi.mtime or 0
    end
    for _, h in ipairs(state.history) do -- a file watched before has a known length
        if h.path == path then
            m.duration = h.dur or 0
            break
        end
    end
    meta[path] = m
    return m
end

local function remember_current()
    local path = mp.get_property("path")
    if not path then return end
    local m = meta_of(path)
    m.duration = mp.get_property_number("duration") or m.duration
    local w = mp.get_property_number("video-params/w") or 0
    local h = mp.get_property_number("video-params/h") or 0
    if w > 0 and h > 0 then m.pixels = w * h end
end

local last_sort_at = 0

local function apply_sort()
    local key = state.prefs.sort
    if key == "none" or sorting then return end
    local t0 = mp.get_time()
    local pl = mp.get_property_native("playlist") or {}
    local n = #pl
    if n < 2 then return end

    local rows = {}
    for i, e in ipairs(pl) do
        local path = e.filename or ""
        local name = (e.title or util.basename(path))
        local m = meta_of(path)
        local value
        if key == "size" then value = m.size
        elseif key == "quality" then value = m.pixels
        elseif key == "duration" then value = m.duration
        elseif key == "mtime" then value = m.mtime end
        rows[i] = { orig = i - 1, name = name, value = value }
    end

    local desc = state.prefs.sort_desc
    table.sort(rows, function(a, b)
        if a.value and b.value and a.value ~= b.value then
            if desc then return a.value > b.value end
            return a.value < b.value
        end
        if desc then return util.natural_less(b.name, a.name) end
        return util.natural_less(a.name, b.name)
    end)

    local sorted_ms = (mp.get_time() - t0) * 1000

    local same = true
    for i = 1, n do
        if rows[i].orig ~= i - 1 then
            same = false
            break
        end
    end
    if same then return end

    -- Work out every move first, then send them all asynchronously.
    -- Sending them one at a time meant a round trip per command: over 6 s for 500 rows.
    local t1 = mp.get_time()
    local plan = {}
    local pos, at = {}, {}
    for i = 0, n - 1 do
        pos[i] = i
        at[i] = i
    end
    for dest = 0, n - 1 do
        local orig = rows[dest + 1].orig
        local src = pos[orig]
        if src ~= dest then
            plan[#plan + 1] = { src, dest }
            -- moving src to dest shifts everything in between by one
            if src > dest then
                for k = src, dest + 1, -1 do
                    local moved = at[k - 1]
                    at[k] = moved
                    pos[moved] = k
                end
            else
                for k = src, dest - 1 do
                    local moved = at[k + 1]
                    at[k] = moved
                    pos[moved] = k
                end
            end
            at[dest] = orig
            pos[orig] = dest
        end
    end

    if #plan == 0 then return end

    sorting = true
    local left = #plan
    -- release the lock even if the playlist changes and some callbacks never arrive
    mp.add_timeout(5, function()
        if sorting then
            sorting = false
            if open then draw() end
        end
    end)
    for _, mv in ipairs(plan) do
        mp.command_native_async({ "playlist-move", mv[1], mv[2] }, function()
            left = left - 1
            if left > 0 then return end
            sorting = false
            last_sort_at = mp.get_time()
            stats.move_ms = (mp.get_time() - t1) * 1000
            if open then draw() end
        end)
    end
    stats.sort_ms = sorted_ms
    stats.moves = #plan
end

-- ── margins that push the video aside ──────────────────────────────
local MIN_W, KEEP_VIDEO = 200, 160 -- smallest panel / smallest slice left for video

local function panel_width()
    local ow = select(1, ui.osd_size())
    local w = tonumber(state.prefs.panel_w) or opts.panel_width
    if ow > 0 then
        w = math.min(w, math.max(MIN_W, ow - KEEP_VIDEO))
    end
    return math.max(MIN_W, math.floor(w))
end

local function apply_margin()
    local ow = select(1, ui.osd_size())
    local ratio = 0
    if open and ow > 0 and mp.get_property("path") then
        ratio = panel_width() / ow
    end
    ui.reserved_right = ratio * ow
    mp.set_property_number("video-margin-ratio-right", ratio)
end

-- ── building rows ─────────────────────────────────────────────────
-- The note on the right. Reading file info for a long list is slow on its own,
-- so only work it out for rows that are actually drawn.
local function row_hint(path)
    if not path or path == "" then return "" end
    local sort = state.prefs.sort
    if sort == "size" then
        return util.fmt_size(meta_of(path).size)
    elseif sort == "duration" then
        local d = meta_of(path).duration
        return d > 0 and util.fmt_time(d) or ""
    elseif sort == "quality" then
        local px = meta_of(path).pixels
        return px > 0 and string.format("%.1fMP", px / 1000000) or ""
    end
    return ""
end

local function playlist_rows()
    local rows = {}
    for i, e in ipairs(mp.get_property_native("playlist") or {}) do
        local idx = i - 1
        local path = e.filename or ""
        -- One click plays the row.
        -- Clicking the row that is already playing does not restart it, so a habitual
        rows[#rows + 1] = {
            text = e.title or util.basename(path),
            path = path,
            current = e.current,
            selected = (selected == idx),
            click = function()
                selected = idx
                if mp.get_property_number("playlist-pos") ~= idx then
                    mp.commandv("playlist-play-index", idx)
                end
                mp.set_property_bool("pause", false)
                draw()
            end,
        }
    end
    return rows
end

local function track_rows(kind)
    local rows = {}
    local prop = ({ audio = "aid", sub = "sid", video = "vid" })[kind]
    if kind == "sub" then
        rows[#rows + 1] = {
            text = t("sub_off"),
            current = mp.get_property("sid") == "no",
            click = function() mp.set_property("sid", "no") end,
        }
    end
    for _, tr in ipairs(mp.get_property_native("track-list") or {}) do
        if tr.type == kind then
            local id = tr.id
            local label = tr.title or tr.codec or ""
            if tr.lang then label = "[" .. tr.lang .. "] " .. label end
            rows[#rows + 1] = {
                text = string.format("%s  %s", tostring(id), label),
                hint = tr.external and t("track_external") or nil,
                current = tr.selected,
                click = function() mp.set_property(prop, id) end,
            }
        end
    end
    return rows
end

local function fav_rows()
    local path = mp.get_property("path")
    local saved = state.favorites_of(path)
    local rows = {}
    for i, f in ipairs(saved) do
        local idx, a, b = i, f.a or 0, f.b
        local range = b and (util.fmt_time(a) .. " ~ " .. util.fmt_time(b)) or util.fmt_time(a)
        rows[#rows + 1] = {
            text = f.name or t("clip_n", i),
            hint = range,
            click = function()
                mp.commandv("seek", a, "absolute")
                mp.set_property_bool("pause", false)
            end,
            loop = b and function()
                mp.set_property_number("ab-loop-a", a)
                mp.set_property_number("ab-loop-b", b)
                mp.commandv("seek", a, "absolute")
                mp.set_property_bool("pause", false)
                mp.osd_message(t("fav_loop", range))
            end or nil,
            remove = function()
                local list = {}
                for j, v in ipairs(state.favorites_of(path)) do
                    if j ~= idx then list[#list + 1] = v end
                end
                state.set_favorites(path, list)
                draw()
            end,
        }
    end
    return rows
end

local function chapter_rows()
    local rows = {}
    local cur = mp.get_property_number("chapter") or -1
    for i, ch in ipairs(mp.get_property_native("chapter-list") or {}) do
        local ci = i - 1
        rows[#rows + 1] = {
            text = ch.title or t("chapter_n", i),
            hint = util.fmt_time(ch.time or 0),
            current = ci == cur,
            click = function() mp.set_property_number("chapter", ci) end,
        }
    end
    local path = mp.get_property("path")
    for i, sec in ipairs(state.bookmarks_of(path)) do
        rows[#rows + 1] = {
            text = t("bookmark_n", i),
            hint = util.fmt_time(sec),
            click = function() mp.commandv("seek", sec, "absolute") end,
        }
    end
    local skip = state.skip_of(path)
    if skip then
        if (skip.intro or 0) > 0 then
            rows[#rows + 1] = {
                text = t("intro_end"),
                hint = util.fmt_time(skip.intro),
                click = function() mp.commandv("seek", skip.intro, "absolute") end,
            }
        end
        if (skip.outro or 0) > 0 then
            rows[#rows + 1] = {
                text = t("outro_start"),
                hint = util.fmt_time(skip.outro),
                click = function() mp.commandv("seek", skip.outro, "absolute") end,
            }
        end
    end
    return rows
end

-- ── drawing ───────────────────────────────────────────────────────
local function draw_impl()
    local t_draw = mp.get_time()
    -- With no file loaded, leave the screen to the idle view.
    if not open or not ui.ready() or not mp.get_property("path") then
        layer:hide()
        info = { open = false }
        publish()
        return
    end
    local ow, oh, s = layer:start()
    local th = ui.theme
    local w = panel_width()
    local x0 = ow - w
    info = { open = true, tab = tab, x0 = x0, width = w, oh = oh, ow = ow, scale = s,
        sort = state.prefs.sort, sort_desc = state.prefs.sort_desc, tabs = #TABS }

    layer:rect(x0, 0, w, oh, th.bg, 246)
    layer:rect(x0, 0, 1, oh, th.line, 255)

    -- Registered first so it sits at the bottom: takes the wheel, blocks stray clicks.
    layer:hit(x0, 0, w, oh, {
        id = "surface",
        scroll = function(dir)
            scroll = scroll - dir
            follow = false -- once you scroll by hand, stop chasing the playing row
            draw()
        end,
    })

    -- tabs
    local tab_h = 38 * s
    local tw = (w - 12 * s) / #TABS
    local tab_fs = 13.5 * s
    local longest = 0
    for _, def in ipairs(TABS) do
        longest = math.max(longest, util.text_width(t(def.key), tab_fs))
    end
    if longest > tw - 4 * s then
        tab_fs = math.max(11 * s, tab_fs * (tw - 4 * s) / longest)
    end
    for i, def in ipairs(TABS) do
        local id = def.id
        local x = x0 + 6 * s + (i - 1) * tw
        local on = tab == id
        layer:text_fit(x + tw / 2, 12 * s, tab_fs, on and th.text or th.mute, 8, t(def.key), tw - 2 * s)
        if on then
            layer:rect(x + 4 * s, 0, tw - 8 * s, tab_h - 4 * s, th.bg2, 200)
            layer:rect(x + 4 * s, tab_h - 5 * s, tw - 8 * s, 3 * s, th.accent, 255)
        end
        layer:hit(x, 0, tw, tab_h, {
            id = "tab" .. id,
            click = function()
                tab = id
                scroll = 0
                draw()
            end,
        })
    end

    local acts = (tab == "pl" and ACTIONS) or (tab == "fav" and FAV_ACTIONS) or nil
    local top = tab_h + 6 * s
    local bottom = oh - (acts and 52 * s or 26 * s)

    if tab == "color" then
        -- colour tab
        local y = top + 6 * s
        local auto = state.prefs.auto_color
        layer:rect(x0 + 16 * s, y, w - 32 * s, 26 * s, auto and th.accent or th.bg2, 255)
        layer:text(x0 + w / 2, y + 5 * s, 13.5 * s, th.text, 8,
            auto and t("auto_color_on") or t("auto_color_off"))
        layer:hit(x0 + 16 * s, y, w - 32 * s, 26 * s, {
            id = "auto",
            click = function()
                state.prefs.auto_color = not state.prefs.auto_color
                state.mark("prefs")
                mp.commandv("script-message", "boda-auto-color", state.prefs.auto_color and "on" or "off")
                draw()
            end,
        })
        y = y + 40 * s
        for _, c in ipairs(COLORS) do
            local val = mp.get_property_number(c.id) or 0
            layer:text(x0 + 16 * s, y, 13.5 * s, th.text, 7, t(c.key))
            layer:text(x0 + w - 16 * s, y, 12 * s, th.mute, 9, string.format("%d", val))
            layer:text_fit(x0 + 16 * s + util.text_width(t(c.key), 13.5 * s) + 8 * s, y + 1.5 * s,
                10.5 * s, th.mute, 7, c.keys, w - 90 * s)
            local bx, by, bw2 = x0 + 16 * s, y + 22 * s, w - 32 * s
            layer:rect(bx, by, bw2, 4 * s, th.track, 200)
            -- zero sits in the middle, so fill outwards from the centre
            local mid = bx + bw2 / 2
            local fw = bw2 / 2 * (val / 100)
            if val >= 0 then
                layer:rect(mid, by, math.max(1, fw), 4 * s, th.accent, 255)
            else
                layer:rect(mid + fw, by, math.max(1, -fw), 4 * s, th.accent, 255)
            end
            layer:rect(mid + fw - 5 * s, by - 5 * s, 10 * s, 14 * s, th.text, 255)
            local function set_from(mx)
                state.prefs.auto_color = false
                state.mark("prefs")
                mp.set_property_number(c.id, util.round(util.clamp((mx - bx) / bw2, 0, 1) * 200 - 100))
                draw()
            end
            layer:hit(bx - 6 * s, by - 14 * s, bw2 + 12 * s, 30 * s,
                { id = "c" .. c.id, press = set_from, drag = set_from })
            y = y + 52 * s
        end
        layer:text(x0 + w / 2, y + 4 * s, 12 * s,
            layer:hovered("reset") and th.text or th.mute, 8, t("color_reset_btn"))
        layer:hit(x0 + 16 * s, y, w - 32 * s, 26 * s, {
            id = "reset",
            click = function()
                for _, c in ipairs(COLORS) do mp.set_property_number(c.id, 0) end
                state.prefs.auto_color = false
                state.mark("prefs")
                draw()
            end,
        })
    else
        -- playlist / track / chapter tabs
        local rows
        if tab == "pl" then
            rows = playlist_rows()
            info.sort_top = top
            local bw2 = (w - 20 * s) / #SORTS
            for i, def in ipairs(SORTS) do
                local id = def.id
                local x = x0 + 10 * s + (i - 1) * bw2
                local on = state.prefs.sort == id
                local arrow = (on and id ~= "none") and (state.prefs.sort_desc and " ↓" or " ↑") or ""
                if on then layer:rect(x + 2 * s, top, bw2 - 4 * s, 24 * s, th.bg2, 220) end
                layer:text_fit(x + bw2 / 2, top + 4 * s, 12 * s, on and th.accent or th.mute, 8,
                    t(def.key) .. arrow, bw2 - 6 * s)
                layer:hit(x, top, bw2, 24 * s, {
                    id = "sort" .. id,
                    click = function()
                        if state.prefs.sort == id then
                            state.prefs.sort_desc = not state.prefs.sort_desc
                        else
                            state.prefs.sort = id
                            state.prefs.sort_desc = false
                        end
                        state.mark("prefs")
                        apply_sort()
                        scroll = 0
                        draw()
                    end,
                })
            end
            -- gap between the sort row and the list, so a near miss does not play something
            top = top + 32 * s
        elseif tab == "chapter" then
            rows = chapter_rows()
        elseif tab == "fav" then
            rows = fav_rows()
        else
            rows = track_rows(tab)
        end

        local row_h = 34 * s
        local vis = math.max(1, math.floor((bottom - top) / row_h))
        local max_scroll = math.max(0, #rows - vis)
        scroll = util.clamp(scroll, 0, max_scroll)

        -- Chase the playing row only when the file changes or the panel opens.
        -- Doing it on every draw yanked the list back and looked like scrolling was broken.
        if follow then
            for i, r in ipairs(rows) do
                if r.current then
                    if i <= scroll or i > scroll + vis then
                        scroll = util.clamp(i - math.ceil(vis / 2), 0, max_scroll)
                    end
                    break
                end
            end
            follow = false
        end

        info.scroll, info.rows, info.vis = scroll, #rows, vis
        info.max_scroll, info.top, info.row_h = max_scroll, top, row_h

        for i = 1, vis do
            local row = rows[scroll + i]
            if not row then break end
            local y = top + (i - 1) * row_h
            local id = "row" .. (scroll + i)
            local hot = layer:hovered(id)
            if row.selected then
                layer:rect(x0 + 6 * s, y, w - 12 * s, row_h - 2 * s, th.hover, hot and 210 or 170)
            elseif hot then
                layer:rect(x0 + 6 * s, y, w - 12 * s, row_h - 2 * s, th.hover, 110)
            end
            if row.current then
                layer:rect(x0 + 6 * s, y, w - 12 * s, row_h - 2 * s, th.accent, 40)
                layer:rect(x0 + 6 * s, y + 3 * s, 4 * s, row_h - 8 * s, th.accent, 255)
            elseif row.selected then
                layer:rect(x0 + 6 * s, y + 3 * s, 4 * s, row_h - 8 * s, th.mute, 220)
            end
            local hint = row.hint or row_hint(row.path)
            local right = x0 + w - 14 * s
            local btn_w = 0
            local btns = {} -- registered after the row so they sit on top of it
            if row.remove then
                local rid = id .. "x"
                layer:text(right, y + 7 * s, 15 * s, layer:hovered(rid) and th.text or th.mute, 9, "×")
                btns[#btns + 1] = { right - 16 * s, 24 * s, rid, row.remove }
                right = right - 22 * s
                btn_w = btn_w + 22 * s
            end
            if row.loop then
                local lid = id .. "r"
                layer:text(right, y + 9 * s, 12 * s,
                    layer:hovered(lid) and th.text or th.mute, 9, t("btn_loop"))
                btns[#btns + 1] = { right - 34 * s, 40 * s, lid, row.loop }
                right = right - 40 * s
                btn_w = btn_w + 40 * s
            end
            local hint_w = (hint ~= "") and (util.text_width(hint, 12 * s) + 12 * s) or 0
            layer:text_fit(x0 + 18 * s, y + 8 * s, 14.5 * s,
                (row.current or hot or row.selected) and th.text or th.text2, 7, row.text,
                w - 34 * s - hint_w - btn_w)
            if hint ~= "" then
                layer:text(right, y + 11 * s, 12 * s, th.mute, 9, hint)
            end
            layer:hit(x0 + 6 * s, y, w - 12 * s, row_h - 2 * s,
                { id = id, click = row.click, dbl = row.dbl })
            for _, b in ipairs(btns) do
                layer:hit(b[1], y, b[2], row_h - 2 * s, { id = b[3], click = b[4] })
            end
        end

        if #rows == 0 then
            local empty = (tab == "fav") and t("row_empty_fav") or t("row_empty")
            layer:text_fit(x0 + 18 * s, top + 8 * s, 13.5 * s, th.mute, 7, empty, w - 36 * s)
        end

        -- scrollbar, draggable
        if max_scroll > 0 then
            local track_h = bottom - top
            local kh = math.max(24 * s, track_h * vis / #rows)
            local ky = top + (track_h - kh) * (scroll / max_scroll)
            local hot = layer:hovered("scrollbar")
            layer:rect(ow - 6 * s, top, 3 * s, track_h, th.line, 140)
            layer:rect(ow - 6 * s, ky, 3 * s, kh, hot and th.text or th.mute, hot and 230 or 150)
            local function to_scroll(_, my)
                local pos = util.clamp((my - top - kh / 2) / math.max(1, track_h - kh), 0, 1)
                scroll = util.round(pos * max_scroll)
                follow = false
                draw()
            end
            layer:hit(ow - 14 * s, top, 14 * s, track_h,
                { id = "scrollbar", press = to_scroll, drag = to_scroll })
        end
        layer:text(x0 + 14 * s, oh - 21 * s, 12 * s, th.mute, 7, t("row_count", #rows))
    end

    -- action row at the bottom
    if acts then
        local aw = (w - 16 * s) / #acts
        for i, a in ipairs(acts) do
            local x = x0 + 8 * s + (i - 1) * aw
            local id = "act" .. i
            layer:text_fit(x + aw / 2, oh - 45 * s, 12.5 * s,
                layer:hovered(id) and th.text or th.text2, 8, t(a.key), aw - 4 * s)
            layer:hit(x, oh - 50 * s, aw, 22 * s, {
                id = id,
                click = function() mp.commandv("script-message", "boda-" .. a.msg) end,
            })
        end
    end

    -- Left edge: drag to resize freely, click to cycle through preset widths.
    local grip = layer:hovered("grip")
    layer:rect(x0, 0, grip and 3 * s or 1, oh, grip and th.accent or th.line, 255)
    local max_w = math.max(MIN_W, ow - KEEP_VIDEO)
    layer:hit(x0 - 7 * s, 0, 16 * s, oh, {
        id = "grip",
        drag = function(mx)
            local want = util.round(util.clamp(ow - mx, MIN_W, max_w))
            if want == state.prefs.panel_w then return end
            state.prefs.panel_w = want
            state.mark("prefs")
            apply_margin()
            draw()
        end,
        drag_end = function(moved)
            if moved then return end
            local presets = { 260, 320, 420, 540 }
            local cur, nxt = state.prefs.panel_w, presets[1]
            for i, p in ipairs(presets) do
                if cur < p - 10 then
                    nxt = p
                    break
                end
                nxt = presets[(i % #presets) + 1]
            end
            state.prefs.panel_w = util.clamp(nxt, MIN_W, max_w)
            state.mark("prefs")
            apply_margin()
            draw()
        end,
    })

    info.hover = ui.hovered_id()
    stats.draw_ms = (mp.get_time() - t_draw) * 1000
    info.draw_ms = stats.draw_ms
    info.sort_ms, info.move_ms, info.moves = stats.sort_ms, stats.move_ms, stats.moves
    info.meta_ms, info.meta_done = stats.meta_ms, stats.meta_done
    publish()
    layer:flush()
end

draw = ui.guard("panel", draw_impl)
M.draw = draw

function M.set(target)
    if target == "toggle" then
        open = not open
    elseif target == "close" then
        open = false
    else
        -- look it up in TABS so adding a tab needs no change here
        local id = (target == "playlist") and "pl" or nil
        for _, def in ipairs(TABS) do
            if def.id == target then id = def.id end
        end
        if id then
            if open and tab == id then
                open = false
            else
                open, tab, scroll = true, id, 0
            end
        else
            open = not open
        end
    end
    if open then follow = true end
    ui.hold_cursor(open)
    apply_margin()
    draw()
    ui.update_dragging()
end

function M.is_open()
    return open
end

function M.init()
    layer = ui.layer("panel", 80)
    layer.redraw = draw

    mp.register_script_message("boda-panel", function(target) M.set(target or "toggle") end)
    mp.register_script_message("boda-refresh", function()
        if open then draw() end
    end)

    -- Let a key or another script trigger sorting.
    --   script-message boda-sort size desc
    mp.register_script_message("boda-sort", function(key, dir)
        local ok = false
        for _, def in ipairs(SORTS) do
            if def.id == key then ok = true end
        end
        if not ok then return end
        if state.prefs.sort == key and dir == nil then
            state.prefs.sort_desc = not state.prefs.sort_desc
        else
            state.prefs.sort = key
            state.prefs.sort_desc = (dir == "desc")
        end
        state.mark("prefs")
        apply_sort()
        scroll = 0
        if open then draw() end
    end)

    mp.add_key_binding(nil, "panel-toggle", function() M.set("toggle") end)

    -- Remove the row you last clicked, or the playing one if you clicked nothing.
    mp.add_key_binding(nil, "playlist-remove", function()
        local idx = selected or mp.get_property_number("playlist-pos")
        if not idx then return end
        mp.commandv("playlist-remove", idx)
        selected = nil
        if open then draw() end
    end)
    for _, def in ipairs(TABS) do
        local id = def.id
        mp.add_key_binding(nil, "panel-" .. id, function() M.set(id) end)
    end

    mp.observe_property("playlist", "native", function()
        if sorting then return end
        -- ignore the notification caused by our own moves
        if mp.get_time() - last_sort_at > 0.3 then apply_sort() end
        if open then draw() end
    end)
    -- Follow the list to the playing row only when the file itself changes.
    mp.observe_property("playlist-pos", "number", function()
        follow = true
        if open then draw() end
    end)
    for _, prop in ipairs({ "track-list", "chapter", "sid", "aid", "vid" }) do
        mp.observe_property(prop, "native", function()
            if open then draw() end
        end)
    end

    mp.register_event("file-loaded", function()
        remember_current()
        follow = true
        apply_margin()
        if open then draw() end
        ui.update_dragging()
    end)
    mp.register_event("end-file", function()
        apply_margin()
        draw()
    end)
end

return M
