-- Disabled. In-window UI is scripts/player-ui.lua
-- Kill leftover external dock processes once.
local mp = require("mp")
mp.add_timeout(0.2, function()
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        detach = true,
        args = {
            "powershell.exe", "-NoProfile", "-WindowStyle", "Hidden", "-Command",
            "Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*playlist-dock.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
        }
    }, function() end)
end)
