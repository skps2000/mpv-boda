-- 열기 계열. 파일/폴더 선택은 Windows 대화상자를 쓰고,
-- 짧은 입력(URL, 시간 이동)은 mpv 안에서 받는다 (PowerShell 창을 띄우지 않는다).
local mp = require("mp")
local util = require("lib.util")
local state = require("lib.state")

local M = {}

local has_input, input = pcall(require, "mp.input")

-- 대화상자는 비동기로 띄운다. 예전에는 동기 호출이라 창이 떠 있는 동안 UI가 멈췄다.
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
$f.Title = '파일 열기'
$f.InitialDirectory = ]] .. ps_quote(start_dir()) .. [[

$f.Filter = '동영상/음악|*.mkv;*.mp4;*.avi;*.webm;*.mov;*.ts;*.m2ts;*.wmv;*.flv;*.mpg;*.mpeg;*.m4v' +
  ';*.flac;*.mp3;*.wav;*.m4a;*.aac;*.ogg;*.opus|재생목록|*.m3u;*.m3u8|모든 파일|*.*'
if ($f.ShowDialog() -eq 'OK') { $f.FileNames -join "`n" }
]], function(out) open_paths(out, "replace") end)
    end)

    -- 폴더를 열면 하위 폴더까지 전부 훑어서 재생목록에 넣는다.
    local function load_folder(dir)
        if not dir or dir == "" then return end
        dir = dir:gsub("[\\/]+$", "")
        if not util.exists(dir) then
            mp.osd_message("폴더를 찾을 수 없습니다\n" .. dir, 2.5)
            state.forget_folder(dir)
            return
        end
        state.remember_folder(dir)
        mp.commandv("loadfile", dir, "replace", -1, "directory-mode=recursive")
        mp.set_property_bool("pause", false)
        mp.osd_message("폴더 열기: " .. dir, 2)
    end

    local function browse_folder()
        ps_async([[
Add-Type -AssemblyName System.Windows.Forms
$d = New-Object System.Windows.Forms.FolderBrowserDialog
$d.Description = '폴더 열기'
$d.SelectedPath = ]] .. ps_quote(start_dir()) .. [[

if ($d.ShowDialog() -eq 'OK') { $d.SelectedPath }
]], function(out)
            load_folder((out:gsub("%s+$", "")))
        end)
    end

    -- F2: 최근 폴더를 위에 세워 바로 고르게 하고, 맨 아래에서 찾아보기로 넘어간다.
    action("open-folder", function()
        local dirs = {}
        for _, d in ipairs(state.recent or {}) do dirs[#dirs + 1] = d end
        if not (has_input and input.select) or #dirs == 0 then
            browse_folder()
            return
        end
        local items = {}
        for i, d in ipairs(dirs) do items[i] = d end
        items[#items + 1] = "▸ 폴더 찾아보기…"
        input.select({
            prompt = "폴더 열기 — 최근 폴더",
            items = items,
            default_item = 1,
            submit = function(i)
                if dirs[i] then load_folder(dirs[i]) else browse_folder() end
            end,
        })
    end)

    mp.add_key_binding(nil, "browse-folder", browse_folder)

    -- 메뉴에서 최근 폴더를 번호로 고른다
    mp.register_script_message("boda-open-recent", function(n)
        local dir = (state.recent or {})[tonumber(n) or 0]
        if dir then load_folder(dir) end
    end)

    action("open-sub", function()
        ps_async([[
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object System.Windows.Forms.OpenFileDialog
$f.Title = '자막 열기'
$f.InitialDirectory = ]] .. ps_quote(start_dir()) .. [[

$f.Filter = '자막|*.srt;*.ass;*.ssa;*.vtt;*.sub;*.smi|모든 파일|*.*'
if ($f.ShowDialog() -eq 'OK') { $f.FileName }
]], function(out)
            local path = out:gsub("%s+$", "")
            if path ~= "" then
                mp.commandv("sub-add", path)
                mp.osd_message("자막 추가: " .. util.basename(path))
            end
        end)
    end)

    action("load-m3u", function()
        ps_async([[
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object System.Windows.Forms.OpenFileDialog
$f.Title = '재생목록 열기'
$f.Filter = '재생목록|*.m3u;*.m3u8|모든 파일|*.*'
if ($f.ShowDialog() -eq 'OK') { $f.FileName }
]], function(out)
            local path = out:gsub("%s+$", "")
            if path ~= "" then mp.commandv("loadlist", path, "replace") end
        end)
    end)

    action("open-url", function()
        ask("URL 또는 경로: ", "", function(text)
            mp.commandv("loadfile", text, "replace")
            mp.set_property_bool("pause", false)
        end)
    end)

    action("jump-time", function()
        ask("이동할 시간 (1:23:00 또는 90): ", "", function(text)
            mp.commandv("seek", (text:gsub("%s", "")), "absolute")
        end)
    end)

    -- 클립보드는 mpv 속성으로 바로 읽는다 (PowerShell 필요 없음).
    action("open-clipboard", function()
        local text = mp.get_property("clipboard/text")
        if text and text ~= "" then
            text = text:gsub("^%s+", ""):gsub("%s+$", "")
            if text ~= "" then
                mp.commandv("loadfile", text, "replace")
                mp.set_property_bool("pause", false)
                mp.osd_message("클립보드에서 열기")
                return
            end
        end
        ps_async("Get-Clipboard -Raw", function(out)
            local t = out:gsub("^%s+", ""):gsub("%s+$", "")
            if t ~= "" then
                mp.commandv("loadfile", t, "replace")
                mp.set_property_bool("pause", false)
                mp.osd_message("클립보드에서 열기")
            else
                mp.osd_message("클립보드가 비어 있습니다")
            end
        end)
    end)
end

return M
