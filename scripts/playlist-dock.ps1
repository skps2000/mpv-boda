# PotPlayer-style side panel for mpv — single instance (mutex first, before slow Add-Type)
$confDir = Join-Path $env:APPDATA "mpv"
$pidFile = Join-Path $confDir "dock.pid"
$showFileEarly = Join-Path $confDir "dock-show.txt"
$createdNew = $false
$script:singleMutex = New-Object System.Threading.Mutex($true, "Global\mpv-pp-dock-single", [ref]$createdNew)
if (-not $createdNew) {
    try {
        $ev = [System.Threading.EventWaitHandle]::OpenExisting("mpv-pp-dock-toggle")
        [void]$ev.Set()
    } catch {}
    exit 0
}
New-Item -ItemType Directory -Force -Path $confDir | Out-Null
Set-Content -Path $pidFile -Value $PID -Encoding ASCII

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing @"
using System;
using System.Text;
using System.Windows.Forms;
using System.Runtime.InteropServices;
public class PpDockNative {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  public const uint SWP_NOACTIVATE = 0x0010;
  public const uint SWP_SHOWWINDOW = 0x0040;
  public const uint SWP_NOZORDER = 0x0004;
}
public class PpNoActForm : Form {
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override CreateParams CreateParams {
    get {
      CreateParams cp = base.CreateParams;
      cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
      return cp;
    }
  }
}
"@

$ErrorActionPreference = "Continue"
[System.Windows.Forms.Application]::EnableVisualStyles()
try { chcp 65001 | Out-Null } catch {}

$pipeName = "mpv-pp"
$showFile = Join-Path $confDir "dock-show.txt"
$tabFile = Join-Path $confDir "dock-tab.txt"
$colorFile = Join-Path $confDir "color-show.txt"
$errLog = Join-Path $confDir "dock-error.log"
function Write-DockLog($m) {
    try { Add-Content -Path $errLog -Value ("{0} {1}" -f (Get-Date -Format "HH:mm:ss"), $m) -Encoding UTF8 } catch {}
}

# leftover toggle files were hiding the panel on startup
Remove-Item $showFile -Force -ErrorAction SilentlyContinue
Remove-Item $tabFile -Force -ErrorAction SilentlyContinue

$evt = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, "mpv-pp-dock-toggle")
$script:startedAt = Get-Date
$script:missedMpv = 0

$bg = [System.Drawing.Color]::FromArgb(28, 28, 28)
$bg2 = [System.Drawing.Color]::FromArgb(40, 40, 40)
$fg = [System.Drawing.Color]::FromArgb(230, 230, 230)
$acc = [System.Drawing.Color]::FromArgb(0, 122, 204)
$font = New-Object System.Drawing.Font("Malgun Gothic", 9)

$script:pipe = $null
$script:sw = $null
$script:sr = $null
$script:req = 1
$script:tab = "playlist"
$script:hwnd = [IntPtr]::Zero
$script:mpvPid = 0
$script:updating = $false
$script:lastSig = ""
$script:visible = $true
$script:enumFound = [IntPtr]::Zero

function Connect-Mpv {
    if ($script:pipe -and $script:pipe.IsConnected) { return $true }
    try {
        $script:pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $script:pipe.Connect(400)
        $utf8 = New-Object System.Text.UTF8Encoding $false
        $script:sw = New-Object System.IO.StreamWriter($script:pipe, $utf8)
        $script:sw.AutoFlush = $true
        $script:sr = New-Object System.IO.StreamReader($script:pipe, $utf8)
        return $true
    } catch {
        $script:pipe = $null
        return $false
    }
}

function Send-Mpv {
    param([object[]]$Cmd)
    if (-not (Connect-Mpv)) { return $null }
    $script:req++
    $payload = @{ command = $Cmd; request_id = $script:req } | ConvertTo-Json -Compress -Depth 8
    try {
        $script:sw.WriteLine($payload)
        $line = $script:sr.ReadLine()
        if (-not $line) { return $null }
        return ($line | ConvertFrom-Json)
    } catch {
        try { $script:pipe.Dispose() } catch {}
        $script:pipe = $null
        return $null
    }
}

function Get-Prop {
    param([string]$Name)
    $r = Send-Mpv -Cmd @("get_property", $Name)
    if ($r -and $r.error -eq "success") { return $r.data }
    return $null
}

function Find-MpvHwnd {
    $proc = Get-Process mpv -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) { return [IntPtr]::Zero }
    $script:mpvPid = $proc.Id
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { return $proc.MainWindowHandle }
    $script:enumFound = [IntPtr]::Zero
    $cb = [PpDockNative+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$l)
        $pid = [uint32]0
        [void][PpDockNative]::GetWindowThreadProcessId($h, [ref]$pid)
        if ($pid -eq $script:mpvPid -and [PpDockNative]::IsWindowVisible($h) -and -not [PpDockNative]::IsIconic($h)) {
            $sb = New-Object System.Text.StringBuilder 256
            [void][PpDockNative]::GetWindowText($h, $sb, 256)
            if ($sb.ToString() -match "mpv") { $script:enumFound = $h; return $false }
        }
        return $true
    }
    [void][PpDockNative]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:enumFound
}

function Get-BaseName {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "(none)" }
    try { return [System.IO.Path]::GetFileName($Path) } catch { return $Path }
}

$form = New-Object PpNoActForm
$form.KeyPreview = $true
$form.Text = "재생 목록"
$form.FormBorderStyle = "SizableToolWindow"
$form.ShowInTaskbar = $true
$form.MinimizeBox = $true
$form.StartPosition = "Manual"
$form.Width = 320
$form.Height = 480
$form.BackColor = $bg
$form.ForeColor = $fg
$form.Font = $font
$form.MinimumSize = New-Object System.Drawing.Size(220, 200)

$list = New-Object System.Windows.Forms.ListView
$list.Dock = "Fill"
$list.View = "Details"
$list.FullRowSelect = $true
$list.HideSelection = $false
$list.MultiSelect = $false
$list.HeaderStyle = "None"
$list.BorderStyle = "None"
$list.BackColor = $bg
$list.ForeColor = $fg
$list.Font = $font
[void]$list.Columns.Add("item", 280)
$form.Controls.Add($list)

$status = New-Object System.Windows.Forms.Label
$status.Dock = "Bottom"
$status.Height = 22
$status.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
$status.Text = "  waiting for mpv"
$form.Controls.Add($status)

$tabs = New-Object System.Windows.Forms.FlowLayoutPanel
$tabs.Dock = "Top"
$tabs.Height = 32
$tabs.BackColor = $bg2
$tabs.Padding = New-Object System.Windows.Forms.Padding(4, 4, 4, 0)
$form.Controls.Add($tabs)

function New-TabBtn {
    param([string]$Text, [string]$Id)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Tag = $Id
    $b.FlatStyle = "Flat"
    $b.FlatAppearance.BorderSize = 0
    $b.Height = 24
    $b.AutoSize = $true
    $b.ForeColor = $fg
    $b.BackColor = $bg2
    $b.Add_Click({
        $script:tab = [string]$this.Tag
        $script:lastSig = ""
        Refresh-Tabs
        Refresh-List
    })
    [void]$tabs.Controls.Add($b)
}

New-TabBtn -Text "재생목록" -Id "playlist"
New-TabBtn -Text "오디오" -Id "audio"
New-TabBtn -Text "자막" -Id "sub"
New-TabBtn -Text "비디오" -Id "video"
New-TabBtn -Text "챕터" -Id "chapter"

function Refresh-Tabs {
    foreach ($c in $tabs.Controls) {
        if ($c.Tag -eq $script:tab) { $c.BackColor = $acc } else { $c.BackColor = $bg2 }
    }
}

function Invoke-Current {
    if ($list.SelectedItems.Count -lt 1) { return }
    $idx = $list.SelectedItems[0].Tag
    switch ($script:tab) {
        "playlist" { [void](Send-Mpv -Cmd @("playlist-play-index", [int]$idx)) }
        "audio"    { [void](Send-Mpv -Cmd @("set_property", "aid", $idx)) }
        "sub"      { [void](Send-Mpv -Cmd @("set_property", "sid", $idx)) }
        "video"    { [void](Send-Mpv -Cmd @("set_property", "vid", $idx)) }
        "chapter"  {
            $s = [string]$idx
            if ($s.StartsWith("bm:")) {
                $t = [double]($s.Substring(3))
                [void](Send-Mpv -Cmd @("seek", $t, "absolute"))
            } else {
                [void](Send-Mpv -Cmd @("set_property", "chapter", [int]$idx))
            }
        }
    }
}

function Add-Row {
    param([string]$Text, $Tag, [bool]$Current)
    $it = New-Object System.Windows.Forms.ListViewItem($Text)
    $it.Tag = $Tag
    if ($Current) {
        $it.BackColor = $acc
        $it.ForeColor = [System.Drawing.Color]::White
    }
    [void]$list.Items.Add($it)
    if ($Current) { $it.Selected = $true; $it.EnsureVisible() }
}

function Refresh-List {
    if (-not (Connect-Mpv)) {
        $status.Text = "  mpv not connected"
        return
    }
    $pl = $null; $tr = $null; $ch = $null; $bms = $null
    $aid = $null; $sid = $null; $vid = $null; $curCh = $null
    switch ($script:tab) {
        "playlist" { $pl = Get-Prop "playlist" }
        "audio" { $tr = Get-Prop "track-list"; $aid = Get-Prop "aid" }
        "sub" { $tr = Get-Prop "track-list"; $sid = Get-Prop "sid" }
        "video" { $tr = Get-Prop "track-list"; $vid = Get-Prop "vid" }
        "chapter" { $ch = Get-Prop "chapter-list"; $curCh = Get-Prop "chapter"; $bms = Get-Prop "user-data/pp-bookmarks" }
    }
    $sig = "$($script:tab)|$(ConvertTo-Json $pl -Compress -Depth 6)|$(ConvertTo-Json $tr -Compress -Depth 6)|$aid|$sid|$vid|$curCh|$(ConvertTo-Json $bms -Compress)"
    if ($sig -eq $script:lastSig) { return }
    $script:lastSig = $sig
    $script:updating = $true
    try {
        $list.BeginUpdate()
        $list.Items.Clear()
        switch ($script:tab) {
            "playlist" {
                if ($null -eq $pl) { break }
                $i = 0
                foreach ($e in @($pl)) {
                    $name = $e.title
                    if (-not $name) { $name = Get-BaseName $e.filename }
                    $cur = [bool]$e.current
                    $prefix = if ($cur) { "> " } else { "  " }
                    Add-Row -Text ($prefix + $name) -Tag $i -Current $cur
                    $i++
                }
                $status.Text = "  playlist $($list.Items.Count)"
            }
            "audio" {
                foreach ($t in @($tr)) {
                    if ($t.type -ne "audio") { continue }
                    $label = ("A{0}  {1}  {2}  {3}" -f $t.id, $t.lang, $t.title, $t.codec)
                    $label = ($label -replace "\s+", " ").Trim()
                    $isCur = ($t.id -eq $aid) -or $t.selected
                    Add-Row -Text $label -Tag $t.id -Current $isCur
                }
                $status.Text = "  audio tracks"
            }
            "sub" {
                $off = ($sid -eq "no") -or ($sid -eq $false)
                Add-Row -Text "(sub off)" -Tag "no" -Current $off
                foreach ($t in @($tr)) {
                    if ($t.type -ne "sub") { continue }
                    $label = ("S{0}  {1}  {2}  {3}" -f $t.id, $t.lang, $t.title, $t.codec)
                    $label = ($label -replace "\s+", " ").Trim()
                    $isCur = ($t.id -eq $sid) -or $t.selected
                    Add-Row -Text $label -Tag $t.id -Current $isCur
                }
                $status.Text = "  subtitles"
            }
            "video" {
                foreach ($t in @($tr)) {
                    if ($t.type -ne "video") { continue }
                    $label = ("V{0}  {1}" -f $t.id, $t.codec)
                    Add-Row -Text $label -Tag $t.id -Current (($t.id -eq $vid) -or $t.selected)
                }
                $status.Text = "  video tracks"
            }
            "chapter" {
                $n = 0
                foreach ($c in @($ch)) {
                    $title = $c.title
                    if (-not $title) { $title = "Chapter $($n+1)" }
                    Add-Row -Text $title -Tag $n -Current ($n -eq $curCh)
                    $n++
                }
                if ($bms) {
                    $k = 1
                    foreach ($t in @($bms)) {
                        $label = "Bookmark $k  ($([math]::Round([double]$t,1))s)"
                        Add-Row -Text $label -Tag ("bm:$t") -Current $false
                        $k++
                    }
                }
                if ($list.Items.Count -eq 0) { Add-Row -Text "(empty)" -Tag -1 -Current $false }
                $status.Text = "  chapters / bookmarks"
            }
        }
        $list.Columns[0].Width = [Math]::Max(80, $list.ClientSize.Width - 8)
    } finally {
        $list.EndUpdate()
        $script:updating = $false
    }
    Refresh-Tabs
}

$list.Add_DoubleClick({
    if (-not $script:updating) { Invoke-Current }
})
$form.Add_KeyDown({
    param($sender, $e)
    [void](Handle-ArrowKeys $e)
})
$list.Add_KeyDown({
    param($sender, $e)
    if (Handle-ArrowKeys $e) { return }
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Return) { Invoke-Current; $e.Handled = $true }
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Delete) {
        if ($script:tab -eq "playlist" -and $list.SelectedItems.Count -gt 0) {
            $idx = [int]$list.SelectedItems[0].Tag
            [void](Send-Mpv -Cmd @("playlist-remove", $idx))
        }
        $e.Handled = $true
    }
})
$form.Add_Resize({ $list.Columns[0].Width = [Math]::Max(80, $list.ClientSize.Width - 8) })

function Place-Dock {
    if (-not $form.Visible) { return }
    $w = $form.Width
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $left = $wa.Right - $w
    $top = $wa.Top
    $hgt = [Math]::Max(240, [int]($wa.Height * 0.7))
    $h = Find-MpvHwnd
    if ($h -ne [IntPtr]::Zero -and [PpDockNative]::IsWindow($h)) {
        $r = New-Object PpDockNative+RECT
        if ([PpDockNative]::GetWindowRect($h, [ref]$r)) {
            $rectW = $r.Right - $r.Left
            $rectH = $r.Bottom - $r.Top
            if ($rectW -gt 120 -and $rectH -gt 120) {
                $screen = [System.Windows.Forms.Screen]::FromHandle($h)
                $wa = $screen.WorkingArea
                $hgt = [Math]::Max(240, $rectH)
                $left = $r.Right
                if (($left + $w) -gt $wa.Right) { $left = $r.Left - $w }
                if ($left -lt $wa.Left) { $left = $wa.Right - $w }
                $top = $r.Top
                if (($top + $hgt) -gt $wa.Bottom) { $hgt = [Math]::Max(240, $wa.Bottom - $top) }
            }
        }
    }
    Move-NoActivate $form $left $top $w $hgt
}

function Move-NoActivate($win, $x, $y, $w, $h) {
    if (-not $win -or -not $win.Visible -or $win.Handle -eq [IntPtr]::Zero) { return }
    $dx = [Math]::Abs($win.Left - $x)
    $dy = [Math]::Abs($win.Top - $y)
    $dw = [Math]::Abs($win.Width - $w)
    $dh = [Math]::Abs($win.Height - $h)
    if ($dx -lt 8 -and $dy -lt 8 -and $dw -lt 8 -and $dh -lt 16) { return }
    [void][PpDockNative]::SetWindowPos($win.Handle, [IntPtr]::Zero, [int]$x, [int]$y, [int]$w, [int]$h, 0x0010)
}

function Focus-Mpv {
    $h = Find-MpvHwnd
    if ($h -ne [IntPtr]::Zero) { [void][PpDockNative]::SetForegroundWindow($h) }
}

function Handle-ArrowKeys($e) {
    $k = $e.KeyCode
    if ($k -eq [System.Windows.Forms.Keys]::Left) {
        [void](Send-Mpv -Cmd @("seek", -5, "exact")); $e.Handled = $true; Focus-Mpv; return $true
    }
    if ($k -eq [System.Windows.Forms.Keys]::Right) {
        [void](Send-Mpv -Cmd @("seek", 5, "exact")); $e.Handled = $true; Focus-Mpv; return $true
    }
    if ($k -eq [System.Windows.Forms.Keys]::Up) {
        [void](Send-Mpv -Cmd @("add", "volume", 5)); $e.Handled = $true; Focus-Mpv; return $true
    }
    if ($k -eq [System.Windows.Forms.Keys]::Down) {
        [void](Send-Mpv -Cmd @("add", "volume", -5)); $e.Handled = $true; Focus-Mpv; return $true
    }
    return $false
}

function Read-CmdFiles {
    if (Test-Path $tabFile) {
        $t = (Get-Content $tabFile -Raw -ErrorAction SilentlyContinue)
        if ($t) { $script:tab = $t.Trim(); $script:lastSig = "" }
        Remove-Item $tabFile -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $showFile) {
        $s = (Get-Content $showFile -Raw -ErrorAction SilentlyContinue)
        Remove-Item $showFile -Force -ErrorAction SilentlyContinue
        if ($s) { $s = $s.Trim() }
        if ($s -eq "hide") { $form.Hide(); $script:visible = $false }
        elseif ($s -eq "show") { $form.Show(); $script:visible = $true; Place-Dock }
        else {
            $script:visible = -not $form.Visible
            if ($script:visible) { $form.Show(); Place-Dock } else { $form.Hide() }
        }
    }
    if (Test-Path $colorFile) {
        $s = (Get-Content $colorFile -Raw -ErrorAction SilentlyContinue)
        Remove-Item $colorFile -Force -ErrorAction SilentlyContinue
        if ($s) { $s = $s.Trim() }
        if ($s -eq "hide") { $colorForm.Hide() }
        elseif ($s -eq "show") { $colorForm.Show(); Place-Color; Sync-ColorSliders }
        else {
            if ($colorForm.Visible) { $colorForm.Hide() } else { $colorForm.Show(); Place-Color; Sync-ColorSliders }
        }
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400
$timer.Add_Tick({
    try {
        if ($evt.WaitOne(0)) { Read-CmdFiles }
        Read-CmdFiles
        $mpvAlive = [bool](Get-Process -Name mpv -ErrorAction SilentlyContinue)
        if ($mpvAlive) { $script:missedMpv = 0 } else { $script:missedMpv++ }
        # only quit after mpv has been gone for a while (not on a brief restart)
        if ($script:missedMpv -gt 40) { $form.Close(); return }
        if ($form.Visible) {
            Place-Dock
            Refresh-List
        } else {
            [void](Connect-Mpv)
        }
        if ($colorForm.Visible) {
            Place-Color
            Sync-ColorSliders
        }
    } catch {
        Write-DockLog $_.Exception.Message
    }
})

$form.Add_Shown({
    $form.Show()
    $form.WindowState = "Normal"
    Refresh-Tabs
    Place-Dock
    Refresh-List
    $timer.Start()
})
$form.Add_FormClosing({
    param($sender, $e)
    if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true
        $form.Hide()
    }
})
$form.Add_FormClosed({
    $timer.Stop()
    try { $script:pipe.Dispose() } catch {}
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
})

# --- F7 color / look panel ---
$script:colorBusy = $false
$script:sliders = @{}
$script:sliderLabels = @{}

$colorForm = New-Object PpNoActForm
$colorForm.Text = "색감 / 미감"
$colorForm.FormBorderStyle = "SizableToolWindow"
$colorForm.ShowInTaskbar = $true
$colorForm.StartPosition = "Manual"
$colorForm.Width = 300
$colorForm.Height = 420
$colorForm.BackColor = $bg
$colorForm.ForeColor = $fg
$colorForm.Font = $font
$colorForm.KeyPreview = $true
$colorForm.Visible = $false
$colorForm.MinimumSize = New-Object System.Drawing.Size(260, 360)

$colorForm.Add_KeyDown({
    param($sender, $e)
    [void](Handle-ArrowKeys $e)
})
$colorForm.Add_FormClosing({
    param($sender, $e)
    if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true
        $colorForm.Hide()
    }
})

$hint = New-Object System.Windows.Forms.Label
$hint.Dock = "Top"
$hint.Height = 48
$hint.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
$hint.Text = "  실시간 적용 · 화살표는 영상 창으로" + [Environment]::NewLine + "  F7 패널 토글 · Q 초기화"
$colorForm.Controls.Add($hint)

$btnReset = New-Object System.Windows.Forms.Button
$btnReset.Text = "초기화 (Q)"
$btnReset.Dock = "Bottom"
$btnReset.Height = 32
$btnReset.FlatStyle = "Flat"
$btnReset.ForeColor = $fg
$btnReset.BackColor = $bg2
$btnReset.Add_Click({
    foreach ($n in @("brightness","contrast","saturation","gamma","hue")) {
        [void](Send-Mpv -Cmd @("set_property", $n, 0))
        if ($script:sliders.ContainsKey($n)) { $script:sliders[$n].Value = 0 }
    }
    Sync-ColorSliders
    Focus-Mpv
})
$colorForm.Controls.Add($btnReset)

$grid = New-Object System.Windows.Forms.Panel
$grid.Dock = "Fill"
$grid.BackColor = $bg
$grid.AutoScroll = $true
$colorForm.Controls.Add($grid)
$grid.BringToFront()

function Add-ColorSlider($parent, $y, $prop, $title, $keys) {
    $lab = New-Object System.Windows.Forms.Label
    $lab.Location = New-Object System.Drawing.Point(10, $y)
    $lab.Size = New-Object System.Drawing.Size(260, 18)
    $lab.ForeColor = $fg
    $lab.Text = "$title  $keys"
    [void]$parent.Controls.Add($lab)
    $tb = New-Object System.Windows.Forms.TrackBar
    $tb.Location = New-Object System.Drawing.Point(8, ($y + 18))
    $tb.Size = New-Object System.Drawing.Size(250, 40)
    $tb.Minimum = -100
    $tb.Maximum = 100
    $tb.TickFrequency = 10
    $tb.SmallChange = 1
    $tb.LargeChange = 10
    $tb.BackColor = $bg
    $tb.Tag = $prop
    $val = New-Object System.Windows.Forms.Label
    $val.Location = New-Object System.Drawing.Point(220, $y)
    $val.Size = New-Object System.Drawing.Size(50, 18)
    $val.ForeColor = $acc
    $val.TextAlign = "MiddleRight"
    $val.Text = "0"
    [void]$parent.Controls.Add($val)
    $tb.Add_Scroll({
        $script:colorBusy = $true
        $p = [string]$this.Tag
        [void](Send-Mpv -Cmd @("set_property", $p, $this.Value))
        if ($script:sliderLabels.ContainsKey($p)) { $script:sliderLabels[$p].Text = [string]$this.Value }
    })
    $tb.Add_MouseUp({ $script:colorBusy = $false; Focus-Mpv })
    $tb.Add_KeyUp({ [void](Handle-ArrowKeys $_); Focus-Mpv })
    [void]$parent.Controls.Add($tb)
    $script:sliders[$prop] = $tb
    $script:sliderLabels[$prop] = $val
}

Add-ColorSlider $grid 8  "brightness" "밝기" "W / E"
Add-ColorSlider $grid 70 "contrast"   "대비" "R / T"
Add-ColorSlider $grid 132 "saturation" "채도" "Y / U"
Add-ColorSlider $grid 194 "gamma"      "감마" "Ctrl+Shift+W / E"
Add-ColorSlider $grid 256 "hue"        "색상" "I / O"

function Sync-ColorSliders {
    if ($script:colorBusy) { return }
    foreach ($n in @("brightness","contrast","saturation","gamma","hue")) {
        $v = Get-Prop $n
        if ($null -eq $v) { continue }
        $i = [int][math]::Round([double]$v)
        if ($i -lt -100) { $i = -100 }
        if ($i -gt 100) { $i = 100 }
        if ($script:sliders.ContainsKey($n) -and $script:sliders[$n].Value -ne $i) {
            $script:sliders[$n].Value = $i
        }
        if ($script:sliderLabels.ContainsKey($n)) { $script:sliderLabels[$n].Text = [string]$i }
    }
}

function Place-Color {
    if (-not $colorForm.Visible) { return }
    $w = $colorForm.Width
    $hgt = $colorForm.Height
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $left = $wa.Left
    $top = $wa.Top + 40
    $h = Find-MpvHwnd
    if ($h -ne [IntPtr]::Zero) {
        $r = New-Object PpDockNative+RECT
        if ([PpDockNative]::GetWindowRect($h, [ref]$r)) {
            $left = $r.Left - $w
            if ($left -lt $wa.Left) { $left = $r.Right }
            if (($left + $w) -gt $wa.Right) { $left = $wa.Left }
            $top = $r.Top
            $hgt = [Math]::Max(360, [Math]::Min(480, $r.Bottom - $r.Top))
        }
    }
    Move-NoActivate $colorForm $left $top $w $hgt
}

[System.Windows.Forms.Application]::Run($form)

