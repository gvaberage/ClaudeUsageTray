# Claude usage in system tray: icon = session (5h) %, tooltip = session + weekly.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace W -Name U -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
[DllImport("user32.dll")] public static extern IntPtr FindWindow(string cls, string name);
[DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
[DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr m, int type, out uint x, out uint y);
[DllImport("user32.dll")] public static extern int GetSystemMetricsForDpi(int index, uint dpi);
'@
[W.U]::SetProcessDPIAware() | Out-Null

# Real tray icon size (16/20/24 px at 100/125/150%). The scale is switched on the fly, while the process DPI
# is frozen at start, so ask the taskbar's monitor directly with a per-monitor-aware thread context.
function Get-TrayIconSize {
    $prev = [W.U]::SetThreadDpiAwarenessContext([IntPtr]-4)   # PER_MONITOR_AWARE_V2
    try {
        $mon = [W.U]::MonitorFromWindow([W.U]::FindWindow('Shell_TrayWnd', $null), 2)   # nearest
        $dx = [uint32]0; $dy = [uint32]0
        if ([W.U]::GetDpiForMonitor($mon, 0, [ref]$dx, [ref]$dy) -ne 0) { return 16 }
        [W.U]::GetSystemMetricsForDpi(49, $dx)   # SM_CXSMICON
    } finally { [W.U]::SetThreadDpiAwarenessContext($prev) | Out-Null }
}
$script:iconSize = Get-TrayIconSize

# Language: lang.txt ("en" / "ru") wins; otherwise Russian when the Windows UI language or regional format is Russian
$script:lang = 'en'
$langFile = "$PSScriptRoot\lang.txt"
if ((Test-Path $langFile) -and (Get-Content $langFile -Raw).Trim() -in 'en', 'ru') { $script:lang = (Get-Content $langFile -Raw).Trim() }
elseif ('ru' -in [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName, [Globalization.CultureInfo]::CurrentCulture.TwoLetterISOLanguageName) { $script:lang = 'ru' }
function L([string]$ru, [string]$en) { if ($script:lang -eq 'ru') { $ru } else { $en } }

. "$PSScriptRoot\Estimate.ps1"
. "$PSScriptRoot\Icons.ps1"

$credPath = "$env:USERPROFILE\.claude\.credentials.json"
$intervalMs = 180000

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Visible = $true
$script:hIcon = [IntPtr]::Zero
$script:details = ''

# mode.txt: "<style> <alt>", style = rows | bar | frame | framepix (see Icons.ps1), alt = 0/1 (toggled by left click)
$modeFile = "$PSScriptRoot\mode.txt"
$script:style = 'rows'; $script:alt = $false
if (Test-Path $modeFile) {
    $m = (Get-Content $modeFile -Raw).Trim() -split '\s+'
    if ($m[0] -eq 'split') { $script:alt = $true }   # old format: split / single
    elseif ($m[0] -in 'rows', 'bar', 'frame', 'framepix') { $script:style = $m[0]; $script:alt = $m[1] -eq '1' }
}
function Save-Mode { try { Set-Content $modeFile "$($script:style) $(if ($script:alt) { 1 } else { 0 })" } catch {} }
$script:last = $null   # @{ s = int; w = int } after a successful fetch

# history.csv: "time,session,week", one line only when a percent changes (~2 MB a year).
# history.html shows it; it can't read files itself, so Open-History dumps the CSV into history-data.js.
$historyFile = "$PSScriptRoot\history.csv"
$script:logged = ''
$script:lastPoll = $null
if (Test-Path $historyFile) {
    $tail = Get-Content $historyFile -Tail 1
    if ($tail -match '^[^,]+,(\d+),(\d+)$') { $script:logged = "$($Matches[1]),$($Matches[2])" }
}
function Write-History([int]$s, [int]$w) {
    $script:lastPoll = Get-Date
    $v = "$s,$w"
    if ($v -eq $script:logged) { return }
    try {
        if (-not (Test-Path $historyFile)) { Set-Content $historyFile 'time,session,week' -Encoding ASCII }
        Add-Content $historyFile "$((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')),$v" -Encoding ASCII
        $script:logged = $v
    } catch {}
}
function Open-History {
    # ReadAllText, not Get-Content -Raw: that one carries PSPath etc., and ConvertTo-Json dumps it as an object
    $csv = if (Test-Path $historyFile) { [IO.File]::ReadAllText($historyFile) } else { '' }
    $poll = if ($script:lastPoll) { $script:lastPoll.ToString('yyyy-MM-ddTHH:mm:sszzz') } else { '' }
    $js = "window.HISTORY_CSV = $(ConvertTo-Json $csv);`nwindow.HISTORY_POLL = $(ConvertTo-Json $poll);`nwindow.HISTORY_LANG = '$($script:lang)';"
    Set-Content "$PSScriptRoot\history-data.js" $js -Encoding UTF8
    Start-Process "$PSScriptRoot\history.html"
}

function Set-Icon($bmp) {
    $h = $bmp.GetHicon(); $bmp.Dispose()
    $tray.Icon = [System.Drawing.Icon]::FromHandle($h)
    if ($script:hIcon -ne [IntPtr]::Zero) { [W.U]::DestroyIcon($script:hIcon) | Out-Null }
    $script:hIcon = $h
}

function Format-Reset($iso) {
    $t = [DateTimeOffset]::Parse($iso).LocalDateTime
    if ($t.Date -eq (Get-Date).Date) { $t.ToString('HH:mm') }
    else { $t.ToString((L 'dd.MM HH:mm' 'MMM d HH:mm'), [Globalization.CultureInfo]::InvariantCulture) }
}

function Show-Last {
    if (-not $script:last) { Set-Icon (New-TextIcon $script:iconSize '?' ([System.Drawing.Color]::Gray)); return }
    Set-Icon (New-UsageIcon $script:iconSize $script:style $script:alt $script:last.s $script:last.w)
}

function Update-Usage {
    try {
        $c = Get-Content $credPath -Raw | ConvertFrom-Json
        $h = @{ Authorization = "Bearer $($c.claudeAiOauth.accessToken)"; 'anthropic-beta' = 'oauth-2025-04-20' }
        $u = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers $h -TimeoutSec 20
        $s = [int]$u.five_hour.utilization
        $w = [int]$u.seven_day.utilization
        $script:last = @{ s = $s; w = $w }
        Write-History $s $w
        Show-Last
        $sr = if ($u.five_hour.resets_at) { Format-Reset $u.five_hour.resets_at } else { '-' }
        $wr = if ($u.seven_day.resets_at) { Format-Reset $u.seven_day.resets_at } else { '-' }
        $tip = (L "Сессия $s% до $sr`nНеделя $w% до $wr" "Session $s% until $sr`nWeekly $w% until $wr")
        try {
            $est = Get-Estimate $u
            Set-Info $est.lines
            if ($est.tip) { $tip += "`n$($est.tip)" }
        } catch { Set-Info @(L 'Оценка лимита: ошибка чтения логов' 'Limit estimate: failed to read logs') }
        $tray.Text = $tip.Substring(0, [Math]::Min(63, $tip.Length))
    } catch {
        $script:last = $null
        Show-Last
        $tray.Text = L 'Claude: нет данных (токен истёк? запусти claude)' 'Claude: no data (token expired? run claude)'
    }
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
# Info lines with the limit estimate (filled by Update-Usage), then the actions
$infoItems = foreach ($i in 1..4) {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem
    $it.Visible = $false
    $menu.Items.Add($it) | Out-Null
    $it
}
function Set-Info([string[]]$lines) {
    for ($i = 0; $i -lt $infoItems.Count; $i++) {
        $infoItems[$i].Visible = $i -lt $lines.Count
        if ($i -lt $lines.Count) { $infoItems[$i].Text = $lines[$i] }
    }
}
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$viewMenu = New-Object System.Windows.Forms.ToolStripMenuItem (L 'Вид' 'Style')
foreach ($v in @(
        @('rows', (L 'Цифры (клик: сессия / две строки)' 'Digits (click: session / two rows)')),
        @('bar', (L 'Полоска (клик: сессия / неделя)' 'Bar (click: session / weekly)')),
        @('frame', (L 'Рамка тонкая, жирный шрифт (клик: сессия / неделя)' 'Thin ring, bold font (click: session / weekly)')),
        @('framepix', (L 'Рамка, пиксельный шрифт (клик: сессия / неделя)' 'Ring, pixel font (click: session / weekly)')))) {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem $v[1]
    $it.Tag = $v[0]
    $it.Checked = $v[0] -eq $script:style
    $it.add_Click({ param($sender)
        $script:style = $sender.Tag
        foreach ($x in $viewMenu.DropDownItems) { $x.Checked = $x.Tag -eq $script:style }
        Save-Mode; Show-Last
    })
    $viewMenu.DropDownItems.Add($it) | Out-Null
}
$menu.Items.Add($viewMenu) | Out-Null
$menu.Items.Add((L 'История расхода…' 'Usage history…'), $null, { Open-History }) | Out-Null
$menu.Items.Add((L 'Обновить' 'Refresh'), $null, { Update-Usage }) | Out-Null
$menu.Items.Add((L 'Выход' 'Exit'), $null, { $tray.Visible = $false; [System.Windows.Forms.Application]::Exit() }) | Out-Null
$tray.ContextMenuStrip = $menu
$tray.add_MouseClick({ param($s, $e)
    if ($e.Button -eq 'Left') {
        $script:alt = -not $script:alt
        Save-Mode; Show-Last
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $intervalMs
$timer.add_Tick({ Update-Usage })
$timer.Start()

# Redraw at the new size when the display scale changes
$dpiTimer = New-Object System.Windows.Forms.Timer
$dpiTimer.Interval = 2000
$dpiTimer.add_Tick({
    $sz = Get-TrayIconSize
    if ($sz -ne $script:iconSize) { $script:iconSize = $sz; Show-Last }
})
$dpiTimer.Start()

Update-Usage
[System.Windows.Forms.Application]::Run()
$tray.Dispose()
