-- 사용자 설정. script-opts/boda.conf 또는 --script-opts=boda-key=value 로 바꾼다.
local mp = require("mp")
local options = require("mp.options")

local M = {
    -- 모양
    font = "Malgun Gothic",
    scale = 0,                -- 0 이면 창 높이에 맞춰 자동
    accent = "FF0000",        -- 강조색 #RRGGBB
    -- 동작
    auto_color = false,       -- 파일마다 밝기/대비/채도를 자동으로 건드릴지
    resume = true,            -- 마지막 위치에서 이어보기
    thumbnails = true,        -- 탐색바 썸네일 (ffmpeg 필요)
    ffmpeg = "",              -- ffmpeg 경로 (비우면 자동 탐색)
    wheel_volume = 5,         -- 휠 한 칸 음량
    history_size = 60,        -- 기록 보관 개수
    panel_width = 360,        -- 목록 패널 기본 너비(px)
    state_dir = "",           -- 기록 저장 폴더 (비우면 mpv 상태 폴더)
    menu_sections = "",       -- 우클릭 메뉴 구성 (비우면 기본 순서)
}

local subscribers = {}

function M.on_change(fn)
    subscribers[#subscribers + 1] = fn
end

options.read_options(M, "boda", function()
    for _, fn in ipairs(subscribers) do
        local ok, err = pcall(fn)
        if not ok then mp.msg.error("옵션 반영 실패: " .. tostring(err)) end
    end
end)

return M
