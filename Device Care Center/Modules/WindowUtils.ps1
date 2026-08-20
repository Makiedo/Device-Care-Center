<#
    WindowUtils.ps1
    ----------------
    Lets us hide the PowerShell console window that would otherwise flash up
    behind the GUI (both on first launch and again after the elevation
    relaunch), and show it back on demand when Technical Mode is switched on.

    This is dot-sourced very early by the launcher - before the admin check -
    so the console can be hidden as soon as possible on every run.
#>

if (-not ("Native.ConsoleWindow" -as [type])) {
    Add-Type -Namespace Native -Name ConsoleWindow -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern IntPtr GetConsoleWindow();

[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
}

$Script:SW_HIDE = 0
$Script:SW_SHOW = 5

function Hide-ConsoleWindow {
    $handle = [Native.ConsoleWindow]::GetConsoleWindow()
    if ($handle -ne [IntPtr]::Zero) {
        [Native.ConsoleWindow]::ShowWindow($handle, $Script:SW_HIDE) | Out-Null
    }
}

function Show-ConsoleWindow {
    $handle = [Native.ConsoleWindow]::GetConsoleWindow()
    if ($handle -ne [IntPtr]::Zero) {
        [Native.ConsoleWindow]::ShowWindow($handle, $Script:SW_SHOW) | Out-Null
    }
}
