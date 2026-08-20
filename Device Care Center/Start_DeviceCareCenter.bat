@echo off
REM Device Care Center Launcher
REM Double-click this file to start the application

setlocal enabledelayedexpansion

REM Get the directory where this batch file is located
set "scriptDir=%~dp0"

REM Launch PowerShell with the DeviceCareCenter.ps1 script.
REM -NoProfile for faster startup, -ExecutionPolicy Bypass to run scripts,
REM -STA because the app is a WinForms GUI, -WindowStyle Hidden so no
REM console window flashes up before the app hides it (belt and suspenders
REM with the app's own Hide-ConsoleWindow call).
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%scriptDir%DeviceCareCenter.ps1"

exit
