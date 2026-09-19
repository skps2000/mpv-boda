-- boda context menu tests
--
-- Showing the menu for real (context-menu) blocks until someone dismisses it,
-- so these tests stop at building the tree and publishing it.
--
--   mpv --script=tests/menu.lua --script-opts=boda-state_dir=<tmp> <file>
--
-- To cover the layout setting as well (commas need %length% quoting):
--   --script-opts=boda-state_dir=<tmp>,boda-menu_sections=%19%open,fav,-,settings

local mp = require("mp")

local pass, fail = 0, 0
local queue, qi = {}, 0
local saved = {}

local function log(s) mp.msg.warn("T " .. s) end

local function check(name, ok, detail)
    if ok then
        pass = pass + 1
        log("PASS  " .. name)
    else
        fail = fail + 1
        log(string.format("FAIL  %s  (%s)", name, tostring(detail or "")))
    end
end

local function step(d, fn) queue[#queue + 1] = { d = d, fn = fn } end

local function run_next()
    qi = qi + 1
    local s = queue[qi]
    if not s then
        log(string.format("RESULT %d pass / %d fail", pass, fail))
        mp.commandv("quit", fail == 0 and 0 or 1)
        return
    end
    local ok, err = pcall(s.fn)
    if not ok then
        fail = fail + 1
        log("FAIL  step " .. qi .. " raised: " .. tostring(err))
    end
    mp.add_timeout(s.d, run_next)
end

local function build(which)
    mp.commandv("script-message", "boda-menu-build", which or "main")
end

local function meta() return mp.get_property_native("user-data/boda/menu") or {} end
-- mpv's own menu may overwrite menu-data, so read the tree boda publishes
local function tree() return meta().tree or {} end

-- find an entry by title, submenus included
-- the extensions mpv counts as video, so the playlist can be checked against them
local video_ext = {}
for _, e in ipairs(mp.get_property_native("video-exts") or {}) do video_ext[e:lower()] = true end

local function basename(path)
    return tostring(path):match("[^/\\]+$") or tostring(path)
end

local function find(items, title)
    for _, it in ipairs(items or {}) do
        if it.title == title then return it end
        if it.submenu then
            local hit = find(it.submenu, title)
            if hit then return hit end
        end
    end
    return nil
end

-- every "play this row" entry in the tree, keyed by its command so the reading
-- survives the menu showing a different window of the playlist
local function playlist_titles()
    local out = {}
    local function walk(items)
        for _, it in ipairs(items or {}) do
            if it.cmd and it.cmd:find("playlist%-play%-index") and it.title then
                out[it.cmd] = it.title
            end
            if it.submenu then walk(it.submenu) end
        end
    end
    walk(tree())
    return out
end

local function has_state(it, want)
    for _, s in ipairs((it or {}).state or {}) do
        if s == want then return true end
    end
    return false
end

local function titles(items)
    local out = {}
    for _, it in ipairs(items or {}) do
        if it.title then out[#out + 1] = it.title end
    end
    return out
end

local function count_all(items)
    local n = 0
    for _, it in ipairs(items or {}) do
        n = n + 1
        if it.submenu then n = n + count_all(it.submenu) end
    end
    return n
end

-- walk the tree looking for empty commands and empty submenus
local function validate(items, path, problems)
    for _, it in ipairs(items or {}) do
        local where = (path or "") .. "/" .. tostring(it.title or it.type)
        if it.type == "submenu" then
            if #(it.submenu or {}) == 0 then problems[#problems + 1] = where .. " (empty submenu)" end
            validate(it.submenu, where, problems)
        elseif it.type ~= "separator" then -- nothing to check on a separator
            local disabled = has_state(it, "disabled")
            if (not it.cmd or it.cmd == "") and not disabled then
                problems[#problems + 1] = where .. " (no command)"
            end
        end
    end
end

-- Short test clips would otherwise roll over to the next file mid-run, changing
-- the playlist position the menu is built around.
step(0.2, function() mp.set_property("loop-file", "inf") end)

-- ── stage 1: the tree and its state ─────────────────────────────────
step(0.8, function()
    log("[stage 1] menu tree")
    mp.set_property_bool("pause", false)
    build("main")
end)

step(0.6, function()
    saved.custom = (mp.get_opt("boda-menu_sections") or "") ~= ""
    local t = tree()
    saved.total = count_all(t)
    check("a menu is built", #t > 8, #t .. " top level entries")
    check("it reports what it built", meta().kind == "main", tostring(meta().kind))
    if not saved.custom then
        check("it has enough entries", saved.total > 80, saved.total .. " in total")
        local want = { "Open", "Playlist", "Clips", "Chapters · Bookmarks", "Speed", "Loop range",
            "Skip", "Video", "Audio", "Subtitles", "Color", "Window", "Capture · Record", "Copy",
            "Panel", "Settings · About" }
        local missing = {}
        for _, name in ipairs(want) do
            if not find(t, name) then missing[#missing + 1] = name end
        end
        check("every group is there", #missing == 0, table.concat(missing, ", "))
    end

    local problems = {}
    validate(t, "", problems)
    check("no empty commands or submenus", #problems == 0, table.concat(problems, " | "))

    -- only videos belong in the playlist: no music, images or playlist files
    local wrong = {}
    for _, e in ipairs(mp.get_property_native("playlist") or {}) do
        local ext = (e.filename or ""):lower():match("%.([%w]+)$")
        if ext and not video_ext[ext] then wrong[#wrong + 1] = basename(e.filename) end
    end
    check("the playlist holds video files only", #wrong == 0, table.concat(wrong, " | "))
end)

-- A row must not rename itself when it is played: mpv fills an entry's title in
-- from the file's own metadata, and a list that renames itself as you watch is
-- unreadable. Names a playlist file gave its entries have to survive too.
step(0.3, function() build("main") end)

step(0.5, function()
    saved.names = playlist_titles()
    saved.named = 0
    -- play the last row the menu is showing: the earlier stages may already have
    -- played the ones near the top, and a row only renames itself once played
    local last = -1
    for cmd in pairs(saved.names) do
        saved.named = saved.named + 1
        local i = tonumber(cmd:match("(%d+)%s*$"))
        if i and i > last then last = i end
    end
    if last >= 0 then mp.commandv("playlist-play-index", last) end
end)

step(1.4, function() build("main") end)

step(0.6, function()
    local now = playlist_titles()
    local changed = {}
    for cmd, was in pairs(saved.names) do
        if now[cmd] and now[cmd] ~= was then
            changed[#changed + 1] = was .. " -> " .. now[cmd]
        end
    end
    check("a row keeps its name once it has been played", saved.named > 1 and #changed == 0,
        string.format("%d rows, changed: %s", saved.named, table.concat(changed, " | ")))
end)

-- do check marks and disabled entries match reality
step(0.3, function()
    mp.set_property_bool("pause", true)
    build("main")
end)

step(0.5, function()
    check("paused, the first entry is Play", titles(tree())[1] == "Play", titles(tree())[1])
    mp.set_property_bool("pause", false)
    mp.set_property_number("speed", 1.5)
    mp.set_property_bool("mute", true)
    build("main")
end)

step(0.5, function()
    local t = tree()
    check("playing, the first entry is Pause", titles(t)[1] == "Pause", titles(t)[1])
    if not saved.custom then
        check("the current speed is checked", has_state(find(t, "1.50x"), "checked"))
        check("mute shows as checked", has_state(find(t, "Mute"), "checked"))
    end
    mp.set_property_number("speed", 1)
    mp.set_property_bool("mute", false)
end)

step(0.3, function()
    mp.commandv("script-message", "boda-blur") -- switch one filter on
end)

step(0.6, function()
    build("main")
end)

step(0.6, function()
    if not saved.custom then
        check("a filter that is on shows as checked", has_state(find(tree(), "Blur"), "checked"),
            "vf=" .. tostring(mp.get_property("vf")))
    end
    mp.commandv("script-message", "boda-blur") -- and off again
end)

-- ── stage 2: menus per context ──────────────────────────────────────
step(0.6, function()
    log("[stage 2] context menus")
    build("auto")
end)

step(0.5, function()
    check("over the video it is the main menu", meta().kind == "main", tostring(meta().kind))
    mp.commandv("script-message", "boda-panel", "pl")
end)

step(0.8, function()
    -- move the cursor over one of the rows
    local n = mp.get_property_native("user-data/boda/panel") or {}
    saved.row_index = (n.scroll or 0) + 2
    mp.commandv("mouse", math.floor(n.x0 + 40), math.floor(n.top + 1.5 * n.row_h))
end)

step(0.6, function()
    build("auto")
end)

step(0.6, function()
    local t = tree()
    check("over a row it is that row menu", meta().kind == "playlist", tostring(meta().kind))
    saved.playlist_menu_seen = meta().kind == "playlist"
    check("play and remove are there", find(t, "Play") ~= nil and find(t, "Remove from playlist") ~= nil)
    check("sorting is offered", find(t, "Sort") ~= nil)
    check("it is shorter than the main menu", count_all(t) < saved.total,
        count_all(t) .. " vs " .. saved.total)
    build("auto-key") -- cursor still over the row, but opened with a key
end)

step(0.6, function()
    check("opened with F4 it is the main menu anyway",
        meta().kind == "main", tostring(meta().kind))
    mp.commandv("script-message", "boda-panel", "toggle")
    mp.commandv("mouse", 60, 200) -- back over the video
end)

step(0.6, function()
    build("auto")
    saved.was_playing = true
end)

step(0.5, function()
    check("with the panel closed it is the main menu", meta().kind == "main", tostring(meta().kind))
    mp.command("stop")
end)

step(1.2, function()
    build("auto")
end)

step(0.6, function()
    local t = tree()
    check("with no file it is the idle menu", meta().kind == "idle", tostring(meta().kind))
    check("opening comes first", titles(t)[1] == "Open file…", tostring(titles(t)[1]))
    check("the idle menu is short", #t < 12, #t .. " top level entries")
end)

-- ── stage 3: layout setting and fallback ────────────────────────────
step(0.4, function()
    log("[stage 3] layout and fallback")
    local conf = mp.get_opt("boda-menu_sections")
    saved.conf = conf
    build("main")
end)

step(0.6, function()
    local t = tree()
    if saved.conf and saved.conf ~= "" then
        check("only the configured groups appear", find(t, "Open") ~= nil and find(t, "Video") == nil,
            table.concat(titles(t), ", "))
    else
        check("with no setting it is the default layout", find(t, "Video") ~= nil, "menu_sections unset")
    end
end)

step(0.4, function()
    -- show the list used where the native menu is missing
    mp.commandv("script-message", "boda-menu-fallback")
end)

step(1.0, function()
    local console = mp.get_property_native("user-data/mpv/console") or {}
    check("the fallback list opens", console.open == true, "open=" .. tostring(console.open))
    mp.commandv("keypress", "ESC")
end)

step(0.8, function()
    local console = mp.get_property_native("user-data/mpv/console") or {}
    check("ESC closes it", console.open == false, "open=" .. tostring(console.open))
end)

-- How far the arrow keys seek is a setting the menu can change.
step(0.3, function() build("main") end)

step(0.5, function()
    local group = find(tree(), "Seek")
    saved.seek_group = group
    check("the seek steps are in the menu", group ~= nil and #(group.submenu or {}) == 4,
        group and (#(group.submenu or {}) .. " steps") or "no Seek group")
    mp.commandv("script-message", "boda-seek-step", "arrow", "15")
end)

step(0.7, function() build("main") end)

step(0.7, function()
    local group = find(tree(), "Seek")
    local arrows = (group or {}).submenu and group.submenu[1]
    local ticked
    for _, it in ipairs((arrows or {}).submenu or {}) do
        if has_state(it, "checked") then ticked = it.title end
    end
    check("picking one changes the step", ticked == "15s", tostring(ticked))

    -- from the start, paused: a short test clip cannot seek further than it runs
    mp.set_property_bool("pause", true)
    mp.commandv("seek", 0, "absolute")
end)

step(0.5, function()
    saved.before_seek = mp.get_property_number("time-pos") or 0
    saved.dur = mp.get_property_number("duration") or 0
    mp.commandv("script-message", "boda-seek-forward")
end)

step(0.6, function()
    local moved = (mp.get_property_number("time-pos") or 0) - saved.before_seek
    local want = math.min(15, math.max(0, saved.dur - saved.before_seek))
    check("and the arrow keys seek by it", math.abs(moved - want) < 1.5,
        string.format("moved %.1fs, wanted %.1fs", moved, want))
end)

-- The command palette is the same tree flattened, searched in mpv's console.
step(0.3, function()
    mp.set_property("vf", "")
    mp.commandv("script-message", "boda-palette")
end)

step(0.9, function()
    local console = mp.get_property_native("user-data/mpv/console") or {}
    local pal = mp.get_property_native("user-data/boda/palette") or {}
    check("the palette lists what the menu can do", console.open == true and (pal.count or 0) > 80,
        string.format("open=%s entries=%s", tostring(console.open), tostring(pal.count)))
    for _, ch in ipairs({ "d", "e", "b" }) do mp.commandv("keypress", ch) end
end)

step(0.8, function() mp.commandv("keypress", "ENTER") end)

step(0.8, function()
    check("typing narrows it, and Enter runs what is left",
        (mp.get_property("vf") or ""):find("deblock", 1, true) ~= nil,
        "vf=" .. tostring(mp.get_property("vf")))
    mp.set_property("vf", "")
end)

-- Errors are swallowed so a broken menu cannot kill the script; count them here.
step(0.4, function()
    local e = mp.get_property_native("user-data/boda/errors") or {}
    check("nothing threw while building", (e.count or 0) == 0,
        string.format("%s errors, last: %s", tostring(e.count), tostring(e.last)))
end)

mp.register_event("file-loaded", function()
    if qi == 0 then mp.add_timeout(0.6, run_next) end
end)
