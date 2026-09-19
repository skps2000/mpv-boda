-- The playlist: what its entries are called, and one thing mpv gets wrong about
-- opening a playlist file.
--
-- A title can reach an entry two ways, and only one of them is any use here: a
-- playlist file gives its entries names when it loads (an m3u EXTINF line),
-- while mpv fills the title in from the file's own metadata once the file has
-- been played. Going by whatever happens to be there renames a row the moment
-- you pick it, and moves it elsewhere under a name sort.
--
-- So the title an entry arrives with is remembered, and that is the one used
-- from then on. Entries that never had one are named after the file.

local mp = require("mp")
local util = require("lib.util")

local M = {}

-- entry id -> the name the playlist itself gave it, or false for none
local given = {}
local counted = -1

local function remember(pl)
    pl = pl or {}
    for _, e in ipairs(pl) do
        if e.id and given[e.id] == nil then given[e.id] = e.title or false end
    end
    if #pl < counted then -- entries were removed, forget the ones that left
        local live = {}
        for _, e in ipairs(pl) do
            if e.id then live[e.id] = true end
        end
        for id in pairs(given) do
            if not live[id] then given[id] = nil end
        end
    end
    counted = #pl
end

-- What to call an entry of the `playlist` property.
function M.name(entry)
    if type(entry) ~= "table" then return "" end
    local path = entry.filename or ""
    local title = entry.id and given[entry.id]
    if title then return title end
    -- No name of its own: the file on disk is what the eye is looking for, and
    -- a title is only any use where there is no filename to show (streams).
    if path ~= "" and not path:find("://", 1, true) then return util.basename(path) end
    return entry.title or util.basename(path)
end

-- Opening an .m3u: mpv builds a playlist out of the folder the file sits in,
-- and then expands the list on top of that, so every entry lands in the list
-- twice and only one copy carries the name the playlist gave it. There is
-- nothing to build a folder playlist around a playlist file, so turn that off
-- before playback starts.
local function keep_playlist_files_intact()
    if (mp.get_property_number("playlist-count") or 0) ~= 1 then return end
    if mp.get_property("autocreate-playlist") == "no" then return end
    local first = (mp.get_property("playlist/0/filename") or ""):lower()
    local ext = first:match("%.([%w]+)$")
    if not ext then return end
    for _, known in ipairs(mp.get_property_native("playlist-exts") or {}) do
        if ext == known:lower() then
            mp.set_property("autocreate-playlist", "no")
            mp.msg.verbose("opened a playlist file, not building one from its folder")
            return
        end
    end
end

function M.init()
    keep_playlist_files_intact()
    mp.observe_property("playlist", "native", function(_, pl) remember(pl) end)
end

return M
