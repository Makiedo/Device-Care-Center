<#
    Theme.ps1
    ---------
    Central place for colors, fonts, and font helpers. Change values here to
    re-skin the whole app - nothing else needs to be touched.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Theme = @{
    Background     = [System.Drawing.Color]::FromArgb(255, 32, 32, 32)
    Surface        = [System.Drawing.Color]::FromArgb(255, 43, 43, 43)
    SurfaceAlt     = [System.Drawing.Color]::FromArgb(255, 54, 54, 54)
    Accent         = [System.Drawing.Color]::FromArgb(255, 0, 120, 212)
    AccentHover    = [System.Drawing.Color]::FromArgb(255, 28, 142, 230)
    Success        = [System.Drawing.Color]::FromArgb(255, 108, 203, 95)
    Warning        = [System.Drawing.Color]::FromArgb(255, 255, 185, 0)
    Error          = [System.Drawing.Color]::FromArgb(255, 232, 89, 89)
    TextPrimary    = [System.Drawing.Color]::FromArgb(255, 245, 245, 245)
    TextSecondary  = [System.Drawing.Color]::FromArgb(255, 175, 175, 175)
    Border         = [System.Drawing.Color]::FromArgb(255, 70, 70, 70)
}

# Prefer Segoe UI Variable (Win11); fall back gracefully on older systems.
$FontFamily = "Segoe UI Variable"
try {
    $testFont = New-Object System.Drawing.Font($FontFamily, 9)
    if ($testFont.Name -ne $FontFamily) { $FontFamily = "Segoe UI" }
} catch { $FontFamily = "Segoe UI" }

function New-Font {
    param([single]$Size, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
    return New-Object System.Drawing.Font($FontFamily, $Size, $Style)
}
