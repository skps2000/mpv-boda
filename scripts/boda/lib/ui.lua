-- One place that owns every drawing layer and all mouse input.
-- The old setup had two scripts force-binding MBTN_LEFT at the same time, so
-- whichever armed last swallowed every click. Now there is a single entry point.
local mp = require("mp")
local util = require("lib.util")
local opts = require("lib.options")

local M = {}

local layers = {}     -- sorted by z, highest first (hit test order)
local mouse_subs = {}
local hover_id = nil
local drag = nil
local press_region = nil
local cursor_saved = nil
local cursor_held = false
local drag_allowed = nil -- the user's own window-dragging setting
local drag_now = nil

-- ── colours ───────────────────────────────────────────────────────
local function to_ass(rgb) -- #RRGGBB → BBGGRR, the order ASS wants
    rgb = tostring(rgb or ""):gsub("#", "")
    if #rgb ~= 6 or rgb:match("%X") then rgb = "FF0000" end
    return rgb:sub(5, 6) .. rgb:sub(3, 4) .. rgb:sub(1, 2)
end

M.theme = {}

-- How much width the side panel takes, so the seek bar can stay over the video.
M.reserved_right = 0

local function build_theme()
    M.theme = {
        bg = to_ass("0F0F0F"),
        bg2 = to_ass("212121"),
        hover = to_ass("3D3D3D"),
        line = to_ass("323232"),
        track = to_ass("717171"),
        text = to_ass("FFFFFF"),
        text2 = to_ass("E4E4E4"),
        mute = to_ass("9E9E9E"),
        accent = to_ass(opts.accent),
    }
end

-- ── sizing ────────────────────────────────────────────────────────
function M.osd_size()
    return mp.get_property_number("osd-width") or 0, mp.get_property_number("osd-height") or 0
end

-- Shrink gently so text stays readable in a small window; how many rows fit
-- is worked out by each screen itself.
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

-- ── layers ────────────────────────────────────────────────────────
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

-- Draw an icon with ASS shapes (no emoji font needed).
function Layer:draw(x, y, color, opacity, path)
    self:add(string.format("{\\an7\\pos(%.0f,%.0f)\\bord0\\shad0\\p1\\1c&H%s&\\1a&H%02X&}%s{\\p0}",
        x, y, color, 255 - (opacity or 255), path))
end

function Layer:text(x, y, size, color, align, s, opacity)
    self:add(string.format(
        "{\\an%d\\pos(%.0f,%.0f)\\fn%s\\fs%.0f\\b0\\bord0\\shad0\\1c&H%s&\\1a&H%02X&}%s",
        align or 7, x, y, opts.font, size, color, 255 - (opacity or 255), util.esc(s)))
end

-- Draw text cut to fit; returns what was actually drawn.
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

-- ── hit testing ───────────────────────────────────────────────────
-- With `want`, return the topmost region that has that handler
-- (so the wheel still scrolls the panel while hovering a row).
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

function M.hovered_id()
    return hover_id
end

function M.mouse_pos()
    local m = mp.get_property_native("mouse-pos")
    if not m or not m.x then return nil end
    return m.x, m.y, m.hover
end

-- Wrap a callback so one bad frame does not take the whole script down.
-- One bad draw must not take the whole script down, so errors are swallowed.
-- They are also counted and published, so the tests can fail on them instead of
-- a screen quietly going blank.
local errors = { count = 0, last = "" }

function M.failed(where, err)
    errors.count = errors.count + 1
    errors.last = where .. ": " .. tostring(err)
    mp.msg.error(errors.last)
    mp.set_property_native("user-data/boda/errors", errors)
end

function M.guard(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then M.failed(name, err) end
    end
end

local function redraw(layer)
    if layer and layer.redraw then
        local ok, err = pcall(layer.redraw)
        if not ok then M.failed(layer.name .. " draw failed", err) end
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

-- ── window dragging ───────────────────────────────────────────────
-- mpv moves the window when you press the left button over the video
-- (--window-dragging), so it has to be off over the UI or panel resizing and
local function set_window_dragging(allow)
    if drag_allowed == nil then
        drag_allowed = mp.get_property_bool("window-dragging")
        if drag_allowed == nil then drag_allowed = true end
    end
    if not drag_allowed then return end -- leave it alone if the user turned it off
    local want = allow and true or false
    if want == drag_now then return end
    drag_now = want
    mp.set_property_bool("window-dragging", want)
end

-- Re-check against the cursor position (after the panel opens or redraws).
function M.update_dragging()
    local x, y = M.mouse_pos()
    set_window_dragging(not (drag or (x and region_at(x, y))))
end

-- ── input ─────────────────────────────────────────────────────────
function M.on_mouse(fn)
    mouse_subs[#mouse_subs + 1] = fn
end

function M.click(event)
    -- Called without up/down information (a script-message, say): treat it as one click.
    if event ~= "down" and event ~= "up" then
        M.click("down")
        M.click("up")
        return
    end
    local x, y = M.mouse_pos()
    if not x then return end
    if event == "down" then
        local r = region_at(x, y)
        press_region = r
        if not r then
            set_window_dragging(true)
            return
        end
        set_window_dragging(false)
        if r.drag or r.press then
            drag = { region = r, x0 = x, y0 = y, moved = false }
        end
        if r.press then r.press(x, y) end
    elseif event == "up" then
        local d = drag
        local pressed = press_region
        drag, press_region = nil, nil
        if d then
            if d.region.drag_end then d.region.drag_end(d.moved, x, y) end
            if d.moved then
                M.update_dragging()
                return
            end
        end
        -- Only count it as a click when press and release land on the same region.
        local r = region_at(x, y)
        if r and r.click and (not pressed or pressed.id == r.id) then r.click(x, y) end
        M.update_dragging()
    end
end

-- Double clicks come here too; outside the UI they fall through to play/pause.
function M.double_click()
    local x, y = M.mouse_pos()
    local r = region_at(x, y)
    if r and r.dbl then
        r.dbl(x, y)
        return true
    end
    return r ~= nil
end

local update_hover -- filled in by init below

function M.wheel(dir)
    local x, y = M.mouse_pos()
    local r = region_at(x, y, "scroll")
    if r then
        r.scroll(dir)
        -- The list moved under the cursor, so work out the highlight again.
        if update_hover then update_hover(x, y, true) end
        return true
    end
    return false
end

-- ── cursor ────────────────────────────────────────────────────────
-- Keep the cursor visible while a panel is open.
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

    update_hover = function(x, y, inside)
        if inside == false then
            set_hover(nil, nil)
            set_window_dragging(true)
            return
        end
        local r = region_at(x, y)
        set_hover(r and r.id or nil, r and r.layer or nil)
        set_window_dragging(not r)
    end

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
        update_hover(x, y, m.hover)
        for _, fn in ipairs(mouse_subs) do
            local ok, err = pcall(fn, x, y, m.hover)
            if not ok then mp.msg.error("mouse handler failed: " .. tostring(err)) end
        end
    end)

    -- Redraw every layer when the window size changes.
    local function on_resize()
        for _, l in ipairs(layers) do
            if l.shown then redraw(l) end
        end
    end
    mp.observe_property("osd-width", "number", on_resize)
    mp.observe_property("osd-height", "number", on_resize)
end

return M
