# -*- coding: utf-8 -*-
"""Generate scripts/boda/lib/icons.lua from the Material Symbols SVGs in tools/mdi/.

    python tools/icons.py

To add an icon: drop its SVG in tools/mdi/ (Material Symbols, rounded, filled,
24px, from https://fonts.google.com/icons) and add a line to ICONS below.
"""
import io, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from svg2ass import convert

# boda name -> Material Symbols file
ICONS = [
    ("play", "play_arrow"), ("pause", "pause"),
    ("prev", "skip_previous"), ("next", "skip_next"),
    ("volume", "volume_up"), ("mute", "volume_off"),
    ("fullscreen", "fullscreen"), ("subtitle", "subtitles"),
    ("list", "format_list_bulleted"), ("color", "palette"),
    ("video", "movie"), ("audio", "graphic_eq"),
    ("chapter", "bookmark"), ("clip", "content_cut"),
    ("save", "save"), ("folder", "folder_open"),
    ("intro", "login"), ("outro", "logout"),
    ("record", "radio_button_checked"), ("loop", "repeat"),
    ("close", "close"), ("clear", "delete_sweep"),
    ("add", "add"), ("mark_a", "first_page"), ("mark_b", "last_page"),
    ("search", "search"), ("settings", "tune"),
]

head = '''-- Icons, drawn as ASS shapes so nothing depends on a font being installed.
--
-- The paths come from Google's Material Symbols (Apache-2.0, rounded, filled),
-- converted from SVG. They are written for a 24x24 box and scaled on use.
-- To change or add one: drop the .svg in tools/mdi/ and run tools/icons.py.

local M = {}

local function rect(x, y, w, h)
    return string.format("m %.1f %.1f l %.1f %.1f l %.1f %.1f l %.1f %.1f",
        x, y, x + w, y, x + w, y + h, x, y + h)
end

M.rect = rect

local PATHS = {
'''

tail = '''}

-- Scaling means rewriting every number in the path, so keep the results: the
-- same handful of icons is redrawn at the same few sizes over and over.
local cache = {}

local function scaled(name, size)
    local d = PATHS[name]
    if not d then return "" end
    size = math.floor((tonumber(size) or 16) * 4 + 0.5) / 4
    local key = name .. ":" .. size
    local hit = cache[key]
    if hit then return hit end
    local f = size / 24
    local out = d:gsub("%-?%d+%.?%d*", function(n)
        return string.format("%.2f", tonumber(n) * f)
    end)
    cache[key] = out
    return out
end

-- icons.play(16) and icons.get("play", 16) both work
function M.get(name, size) return scaled(name, size) end

for name in pairs(PATHS) do
    M[name] = function(size) return scaled(name, size) end
end

-- the one icon that depends on state
function M.speaker(size, muted)
    return scaled(muted and "mute" or "volume", size)
end

return M
'''

lines = []
for name, src in ICONS:
    path = os.path.join(HERE, "mdi", src + ".svg")
    d = convert(path)
    lines.append('    %s = "%s",' % (name, d))

out = head + "\n".join(lines) + "\n" + tail
target = sys.argv[1] if len(sys.argv) > 1 else "icons.lua"
io.open(target, "w", encoding="utf-8", newline="\n").write(out)
print("wrote %s (%d icons, %d bytes)" % (target, len(ICONS), len(out)))
