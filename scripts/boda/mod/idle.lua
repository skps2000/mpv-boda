-- The "continue watching" screen shown when nothing is playing.
-- Only the rows that fit are drawn, the rest scrolls, and titles are cut to width.
local mp = require("mp")
local util = require("lib.util")
local ui = require("lib.ui")
local icons = require("lib.icons")
local state = require("lib.state")
local t = require("lib.i18n").t

local M = {}

local layer
local active = false
local scroll = 0
local visible_items = {} -- entries the number keys can open

local function play(path)
    mp.commandv("loadfile", path, "replace")
    mp.set_property_bool("pause", false)
end

-- Build the rows first: their heights decide how many fit on screen.
-- Folders come first: picking up a folder you were working through is the more
-- common way back in than a single file.
local function build(s)
    local items = {}
    if #(state.recent or {}) > 0 then
        items[#items + 1] = { kind = "header", text = t("idle_recent_folders"),
            clear = "recent-clear", h = 34 * s }
        for _, dir in ipairs(state.recent) do
            items[#items + 1] = { kind = "folder", path = dir, h = 32 * s }
        end
    end
    local history = state.history or {}
    if #history > 0 then
        items[#items + 1] = { kind = "header", text = t("idle_recent_videos"),
            clear = "history-clear", h = 34 * s }
        for _, h in ipairs(history) do
            if h.path then
                items[#items + 1] = { kind = "video", entry = h, h = 56 * s }
            end
        end
    end
    return items
end

-- Clearing a list takes two clicks: the button asks first, and forgets it was
-- asked after a few seconds.
local armed, armed_until = nil, 0
local function arming(which)
    return armed == which and mp.get_time() < armed_until
end

-- What the tests read: whether the screen is up, how much of it was drawn, and
-- where the clear buttons ended up.
local buttons = {}

local function publish(rows, shown, max_scroll)
    mp.set_property_native("user-data/boda/idle", {
        active = active, rows = rows or 0, shown = shown or 0,
        scroll = scroll, max_scroll = max_scroll or 0, buttons = buttons,
    })
end

local draw -- wrapped with ui.guard below
local function draw_impl()
    if not active or not ui.ready() then
        layer:hide()
        publish(0, 0, 0)
        return
    end
    local ow, oh, s = layer:start()
    local th = ui.theme

    layer:rect(0, 0, ow, oh, th.bg, 255)

    local pad = math.max(18 * s, math.min(ow * 0.06, 56 * s))
    local title_size = math.min(28 * s, oh * 0.06)
    layer:text_fit(pad, pad * 0.7, title_size, th.text, 7, t("idle_title"), ow - pad * 2)

    local hint_y = pad * 0.7 + title_size + 6 * s
    layer:text_fit(pad, hint_y, 12 * s, th.mute, 7, t("idle_hint"), ow - pad * 2)

    local top = hint_y + 26 * s
    local bottom = oh - 10 * s
    local avail = bottom - top
    local card_w = math.min(780 * s, ow - pad * 2)

    local items = build(s)
    visible_items = {}
    buttons = {}

    if #items == 0 then
        layer:text_fit(pad, top + 10 * s, 14 * s, th.mute, 7, t("idle_empty"), ow - pad * 2)
        layer:flush()
        publish(0, 0, 0)
        return
    end

    -- Scroll range, clamped so the last row lands at the bottom.
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

    -- Registered before the cards so it sits underneath: cards take clicks, this takes the wheel.
    layer:hit(0, top, ow, bottom - top, {
        id = "surface",
        scroll = function(dir)
            scroll = util.clamp(scroll - dir, 0, max_scroll)
            draw()
        end,
    })

    local y = top
    local digit = 0
    local shown = 0
    for i = scroll + 1, #items do
        local it = items[i]
        if y + it.h > bottom then break end
        shown = shown + 1

        if it.kind == "header" then
            local label_w = card_w
            if it.clear then
                local asking = arming(it.clear)
                local label = asking and t("idle_confirm") or t("idle_clear")
                local bw = util.text_width(label, 12 * s) + 34 * s
                local bx = pad + card_w - bw
                local id = "clear" .. it.clear
                local hot = layer:hovered(id)
                layer:rect(bx, y + it.h - 26 * s, bw, 22 * s,
                    asking and th.accent or (hot and th.hover or th.bg2), asking and 220 or 150)
                local fg = (asking or hot) and th.text or th.mute
                layer:icon(bx + 13 * s, y + it.h - 15 * s, 13 * s, fg,
                    asking and ui.alpha.icon_hot or ui.alpha.icon, icons.get("clear", 13 * s))
                layer:text(bx + bw / 2 + 7 * s, y + it.h - 23 * s, 12 * s, fg, 8, label)
                local target = it.clear
                buttons[target] = { x = bx + bw / 2, y = y + it.h - 15 * s,
                    w = bw, h = 26 * s, asking = asking }
                layer:hit(bx, y + it.h - 28 * s, bw, 26 * s, {
                    id = id,
                    click = function()
                        if arming(target) then
                            armed = nil
                            mp.commandv("script-message", "boda-" .. target)
                        else
                            armed, armed_until = target, mp.get_time() + 4
                            mp.add_timeout(4.1, function()
                                if not arming(target) then
                                    armed = nil
                                    draw()
                                end
                            end)
                        end
                        draw()
                    end,
                })
                label_w = card_w - bw - 10 * s
            end
            layer:text_fit(pad, y + it.h - 18 * s, 12 * s, th.mute, 7, it.text, label_w)
        elseif it.kind == "video" then
            local h = it.entry
            local id = "v" .. i
            local hot = layer:hovered(id)
            local pct = (h.dur and h.dur > 0) and util.clamp((h.pos or 0) / h.dur * 100, 0, 100) or 0
            local done = pct >= 92
            local card_h = it.h - 6 * s
            layer:rect(pad, y, card_w, card_h, hot and th.hover or th.bg2, hot and 210 or 150)

            digit = digit + 1
            local num_w = 0
            if digit <= 9 then
                num_w = 22 * s
                layer:text(pad + 12 * s, y + 9 * s, 12 * s, th.mute, 7, tostring(digit))
                visible_items[digit] = h.path
            end

            local right = (h.dur and h.dur > 0) and
                (done and t("idle_watched") or (util.fmt_time(h.pos or 0) .. " / " .. util.fmt_time(h.dur))) or ""
            local right_w = util.text_width(right, 11.5 * s) + 14 * s
            layer:text_fit(pad + 12 * s + num_w, y + 8 * s, 14 * s, done and th.mute or th.text, 7,
                util.basename(h.path), card_w - 24 * s - num_w - right_w)
            layer:text(pad + card_w - 12 * s, y + 9 * s, 11.5 * s, th.mute, 9, right)

            local bar_y = y + card_h - 12 * s
            layer:rect(pad + 12 * s, bar_y, card_w - 24 * s, 3 * s, th.track, 160)
            layer:rect(pad + 12 * s, bar_y, math.max(2, (card_w - 24 * s) * pct / 100), 3 * s,
                done and th.mute or th.accent, 255)

            local target = h.path
            layer:hit(pad, y, card_w, card_h, { id = id, click = function() play(target) end })
        else
            local id = "f" .. i
            local hot = layer:hovered(id)
            layer:rect(pad, y, card_w, it.h - 4 * s, hot and th.hover or th.bg2, hot and 200 or 110)
            layer:text_fit(pad + 12 * s, y + 7 * s, 12.5 * s, hot and th.text or th.mute, 7,
                it.path, card_w - 24 * s)
            local target = it.path
            layer:hit(pad, y, card_w, it.h - 4 * s, { id = id, click = function() play(target) end })
        end
        y = y + it.h
    end

    if max_scroll > 0 then
        local kh = math.max(24 * s, avail * (avail / total))
        local ky = top + (avail - kh) * (scroll / max_scroll)
        layer:rect(ow - 6 * s, ky, 3 * s, kh, th.mute, 150)
        layer:text(ow - pad, bottom - 16 * s, 11 * s, th.mute, 9, t("idle_scroll"))
    end

    layer:flush()
    publish(#items, shown, max_scroll)
end

draw = ui.guard("idle screen", draw_impl)
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
    mp.register_script_message("boda-refresh", function() draw() end)
    mp.register_event("end-file", function() mp.add_timeout(0.05, update) end)
    mp.register_event("file-loaded", update)

    -- Number keys: open a recent file on the idle screen, seek by percent while playing.
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
