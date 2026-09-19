-- Shared helpers: ASS escaping, text width, time and path formatting, JSON files.
local mp = require("mp")
local utils = require("mp.utils")

local M = {}

function M.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function M.round(v)
    return math.floor((tonumber(v) or 0) + 0.5)
end

-- ── ASS escaping ──────────────────────────────────────────────────
-- libass reads sequences like \N \h \{ , so a raw "D:\New" turns into a line break.
-- This does what mpv's escape-ass command does, but inside Lua:
-- calling the command means a round trip to the mpv core per string, which cost
-- 0.7 s just to draw 40 playlist rows the first time.
local esc_cache, esc_count = {}, 0

function M.esc(s)
    s = tostring(s or "")
    local cached = esc_cache[s]
    if cached then return cached end
    -- put U+2060 after a backslash so \N and friends stop being sequences
    local out = s:gsub("\\", "\\\226\129\160")
    out = out:gsub("([{}])", "\\%1")
    if esc_count > 2000 then
        esc_cache, esc_count = {}, 0
    end
    esc_cache[s] = out
    esc_count = esc_count + 1
    return out
end

-- ── text width ────────────────────────────────────────────────────
-- Asking libass for the real width needs a separate overlay pass, so estimate it.
function M.codepoints(s)
    local i, n = 1, #s
    return function()
        if i > n then return nil end
        local c = s:byte(i)
        local len = 1
        if c >= 0xF0 then len = 4
        elseif c >= 0xE0 then len = 3
        elseif c >= 0xC0 then len = 2 end
        local cp = c
        if len == 2 then cp = c - 0xC0
        elseif len == 3 then cp = c - 0xE0
        elseif len == 4 then cp = c - 0xF0 end
        for k = 1, len - 1 do
            cp = cp * 64 + ((s:byte(i + k) or 0) % 64)
        end
        i = i + len
        return cp, len
    end
end

local function em(cp)
    if cp >= 0x1100 then
        if (cp >= 0x1100 and cp <= 0x115F)
            or (cp >= 0x2E80 and cp <= 0xA4CF)
            or (cp >= 0xAC00 and cp <= 0xD7A3)
            or (cp >= 0xF900 and cp <= 0xFAFF)
            or (cp >= 0xFE30 and cp <= 0xFE6F)
            or (cp >= 0xFF00 and cp <= 0xFF60)
            or (cp >= 0xFFE0 and cp <= 0xFFE6)
            or cp >= 0x20000 then
            return 1.0 -- Hangul, Han, full width
        end
        return 0.62
    end
    if cp == 32 then return 0.3 end
    if cp >= 0x30 and cp <= 0x39 then return 0.56 end
    return 0.53
end

function M.text_width(s, size)
    local w = 0
    for cp in M.codepoints(tostring(s or "")) do
        w = w + em(cp) * size
    end
    return w
end

-- Cut to width and add an ellipsis so text never spills out of a small window.
function M.truncate(s, size, max_w)
    s = tostring(s or "")
    if max_w <= 0 then return "" end
    if M.text_width(s, size) <= max_w then return s end
    local budget = max_w - size
    if budget <= 0 then return "…" end
    local out, w, pos = {}, 0, 1
    for cp, len in M.codepoints(s) do
        local cw = em(cp) * size
        if w + cw > budget then break end
        w = w + cw
        out[#out + 1] = s:sub(pos, pos + len - 1)
        pos = pos + len
    end
    return table.concat(out) .. "…"
end

-- ── time and paths ────────────────────────────────────────────────
function M.fmt_time(t)
    t = math.max(0, math.floor(tonumber(t) or 0))
    local s, m, h = t % 60, math.floor(t / 60) % 60, math.floor(t / 3600)
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

function M.fmt_size(bytes)
    bytes = tonumber(bytes) or 0
    if bytes <= 0 then return "" end
    local units = { "B", "KB", "MB", "GB", "TB" }
    local i = 1
    while bytes >= 1024 and i < #units do
        bytes = bytes / 1024
        i = i + 1
    end
    if i <= 2 then return string.format("%d%s", bytes, units[i]) end
    return string.format("%.1f%s", bytes, units[i])
end

function M.basename(path)
    if not path or path == "" then return "" end
    local _, file = utils.split_path(path)
    return (file and file ~= "") and file or path
end

function M.dirname(path)
    if not path or path == "" then return nil end
    local dir = utils.split_path(path)
    if not dir or dir == "" then return nil end
    return (dir:gsub("[\\/]+$", ""))
end

function M.is_url(path)
    return (tostring(path or "")):match("^%a[%w+%-.]*://") ~= nil
end

function M.exists(path)
    return path ~= nil and path ~= "" and utils.file_info(path) ~= nil
end

-- Compare digits as numbers so "ep2" sorts before "ep10".
function M.natural_less(a, b)
    a, b = tostring(a or ""):lower(), tostring(b or ""):lower()
    local ai, bi = 1, 1
    while true do
        local ad, bd = a:match("^%d+", ai), b:match("^%d+", bi)
        if ad and bd then
            local an, bn = tonumber(ad), tonumber(bd)
            if an ~= bn then return an < bn end
            ai, bi = ai + #ad, bi + #bd
        else
            local ac, bc = a:sub(ai, ai), b:sub(bi, bi)
            if ac == "" or bc == "" then return #a < #b end
            if ac ~= bc then return ac < bc end
            ai, bi = ai + 1, bi + 1
        end
        if ai > #a or bi > #b then return #a - ai < #b - bi end
    end
end

-- ── JSON files ────────────────────────────────────────────────────
function M.read_json(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    if not body or body == "" then return nil end
    local ok, value = pcall(utils.parse_json, body)
    if not ok or type(value) ~= "table" then return nil end
    return value
end

function M.write_json(path, value)
    local ok, body = pcall(utils.format_json, value)
    if not ok or type(body) ~= "string" then return false end
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(body)
    f:close()
    os.remove(path)
    if os.rename(tmp, path) then return true end
    local g = io.open(path, "wb")
    if not g then return false end
    g:write(body)
    g:close()
    os.remove(tmp)
    return true
end

function M.ensure_dir(dir)
    if not dir or dir == "" or M.exists(dir) then return end
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        args = { "cmd", "/c", "mkdir", (dir:gsub("/", "\\")) },
    }, function() end)
end

return M
