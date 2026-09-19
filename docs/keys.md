# All keys

PotPlayer's default shortcuts, mapped onto mpv. They all live in [`input.conf`](../input.conf),
and editing that file is all it takes to change them.

한국어: [keys.ko.md](keys.ko.md)

> A shifted letter is written as the capital: `N`, not `Shift+n`.

## General

| Key | Action |
|---|---|
| `F1` | About |
| `F2` | Open folder (recent folders first, then everything below the one you pick) |
| `F3` / `F12` | Open file |
| `F4` | Menu |
| `Ctrl+Shift+P` | Command palette (type to find anything the menu can do) |
| `Ctrl+F4` | Stop (back to the idle screen) |
| `F5` / `Ctrl+F` | Open the config folder |
| `F6` | Playlist panel |
| `F7` | Colour panel |
| `F8` | Dual subtitles |
| `F9` | Sharp upscale on/off |
| `F10` | PiP (small window, always on top) |
| `F11` | Fullscreen |
| `B` | Boss key (pause and minimise) |
| `Ctrl+U` / `Alt+F12` | Open a URL or path |
| `Ctrl+V` | Open what is on the clipboard |
| `Ctrl+Y` | Reload the current file |
| `Alt+O` / `Alt+E` | Open a subtitle file |
| `Ctrl+Alt+Y` | Look for subtitles again |
| `Ctrl+Shift+M` | Save the playlist (to the desktop) |
| `Ctrl+Shift+O` | Open a playlist |
| `Ctrl+Shift+R` | Start / stop recording |
| `Ctrl+F1` | Playback statistics |
| `Ctrl+F12` | mpv console |
| `Alt+F4` | Quit |

## Playback

| Key | Action |
|---|---|
| `Space` | Play / pause |
| `PgUp` / `PgDn` | Previous / next file |
| `Del` | Remove from the playlist (the row you last clicked, else the playing one) |
| `←` `→` | 8 seconds |
| `Ctrl+←` `Ctrl+→` | 30 seconds |
| `Shift+←` `Shift+→` | 1 min 40 s |
| `Ctrl+Alt+←` `Ctrl+Alt+→` | 5 minutes |

Those four steps are settings: **Menu › Seek**, or `seek_arrow` / `seek_ctrl` / `seek_shift` /
`seek_alt` in `script-opts/boda.conf`. What you pick in the menu is remembered.

| Key | Action |
|---|---|
| `Ctrl+Shift+←` `Ctrl+Shift+→` | Keyframe by keyframe |
| `D` | Previous frame |
| `F` | Next frame |
| `Backspace` | Back to the start |
| `Ctrl+Backspace` | To the middle |
| `Shift+Backspace` | 30 s before the end |
| `G` | Jump to a time you type (1:23:00 or 90) |
| `Home` / `End` | Previous / next subtitle |
| `0`–`9` | 0–90 %. On the idle screen they open a recent file |
| `Z` | Back to normal speed (and back again) |
| `X` / `C` | Slower / faster by 0.1x |

## Clips, bookmarks and loops

| Key | Action |
|---|---|
| `+` | Save this moment as a clip (with `[` and `]` set, the whole range) |
| `Ctrl+Insert` | Open the clips tab |
| `P` | Bookmark this moment |
| `Shift+PgUp` / `Shift+PgDn` | Previous / next bookmark (chapters when there are none) |
| `H` | Chapters and bookmarks tab |
| `[` / `]` | Set A / set B |
| `{` / `}` | Clear A / clear B |
| `\` | Clear the loop |
| `Ctrl+[` / `Ctrl+]` | Nudge A / B 0.1 s earlier |
| `Alt+[` / `Alt+]` | Nudge A / B 0.1 s later |
| `Ctrl+Alt+[` / `Ctrl+Alt+]` | Nudge both by 0.1 s |
| `Ctrl+\` | Back to the start of the current subtitle |
| `Ctrl+I` | Intro ends here (skipped from next time) |
| `Ctrl+O` | Outro starts here (moves on to the next file) |
| `Ctrl+Shift+I` | Clear the skip points for this file |

## Subtitles

| Key | Action |
|---|---|
| `L` | Subtitles tab |
| `Alt+L` | Next subtitle track |
| `Alt+Ctrl+L` | Secondary subtitle track |
| `Alt+H` | Show / hide subtitles |
| `Alt+PgUp` / `Alt+PgDn` | Size |
| `Alt+↑` `Alt+↓` | Position |
| `Alt+←` `Alt+→` | Side margins |
| `Alt+Home` | Reset position and size |
| `Alt+I` | Put subtitles in the letterbox |
| `Alt+B` | Bold |
| `,` / `.` | Timing by 0.5 s |
| `Ctrl+,` / `Ctrl+.` | Timing by 5 s |
| `Alt+,` / `Alt+.` | Timing by 50 s |
| `/` | Reset timing |

## Video

| Key | Action |
|---|---|
| `V` | Video tab |
| `Alt+V` | Next video track |
| `Ctrl+Q` / `Ctrl+F5` / `Ctrl+F6` | Cycle aspect ratio |
| `Ctrl+Shift+D` | Deinterlace |
| `J` | 3D mode |
| `Ctrl+Z` / `Ctrl+P` | Flip horizontally / vertically |
| `Alt+K` | Rotate 90° |
| `Ctrl+B` | Blur |
| `Ctrl+R` | Sharpen |
| `Ctrl+H` | Deblock |
| `Ctrl+N` / `Ctrl+M` | Denoise |
| `Ctrl+Alt+F` | Remove every video filter |

## Colour

| Key | Action |
|---|---|
| `Q` | Correction on/off, to compare with the original |
| `W` / `E` | Brightness |
| `R` / `T` | Contrast |
| `Y` / `U` | Saturation |
| `I` / `O` | Hue |
| `Ctrl+Shift+W` / `Ctrl+Shift+E` | Gamma |
| `Ctrl+Alt+R` | Reset |
| `Ctrl+Alt+A` | Automatic correction on/off |
| `F7` | Colour panel (sliders) |

## Capture

| Key | Action |
|---|---|
| `K` / `Ctrl+G` / `Ctrl+E` | Save the frame at its own size |
| `Alt+N` / `Ctrl+Alt+C` / `Ctrl+Alt+E` | Save what you see |
| `Ctrl+S` | Save the frame with subtitles |
| `Ctrl+C` | Copy the frame to the clipboard |

Files go to the desktop; change `screenshot-directory` in `mpv.conf`.

## Audio

| Key | Action |
|---|---|
| `↑` / `↓` | Volume by 5 |
| `Shift+↑` / `Shift+↓` | Volume by 10 |
| Wheel | Volume (scrolls the list over a panel) |
| `M` | Mute |
| `A` | Audio tab |
| `Alt+A` | Next audio track |
| `<` / `>` | Timing by 0.05 s |
| `\|` | Reset timing |
| `N` | Volume levelling (lift the quiet parts) |
| `T` | Swap left and right |
| `Ctrl+Shift+V` | Try to remove vocals |
| `Ctrl+Alt+N` | Reset audio filters and timing |

## Window

| Key | Action |
|---|---|
| `Tab` | Cycle size (0.5 → 1 → 1.5 → 2x) |
| `Enter` / `Alt+Enter` | Fullscreen |
| `Ctrl+Enter` | Fill the window (crop) |
| `Ctrl+T` | Always on top |
| `Alt+1`–`Alt+4` | 0.5 / 1 / 1.5 / 2x |
| `Alt+5` | Maximise |
| `` ` `` | 0.3x |
| `Ctrl+Alt++` / `Ctrl+Alt+-` | Fine size steps |
| `Shift+Tab` | Playback statistics |

### Numpad (zoom and pan)

| Key | Action |
|---|---|
| `KP0` | Cycle window size |
| `KP5` | Back to the original size |
| `KP9` / `KP1` | Zoom in / out |
| `KP8` / `KP2` | Zoom in / out, finer |
| `KP6` / `KP4` | Aspect ratio |
| `Ctrl+KP4` `Ctrl+KP6` `Ctrl+KP8` `Ctrl+KP2` | Pan |
| `Ctrl+KP5` | Reset panning |

## Mouse

| Action | Result |
|---|---|
| Left click | UI buttons and the seek bar. A playlist row plays straight away (nothing over the video) |
| Double click | Play / pause (over the UI it behaves like a single click) |
| Right click | Menu (contents depend on what is under the cursor) |
| Middle click | Play / pause |
| Wheel | Volume (scrolls over a panel or the idle screen) |
| Wheel left / right | 5 seconds |
| Drag the panel's left edge | Resize it (a plain click cycles preset widths) |

## The menu

Right click, or press `F4`. It is the native window menu, so submenus, check marks and keyboard
navigation all work. From a key it always opens the main menu, whatever the cursor is over.

- **Over the video** — play/stop, open, continue watching, playlist, clips, chapters, speed,
  loop, skip, video, audio, subtitles, colour, window, capture, copy, panel, settings
- **Over the playlist** — play this row, remove it, sort, open a folder
- **Idle screen** — opening things and recent files

Change which groups appear with `menu_sections` in `script-opts/boda.conf`. To get mpv's default
right click back, set the `MBTN_RIGHT` line in `input.conf` to `cycle pause`.

## Actions without a key

Useful things left unbound. Add a line to `input.conf` to reach them.

```
Ctrl+Alt+h   script-binding boda/history-clear      # forget the watch history
Ctrl+Alt+f   script-binding boda/recent-clear       # forget the recent folders
Ctrl+Alt+b   script-binding boda/bookmark-clear     # clear this file's bookmarks
Ctrl+Alt+z   script-binding boda/speed-reset        # back to 1x
Ctrl+Alt+o   script-binding boda/osd-toggle         # force the seek bar on/off
Ctrl+Alt+x   script-binding boda/ab-clear           # clear both A and B
```

## PotPlayer features mpv does not have

These only say so when pressed: webcam and capture devices (`Ctrl+J`), TV tuners (`Ctrl+W`,
`Ctrl+K`), DVD and Blu-ray (`Ctrl+D`, `Ctrl+Alt+D`), subtitle authoring (`Alt+P`), subtitle font
settings (`Alt+F`), equaliser (`E`), level control (`Ctrl+L`), Freeverb (`R`).
