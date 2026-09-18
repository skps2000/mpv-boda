-- boda 패널 조작 테스트
--
-- 실제 마우스 이동·클릭·드래그·휠을 흉내내서 패널이 제대로 반응하는지 확인한다.
-- 창이 있어야 하므로 headless 로는 돌지 않는다. 실행 방법은 tests/README.md 참고.
--
--   mpv --script=tests/panel-ui.lua --script-opts=boda-state_dir=<임시폴더> <영상 폴더의 첫 파일>
--
-- 영상은 30개 이상 들어 있는 폴더로 시험해야 스크롤 관련 항목이 의미가 있다.

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

local function info() return mp.get_property_native("user-data/boda/panel") or {} end
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

-- 누른 채로 끌기. 사람 손처럼 시간 간격을 둬야 한다
-- (한 번에 몰아 보내면 mpv 가 순서대로 처리하기 전에 끝나버린다).
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
        log(string.format("RESULT %d 통과 / %d 실패", pass, fail))
        mp.commandv("quit", fail == 0 and 0 or 1)
        return
    end
    local ok, err = pcall(s.fn)
    if not ok then
        fail = fail + 1
        log("FAIL  단계 " .. qi .. " 예외: " .. tostring(err))
    end
    mp.add_timeout(s.delay, run_next)
end

-- ── 1. 정주행: 재생 중 목록 스크롤 ──────────────────────────────────
step(0.6, function()
    log("[1] 재생 중 목록 스크롤")
    mp.set_property_bool("pause", false)
    mp.commandv("script-message", "boda-panel", "pl")
end)

step(0.5, function()
    local n = info()
    check("패널이 열린다", n.open == true, "open=" .. tostring(n.open))
    check("한 화면에 다 안 들어와 스크롤이 필요하다", (n.max_scroll or 0) > 0,
        "rows=" .. tostring(n.rows) .. " vis=" .. tostring(n.vis))
    saved.scroll0 = n.scroll
end)

step(0.4, function()
    local n = info()
    wheel(n.x0 + n.width / 2, n.oh / 2, -1, 5)
end)

step(0.5, function()
    local n = info()
    check("휠로 목록이 내려간다", n.scroll == (saved.scroll0 or 0) + 5, "scroll=" .. tostring(n.scroll))
    saved.scroll1 = n.scroll
end)

step(1.5, function()
    check("재생이 계속돼도 스크롤 위치가 유지된다", info().scroll == saved.scroll1,
        "scroll=" .. tostring(info().scroll))
end)

step(0.3, function()
    local n = info()
    wheel(n.x0 + n.width / 2, n.oh / 2, 1, 2)
end)

step(0.5, function()
    check("휠 위로도 움직인다", info().scroll == saved.scroll1 - 2, "scroll=" .. tostring(info().scroll))
end)

-- ── 2. 목록에서 다른 화 고르기 ──────────────────────────────────────
step(0.3, function()
    log("[2] 고르기와 재생")
    saved.pos0 = mp.get_property_number("playlist-pos")
    saved.target = info().scroll + 2
    local x, y = row_xy(3)
    click(x, y)
end)

step(0.6, function()
    check("한 번 클릭은 고르기만 한다", mp.get_property_number("playlist-pos") == saved.pos0,
        "pos=" .. tostring(mp.get_property_number("playlist-pos")))
    check("클릭해도 재생이 멈추지 않는다", mp.get_property_bool("pause") == false,
        "pause=" .. tostring(mp.get_property("pause")))
end)

step(0.3, function()
    local x, y = row_xy(3)
    dblclick(x, y)
end)

step(0.8, function()
    check("더블클릭하면 그 화가 재생된다", mp.get_property_number("playlist-pos") == saved.target,
        "pos=" .. tostring(mp.get_property_number("playlist-pos")))
    check("더블클릭이 일시정지로 새지 않는다", mp.get_property_bool("pause") == false,
        "pause=" .. tostring(mp.get_property("pause")))
    local n = info()
    local cur = (mp.get_property_number("playlist-pos") or 0) + 1
    check("재생 중인 항목이 화면 안에 보인다", cur > n.scroll and cur <= n.scroll + n.vis,
        "scroll=" .. tostring(n.scroll))
end)

-- ── 3. 커서 아래 줄 강조 ────────────────────────────────────────────
step(0.3, function()
    log("[3] 강조 표시")
    local x, y = row_xy(5)
    mouse(x, y)
end)

step(0.4, function()
    check("커서를 올리면 그 줄이 강조된다",
        tostring(info().hover):match("^panel/row%d+") ~= nil, tostring(info().hover))
    local n = info()
    wheel(n.x0 + n.width / 2, select(2, row_xy(5)), -1, 3)
end)

step(0.5, function()
    check("휠을 굴린 뒤에도 커서 아래 줄이 강조된다",
        tostring(info().hover):match("^panel/row%d+") ~= nil, tostring(info().hover))
end)

-- ── 4. 패널 너비 자유 조절 ──────────────────────────────────────────
step(0.3, function()
    log("[4] 너비 드래그")
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
    check("끈 만큼 넓어진다", math.abs(info().width - (saved.w0 + 200)) <= 8,
        "width=" .. tostring(info().width))
    saved.w1 = info().width
end)

drag_steps(function()
    local n = info()
    return { from = { n.x0, n.oh / 2 }, points = { { n.x0 + 60, n.oh / 2 }, { n.x0 + 130, n.oh / 2 } } }
end)

step(0.4, function()
    check("반대로 끌면 좁아진다", math.abs(info().width - (saved.w1 - 130)) <= 8,
        "width=" .. tostring(info().width))
end)

drag_steps(function()
    local n = info()
    return { from = { n.x0, n.oh / 2 }, points = { { 300, n.oh / 2 }, { 60, n.oh / 2 }, { -300, n.oh / 2 } } }
end)

step(0.4, function()
    local n = info()
    check("창 밖까지 끌어도 영상 자리가 남는다", n.width <= n.ow - 150,
        "width=" .. tostring(n.width) .. " ow=" .. tostring(n.ow))
    saved.w2 = n.width
    click(n.x0, n.oh / 2)
end)

step(0.5, function()
    check("가장자리를 그냥 누르면 정해진 너비로 바뀐다", info().width ~= saved.w2,
        "width=" .. tostring(info().width))
end)

-- ── 5. 스크롤바 끌기 ────────────────────────────────────────────────
step(0.3, function() log("[5] 스크롤바") end)

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
    check("스크롤바를 끝까지 끌면 목록 맨 아래", n.scroll == n.max_scroll,
        "scroll=" .. tostring(n.scroll) .. "/" .. tostring(n.max_scroll))
end)

-- ── 6. 탭 전환 ──────────────────────────────────────────────────────
step(0.3, function()
    log("[6] 탭")
    local n = info()
    local tw = (n.width - 12 * n.scale) / 6
    saved.tabx = {}
    for i = 1, 6 do saved.tabx[i] = n.x0 + 6 * n.scale + (i - 0.5) * tw end
    click(saved.tabx[2], 16 * n.scale)
end)

step(0.4, function()
    check("오디오 탭으로 바뀐다", info().tab == "audio", tostring(info().tab))
    click(saved.tabx[5], 16 * info().scale)
end)

step(0.4, function()
    check("챕터 탭으로 바뀐다", info().tab == "chapter", tostring(info().tab))
    -- 항목이 없는 탭에서 빈 곳을 눌러본다
    local n = info()
    saved.paused = mp.get_property_bool("pause")
    click(n.x0 + n.width / 2, n.oh * 0.6)
    dblclick(n.x0 + n.width / 2, n.oh * 0.6)
end)

step(0.5, function()
    check("패널 빈 곳을 눌러도 영상이 멈추지 않는다",
        mp.get_property_bool("pause") == saved.paused, "pause=" .. tostring(mp.get_property("pause")))
    click(saved.tabx[6], 16 * info().scale)
end)

step(0.4, function()
    check("색감 탭으로 바뀐다", info().tab == "color", tostring(info().tab))
    mp.set_property_number("brightness", 0)
end)

-- ── 7. 색감 슬라이더 ────────────────────────────────────────────────
drag_steps(function()
    local n = info()
    local s = n.scale
    local by = (34 * s + 6 * s) + 6 * s + 40 * s + 22 * s -- 첫 슬라이더 막대
    return {
        from = { n.x0 + n.width * 0.5, by },
        points = { { n.x0 + n.width * 0.7, by }, { n.x0 + n.width * 0.85, by } },
    }
end)

step(0.4, function()
    log("[7] 색감 슬라이더")
    check("슬라이더를 끌면 밝기가 올라간다", (mp.get_property_number("brightness") or 0) > 10,
        "brightness=" .. tostring(mp.get_property_number("brightness")))
    mp.set_property_number("brightness", 0)
    mp.commandv("script-message", "boda-panel", "pl")
end)

-- ── 8. 창 끌기 방지 ─────────────────────────────────────────────────
step(0.4, function()
    log("[8] 창 끌기")
    local n = info()
    mouse(n.x0 + n.width / 2, n.oh / 2)
end)

step(0.4, function()
    check("패널 위에서는 창 끌기가 꺼진다", mp.get_property_bool("window-dragging") == false,
        tostring(mp.get_property("window-dragging")))
    mouse(40, 200)
end)

step(0.4, function()
    check("영상 위에서는 창 끌기가 살아난다", mp.get_property_bool("window-dragging") == true,
        tostring(mp.get_property("window-dragging")))
end)

-- ── 9. 정렬 ─────────────────────────────────────────────────────────
step(0.3, function()
    log("[9] 정렬")
    local n = info()
    local bw = (n.width - 20 * n.scale) / 6
    saved.sortx = {}
    for i = 1, 6 do saved.sortx[i] = n.x0 + 10 * n.scale + (i - 0.5) * bw end
    click(saved.sortx[2], n.sort_top + 10 * n.scale) -- 이름
end)

step(0.8, function()
    local pl = mp.get_property_native("playlist") or {}
    local sorted = true
    for i = 2, #pl do
        if basename(pl[i - 1].filename) > basename(pl[i].filename) then sorted = false break end
    end
    check("이름 정렬이 순서대로 된다", sorted, basename(pl[1] and pl[1].filename))
    local cur = (mp.get_property_number("playlist-pos") or 0) + 1
    check("정렬해도 보던 파일이 그대로 현재 항목이다", pl[cur] and pl[cur].current == true,
        "pos=" .. tostring(cur - 1))
    click(saved.sortx[2], info().sort_top + 10 * info().scale) -- 다시 = 역순
end)

step(0.8, function()
    local pl = mp.get_property_native("playlist") or {}
    local desc = true
    for i = 2, #pl do
        if basename(pl[i - 1].filename) < basename(pl[i].filename) then desc = false break end
    end
    check("같은 정렬 버튼을 다시 누르면 역순", desc, basename(pl[1] and pl[1].filename))
end)

-- ── 10. 영상 위 휠은 음량 ───────────────────────────────────────────
step(0.3, function()
    log("[10] 영상 위 휠")
    saved.vol = mp.get_property_number("volume")
    wheel(60, 200, 1, 2)
end)

step(0.5, function()
    local v = mp.get_property_number("volume")
    check("영상 위에서 휠은 음량", v and saved.vol and v > saved.vol, "volume=" .. tostring(v))
end)

-- ── 11. 패널이 열려 있어도 탐색바가 눌린다 ──────────────────────────
step(0.3, function()
    log("[11] 탐색바")
    local n = info()
    mouse(n.x0 / 2, n.oh - 30)
end)

step(0.5, function()
    local n = info()
    saved.paused2 = mp.get_property_bool("pause")
    click(24 * (n.scale or 1), n.oh - 30 * (n.scale or 1))
end)

step(0.6, function()
    check("탐색바 재생 버튼이 패널에 가려지지 않는다",
        mp.get_property_bool("pause") ~= saved.paused2, "pause=" .. tostring(mp.get_property("pause")))
    mp.set_property_bool("pause", false)
end)

-- ── 12. 창 크기 변화 ────────────────────────────────────────────────
step(0.3, function()
    log("[12] 전체화면")
    saved.width_before = info().width
    mp.set_property_bool("fullscreen", true)
end)

step(1.2, function()
    local n = info()
    check("전체화면에서도 패널이 유지된다", n.open == true, tostring(n.open))
    check("전체화면 폭에 맞춰 다시 계산된다", n.x0 + n.width == n.ow,
        string.format("x0=%s w=%s ow=%s", tostring(n.x0), tostring(n.width), tostring(n.ow)))
    mp.set_property_bool("fullscreen", false)
end)

step(1.2, function()
    check("창으로 돌아와도 너비가 유지된다",
        math.abs((info().width or 0) - (saved.width_before or 0)) <= 8, tostring(info().width))
end)

-- ── 13. 키보드 토글과 정지 ──────────────────────────────────────────
step(0.3, function()
    log("[13] F6 토글과 정지")
    mp.commandv("keypress", "F6")
end)

step(0.5, function()
    check("F6 으로 닫힌다", info().open ~= true, tostring(info().open))
    mp.commandv("keypress", "F6")
end)

step(0.5, function()
    check("F6 으로 다시 열린다", info().open == true, tostring(info().open))
    check("여백이 정상으로 돌아온다", (mp.get_property_number("video-margin-ratio-right") or 0) > 0.05,
        tostring(mp.get_property("video-margin-ratio-right")))
    mp.command("stop")
end)

step(1.2, function()
    check("정지하면 패널이 대기 화면을 가리지 않는다", info().open ~= true, tostring(info().open))
end)

mp.register_event("file-loaded", function()
    if qi == 0 then mp.add_timeout(0.5, run_next) end
end)
