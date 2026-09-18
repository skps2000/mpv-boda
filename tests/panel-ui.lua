-- boda panel tests
--
-- Replays real mouse moves, clicks, drags and wheel events to see how the panel
-- reacts. A window is needed, so this does not run headless. See tests/README.md.
--
--   mpv --script=tests/panel-ui.lua --script-opts=boda-state_dir=<tmp> <first file>
--
-- Use a folder with 30+ videos, otherwise the scrolling checks mean nothing.

local mp = require("mp")

local pass, fail = 0, 0
local queue, qi = {}, 0
local saved = {}
local loads = 0 -- how often a file was loaded (to catch an unwanted restart)

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

local function info() return mp.get_property_native("user-data/boda/panel") or {} end
local function idle_info() return mp.get_property_native("user-data/boda/idle") or {} end
local function errors() return mp.get_property_native("user-data/boda/errors") or {} end
local function mouse(x, y) mp.commandv("mouse", math.floor(x), math.floor(y)) end

local function click(x, y)
    mouse(x, y)
    mp.commandv("mouse", math.floor(x), math.floor(y), 0)
end

local function dblclick(x, y)
    mouse(x, y)
    mp.commandv("mouse", math.floor(x), math.floor(y), 0, "double")
end

local function wheel(x, y, dir, times)
    mouse(x, y)
    for _ = 1, (times or 1) do
        mp.commandv("keypress", dir > 0 and "WHEEL_UP" or "WHEEL_DOWN")
    end
end

local function step(delay, fn) queue[#queue + 1] = { delay = delay, fn = fn } end

-- Drag with the button held. Steps need time between them, like a real hand:
-- sent all at once, mpv never processes them in order.
local function drag_steps(plan_fn)
    local plan
    step(0.15, function()
        plan = plan_fn()
        mouse(plan.from[1], plan.from[2])
    end)
    step(0.15, function() mp.commandv("keydown", "MBTN_LEFT") end)
    for i = 1, 6 do
        step(0.12, function()
            local p = plan.points[i]
            if p then mouse(p[1], p[2]) end
        end)
    end
    step(0.2, function() mp.commandv("keyup", "MBTN_LEFT") end)
end

local function row_xy(i)
    local n = info()
    return n.x0 + 40, n.top + (i - 1) * n.row_h + n.row_h / 2
end

local function basename(path)
    return (tostring(path or ""):gsub(".*[\\/]", ""))
end

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
    mp.add_timeout(s.delay, run_next)
end

-- ── 1. scrolling the list while playing ─────────────────────────────
step(0.6, function()
    log("[1] scrolling while playing")
    mp.set_property_bool("pause", false)
    mp.commandv("script-message", "boda-panel", "pl")
end)

step(0.8, function()
    local n = info()
    check("the panel opens", n.open == true, "open=" .. tostring(n.open))
    check("the list is longer than the screen", (n.max_scroll or 0) > 0,
        "rows=" .. tostring(n.rows) .. " vis=" .. tostring(n.vis))
    saved.scroll0 = n.scroll
end)

step(0.4, function()
    local n = info()
    wheel(n.x0 + n.width / 2, n.oh / 2, -1, 5)
end)

step(0.5, function()
    local n = info()
    check("the wheel scrolls down", n.scroll == (saved.scroll0 or 0) + 5, "scroll=" .. tostring(n.scroll))
    saved.scroll1 = n.scroll
end)

step(1.5, function()
    check("the scroll position holds while playback continues", info().scroll == saved.scroll1,
        "scroll=" .. tostring(info().scroll))
end)

-- Paused from here: the list re-centres on the playing row when the file
-- changes, and with short test clips that lands right on top of this check.
step(0.3, function() mp.set_property_bool("pause", true) end)

step(0.3, function()
    local n = info()
    wheel(n.x0 + n.width / 2, n.oh / 2, -1, 5)
end)

step(0.4, function()
    local n = info()
    saved.scroll2 = n.scroll
    wheel(n.x0 + n.width / 2, n.oh / 2, 1, 2)
end)

step(0.5, function()
    check("the wheel scrolls back up", info().scroll == saved.scroll2 - 2,
        string.format("scroll=%s from=%s", tostring(info().scroll), tostring(saved.scroll2)))
    mp.set_property_bool("pause", false)
end)

-- ── 2. picking another file ─────────────────────────────────────────
step(0.3, function()
    log("[2] click to play")
    saved.target = info().scroll + 2
    local x, y = row_xy(3)
    click(x, y)
end)

step(0.8, function()
    check("one click plays that row", mp.get_property_number("playlist-pos") == saved.target,
        "pos=" .. tostring(mp.get_property_number("playlist-pos")) ..
        " (expected " .. tostring(saved.target) .. ")")
    check("clicking does not pause playback", mp.get_property_bool("pause") == false,
        "pause=" .. tostring(mp.get_property("pause")))
    local n = info()
    local cur = (mp.get_property_number("playlist-pos") or 0) + 1
    check("the playing row is on screen", cur > n.scroll and cur <= n.scroll + n.vis,
        "scroll=" .. tostring(n.scroll))
end)

-- Someone who always double clicks must not lose their place
step(0.5, function()
    saved.loads = loads
    local n = info()
    local visible_row = (mp.get_property_number("playlist-pos") or 0) - n.scroll + 1
    local x, y = row_xy(visible_row)
    dblclick(x, y)
end)

step(0.8, function()
    check("clicking the playing row again does not restart it", loads == saved.loads,
        "loaded " .. tostring(loads - saved.loads) .. " more times")
    check("a double click does not leak into play/pause", mp.get_property_bool("pause") == false,
        "pause=" .. tostring(mp.get_property("pause")))
end)

-- ── 3. highlighting the row under the cursor ────────────────────────
step(0.3, function()
    log("[3] highlight")
    local x, y = row_xy(5)
    mouse(x, y)
end)

step(0.4, function()
    check("hovering highlights that row",
        tostring(info().hover):match("^panel/row%d+") ~= nil, tostring(info().hover))
    local n = info()
    wheel(n.x0 + n.width / 2, select(2, row_xy(5)), -1, 3)
end)

step(0.5, function()
    check("after a scroll the row under the cursor is highlighted",
        tostring(info().hover):match("^panel/row%d+") ~= nil, tostring(info().hover))
end)

-- ── 4. resizing the panel freely ────────────────────────────────────
step(0.3, function()
    log("[4] width drag")
    saved.w0 = info().width
end)

drag_steps(function()
    local n = info()
    return {
        from = { n.x0, n.oh / 2 },
        points = { { n.x0 - 40, n.oh / 2 }, { n.x0 - 120, n.oh / 2 }, { n.x0 - 200, n.oh / 2 } },
    }
end)

step(0.4, function()
    check("it widens by what you dragged", math.abs(info().width - (saved.w0 + 200)) <= 8,
        "width=" .. tostring(info().width))
    saved.w1 = info().width
end)

drag_steps(function()
    local n = info()
    return { from = { n.x0, n.oh / 2 }, points = { { n.x0 + 60, n.oh / 2 }, { n.x0 + 130, n.oh / 2 } } }
end)

step(0.4, function()
    check("dragging back narrows it", math.abs(info().width - (saved.w1 - 130)) <= 8,
        "width=" .. tostring(info().width))
end)

drag_steps(function()
    local n = info()
    return { from = { n.x0, n.oh / 2 }, points = { { 300, n.oh / 2 }, { 60, n.oh / 2 }, { -300, n.oh / 2 } } }
end)

step(0.4, function()
    local n = info()
    check("video keeps a slice when dragged off-screen", n.width <= n.ow - 150,
        "width=" .. tostring(n.width) .. " ow=" .. tostring(n.ow))
    saved.w2 = n.width
    click(n.x0, n.oh / 2)
end)

step(0.5, function()
    check("a plain click on the edge jumps to a preset width", info().width ~= saved.w2,
        "width=" .. tostring(info().width))
end)

-- ── 5. dragging the scrollbar ───────────────────────────────────────
step(0.3, function() log("[5] scrollbar") end)

drag_steps(function()
    local n = info()
    return {
        from = { n.ow - 7, n.top + 20 },
        points = { { n.ow - 7, n.oh * 0.4 }, { n.ow - 7, n.oh * 0.7 },
            { n.ow - 7, n.oh * 0.9 }, { n.ow - 7, n.oh - 10 } },
    }
end)

step(0.4, function()
    local n = info()
    check("dragging it to the end reaches the last row", n.scroll == n.max_scroll,
        "scroll=" .. tostring(n.scroll) .. "/" .. tostring(n.max_scroll))
end)

-- ── 6. switching tabs ───────────────────────────────────────────────
step(0.3, function()
    log("[6] tabs")
    local n = info()
    local count = n.tabs or 6
    local tw = (n.width - 12 * n.scale) / count
    saved.tabx = {}
    for i = 1, count do saved.tabx[i] = n.x0 + 6 * n.scale + (i - 0.5) * tw end
    saved.taby = 16 * n.scale
    click(saved.tabx[2], saved.taby) -- audio
end)

step(0.4, function()
    check("the audio tab opens", info().tab == "audio", tostring(info().tab))
    click(saved.tabx[5], saved.taby) -- chapters
end)

step(0.4, function()
    check("the chapters tab opens", info().tab == "chapter", tostring(info().tab))
    -- press empty space on a tab with no rows
    local n = info()
    saved.paused = mp.get_property_bool("pause")
    click(n.x0 + n.width / 2, n.oh * 0.6)
    dblclick(n.x0 + n.width / 2, n.oh * 0.6)
end)

step(0.5, function()
    check("clicking empty panel space does not pause",
        mp.get_property_bool("pause") == saved.paused, "pause=" .. tostring(mp.get_property("pause")))
    click(saved.tabx[(info().tabs or 6)], saved.taby) -- colour, the last tab
end)

step(0.4, function()
    check("the colour tab opens", info().tab == "color", tostring(info().tab))
    mp.set_property_number("brightness", 0)
end)

-- ── 7. colour sliders ───────────────────────────────────────────────
drag_steps(function()
    local n = info()
    local s = n.scale
    local by = (34 * s + 6 * s) + 6 * s + 40 * s + 22 * s -- the first slider
    return {
        from = { n.x0 + n.width * 0.5, by },
        points = { { n.x0 + n.width * 0.7, by }, { n.x0 + n.width * 0.85, by } },
    }
end)

step(0.4, function()
    log("[7] colour slider")
    check("dragging the slider raises brightness", (mp.get_property_number("brightness") or 0) > 10,
        "brightness=" .. tostring(mp.get_property_number("brightness")))
    mp.set_property_number("brightness", 0)
    mp.commandv("script-message", "boda-panel", "pl")
end)

-- ── 8. window dragging ──────────────────────────────────────────────
step(0.4, function()
    log("[8] window dragging")
    local n = info()
    mouse(n.x0 + n.width / 2, n.oh / 2)
end)

step(0.4, function()
    check("it is off over the panel", mp.get_property_bool("window-dragging") == false,
        tostring(mp.get_property("window-dragging")))
    mouse(40, 200)
end)

step(0.4, function()
    check("it is back over the video", mp.get_property_bool("window-dragging") == true,
        tostring(mp.get_property("window-dragging")))
end)

-- ── 9. sorting ──────────────────────────────────────────────────────
step(0.3, function()
    log("[9] sorting")
    local n = info()
    local bw = (n.width - 20 * n.scale) / 6 -- six sort buttons
    saved.sortx = {}
    for i = 1, 6 do saved.sortx[i] = n.x0 + 10 * n.scale + (i - 0.5) * bw end
    click(saved.sortx[2], n.sort_top + 10 * n.scale) -- by name
end)

step(0.8, function()
    local pl = mp.get_property_native("playlist") or {}
    local sorted = true
    for i = 2, #pl do
        if basename(pl[i - 1].filename) > basename(pl[i].filename) then sorted = false break end
    end
    check("sorting by name orders the list", sorted, basename(pl[1] and pl[1].filename))
    local cur = (mp.get_property_number("playlist-pos") or 0) + 1
    check("the playing file stays current after sorting", pl[cur] and pl[cur].current == true,
        "pos=" .. tostring(cur - 1))
    click(saved.sortx[2], info().sort_top + 10 * info().scale) -- again = reversed
end)

step(0.8, function()
    local pl = mp.get_property_native("playlist") or {}
    local desc = true
    for i = 2, #pl do
        if basename(pl[i - 1].filename) < basename(pl[i].filename) then desc = false break end
    end
    check("pressing the same button reverses it", desc, basename(pl[1] and pl[1].filename))
end)

-- ── 10. the wheel over the video ────────────────────────────────────
step(0.3, function()
    log("[10] wheel over the video")
    saved.vol = mp.get_property_number("volume")
    wheel(60, 200, 1, 2)
end)

step(0.5, function()
    local v = mp.get_property_number("volume")
    check("it changes volume", v and saved.vol and v > saved.vol, "volume=" .. tostring(v))
end)

-- ── 11. the seek bar with the panel open ────────────────────────────
step(0.3, function()
    log("[11] seek bar")
    local n = info()
    mouse(n.x0 / 2, n.oh - 30)
end)

step(0.5, function()
    local n = info()
    saved.paused2 = mp.get_property_bool("pause")
    click(24 * (n.scale or 1), n.oh - 30 * (n.scale or 1))
end)

step(0.6, function()
    check("its play button is not blocked by the panel",
        mp.get_property_bool("pause") ~= saved.paused2, "pause=" .. tostring(mp.get_property("pause")))
    mp.set_property_bool("pause", false)
end)

-- ── 12. saved clips ─────────────────────────────────────────────────
step(0.3, function()
    log("[12] saved clips")
    mp.set_property_bool("pause", true)
    local dur = mp.get_property_number("duration") or 10
    saved.fav_a = dur * 0.25
    saved.fav_b = dur * 0.7
    mp.commandv("seek", saved.fav_a, "absolute")
end)

step(0.4, function() mp.commandv("script-message", "boda-ab-a") end)
step(0.3, function() mp.commandv("seek", saved.fav_b, "absolute") end)
step(0.4, function() mp.commandv("script-message", "boda-ab-b") end)
step(0.4, function() mp.commandv("script-message", "boda-favorite-add") end)
step(0.4, function() mp.commandv("script-message", "boda-panel", "fav") end)

step(0.7, function()
    local n = info()
    check("the clips tab opens", n.tab == "fav", tostring(n.tab))
    check("the range set with [ and ] is saved", n.rows == 1, "rows=" .. tostring(n.rows))
    mp.commandv("seek", 0, "absolute")
end)

step(0.5, function()
    local x, y = row_xy(1)
    click(x, y)
end)

step(0.7, function()
    local t = mp.get_property_number("time-pos") or -1
    check("clicking a clip plays from its start", math.abs(t - saved.fav_a) < 1.0,
        string.format("time-pos=%.1f (expected %.1f)", t, saved.fav_a))
    mp.set_property("ab-loop-a", "no")
    mp.set_property("ab-loop-b", "no")
end)

step(0.4, function()
    local n = info()
    local _, y = row_xy(1)
    click(n.x0 + n.width - 32 * n.scale, y) -- loop button
end)

step(0.7, function()
    local a = tonumber(mp.get_property("ab-loop-a"))
    local b = tonumber(mp.get_property("ab-loop-b"))
    check("the loop button sets the A-B loop",
        a ~= nil and b ~= nil and math.abs(a - saved.fav_a) < 1 and math.abs(b - saved.fav_b) < 1,
        string.format("a=%s b=%s (expected %.1f/%.1f)", tostring(a), tostring(b),
            saved.fav_a or -1, saved.fav_b or -1))
    local n = info()
    local _, y = row_xy(1)
    click(n.x0 + n.width - 14 * n.scale, y) -- the × button
end)

step(0.7, function()
    check("× removes it from the list", info().rows == 0, "rows=" .. tostring(info().rows))
    mp.set_property("ab-loop-a", "no")
    mp.set_property("ab-loop-b", "no")
    mp.commandv("script-message", "boda-panel", "pl")
    mp.set_property_bool("pause", false)
end)

-- ── 13. changing the window size ────────────────────────────────────
step(0.3, function()
    log("[13] fullscreen")
    saved.width_before = info().width
    mp.set_property_bool("fullscreen", true)
end)

step(1.2, function()
    local n = info()
    check("the panel survives fullscreen", n.open == true, tostring(n.open))
    check("it is laid out for the new width", n.x0 + n.width == n.ow,
        string.format("x0=%s w=%s ow=%s", tostring(n.x0), tostring(n.width), tostring(n.ow)))
    mp.set_property_bool("fullscreen", false)
end)

step(1.2, function()
    check("the width is kept coming back",
        math.abs((info().width or 0) - (saved.width_before or 0)) <= 8, tostring(info().width))
end)

-- ── 14. keyboard toggle and stop ────────────────────────────────────
step(0.3, function()
    log("[14] F6 toggle and stop")
    mp.commandv("keypress", "F6")
end)

step(0.5, function()
    check("F6 closes it", info().open ~= true, tostring(info().open))
    mp.commandv("keypress", "F6")
end)

step(0.5, function()
    check("F6 opens it again", info().open == true, tostring(info().open))
    check("the video margin comes back", (mp.get_property_number("video-margin-ratio-right") or 0) > 0.05,
        tostring(mp.get_property("video-margin-ratio-right")))
    mp.command("stop")
end)

step(1.2, function()
    check("stopping hands the screen to the idle view", info().open ~= true, tostring(info().open))
    local n = idle_info()
    check("the idle screen comes up", n.active == true, tostring(n.active))
    check("it lists what was watched", (n.rows or 0) > 0 and (n.shown or 0) > 0,
        string.format("rows=%s shown=%s", tostring(n.rows), tostring(n.shown)))
end)

-- A draw that throws is swallowed so one bad screen cannot kill the script, so
-- the count is checked here instead: a silently blank screen is still a failure.
step(0.4, function()
    local e = errors()
    check("nothing threw while drawing", (e.count or 0) == 0,
        string.format("%s errors, last: %s", tostring(e.count), tostring(e.last)))
end)

mp.register_event("file-loaded", function()
    loads = loads + 1
    if qi == 0 then mp.add_timeout(0.5, run_next) end
end)
