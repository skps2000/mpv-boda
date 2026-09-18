-- If a single local file is opened, append the rest of that folder.

local mp = require("mp")
local utils = require("mp.utils")

local EXT = {
    mkv=true, mp4=true, webm=true, avi=true, mov=true, m4v=true, ts=true,
    m2ts=true, wmv=true, flv=true, mpg=true, mpeg=true, ogv=true, m3u=true,
    m3u8=true
}

local busy = false

local function is_video(name)
    local e = name:lower():match("%.([a-z0-9]+)$")
    return e and EXT[e]
end

mp.register_event("start-file", function()
    if busy then return end
    local pl = mp.get_property_native("playlist") or {}
    if #pl ~= 1 then return end
    local path = mp.get_property("path")
    if not path or path:match("^https?://") or path:match("^edl://") then return end
    local dir, file = utils.split_path(path)
    if not dir or dir == "" then return end
    local ok, list = pcall(utils.readdir, dir, "files")
    if not ok or not list then return end
    local files = {}
    for _, n in ipairs(list) do
        if is_video(n) then files[#files + 1] = n end
    end
    table.sort(files, function(a, b) return a:lower() < b:lower() end)
    if #files < 2 then return end
    busy = true
    local prefix = dir
    if not prefix:match("[\\/]$") then prefix = prefix .. "\\" end
    for _, n in ipairs(files) do
        local full = prefix .. n
        if full:lower() ~= path:lower() then
            mp.commandv("loadfile", full, "append")
        end
    end
    busy = false
end)
