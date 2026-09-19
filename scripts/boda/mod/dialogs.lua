-- Opening things. File and folder pickers use the Windows dialogs; short input
-- (URL, jump to time) is taken inside mpv, without spawning a PowerShell window.
local mp = require("mp")
local util = require("lib.util")
local state = require("lib.state")
local t = require("lib.i18n").t

local M = {}

local has_input, input = pcall(require, "mp.input")

-- Dialogs run asynchronously; the old synchronous call froze the UI while open.
local function ps_async(script, cb)
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = { "powershell", "-NoProfile", "-STA", "-WindowStyle", "Hidden", "-Command", script },
    }, function(ok, res)
        cb((ok and res and res.stdout) or "")
    end)
end

local function ps_quote(s)
    return "'" .. tostring(s or ""):gsub("'", "''") .. "'"
end

-- Windows dialog filters look like "Label|*.a;*.b|Label|*.*"
local MEDIA_EXT = "*.mkv;*.mp4;*.avi;*.webm;*.mov;*.ts;*.m2ts;*.wmv;*.flv;*.mpg;*.mpeg;*.m4v;"
    .. "*.flac;*.mp3;*.wav;*.m4a;*.aac;*.ogg;*.opus"
local SUB_EXT = "*.srt;*.ass;*.ssa;*.vtt;*.sub;*.smi"
local LIST_EXT = "*.m3u;*.m3u8"

local function media_filter()
    return ps_quote(t("filter_media") .. "|" .. MEDIA_EXT
        .. "|" .. t("filter_playlist") .. "|" .. LIST_EXT
        .. "|" .. t("filter_all") .. "|*.*")
end

local function sub_filter()
    return ps_quote(t("filter_sub") .. "|" .. SUB_EXT .. "|" .. t("filter_all") .. "|*.*")
end

local function playlist_filter()
    return ps_quote(t("filter_playlist") .. "|" .. LIST_EXT .. "|" .. t("filter_all") .. "|*.*")
end

local function start_dir()
    local path = mp.get_property("path")
    local dir = path and (not util.is_url(path)) and util.dirname(path) or nil
    return dir or state.recent[1] or ""
end

local function ask(prompt, default, submit)
    if has_input and input and input.get then
        input.get({
            prompt = prompt,
            default_text = default or "",
            submit = function(text)
                input.terminate()
                if text and text ~= "" then submit(text) end
            end,
        })
        return
    end
    ps_async([[
Add-Type -AssemblyName Microsoft.VisualBasic
[Microsoft.VisualBasic.Interaction]::InputBox(]] .. ps_quote(prompt) .. [[, 'mpv', '')
]], function(out)
        local text = out:gsub("%s+$", "")
        if text ~= "" then submit(text) end
    end)
end

local function open_paths(lines, mode)
    local first = true
    for line in lines:gmatch("[^\r\n]+") do
        local path = line:gsub("%s+$", "")
        if path ~= "" then
            mp.commandv("loadfile", path, (first and mode == "replace") and "replace" or "append")
            first = false
        end
    end
    if not first then mp.set_property_bool("pause", false) end
end

local function action(name, fn)
    mp.add_key_binding(nil, name, fn)
    mp.register_script_message("boda-" .. name, fn)
end

function M.init()
    action("open-file", function()
        ps_async([[
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object System.Windows.Forms.OpenFileDialog
$f.Multiselect = $true
$f.Title = ]] .. ps_quote(t("dlg_file")) .. [[

$f.InitialDirectory = ]] .. ps_quote(start_dir()) .. [[

$f.Filter = ]] .. media_filter() .. [[

if ($f.ShowDialog() -eq 'OK') { $f.FileNames -join "`n" }
]], function(out) open_paths(out, "replace") end)
    end)

    -- Opening a folder walks every subfolder and puts it all in the playlist.
    local function load_folder(dir)
        if not dir or dir == "" then return end
        dir = dir:gsub("[\\/]+$", "")
        if not util.exists(dir) then
            mp.osd_message(t("folder_missing", dir), 2.5)
            state.forget_folder(dir)
            return
        end
        state.remember_folder(dir)
        mp.commandv("loadfile", dir, "replace", -1, "directory-mode=recursive")
        mp.set_property_bool("pause", false)
        mp.osd_message(t("folder_opened", dir), 2)
    end

    local function browse_folder()
        ps_async([[
Add-Type -AssemblyName System.Windows.Forms
$d = New-Object System.Windows.Forms.FolderBrowserDialog
$d.Description = ]] .. ps_quote(t("dlg_folder")) .. [[

$d.SelectedPath = ]] .. ps_quote(start_dir()) .. [[

if ($d.ShowDialog() -eq 'OK') { $d.SelectedPath }
]], function(out)
            load_folder((out:gsub("%s+$", "")))
        end)
    end

    -- F2: recent folders first so you can pick one right away, browsing at the end.
    action("open-folder", function()
        local dirs = {}
        for _, d in ipairs(state.recent or {}) do dirs[#dirs + 1] = d end
        if not (has_input and input.select) or #dirs == 0 then
            browse_folder()
            return
        end
        local items = {}
        for i, d in ipairs(dirs) do items[i] = d end
        items[#items + 1] = "▸ " .. t("folder_browse")
        input.select({
            prompt = t("folder_pick"),
            items = items,
            default_item = 1,
            submit = function(i)
                if dirs[i] then load_folder(dirs[i]) else browse_folder() end
            end,
        })
    end)

    mp.add_key_binding(nil, "browse-folder", browse_folder)

    -- Pick a recent folder by index (used by the menu)
    mp.register_script_message("boda-open-recent", function(n)
        local dir = (state.recent or {})[tonumber(n) or 0]
        if dir then load_folder(dir) end
    end)

    action("open-sub", function()
        ps_async([[
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object System.Windows.Forms.OpenFileDialog
$f.Title = ]] .. ps_quote(t("dlg_sub")) .. [[

$f.InitialDirectory = ]] .. ps_quote(start_dir()) .. [[

$f.Filter = ]] .. sub_filter() .. [[

if ($f.ShowDialog() -eq 'OK') { $f.FileName }
]], function(out)
            local path = out:gsub("%s+$", "")
            if path ~= "" then
                mp.commandv("sub-add", path)
                mp.osd_message(t("sub_added", util.basename(path)))
            end
        end)
    end)

    action("load-m3u", function()
        ps_async([[
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object System.Windows.Forms.OpenFileDialog
$f.Title = ]] .. ps_quote(t("dlg_playlist")) .. [[

$f.Filter = ]] .. playlist_filter() .. [[

if ($f.ShowDialog() -eq 'OK') { $f.FileName }
]], function(out)
            local path = out:gsub("%s+$", "")
            if path ~= "" then mp.commandv("loadlist", path, "replace") end
        end)
    end)

    action("open-url", function()
        ask(t("prompt_url"), "", function(text)
            mp.commandv("loadfile", text, "replace")
            mp.set_property_bool("pause", false)
        end)
    end)

    action("jump-time", function()
        ask(t("prompt_time"), "", function(text)
            mp.commandv("seek", (text:gsub("%s", "")), "absolute")
        end)
    end)

    -- The menu's "type a value" for a seek step.
    mp.register_script_message("boda-seek-ask", function(which)
        if not which then return end
        local cur = (state.prefs.seek or {})[which]
        ask(t("menu_seek_ask"), tostring(cur or ""), function(text)
            local n = tonumber((text:gsub("[^%d%.]", "")))
            if n and n > 0 then
                mp.commandv("script-message", "boda-seek-step", which, tostring(n))
            end
        end)
    end)

    -- The clipboard is read straight from an mpv property, no PowerShell needed.
    action("open-clipboard", function()
        local text = mp.get_property("clipboard/text")
        if text and text ~= "" then
            text = text:gsub("^%s+", ""):gsub("%s+$", "")
            if text ~= "" then
                mp.commandv("loadfile", text, "replace")
                mp.set_property_bool("pause", false)
                mp.osd_message(t("clipboard_opened"))
                return
            end
        end
        ps_async("Get-Clipboard -Raw", function(out)
            local clip = out:gsub("^%s+", ""):gsub("%s+$", "")
            if clip ~= "" then
                mp.commandv("loadfile", clip, "replace")
                mp.set_property_bool("pause", false)
                mp.osd_message(t("clipboard_opened"))
            else
                mp.osd_message(t("clipboard_empty"))
            end
        end)
    end)
end

return M
