-- Icons drawn with ASS shapes, so they never depend on an emoji font.
local M = {}

local function rect(x, y, w, h)
    return string.format("m %.1f %.1f l %.1f %.1f l %.1f %.1f l %.1f %.1f",
        x, y, x + w, y, x + w, y + h, x, y + h)
end

M.rect = rect

function M.play(s)
    return string.format("m 0 0 l 0 %.1f l %.1f %.1f", s, s * 0.88, s / 2)
end

function M.pause(s)
    return rect(s * 0.08, 0, s * 0.28, s) .. " " .. rect(s * 0.62, 0, s * 0.28, s)
end

function M.prev(s)
    return rect(0, 0, s * 0.16, s) .. " " ..
        string.format("m %.1f %.1f l %.1f 0 l %.1f %.1f", s * 0.24, s / 2, s, s, s)
end

function M.next(s)
    return rect(s * 0.84, 0, s * 0.16, s) .. " " ..
        string.format("m 0 0 l %.1f %.1f l 0 %.1f", s * 0.76, s / 2, s)
end

function M.fullscreen(s)
    local t = math.max(2, s * 0.15)
    local a = s * 0.4
    return table.concat({
        rect(0, 0, a, t), rect(0, 0, t, a),
        rect(s - a, 0, a, t), rect(s - t, 0, t, a),
        rect(0, s - t, a, t), rect(0, s - a, t, a),
        rect(s - a, s - t, a, t), rect(s - t, s - a, t, a),
    }, " ")
end

function M.list(s)
    local t = math.max(2, s * 0.16)
    return table.concat({
        rect(0, 0, s, t), rect(0, (s - t) / 2, s, t), rect(0, s - t, s, t),
    }, " ")
end

function M.speaker(s, muted)
    local body = string.format("m 0 %.1f l %.1f %.1f l %.1f 0 l %.1f %.1f l %.1f %.1f l 0 %.1f",
        s * 0.33, s * 0.28, s * 0.33, s * 0.6, s * 0.6, s, s * 0.28, s * 0.67, s * 0.67)
    if muted then
        local t = s * 0.1
        local d = string.format("m %.1f %.1f l %.1f %.1f l %.1f %.1f l %.1f %.1f",
            s * 0.72, s * 0.28, s * 0.72 + t, s * 0.28, s * 1.02, s * 0.72, s * 1.02 - t, s * 0.72)
        local d2 = string.format("m %.1f %.1f l %.1f %.1f l %.1f %.1f l %.1f %.1f",
            s * 1.02 - t, s * 0.28, s * 1.02, s * 0.28, s * 0.72 + t, s * 0.72, s * 0.72, s * 0.72)
        return body .. " " .. d .. " " .. d2
    end
    return body .. " " .. rect(s * 0.72, s * 0.3, s * 0.08, s * 0.4) ..
        " " .. rect(s * 0.88, s * 0.15, s * 0.08, s * 0.7)
end

function M.subtitle(s)
    local t = math.max(1.5, s * 0.1)
    local h = s * 0.74
    return table.concat({
        rect(0, 0, s, t), rect(0, h - t, s, t), rect(0, 0, t, h), rect(s - t, 0, t, h),
        rect(s * 0.18, h * 0.55, s * 0.26, t), rect(s * 0.54, h * 0.55, s * 0.28, t),
    }, " ")
end

return M
