-- PotPlayer-compatible helpers for mpv (Windows)

local mp = require("mp")
local msg = require("mp.msg")
local utils = require("mp.utils")
local options = require("mp.options")

local last_speed = 1.0
local bookmarks = {}
local shot_seq = false
local last_eq = { brightness = 0, contrast = 0, saturation = 0, gamma = 0, hue = 0 }
local eq_on = true
local hflip, vflip = false, false
local denoise_on, blur_on, sharp_on, deblock_on = false, false, false, false
local voice_rm, stereo_swap, norm_on = false, false, false

local function osd(t, d)
    mp.osd_message(t, d or 1.2)
end

local function seek_rel(dt)
    mp.commandv("seek", dt, "relative")
    local cur = mp.get_property_osd("playback-time") or ""
    local dur = mp.get_property_osd("duration") or ""
    if cur ~= "" then
        osd((dur ~= "" and (cur .. " / " .. dur) or cur), 0.6)
    end
end

local seek_opts = {repeatable = true}
mp.add_forced_key_binding("LEFT",  "pp-seek-left",  function() seek_rel(-5) end, seek_opts)
mp.add_forced_key_binding("RIGHT", "pp-seek-right", function() seek_rel(5) end, seek_opts)
mp.add_forced_key_binding("Ctrl+LEFT",  "pp-seek-l30", function() seek_rel(-30) end, seek_opts)
mp.add_forced_key_binding("Ctrl+RIGHT", "pp-seek-r30", function() seek_rel(30) end, seek_opts)
mp.add_forced_key_binding("Shift+LEFT",  "pp-seek-l60", function() seek_rel(-60) end, seek_opts)
mp.add_forced_key_binding("Shift+RIGHT", "pp-seek-r60", function() seek_rel(60) end, seek_opts)

local function time_pos()
    return mp.get_property_number("time-pos") or 0
end

local function duration()
    return mp.get_property_number("duration") or 0
end

-- Speed: Z toggles 1.0 / last used; X slower; C faster
mp.register_script_message("pp-speed-down", function()
    local s = mp.get_property_number("speed") or 1
    if math.abs(s - 1.0) > 0.01 then last_speed = s end
    s = math.max(0.1, s - 0.1)
    mp.set_property_number("speed", s)
    osd(string.format("속도: %.2fx", s))
end)

mp.register_script_message("pp-speed-up", function()
    local s = mp.get_property_number("speed") or 1
    if math.abs(s - 1.0) > 0.01 then last_speed = s end
    s = math.min(8, s + 0.1)
    mp.set_property_number("speed", s)
    osd(string.format("속도: %.2fx", s))
end)

mp.register_script_message("pp-speed-toggle", function()
    local s = mp.get_property_number("speed") or 1
    if math.abs(s - 1.0) < 0.01 then
        mp.set_property_number("speed", last_speed)
        osd(string.format("속도: %.2fx (이전)", last_speed))
    else
        last_speed = s
        mp.set_property_number("speed", 1.0)
        osd("속도: 1.00x")
    end
end)

-- A-B loop
local function show_ab()
    local a = mp.get_property("ab-loop-a")
    local b = mp.get_property("ab-loop-b")
    osd(string.format("A-B  |  A=%s  B=%s", tostring(a), tostring(b)))
end

mp.register_script_message("pp-ab-a", function()
    mp.set_property_number("ab-loop-a", time_pos())
    show_ab()
end)
mp.register_script_message("pp-ab-b", function()
    mp.set_property_number("ab-loop-b", time_pos())
    show_ab()
end)
mp.register_script_message("pp-ab-clear-a", function()
    mp.set_property("ab-loop-a", "no")
    show_ab()
end)
mp.register_script_message("pp-ab-clear-b", function()
    mp.set_property("ab-loop-b", "no")
    show_ab()
end)
mp.register_script_message("pp-ab-toggle", function()
    local a = mp.get_property("ab-loop-a")
    local b = mp.get_property("ab-loop-b")
    if a ~= "no" or b ~= "no" then
        mp.set_property("ab-loop-a", "no")
        mp.set_property("ab-loop-b", "no")
        osd("A-B 반복 해제")
    else
        osd("A-B 지점이 없습니다. [ 와 ] 로 지정하세요")
    end
end)

local function nudge_ab(which, delta)
    local p = mp.get_property(which)
    if p == "no" then return end
    local n = tonumber(p) + delta
    if n < 0 then n = 0 end
    mp.set_property_number(which, n)
    show_ab()
end
mp.register_script_message("pp-ab-nudge", function(which, delta)
    nudge_ab(which, tonumber(delta) or 0)
end)
mp.register_script_message("pp-ab-nudge-both", function(delta)
    local d = tonumber(delta) or 0
    nudge_ab("ab-loop-a", d)
    nudge_ab("ab-loop-b", d)
end)

-- Jump helpers
mp.register_script_message("pp-jump-start", function()
    mp.commandv("seek", "0", "absolute")
    osd("처음으로")
end)
mp.register_script_message("pp-jump-mid", function()
    local d = duration()
    if d > 0 then
        mp.commandv("seek", d / 2, "absolute")
        osd("중간")
    end
end)
mp.register_script_message("pp-jump-end30", function()
    local d = duration()
    if d > 30 then
        mp.commandv("seek", d - 30, "absolute")
        osd("끝 30초 전")
    end
end)

-- Bookmarks
local function publish_bookmarks()
    pcall(function()
        mp.set_property_native("user-data/pp-bookmarks", bookmarks)
    end)
end

mp.register_event("file-loaded", function()
    mp.add_timeout(0.08, function()
        local v = mp.get_property_native("user-data/pp-bookmarks")
        if type(v) == "table" then bookmarks = v end
    end)
end)

mp.register_script_message("pp-bookmark-add", function()
    local t = time_pos()
    table.insert(bookmarks, t)
    publish_bookmarks()
    osd(string.format("북마크 #%d  @ %.1fs", #bookmarks, t))
end)
mp.register_script_message("pp-bookmark-list", function()
    mp.commandv("script-message", "pp-dock-show", "chapter")
end)
local function nearest_bookmark(dir)
    local t = time_pos()
    local best, best_d = nil, nil
    for _, b in ipairs(bookmarks) do
        local ok = (dir > 0 and b > t + 0.3) or (dir < 0 and b < t - 0.3)
        if ok then
            local d = math.abs(b - t)
            if not best_d or d < best_d then best, best_d = b, d end
        end
    end
    if best then
        mp.commandv("seek", best, "absolute")
        osd(string.format("북마크 %.1fs", best))
        return true
    end
    return false
end
mp.register_script_message("pp-bookmark-prev", function()
    if not nearest_bookmark(-1) then mp.commandv("add", "chapter", "-1") end
end)
mp.register_script_message("pp-bookmark-next", function()
    if not nearest_bookmark(1) then mp.commandv("add", "chapter", "1") end
end)

-- Color
local function show_eq()
    osd(string.format("밝기 %d  대비 %d  채도 %d  색상 %d",
        mp.get_property_number("brightness") or 0,
        mp.get_property_number("contrast") or 0,
        mp.get_property_number("saturation") or 0,
        mp.get_property_number("hue") or 0))
end
mp.register_script_message("pp-eq-toggle", function()
    if eq_on then
        last_eq.brightness = mp.get_property_number("brightness") or 0
        last_eq.contrast = mp.get_property_number("contrast") or 0
        last_eq.saturation = mp.get_property_number("saturation") or 0
        last_eq.gamma = mp.get_property_number("gamma") or 0
        last_eq.hue = mp.get_property_number("hue") or 0
        mp.set_property_number("brightness", 0)
        mp.set_property_number("contrast", 0)
        mp.set_property_number("saturation", 0)
        mp.set_property_number("gamma", 0)
        mp.set_property_number("hue", 0)
        eq_on = false
        osd("색보정 해제")
    else
        mp.set_property_number("brightness", last_eq.brightness)
        mp.set_property_number("contrast", last_eq.contrast)
        mp.set_property_number("saturation", last_eq.saturation)
        mp.set_property_number("gamma", last_eq.gamma)
        mp.set_property_number("hue", last_eq.hue)
        eq_on = true
        show_eq()
    end
end)
mp.register_script_message("pp-eq-show", show_eq)

-- Window scale (1–4, 5 max, 6/7 maximize)
mp.register_script_message("pp-window-scale", function(s)
    mp.set_property_number("window-scale", tonumber(s) or 1)
    osd(string.format("창 크기: %sx", s))
end)
mp.register_script_message("pp-window-max", function()
    local fs = mp.get_property_bool("fullscreen")
    mp.set_property_bool("fullscreen", not fs)
    osd(fs and "창 모드" or "최대화")
end)

local WIN_SCALES = {0.5, 1, 1.5, 2}
mp.register_script_message("pp-window-cycle", function()
    if mp.get_property_bool("fullscreen") then
        mp.set_property_bool("fullscreen", false)
    end
    local cur = mp.get_property_number("window-scale") or 1
    local nxt = WIN_SCALES[1]
    for i, s in ipairs(WIN_SCALES) do
        if cur < s - 0.08 then
            nxt = s
            break
        end
        nxt = WIN_SCALES[1]
    end
    mp.set_property_number("window-scale", nxt)
    osd(string.format("창 크기: %.1fx", nxt))
end)

local function seek_percent(p)
    local dur = mp.get_property_number("duration") or 0
    if dur <= 0 then return end
    mp.commandv("seek", p, "absolute-percent")
    osd(string.format("%d%%", p), 0.6)
end

for i = 0, 9 do
    local pct = i * 10
    mp.add_forced_key_binding(tostring(i), "yt-seek-" .. i, function()
        seek_percent(pct)
    end)
end

-- Screenshot to clipboard (Windows)
mp.register_script_message("pp-shot-clipboard", function()
    local tmp = os.getenv("TEMP") or "."
    local path = utils.join_path(tmp, "mpv-clipboard.png")
    mp.commandv("screenshot-to-file", path, "video")
    local r = mp.command_native({
        name = "subprocess",
        playback_only = false,
        args = {
            "powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command",
            "Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; " ..
            "$img = [System.Drawing.Image]::FromFile('" .. path:gsub("\\", "\\\\") .. "'); " ..
            "[System.Windows.Forms.Clipboard]::SetImage($img); $img.Dispose()"
        }
    })
    if r and r.status == 0 then osd("프레임을 클립보드에 복사") else osd("클립보드 복사 실패") end
end)

mp.register_script_message("pp-shot-seq", function()
    shot_seq = not shot_seq
    mp.set_property_bool("screenshot-sw", false)
    if shot_seq then
        mp.commandv("screenshot", "video", "each-frame")
        osd("연속 캡처 시작 (다시 누르면 중지)")
    else
        mp.commandv("screenshot", "video") -- dummy to reset? each-frame is a flag on command
        osd("연속 캡처는 다음 스크린샷 명령에서 each-frame 없이 촬영하면 종료됩니다")
    end
end)

-- Open file / folder / URL
local function ps(cmd)
    return mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = { "powershell", "-NoProfile", "-STA", "-Command", cmd }
    })
end

mp.register_script_message("pp-open-file", function()
    local r = ps([[
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object System.Windows.Forms.OpenFileDialog
$f.Multiselect = $true
$f.Filter = 'Media files|*.mkv;*.mp4;*.avi;*.webm;*.mov;*.ts;*.m2ts;*.flac;*.mp3;*.wav;*.m4a;*.aac;*.ogg;*.opus|All|*.*'
if ($f.ShowDialog() -eq 'OK') { $f.FileNames -join "`n" }
]])
    if not r or not r.stdout or r.stdout == "" then return end
    local first = true
    for line in r.stdout:gmatch("[^\r\n]+") do
        if first then
            mp.commandv("loadfile", line, "replace")
            first = false
        else
            mp.commandv("loadfile", line, "append")
        end
    end
end)

mp.register_script_message("pp-open-folder", function()
    local r = ps([[
Add-Type -AssemblyName System.Windows.Forms
$d = New-Object System.Windows.Forms.FolderBrowserDialog
if ($d.ShowDialog() -eq 'OK') { $d.SelectedPath }
]])
    if not r or not r.stdout then return end
    local dir = r.stdout:gsub("%s+$", "")
    if dir == "" then return end
    mp.commandv("loadfile", dir, "replace")
end)

mp.register_script_message("pp-open-url", function()
    local r = ps([[
Add-Type -AssemblyName Microsoft.VisualBasic
[Microsoft.VisualBasic.Interaction]::InputBox('URL 또는 파일 경로','열기','')
]])
    if not r or not r.stdout then return end
    local u = r.stdout:gsub("%s+$", "")
    if u ~= "" then mp.commandv("loadfile", u, "replace") end
end)

mp.register_script_message("pp-open-clipboard", function()
    local r = ps("Get-Clipboard -Raw")
    if not r or not r.stdout then return end
    local u = r.stdout:gsub("^%s+", ""):gsub("%s+$", "")
    if u ~= "" then
        mp.commandv("loadfile", u, "replace")
        osd("클립보드에서 열기")
    end
end)

mp.register_script_message("pp-jump-time", function()
    local r = ps([[
Add-Type -AssemblyName Microsoft.VisualBasic
[Microsoft.VisualBasic.Interaction]::InputBox('이동할 시간 (예: 1:23:00 또는 90)','위치 이동','')
]])
    if not r or not r.stdout then return end
    local s = r.stdout:gsub("%s+", "")
    if s == "" then return end
    mp.commandv("seek", s, "absolute")
end)

mp.register_script_message("pp-load-sub", function()
    local r = ps([[
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object System.Windows.Forms.OpenFileDialog
$f.Filter = 'Subtitles|*.srt;*.ass;*.ssa;*.vtt;*.sub|All|*.*'
if ($f.ShowDialog() -eq 'OK') { $f.FileName }
]])
    if not r or not r.stdout then return end
    local pth = r.stdout:gsub("%s+$", "")
    if pth ~= "" then mp.commandv("sub-add", pth) end
end)

mp.register_script_message("pp-open-config", function()
    local conf = mp.command_native({ "expand-path", "~~/" })
    mp.command_native({
        name = "subprocess",
        playback_only = false,
        args = { "explorer.exe", conf }
    })
    osd("설정 폴더 열기")
end)

mp.register_script_message("pp-about", function()
    local v = mp.get_property("mpv-version") or "mpv"
    osd(v .. "\n팟플레이어 단축키 호환 적용됨", 3)
end)

mp.register_script_message("pp-playlist-toggle", function()
    mp.commandv("script-message", "pp-dock-toggle")
end)

mp.register_script_message("pp-na", function(what)
    osd((what or "이 기능") .. " 은 mpv에 없습니다")
end)

-- Filters
local function toggle_vf(label, args, flag)
    if flag then
        mp.command("vf remove @" .. label)
        return false
    else
        mp.command("vf add @" .. label .. ":" .. args)
        return true
    end
end

mp.register_script_message("pp-hflip", function()
    hflip = not hflip
    mp.commandv("vf", hflip and "add" or "remove", "@hflip:hflip")
    osd(hflip and "좌우 반전" or "좌우 반전 해제")
end)
mp.register_script_message("pp-vflip", function()
    vflip = not vflip
    mp.commandv("vf", vflip and "add" or "remove", "@vflip:vflip")
    osd(vflip and "상하 반전" or "상하 반전 해제")
end)
mp.register_script_message("pp-blur", function()
    blur_on = toggle_vf("ppblur", "gblur=sigma=1.2", blur_on)
    osd(blur_on and "블러 켜짐" or "블러 꺼짐")
end)
mp.register_script_message("pp-sharp", function()
    sharp_on = toggle_vf("ppsharp", "unsharp", sharp_on)
    osd(sharp_on and "샤픈 켜짐" or "샤픈 꺼짐")
end)
mp.register_script_message("pp-denoise", function()
    denoise_on = toggle_vf("ppdn", "hqdn3d", denoise_on)
    osd(denoise_on and "노이즈 감소 켜짐" or "노이즈 감소 꺼짐")
end)
mp.register_script_message("pp-deblock", function()
    deblock_on = toggle_vf("ppdb", "pp=ha/va/dr", deblock_on)
    osd(deblock_on and "디블록 켜짐" or "디블록 꺼짐")
end)

mp.register_script_message("pp-norm", function()
    norm_on = not norm_on
    mp.set_property("af", norm_on and "dynaudnorm" or "")
    osd(norm_on and "노멀라이저 켜짐" or "노멀라이저 꺼짐")
end)
mp.register_script_message("pp-voice-rm", function()
    voice_rm = not voice_rm
    mp.set_property("af", voice_rm and "stereotools=mlev=0" or "")
    osd(voice_rm and "보컬 제거 시도" or "보컬 제거 해제")
end)
mp.register_script_message("pp-stereo-swap", function()
    stereo_swap = not stereo_swap
    mp.set_property("af", stereo_swap and "pan=stereo|c0=c1|c1=c0" or "")
    osd(stereo_swap and "스테레오 채널 교환" or "채널 원위치")
end)

mp.register_script_message("pp-rotate", function()
    local r = (mp.get_property_number("video-rotate") or 0) + 90
    if r >= 360 then r = 0 end
    mp.set_property_number("video-rotate", r)
    osd("회전 " .. tostring(r))
end)

mp.register_script_message("pp-stop", function()
    mp.command("stop")
end)

mp.register_script_message("pp-reopen", function()
    local path = mp.get_property("path")
    if path then mp.commandv("loadfile", path, "replace") end
end)

mp.register_script_message("pp-reload-sub", function()
    mp.command("rescan-external-files")
    osd("자막 다시 검색")
end)
