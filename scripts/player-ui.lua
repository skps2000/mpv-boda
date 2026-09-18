-- In-window playlist, color panel, recent folders (same mpv window).

local mp = require("mp")
local utils = require("mp.utils")

local ov = mp.create_osd_overlay("ass-events")
ov.z = 80

local pl_on, col_on, recent_on = false, false, true
local tab = "pl"
local scroll = 0
local hover, drag = nil, nil
local hits = {}
local recent = {}
local selected = nil -- playlist filename selected (single click)
local sort_key, sort_desc = "name", false
local pl_w, col_w = 300, 280
local PL_PRESETS = {240, 320, 420, 540}
local auto_color = true
local auto_name = ""
local sorting = false
local last_click_id, last_click_t = nil, 0
local meta = {} -- path -> {size, mtime, duration, pixels}

local recent_file = mp.command_native({"expand-path", "~~/recent-folders.txt"})
local state_file = mp.command_native({"expand-path", "~~/ui-state.txt"})

local COLORS = {
    {id = "brightness", name = "밝기", keys = "W / E"},
    {id = "contrast",   name = "대비", keys = "R / T"},
    {id = "saturation", name = "채도", keys = "Y / U"},
    {id = "gamma",      name = "감마", keys = "Ctrl+Shift+W/E"},
    {id = "hue",        name = "색상", keys = "I / O"},
}

local SORTS = {
    {id = "name",     t = "이름"},
    {id = "size",     t = "크기"},
    {id = "quality",  t = "화질"},
    {id = "duration", t = "길이"},
    {id = "mtime",    t = "수정일"},
}

local function esc(s)
    s = tostring(s or "")
    return s:gsub("\\", "\\\\"):gsub("{", "("):gsub("}", ")"):gsub("\n", " ")
end

local function load_state()
    local f = io.open(state_file, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^(%w+)=(.+)$")
        if k == "pl_w" then pl_w = tonumber(v) or pl_w end
        if k == "col_w" then col_w = tonumber(v) or col_w end
        if k == "sort" then sort_key = v end
        if k == "desc" then sort_desc = (v == "1") end
        if k == "auto" then auto_color = (v ~= "0") end
    end
    f:close()
end

local function save_state()
    local f = io.open(state_file, "w")
    if not f then return end
    f:write(string.format("pl_w=%d\ncol_w=%d\nsort=%s\ndesc=%s\nauto=%s\n",
        pl_w, col_w, sort_key, sort_desc and "1" or "0", auto_color and "1" or "0"))
    f:close()
end

local function load_recent()
    recent = {}
    local f = io.open(recent_file, "r")
    if not f then return end
    for line in f:lines() do
        line = line:gsub("%s+$", "")
        if line ~= "" then recent[#recent + 1] = line end
        if #recent >= 12 then break end
    end
    f:close()
end

local function save_recent()
    local f = io.open(recent_file, "w")
    if not f then return end
    for i = 1, math.min(12, #recent) do f:write(recent[i], "\n") end
    f:close()
end

local function remember_path(path)
    if not path or path:match("^https?://") then return end
    local dir = utils.split_path(path)
    if not dir or dir == "" then return end
    dir = dir:gsub("[\\/]+$", "")
    local out = {dir}
    for _, p in ipairs(recent) do
        if p:lower() ~= dir:lower() then out[#out + 1] = p end
        if #out >= 12 then break end
    end
    recent = out
    save_recent()
end

local function osd_size()
    return mp.get_property_number("osd-width") or 1280, mp.get_property_number("osd-height") or 720
end

local last_ml, last_mr = -1, -1

local function clamp_widths()
    local ow = select(1, osd_size())
    if ow < 80 then return end
    pl_w = math.max(220, math.min(math.floor(ow * 0.5), math.floor(pl_w)))
    col_w = math.max(220, math.min(math.floor(ow * 0.45), math.floor(col_w)))
end

local function apply_margins()
    local ow = select(1, osd_size())
    if ow < 80 then return end
    clamp_widths()
    local r = (pl_on and mp.get_property("path")) and (pl_w / ow) or 0
    local l = (col_on and mp.get_property("path")) and (col_w / ow) or 0
    if math.abs(l - last_ml) < 0.002 and math.abs(r - last_mr) < 0.002 then return end
    last_ml, last_mr = l, r
    mp.set_property_number("video-margin-ratio-left", l)
    mp.set_property_number("video-margin-ratio-right", r)
    mp.set_property_number("video-margin-ratio-top", 0)
    mp.set_property_number("video-margin-ratio-bottom", 0)
end

local function cycle_pl_size()
    local idx = 1
    for i, w in ipairs(PL_PRESETS) do
        if math.abs(pl_w - w) <= 24 then
            idx = i
            break
        elseif pl_w >= w then
            idx = i
        end
    end
    idx = (idx % #PL_PRESETS) + 1
    pl_w = PL_PRESETS[idx]
    last_ml, last_mr = -1, -1
    clamp_widths()
    apply_margins()
    mp.osd_message("목록 너비 " .. tostring(pl_w))
end

local function quality_from_name(path)
    local low = path:lower()
    if low:find("2160p", 1, true) or low:find("2160", 1, true) or low:find("4k", 1, true) then
        return 3840 * 2160
    elseif low:find("1440p", 1, true) or low:find("2k", 1, true) then
        return 2560 * 1440
    elseif low:find("1080p", 1, true) or low:find("1080", 1, true) or low:find("fhd", 1, true) then
        return 1920 * 1080
    elseif low:find("720p", 1, true) or low:find("720", 1, true) then
        return 1280 * 720
    elseif low:find("480p", 1, true) or low:find("480", 1, true) then
        return 640 * 480
    end
    return 0
end

local function get_meta(path)
    if not path then return {size = 0, mtime = 0, duration = 0, pixels = 0} end
    local m = meta[path]
    if m then return m end
    m = {size = 0, mtime = 0, duration = 0, pixels = quality_from_name(path)}
    local fi = utils.file_info(path)
    if fi then
        m.size = fi.size or 0
        m.mtime = fi.mtime or 0
    end
    meta[path] = m
    return m
end

local prefetch_q, prefetch_n, prefetch_busy = {}, 0, false
local function prefetch_meta_step()
    local n = 0
    while prefetch_n > 0 and n < 64 do
        local path = prefetch_q[prefetch_n]
        prefetch_q[prefetch_n] = nil
        prefetch_n = prefetch_n - 1
        if path and not meta[path] then get_meta(path) end
        n = n + 1
    end
    if prefetch_n > 0 then
        mp.add_timeout(0.02, prefetch_meta_step)
    else
        prefetch_busy = false
    end
end

local function queue_prefetch(pl)
    if not pl then return end
    for i = #pl, 1, -1 do
        local p = pl[i].filename
        if p and not meta[p] then
            prefetch_n = prefetch_n + 1
            prefetch_q[prefetch_n] = p
        end
    end
    if prefetch_n > 0 and not prefetch_busy then
        prefetch_busy = true
        mp.add_timeout(0.02, prefetch_meta_step)
    end
end

local function cache_current_media()
    local path = mp.get_property("path")
    if not path then return end
    local m = get_meta(path)
    m.duration = mp.get_property_number("duration") or m.duration
    local w = mp.get_property_number("video-params/w") or 0
    local h = mp.get_property_number("video-params/h") or 0
    if w > 0 and h > 0 then m.pixels = w * h end
    meta[path] = m
end

function basename_of(p)
    if not p then return "(없음)" end
    local _, f = utils.split_path(p)
    return (f and f ~= "") and f or p
end

local function key_of(e)
    local path = e.filename or ""
    local name = (e.title or basename_of(path)):lower()
    if sort_key == "name" then return name, name end
    local m = get_meta(path)
    if sort_key == "size" then return m.size or 0, name end
    if sort_key == "quality" then return m.pixels or 0, name end
    if sort_key == "duration" then return m.duration or 0, name end
    if sort_key == "mtime" then return m.mtime or 0, name end
    return name, name
end

local function apply_sort()
    local pl = mp.get_property_native("playlist") or {}
    local n = #pl
    if n < 2 then return end

    local rows = {}
    for i, e in ipairs(pl) do
        local k, name = key_of(e)
        rows[i] = {orig = i - 1, file = e.filename, key = k, name = name}
    end
    table.sort(rows, function(a, b)
        if a.key == b.key then
            if sort_desc then return a.name > b.name end
            return a.name < b.name
        end
        if sort_desc then
            if type(a.key) == "string" then return a.key > b.key end
            return (a.key or 0) > (b.key or 0)
        end
        if type(a.key) == "string" then return a.key < b.key end
        return (a.key or 0) < (b.key or 0)
    end)

    local same = true
    for i = 1, n do
        if rows[i].orig ~= i - 1 then same = false break end
    end
    if same then return end

    -- pos[orig] = current index; playlist-move src dest → dest is the FINAL index
    local pos = {}
    for i = 0, n - 1 do pos[i] = i end

    sorting = true
    for dest = 0, n - 1 do
        local orig = rows[dest + 1].orig
        local src = pos[orig]
        if src ~= dest then
            mp.commandv("playlist-move", src, dest)
            if src > dest then
                for k = 0, n - 1 do
                    local p = pos[k]
                    if p == src then pos[k] = dest
                    elseif p >= dest and p < src then pos[k] = p + 1 end
                end
            else
                for k = 0, n - 1 do
                    local p = pos[k]
                    if p == src then pos[k] = dest
                    elseif p > src and p <= dest then pos[k] = p - 1 end
                end
            end
        end
    end
    sorting = false
end

local function play_index(i)
    mp.commandv("playlist-play-index", i)
    mp.set_property_bool("pause", false)
end

local function recommend_eq()
    local path = (mp.get_property("path") or ""):lower()
    local transfer = tostring(mp.get_property("video-params/gamma") or mp.get_property("video-params/color-transfer") or "")
    local peak = mp.get_property_number("video-params/sig-peak") or 0
    local h = mp.get_property_number("video-params/h") or 0
    local eq = {brightness = 0, contrast = 0, saturation = 0, gamma = 0, hue = 0}
    local name = "원본"

    local hdr = transfer:find("pq") or transfer:find("hlg") or peak > 1.2 or path:find("hdr")
    if hdr then
        name = "HDR 유지"
        return eq, name
    end
    if h >= 2160 then
        eq = {brightness = 1, contrast = 3, saturation = 3, gamma = 0, hue = 0}
        name = "4K SDR 추천"
    elseif h >= 1080 then
        eq = {brightness = 2, contrast = 5, saturation = 5, gamma = -1, hue = 0}
        name = "FHD 추천"
    elseif h > 0 then
        eq = {brightness = 4, contrast = 7, saturation = 6, gamma = -2, hue = 0}
        name = "저해상 선명"
    else
        eq = {brightness = 2, contrast = 4, saturation = 4, gamma = 0, hue = 0}
        name = "기본 추천"
    end
    if path:find("night") or path:find("dark") or path:find("어두운") or path:find("night") then
        eq.brightness = eq.brightness + 6
        eq.gamma = eq.gamma - 3
        name = name .. " · 어두운 영상"
    end
    return eq, name
end

local function apply_auto_color()
    if not auto_color then
        auto_name = "수동"
        return
    end
    local eq, name = recommend_eq()
    auto_name = name
    for k, v in pairs(eq) do
        mp.set_property_number(k, v)
    end
end

-- Visual tokens (ASS is BGR). YouTube player: #0F0F0F + #FF0000.
local C = {
    bg = "0F0F0F",
    bg2 = "212121",
    hover = "3D3D3D",
    line = "272727",
    track = "717171",
    text = "FFFFFF",
    mute = "AAAAAA",
    acc = "0000FF", -- YouTube red
    acc2 = "FFFFFF",
}

local function rect(x, y, w, h, bgr, a)
    return string.format(
        "{\\an7\\pos(%.0f,%.0f)\\bord0\\shad0\\p1\\1c&H%s&\\1a&H%s&}m 0 0 l %.0f 0 l %.0f %.0f l 0 %.0f{\\p0}",
        x, y, bgr, a or "00", w, w, h, h)
end

local function txt(x, y, size, bgr, a, align, s)
    return string.format("{\\an%d\\pos(%.0f,%.0f)\\fnMalgun Gothic\\fs%d\\b0\\bord0\\shad0\\1c&H%s&\\1a&H%s&}%s",
        align or 7, x, y, size, bgr, a or "00", esc(s))
end

local function add_hit(x, y, w, h, fn, id, extra)
    local t = {x = x, y = y, w = w, h = h, fn = fn, id = id}
    if extra then for k, v in pairs(extra) do t[k] = v end end
    hits[#hits + 1] = t
end

local function hit_at(mx, my)
    for i = #hits, 1, -1 do
        local h = hits[i]
        if mx >= h.x and mx <= h.x + h.w and my >= h.y and my <= h.y + h.h then
            return h
        end
    end
    return nil
end

local function draw()
    hits = {}
    local ow, oh = osd_size()
    ov.res_x, ov.res_y = ow, oh
    if ow < 40 or oh < 40 then ov.data = "" ov:update() return end
    clamp_widths()

    local a = {}
    local function P(s) a[#a + 1] = s end
    local idle = not mp.get_property("path")

    if idle and recent_on then
        local hist = mp.get_property_native("user-data/pp-history") or {}
        P(rect(0, 0, ow, oh, C.bg, "20"))
        local pad = math.max(36, math.floor(ow * 0.06))
        P(txt(pad, 36, 32, C.text, "00", 7, "이어서 보기"))
        P(txt(pad, 76, 14, C.mute, "00", 7, "F2 폴더   F3 파일   F6 목록   F7 색감"))
        local y = 118
        local cardw = math.min(720, ow - pad * 2)
        if #hist > 0 then
            P(txt(pad, y, 13, C.mute, "00", 7, "최근 영상"))
            y = y + 28
            for i = 1, math.min(8, #hist) do
                local hitem = hist[i]
                local hp = hitem.path
                local pct = (hitem.dur and hitem.dur > 0) and math.floor(100 * (hitem.pos or 0) / hitem.dur) or 0
                local done = pct >= 90
                local name = basename_of(hp)
                local hot = hover == ("h" .. i)
                P(rect(pad, y, cardw, 52, hot and C.hover or C.bg2, "28"))
                P(txt(pad + 18, y + 10, 16, done and C.mute or C.text, "00", 7, name))
                P(rect(pad + 18, y + 36, cardw - 36, 3, C.track, "00"))
                P(rect(pad + 18, y + 36, math.max(2, (cardw - 36) * math.min(1, pct / 100)), 3, C.acc, "00"))
                P(txt(pad + cardw - 18, y + 12, 12, C.mute, "00", 9, done and "완료" or (pct .. "%")))
                add_hit(pad, y, cardw, 52, function()
                    mp.commandv("loadfile", hp, "replace")
                    mp.set_property_bool("pause", false)
                end, "h" .. i)
                y = y + 60
            end
        end
        P(txt(pad, y + 8, 13, C.mute, "00", 7, "최근 폴더"))
        y = y + 32
        if #recent == 0 and #hist == 0 then
            P(txt(pad, y, 15, C.mute, "00", 7, "아직 기록이 없습니다. F2 / F3 으로 여세요."))
        end
        for i, p in ipairs(recent) do
            local rp, ri = p, i
            local hot = hover == ("r" .. ri)
            P(rect(pad, y, cardw, 34, hot and C.hover or C.bg2, "40"))
            P(txt(pad + 18, y + 8, 14, C.text, "00", 7, rp))
            add_hit(pad, y, cardw, 34, function()
                mp.commandv("loadfile", rp, "replace")
                mp.set_property_bool("pause", false)
            end, "r" .. ri)
            y = y + 40
        end
        ov.data = table.concat(a, "\n")
        ov:update()
        return
    end

    if col_on then
        P(rect(0, 0, col_w, oh, C.bg, "18"))
        P(rect(col_w - 1, 0, 1, oh, C.line, "00"))
        P(txt(20, 18, 18, C.text, "00", 7, "색감"))
        P(txt(20, 42, 12, C.mute, "00", 7, "F7"))
        local rec = auto_color and (auto_name ~= "" and auto_name or "자동") or "수동"
        P(rect(20, 64, col_w - 40, 26, auto_color and C.acc or C.bg2, auto_color and "00" or "00"))
        P(txt(col_w / 2, 68, 13, C.text, "00", 8, rec))
        add_hit(20, 64, col_w - 40, 26, function()
            auto_color = not auto_color
            if auto_color then apply_auto_color() else
                for _, c in ipairs(COLORS) do mp.set_property_number(c.id, 0) end
                auto_name = "수동"
            end
            save_state()
            draw()
        end, "auto")

        for i, c in ipairs(COLORS) do
            local cid, cname = c.id, c.name
            local y = 104 + (i - 1) * 58
            local val = mp.get_property_number(cid) or 0
            P(txt(20, y, 13, C.text, "00", 7, cname))
            P(txt(col_w - 20, y, 12, C.mute, "00", 9, string.format("%d", val)))
            local bx, by, bw, bh = 20, y + 24, col_w - 40, 4
            P(rect(bx, by, bw, bh, C.track, "00"))
            local ratio = (val + 100) / 200
            local fw = math.max(2, bw * ratio)
            P(rect(bx, by, fw, bh, C.acc, "00"))
            P(rect(bx + fw - 5, by - 4, 10, 12, C.text, "00"))
            add_hit(bx, by - 10, bw, bh + 20, function(mx)
                auto_color = false
                auto_name = "수동"
                local t = (mx - bx) / bw
                if t < 0 then t = 0 elseif t > 1 then t = 1 end
                mp.set_property_number(cid, math.floor(t * 200 - 100 + 0.5))
                draw()
            end, "c" .. cid, {kind = "slider"})
        end
        local ry = 104 + #COLORS * 58 + 8
        P(txt(col_w / 2, ry, 13, C.mute, "00", 8, "원본  Q"))
        add_hit(20, ry - 4, col_w - 40, 24, function()
            auto_color = false
            auto_name = "수동"
            for _, c in ipairs(COLORS) do mp.set_property_number(c.id, 0) end
            save_state()
            draw()
        end, "reset")
        local extras = {
            {t = "업스케일", msg = "pp-upscale"},
            {t = "듀얼 자막", msg = "pp-dual-sub"},
            {t = "PiP", msg = "pp-pip"},
        }
        for i, ex in ipairs(extras) do
            local msg, label, yi = ex.msg, ex.t, i
            local yb = ry + 32 + (yi - 1) * 28
            P(txt(20, yb, 13, hover == ("ex" .. yi) and C.text or C.mute, "00", 7, label))
            add_hit(16, yb - 4, col_w - 32, 24, function()
                mp.commandv("script-message", msg)
            end, "ex" .. yi)
        end
    end

    if pl_on then
        local x0 = ow - pl_w
        P(rect(x0, 0, pl_w, oh, C.bg, "18"))
        P(rect(x0, 0, 1, oh, C.line, "00"))

        local tabs = {
            {id = "pl", t = "목록"},
            {id = "audio", t = "오디오"},
            {id = "sub", t = "자막"},
            {id = "video", t = "비디오"},
            {id = "chapter", t = "챕터"},
        }
        local tw = (pl_w - 16) / #tabs
        for i, tdef in ipairs(tabs) do
            local tid, tlabel = tdef.id, tdef.t
            local x = x0 + 8 + (i - 1) * tw
            local on = tab == tid
            P(txt(x + tw / 2, 14, 13, on and C.text or C.mute, "00", 8, tlabel))
            if on then P(rect(x + 8, 34, tw - 16, 2, C.acc, "00")) end
            add_hit(x, 8, tw, 30, function()
                tab = tid
                scroll = 0
                draw()
            end, "tab" .. tid)
        end

        local top = 44
        if tab == "pl" then
            local bw = (pl_w - 24) / #SORTS
            for i, sdef in ipairs(SORTS) do
                local sid, slabel = sdef.id, sdef.t
                local x = x0 + 14 + (i - 1) * bw
                local on = sort_key == sid
                local arrow = on and (sort_desc and " ↓" or " ↑") or ""
                P(txt(x + bw / 2, 46, 11, on and C.acc or C.mute, "00", 8, slabel .. arrow))
                add_hit(x, 42, bw, 22, function()
                    if sort_key == sid then sort_desc = not sort_desc else
                        sort_key = sid
                        sort_desc = false
                    end
                    save_state()
                    apply_sort()
                    draw()
                end, "sort" .. sid)
            end
            top = 70
        end

        local rows = {}
        if tab == "pl" then
            for i, e in ipairs(mp.get_property_native("playlist") or {}) do
                local path = e.filename
                local idx = i - 1
                rows[#rows + 1] = {
                    text = (e.current and "▶ " or "   ") .. basename_of(e.title or path),
                    cur = e.current,
                    sel = selected == path,
                    play = function() play_index(idx) end,
                    sel_fn = function() selected = path draw() end
                }
            end
        elseif tab == "audio" or tab == "sub" or tab == "video" then
            local kind = tab
            if tab == "sub" then
                rows[#rows + 1] = {
                    text = "(자막 끄기)",
                    cur = mp.get_property("sid") == "no",
                    play = function() mp.set_property("sid", "no") draw() end
                }
            end
            for _, tr in ipairs(mp.get_property_native("track-list") or {}) do
                if tr.type == kind then
                    local tid, tkind = tr.id, kind
                    rows[#rows + 1] = {
                        text = string.format("%s %s %s", tr.id or "", tr.lang or "", tr.title or tr.codec or ""),
                        cur = tr.selected,
                        play = function()
                            mp.set_property(({audio = "aid", sub = "sid", video = "vid"})[tkind], tid)
                            draw()
                        end
                    }
                end
            end
        else
            for i, ch in ipairs(mp.get_property_native("chapter-list") or {}) do
                local ci = i - 1
                local ctitle = ch.title or ("챕터 " .. i)
                rows[#rows + 1] = {
                    text = ctitle,
                    cur = (mp.get_property_number("chapter") or -1) == ci,
                    play = function() mp.set_property_number("chapter", ci) draw() end
                }
            end
            for i, t in ipairs(mp.get_property_native("user-data/pp-bookmarks") or {}) do
                local sec = tonumber(t) or 0
                local bi = i
                rows[#rows + 1] = {
                    text = string.format("북마크 %d  (%d:%02d)", bi, math.floor(sec / 60), math.floor(sec % 60)),
                    cur = false,
                    play = function() mp.commandv("seek", sec, "absolute") end
                }
            end
        end

        local row_h = 32
        local vis = math.max(1, math.floor((oh - top - 56) / row_h))
        if scroll > math.max(0, #rows - vis) then scroll = math.max(0, #rows - vis) end
        if scroll < 0 then scroll = 0 end
        for i = 1, vis do
            local idx = scroll + i
            local row = rows[idx]
            if not row then break end
            local y = top + (i - 1) * row_h
            local hot = hover == ("p" .. idx)
            if row.cur then
                P(rect(x0 + 8, y + 6, 2, row_h - 14, C.acc, "00"))
            elseif hot or row.sel then
                P(rect(x0 + 8, y, pl_w - 16, row_h - 2, C.hover, "40"))
            end
            local tc = row.cur and C.text or (hot and C.text or C.mute)
            P(txt(x0 + 18, y + 8, 13, tc, "00", 7, row.text))
            if tab == "pl" then
                add_hit(x0 + 14, y, pl_w - 22, row_h - 2, row.sel_fn, "p" .. idx, {dbl = row.play})
            else
                add_hit(x0 + 14, y, pl_w - 22, row_h - 2, row.play, "p" .. idx)
            end
        end
        local acts = {
            {t = "저장", msg = "pp-save-m3u"},
            {t = "열기", msg = "pp-load-m3u"},
            {t = "인트로", msg = "pp-mark-intro"},
            {t = "엔딩", msg = "pp-mark-outro"},
            {t = "녹화", msg = "pp-record"},
        }
        local aw = (pl_w - 24) / #acts
        for i, ac in ipairs(acts) do
            local msg, label, ai = ac.msg, ac.t, i
            local x = x0 + 14 + (ai - 1) * aw
            P(txt(x + aw / 2, oh - 44, 11, hover == ("act" .. ai) and C.text or C.mute, "00", 8, label))
            add_hit(x, oh - 50, aw - 2, 22, function()
                mp.commandv("script-message", msg)
            end, "act" .. ai)
        end
        P(txt(x0 + 16, oh - 22, 11, C.mute, "00", 7, #rows .. "   F6"))
        local gh = hover == "drag-pl"
        P(rect(x0, 0, gh and 4 or 1, oh, gh and C.acc or C.line, "00"))
        add_hit(x0, 0, 12, oh, function() end, "drag-pl", {kind = "drag-pl"})
    end

    if col_on then
        local gh = hover == "drag-col"
        P(rect(col_w - (gh and 4 or 1), 0, gh and 4 or 1, oh, gh and C.acc or C.line, "00"))
        add_hit(col_w - 12, 0, 12, oh, function() end, "drag-col", {kind = "drag-col"})
    end

    if not col_on and not pl_on and not (idle and recent_on) then
        ov.data = ""
    else
        ov.data = table.concat(a, "\n")
    end
    ov:update()
end

local function bind_mouse(on)
    mp.remove_key_binding("ui-lmb")
    mp.remove_key_binding("ui-wu")
    mp.remove_key_binding("ui-wd")
    if not on then return end
    mp.add_forced_key_binding("MBTN_LEFT", "ui-lmb", function(e)
        local ok, err = pcall(function()
            local m = mp.get_property_native("mouse-pos")
            if e.event == "down" then
                if not m then return end
                local h = hit_at(m.x, m.y)
                if not h then return end
                if h.kind == "drag-pl" then
                    drag = {kind = "pl", x = m.x, w = pl_w, moved = false}
                    return
                end
                if h.kind == "drag-col" then
                    drag = {kind = "col", x = m.x, w = col_w, moved = false}
                    return
                end
                if h.kind == "slider" or (h.id and tostring(h.id):sub(1, 1) == "c") then
                    drag = h
                    if h.fn then h.fn(m.x, m.y) end
                    return
                end
                local now = mp.get_time()
                if h.dbl and last_click_id == h.id and (now - last_click_t) < 0.45 then
                    last_click_id = nil
                    h.dbl()
                    return
                end
                last_click_id, last_click_t = h.id, now
                if h.fn then h.fn(m.x, m.y) end
                draw()
            elseif e.event == "up" then
                if drag and drag.kind == "pl" then
                    if not drag.moved then
                        cycle_pl_size()
                        apply_margins()
                    end
                end
                drag = nil
                save_state()
                draw()
            end
        end)
        if not ok then mp.msg.error("ui-lmb: " .. tostring(err)) end
    end, {complex = true})
        mp.add_forced_key_binding("WHEEL_UP", "ui-wu", function()
            local m = mp.get_property_native("mouse-pos")
            local ow = select(1, osd_size())
            if pl_on and m and m.x >= ow - pl_w then
                scroll = scroll - 1
                draw()
                return
            end
            mp.command("add volume 5")
        end)
        mp.add_forced_key_binding("WHEEL_DOWN", "ui-wd", function()
            local m = mp.get_property_native("mouse-pos")
            local ow = select(1, osd_size())
            if pl_on and m and m.x >= ow - pl_w then
                scroll = scroll + 1
                draw()
                return
            end
            mp.command("add volume -5")
        end)
end

local function ui_active()
    local idle = not mp.get_property("path")
    return pl_on or col_on or (idle and recent_on)
end

local function bind_recent_digits(on)
    for i = 1, 9 do
        local name = "recent-" .. i
        if on then
            mp.add_forced_key_binding(tostring(i), name, function()
                if recent[i] then
                    mp.commandv("loadfile", recent[i], "replace")
                    mp.set_property_bool("pause", false)
                end
            end)
        else
            mp.remove_key_binding(name)
        end
    end
end

local function refresh_binds()
    bind_mouse(ui_active())
    bind_recent_digits(recent_on and not mp.get_property("path"))
    mp.set_property("cursor-autohide", (col_on or pl_on) and "no" or "1000")
    apply_margins()
    draw()
end

local function toggle_pl()
    pl_on = not pl_on
    if pl_on then
        recent_on = false
        if (pl_w or 0) < 220 then pl_w = 320 end
        clamp_widths()
        last_ml, last_mr = -1, -1
    end
    refresh_binds()
end

local function toggle_col()
    col_on = not col_on
    if col_on then recent_on = false end
    refresh_binds()
end

mp.register_script_message("ui-pl-toggle", toggle_pl)
mp.register_script_message("ui-color-toggle", toggle_col)
mp.register_script_message("pp-dock-toggle", toggle_pl)
mp.register_script_message("pp-color-toggle", toggle_col)
mp.register_script_message("pp-dock-show", function(t)
    pl_on = true
    recent_on = false
    tab = ({audio = "audio", sub = "sub", video = "video", chapter = "chapter", playlist = "pl"})[t] or "pl"
    refresh_binds()
end)

mp.observe_property("playlist", "native", function(_, pl)
    if sorting then return end
    queue_prefetch(pl)
    if pl_on then draw() end
end)
mp.observe_property("osd-width", "number", function() if ui_active() then draw() end end)
mp.observe_property("osd-height", "number", function() if ui_active() then draw() end end)
mp.observe_property("mouse-pos", "native", function(_, m)
    if not m or not ui_active() then return end
    if drag then
        if drag.kind == "pl" then
            local dx = math.abs((m.x or 0) - (drag.x or 0))
            if dx > 12 then
                drag.moved = true
                local ow = select(1, osd_size())
                pl_w = math.max(220, math.min(math.floor(ow * 0.5), ow - m.x))
                last_ml, last_mr = -1, -1
                apply_margins()
                draw()
            end
            return
        elseif drag.kind == "col" then
            local dx = math.abs((m.x or 0) - (drag.x or 0))
            if dx > 12 then
                drag.moved = true
                col_w = math.max(220, math.min(math.floor(select(1, osd_size()) * 0.45), m.x))
                last_ml, last_mr = -1, -1
                apply_margins()
                draw()
            end
            return
        elseif drag.fn then
            drag.fn(m.x, m.y)
            return
        end
    end
    local h = hit_at(m.x or -1, m.y or -1)
    local id = h and h.id or nil
    if id ~= hover then hover = id draw() end
end)

local saved_geom = nil
mp.register_event("start-file", function()
    local w, h = osd_size()
    if w and h and w > 120 and h > 80 then
        saved_geom = string.format("%dx%d", math.floor(w), math.floor(h))
    end
end)

mp.register_event("file-loaded", function()
    recent_on = false
    remember_path(mp.get_property("path"))
    mp.set_property("keepaspect", "yes")
    mp.set_property("keepaspect-window", "no")
    mp.set_property_bool("pause", false)
    if saved_geom then mp.set_property("geometry", saved_geom) end
    cache_current_media()
    mp.add_timeout(0.35, function()
        cache_current_media()
        apply_auto_color()
        draw()
    end)
    apply_margins()
    refresh_binds()
end)

mp.observe_property("path", "string", function(_, p)
    if not p or p == "" then
        recent_on = true
        refresh_binds()
    end
end)

load_state()
load_recent()
mp.add_timeout(0.15, refresh_binds)
