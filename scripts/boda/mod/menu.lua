-- 우클릭 메뉴.
--
-- mpv 0.41 은 menu-data 속성에 메뉴 트리를 넣고 context-menu 명령을 부르면
-- 윈도우 기본 메뉴로 띄워준다. 하위 메뉴·체크 표시·단축키 표기·키보드 이동이
-- 전부 따라오므로 직접 그리지 않는다.
-- 그 기능이 없는 환경에서는 mp.input.select 로 같은 트리를 단계별로 보여준다.
local mp = require("mp")
local util = require("lib.util")
local ui = require("lib.ui")
local opts = require("lib.options")
local state = require("lib.state")

local M = {}

local has_input, input = pcall(require, "mp.input")
local native_ok = nil -- nil = 아직 모름

-- ── 트리 만들기 도우미 ──────────────────────────────────────────────
local SEP = { type = "separator" }

local function item(title, cmd, o)
    o = o or {}
    local st = {}
    if o.checked then st[#st + 1] = "checked" end
    if o.disabled then st[#st + 1] = "disabled" end
    return { title = title, cmd = cmd, shortcut = o.key, state = st }
end

local function submenu(title, items, o)
    o = o or {}
    if #items == 0 then
        items = { item("(없음)", "", { disabled = true }) }
        o.disabled = true
    end
    return {
        type = "submenu",
        title = title,
        submenu = items,
        state = o.disabled and { "disabled" } or {},
    }
end

local function bind(name) return "script-binding boda/" .. name end

local function message(name, ...)
    local parts = { "script-message", "boda-" .. name }
    for _, v in ipairs({ ... }) do parts[#parts + 1] = tostring(v) end
    return table.concat(parts, " ")
end

local function has_file()
    return mp.get_property("path") ~= nil
end

local function near(a, b)
    return a and b and math.abs(a - b) < 0.01
end

-- ── 조각들 ──────────────────────────────────────────────────────────
local function tracks_of(kind, prop)
    local items = {}
    local cur = mp.get_property(prop)
    if kind == "sub" then
        items[#items + 1] = item("끄기", "set sid no", { checked = cur == "no" })
    end
    for _, tr in ipairs(mp.get_property_native("track-list") or {}) do
        if tr.type == kind then
            local label = tr.title or tr.codec or ("트랙 " .. tostring(tr.id))
            if tr.lang then label = "[" .. tr.lang .. "] " .. label end
            if tr.external then label = label .. "  (외부)" end
            items[#items + 1] = item(label, "set " .. prop .. " " .. tostring(tr.id),
                { checked = tr.selected })
        end
    end
    return items
end

local function audio_devices()
    local items = {}
    local cur = mp.get_property("audio-device")
    for _, d in ipairs(mp.get_property_native("audio-device-list") or {}) do
        items[#items + 1] = item(d.description or d.name,
            string.format('set audio-device "%s"', d.name), { checked = d.name == cur })
        if #items >= 12 then break end
    end
    return items
end

local function recent_folders()
    local items = {}
    for i, dir in ipairs(state.recent or {}) do
        items[#items + 1] = item(dir, message("open-recent", i))
        if i >= 8 then break end
    end
    return items
end

local function history_items()
    local items = {}
    for i, h in ipairs(state.history or {}) do
        local pct = (h.dur and h.dur > 0) and math.floor((h.pos or 0) / h.dur * 100) or 0
        items[#items + 1] = item(string.format("%s  (%d%%)", util.basename(h.path), pct),
            message("play-history", i))
        if i >= 8 then break end
    end
    return items
end

-- 재생목록은 길 수 있으니 현재 위치 주변만 보여준다.
local function playlist_items()
    local pl = mp.get_property_native("playlist") or {}
    local cur = (mp.get_property_number("playlist-pos") or 0) + 1
    local first = math.max(1, cur - 10)
    local last = math.min(#pl, first + 29)
    local items = {}
    for i = first, last do
        local e = pl[i]
        items[#items + 1] = item(util.basename(e.title or e.filename),
            "playlist-play-index " .. (i - 1), { checked = e.current })
    end
    if #pl > last then
        items[#items + 1] = item(string.format("… 그 밖에 %d개 (F6 으로 목록 열기)", #pl - last),
            bind("panel-pl"))
    end
    return items
end

local function sort_items()
    local defs = {
        { "none", "기본 순서" }, { "name", "이름" }, { "size", "크기" },
        { "quality", "화질" }, { "duration", "길이" }, { "mtime", "날짜" },
    }
    local items = {}
    for _, d in ipairs(defs) do
        local on = state.prefs.sort == d[1]
        local label = d[2]
        if on and d[1] ~= "none" then
            label = label .. (state.prefs.sort_desc and "  ↓" or "  ↑")
        end
        items[#items + 1] = item(label, message("sort", d[1]), { checked = on })
    end
    return items
end

local function favorite_items()
    local path = mp.get_property("path")
    local items = {}
    for i, f in ipairs(state.favorites_of(path)) do
        local label = f.name or ("구간 " .. i)
        if f.b then
            label = string.format("%s  (%s ~ %s)", label, util.fmt_time(f.a), util.fmt_time(f.b))
        else
            label = string.format("%s  (%s)", label, util.fmt_time(f.a))
        end
        items[#items + 1] = submenu(label, {
            item("이 지점으로", message("favorite-play", i)),
            item("구간 반복", message("favorite-loop", i), { disabled = not f.b }),
            item("삭제", message("favorite-remove", i)),
        })
        if i >= 20 then break end
    end
    return items
end

local function chapter_items()
    local items = {}
    local cur = mp.get_property_number("chapter") or -1
    for i, ch in ipairs(mp.get_property_native("chapter-list") or {}) do
        items[#items + 1] = item(ch.title or ("챕터 " .. i), "set chapter " .. (i - 1),
            { checked = (i - 1) == cur })
        if i >= 30 then break end
    end
    local path = mp.get_property("path")
    local marks = state.bookmarks_of(path)
    if #marks > 0 then
        items[#items + 1] = SEP
        for i, sec in ipairs(marks) do
            items[#items + 1] = item(string.format("북마크 %d  (%s)", i, util.fmt_time(sec)),
                "seek " .. string.format("%.3f", sec) .. " absolute")
            if i >= 20 then break end
        end
    end
    return items
end

local function speed_items()
    local cur = mp.get_property_number("speed") or 1
    local items = {}
    for _, v in ipairs({ 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2 }) do
        items[#items + 1] = item(string.format("%.2fx", v), "set speed " .. v,
            { checked = near(cur, v) })
    end
    items[#items + 1] = SEP
    items[#items + 1] = item("느리게", bind("speed-down"), { key = "X" })
    items[#items + 1] = item("빠르게", bind("speed-up"), { key = "C" })
    items[#items + 1] = item("되돌리기", bind("speed-toggle"), { key = "Z" })
    return items
end

local function vf_on(label)
    return (mp.get_property("vf") or ""):find("@" .. label, 1, true) ~= nil
end

local function af_on(label)
    return (mp.get_property("af") or ""):find("@" .. label, 1, true) ~= nil
end

local function aspect_items()
    local cur = mp.get_property("video-aspect-override") or "-1"
    local defs = { { "-1", "원본" }, { "16:9", "16:9" }, { "4:3", "4:3" },
        { "2.35:1", "2.35:1" }, { "1.85:1", "1.85:1" } }
    local items = {}
    for _, d in ipairs(defs) do
        items[#items + 1] = item(d[2], "set video-aspect-override " .. d[1],
            { checked = tostring(cur):find(d[1], 1, true) ~= nil })
    end
    return items
end

-- ── 구역별 묶음 ─────────────────────────────────────────────────────
local sections = {}

sections.open = function(out)
    out[#out + 1] = submenu("열기", {
        item("파일…", bind("open-file"), { key = "F3" }),
        item("폴더…", bind("open-folder"), { key = "F2" }),
        item("URL / 경로 입력…", bind("open-url"), { key = "Ctrl+U" }),
        item("클립보드 주소 열기", bind("open-clipboard"), { key = "Ctrl+V" }),
        SEP,
        submenu("최근 폴더", recent_folders()),
        item("지금 파일 다시 열기", bind("reopen"), { key = "Ctrl+Y", disabled = not has_file() }),
    })
end

sections.resume = function(out)
    out[#out + 1] = submenu("이어서 보기", history_items())
end

sections.playlist = function(out)
    out[#out + 1] = submenu("재생목록", {
        submenu("항목", playlist_items()),
        submenu("정렬", sort_items()),
        SEP,
        item("목록 패널 열기", bind("panel-pl"), { key = "F6" }),
        item("재생목록 저장", bind("save-m3u"), { key = "Ctrl+Shift+M" }),
        item("재생목록 열기…", bind("load-m3u"), { key = "Ctrl+Shift+O" }),
        item("이 항목 빼기", bind("playlist-remove"), { key = "Del", disabled = not has_file() }),
    })
end

sections.fav = function(out)
    out[#out + 1] = submenu("즐겨찾기", {
        item("지금 구간 담기", bind("favorite-add"), { key = "Insert", disabled = not has_file() }),
        item("[ 구간 시작", bind("ab-a"), { key = "[", disabled = not has_file() }),
        item("] 구간 끝", bind("ab-b"), { key = "]", disabled = not has_file() }),
        SEP,
        submenu("담아둔 구간", favorite_items()),
        item("이 영상 즐겨찾기 비우기", bind("favorite-clear"), { disabled = not has_file() }),
    })
end

sections.chapter = function(out)
    out[#out + 1] = submenu("챕터 · 북마크", {
        submenu("이동", chapter_items()),
        SEP,
        item("지금 위치 북마크", bind("bookmark-add"), { key = "P", disabled = not has_file() }),
        item("이전 북마크", bind("bookmark-prev"), { key = "Shift+PgUp" }),
        item("다음 북마크", bind("bookmark-next"), { key = "Shift+PgDn" }),
    })
end

sections.speed = function(out)
    out[#out + 1] = submenu("속도", speed_items())
end

sections.loop = function(out)
    local a = mp.get_property("ab-loop-a")
    local b = mp.get_property("ab-loop-b")
    out[#out + 1] = submenu("구간 반복", {
        item("A 지점", bind("ab-a"), { key = "[" }),
        item("B 지점", bind("ab-b"), { key = "]" }),
        item("해제", bind("ab-clear"), { disabled = (a == "no" and b == "no") }),
        SEP,
        item("이 구간 즐겨찾기에 담기", bind("favorite-add"), { key = "Insert" }),
        item("파일 반복", "cycle-values loop-file inf no",
            { checked = tostring(mp.get_property("loop-file")) ~= "no" }),
        item("목록 반복", "cycle-values loop-playlist inf no",
            { checked = tostring(mp.get_property("loop-playlist")) ~= "no" }),
    })
end

sections.skip = function(out)
    local skip = state.skip_of(mp.get_property("path"))
    out[#out + 1] = submenu("건너뛰기", {
        item("여기까지가 오프닝", bind("mark-intro"), { key = "Ctrl+I" }),
        item("여기부터 엔딩", bind("mark-outro"), { key = "Ctrl+O" }),
        item("이 영상 설정 지우기", bind("clear-skip"), { key = "Ctrl+Shift+I", disabled = skip == nil }),
    })
end

sections.video = function(out)
    out[#out + 1] = submenu("영상", {
        submenu("트랙", tracks_of("video", "vid")),
        submenu("화면 비율", aspect_items()),
        SEP,
        item("좌우 반전", bind("flip-h"), { key = "Ctrl+Z", checked = vf_on("hflip") }),
        item("상하 반전", bind("flip-v"), { key = "Ctrl+P", checked = vf_on("vflip") }),
        item("90도 회전", bind("rotate"), { key = "Alt+K" }),
        SEP,
        submenu("화질 보정", {
            item("선명 업스케일", bind("upscale-toggle"),
                { key = "F9", checked = mp.get_property("scale") == "ewa_lanczossharp" }),
            item("샤픈", bind("sharpen"), { key = "Ctrl+R", checked = vf_on("sharp") }),
            item("블러", bind("blur"), { key = "Ctrl+B", checked = vf_on("blur") }),
            item("노이즈 감소", bind("denoise"), { key = "Ctrl+N", checked = vf_on("dn") }),
            item("디블록", bind("deblock"), { key = "Ctrl+H", checked = vf_on("deblock") }),
            item("디인터레이스", "cycle deinterlace",
                { key = "Ctrl+Shift+D", checked = mp.get_property("deinterlace") == "yes" }),
            SEP,
            item("영상 필터 모두 해제", bind("filters-clear"), { key = "Ctrl+Alt+F" }),
        }),
    }, { disabled = not has_file() })
end

sections.audio = function(out)
    out[#out + 1] = submenu("소리", {
        submenu("트랙", tracks_of("audio", "aid")),
        submenu("출력 장치", audio_devices()),
        SEP,
        item("음소거", "cycle mute", { key = "M", checked = mp.get_property_bool("mute") }),
        item("음량 평준화", bind("audio-norm"), { key = "N", checked = af_on("norm") }),
        item("좌우 채널 교환", bind("stereo-swap"), { key = "T", checked = af_on("swap") }),
        item("보컬 제거 시도", bind("voice-remove"),
            { key = "Ctrl+Shift+V", checked = af_on("voice") }),
        SEP,
        item("싱크 당기기 (-0.05초)", "add audio-delay -0.05", { key = "<" }),
        item("싱크 미루기 (+0.05초)", "add audio-delay 0.05", { key = ">" }),
        item("소리 설정 초기화", bind("audio-reset"), { key = "Ctrl+Alt+N" }),
    })
end

sections.sub = function(out)
    out[#out + 1] = submenu("자막", {
        submenu("트랙", tracks_of("sub", "sid")),
        item("자막 보이기", "cycle sub-visibility",
            { key = "Alt+H", checked = mp.get_property_bool("sub-visibility") }),
        SEP,
        item("자막 파일 열기…", bind("open-sub"), { key = "Alt+O" }),
        item("자막 다시 찾기", bind("reload-sub"), { key = "Ctrl+Alt+Y" }),
        item("듀얼 자막", bind("dual-sub"), { key = "F8" }),
        SEP,
        item("크게", "add sub-font-size 2", { key = "Alt+PgUp" }),
        item("작게", "add sub-font-size -2", { key = "Alt+PgDn" }),
        item("싱크 당기기 (-0.5초)", "add sub-delay -0.5", { key = "," }),
        item("싱크 미루기 (+0.5초)", "add sub-delay 0.5", { key = "." }),
        item("싱크 초기화", "set sub-delay 0", { key = "/" }),
    })
end

sections.color = function(out)
    out[#out + 1] = submenu("색감", {
        item("색감 패널 열기", bind("panel-color"), { key = "F7" }),
        item("자동 보정", bind("auto-color-toggle"),
            { key = "Ctrl+Alt+A", checked = state.prefs.auto_color == true }),
        item("원본과 비교 (껐다 켜기)", bind("eq-toggle"), { key = "Q" }),
        item("초기화", bind("eq-reset"), { key = "Ctrl+Alt+R" }),
        SEP,
        item("밝기 +", "add brightness 1", { key = "E" }),
        item("밝기 −", "add brightness -1", { key = "W" }),
        item("대비 +", "add contrast 1", { key = "T" }),
        item("대비 −", "add contrast -1", { key = "R" }),
        item("채도 +", "add saturation 1", { key = "U" }),
        item("채도 −", "add saturation -1", { key = "Y" }),
    })
end

sections.window = function(out)
    out[#out + 1] = submenu("창", {
        item("전체화면", "cycle fullscreen",
            { key = "Enter", checked = mp.get_property_bool("fullscreen") }),
        item("항상 위", "cycle ontop", { key = "Ctrl+T", checked = mp.get_property_bool("ontop") }),
        item("PiP (작게 + 항상 위)", bind("pip"), { key = "F10" }),
        SEP,
        item("0.5배", message("window-scale", 0.5), { key = "Alt+1" }),
        item("1배", message("window-scale", 1), { key = "Alt+2" }),
        item("1.5배", message("window-scale", 1.5), { key = "Alt+3" }),
        item("2배", message("window-scale", 2), { key = "Alt+4" }),
        item("최대화", bind("window-max"), { key = "Alt+5" }),
    })
end

sections.capture = function(out)
    out[#out + 1] = submenu("캡처 · 녹화", {
        item("화면 저장 (자막 포함)", "screenshot", { key = "Ctrl+S" }),
        item("원본 그대로 저장", "screenshot video", { key = "K" }),
        item("보이는 대로 저장", "screenshot window", { key = "Alt+N" }),
        item("클립보드로 복사", bind("shot-clipboard"), { key = "Ctrl+C" }),
        SEP,
        item("녹화 시작 / 중지", bind("record"), { key = "Ctrl+Shift+R" }),
    }, { disabled = not has_file() })
end

sections.copy = function(out)
    out[#out + 1] = submenu("복사", {
        item("파일 경로", "set clipboard/text ${path}"),
        item("파일 이름", "set clipboard/text ${filename}"),
        item("제목", "set clipboard/text ${media-title}"),
        item("현재 시간", "set clipboard/text ${time-pos}"),
        item("지금 자막 문장", "set clipboard/text ${sub-text}"),
    }, { disabled = not has_file() })
end

sections.panel = function(out)
    out[#out + 1] = submenu("패널", {
        item("재생목록", bind("panel-pl"), { key = "F6" }),
        item("오디오", bind("panel-audio"), { key = "A" }),
        item("자막", bind("panel-sub"), { key = "L" }),
        item("비디오", bind("panel-video"), { key = "V" }),
        item("챕터", bind("panel-chapter"), { key = "H" }),
        item("즐겨찾기", bind("panel-fav"), { key = "Ctrl+Insert" }),
        item("색감", bind("panel-color"), { key = "F7" }),
    })
end

sections.settings = function(out)
    out[#out + 1] = submenu("설정 · 정보", {
        item("설정 폴더 열기", bind("open-config"), { key = "F5" }),
        item("재생 통계", "script-binding stats/display-stats-toggle", { key = "Ctrl+F1" }),
        item("콘솔", "script-binding console/enable", { key = "Ctrl+F12" }),
        SEP,
        item("boda 정보", bind("about"), { key = "F1" }),
    })
end

local DEFAULT_ORDER = {
    "open", "resume", "-", "playlist", "fav", "chapter", "-",
    "speed", "loop", "skip", "-", "video", "audio", "sub", "color", "-",
    "window", "capture", "copy", "-", "panel", "settings",
}

local function wanted_order()
    local conf = tostring(opts.menu_sections or ""):gsub("%s", "")
    if conf == "" then return DEFAULT_ORDER end
    local out = {}
    for name in conf:gmatch("[^,]+") do out[#out + 1] = name end
    return out
end

-- ── 상황별 메뉴 ─────────────────────────────────────────────────────
local function main_menu()
    local paused = mp.get_property_bool("pause")
    local out = {
        item(paused and "재생" or "일시정지", "cycle pause", { key = "Space", disabled = not has_file() }),
        item("정지", "stop", { key = "F4", disabled = not has_file() }),
        item("이전 파일", "playlist-prev", { key = "PgUp" }),
        item("다음 파일", "playlist-next", { key = "PgDn" }),
        SEP,
    }
    for _, name in ipairs(wanted_order()) do
        if name == "-" then
            out[#out + 1] = SEP
        elseif sections[name] then
            sections[name](out)
        end
    end
    out[#out + 1] = SEP
    out[#out + 1] = item("종료", "quit", { key = "Alt+F4" })
    return out
end

-- 목록 패널 위에서 누른 경우: 그 줄에 대한 메뉴
local function playlist_menu(index)
    local pl = mp.get_property_native("playlist") or {}
    local e = pl[index + 1]
    local name = e and util.basename(e.title or e.filename) or "항목"
    return {
        item(name, "", { disabled = true }),
        SEP,
        item("재생", "playlist-play-index " .. index),
        item("목록에서 빼기", "playlist-remove " .. index),
        SEP,
        submenu("정렬", sort_items()),
        item("폴더 열기…", bind("open-folder"), { key = "F2" }),
        item("재생목록 저장", bind("save-m3u")),
        SEP,
        item("패널 닫기", bind("panel-toggle"), { key = "F6" }),
    }
end

local function idle_menu()
    return {
        item("파일 열기…", bind("open-file"), { key = "F3" }),
        item("폴더 열기…", bind("open-folder"), { key = "F2" }),
        item("URL / 경로 입력…", bind("open-url"), { key = "Ctrl+U" }),
        item("클립보드 주소 열기", bind("open-clipboard"), { key = "Ctrl+V" }),
        SEP,
        submenu("이어서 보기", history_items()),
        submenu("최근 폴더", recent_folders()),
        SEP,
        item("설정 폴더 열기", bind("open-config"), { key = "F5" }),
        item("종료", "quit", { key = "Alt+F4" }),
    }
end

-- 커서 위치로 어떤 메뉴를 띄울지 고른다.
local function pick_menu()
    if not has_file() then return idle_menu(), "idle" end
    local x, y = ui.mouse_pos()
    if x then
        local r = ui.region_at(x, y)
        local id = r and r.id or ""
        local row = id:match("^panel/row(%d+)$")
        if row then
            local info = mp.get_property_native("user-data/boda/panel") or {}
            if info.tab == "pl" then
                return playlist_menu((info.scroll or 0) + tonumber(row) - 1), "playlist"
            end
        end
    end
    return main_menu(), "main"
end

-- ── 내장 메뉴가 없을 때 (mp.input.select 로 대체) ───────────────────
local function show_fallback(items, title)
    if not (has_input and input and input.select) then
        mp.osd_message("이 환경에서는 우클릭 메뉴를 쓸 수 없습니다", 2)
        return
    end
    local labels, acts = {}, {}
    for _, it in ipairs(items) do
        if it.type ~= "separator" then
            local disabled = false
            for _, s in ipairs(it.state or {}) do
                if s == "disabled" then disabled = true end
            end
            local mark = ""
            for _, s in ipairs(it.state or {}) do
                if s == "checked" then mark = "● " end
            end
            if not disabled then
                if it.type == "submenu" then
                    labels[#labels + 1] = mark .. it.title .. "  ▸"
                    acts[#acts + 1] = { sub = it.submenu, title = it.title }
                else
                    labels[#labels + 1] = mark .. it.title
                    acts[#acts + 1] = { cmd = it.cmd }
                end
            end
        end
    end
    if #labels == 0 then return end
    input.select({
        prompt = title or "메뉴",
        items = labels,
        default_item = 1,
        submit = function(i)
            local a = acts[i]
            if not a then return end
            if a.sub then
                show_fallback(a.sub, a.title)
            elseif a.cmd and a.cmd ~= "" then
                mp.command(a.cmd)
            end
        end,
    })
end

-- ── 띄우기 ──────────────────────────────────────────────────────────
local function show()
    local items, kind = pick_menu()
    M.last_kind = kind
    M.last_items = items
    if native_ok ~= false then
        local ok = pcall(mp.set_property_native, "menu-data", items)
        if ok then
            local res = mp.command_native({ "context-menu" })
            if res ~= nil or native_ok == true then
                native_ok = true
                return
            end
            -- 명령이 실패하면 아래 대체 방식으로 간다
            native_ok = false
        else
            native_ok = false
        end
    end
    show_fallback(items, "메뉴")
end

function M.init()
    mp.add_key_binding(nil, "menu", show)
    mp.register_script_message("boda-menu", show)

    -- 테스트·디버깅용: 메뉴를 띄우지 않고 트리만 만들어 속성으로 내보낸다.
    -- (실제로 context-menu 를 부르면 창이 뜨고 사용자가 닫을 때까지 멈춘다)
    mp.register_script_message("boda-menu-build", function(which)
        local items, kind
        if which == "idle" then
            items, kind = idle_menu(), "idle"
        elseif which == "playlist" then
            local info = mp.get_property_native("user-data/boda/panel") or {}
            items, kind = playlist_menu(info.scroll or 0), "playlist"
        elseif which == "auto" then
            items, kind = pick_menu()
        else
            items, kind = main_menu(), "main"
        end
        pcall(mp.set_property_native, "menu-data", items)
        -- menu-data 는 mpv 기본 메뉴가 다시 쓸 수 있으므로, 확인용으로 우리 트리도 따로 둔다
        pcall(mp.set_property_native, "user-data/boda/menu",
            { kind = kind, count = #items, tree = items })
    end)

    -- 내장 메뉴가 없는 환경에서 쓰는 대체 방식만 따로 띄워본다
    mp.register_script_message("boda-menu-fallback", function()
        local items = select(1, pick_menu())
        show_fallback(items, "메뉴")
    end)
end

return M
