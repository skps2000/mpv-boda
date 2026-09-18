-- 기록/설정 저장. 설정 폴더가 아니라 mpv 상태 폴더(~~state)에 둔다.
-- 설정 폴더는 그대로 공개(저장소)할 수 있어야 하고, 시청 기록은 개인 정보다.
local mp = require("mp")
local util = require("lib.util")
local opts = require("lib.options")

local M = {
    history = {},   -- { {path=, pos=, dur=, seen=}, ... } 최근 순
    bookmarks = {}, -- path -> { 초, ... }
    skips = {},     -- path -> {intro=, outro=}
    recent = {},    -- 최근 폴더
    prefs = {},     -- 패널 너비, 정렬, 색보정 자동 여부
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
        skips = dir .. "/skips.json",
        prefs = dir .. "/prefs.json",
    }

    M.history = util.read_json(files.history) or {}
    M.bookmarks = util.read_json(files.bookmarks) or {}
    M.skips = util.read_json(files.skips) or {}

    local p = util.read_json(files.prefs) or {}
    M.recent = p.recent or {}
    M.prefs = {
        panel_w = tonumber(p.panel_w) or opts.panel_width,
        sort = p.sort or "none",
        sort_desc = p.sort_desc == true,
        auto_color = p.auto_color,
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
    if dirty.skips then util.write_json(files.skips, M.skips) end
    if dirty.prefs then
        util.write_json(files.prefs, {
            recent = M.recent,
            panel_w = M.prefs.panel_w,
            sort = M.prefs.sort,
            sort_desc = M.prefs.sort_desc,
            auto_color = M.prefs.auto_color,
        })
    end
    dirty = {}
end

function M.remember_folder(path)
    local dir = (not util.is_url(path)) and util.dirname(path) or nil
    if not dir then return end
    local out = { dir }
    for _, p in ipairs(M.recent) do
        if p:lower() ~= dir:lower() and #out < 12 then out[#out + 1] = p end
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
        M.bookmarks[path] = nil -- 빈 항목까지 남기면 파일이 계속 커진다
    else
        M.bookmarks[path] = list
    end
    M.mark("bookmarks")
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
