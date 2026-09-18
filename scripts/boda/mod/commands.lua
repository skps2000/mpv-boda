-- 키로 부르는 동작들. 모든 동작은 script-binding 과 script-message 양쪽으로 열어둔다.
-- (기본 키는 input.conf 에만 있고, 스크립트가 키를 강제로 가져가지 않는다.)
local mp = require("mp")
local util = require("lib.util")
local state = require("lib.state")

local M = {}

local function osd(text, dur)
    mp.osd_message(text, dur or 1.2)
end

local function action(name, fn, flags)
    mp.add_key_binding(nil, name, fn, flags)
    mp.register_script_message("boda-" .. name, fn)
end

-- ── 속도 ────────────────────────────────────────────────────────────
local last_speed = 1.0

local function set_speed(v)
    v = util.clamp(v, 0.1, 8)
    mp.set_property_number("speed", v)
    osd(string.format("속도 %.2fx", v))
end

-- ── 필터 ────────────────────────────────────────────────────────────
-- 상태를 Lua 변수로 들고 있으면 실제 필터 목록과 어긋난다. mpv 에 toggle 을 맡기고
-- 결과를 다시 읽어서 알린다. (실패하면 "켜짐"이라고 거짓말하지 않는다)
local function toggle_filter(kind, label, filter, on_text, off_text)
    mp.commandv(kind, "toggle", "@" .. label .. ":" .. filter)
    local list = mp.get_property(kind) or ""
    local on = list:find("@" .. label, 1, true) ~= nil
    osd(on and on_text or off_text)
    return on
end

local function vf_action(name, label, filter, on_text, off_text)
    action(name, function() toggle_filter("vf", label, filter, on_text, off_text) end)
end

local function af_action(name, label, filter, on_text, off_text)
    action(name, function() toggle_filter("af", label, filter, on_text, off_text) end)
end

-- ── 색보정 ──────────────────────────────────────────────────────────
local EQ = { "brightness", "contrast", "saturation", "gamma", "hue" }
local saved_eq, eq_off = nil, false

local function eq_text()
    return string.format("밝기 %d  대비 %d  채도 %d  감마 %d  색상 %d",
        mp.get_property_number("brightness") or 0,
        mp.get_property_number("contrast") or 0,
        mp.get_property_number("saturation") or 0,
        mp.get_property_number("gamma") or 0,
        mp.get_property_number("hue") or 0)
end

local function recommend()
    local transfer = tostring(mp.get_property("video-params/gamma") or "")
    local peak = mp.get_property_number("video-params/sig-peak") or 0
    if transfer:find("pq") or transfer:find("hlg") or peak > 1.2 then
        return nil, "HDR 원본 유지"
    end
    local h = mp.get_property_number("video-params/h") or 0
    if h >= 1440 then
        return { brightness = 0, contrast = 2, saturation = 2, gamma = 0 }, "고해상도"
    elseif h >= 1000 then
        return { brightness = 1, contrast = 3, saturation = 3, gamma = 0 }, "FHD"
    elseif h > 0 then
        return { brightness = 2, contrast = 5, saturation = 4, gamma = -1 }, "저해상도 보정"
    end
    return nil, nil
end

local function apply_auto_color(quiet)
    if not state.prefs.auto_color then return end
    local eq, name = recommend()
    if not eq then
        if name and not quiet then osd("자동 보정: " .. name, 1.0) end
        return
    end
    for k, v in pairs(eq) do mp.set_property_number(k, v) end
    if not quiet then osd("자동 보정: " .. name, 1.0) end
end

-- ── 창 ──────────────────────────────────────────────────────────────
local WIN_SCALES = { 0.5, 1, 1.5, 2 }
local pip_saved = nil
local boss_hidden = false

function M.init()
    -- 속도
    action("speed-up", function()
        local s = mp.get_property_number("speed") or 1
        if math.abs(s - 1) > 0.01 then last_speed = s end
        set_speed(s + 0.1)
    end, { repeatable = true })
    action("speed-down", function()
        local s = mp.get_property_number("speed") or 1
        if math.abs(s - 1) > 0.01 then last_speed = s end
        set_speed(s - 0.1)
    end, { repeatable = true })
    action("speed-toggle", function()
        local s = mp.get_property_number("speed") or 1
        if math.abs(s - 1) < 0.01 then
            set_speed(last_speed)
        else
            last_speed = s
            set_speed(1)
        end
    end)
    action("speed-reset", function() set_speed(1) end)

    -- A-B 반복
    local function show_ab()
        local function fmt(v)
            if not v or v == "no" then return "―" end
            return util.fmt_time(tonumber(v))
        end
        osd(string.format("A-B  A %s   B %s",
            fmt(mp.get_property("ab-loop-a")), fmt(mp.get_property("ab-loop-b"))))
    end
    action("ab-a", function()
        mp.set_property_number("ab-loop-a", mp.get_property_number("time-pos") or 0)
        show_ab()
    end)
    action("ab-b", function()
        mp.set_property_number("ab-loop-b", mp.get_property_number("time-pos") or 0)
        show_ab()
    end)
    action("ab-clear-a", function()
        mp.set_property("ab-loop-a", "no")
        show_ab()
    end)
    action("ab-clear-b", function()
        mp.set_property("ab-loop-b", "no")
        show_ab()
    end)
    action("ab-clear", function()
        mp.set_property("ab-loop-a", "no")
        mp.set_property("ab-loop-b", "no")
        osd("A-B 반복 해제")
    end)
    action("ab-toggle", function()
        local a, b = mp.get_property("ab-loop-a"), mp.get_property("ab-loop-b")
        if a ~= "no" or b ~= "no" then
            mp.set_property("ab-loop-a", "no")
            mp.set_property("ab-loop-b", "no")
            osd("A-B 반복 해제")
        else
            osd("A-B 지점이 없습니다. [ 와 ] 로 지정하세요")
        end
    end)
    local function nudge(which, delta)
        local v = tonumber(mp.get_property(which))
        if not v then return end
        mp.set_property_number(which, math.max(0, v + delta))
        show_ab()
    end
    mp.register_script_message("boda-ab-nudge", function(which, delta)
        nudge(which, tonumber(delta) or 0)
    end)
    mp.register_script_message("boda-ab-nudge-both", function(delta)
        local d = tonumber(delta) or 0
        nudge("ab-loop-a", d)
        nudge("ab-loop-b", d)
    end)

    -- 북마크
    action("bookmark-add", function()
        local path = mp.get_property("path")
        local t = mp.get_property_number("time-pos")
        if not path or not t then return end
        local list = {}
        for i, v in ipairs(state.bookmarks_of(path)) do list[i] = v end
        list[#list + 1] = t
        table.sort(list)
        state.set_bookmarks(path, list)
        osd(string.format("북마크 %d개  ·  %s", #list, util.fmt_time(t)))
    end)
    local function jump_bookmark(dir)
        local path = mp.get_property("path")
        local t = mp.get_property_number("time-pos") or 0
        local best = nil
        for _, b in ipairs(state.bookmarks_of(path)) do
            if (dir > 0 and b > t + 0.4) or (dir < 0 and b < t - 0.4) then
                if not best or math.abs(b - t) < math.abs(best - t) then best = b end
            end
        end
        if best then
            mp.commandv("seek", best, "absolute")
            osd("북마크 " .. util.fmt_time(best))
        else
            mp.commandv("add", "chapter", dir)
        end
    end
    action("bookmark-prev", function() jump_bookmark(-1) end)
    action("bookmark-next", function() jump_bookmark(1) end)
    action("bookmark-clear", function()
        local path = mp.get_property("path")
        if path then state.set_bookmarks(path, {}) end
        osd("북마크를 지웠습니다")
    end)

    -- 즐겨찾기 구간
    action("favorite-add", function()
        local path = mp.get_property("path")
        if not path then return end
        local a = tonumber(mp.get_property("ab-loop-a"))
        local b = tonumber(mp.get_property("ab-loop-b"))
        if not a then a = mp.get_property_number("time-pos") or 0 end
        if b and b < a then a, b = b, a end
        local list = {}
        for i, v in ipairs(state.favorites_of(path)) do list[i] = v end
        list[#list + 1] = { a = a, b = b, name = "구간 " .. (#list + 1) }
        state.set_favorites(path, list)
        mp.commandv("script-message", "boda-refresh")
        if b then
            osd(string.format("즐겨찾기 추가  %s ~ %s", util.fmt_time(a), util.fmt_time(b)))
        else
            osd(string.format("즐겨찾기 추가  %s  ([ ] 로 구간을 정하면 구간으로 저장됩니다)",
                util.fmt_time(a)), 2)
        end
    end)
    action("favorite-clear", function()
        local path = mp.get_property("path")
        if not path then return end
        state.set_favorites(path, {})
        mp.commandv("script-message", "boda-refresh")
        osd("이 영상의 즐겨찾기를 비웠습니다")
    end)

    -- 위치 이동
    action("jump-start", function()
        mp.commandv("seek", 0, "absolute")
        osd("처음으로")
    end)
    action("jump-mid", function()
        local d = mp.get_property_number("duration") or 0
        if d > 0 then
            mp.commandv("seek", d / 2, "absolute")
            osd("중간으로")
        end
    end)
    action("jump-end", function()
        local d = mp.get_property_number("duration") or 0
        if d > 30 then
            mp.commandv("seek", d - 30, "absolute")
            osd("끝 30초 전")
        end
    end)

    -- 색보정
    action("eq-show", function() osd(eq_text()) end)
    action("eq-toggle", function()
        if not eq_off then
            saved_eq = {}
            for _, k in ipairs(EQ) do
                saved_eq[k] = mp.get_property_number(k) or 0
                mp.set_property_number(k, 0)
            end
            eq_off = true
            osd("색보정 끔 (원본)")
        else
            for _, k in ipairs(EQ) do
                mp.set_property_number(k, (saved_eq and saved_eq[k]) or 0)
            end
            eq_off = false
            osd(eq_text())
        end
    end)
    action("eq-reset", function()
        for _, k in ipairs(EQ) do mp.set_property_number(k, 0) end
        state.prefs.auto_color = false
        state.mark("prefs")
        osd("색보정 초기화")
    end)
    action("auto-color-toggle", function()
        state.prefs.auto_color = not state.prefs.auto_color
        state.mark("prefs")
        if state.prefs.auto_color then
            apply_auto_color()
        else
            for _, k in ipairs(EQ) do mp.set_property_number(k, 0) end
            osd("자동 보정 끔")
        end
    end)
    mp.register_script_message("boda-auto-color", function(mode)
        state.prefs.auto_color = (mode == "on")
        state.mark("prefs")
        if state.prefs.auto_color then
            apply_auto_color()
        else
            for _, k in ipairs(EQ) do mp.set_property_number(k, 0) end
        end
    end)

    -- 영상 필터
    vf_action("flip-h", "hflip", "hflip", "좌우 반전", "좌우 반전 해제")
    vf_action("flip-v", "vflip", "vflip", "상하 반전", "상하 반전 해제")
    vf_action("blur", "blur", "lavfi=[gblur=sigma=1.2]", "블러 켬", "블러 끔")
    vf_action("sharpen", "sharp", "lavfi=[unsharp=5:5:0.8]", "샤픈 켬", "샤픈 끔")
    vf_action("denoise", "dn", "lavfi=[hqdn3d]", "노이즈 감소 켬", "노이즈 감소 끔")
    -- 예전 pp 필터는 FFmpeg 에서 빠졌다. deblock 으로 대체.
    vf_action("deblock", "deblock", "lavfi=[deblock=filter=weak:block=4]", "디블록 켬", "디블록 끔")
    action("filters-clear", function()
        mp.commandv("vf", "clr", "")
        osd("영상 필터 모두 해제")
    end)

    -- 소리 필터 (mpv.conf 의 scaletempo2 를 지우지 않도록 라벨 토글만 쓴다)
    af_action("audio-norm", "norm", "lavfi=[dynaudnorm]", "음량 평준화 켬", "음량 평준화 끔")
    af_action("voice-remove", "voice", "lavfi=[stereotools=mlev=0]", "보컬 제거 시도", "보컬 제거 해제")
    af_action("stereo-swap", "swap", "lavfi=[pan=stereo|c0=c1|c1=c0]", "좌우 채널 교환", "채널 원위치")
    action("audio-reset", function()
        for _, label in ipairs({ "norm", "voice", "swap" }) do
            mp.commandv("af", "remove", "@" .. label)
        end
        mp.set_property("audio-delay", 0)
        osd("소리 설정 초기화")
    end)

    -- 화면
    action("upscale-toggle", function()
        local sharp = mp.get_property("scale") == "ewa_lanczossharp"
        mp.set_property("scale", sharp and "bilinear" or "ewa_lanczossharp")
        mp.set_property("deband", sharp and "no" or "yes")
        osd(sharp and "업스케일 끔" or "선명 업스케일 켬")
    end)
    action("dual-sub", function()
        mp.command("cycle secondary-sid")
        osd("듀얼 자막: 주 " .. tostring(mp.get_property("sid")) ..
            "  ·  부 " .. tostring(mp.get_property("secondary-sid")))
    end)
    action("rotate", function()
        local r = ((mp.get_property_number("video-rotate") or 0) + 90) % 360
        mp.set_property_number("video-rotate", r)
        osd("회전 " .. r .. "°")
    end)

    -- 창
    action("window-cycle", function()
        if mp.get_property_bool("fullscreen") then mp.set_property_bool("fullscreen", false) end
        local cur = mp.get_property_number("window-scale") or 1
        local nxt = WIN_SCALES[1]
        for _, s in ipairs(WIN_SCALES) do
            if cur < s - 0.08 then
                nxt = s
                break
            end
        end
        mp.set_property_number("window-scale", nxt)
        osd(string.format("창 크기 %.1fx", nxt))
    end)
    action("window-max", function()
        local maxed = mp.get_property_bool("window-maximized")
        mp.set_property_bool("window-maximized", not maxed)
        osd(maxed and "창 복원" or "창 최대화")
    end)
    mp.register_script_message("boda-window-scale", function(v)
        mp.set_property_bool("fullscreen", false)
        mp.set_property_number("window-scale", tonumber(v) or 1)
        osd(string.format("창 크기 %sx", tostring(v)))
    end)
    action("pip", function()
        if pip_saved then
            mp.set_property_bool("ontop", pip_saved.ontop)
            mp.set_property_number("window-scale", pip_saved.scale)
            pip_saved = nil
            osd("PiP 끔")
        else
            pip_saved = {
                ontop = mp.get_property_bool("ontop") or false,
                scale = mp.get_property_number("window-scale") or 1,
            }
            mp.set_property_bool("fullscreen", false)
            mp.set_property_bool("ontop", true)
            mp.set_property_number("window-scale", 0.38)
            osd("PiP 켬")
        end
    end)
    action("boss", function()
        boss_hidden = not boss_hidden
        if boss_hidden then
            mp.set_property_bool("pause", true)
            mp.set_property_bool("window-minimized", true)
        else
            mp.set_property_bool("window-minimized", false)
            mp.set_property_bool("pause", false)
        end
    end)

    -- 캡처 / 녹화
    action("shot-clipboard", function()
        local dir = state.dir or os.getenv("TEMP") or "."
        local file = dir .. "/clipboard.png"
        mp.commandv("screenshot-to-file", file, "video")
        local script = "Add-Type -AssemblyName System.Windows.Forms,System.Drawing; " ..
            "$i=[System.Drawing.Image]::FromFile('" .. file:gsub("'", "''") .. "'); " ..
            "[System.Windows.Forms.Clipboard]::SetImage($i); $i.Dispose()"
        mp.command_native_async({
            name = "subprocess",
            playback_only = false,
            args = { "powershell", "-NoProfile", "-STA", "-WindowStyle", "Hidden", "-Command", script },
        }, function(ok, res)
            osd((ok and res and res.status == 0) and "화면을 클립보드에 복사했습니다"
                or "클립보드 복사 실패")
        end)
    end)
    action("record", function()
        if (mp.get_property("stream-record") or "") ~= "" then
            mp.set_property("stream-record", "")
            osd("녹화 중지")
            return
        end
        local dest = mp.command_native({ "expand-path", "~~desktop/" }) ..
            "record-" .. os.date("%Y%m%d-%H%M%S") .. ".mkv"
        mp.set_property("stream-record", dest)
        osd("녹화 시작\n" .. dest, 2.5)
    end)

    -- 재생목록 저장/불러오기
    action("save-m3u", function()
        local list = mp.get_property_native("playlist") or {}
        if #list == 0 then
            osd("재생목록이 비어 있습니다")
            return
        end
        local path = mp.command_native({ "expand-path", "~~desktop/" }) ..
            "playlist-" .. os.date("%Y%m%d-%H%M%S") .. ".m3u8"
        local f = io.open(path, "wb")
        if not f then
            osd("저장 실패")
            return
        end
        f:write("#EXTM3U\n")
        for _, e in ipairs(list) do
            f:write(e.filename, "\n")
        end
        f:close()
        osd("재생목록 저장\n" .. path, 2.5)
    end)

    -- 기타
    action("stop", function() mp.command("stop") end)
    action("reopen", function()
        local path = mp.get_property("path")
        if path then mp.commandv("loadfile", path, "replace") end
    end)
    action("reload-sub", function()
        mp.command("rescan-external-files")
        osd("자막을 다시 찾았습니다")
    end)
    action("open-config", function()
        mp.command_native_async({
            name = "subprocess",
            playback_only = false,
            detach = true,
            args = { "explorer.exe", mp.command_native({ "expand-path", "~~/" }) },
        }, function() end)
    end)
    action("about", function()
        osd((mp.get_property("mpv-version") or "mpv") ..
            "\nboda · 팟플레이어 스타일 단축키\n설정: " .. (state.dir or ""), 4)
    end)
    mp.register_script_message("boda-na", function(what)
        osd((what or "이 기능") .. "은(는) mpv에 없습니다")
    end)

    mp.register_event("file-loaded", function()
        eq_off = false
        mp.add_timeout(0.3, function() apply_auto_color(false) end)
    end)
end

return M
