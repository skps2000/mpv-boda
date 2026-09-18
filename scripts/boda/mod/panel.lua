-- 오른쪽 사이드 패널: 재생목록 / 트랙 / 챕터 / 색감.
-- 창이 좁아지면 글자를 자르고, 들어가는 줄 수만 그린 뒤 나머지는 스크롤한다.
local mp = require("mp")
local utils = require("mp.utils")
local util = require("lib.util")
local ui = require("lib.ui")
local opts = require("lib.options")
local state = require("lib.state")

local M = {}

local layer
local open = false
local tab = "pl"
local scroll = 0
local sorting = false
local meta = {}
local info = {} -- 지금 화면 상태. user-data/boda/panel 로 공개해 디버깅·테스트에 쓴다.
local follow = true -- 재생 중인 항목을 화면 안으로 끌어올지 (사용자가 스크롤하면 끈다)
local selected = nil -- 클릭으로 골라둔 재생목록 항목 (0부터). 재생은 더블클릭.
local draw -- 아래에서 ui.guard 로 감싼다

local function publish()
    pcall(mp.set_property_native, "user-data/boda/panel", info)
end

local TABS = {
    { id = "pl", t = "목록" },
    { id = "audio", t = "오디오" },
    { id = "sub", t = "자막" },
    { id = "video", t = "비디오" },
    { id = "chapter", t = "챕터" },
    { id = "color", t = "색감" },
}

local SORTS = {
    { id = "none", t = "기본" },
    { id = "name", t = "이름" },
    { id = "size", t = "크기" },
    { id = "quality", t = "화질" },
    { id = "duration", t = "길이" },
    { id = "mtime", t = "날짜" },
}

local COLORS = {
    { id = "brightness", name = "밝기", keys = "W / E" },
    { id = "contrast", name = "대비", keys = "R / T" },
    { id = "saturation", name = "채도", keys = "Y / U" },
    { id = "gamma", name = "감마", keys = "Ctrl+Shift+W / E" },
    { id = "hue", name = "색상", keys = "I / O" },
}

local ACTIONS = {
    { t = "저장", msg = "save-m3u" },
    { t = "열기", msg = "load-m3u" },
    { t = "인트로", msg = "mark-intro" },
    { t = "엔딩", msg = "mark-outro" },
    { t = "녹화", msg = "record" },
}

-- ── 목록 정렬용 메타데이터 ──────────────────────────────────────────
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
    for _, h in ipairs(state.history) do -- 전에 본 파일이면 길이를 알고 있다
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

local function apply_sort()
    local key = state.prefs.sort
    if key == "none" or sorting then return end
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

    local same = true
    for i = 1, n do
        if rows[i].orig ~= i - 1 then
            same = false
            break
        end
    end
    if same then return end

    sorting = true
    local pos = {}
    for i = 0, n - 1 do pos[i] = i end
    for dest = 0, n - 1 do
        local src = pos[rows[dest + 1].orig]
        if src ~= dest then
            mp.commandv("playlist-move", src, dest)
            for k = 0, n - 1 do
                local p = pos[k]
                if p == src then
                    pos[k] = dest
                elseif src > dest and p >= dest and p < src then
                    pos[k] = p + 1
                elseif src < dest and p > src and p <= dest then
                    pos[k] = p - 1
                end
            end
        end
    end
    sorting = false
end

-- ── 여백(영상 밀어내기) ─────────────────────────────────────────────
local MIN_W, KEEP_VIDEO = 200, 160 -- 패널 최소 너비 / 영상에 남겨둘 최소 너비

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

-- ── 행 만들기 ───────────────────────────────────────────────────────
local function playlist_rows()
    local rows = {}
    for i, e in ipairs(mp.get_property_native("playlist") or {}) do
        local idx = i - 1
        local path = e.filename or ""
        local m = meta_of(path)
        local hint = ""
        local sort = state.prefs.sort
        if sort == "size" then
            hint = util.fmt_size(m.size)
        elseif sort == "duration" and m.duration > 0 then
            hint = util.fmt_time(m.duration)
        elseif sort == "quality" and m.pixels > 0 then
            hint = string.format("%.1fMP", m.pixels / 1000000)
        end
        -- 팟플레이어와 같게: 한 번 클릭은 고르기, 두 번 클릭이 재생.
        -- (한 번 클릭으로 바로 재생하면 스크롤하다 잘못 눌러 보던 걸 놓친다)
        rows[#rows + 1] = {
            text = e.title or util.basename(path),
            hint = hint,
            current = e.current,
            selected = (selected == idx),
            click = function()
                selected = idx
                draw()
            end,
            dbl = function()
                selected = idx
                mp.commandv("playlist-play-index", idx)
                mp.set_property_bool("pause", false)
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
            text = "(자막 끄기)",
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
                hint = tr.external and "외부" or nil,
                current = tr.selected,
                click = function() mp.set_property(prop, id) end,
            }
        end
    end
    return rows
end

local function chapter_rows()
    local rows = {}
    local cur = mp.get_property_number("chapter") or -1
    for i, ch in ipairs(mp.get_property_native("chapter-list") or {}) do
        local ci = i - 1
        rows[#rows + 1] = {
            text = ch.title or ("챕터 " .. i),
            hint = util.fmt_time(ch.time or 0),
            current = ci == cur,
            click = function() mp.set_property_number("chapter", ci) end,
        }
    end
    local path = mp.get_property("path")
    for i, sec in ipairs(state.bookmarks_of(path)) do
        rows[#rows + 1] = {
            text = "북마크 " .. i,
            hint = util.fmt_time(sec),
            click = function() mp.commandv("seek", sec, "absolute") end,
        }
    end
    local skip = state.skip_of(path)
    if skip then
        if (skip.intro or 0) > 0 then
            rows[#rows + 1] = {
                text = "오프닝 끝",
                hint = util.fmt_time(skip.intro),
                click = function() mp.commandv("seek", skip.intro, "absolute") end,
            }
        end
        if (skip.outro or 0) > 0 then
            rows[#rows + 1] = {
                text = "엔딩 시작",
                hint = util.fmt_time(skip.outro),
                click = function() mp.commandv("seek", skip.outro, "absolute") end,
            }
        end
    end
    return rows
end

-- ── 그리기 ──────────────────────────────────────────────────────────
local function draw_impl()
    -- 파일이 없을 때는 대기 화면에 자리를 내준다.
    if not open or not ui.ready() or not mp.get_property("path") then
        layer:hide()
        info = { open = false }
        publish()
        return
    end
    local ow, oh, s = layer:start()
    local t = ui.theme
    local w = panel_width()
    local x0 = ow - w
    info = { open = true, tab = tab, x0 = x0, width = w, oh = oh, ow = ow, scale = s }

    layer:rect(x0, 0, w, oh, t.bg, 236)
    layer:rect(x0, 0, 1, oh, t.line, 255)

    -- 가장 먼저 등록해서 제일 아래에 깔리는 영역: 휠 스크롤과 빈 곳 클릭 차단용.
    layer:hit(x0, 0, w, oh, {
        id = "surface",
        scroll = function(dir)
            scroll = scroll - dir
            follow = false -- 손으로 움직였으면 재생 중인 항목을 억지로 따라가지 않는다
            draw()
        end,
    })

    -- 탭
    local tab_h = 34 * s
    local tw = (w - 12 * s) / #TABS
    for i, def in ipairs(TABS) do
        local id = def.id
        local x = x0 + 6 * s + (i - 1) * tw
        local on = tab == id
        layer:text_fit(x + tw / 2, 10 * s, 12.5 * s, on and t.text or t.mute, 8, def.t, tw - 4 * s)
        if on then layer:rect(x + 6 * s, tab_h - 4 * s, tw - 12 * s, 2 * s, t.accent, 255) end
        layer:hit(x, 0, tw, tab_h, {
            id = "tab" .. id,
            click = function()
                tab = id
                scroll = 0
                draw()
            end,
        })
    end

    local top = tab_h + 6 * s
    local bottom = oh - (tab == "pl" and 52 * s or 26 * s)

    if tab == "color" then
        -- 색감 탭
        local y = top + 6 * s
        local auto = state.prefs.auto_color
        layer:rect(x0 + 16 * s, y, w - 32 * s, 26 * s, auto and t.accent or t.bg2, 255)
        layer:text(x0 + w / 2, y + 5 * s, 12.5 * s, t.text, 8, auto and "자동 보정 켜짐" or "자동 보정 꺼짐")
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
            layer:text(x0 + 16 * s, y, 12.5 * s, t.text, 7, c.name)
            layer:text(x0 + w - 16 * s, y, 12 * s, t.mute, 9, string.format("%d", val))
            layer:text_fit(x0 + 16 * s + util.text_width(c.name, 12.5 * s) + 8 * s, y + 1.5 * s,
                10.5 * s, t.mute, 7, c.keys, w - 90 * s)
            local bx, by, bw2 = x0 + 16 * s, y + 22 * s, w - 32 * s
            layer:rect(bx, by, bw2, 4 * s, t.track, 200)
            -- 0 이 가운데인 값이므로 가운데에서부터 칠한다.
            local mid = bx + bw2 / 2
            local fw = bw2 / 2 * (val / 100)
            if val >= 0 then
                layer:rect(mid, by, math.max(1, fw), 4 * s, t.accent, 255)
            else
                layer:rect(mid + fw, by, math.max(1, -fw), 4 * s, t.accent, 255)
            end
            layer:rect(mid + fw - 5 * s, by - 5 * s, 10 * s, 14 * s, t.text, 255)
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
        layer:text(x0 + w / 2, y + 4 * s, 12 * s, layer:hovered("reset") and t.text or t.mute, 8, "원본으로 (Q)")
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
        -- 목록/트랙/챕터 탭
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
                if on then layer:rect(x + 2 * s, top, bw2 - 4 * s, 22 * s, t.bg2, 200) end
                layer:text_fit(x + bw2 / 2, top + 3 * s, 11 * s, on and t.accent or t.mute, 8,
                    def.t .. arrow, bw2 - 6 * s)
                layer:hit(x, top, bw2, 22 * s, {
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
            -- 정렬 줄과 목록 사이에 여백을 둔다 (잘못 눌러 엉뚱한 화가 재생되지 않도록)
            top = top + 30 * s
        elseif tab == "chapter" then
            rows = chapter_rows()
        else
            rows = track_rows(tab)
        end

        local row_h = 30 * s
        local vis = math.max(1, math.floor((bottom - top) / row_h))
        local max_scroll = math.max(0, #rows - vis)
        scroll = util.clamp(scroll, 0, max_scroll)

        -- 재생 중인 항목 따라가기는 파일이 바뀌거나 패널을 열 때 한 번만 한다.
        -- 매번 하면 휠을 굴려도 곧바로 제자리로 끌려와서 스크롤이 안 되는 것처럼 보인다.
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
                layer:rect(x0 + 6 * s, y, w - 12 * s, row_h - 2 * s, t.hover, hot and 210 or 170)
            elseif hot then
                layer:rect(x0 + 6 * s, y, w - 12 * s, row_h - 2 * s, t.hover, 110)
            end
            if row.current then
                layer:rect(x0 + 6 * s, y + 4 * s, 3 * s, row_h - 10 * s, t.accent, 255)
            elseif row.selected then
                layer:rect(x0 + 6 * s, y + 4 * s, 3 * s, row_h - 10 * s, t.mute, 220)
            end
            local hint_w = row.hint and (util.text_width(row.hint, 11 * s) + 10 * s) or 0
            layer:text_fit(x0 + 16 * s, y + 7 * s, 12.5 * s,
                (row.current or hot or row.selected) and t.text or t.mute, 7, row.text,
                w - 30 * s - hint_w)
            if row.hint and row.hint ~= "" then
                layer:text(x0 + w - 12 * s, y + 8 * s, 11 * s, t.mute, 9, row.hint)
            end
            layer:hit(x0 + 6 * s, y, w - 12 * s, row_h - 2 * s,
                { id = id, click = row.click, dbl = row.dbl })
        end

        if #rows == 0 then
            layer:text(x0 + 16 * s, top + 6 * s, 12.5 * s, t.mute, 7, "비어 있음")
        end

        -- 스크롤 막대 (끌어서 움직일 수 있다)
        if max_scroll > 0 then
            local track_h = bottom - top
            local kh = math.max(24 * s, track_h * vis / #rows)
            local ky = top + (track_h - kh) * (scroll / max_scroll)
            local hot = layer:hovered("scrollbar")
            layer:rect(ow - 6 * s, top, 3 * s, track_h, t.line, 140)
            layer:rect(ow - 6 * s, ky, 3 * s, kh, hot and t.text or t.mute, hot and 230 or 150)
            local function to_scroll(_, my)
                local pos = util.clamp((my - top - kh / 2) / math.max(1, track_h - kh), 0, 1)
                scroll = util.round(pos * max_scroll)
                follow = false
                draw()
            end
            layer:hit(ow - 14 * s, top, 14 * s, track_h,
                { id = "scrollbar", press = to_scroll, drag = to_scroll })
        end
        layer:text(x0 + 12 * s, oh - 20 * s, 11 * s, t.mute, 7,
            string.format("%d개", #rows))
    end

    -- 아래 동작 줄 (목록 탭만)
    if tab == "pl" then
        local aw = (w - 16 * s) / #ACTIONS
        for i, a in ipairs(ACTIONS) do
            local x = x0 + 8 * s + (i - 1) * aw
            local id = "act" .. i
            layer:text_fit(x + aw / 2, oh - 44 * s, 11 * s,
                layer:hovered(id) and t.text or t.mute, 8, a.t, aw - 4 * s)
            layer:hit(x, oh - 50 * s, aw, 22 * s, {
                id = id,
                click = function() mp.commandv("script-message", "boda-" .. a.msg) end,
            })
        end
    end

    -- 왼쪽 가장자리: 끌어서 너비 조절 (누른 채로 움직이면 자유롭게, 그냥 누르면 정해진 크기 순환)
    local grip = layer:hovered("grip")
    layer:rect(x0, 0, grip and 3 * s or 1, oh, grip and t.accent or t.line, 255)
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
    publish()
    layer:flush()
end

draw = ui.guard("패널", draw_impl)
M.draw = draw

function M.set(target)
    if target == "toggle" then
        open = not open
    elseif target == "close" then
        open = false
    else
        local id = ({ playlist = "pl", pl = "pl", audio = "audio", sub = "sub",
            video = "video", chapter = "chapter", color = "color" })[target]
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

    mp.add_key_binding(nil, "panel-toggle", function() M.set("toggle") end)

    -- 목록에서 고른 항목이 있으면 그것을, 없으면 지금 재생 중인 것을 뺀다.
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
        apply_sort()
        if open then draw() end
    end)
    -- 재생 중인 파일이 바뀌었을 때만 목록을 그 항목으로 따라 움직인다.
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
