<#
    Feature.UpdateApps.ps1
    -----------------------
    Dashboard card 1: "Update Installed Applications"

    Winget-only. Makes sure winget itself is installed (installing it if
    needed) then runs:
        winget upgrade --all --silent --include-unknown --accept-package-agreements --accept-source-agreements
    Exposes $Worker_UpdateApps for GUI.ps1 to hand to Start-Task.
#>

$Worker_UpdateApps = New-WorkerScript {

    function Test-WingetAvailable {
        return [bool](Get-Command winget -ErrorAction SilentlyContinue)
    }

    # ------------------------------------------------------------------
    # Step 1: make sure winget is installed
    # ------------------------------------------------------------------
    Set-WorkProgress -Sync $Sync -Phase "Checking for winget" -Status "Looking for the Windows Package Manager (winget)..." -Percent 3
    Add-WorkLog -Sync $Sync -Text "Checking whether winget is installed."

    if (-not (Test-WingetAvailable)) {
        Add-WorkLog -Sync $Sync -Text "winget was not found. Installing it now." -Level "Warning"
        Set-WorkProgress -Sync $Sync -Phase "Installing winget" -Status "winget isn't installed yet - installing the Windows Package Manager..." -Percent 8

        $installedOk = $false

        # First, try re-registering an already-present-but-unregistered copy
        # (common after some Windows resets/user-profile issues). Cheap to try.
        try {
            Add-WorkCommand -Sync $Sync -Command 'Add-AppxPackage -RegisterByFamilyName -MainPackage "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe"'
            Add-AppxPackage -RegisterByFamilyName -MainPackage "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" -ErrorAction Stop
            Start-Sleep -Seconds 2
            if (Test-WingetAvailable) {
                $installedOk = $true
                Add-WorkLog -Sync $Sync -Text "winget was already present and has been re-registered successfully." -Level "Success"
            }
        } catch {
            Add-WorkLog -Sync $Sync -Text "Re-registration attempt did not apply (this is normal if winget was never installed)."
            Add-WorkLog -Sync $Sync -Text "$($_.Exception.Message)" -Kind "Technical"
        }

        if ($Sync.StopRequested) { $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled."; return }

        # If that didn't work, download and install the App Installer package
        # (which provides winget) directly from Microsoft's GitHub releases.
        if (-not $installedOk) {
            try {
                Set-WorkProgress -Sync $Sync -Phase "Installing winget" -Status "Downloading the App Installer package..." -Percent 15
                $tempDir = Join-Path $env:TEMP "DeviceCareCenter-winget"
                New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

                $depsUrl   = "https://github.com/microsoft/winget-cli/releases/latest/download/DesktopAppInstaller_Dependencies.zip"
                $mainUrl   = "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
                $licenseUrl = "https://github.com/microsoft/winget-cli/releases/latest/download/8fdb2f56-7bcd-4d6c-98c4-c8fb5b70e8c8_License1.xml"

                $mainPath = Join-Path $tempDir "AppInstaller.msixbundle"
                $depsZip  = Join-Path $tempDir "Dependencies.zip"
                $depsDir  = Join-Path $tempDir "Dependencies"

                Add-WorkCommand -Sync $Sync -Command "Invoke-WebRequest -Uri $mainUrl -OutFile $mainPath"
                Invoke-WebRequest -Uri $mainUrl -OutFile $mainPath -UseBasicParsing -ErrorAction Stop
                Add-WorkLog -Sync $Sync -Text "Downloaded the App Installer package."

                if ($Sync.StopRequested) { $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled."; return }

                Set-WorkProgress -Sync $Sync -Phase "Installing winget" -Status "Downloading required dependencies..." -Percent 35
                Add-WorkCommand -Sync $Sync -Command "Invoke-WebRequest -Uri $depsUrl -OutFile $depsZip"
                Invoke-WebRequest -Uri $depsUrl -OutFile $depsZip -UseBasicParsing -ErrorAction Stop
                Expand-Archive -Path $depsZip -DestinationPath $depsDir -Force

                $arch = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
                $depPackages = Get-ChildItem -Path $depsDir -Recurse -Filter "*$arch*.appx" -ErrorAction SilentlyContinue

                Set-WorkProgress -Sync $Sync -Phase "Installing winget" -Status "Installing dependencies..." -Percent 55
                foreach ($dep in $depPackages) {
                    try {
                        Add-WorkCommand -Sync $Sync -Command "Add-AppxPackage -Path `"$($dep.FullName)`""
                        Add-AppxPackage -Path $dep.FullName -ErrorAction Stop
                    }
                    catch { Add-WorkLog -Sync $Sync -Text "Dependency $($dep.Name) may already be installed: $($_.Exception.Message)" }
                }

                if ($Sync.StopRequested) { $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled."; return }

                Set-WorkProgress -Sync $Sync -Phase "Installing winget" -Status "Installing the Windows Package Manager..." -Percent 75
                try {
                    $licensePath = Join-Path $tempDir "License1.xml"
                    Invoke-WebRequest -Uri $licenseUrl -OutFile $licensePath -UseBasicParsing -ErrorAction Stop
                    Add-WorkCommand -Sync $Sync -Command "Add-AppxProvisionedPackage -Online -PackagePath `"$mainPath`" -LicensePath `"$licensePath`""
                    Add-AppxProvisionedPackage -Online -PackagePath $mainPath -LicensePath $licensePath -ErrorAction Stop | Out-Null
                } catch {
                    # Fall back to a plain Add-AppxPackage install (works for the current user without provisioning)
                    Add-WorkCommand -Sync $Sync -Command "Add-AppxPackage -Path `"$mainPath`""
                    Add-AppxPackage -Path $mainPath -ErrorAction Stop
                }

                Start-Sleep -Seconds 3
                if (Test-WingetAvailable) {
                    $installedOk = $true
                    Add-WorkLog -Sync $Sync -Text "winget installed successfully." -Level "Success"
                }

                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            } catch {
                Add-WorkLog -Sync $Sync -Text "Automatic winget install failed: $($_.Exception.Message)" -Level "Error"
            }
        }

        if (-not $installedOk -and -not (Test-WingetAvailable)) {
            Set-WorkProgress -Sync $Sync -Phase "Complete" -Status "Could not install winget." -Percent 100 -ETA "Done"
            $Sync.Done = $true
            $Sync.Success = $false
            $Sync.Summary = "winget could not be installed automatically. Please install 'App Installer' from the Microsoft Store, then try again."
            return
        }
    } else {
        Add-WorkLog -Sync $Sync -Text "winget is already installed."
    }

    if ($Sync.StopRequested) { $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled."; return }

    # ------------------------------------------------------------------
    # Step 2a: find out what has an update, in plain language, before
    # touching anything - this is a listing-only call (no --all, no
    # --silent), so it's fast and doesn't install or change anything.
    # ------------------------------------------------------------------
    Set-WorkProgress -Sync $Sync -Phase "Updating applications" -Status "Checking for available application updates..." -Percent 80 -ETA "A few minutes"
    Add-WorkLog -Sync $Sync -Text "Checking installed applications for available updates."
    Add-WorkCommand -Sync $Sync -Command "winget upgrade --include-unknown --accept-source-agreements"

    $listLines = New-Object System.Collections.Generic.List[string]
    try {
        Invoke-LiveProcess -Sync $Sync -FilePath "winget.exe" -ArgumentList @("upgrade", "--include-unknown", "--accept-source-agreements") -OnLine {
            param($Sync, $line)
            Add-TerminalOutput -Sync $Sync -Text ([string]$line)
            $listLines.Add([string]$line)
        } | Out-Null
    } catch {
        Add-WorkLog -Sync $Sync -Text "Could not read the list of specific apps ahead of time: $($_.Exception.Message)" -Kind "Technical"
    }

    if ($Sync.StopRequested) { $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled."; return }

    # Parse the table by the header row's column positions (app names can
    # contain spaces, so a simple whitespace split would cut names apart).
    $appNames = New-Object System.Collections.Generic.List[string]
    $headerIdx = -1
    for ($i = 0; $i -lt $listLines.Count; $i++) {
        if ($listLines[$i] -match '^Name\s+Id\s+Version') { $headerIdx = $i; break }
    }
    if ($headerIdx -ge 0) {
        $idCol = $listLines[$headerIdx].IndexOf("Id")
        $dataStart = $headerIdx + 1
        while ($dataStart -lt $listLines.Count -and $listLines[$dataStart] -match '^[-\s]*$') { $dataStart++ }
        for ($i = $dataStart; $i -lt $listLines.Count; $i++) {
            $row = $listLines[$i]
            if ([string]::IsNullOrWhiteSpace($row)) { break }
            if ($row.Length -lt $idCol) { continue }
            $name = $row.Substring(0, $idCol).Trim()
            if ($name.Length -gt 0) { $appNames.Add($name) }
        }
    }

    if ($appNames.Count -gt 0) {
        Add-WorkLog -Sync $Sync -Text "Found $($appNames.Count) app$(if ($appNames.Count -ne 1) { 's' }) with an update available:"
        foreach ($n in $appNames) { Add-WorkLog -Sync $Sync -Text "  - $n" }
    } elseif ($headerIdx -ge 0) {
        # The listing ran and returned a table with zero rows - genuinely nothing to update.
        Set-WorkProgress -Sync $Sync -Phase "Complete" -Status "All applications are up to date." -Percent 100 -ETA "Done"
        $Sync.Done = $true
        $Sync.Success = $true
        $Sync.Summary = "All applications are already up to date - winget found nothing to update."
        return
    } else {
        Add-WorkLog -Sync $Sync -Text "Couldn't read the specific list of app names ahead of time, but checking for updates now."
    }

    if ($Sync.StopRequested) { $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled."; return }

    # ------------------------------------------------------------------
    # Step 2b: actually install them, narrating success/failure per app
    # in plain language as winget works through the list live.
    # ------------------------------------------------------------------
    $upgradeOk = $true
    $updatedOk = New-Object System.Collections.Generic.List[string]
    $updatedFailed = New-Object System.Collections.Generic.List[string]
    try {
        $wingetArgs = @("upgrade", "--all", "--silent", "--include-unknown", "--accept-package-agreements", "--accept-source-agreements")
        Add-WorkCommand -Sync $Sync -Command "winget $($wingetArgs -join ' ')"
        Add-WorkLog -Sync $Sync -Text "Installing updates now..."
        # Streamed live via Invoke-LiveProcess (see TaskEngine.ps1) instead of
        # "$out = & winget ... 2>&1", which would buffer everything until
        # winget finished and leave Stop unable to interrupt it mid-upgrade.
        $wingetStart = Get-Date
        $script:currentApp = $null
        $script:appIndex = 0
        $exitCode = Invoke-LiveProcess -Sync $Sync -FilePath "winget.exe" -ArgumentList $wingetArgs -OnLine {
            param($Sync, $line)
            Add-TerminalOutput -Sync $Sync -Text ([string]$line)
            if ("$line" -match '(\d{1,3})%') {
                $pct = [int]$Matches[1]
                $eta = Get-EtaString -StartTime $wingetStart -PercentComplete $pct
                Set-WorkProgress -Sync $Sync -Phase "Updating applications" -Status "Installing application updates... ($pct% complete)" -Percent ([int](80 + ($pct * 0.19))) -ETA $eta
            }

            # winget usually names the app it's currently working on directly;
            # fall back to the order from the earlier listing if it doesn't.
            # NOTE: $script: scope is required here, not just $currentApp/
            # $appIndex - a plain reassignment inside this block (invoked via
            # "&" from Invoke-LiveProcess) would only create a new local
            # variable for that one call and be discarded immediately after,
            # never actually persisting to the next line's callback.
            if ("$line" -match '^Found\s+(.+?)\s+\[') {
                $script:currentApp = $Matches[1].Trim()
            }

            if ("$line" -match 'Successfully installed') {
                $name = if ($script:currentApp) { $script:currentApp } elseif ($script:appIndex -lt $appNames.Count) { $appNames[$script:appIndex] } else { "An application" }
                Add-WorkLog -Sync $Sync -Text "$name updated successfully." -Level "Success"
                $updatedOk.Add($name)
                $script:appIndex++
                $script:currentApp = $null
            } elseif ("$line" -match 'Installer failed|failed with exit code|Installation failed|No applicable update found') {
                $name = if ($script:currentApp) { $script:currentApp } elseif ($script:appIndex -lt $appNames.Count) { $appNames[$script:appIndex] } else { "An application" }
                Add-WorkLog -Sync $Sync -Text "$name could not be updated." -Level "Warning"
                $updatedFailed.Add($name)
                $script:appIndex++
                $script:currentApp = $null
            }
        }
        if ($null -eq $exitCode -or $exitCode -ne 0) { $upgradeOk = $false }
    } catch {
        Add-WorkLog -Sync $Sync -Text "winget upgrade failed: $($_.Exception.Message)" -Level "Error"
        $upgradeOk = $false
    }

    if ($Sync.StopRequested) { $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled during upgrade."; return }

    Set-WorkProgress -Sync $Sync -Phase "Complete" -Status "Application update pass finished." -Percent 100 -ETA "Done"
    $Sync.Done = $true
    $Sync.Success = $upgradeOk
    $Sync.Summary = if ($upgradeOk) {
        if ($updatedOk.Count -gt 0) {
            "Updated $($updatedOk.Count) app$(if ($updatedOk.Count -ne 1) { 's' }): $($updatedOk -join ', ')."
        } else {
            "All applications with available updates were upgraded via winget."
        }
    } else {
        $countNote = if ($updatedFailed.Count -gt 0) { " ($($updatedFailed.Count) app$(if ($updatedFailed.Count -ne 1) { 's' }) affected: $($updatedFailed -join ', '))" } else { "" }
        "Winget ran successfully!

However, one or more applications could not be updated due to an error.$countNote Don't worry this is normal for certain applications and does not indicate a problem with the system.

Please check the log for details if required."
    }
}
