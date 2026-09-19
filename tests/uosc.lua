-- Checks the optional uosc bridge without uosc being installed.
--
-- This script's name is "uosc", so to boda it is uosc: it announces itself the
-- way uosc does, takes the menu boda hands over, and answers with the callback
-- uosc would send. Then it checks boda acted on the answer.
--
--   mpv --script=tests/uosc.lua --script-opts=boda-state_dir=<tmp> <video>

local mp = require("mp")
local utils = require("mp.utils")

local pass, fail = 0, 0
local seen = {}

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

local function walk(items, depth, acc)
    acc = acc or { nodes = 0, leaves = 0, depth = 0, titles = {} }
    for _, it in ipairs(items or {}) do
        acc.nodes = acc.nodes + 1
        acc.depth = math.max(acc.depth, depth)
        if it.title then acc.titles[it.title] = it end
        if it.items then
            walk(it.items, depth + 1, acc)
        else
            acc.leaves = acc.leaves + 1
        end
    end
    return acc
end

mp.add_timeout(0.3, function()
    mp.commandv("script-message", "uosc-version", "5.0.0-test")
end)

mp.register_script_message("disable-elements", function(who, list)
    seen.disable = { who = who, list = list }
end)

mp.register_script_message("open-menu", function(json)
    local menu = utils.parse_json(json or "")
    seen.menu = menu
    if not menu then return end
    seen.walk = walk(menu.items, 1)
    -- answer the way uosc does when the user picks something
    local pick = seen.walk.titles[seen.want or ""]
    if pick and menu.callback then
        mp.commandv("script-message-to", menu.callback[1], menu.callback[2],
            utils.format_json({ type = "activate", value = pick.value, index = 1 }))
    end
end)

local queue, qi = {}, 0
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
    if not ok then check("step " .. qi .. " raised", false, err) end
    mp.add_timeout(s.d, run_next)
end

step(0.6, function()
    check("boda takes uosc's elements out of the way",
        seen.disable ~= nil and (seen.disable.list or ""):find("timeline", 1, true) ~= nil,
        seen.disable and seen.disable.list or "nothing sent")
    check("and says who is asking", seen.disable and seen.disable.who == "boda",
        seen.disable and tostring(seen.disable.who))
end)

-- the menu goes to uosc instead of the native one
step(0.2, function()
    seen.want = "1.50x"
    mp.set_property_number("speed", 1)
    mp.commandv("script-message", "boda-menu")
end)

step(0.8, function()
    local w = seen.walk or {}
    check("the menu is handed over", seen.menu ~= nil and (w.nodes or 0) > 80,
        string.format("%s nodes", tostring(w.nodes)))
    check("with its submenus intact", (w.depth or 0) >= 3, "depth " .. tostring(w.depth))
    check("and a way to answer", seen.menu ~= nil and seen.menu.callback ~= nil
        and seen.menu.callback[1] == "boda", tostring(seen.menu and seen.menu.callback))
    check("picking an item does what it says",
        math.abs((mp.get_property_number("speed") or 0) - 1.5) < 0.01,
        "speed=" .. tostring(mp.get_property("speed")))
end)

-- the palette asks for the search field to be open from the start
step(0.2, function()
    seen.menu, seen.want = nil, nil
    mp.commandv("script-message", "boda-palette")
end)

step(0.8, function()
    check("the palette opens as a search", seen.menu ~= nil and seen.menu.search_style == "palette",
        tostring(seen.menu and seen.menu.search_style))
    local console = mp.get_property_native("user-data/mpv/console") or {}
    check("and does not also open the console one", console.open ~= true, tostring(console.open))
end)

step(0.3, function()
    local e = mp.get_property_native("user-data/boda/errors") or {}
    check("nothing threw", (e.count or 0) == 0,
        string.format("%s errors, last: %s", tostring(e.count), tostring(e.last)))
end)

mp.register_event("file-loaded", function()
    if qi == 0 then mp.add_timeout(0.8, run_next) end
end)
