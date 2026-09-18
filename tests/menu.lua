-- boda 우클릭 메뉴 테스트
--
-- 메뉴를 실제로 띄우면(context-menu) 사용자가 닫을 때까지 멈추므로,
-- 여기서는 트리를 만들어 menu-data 에 넣는 데까지만 확인한다.
--
--   mpv --script=tests/menu.lua --script-opts=boda-state_dir=<임시폴더> <영상>
--
-- 구성 설정 확인까지 하려면 아래도 함께 준다:
--   --script-opts=boda-state_dir=<임시폴더>,boda-menu_sections=open,fav,-,settings

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
        log(string.format("RESULT %d 통과 / %d 실패", pass, fail))
        mp.commandv("quit", fail == 0 and 0 or 1)
        return
    end
    local ok, err = pcall(s.fn)
    if not ok then
        fail = fail + 1
        log("FAIL  단계 " .. qi .. " 예외: " .. tostring(err))
    end
    mp.add_timeout(s.d, run_next)
end

local function build(which)
    mp.commandv("script-message", "boda-menu-build", which or "main")
end

local function meta() return mp.get_property_native("user-data/boda/menu") or {} end
-- menu-data 는 mpv 기본 메뉴가 덮어쓸 수 있어서, boda 가 따로 내보낸 트리를 본다
local function tree() return meta().tree or {} end

-- 트리에서 제목으로 항목 찾기 (하위까지 훑는다)
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

-- 명령이 비어 있지 않은지, 하위 메뉴가 비어 있지 않은지 훑는다
local function validate(items, path, problems)
    for _, it in ipairs(items or {}) do
        local where = (path or "") .. "/" .. tostring(it.title or it.type)
        if it.type == "submenu" then
            if #(it.submenu or {}) == 0 then problems[#problems + 1] = where .. " (빈 하위메뉴)" end
            validate(it.submenu, where, problems)
        elseif it.type ~= "separator" then -- 구분선은 확인할 것이 없다
            local disabled = has_state(it, "disabled")
            if (not it.cmd or it.cmd == "") and not disabled then
                problems[#problems + 1] = where .. " (명령 없음)"
            end
        end
    end
end

-- ── 1차: 기본 트리와 상태 ───────────────────────────────────────────
step(0.8, function()
    log("[1차] 메뉴 트리")
    mp.set_property_bool("pause", false)
    build("main")
end)

step(0.6, function()
    saved.custom = (mp.get_opt("boda-menu_sections") or "") ~= ""
    local t = tree()
    saved.total = count_all(t)
    check("메뉴가 만들어진다", #t > 8, "최상위 " .. #t .. "개")
    check("메타 정보가 나온다", meta().kind == "main", tostring(meta().kind))
    if not saved.custom then
        check("항목이 충분히 들어 있다", saved.total > 80, "전체 " .. saved.total .. "개")
        local want = { "열기", "재생목록", "즐겨찾기", "챕터 · 북마크", "속도", "구간 반복",
            "건너뛰기", "영상", "소리", "자막", "색감", "창", "캡처 · 녹화", "복사", "패널", "설정 · 정보" }
        local missing = {}
        for _, name in ipairs(want) do
            if not find(t, name) then missing[#missing + 1] = name end
        end
        check("필요한 묶음이 모두 있다", #missing == 0, table.concat(missing, ", "))
    end

    local problems = {}
    validate(t, "", problems)
    check("빈 명령·빈 하위메뉴가 없다", #problems == 0, table.concat(problems, " | "))
end)

-- 상태(체크/비활성)가 실제 값과 맞는지
step(0.3, function()
    mp.set_property_bool("pause", true)
    build("main")
end)

step(0.5, function()
    check("일시정지 중에는 첫 항목이 '재생'", titles(tree())[1] == "재생", titles(tree())[1])
    mp.set_property_bool("pause", false)
    mp.set_property_number("speed", 1.5)
    mp.set_property_bool("mute", true)
    build("main")
end)

step(0.5, function()
    local t = tree()
    check("재생 중에는 첫 항목이 '일시정지'", titles(t)[1] == "일시정지", titles(t)[1])
    if not saved.custom then
        check("현재 속도에 체크가 붙는다", has_state(find(t, "1.50x"), "checked"))
        check("음소거 상태가 체크로 보인다", has_state(find(t, "음소거"), "checked"))
    end
    mp.set_property_number("speed", 1)
    mp.set_property_bool("mute", false)
end)

step(0.3, function()
    mp.commandv("script-message", "boda-blur") -- 필터 하나 켜기
end)

step(0.6, function()
    build("main")
end)

step(0.6, function()
    if not saved.custom then
        check("켜둔 영상 필터가 체크로 보인다", has_state(find(tree(), "블러"), "checked"),
            "vf=" .. tostring(mp.get_property("vf")))
    end
    mp.commandv("script-message", "boda-blur") -- 되돌리기
end)

-- ── 2차: 상황별 메뉴 ────────────────────────────────────────────────
step(0.6, function()
    log("[2차] 상황별 메뉴")
    build("auto")
end)

step(0.5, function()
    check("영상 위에서는 기본 메뉴", meta().kind == "main", tostring(meta().kind))
    mp.commandv("script-message", "boda-panel", "pl")
end)

step(0.8, function()
    -- 목록의 한 줄 위로 커서를 옮긴다
    local n = mp.get_property_native("user-data/boda/panel") or {}
    saved.row_index = (n.scroll or 0) + 2
    mp.commandv("mouse", math.floor(n.x0 + 40), math.floor(n.top + 1.5 * n.row_h))
end)

step(0.6, function()
    build("auto")
end)

step(0.6, function()
    local t = tree()
    check("목록 위에서는 그 줄에 대한 메뉴", meta().kind == "playlist", tostring(meta().kind))
    saved.playlist_menu_seen = meta().kind == "playlist" 
    check("재생·빼기 항목이 있다", find(t, "재생") ~= nil and find(t, "목록에서 빼기") ~= nil)
    check("정렬 하위메뉴가 붙는다", find(t, "정렬") ~= nil)
    check("항목 수가 기본 메뉴보다 적다", count_all(t) < saved.total,
        count_all(t) .. " vs " .. saved.total)
    build("auto-key") -- 커서는 목록 위에 그대로 두고 키로 부른 상황
end)

step(0.6, function()
    check("키(F4)로 부르면 커서가 목록 위여도 기본 메뉴",
        meta().kind == "main", tostring(meta().kind))
    mp.commandv("script-message", "boda-panel", "toggle")
    mp.commandv("mouse", 60, 200) -- 영상 위로
end)

step(0.6, function()
    build("auto")
    saved.was_playing = true
end)

step(0.5, function()
    check("패널을 닫으면 다시 기본 메뉴", meta().kind == "main", tostring(meta().kind))
    mp.command("stop")
end)

step(1.2, function()
    build("auto")
end)

step(0.6, function()
    local t = tree()
    check("파일이 없을 때는 대기 화면 메뉴", meta().kind == "idle", tostring(meta().kind))
    check("열기 항목이 앞에 있다", titles(t)[1] == "파일 열기…", tostring(titles(t)[1]))
    check("대기 메뉴는 짧다", #t < 12, "최상위 " .. #t .. "개")
end)

-- ── 3차: 구성 설정과 대체 방식 ──────────────────────────────────────
step(0.4, function()
    log("[3차] 구성 설정 / 대체 방식")
    local conf = mp.get_opt("boda-menu_sections")
    saved.conf = conf
    build("main")
end)

step(0.6, function()
    local t = tree()
    if saved.conf and saved.conf ~= "" then
        check("설정한 묶음만 나온다", find(t, "열기") ~= nil and find(t, "영상") == nil,
            table.concat(titles(t), ", "))
    else
        check("설정을 비우면 기본 구성", find(t, "영상") ~= nil, "menu_sections 미지정")
    end
end)

step(0.4, function()
    -- 내장 메뉴가 없는 환경에서 쓰는 목록 방식을 띄워본다
    mp.commandv("script-message", "boda-menu-fallback")
end)

step(1.0, function()
    local console = mp.get_property_native("user-data/mpv/console") or {}
    check("대체 방식(목록)이 뜬다", console.open == true, "open=" .. tostring(console.open))
    mp.commandv("keypress", "ESC")
end)

step(0.8, function()
    local console = mp.get_property_native("user-data/mpv/console") or {}
    check("ESC 로 닫힌다", console.open == false, "open=" .. tostring(console.open))
end)

mp.register_event("file-loaded", function()
    if qi == 0 then mp.add_timeout(0.6, run_next) end
end)
