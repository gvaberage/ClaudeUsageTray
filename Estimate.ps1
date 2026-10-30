# Estimates the weekly / session limit size from local Claude Code logs.
# Pure local math: reads ~/.claude/projects/**/*.jsonl, no API calls, no tokens spent.
# Cost is in API-price dollars ("API-equivalent"), since limits are cost-weighted, not raw tokens.

$projectsDir = "$env:USERPROFILE\.claude\projects"
$script:offsets = @{}   # file path -> bytes already parsed
$script:seen = New-Object 'System.Collections.Generic.HashSet[string]'
$script:entries = @()   # @{ t = DateTime (UTC); cost = $ }

# Raw-line regexes are safe: inside JSON strings quotes are escaped, so "key": only matches real keys.
$rx = @{
    ts   = [regex]'"timestamp":"([^"]+)"'
    model = [regex]'"model":"([^"]+)"'
    id   = [regex]'"id":"(msg_[^"]+)"'
    req  = [regex]'"requestId":"([^"]+)"'
    in   = [regex]'"input_tokens":(\d+)'
    out  = [regex]'"output_tokens":(\d+)'
    cr   = [regex]'"cache_read_input_tokens":(\d+)'
    cw   = [regex]'"cache_creation_input_tokens":(\d+)'
    cw1h = [regex]'"ephemeral_1h_input_tokens":(\d+)'
}

# $/MTok: input, output, cache read. Cache write = input x1.25 (5 min) or x2 (1 h).
function Get-Price([string]$m) {
    if ($m -match 'fable|mythos') { 10, 50, 0.25 }
    elseif ($m -match 'opus') { 4, 20, 0.20 }
    elseif ($m -match 'sonnet') { 2, 10, 0.20 }
    elseif ($m -match 'haiku') { 0.10, 0.50, 0.01 }
    else { $null }
}

function Get-Num($r, [string]$s) {
    $m = $r.Match($s)
    if ($m.Success) { [double]$m.Groups[1].Value } else { 0 }
}

function Add-Entry([string]$line) {
    $u = $line.IndexOf('"usage":{', [StringComparison]::Ordinal)
    if ($u -lt 0 -or $line.IndexOf('"type":"assistant"', [StringComparison]::Ordinal) -lt 0) { return }
    $id = $rx.id.Match($line).Groups[1].Value
    if (-not $id) { return }
    if (-not $script:seen.Add($id + '|' + $rx.req.Match($line).Groups[1].Value)) { return }
    $p = Get-Price $rx.model.Match($line).Groups[1].Value
    if (-not $p) { return }
    $us = $line.Substring($u)
    $cw = Get-Num $rx.cw $us; $cw1h = Get-Num $rx.cw1h $us
    $cost = ((Get-Num $rx.in $us) * $p[0] + (Get-Num $rx.out $us) * $p[1] + (Get-Num $rx.cr $us) * $p[2] +
        ($cw - $cw1h) * $p[0] * 1.25 + $cw1h * $p[0] * 2) / 1e6
    $t = [DateTimeOffset]::Parse($rx.ts.Match($line).Groups[1].Value).UtcDateTime
    $script:entries += @{ t = $t; cost = $cost }
}

# Parses only the bytes appended since the last call.
function Read-Logs {
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-8)
    foreach ($f in Get-ChildItem $projectsDir -Filter *.jsonl -Recurse -File -ErrorAction SilentlyContinue) {
        $path = $f.FullName
        $pos = if ($script:offsets.ContainsKey($path)) { $script:offsets[$path] } else { 0L }
        if ($f.LastWriteTimeUtc -lt $cutoff) { $script:offsets[$path] = $f.Length; continue }
        if ($f.Length -lt $pos) { $pos = 0L }   # file was rewritten; dedup protects from double counting
        if ($f.Length -eq $pos) { continue }
        try {
            $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
            try {
                $fs.Position = $pos
                $buf = New-Object byte[] ($f.Length - $pos)
                $n = 0
                while ($n -lt $buf.Length) { $r = $fs.Read($buf, $n, $buf.Length - $n); if ($r -le 0) { break }; $n += $r }
            } finally { $fs.Dispose() }
        } catch { continue }
        if ($n -eq 0) { continue }
        $last = [Array]::LastIndexOf($buf, [byte]10, $n - 1)
        if ($last -lt 0) { continue }   # no complete line yet
        $script:offsets[$path] = $pos + $last + 1
        foreach ($line in [System.Text.Encoding]::UTF8.GetString($buf, 0, $last).Split("`n")) { Add-Entry $line }
    }
    $script:entries = @($script:entries | Where-Object { $_.t -ge $cutoff })
}

function Get-CostSince([DateTime]$start) {
    $sum = 0.0
    foreach ($e in $script:entries) { if ($e.t -ge $start) { $sum += $e.cost } }
    $sum
}

function Format-Usd([double]$v) { if ($v -ge 10) { '$' + $v.ToString('0') } else { '$' + $v.ToString('0.00') } }

# $u = response of api/oauth/usage. Returns @{ lines = menu lines; tip = short tooltip line or $null }.
function Get-Estimate($u) {
    Read-Logs
    $s = [int]$u.five_hour.utilization
    $w = [int]$u.seven_day.utilization
    $weekCost = 0.0; $sessCost = 0.0
    if ($u.seven_day.resets_at) {
        $weekCost = Get-CostSince ([DateTimeOffset]::Parse($u.seven_day.resets_at).UtcDateTime.AddDays(-7))
        # chats on claude.ai / other devices are not in local logs: scale up by Claude Code's share
        $cc = ($u.seven_day_breakdown.rows | Where-Object { $_.key -eq 'claude_code' }).percent
        if ($cc -gt 0 -and $cc -lt 100) { $weekCost = $weekCost * 100 / $cc }
    }
    if ($u.five_hour.resets_at) {
        $sessCost = Get-CostSince ([DateTimeOffset]::Parse($u.five_hour.resets_at).UtcDateTime.AddHours(-5))
    }
    $weekLimit = if ($w -ge 1 -and $weekCost -gt 0) { $weekCost * 100 / $w } else { 0 }
    $sessLimit = if ($s -ge 1 -and $sessCost -gt 0) { $sessCost * 100 / $s } else { 0 }

    $lines = @(L "Потрачено (цены API): неделя $(Format-Usd $weekCost), сессия $(Format-Usd $sessCost)" "Used (API prices): weekly $(Format-Usd $weekCost), session $(Format-Usd $sessCost)")
    $lines += if ($weekLimit) { L "Лимит недели ≈ $(Format-Usd $weekLimit) (±$([Math]::Round(50 / $w))%)" "Weekly limit ≈ $(Format-Usd $weekLimit) (±$([Math]::Round(50 / $w))%)" } else { L 'Лимит недели: мало данных (нужно ≥ 1%)' 'Weekly limit: not enough data (needs ≥ 1%)' }
    $lines += if ($sessLimit) { L "Лимит сессии ≈ $(Format-Usd $sessLimit) (±$([Math]::Round(50 / $s))%)" "Session limit ≈ $(Format-Usd $sessLimit) (±$([Math]::Round(50 / $s))%)" } else { L 'Лимит сессии: мало данных (нужно ≥ 1%)' 'Session limit: not enough data (needs ≥ 1%)' }
    $tip = $null
    if ($weekLimit -and $sessLimit) {
        $per = $weekLimit / $sessLimit
        $left = $per * (100 - $w) / 100
        $lines += L "В неделе ≈ $([Math]::Round($per, 1)) сессий, осталось ≈ $([Math]::Round($left, 1))" "≈ $([Math]::Round($per, 1)) sessions a week, ≈ $([Math]::Round($left, 1)) left"
        $tip = L "Ост. ≈$([Math]::Round($left, 1)) сессий" "≈$([Math]::Round($left, 1)) sessions left"
    }
    @{ lines = $lines; tip = $tip }
}
