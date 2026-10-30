# Tray icon rendering. Styles, each with a normal view and an alt view (left click):
#   rows     - session in big font; alt: session over week, 5x7 pixel digits
#   bar      - big number + thin bar for the other limit: grey spent part on the left, coloured remainder
#              on the right. Normal: session + week bar at the bottom, alt: week + session bar at the top
#   frame    - big number inside a thin ring for the other limit; the ring turns grey clockwise from
#              12 o'clock as that limit is spent. Normal: session in a week ring, alt: week in a session ring
#   framepix - same as frame, thicker ring and 5x7 pixel digits
Add-Type -AssemblyName System.Drawing

$script:SpentColor = [System.Drawing.Color]::FromArgb(85, 85, 85)
$script:BigFontName = 'Segoe UI Black'
$script:BigFontStyle = [System.Drawing.FontStyle]::Regular

function Get-LevelColor([int]$p) {
    if ($p -ge 90) { [System.Drawing.Color]::FromArgb(200, 40, 40) }
    elseif ($p -ge 70) { [System.Drawing.Color]::FromArgb(210, 130, 0) }
    else { [System.Drawing.Color]::FromArgb(40, 140, 70) }
}

# 5x7 pixel digits: stay crisp at tray size, unlike Segoe UI at 8px
$script:PixFont = @{
    '0' = '01110', '10001', '10011', '10101', '11001', '10001', '01110'
    '1' = '00100', '01100', '00100', '00100', '00100', '00100', '01110'
    '2' = '01110', '10001', '00001', '00010', '00100', '01000', '11111'
    '3' = '11110', '00001', '00001', '01110', '00001', '00001', '11110'
    '4' = '00010', '00110', '01010', '10010', '11111', '00010', '00010'
    '5' = '11111', '10000', '11110', '00001', '00001', '10001', '01110'
    '6' = '00110', '01000', '10000', '11110', '10001', '10001', '01110'
    '7' = '11111', '00001', '00010', '00100', '01000', '01000', '01000'
    '8' = '01110', '10001', '10001', '01110', '10001', '10001', '01110'
    '9' = '01110', '10001', '10001', '01111', '00001', '00010', '01100'
}

function Fill-Rect($g, [System.Drawing.Color]$color, $x, $y, $wd, $ht) {
    $brush = New-Object System.Drawing.SolidBrush $color
    $g.FillRectangle($brush, $x, $y, $wd, $ht); $brush.Dispose()
}

# Pixel text centred horizontally in [0, $width), top edge at $y; letter spacing is dropped when the
# text with spacing is wider than $room
function Draw-PixText($g, [string]$text, [int]$width, [int]$y, [int]$room = $width) {
    $gap = if ($text.Length * 6 - 1 -le $room) { 1 } else { 0 }
    $x0 = [Math]::Floor(($width - ($text.Length * (5 + $gap) - $gap)) / 2)
    for ($i = 0; $i -lt $text.Length; $i++) {
        $rows = $script:PixFont[[string]$text[$i]]
        if (-not $rows) { continue }
        for ($r = 0; $r -lt 7; $r++) {
            for ($c = 0; $c -lt 5; $c++) {
                if ($rows[$r][$c] -eq '1') { $g.FillRectangle([System.Drawing.Brushes]::White, $x0 + $i * (5 + $gap) + $c, $y + $r, 1, 1) }
            }
        }
    }
}

# Largest font whose glyphs fit the box, centred by the glyphs' own outline. Centring the text line
# instead sits digits low, since the line box reserves room for descenders.
function Draw-BigText($g, [string]$text, [System.Drawing.RectangleF]$box) {
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $sf = [System.Drawing.StringFormat]::GenericTypographic.Clone()
    $sf.FormatFlags = [System.Drawing.StringFormatFlags]'NoWrap, NoClip'
    $family = New-Object System.Drawing.FontFamily $script:BigFontName
    for ($px = [single]($box.Height * 1.6); ; $px -= 0.5) {
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddString($text, $family, [int]$script:BigFontStyle, $px, (New-Object System.Drawing.PointF 0, 0), $sf)
        $bb = $path.GetBounds(); $path.Dispose()
        if ($px -le 6 -or ($bb.Width -le $box.Width -and $bb.Height -le $box.Height)) { break }
    }
    $font = New-Object System.Drawing.Font $family, $px, $script:BigFontStyle, ([System.Drawing.GraphicsUnit]::Pixel)
    $x = [Math]::Round($box.X + ($box.Width - $bb.Width) / 2 - $bb.X)
    $y = [Math]::Round($box.Y + ($box.Height - $bb.Height) / 2 - $bb.Y)
    $g.DrawString($text, $font, [System.Drawing.Brushes]::White, [single]$x, [single]$y, $sf)
    $font.Dispose(); $family.Dispose(); $sf.Dispose()
}

function New-Box($x, $y, $wd, $ht) { New-Object System.Drawing.RectangleF $x, $y, $wd, $ht }

function New-TextIcon([int]$size, [string]$text, [System.Drawing.Color]$bg) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    Fill-Rect $g $bg 0 0 $size $size
    $pad = [Math]::Round($size / 8)
    Draw-BigText $g $text (New-Box 1 $pad ($size - 2) ($size - 2 * $pad))
    $g.Dispose()
    $bmp
}

# Ring for the other limit: level colour, grey from 12 o'clock clockwise for the spent part
function Draw-Ring($g, [int]$size, [System.Drawing.Rectangle]$inner, [int]$pct) {
    Fill-Rect $g (Get-LevelColor $pct) 0 0 $size $size
    $sweep = 360 * [Math]::Min(100, $pct) / 100
    if ($sweep -gt 0) {
        $g.SetClip($inner, [System.Drawing.Drawing2D.CombineMode]::Exclude)
        $brush = New-Object System.Drawing.SolidBrush $script:SpentColor
        $g.FillPie($brush, -$size, -$size, 3 * $size, 3 * $size, -90, $sweep); $brush.Dispose()
        $g.ResetClip()
    }
}

function New-UsageIcon([int]$size, [string]$style, [bool]$alt, [int]$session, [int]$week) {
    $num = if ($alt) { $week } else { $session }       # big number in bar/frame
    $other = if ($alt) { $session } else { $week }     # shown as bar/ring
    switch ($style) {
        'bar' {
            $bmp = New-Object System.Drawing.Bitmap $size, $size
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $bh = [Math]::Round($size / 5)
            $by = if ($alt) { 0 } else { $size - $bh }
            $ty = if ($alt) { $bh } else { 0 }
            Fill-Rect $g (Get-LevelColor $num) 0 $ty $size ($size - $bh)
            Fill-Rect $g (Get-LevelColor $other) 0 $by $size $bh
            $len = [Math]::Round($size * [Math]::Min(100, $other) / 100)
            if ($len -gt 0) { Fill-Rect $g $script:SpentColor 0 $by $len $bh }
            $pad = [Math]::Max(1, [Math]::Round($size / 10))
            Draw-BigText $g "$num" (New-Box 1 ($ty + $pad) ($size - 2) ($size - $bh - 2 * $pad))
            $g.Dispose()
            $bmp
        }
        'frame' {
            $bmp = New-Object System.Drawing.Bitmap $size, $size
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $t = [Math]::Max(2, [Math]::Round($size / 10))
            $inner = New-Object System.Drawing.Rectangle $t, $t, ($size - 2 * $t), ($size - 2 * $t)
            Draw-Ring $g $size $inner $other
            Fill-Rect $g (Get-LevelColor $num) $inner.X $inner.Y $inner.Width $inner.Height
            Draw-BigText $g "$num" (New-Box ($t + 1) ($t + 1) ($inner.Width - 2) ($inner.Height - 2))   # 1px gap to the ring
            $g.Dispose()
            $bmp
        }
        'framepix' {
            $bmp = New-Object System.Drawing.Bitmap $size, $size
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $t = [Math]::Round($size * 3 / 20)
            if ("$num".Length -ge 3) { $t = 2 }   # 100 is 15px wide
            $inner = New-Object System.Drawing.Rectangle $t, $t, ($size - 2 * $t), ($size - 2 * $t)
            Draw-Ring $g $size $inner $other
            Fill-Rect $g (Get-LevelColor $num) $inner.X $inner.Y $inner.Width $inner.Height
            Draw-PixText $g "$num" $size ([Math]::Floor(($size - 7) / 2)) $inner.Width
            $g.Dispose()
            $bmp
        }
        default {   # rows
            if (-not $alt) { return New-TextIcon $size "$session" (Get-LevelColor $session) }
            $bmp = New-Object System.Drawing.Bitmap $size, $size
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $h = [Math]::Floor($size / 2)
            Fill-Rect $g (Get-LevelColor $session) 0 0 $size $h
            Fill-Rect $g (Get-LevelColor $week) 0 $h $size ($size - $h)
            Draw-PixText $g "$session" $size ([Math]::Floor(($h - 7) / 2))
            Draw-PixText $g "$week" $size ($h + [Math]::Ceiling(($size - $h - 7) / 2))
            $g.Dispose()
            $bmp
        }
    }
}
