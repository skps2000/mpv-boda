-- boda — 팟플레이어처럼 쓰는 mpv UI / 단축키 (Windows)
--
-- 구성
--   lib/   공용: 설정, 유틸, 상태 저장, 그리기+마우스 입력
--   mod/   기능: 기록, 스킵 구간, 동작, 열기 대화상자, 탐색바, 패널, 대기 화면
--
-- 키는 이 스크립트가 직접 잡지 않는다. 전부 input.conf 에서
-- `script-binding boda/<이름>` 으로 연결하므로 사용자가 마음대로 바꿀 수 있다.

local mp = require("mp")
local opts = require("lib.options")
local ui = require("lib.ui")
local state = require("lib.state")

state.init()
ui.init()

require("mod.history").init()
require("mod.skip").init()
require("mod.commands").init()
require("mod.dialogs").init()
require("mod.seekbar").init()
require("mod.panel").init()
require("mod.idle").init()
require("mod.menu").init()

-- 마우스 입력 창구는 여기 하나뿐이다.
mp.add_key_binding(nil, "mouse-left", function(e)
    ui.click(e and e.event or "press")
end, { complex = true })

mp.add_key_binding(nil, "mouse-left-dbl", function()
    if not ui.double_click() then mp.command("cycle pause") end
end)

mp.add_key_binding(nil, "wheel-up", function()
    if not ui.wheel(1) then mp.commandv("add", "volume", opts.wheel_volume) end
end)

mp.add_key_binding(nil, "wheel-down", function()
    if not ui.wheel(-1) then mp.commandv("add", "volume", -opts.wheel_volume) end
end)

mp.msg.verbose("boda 준비 완료 · 상태 폴더: " .. tostring(state.dir))
