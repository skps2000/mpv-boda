-- Optional bridge to uosc (https://github.com/tomasklaen/uosc).
--
-- uosc is a separate script the user may or may not have installed. When it is
-- there it announces itself, and it can render a menu for another script: in
-- the player's own dark style, with instant search and icons, which the native
-- window menu has none of. Nothing is required: without uosc every menu goes
-- to the native one exactly as before.
--
-- boda keeps ownership of what the items do. uosc is handed titles and hints,
-- and hands back which item was picked; the command is run here.

local mp = require("mp")
local utils = require("mp.utils")
local opts = require("lib.options")

local M = { available = false }

-- items we handed out, by the id we put in their value
local pending = {}
local seq = 0

function M.usable()
    return M.available and opts.uosc ~= false
end

-- boda's menu-data tree -> what uosc draws. Only the keys uosc documents are
-- used; anything it does not know about is left out rather than guessed at.
local function convert(items, out)
    out = out or {}
    for _, it in ipairs(items or {}) do
        local hidden, disabled, checked = false, false, false
        for _, st in ipairs(it.state or {}) do
            if st == "hidden" then hidden = true end
            if st == "disabled" then disabled = true end
            if st == "checked" then checked = true end
        end
        if not hidden and it.type ~= "separator" then
            local entry = { title = it.title, hint = it.shortcut }
            if it.submenu then
                entry.items = convert(it.submenu)
            else
                seq = seq + 1
                local id = tostring(seq)
                pending[id] = it.cmd
                entry.value = id
                entry.active = checked
                entry.selectable = not disabled
            end
            out[#out + 1] = entry
        end
    end
    return out
end

-- Open a menu. `search` makes it a palette: the search field is always there.
function M.open(items, title, search)
    if not M.usable() then return false end
    pending, seq = {}, 0
    local menu = {
        type = "boda",
        title = title,
        items = convert(items),
        search_style = search and "palette" or "on_demand",
        search_submenus = true,
        callback = { mp.get_script_name(), "uosc-event" },
    }
    local ok, json = pcall(utils.format_json, menu)
    if not ok or not json then return false end
    local sent = pcall(mp.commandv, "script-message-to", "uosc", "open-menu", json)
    return sent == true
end

local function run(cmd)
    if type(cmd) ~= "string" or cmd == "" then return end
    mp.command(cmd)
end

function M.init()
    -- uosc broadcasts this on startup; that is how a script knows it is there
    mp.register_script_message("uosc-version", function(version)
        M.available = true
        M.version = version
        if opts.uosc == false then return end
        -- boda draws its own seek bar and controls, so keep uosc's out of the way
        pcall(mp.commandv, "script-message-to", "uosc", "disable-elements",
            mp.get_script_name(), "timeline,controls,volume,top_bar,speed")
        mp.msg.verbose("uosc " .. tostring(version) .. " found, menus go through it")
    end)

    mp.register_script_message("uosc-event", function(payload)
        local ok, event = pcall(utils.parse_json, payload or "")
        if not ok or type(event) ~= "table" then return end
        if event.type == "activate" then
            run(pending[tostring(event.value)])
        end
    end)
end

return M
