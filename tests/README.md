# Tests

The panel is a mouse-driven UI, so there is not much to check beyond looking at it. These tests
replay **real clicks, drags and wheel events** with mpv's `mouse` / `keydown` / `keypress`
commands, then read the state the panel publishes (`user-data/boda/panel`) to see what happened.

## Running them

A window has to open, so they only run on a machine with a display.

1. Point them at any folder of videos. **30 or more** makes the scrolling checks meaningful.
2. Give them a throwaway state dir so your real history is left alone.

```powershell
$tmp = "$env:TEMP\boda-test"
mpv --geometry=1280x720 --ao=null --loop-file=inf `
    --script-opts=boda-state_dir=$tmp `
    --script="$env:APPDATA\mpv\tests\panel-ui.lua" `
    --log-file="$env:TEMP\boda-test.log" `
    "D:\Videos\Series\first.mkv"
```

3. The window moves on its own for a while and then closes. Results are in the log.

```powershell
Select-String -Path "$env:TEMP\boda-test.log" -Pattern '\] T ' |
    ForEach-Object { $_.Line -replace '^.*\] T ', '' }
```

A line like `RESULT 46 pass / 0 fail` means everything worked. Any failure makes mpv exit with
code 1.

## What they cover

| Area | Checked |
|---|---|
| Scrolling while playing | the wheel position stays where you put it |
| Clicking a row | one click plays it, clicking it again does not restart it |
| Highlight | the row under the cursor stays highlighted after a scroll |
| Resizing | dragging the edge is free, and video keeps a slice even when dragged off-screen |
| Scrollbar | dragging it reaches the bottom |
| Tabs and colour | tabs switch, slider drags land in the property |
| Window dragging | off over the panel, on over the video |
| Sorting | by name and reversed, with the playing file still current |
| Clips | `[` and `]` then add, play from there, loop, delete |
| Seek bar | its buttons still work with the panel open |
| Window size | the panel stays put across fullscreen |
| Stop | the panel gets out of the way and the continue-watching screen comes up |
| Continue watching | folders first, and clearing a list asks before it wipes anything |
| Errors | nothing threw while drawing (a swallowed error still fails the run) |

## Menu tests

`tests/menu.lua` builds the menu tree and checks its contents, its state and how it changes with
context, including that playlist rows are named after the file rather than whatever title mpv
reads out of it, and that the seek steps the menu sets really are what the arrow keys use. Actually showing the menu (`context-menu`) blocks until someone dismisses it, so
the tests stop at building the tree.

```powershell
$tmp = "$env:TEMP\boda-test"
mpv --script-opts=boda-state_dir=$tmp `
    --script="$env:APPDATA\mpv\tests\menu.lua" `
    --log-file="$env:TEMP\boda-menu.log" `
    "D:\Videos\Series\first.mkv"
```

To cover the `menu_sections` setting too (it contains commas, so wrap it in `%length%`):

```powershell
--script-opts=boda-state_dir=...,boda-menu_sections=%19%open,fav,-,settings
```

## Notes

- The cursor moves by itself while they run. Do not start them mid-task, and run one at a time:
  a second mpv window takes the focus, and the clicks land in the wrong place.
- Forget `--script-opts=boda-state_dir=` and **test files end up in your real history**.
- Anything that writes files (recording, saving a playlist) is left untested.
