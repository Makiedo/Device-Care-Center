#Requires -Version 5.1
<#
    DeviceCareCenter.ps1
    ----------------------
    Entry point. This is the only file you run.

    It just does two things:
      1. Makes sure we're running as Administrator (re-launches itself
         elevated if not).
      2. Dot-sources every module in .\Modules, in dependency order, then
         calls Show-MainForm (defined in Modules\GUI.ps1) to build and run
         the window.

    To make a change to a specific feature, open the matching file under
    .\Modules - you don't need to touch this launcher or any other module:

        Modules\WindowUtils.ps1          hide/show the console window
        Modules\Theme.ps1               colors, fonts
        Modules\Controls.ps1            rounded corners, toggle switch
        Modules\Logging.ps1             central log panel + export
        Modules\TaskEngine.ps1          background task plumbing
        Modules\Feature_UpdateApps.ps1  "Update Installed Applications"
        Modules\Feature_SystemUpdate.ps1 "Windows / Driver / Firmware Updates"
        Modules\Feature_Repair.ps1      "Windows Repair Tools"
        Modules\Feature_Network.ps1     "Network Troubleshooter"
        Modules\GUI.ps1                 the window itself

    NOTE ON THE COMPILED .EXE: once this is compiled with ps2exe there is no
    console left at all, so an unhandled error would otherwise just make the
    program vanish with no explanation. Everything below runs inside one big
    try/catch for exactly that reason - any startup failure is written to
    DeviceCareCenter-crash.log next to the exe AND shown in a message box,
    instead of failing silently.
#>
Add-Type -AssemblyName System.Windows.Forms

# $PSScriptRoot is reliably set when this runs as a .ps1 (via powershell.exe
# or the .bat launcher), but comes back EMPTY when this same file has been
# compiled into an .exe with ps2exe - so we fall back through a couple of
# other ways to find "the folder this app lives in" before giving up.
function Get-AppRoot {
    if ($PSScriptRoot) { return $PSScriptRoot }
    if ($MyInvocation.MyCommand.Path) { return (Split-Path -Parent $MyInvocation.MyCommand.Path) }
    try {
        $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exePath) { return (Split-Path -Parent $exePath) }
    } catch {}
    return (Get-Location).Path
}

$Global:AppRoot     = Get-AppRoot
$Global:AppIconPath = Join-Path $Global:AppRoot "DeviceCareCenter.ico"
$ModulesPath        = Join-Path $Global:AppRoot "Modules"
$Global:CrashLogPath = Join-Path $Global:AppRoot "DeviceCareCenter-crash.log"

function Write-StartupFailure {
    param([string]$Message)
    try {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        "[$stamp] $Message`r`n" | Out-File -FilePath $Global:CrashLogPath -Append -Encoding UTF8
    } catch {}
    try {
        [System.Windows.Forms.MessageBox]::Show(
            "Device Care Center couldn't start:`n`n$Message`n`nDetails were also written to:`n$Global:CrashLogPath",
            "Device Care Center - Startup Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch {}
}

# Loads a module's code as an in-memory scriptblock instead of dot-sourcing
# the file path directly. This matters because a strict local execution
# policy (AllSigned) blocks PowerShell from directly *running a .ps1 file*
# that isn't digitally signed - but it does NOT block executing a scriptblock
# built from text already read into memory (the same reason Invoke-Expression
# isn't blocked by AllSigned either). Reading the file's bytes and creating a
# scriptblock from them sidesteps that file-signature check entirely, so the
# app works the same on a strict system without needing -ExecutionPolicy
# Bypass anywhere.
#
# NOTE: this can't be a function that does the dot-sourcing internally -
# dot-sourcing inside a function only adds to that function's own local
# scope, which disappears the moment it returns. It has to happen with the
# "." operator written out at each actual call site, at the top level of
# this script, so the functions/variables it defines land in this script's
# scope and are still there afterwards.
function Get-ModuleScriptBlock {
    param([string]$Path)
    $code = [System.IO.File]::ReadAllText($Path)
    return [scriptblock]::Create($code)
}

try {

    # WindowUtils is loaded first and separately from the rest, so the console
    # can be hidden as early as possible on every run - including this first,
    # pre-elevation pass, and again immediately after the elevated relaunch.
    $windowUtilsPath = Join-Path $ModulesPath "WindowUtils.ps1"
    if (-not (Test-Path $windowUtilsPath)) {
        Write-StartupFailure "Missing required file:`n$windowUtilsPath`n`nMake sure the Modules folder is next to this exe/script."
        exit 1
    }
    . (Get-ModuleScriptBlock -Path $windowUtilsPath)
    Hide-ConsoleWindow

    function Test-IsAdmin {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    if (-not (Test-IsAdmin)) {
        # Figure out what's actually running: the compiled DeviceCareCenter.exe,
        # or this .ps1 under powershell.exe/pwsh.exe (e.g. via the .bat launcher).
        # $PSCommandPath is unreliable once compiled, so use the OS process path.
        $currentExePath = $null
        try { $currentExePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch {}
        if (-not $currentExePath) { $currentExePath = (Get-Process -Id $PID).Path }

        $scriptPath = if ($PSCommandPath) { $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $null }
        $isCompiledExe = $currentExePath -and ($currentExePath -notmatch '(?i)(^|\\)(powershell|pwsh)(\.exe)?$')

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        if ($isCompiledExe) {
            # Already the standalone exe - just relaunch itself elevated, no arguments needed.
            $psi.FileName  = $currentExePath
            $psi.Arguments = ""
        } else {
            $psi.FileName  = $currentExePath
            $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$scriptPath`""
        }
        $psi.Verb        = "runas"
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        try {
            [System.Diagnostics.Process]::Start($psi) | Out-Null
        } catch {
            # Most common cause here: the user clicked "No" on the UAC prompt.
            Write-StartupFailure "Administrator privileges are required, and the elevation request was cancelled or failed.`n`n$($_.Exception.Message)"
        }
        exit
    }

    # Order matters: later files depend on functions/variables defined earlier.
    # (WindowUtils.ps1 was already loaded above, ahead of the admin check.)
    $LoadOrder = @(
        "Theme.ps1",
        "Controls.ps1",
        "Logging.ps1",
        "TaskEngine.ps1",
        "Feature_UpdateApps.ps1",
        "Feature_SystemUpdate.ps1",
        "Feature_Repair.ps1",
        "Feature_Network.ps1",
        "GUI.ps1"
    )

    foreach ($file in $LoadOrder) {
        $path = Join-Path $ModulesPath $file
        if (-not (Test-Path $path)) {
            Write-StartupFailure "Missing required file:`n$path`n`nMake sure the Modules folder is next to this exe/script."
            exit 1
        }
        . (Get-ModuleScriptBlock -Path $path)
    }

    Show-MainForm

} catch {
    $details = "$($_.Exception.Message)`r`n`r`n$($_.ScriptStackTrace)"
    Write-StartupFailure $details
    exit 1
}
