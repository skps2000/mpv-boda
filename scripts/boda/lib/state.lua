-- History and preferences. They live in mpv's state dir (~~state), not in the
-- config dir, so the config dir stays safe to publish while what you watched stays private.
local mp = require("mp")
local util = require("lib.util")
local opts = require("lib.options")

local M = {
    history = {},   -- { {path=, pos=, dur=, seen=}, ... } newest first
    bookmarks = {}, -- path -> { seconds, ... }
    favorites = {}, -- path -> { {a=start, b=end, name=label}, ... }
    skips = {},     -- path -> {intro=, outro=}
    recent = {},    -- recently opened folders
    prefs = {},     -- panel width, sorting, auto colour
}

local files = {}
local dirty = {}

function M.init()
    local dir = opts.state_dir
    if dir == "" then dir = mp.command_native({ "expand-path", "~~state/boda" }) end
    dir = tostring(dir):gsub("[\\/]+$", "")
    M.dir = dir
    util.ensure_dir(dir)

    files = {
        history = dir .. "/history.json",
        bookmarks = dir .. "/bookmarks.json",
        favorites = dir .. "/favorites.json",
        skips = dir .. "/skips.json",
        prefs = dir .. "/prefs.json",
    }

    M.history = util.read_json(files.history) or {}
    M.bookmarks = util.read_json(files.bookmarks) or {}
    M.favorites = util.read_json(files.favorites) or {}
    M.skips = util.read_json(files.skips) or {}

    local p = util.read_json(files.prefs) or {}
    M.recent = p.recent or {}
    M.prefs = {
        panel_w = tonumber(p.panel_w) or opts.panel_width,
        sort = p.sort or "none",
        sort_desc = p.sort_desc == true,
        auto_color = p.auto_color,
    }
    -- seek steps: the setting file is the default, the menu overrides it
    local seek = p.seek or {}
    M.prefs.seek = {
        arrow = tonumber(seek.arrow) or opts.seek_arrow,
        ctrl = tonumber(seek.ctrl) or opts.seek_ctrl,
        shift = tonumber(seek.shift) or opts.seek_shift,
        alt = tonumber(seek.alt) or opts.seek_alt,
    }
    if M.prefs.auto_color == nil then M.prefs.auto_color = opts.auto_color end

    mp.register_event("shutdown", M.flush)
    mp.add_periodic_timer(15, function() M.flush() end)
end

function M.mark(kind)
    dirty[kind] = true
end

function M.flush()
    if not files.prefs then return end
    if dirty.history then util.write_json(files.history, M.history) end
    if dirty.bookmarks then util.write_json(files.bookmarks, M.bookmarks) end
    if dirty.favorites then util.write_json(files.favorites, M.favorites) end
    if dirty.skips then util.write_json(files.skips, M.skips) end
    if dirty.prefs then
        util.write_json(files.prefs, {
            recent = M.recent,
            panel_w = M.prefs.panel_w,
            sort = M.prefs.sort,
            sort_desc = M.prefs.sort_desc,
            auto_color = M.prefs.auto_color,
            seek = M.prefs.seek,
        })
    end
    dirty = {}
end

-- Move a folder to the front of the recent list.
function M.remember_folder(dir)
    if not dir or dir == "" or util.is_url(dir) then return end
    dir = dir:gsub("[\\/]+$", "")
    if dir == "" then return end
    local out = { dir }
    for _, p in ipairs(M.recent) do
        if p:lower() ~= dir:lower() and #out < 12 then out[#out + 1] = p end
    end
    M.recent = out
    M.mark("prefs")
end

-- Drop a folder that is no longer there.
function M.forget_folder(dir)
    if not dir then return end
    local out = {}
    for _, p in ipairs(M.recent) do
        if p:lower() ~= dir:lower() then out[#out + 1] = p end
    end
    M.recent = out
    M.mark("prefs")
end

function M.bookmarks_of(path)
    if not path then return {} end
    local list = M.bookmarks[path]
    if type(list) ~= "table" then return {} end
    return list
end

function M.set_bookmarks(path, list)
    if not path then return end
    if #list == 0 then
        M.bookmarks[path] = nil -- keeping empty entries would grow the file forever
    else
        M.bookmarks[path] = list
    end
    M.mark("bookmarks")
end

-- Saved clips: {a, b, name} per file
function M.favorites_of(path)
    if not path then return {} end
    local list = M.favorites[path]
    if type(list) ~= "table" then return {} end
    return list
end

function M.set_favorites(path, list)
    if not path then return end
    if #list == 0 then
        M.favorites[path] = nil
    else
        M.favorites[path] = list
    end
    M.mark("favorites")
end

function M.skip_of(path)
    if not path then return nil end
    local s = M.skips[path]
    if type(s) ~= "table" then return nil end
    return s
end

function M.set_skip(path, intro, outro)
    if not path then return end
    if (intro or 0) <= 0 and (outro or 0) <= 0 then
        M.skips[path] = nil
    else
        M.skips[path] = { intro = intro or 0, outro = outro or 0 }
    end
    M.mark("skips")
end

return M
