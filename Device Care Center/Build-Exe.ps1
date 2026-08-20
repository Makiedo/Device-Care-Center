<#
    Build-Exe.ps1
    --------------
    Run this ONCE, on your own Windows PC, in a normal (non-elevated)
    PowerShell window, from inside this folder:

        cd path\to\DeviceCareCenter
        .\Build-Exe.ps1

    What it does:
      1. Installs the "ps2exe" module from the PowerShell Gallery if it
         isn't already installed (this needs internet access, one time).
      2. Compiles DeviceCareCenter.ps1 into DeviceCareCenter.exe, with
         DeviceCareCenter.ico embedded as:
           - the .exe file's own icon (what you see in Explorer)
           - the icon requested elevation (UAC) prompt uses
         GUI.ps1 already sets that same .ico as the running window's
         icon, which Windows also uses for the taskbar button - so the
         .ico shows up everywhere: file, UAC prompt, title bar, taskbar.
      3. The compiled .exe has an admin-required manifest baked in, so
         Windows elevates it automatically via UAC - no separate console
         window ever flashes up.

    After this finishes, DeviceCareCenter.exe sits next to this script.
    You can copy DeviceCareCenter.exe + DeviceCareCenter.ico + the
    Modules folder anywhere as a set and it will keep working (the exe
    still dot-sources the modules in .\Modules next to it, same as the
    .ps1 does).

    TROUBLESHOOTING: if the exe doesn't appear to do anything when you
    run it, check for DeviceCareCenter-crash.log next to the exe - the
    app writes any startup error there (and shows it in a message box)
    instead of failing silently.

    You do NOT need to keep this Build-Exe.ps1 file after building - it's
    only a build tool, not something the app needs at runtime.
#>

#Requires -Version 5.1

$ErrorActionPreference = "Stop"

$root      = $PSScriptRoot
$sourcePs1 = Join-Path $root "DeviceCareCenter.ps1"
$iconFile  = Join-Path $root "DeviceCareCenter.ico"
$outExe    = Join-Path $root "DeviceCareCenter.exe"

if (-not (Test-Path $sourcePs1)) { throw "Can't find DeviceCareCenter.ps1 next to this build script." }
if (-not (Test-Path $iconFile))  { throw "Can't find DeviceCareCenter.ico next to this build script." }

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "Installing the ps2exe module (one-time, needs internet access)..." -ForegroundColor Cyan
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
}

Import-Module ps2exe -Force

Write-Host "Compiling DeviceCareCenter.exe ..." -ForegroundColor Cyan

Invoke-ps2exe `
    -inputFile      $sourcePs1 `
    -outputFile     $outExe `
    -iconFile       $iconFile `
    -title          "Device Care Center" `
    -product        "Device Care Center" `
    -description    "Guided PC maintenance" `
    -company        "Device Care Center" `
    -noConsole `
    -noOutput `
    -requireAdmin `
    -STA
if (Test-Path $outExe) {
    Write-Host ""
    Write-Host "Done. Created: $outExe" -ForegroundColor Green
    Write-Host "Double-click DeviceCareCenter.exe to run it (Modules folder must stay next to it)."
} else {
    Write-Host "Build did not produce an exe - check the messages above for errors." -ForegroundColor Red
}
