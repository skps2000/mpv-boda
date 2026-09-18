# 테스트

패널은 마우스로 조작하는 UI라서, 눈으로 보는 것 말고는 확인할 방법이 마땅치 않습니다.
그래서 mpv의 `mouse` / `keydown` / `keypress` 명령으로 **실제 클릭·드래그·휠을 흉내내고**,
패널이 공개하는 상태(`user-data/boda/panel`)를 읽어 결과를 확인합니다.

## 돌리는 법

창이 떠야 하므로 화면이 있는 환경에서만 됩니다.

1. 아무 영상 폴더나 준비합니다. **30개 이상** 있어야 스크롤 항목이 의미가 있습니다.
2. 기록이 섞이지 않게 임시 폴더를 상태 폴더로 지정합니다.

```powershell
$tmp = "$env:TEMP\boda-test"
mpv --geometry=1280x720 --ao=null --loop-file=inf `
    --script-opts=boda-state_dir=$tmp `
    --script="$env:APPDATA\mpv\tests\panel-ui.lua" `
    --log-file="$env:TEMP\boda-test.log" `
    "D:\영상폴더\첫파일.mkv"
```

3. 창이 저절로 움직이다가 닫힙니다. 결과는 로그에서 봅니다.

```powershell
Select-String -Path "$env:TEMP\boda-test.log" -Pattern '\] T ' |
    ForEach-Object { $_.Line -replace '^.*\] T ', '' }
```

`RESULT 38 통과 / 0 실패` 처럼 나오면 정상입니다. 하나라도 실패하면 mpv가 종료 코드 1로 끝납니다.

## 무엇을 확인하나

| 항목 | 확인 내용 |
|---|---|
| 재생 중 스크롤 | 휠로 움직인 위치가 재생 중에도 유지되는지 |
| 고르기 / 재생 | 한 번 클릭은 고르기, 두 번 클릭이 재생인지 |
| 강조 표시 | 휠을 굴린 뒤에도 커서 아래 줄이 강조되는지 |
| 너비 조절 | 가장자리를 끌어 자유롭게, 창 밖으로 끌어도 영상 자리가 남는지 |
| 스크롤바 | 끌어서 맨 아래까지 가는지 |
| 탭 / 색감 | 탭 전환, 슬라이더 드래그가 값에 반영되는지 |
| 창 끌기 | 패널 위에서는 창이 안 끌리고, 영상 위에서는 끌리는지 |
| 정렬 | 이름 정렬과 역순, 정렬 후에도 보던 파일이 현재 항목인지 |
| 탐색바 | 패널이 열려 있어도 아래 버튼이 눌리는지 |
| 창 크기 | 전체화면 전환 후에도 패널이 제자리인지 |
| 정지 | 정지하면 패널이 대기 화면을 가리지 않는지 |

## 우클릭 메뉴 테스트

`tests/menu.lua` 는 메뉴 트리를 만들어 내용·상태·상황별 분기를 확인합니다.
실제로 메뉴를 띄우면(`context-menu`) 사용자가 닫을 때까지 멈추므로, 트리를 만드는 데까지만 봅니다.

```powershell
mpv --script-opts=boda-state_dir=$env:TEMPoda-test `
    --script="$env:APPDATA\mpv	ests\menu.lua" `
    --log-file="$env:TEMPoda-menu.log" "D:\영상폴더\첫파일.mkv"
```

메뉴 구성 설정까지 보려면 (쉼표가 들어가므로 `%길이%` 로 감싼다):

```powershell
--script-opts=boda-state_dir=...,boda-menu_sections=%19%open,fav,-,settings
```

## 주의

- 테스트 도중 마우스 커서가 저절로 움직입니다. 다른 작업 중에는 돌리지 마세요.
- `--script-opts=boda-state_dir=` 를 빼먹으면 **실제 시청 기록에 테스트 기록이 섞입니다.**
- 녹화나 재생목록 저장처럼 파일을 만드는 동작은 테스트하지 않습니다.
