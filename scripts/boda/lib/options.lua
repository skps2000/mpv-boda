-- User settings. Change them in script-opts/boda.conf or with --script-opts=boda-key=value.
local mp = require("mp")
local options = require("mp.options")

local M = {
    -- language of the UI: en or ko
    language = "en",
    -- looks
    font = "Segoe UI",        -- UI font (Windows falls back for glyphs it lacks)
    scale = 0,                -- 0 = follow the window height
    accent = "FF0000",        -- accent colour, #RRGGBB
    -- behaviour
    auto_color = false,       -- nudge brightness/contrast per file
    resume = true,            -- continue where you left off
    thumbnails = true,        -- seek bar previews (needs ffmpeg)
    ffmpeg = "",              -- path to ffmpeg (empty = look it up)
    wheel_volume = 5,         -- volume step for one wheel notch
    -- how far the arrow keys seek, in seconds (the menu can change these too)
    seek_arrow = 8,           -- ← →
    seek_ctrl = 30,           -- Ctrl + ← →
    seek_shift = 100,         -- Shift + ← →
    seek_alt = 300,           -- Ctrl + Alt + ← →
    history_size = 60,        -- how many files to remember
    panel_width = 360,        -- default panel width in px
    state_dir = "",           -- where to keep history (empty = mpv state dir)
    menu_sections = "",       -- context menu layout (empty = default order)
}

local subscribers = {}

function M.on_change(fn)
    subscribers[#subscribers + 1] = fn
end

options.read_options(M, "boda", function()
    for _, fn in ipairs(subscribers) do
        local ok, err = pcall(fn)
        if not ok then mp.msg.error("option update failed: " .. tostring(err)) end
    end
end)

return M
