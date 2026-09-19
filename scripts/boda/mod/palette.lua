-- Command palette: one key, type a few letters, run anything boda can do.
--
-- The list is the context menu flattened, so it never drifts out of step with
-- the menu and needs no second registry to maintain. Where uosc is installed it
-- draws the palette; otherwise mpv's own console does, which already filters
-- what you type against the list.

local mp = require("mp")
local uosc = require("lib.uosc")
local t = require("lib.i18n").t

local has_input, input = pcall(require, "mp.input")

local M = {}

local SEP = "  ›  "

-- Walk the tree, keeping the path so "Video › Sharpen" tells you where it lives.
local function flatten(items, prefix, out)
    out = out or {}
    for _, it in ipairs(items or {}) do
        local hidden, disabled = false, false
        for _, st in ipairs(it.state or {}) do
            if st == "hidden" then hidden = true end
            if st == "disabled" then disabled = true end
        end
        if not hidden and it.type ~= "separator" and it.title then
            local label = prefix == "" and it.title or (prefix .. SEP .. it.title)
            if it.submenu then
                flatten(it.submenu, label, out)
            elseif it.cmd and it.cmd ~= "" and not disabled then
                out[#out + 1] = { label = label, cmd = it.cmd, key = it.shortcut }
            end
        end
    end
    return out
end

function M.open(items, title)
    local entries = flatten(items, "")
    if #entries == 0 then return end

    if uosc.usable() then
        -- uosc wants the tree, and searches into submenus itself
        if uosc.open(items, title or t("palette_title"), true) then return end
    end

    if not (has_input and input and input.select) then
        mp.osd_message(t("palette_missing"))
        return
    end

    local labels = {}
    for i, e in ipairs(entries) do
        labels[i] = e.key and e.key ~= "" and (e.label .. "   [" .. e.key .. "]") or e.label
    end
    input.select({
        prompt = title or t("palette_title"),
        items = labels,
        submit = function(i)
            input.terminate()
            local pick = entries[i]
            if pick then mp.command(pick.cmd) end
        end,
    })
    mp.set_property_native("user-data/boda/palette", { count = #entries })
end

return M
