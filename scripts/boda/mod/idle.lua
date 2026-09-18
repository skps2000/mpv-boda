-- 파일이 없을 때 뜨는 "이어서 보기" 화면.
-- 창 크기에 맞춰 들어갈 만큼만 그리고 나머지는 스크롤한다. 제목은 폭에 맞춰 자른다.
local mp = require("mp")
local util = require("lib.util")
local ui = require("lib.ui")
local state = require("lib.state")

local M = {}

local layer
local active = false
local scroll = 0
local visible_items = {} -- 숫자키로 열 수 있는 최근 영상

local function play(path)
    mp.commandv("loadfile", path, "replace")
    mp.set_property_bool("pause", false)
end

-- 화면에 그릴 항목들을 먼저 만든다 (높이를 알아야 몇 개가 들어가는지 계산할 수 있다).
local function build(s)
    local items = {}
    local history = state.history or {}
    if #history > 0 then
        items[#items + 1] = { kind = "header", text = "최근 영상", h = 30 * s }
        for _, h in ipairs(history) do
            if h.path then
                items[#items + 1] = { kind = "video", entry = h, h = 56 * s }
            end
        end
    end
    if #(state.recent or {}) > 0 then
        items[#items + 1] = { kind = "header", text = "최근 폴더", h = 34 * s }
        for _, dir in ipairs(state.recent) do
            items[#items + 1] = { kind = "folder", path = dir, h = 32 * s }
        end
    end
    return items
end

local draw -- 아래에서 ui.guard 로 감싼다
local function draw_impl()
    if not active or not ui.ready() then
        layer:hide()
        return
    end
    local ow, oh, s = layer:start()
    local t = ui.theme

    layer:rect(0, 0, ow, oh, t.bg, 255)

    local pad = math.max(18 * s, math.min(ow * 0.06, 56 * s))
    local title_size = math.min(28 * s, oh * 0.06)
    layer:text_fit(pad, pad * 0.7, title_size, t.text, 7, "이어서 보기", ow - pad * 2)

    local hint_y = pad * 0.7 + title_size + 6 * s
    layer:text_fit(pad, hint_y, 12 * s, t.mute, 7,
        "F2 폴더   F3 파일   F6 목록   F7 색감   ·   숫자키로 최근 영상 열기", ow - pad * 2)

    local top = hint_y + 26 * s
    local bottom = oh - 10 * s
    local avail = bottom - top
    local card_w = math.min(780 * s, ow - pad * 2)

    local items = build(s)
    visible_items = {}

    if #items == 0 then
        layer:text_fit(pad, top + 10 * s, 14 * s, t.mute, 7,
            "아직 기록이 없습니다. F2(폴더) 또는 F3(파일)으로 여세요.", ow - pad * 2)
        layer:flush()
        return
    end

    -- 스크롤 범위: 아래가 남지 않도록 맞춘다.
    local total = 0
    for _, it in ipairs(items) do total = total + it.h end
    local max_scroll = 0
    if total > avail then
        local acc = 0
        for i = #items, 1, -1 do
            acc = acc + items[i].h
            if acc > avail then
                max_scroll = i
                break
            end
        end
    end
    scroll = util.clamp(scroll, 0, max_scroll)

    -- 카드보다 먼저 등록해서 아래에 깔리게 한다 (클릭은 카드가, 휠은 여기가 받는다).
    layer:hit(0, top, ow, bottom - top, {
        id = "surface",
        scroll = function(dir)
            scroll = util.clamp(scroll - dir, 0, max_scroll)
            draw()
        end,
    })

    local y = top
    local digit = 0
    for i = scroll + 1, #items do
        local it = items[i]
        if y + it.h > bottom then break end

        if it.kind == "header" then
            layer:text_fit(pad, y + it.h - 18 * s, 12 * s, t.mute, 7, it.text, card_w)
        elseif it.kind == "video" then
            local h = it.entry
            local id = "v" .. i
            local hot = layer:hovered(id)
            local pct = (h.dur and h.dur > 0) and util.clamp((h.pos or 0) / h.dur * 100, 0, 100) or 0
            local done = pct >= 92
            local card_h = it.h - 6 * s
            layer:rect(pad, y, card_w, card_h, hot and t.hover or t.bg2, hot and 210 or 150)

            digit = digit + 1
            local num_w = 0
            if digit <= 9 then
                num_w = 22 * s
                layer:text(pad + 12 * s, y + 9 * s, 12 * s, t.mute, 7, tostring(digit))
                visible_items[digit] = h.path
            end

            local right = (h.dur and h.dur > 0) and
                (done and "다 봄" or (util.fmt_time(h.pos or 0) .. " / " .. util.fmt_time(h.dur))) or ""
            local right_w = util.text_width(right, 11.5 * s) + 14 * s
            layer:text_fit(pad + 12 * s + num_w, y + 8 * s, 14 * s, done and t.mute or t.text, 7,
                util.basename(h.path), card_w - 24 * s - num_w - right_w)
            layer:text(pad + card_w - 12 * s, y + 9 * s, 11.5 * s, t.mute, 9, right)

            local bar_y = y + card_h - 12 * s
            layer:rect(pad + 12 * s, bar_y, card_w - 24 * s, 3 * s, t.track, 160)
            layer:rect(pad + 12 * s, bar_y, math.max(2, (card_w - 24 * s) * pct / 100), 3 * s,
                done and t.mute or t.accent, 255)

            local target = h.path
            layer:hit(pad, y, card_w, card_h, { id = id, click = function() play(target) end })
        else
            local id = "f" .. i
            local hot = layer:hovered(id)
            layer:rect(pad, y, card_w, it.h - 4 * s, hot and t.hover or t.bg2, hot and 200 or 110)
            layer:text_fit(pad + 12 * s, y + 7 * s, 12.5 * s, hot and t.text or t.mute, 7,
                it.path, card_w - 24 * s)
            local target = it.path
            layer:hit(pad, y, card_w, it.h - 4 * s, { id = id, click = function() play(target) end })
        end
        y = y + it.h
    end

    if max_scroll > 0 then
        local kh = math.max(24 * s, avail * (avail / total))
        local ky = top + (avail - kh) * (scroll / max_scroll)
        layer:rect(ow - 6 * s, ky, 3 * s, kh, t.mute, 150)
        layer:text(ow - pad, bottom - 16 * s, 11 * s, t.mute, 9, "휠로 스크롤")
    end

    layer:flush()
end

draw = ui.guard("대기 화면", draw_impl)
M.draw = draw

local function update()
    local idle = mp.get_property("path") == nil
    if idle ~= active then
        active = idle
        scroll = 0
        ui.hold_cursor(active or require("mod.panel").is_open())
    end
    draw()
end

function M.init()
    layer = ui.layer("idle", 75)
    layer.redraw = draw

    mp.observe_property("path", "string", function() update() end)
    mp.register_event("end-file", function() mp.add_timeout(0.05, update) end)
    mp.register_event("file-loaded", update)

    -- 숫자키: 대기 화면에서는 최근 영상 열기, 재생 중에는 퍼센트 이동.
    for i = 0, 9 do
        local n = i
        mp.add_key_binding(nil, "digit-" .. n, function()
            if active then
                local path = visible_items[n]
                if path then play(path) end
                return
            end
            if (mp.get_property_number("duration") or 0) <= 0 then return end
            mp.commandv("seek", n * 10, "absolute-percent")
            mp.osd_message(string.format("%d%%", n * 10), 0.6)
        end)
    end

    mp.add_timeout(0.2, update)
end

return M
