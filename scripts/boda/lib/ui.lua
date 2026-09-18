-- 화면에 그리는 레이어와 마우스 입력을 한 곳에서 관리한다.
-- 예전 구조는 두 스크립트가 MBTN_LEFT 를 동시에 강제로 붙잡아서, 나중에 켜진 쪽이
-- 클릭을 전부 먹어버렸다. 이제 입력 창구는 여기 하나뿐이다.
local mp = require("mp")
local util = require("lib.util")
local opts = require("lib.options")

local M = {}

local layers = {}     -- z 내림차순 (히트 테스트 순서)
local mouse_subs = {}
local hover_id = nil
local drag = nil
local cursor_saved = nil
local cursor_held = false

-- ── 색 ──────────────────────────────────────────────────────────────
local function to_ass(rgb) -- #RRGGBB → ASS 의 BBGGRR
    rgb = tostring(rgb or ""):gsub("#", "")
    if #rgb ~= 6 or rgb:match("%X") then rgb = "FF0000" end
    return rgb:sub(5, 6) .. rgb:sub(3, 4) .. rgb:sub(1, 2)
end

M.theme = {}

-- 목록 패널이 차지한 오른쪽 폭. 탐색바가 영상 영역에만 걸치도록 쓴다.
M.reserved_right = 0

local function build_theme()
    M.theme = {
        bg = to_ass("0F0F0F"),
        bg2 = to_ass("212121"),
        hover = to_ass("3D3D3D"),
        line = to_ass("323232"),
        track = to_ass("717171"),
        text = to_ass("FFFFFF"),
        mute = to_ass("AAAAAA"),
        accent = to_ass(opts.accent),
    }
end

-- ── 크기 ────────────────────────────────────────────────────────────
function M.osd_size()
    return mp.get_property_number("osd-width") or 0, mp.get_property_number("osd-height") or 0
end

-- 창이 작아도 읽을 수 있게 배율은 완만하게만 줄인다. 남는 공간에 몇 줄이
-- 들어가는지는 각 화면이 직접 계산한다.
function M.scale()
    if opts.scale and opts.scale > 0 then return opts.scale end
    local _, h = M.osd_size()
    if h <= 0 then return 1 end
    return util.clamp(h / 720, 0.82, 1.7)
end

function M.ready()
    local w, h = M.osd_size()
    return w >= 120 and h >= 90
end

-- ── 레이어 ──────────────────────────────────────────────────────────
local Layer = {}
Layer.__index = Layer

function M.layer(name, z)
    local l = setmetatable({
        name = name,
        z = z or 50,
        parts = {},
        regions = {},
        shown = false,
        ov = mp.create_osd_overlay("ass-events"),
    }, Layer)
    l.ov.z = l.z
    layers[#layers + 1] = l
    table.sort(layers, function(a, b) return a.z > b.z end)
    return l
end

function Layer:start()
    self.parts, self.regions = {}, {}
    local w, h = M.osd_size()
    self.ov.res_x, self.ov.res_y = w, h
    return w, h, M.scale()
end

function Layer:add(s)
    self.parts[#self.parts + 1] = s
end

function Layer:rect(x, y, w, h, color, opacity)
    if w <= 0 or h <= 0 then return end
    self:add(string.format(
        "{\\an7\\pos(%.0f,%.0f)\\bord0\\shad0\\p1\\1c&H%s&\\1a&H%02X&}m 0 0 l %.0f 0 l %.0f %.0f l 0 %.0f{\\p0}",
        x, y, color, 255 - (opacity or 255), w, w, h, h))
end

-- ASS 드로잉으로 아이콘을 그린다 (이모지 글꼴에 의존하지 않도록).
function Layer:draw(x, y, color, opacity, path)
    self:add(string.format("{\\an7\\pos(%.0f,%.0f)\\bord0\\shad0\\p1\\1c&H%s&\\1a&H%02X&}%s{\\p0}",
        x, y, color, 255 - (opacity or 255), path))
end

function Layer:text(x, y, size, color, align, s, opacity)
    self:add(string.format(
        "{\\an%d\\pos(%.0f,%.0f)\\fn%s\\fs%.0f\\b0\\bord0\\shad0\\1c&H%s&\\1a&H%02X&}%s",
        align or 7, x, y, opts.font, size, color, 255 - (opacity or 255), util.esc(s)))
end

-- 폭에 맞춰 잘라서 그린다. 반환값은 실제로 그린 문자열.
function Layer:text_fit(x, y, size, color, align, s, max_w, opacity)
    local cut = util.truncate(s, size, max_w)
    self:text(x, y, size, color, align, cut, opacity)
    return cut
end

function Layer:hit(x, y, w, h, spec)
    spec = spec or {}
    spec.x, spec.y, spec.w, spec.h = x, y, w, h
    spec.key = spec.id or tostring(#self.regions + 1)
    spec.id = self.name .. "/" .. spec.key
    spec.layer = self
    self.regions[#self.regions + 1] = spec
    return spec
end

function Layer:hovered(key)
    return hover_id == (self.name .. "/" .. key)
end

function Layer:flush()
    self.ov.data = table.concat(self.parts, "\n")
    self.ov:update()
    self.shown = true
end

function Layer:hide()
    self.parts, self.regions = {}, {}
    if self.shown then
        self.ov.data = ""
        self.ov:update()
        self.shown = false
    end
end

-- ── 히트 테스트 ─────────────────────────────────────────────────────
-- want 을 주면 그 동작을 가진 영역 중 가장 위쪽 것을 찾는다.
-- (예: 목록 행 위에서 휠을 굴려도 패널 스크롤이 잡히도록)
local function region_at(x, y, want)
    if not x then return nil end
    for _, l in ipairs(layers) do
        if l.shown then
            for i = #l.regions, 1, -1 do
                local r = l.regions[i]
                if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                    if not want or r[want] then return r end
                end
            end
        end
    end
    return nil
end

M.region_at = region_at

function M.mouse_pos()
    local m = mp.get_property_native("mouse-pos")
    if not m or not m.x then return nil end
    return m.x, m.y, m.hover
end

-- 한 군데의 오류가 스크립트 전체를 죽이지 않도록 감싼다.
function M.guard(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then mp.msg.error(name .. ": " .. tostring(err)) end
    end
end

local function redraw(layer)
    if layer and layer.redraw then
        local ok, err = pcall(layer.redraw)
        if not ok then mp.msg.error(layer.name .. " 그리기 실패: " .. tostring(err)) end
    end
end

M.redraw = redraw

local function set_hover(id, layer)
    if id == hover_id then return end
    local prev = hover_id
    local prev_layer = nil
    for _, l in ipairs(layers) do
        if prev and prev:sub(1, #l.name + 1) == (l.name .. "/") then prev_layer = l end
    end
    hover_id = id
    if prev_layer then redraw(prev_layer) end
    if layer and layer ~= prev_layer then redraw(layer) end
end

-- ── 입력 ────────────────────────────────────────────────────────────
function M.on_mouse(fn)
    mouse_subs[#mouse_subs + 1] = fn
end

function M.click(event)
    -- 누름/뗌 정보가 없는 방식으로 불린 경우(예: script-message)는 한 번의 클릭으로 본다.
    if event ~= "down" and event ~= "up" then
        M.click("down")
        M.click("up")
        return
    end
    local x, y = M.mouse_pos()
    if not x then return end
    if event == "down" then
        local r = region_at(x, y)
        if not r then return end
        if r.drag or r.press then
            drag = { region = r, x0 = x, y0 = y, moved = false }
        end
        if r.press then r.press(x, y) end
    elseif event == "up" then
        local d = drag
        drag = nil
        if d then
            if d.region.drag_end then d.region.drag_end(d.moved, x, y) end
            if d.moved then return end
        end
        local r = region_at(x, y)
        if r and r.click then r.click(x, y) end
    end
end

-- 더블클릭도 여기서 받는다. UI 위가 아니면 원래 동작(재생/일시정지)으로 넘긴다.
function M.double_click()
    local x, y = M.mouse_pos()
    local r = region_at(x, y)
    if r and r.dbl then
        r.dbl(x, y)
        return true
    end
    return r ~= nil
end

function M.wheel(dir)
    local x, y = M.mouse_pos()
    local r = region_at(x, y, "scroll")
    if r then
        r.scroll(dir)
        return true
    end
    return false
end

-- ── 커서 ────────────────────────────────────────────────────────────
-- 패널이 열려 있는 동안에는 커서를 숨기지 않는다.
function M.hold_cursor(hold)
    if hold == cursor_held then return end
    cursor_held = hold
    if hold then
        cursor_saved = cursor_saved or mp.get_property("cursor-autohide") or "1000"
        mp.set_property("cursor-autohide", "no")
    else
        mp.set_property("cursor-autohide", cursor_saved or "1000")
    end
end

function M.init()
    build_theme()
    opts.on_change(function()
        build_theme()
        for _, l in ipairs(layers) do
            if l.shown then redraw(l) end
        end
    end)

    mp.observe_property("mouse-pos", "native", function(_, m)
        if not m or not m.x then return end
        local x, y = m.x, m.y
        if drag then
            if not drag.moved and (math.abs(x - drag.x0) > 3 or math.abs(y - drag.y0) > 3) then
                drag.moved = true
            end
            if drag.region.drag then drag.region.drag(x, y) end
            return
        end
        if m.hover == false then
            set_hover(nil, nil)
        else
            local r = region_at(x, y)
            set_hover(r and r.id or nil, r and r.layer or nil)
        end
        for _, fn in ipairs(mouse_subs) do
            local ok, err = pcall(fn, x, y, m.hover)
            if not ok then mp.msg.error("마우스 처리 실패: " .. tostring(err)) end
        end
    end)

    -- 창 크기가 바뀌면 모든 레이어를 다시 그린다.
    local function on_resize()
        for _, l in ipairs(layers) do
            if l.shown then redraw(l) end
        end
    end
    mp.observe_property("osd-width", "number", on_resize)
    mp.observe_property("osd-height", "number", on_resize)
end

return M
