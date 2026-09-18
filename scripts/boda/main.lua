-- boda — PotPlayer-style UI and keys for mpv (Windows)
--
-- Layout
--   lib/   shared: options, helpers, stored state, drawing + mouse input
--   mod/   features: history, skip points, actions, open dialogs, seek bar, panel, idle screen
--
-- The script never grabs keys itself. Everything is reached from input.conf as
-- `script-binding boda/<name>`, so every key stays yours to change.

local mp = require("mp")
local opts = require("lib.options")
local ui = require("lib.ui")
local state = require("lib.state")

state.init()
ui.init()

require("mod.history").init()
require("mod.skip").init()
require("mod.commands").init()
require("mod.dialogs").init()
require("mod.seekbar").init()
require("mod.panel").init()
require("mod.idle").init()
require("mod.menu").init()

-- Mouse input has exactly one entry point.
mp.add_key_binding(nil, "mouse-left", function(e)
    ui.click(e and e.event or "press")
end, { complex = true })

mp.add_key_binding(nil, "mouse-left-dbl", function()
    if not ui.double_click() then mp.command("cycle pause") end
end)

mp.add_key_binding(nil, "wheel-up", function()
    if not ui.wheel(1) then mp.commandv("add", "volume", opts.wheel_volume) end
end)

mp.add_key_binding(nil, "wheel-down", function()
    if not ui.wheel(-1) then mp.commandv("add", "volume", -opts.wheel_volume) end
end)

mp.msg.verbose("boda ready · state dir: " .. tostring(state.dir))
