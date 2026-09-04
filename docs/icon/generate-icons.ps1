# 智记 SmartBook 图标生成脚本(方案 A · 闪电票据)
# 用法:
#   powershell -File generate-icons.ps1
# 输出:
#   client/android/app/src/main/res/mipmap-{mdpi..xxxhdpi}/ic_launcher.png   (旧式图标,48/72/96/144/192)
#   client/android/app/src/main/res/drawable-{mdpi..xxxhdpi}/ic_launcher_foreground.png  (自适应前景,108..432)
#   client/android/app/src/main/res/drawable-{mdpi..xxxhdpi}/ic_launcher_monochrome.png  (主题单色,108..432)
Add-Type -AssemblyName System.Drawing

$res = "D:\gitee\auto-ledger\client\android\app\src\main\res"

function New-RoundedPath([double]$x, [double]$y, [double]$w, [double]$h, [double]$r, $holes) {
    # 圆角矩形路径;holes = 供挖孔的 (cx,cr) 对(在 512 设计坐标里的中心 x 与半径)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc([float]$x, [float]$y, [float]$r, [float]$r, 180, 90)
    $p.AddArc([float]($x + $w - $r), [float]$y, [float]$r, [float]$r, 270, 90)
    $p.AddArc([float]($x + $w - $r), [float]($y + $h - $r), [float]$r, [float]$r, 0, 90)
    $p.AddArc([float]$x, [float]($y + $h - $r), [float]$r, [float]$r, 90, 90)
    $p.CloseFigure()
    if ($null -ne $holes) {
        $p.FillMode = [System.Drawing.Drawing2D.FillMode]::Alternate
        foreach ($pair in $holes) {
            $cx = [double]$pair[0]; $cr = [double]$pair[1]
            $p.AddEllipse([float]($cx - $cr), [float](152 - $cr), [float](2 * $cr), [float](2 * $cr))
        }
    }
    return $p
}

function New-RoundPen($color, [double]$width, $s) {
    $pen = New-Object System.Drawing.Pen($color, [float]($width * $s))
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    return $pen
}

function New-WhiteBrush() { New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White) }

function Draw-Icon([int]$size, [string]$stage, [string]$outPath) {
    $s = $size / 512.0
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $holes = @( @(188, 9), @(233, 9), @(279, 9), @(324, 9) )
    $fg = [System.Drawing.ColorTranslator]::FromHtml('#FFFFFF')
    $lineGray = [System.Drawing.ColorTranslator]::FromHtml('#D6DEEA')
    $lineGold = [System.Drawing.ColorTranslator]::FromHtml('#F3C94F')
    $boltFill = [System.Drawing.ColorTranslator]::FromHtml('#FFC94D')
    $boltEdge = [System.Drawing.ColorTranslator]::FromHtml('#E8A500')

    if ($stage -eq 'legacy') {
        $rect = New-Object System.Drawing.RectangleF(0, 0, $size, $size)
        $bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $rect, [System.Drawing.ColorTranslator]::FromHtml('#1D2C50'),
            [System.Drawing.ColorTranslator]::FromHtml('#0E1830'), 90.0)
        $g.FillPath($bgBrush, (New-RoundedPath 0 0 $size $size (116 * $s) $null))
        # 票据
        $g.FillPath((New-Object System.Drawing.SolidBrush $fg), (New-RoundedPath (150*$s) (118*$s) (212*$s) (276*$s) (18*$s) $null))
        # 顶部打孔(背景近似色,视觉镂空)
        $holeBrush = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#111B33'))
        foreach ($pair in $holes) {
            $cx = [double]$pair[0]; $cr = [double]$pair[1]
            $g.FillEllipse($holeBrush, [float](($cx - $cr) * $s), [float]((152 - $cr) * $s), [float](2 * $cr * $s), [float](2 * $cr * $s))
        }
    } elseif ($stage -eq 'fg') {
        $g.FillPath((New-Object System.Drawing.SolidBrush $fg), (New-RoundedPath (150*$s) (118*$s) (212*$s) (276*$s) (18*$s) $holes))
    } else {
        # monochrome:全白剪影
        $g.FillPath((New-Object System.Drawing.SolidBrush $fg), (New-RoundedPath (150*$s) (118*$s) (212*$s) (276*$s) (18*$s) $holes))
    }

    # 账单行(legacy 与 fg 用彩色;mono 全白)
    $rows = @( @(166, 346, 196, $lineGray), @(166, 306, 230, $lineGray), @(166, 346, 264, $lineGold) )
    foreach ($row in $rows) {
        $col = $row[3]
        if ($stage -eq 'mono') { $col = $fg }
        $g.DrawLine((New-RoundPen $col 14 $s), [float]($row[0]*$s), [float]($row[2]*$s), [float]($row[1]*$s), [float]($row[2]*$s))
    }

    # 闪电
    $pts = New-Object 'System.Drawing.PointF[]' 6
    $pts[0] = New-Object System.Drawing.PointF (308*$s), (240*$s)
    $pts[1] = New-Object System.Drawing.PointF (264*$s), (306*$s)
    $pts[2] = New-Object System.Drawing.PointF (294*$s), (306*$s)
    $pts[3] = New-Object System.Drawing.PointF (276*$s), (362*$s)
    $pts[4] = New-Object System.Drawing.PointF (338*$s), (288*$s)
    $pts[5] = New-Object System.Drawing.PointF (306*$s), (288*$s)
    if ($stage -eq 'mono') {
        $g.FillPolygon((New-Object System.Drawing.SolidBrush $fg), $pts)
    } else {
        $g.FillPolygon((New-Object System.Drawing.SolidBrush $boltFill), $pts)
        $g.DrawPolygon((New-RoundPen $boltEdge 6 $s), $pts)
    }

    $g.Dispose()
    $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

# 旧式图标
foreach ($pair in @( @('mdpi',48), @('hdpi',72), @('xhdpi',96), @('xxhdpi',144), @('xxxhdpi',192) )) {
    Draw-Icon $pair[1] 'legacy' "$res\mipmap-$($pair[0])\ic_launcher.png"
}
# 自适应前景 + 单色
foreach ($pair in @( @('mdpi',108), @('hdpi',162), @('xhdpi',216), @('xxhdpi',324), @('xxxhdpi',432) )) {
    Draw-Icon $pair[1] 'fg' "$res\drawable-$($pair[0])\ic_launcher_foreground.png"
    Draw-Icon $pair[1] 'mono' "$res\drawable-$($pair[0])\ic_launcher_monochrome.png"
}

# Web 端品牌资源(server/frontend/apps/web/public/branding)
# 与 Android 同款全图样式(渐变背景 + 票据),供 manifest / favicon / 侧边栏 logo 使用。
$webBranding = "D:\gitee\auto-ledger\server\frontend\apps\web\public\branding"
foreach ($pair in @( @('icon-512',512), @('icon-192',192), @('favicon-216',216) )) {
    Draw-Icon $pair[1] 'legacy' "$webBranding\$($pair[0]).png"
}
Write-Host "done: 15 android icons + 3 web branding icons generated"
