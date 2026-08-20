<#
    Feature.SystemUpdate.ps1
    -------------------------
    Dashboard card 2: "Windows / Driver / Firmware Updates"

    Uses the Windows Update Agent (WUA) COM API directly - the same engine
    behind Settings > Windows Update - rather than a third-party module, so
    it works reliably without needing anything installed from PSGallery.

    SCOPE: this targets everything Settings > Windows Update > Advanced
    options > Optional updates covers, plus Microsoft Update content
    (Office, .NET, drivers, firmware, Defender definitions) - not just
    core Windows updates. Concretely:

      1. Register the Microsoft Update service (equivalent to Settings'
         "Receive updates for other Microsoft products" toggle). Without
         this, WUA only searches the base Windows Update catalog and never
         sees drivers, firmware, Office, or .NET updates at all - this was
         the main gap in the previous version of this module.
      2. Search that broadened catalog for everything not installed and
         not explicitly hidden by the user.
      3. Classify each result into a friendly category (Driver, Firmware,
         Security Update, Cumulative Update, .NET, Defender Definition,
         etc.) for reporting - WUA doesn't expose one single authoritative
         "category" property, so this combines Type, DriverClass, and the
         update's own Category names.
      4. Install everything found, in two passes that mirror Settings
         exactly:
           Pass 1: Recommended  - what Settings installs on "Check for
                   updates" (quality/security/cumulative/feature updates).
                   WUA marks these AutoSelectOnWebSites = $true.
           Pass 2: Optional     - what Settings puts under Advanced options
                   > Optional updates (drivers, firmware, OEM updates,
                   preview builds). WUA marks these AutoSelectOnWebSites
                   = $false. This is the same list Settings' "Optional
                   updates" page shows - nothing here is skipped or
                   filtered out by category.
      5. Run a supplementary Defender signature update via Update-
         MpSignature - WUA's own coverage of definition updates can be
         inconsistent, and this is the dedicated, more reliable mechanism
         Windows itself ships for that one category specifically.

    DELIBERATE, NOT A GAP: updates the user has explicitly hidden
    (IsHidden=1) are still excluded. Settings itself never shows hidden
    updates either - force-installing something a user deliberately
    dismissed would be surprising, unwanted behavior for a maintenance
    tool, not a bug to fix.

    KNOWN API LIMITATION (cannot be closed from user-mode code): feature
    updates (major version upgrades, e.g. "Feature update to Windows 11,
    version 24H2") are frequently NOT returned by ANY WUA-based search,
    even when Settings shows one waiting. Settings triggers those through
    a separate, more privileged internal component ("Seeker") tied to
    Microsoft's phased-rollout targeting for this specific device, which
    is not exposed through the public WUA COM API at all. This is a gap
    shared by every WUA-based automation tool (including well-known
    PowerShell modules like PSWindowsUpdate), not something specific to
    this script. When a feature update is the only thing pending, this
    module says so plainly rather than claiming a clean "up to date"
    result, and directs the person to Settings for that specific case.

    Exposes Get-Worker_SystemUpdate. Note this function does not take an
    -AutoReboot parameter - the worker it returns runs in an isolated
    runspace via New-WorkerScript's text-reconstruction, which can't see a
    PowerShell function's own parameter closures, only whatever is
    explicitly injected as "$Sync". The auto-reboot preference is applied
    by the caller directly onto $Sync (see Start-Task in GUI.ps1) instead.

    $Sync contract preserved for the rest of the app (GUI.ps1 depends on
    these): .Done, .Success, .Summary, .RebootRequired. This version adds
    .UpdateReport - a structured [PSCustomObject] summary (counts by
    category, per-update results, reboot state) for anything that wants to
    consume results programmatically rather than parsing the friendly log.
#>

function Get-Worker_SystemUpdate {
    return New-WorkerScript {
        # NOTE: $Sync.AutoReboot is set by the caller (Start-Task, in GUI.ps1)
        # BEFORE this worker starts running - not here. Worker scriptblocks
        # are reconstructed from plain source text to run in an isolated
        # runspace (see New-WorkerScript), so they only ever see whatever is
        # explicitly injected as "$Sync" - a reference to a PowerShell
        # function's own parameter would silently resolve to $null here,
        # since that parameter binding doesn't survive the text-reconstruction step.
        $rebootRequired = $false
        $muServiceId = "7971f918-a847-4430-9279-4a52d1efe18d"  # Microsoft Update - Microsoft-documented, stable GUID

        # ------------------------------------------------------------------
        # Classifies an update into a friendly category for reporting. WUA
        # has no single authoritative "category" property, so this combines
        # Type (Driver vs Software), the update's own Category names, and a
        # few title patterns for the cases WUA's categories don't already
        # make obvious (feature updates, .NET).
        # ------------------------------------------------------------------
        function Get-UpdateCategoryLabel {
            param($Update)

            try {
                # UpdateType enum: 1 = Driver, 2 = Software
                if ($Update.Type -eq 1) {
                    return "Driver"
                }
            } catch {}

            $catNames = @()
            try { $catNames = @($Update.Categories | ForEach-Object { $_.Name }) } catch {}

            if ($catNames -contains "Firmware") { return "Firmware" }
            if ($catNames -contains "Feature Packs" -or "$($Update.Title)" -match "Feature update to") { return "Feature Update" }
            if ($catNames -contains "Definition Updates") { return "Defender Definition Update" }
            if ("$($Update.Title)" -match "\.NET") { return ".NET Update" }
            if ($catNames -contains "Critical Updates") { return "Critical Update" }
            try { if ($Update.MsrcSeverity) { return "Security Update" } } catch {}
            if ($catNames -contains "Security Updates") { return "Security Update" }
            if ("$($Update.Title)" -match "Cumulative Update") { return "Cumulative Update" }
            if ($catNames -contains "Service Packs") { return "Service Pack" }
            if ($catNames -contains "Update Rollups") { return "Update Rollup" }
            if ($catNames -contains "Tools") { return "Tool" }
            if ($catNames.Count -gt 0) { return $catNames[0] }
            return "Other Update"
        }

        # ------------------------------------------------------------------
        # Connect to Windows Update
        # ------------------------------------------------------------------
        Set-WorkProgress -Sync $Sync -Phase "Preparing" -Status "Connecting to Windows Update..." -Percent 2
        Add-WorkCommand -Sync $Sync -Command "New-Object -ComObject Microsoft.Update.Session"
        try {
            $session = New-Object -ComObject Microsoft.Update.Session
            $session.ClientApplicationID = "Device Care Center"
        } catch {
            Add-WorkLog -Sync $Sync -Text "Could not connect to the Windows Update service: $($_.Exception.Message)" -Level "Error"
            $Sync.Done = $true
            $Sync.Success = $false
            $Sync.Summary = "Windows Update service is unavailable on this PC. Make sure the 'Windows Update' service is running, then try again."
            return
        }

        if ($Sync.StopRequested) { $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled."; return }

        # ------------------------------------------------------------------
        # Check for a reboot already pending from an earlier update. WUA can
        # behave unreliably - including throwing errors on install attempts -
        # when a restart is already owed from a previous session, so it's
        # worth stopping here and asking for that restart first rather than
        # attempting installs likely to fail or behave oddly.
        # ------------------------------------------------------------------
        try {
            $sysInfo = New-Object -ComObject Microsoft.Update.SystemInfo
            if ($sysInfo.RebootRequired) {
                Set-WorkProgress -Sync $Sync -Phase "Complete" -Status "A restart is needed before more updates can install." -Percent 100 -ETA "Done"
                $Sync.Done = $true
                $Sync.Success = $true
                $Sync.RebootRequired = $true
                $Sync.Summary = "Windows has updates waiting on a restart from earlier. Please restart your PC, then run this again to continue installing updates."
                return
            }
        } catch {
            # Non-fatal: if this check itself can't run, just proceed normally.
        }

        # ------------------------------------------------------------------
        # Register the Microsoft Update service. This is what actually
        # unlocks driver, firmware, Office, .NET, and Defender-definition
        # updates - equivalent to turning on "Receive updates for other
        # Microsoft products" in Settings. Without this, the search below
        # only ever sees the base Windows Update catalog, no matter how the
        # search criteria itself is written.
        # ------------------------------------------------------------------
        Set-WorkProgress -Sync $Sync -Phase "Preparing" -Status "Registering Microsoft Update (drivers, Office, .NET, Defender definitions)..." -Percent 4
        Add-WorkCommand -Sync $Sync -Command "ServiceManager.AddService2('$muServiceId', 7, '')"
        $muRegistered = $false
        try {
            $serviceManager = New-Object -ComObject Microsoft.Update.ServiceManager
            $existing = $null
            try { $existing = $serviceManager.Services | Where-Object { $_.ServiceID -eq $muServiceId } } catch {}
            if (-not $existing) {
                # Flags 7 = asfAllowPendingRegistration(1) + asfAllowOnlineRegistration(2) + asfRegisterServiceWithAU(4)
                [void]$serviceManager.AddService2($muServiceId, 7, "")
                Add-WorkLog -Sync $Sync -Text "Registered the Microsoft Update service - this is what brings Office, .NET, driver, firmware, and Defender-definition updates into scope, on top of core Windows updates." -Level "Success"
            } else {
                Add-WorkLog -Sync $Sync -Text "Microsoft Update service was already registered on this PC." -Kind "Technical"
            }
            $muRegistered = $true
        } catch {
            Add-WorkLog -Sync $Sync -Text "Could not register the Microsoft Update service: $($_.Exception.Message). Continuing with core Windows updates only - drivers, Office, and .NET updates may not appear this run." -Level "Warning"
        }

        # ------------------------------------------------------------------
        # Search - this is the equivalent of Settings > Windows Update >
        # "Check for updates", but against the broader Microsoft Update
        # catalog (once registered above) rather than just Windows Update.
        # IsHidden=0 excludes updates the user has explicitly dismissed -
        # that's a deliberate choice, not a filtering gap (see header).
        # IsInstalled=0 means "not already installed". No Type filter is
        # applied, so both Software and Driver update types are returned
        # together in one search.
        # ------------------------------------------------------------------
        Set-WorkProgress -Sync $Sync -Phase "Checking for updates" -Status "Checking for updates, including drivers, firmware, and other Microsoft products..." -Percent 6
        Add-WorkCommand -Sync $Sync -Command 'UpdateSearcher.Search("IsInstalled=0 and IsHidden=0")'

        $searcher = $session.CreateUpdateSearcher()
        if ($muRegistered) {
            try {
                $searcher.ServerSelection = 3   # ssOthers - search a specific registered service
                $searcher.ServiceID = $muServiceId
            } catch {
                try { $searcher.ServerSelection = 2 } catch {}   # fall back to Windows Update if targeting MU explicitly fails
            }
        } else {
            try { $searcher.ServerSelection = 2 } catch {}
        }
        try { $searcher.Online = $true } catch {}
        try { $searcher.IncludePotentiallySupersededUpdates = $true } catch {}

        # Retry the search itself a couple of times - transient network/
        # service hiccups here are common and shouldn't fail the whole run.
        $searchResult = $null
        $searchError = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            if ($Sync.StopRequested) { break }
            try {
                $searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0")
                $searchError = $null
                break
            } catch {
                $searchError = $_
                if ($attempt -lt 3) {
                    Add-WorkLog -Sync $Sync -Text "Update search attempt $attempt failed, retrying..." -Kind "Technical"
                    Start-Sleep -Seconds 3
                }
            }
        }
        if ($Sync.StopRequested) { $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled."; return }
        if ($searchError) {
            Add-WorkLog -Sync $Sync -Text "The update search failed after 3 attempts: $($searchError.Exception.Message)" -Level "Error"
            $Sync.Done = $true
            $Sync.Success = $false
            $Sync.Summary = "Could not check for updates. Check your internet connection and try again."
            return
        }

        $allUpdates = @($searchResult.Updates | ForEach-Object { $_ })
        Add-WorkLog -Sync $Sync -Text "Found $($allUpdates.Count) available update(s)."
        $categoryPreview = @{}
        foreach ($u in $allUpdates) {
            $cat = Get-UpdateCategoryLabel -Update $u
            if (-not $categoryPreview.ContainsKey($cat)) { $categoryPreview[$cat] = 0 }
            $categoryPreview[$cat]++
            Add-WorkLog -Sync $Sync -Text "Available ($cat): $($u.Title)" -Kind "Technical"
        }
        foreach ($cat in ($categoryPreview.Keys | Sort-Object)) {
            Add-WorkLog -Sync $Sync -Text "  $cat`: $($categoryPreview[$cat])"
        }

        if ($allUpdates.Count -eq 0) {
            # NOTE (known limitation): feature updates (major version
            # upgrades, e.g. "Feature update to Windows 11, version 24H2")
            # are frequently NOT returned by this kind of direct WUA search,
            # even when Settings > Windows Update shows one waiting. Settings
            # triggers them through a separate, more privileged internal
            # component ("Seeker") that isn't exposed through the public WUA
            # COM API this tool uses - this is a well-known gap shared by
            # most PowerShell/WUA automation, not specific to this search.
            # Say so plainly rather than implying a full, definitive check.
            Set-WorkProgress -Sync $Sync -Phase "Complete" -Status "No updates found through the standard update check." -Percent 100 -ETA "Done"
            $Sync.Done = $true
            $Sync.Success = $true
            $Sync.RebootRequired = $false
            $Sync.UpdateReport = [PSCustomObject]@{
                TotalFound     = 0
                TotalInstalled = 0
                TotalFailed    = 0
                RebootRequired = $false
                Categories     = @{}
                Updates        = @()
            }
            $Sync.Summary = "No updates were found through the standard Windows Update check.

Note: feature updates (major version upgrades) sometimes don't show up here even when Settings > Windows Update lists one as available - Settings can offer those through a channel this tool doesn't have access to. If Settings shows a feature update waiting, please install it from there directly."
            return
        }

        # Recommended = what Settings shows/installs automatically on "Check for updates".
        # Optional    = what Settings puts under Advanced options > Optional updates
        #               (this is where driver, firmware, and OEM updates normally live).
        $recommended = @($allUpdates | Where-Object { $_.AutoSelectOnWebSites })
        $optional    = @($allUpdates | Where-Object { -not $_.AutoSelectOnWebSites })
        Add-WorkLog -Sync $Sync -Text "$($recommended.Count) recommended update(s); $($optional.Count) optional update(s) (drivers, firmware, OEM, previews)."

        if ($Sync.StopRequested) { $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled."; return }

        # Collects one result entry per update across both passes, for the
        # structured report returned at the end.
        $allResults = New-Object System.Collections.Generic.List[PSCustomObject]

        # ------------------------------------------------------------------
        # Downloads and installs one batch of updates, one at a time so
        # progress and per-update results can be reported clearly. Both
        # download and install use WUA's synchronous methods (Download() /
        # Install()), not the async Begin*/End* pair with null callbacks -
        # see the notes further down for why (confirmed via a real HRESULT
        # 0x80004003 / E_POINTER failure at BeginDownload on this system).
        # Trade-off: Stop can only take effect BETWEEN updates, not mid-
        # download/install - acceptable, since updates working correctly
        # matters more than perfect cancellability. Wait-CancellableJob
        # (from TaskEngine.ps1) remains available in case a future
        # COM/async-based module can use it safely.
        #
        # Each update gets up to 2 attempts (1 retry) for transient
        # failures - WUA/network hiccups mid-download or mid-install are
        # common enough to be worth a single automatic retry before giving
        # up and moving on to the next update.
        # ------------------------------------------------------------------
        function Install-UpdateBatch {
            param($Sync, $Session, $Updates, [string]$BatchLabel, [int]$PercentStart, [int]$PercentEnd, $ResultsList)

            if ($Updates.Count -eq 0) {
                Add-WorkLog -Sync $Sync -Text "No $BatchLabel were found."
                return [PSCustomObject]@{ NeedsReboot = $false; Cancelled = $false }
            }

            $needsReboot = $false
            $total = $Updates.Count
            $batchStart = Get-Date
            $maxAttempts = 2

            for ($i = 0; $i -lt $total; $i++) {
                if ($Sync.StopRequested) { return [PSCustomObject]@{ NeedsReboot = $needsReboot; Cancelled = $true } }

                $update = $Updates[$i]
                $category = Get-UpdateCategoryLabel -Update $update
                $pct = $PercentStart + [int]((($i) / $total) * ($PercentEnd - $PercentStart))
                $etaPercent = if ($i -eq 0) { 0 } else { ($i / $total) * 100.0 }
                $eta = if ($i -eq 0) { "Calculating remaining time..." } else { Get-EtaString -StartTime $batchStart -PercentComplete $etaPercent }
                Set-WorkProgress -Sync $Sync -Phase $BatchLabel -Status "Downloading and installing ($($i + 1) of $total): $($update.Title)" -Percent $pct -ETA $eta
                Add-WorkLog -Sync $Sync -Text "$BatchLabel ($($i + 1) of $total) [$category]: $($update.Title)"

                if (-not $update.EulaAccepted) {
                    Add-WorkCommand -Sync $Sync -Command "Update.AcceptEula()  # $($update.Title)"
                    try { $update.AcceptEula() } catch {}
                }

                $entry = [PSCustomObject]@{
                    Title          = $update.Title
                    Category       = $category
                    KB             = ($update.KBArticleIDs -join ", ")
                    Downloaded     = $false
                    Installed      = $false
                    ResultCode     = $null
                    RebootRequired = $false
                    Error          = $null
                }

                $succeeded = $false
                for ($attempt = 1; $attempt -le $maxAttempts -and -not $succeeded; $attempt++) {
                    if ($Sync.StopRequested) {
                        [void]$ResultsList.Add($entry)
                        return [PSCustomObject]@{ NeedsReboot = $needsReboot; Cancelled = $true }
                    }
                    if ($attempt -gt 1) {
                        Add-WorkLog -Sync $Sync -Text "Retrying '$($update.Title)' (attempt $attempt of $maxAttempts)..." -Kind "Technical"
                        Start-Sleep -Seconds 3
                    }

                    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
                    $coll.Add($update) | Out-Null

                    try {
                        if (-not $update.IsDownloaded) {
                            # NOTE: uses the SYNCHRONOUS Download() call, not
                            # BeginDownload(null, null, null). Confirmed via a
                            # real failure: HRESULT 0x80004003 (E_POINTER) at
                            # exactly this call - on this system,
                            # IUpdateDownloader.BeginDownload does NOT tolerate
                            # null progress/completion callbacks, contrary to
                            # what's often documented as the more lenient of
                            # the two WUA async methods. Download() takes no
                            # callback parameters at all, sidestepping this,
                            # the same way Install() already does below.
                            # Trade-off: Stop can no longer interrupt mid-
                            # download either (only before it starts) - the
                            # same trade already accepted for install, and for
                            # the same reason: a working download matters more
                            # than a perfectly cancellable one.
                            Add-WorkCommand -Sync $Sync -Command "UpdateDownloader.Download()  # $($update.Title)"
                            $downloader = $Session.CreateUpdateDownloader()
                            $downloader.ClientApplicationID = "Device Care Center"
                            $downloader.Updates = $coll
                            $downloadResult = $downloader.Download()
                            Add-TerminalOutput -Sync $Sync -Text "Download result code: $($downloadResult.ResultCode)"
                            Add-WorkLog -Sync $Sync -Text "Download result code for '$($update.Title)': $($downloadResult.ResultCode)" -Kind "Technical"
                            $entry.Downloaded = ($downloadResult.ResultCode -eq 2 -or $downloadResult.ResultCode -eq 3)
                        } else {
                            $entry.Downloaded = $true
                        }

                        if ($Sync.StopRequested) {
                            [void]$ResultsList.Add($entry)
                            return [PSCustomObject]@{ NeedsReboot = $needsReboot; Cancelled = $true }
                        }

                        # NOTE: install uses the SYNCHRONOUS Install() call, not
                        # BeginInstall(null, null, null) like the download step
                        # above. IUpdateInstaller is documented to be considerably
                        # stricter than IUpdateDownloader about null progress/
                        # completion callbacks - some internal WUA install code
                        # paths do try to invoke them, and a null reference there
                        # throws exactly "Object reference not set to an instance
                        # of an object" (which looks like a bug in this script but
                        # is really WUA's own internal callback handling). Install()
                        # takes no callback parameters at all, sidestepping this.
                        # Trade-off: Stop can no longer interrupt mid-install (only
                        # before it starts) - acceptable, since installs are
                        # normally much quicker than downloads, and a working
                        # install matters more than a perfectly cancellable one.
                        Add-WorkCommand -Sync $Sync -Command "UpdateInstaller.Install()  # $($update.Title)"
                        $installer = $Session.CreateUpdateInstaller()
                        $installer.ClientApplicationID = "Device Care Center"
                        $installer.ForceQuiet = $true
                        $installer.Updates = $coll
                        $installResult = $installer.Install()
                        Add-TerminalOutput -Sync $Sync -Text "Install result code: $($installResult.ResultCode)"
                        Add-WorkLog -Sync $Sync -Text "Install result code for '$($update.Title)': $($installResult.ResultCode)" -Kind "Technical"

                        $entry.ResultCode = $installResult.ResultCode
                        $entry.RebootRequired = [bool]$installResult.RebootRequired

                        # ResultCode: 2 = Succeeded, 3 = Succeeded With Errors
                        if ($installResult.ResultCode -eq 2 -or $installResult.ResultCode -eq 3) {
                            Add-WorkLog -Sync $Sync -Text "Installed: $($update.Title)" -Level "Success"
                            $entry.Installed = $true
                            $succeeded = $true
                        } else {
                            $entry.Error = "Install result code $($installResult.ResultCode)"
                            if ($attempt -eq $maxAttempts) {
                                Add-WorkLog -Sync $Sync -Text "Could not install: $($update.Title) (result code $($installResult.ResultCode))" -Level "Warning"
                            }
                        }

                        if ($installResult.RebootRequired) { $needsReboot = $true }
                    } catch {
                        $hresult = try { "0x{0:X8}" -f $_.Exception.HResult } catch { "unknown" }
                        $entry.Error = "$($_.Exception.Message) (code $hresult)"
                        Add-TerminalOutput -Sync $Sync -Text "Error ($hresult): $($_.Exception.Message)"
                        if ($attempt -eq $maxAttempts) {
                            Add-WorkLog -Sync $Sync -Text "Error updating '$($update.Title)': $($_.Exception.Message) (code $hresult)" -Level "Warning"
                        }
                    }
                }

                [void]$ResultsList.Add($entry)
            }

            return [PSCustomObject]@{ NeedsReboot = $needsReboot; Cancelled = $false }
        }

        # ------------------------------------------------------------------
        # Pass 1: Recommended updates (Settings > "Check for updates" > Download and install)
        # ------------------------------------------------------------------
        $pass1 = Install-UpdateBatch -Sync $Sync -Session $session -Updates $recommended -BatchLabel "Windows Updates" -PercentStart 10 -PercentEnd 50 -ResultsList $allResults
        if ($pass1.NeedsReboot) { $rebootRequired = $true }
        if ($pass1.Cancelled) {
            $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled during Windows Updates."
            $Sync.UpdateReport = [PSCustomObject]@{ TotalFound = $allUpdates.Count; TotalInstalled = @($allResults | Where-Object Installed).Count; TotalFailed = @($allResults | Where-Object { -not $_.Installed }).Count; RebootRequired = $rebootRequired; Categories = $categoryPreview; Updates = @($allResults) }
            return
        }

        if ($Sync.StopRequested) { $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled."; return }

        # ------------------------------------------------------------------
        # Pass 2: Optional updates (Advanced options > Optional updates > Download & install all)
        # This is where driver, firmware, and OEM updates normally appear.
        # ------------------------------------------------------------------
        $pass2 = Install-UpdateBatch -Sync $Sync -Session $session -Updates $optional -BatchLabel "Optional Updates (drivers, firmware, OEM, previews)" -PercentStart 50 -PercentEnd 88 -ResultsList $allResults
        if ($pass2.NeedsReboot) { $rebootRequired = $true }
        if ($pass2.Cancelled) {
            $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled during optional updates."
            $Sync.UpdateReport = [PSCustomObject]@{ TotalFound = $allUpdates.Count; TotalInstalled = @($allResults | Where-Object Installed).Count; TotalFailed = @($allResults | Where-Object { -not $_.Installed }).Count; RebootRequired = $rebootRequired; Categories = $categoryPreview; Updates = @($allResults) }
            return
        }

        if ($Sync.StopRequested) { $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled."; return }

        # ------------------------------------------------------------------
        # Supplementary pass: Defender signature/intelligence updates.
        # WUA's own coverage of definition updates can be inconsistent, so
        # this uses Update-MpSignature directly - the dedicated, more
        # reliable mechanism Windows itself ships for this one category.
        # Best-effort: non-fatal if Defender isn't the active AV (e.g. a
        # third-party antivirus has replaced it) or the cmdlet isn't present.
        # ------------------------------------------------------------------
        Set-WorkProgress -Sync $Sync -Phase "Defender definitions" -Status "Updating Microsoft Defender security intelligence..." -Percent 92
        if (Get-Command Update-MpSignature -ErrorAction SilentlyContinue) {
            Add-WorkCommand -Sync $Sync -Command "Update-MpSignature -UpdateSource MicrosoftUpdateServer"
            try {
                Update-MpSignature -UpdateSource MicrosoftUpdateServer -ErrorAction Stop
                Add-WorkLog -Sync $Sync -Text "Microsoft Defender security intelligence is up to date." -Level "Success"
            } catch {
                Add-WorkLog -Sync $Sync -Text "Could not update Defender security intelligence: $($_.Exception.Message)" -Kind "Technical"
            }
        } else {
            Add-WorkLog -Sync $Sync -Text "Update-MpSignature isn't available on this PC (Defender may not be the active antivirus) - skipping." -Kind "Technical"
        }

        $totalInstalled = @($allResults | Where-Object Installed).Count
        $totalFailed = @($allResults | Where-Object { -not $_.Installed }).Count

        $Sync.RebootRequired = $rebootRequired
        $Sync.UpdateReport = [PSCustomObject]@{
            TotalFound     = $allUpdates.Count
            TotalInstalled = $totalInstalled
            TotalFailed    = $totalFailed
            RebootRequired = $rebootRequired
            Categories     = $categoryPreview
            Updates        = @($allResults)
        }

        Set-WorkProgress -Sync $Sync -Phase "Complete" -Status "Windows Update pass finished (recommended + optional + Defender definitions)." -Percent 100 -ETA "Done"
        $Sync.Done = $true
        $Sync.Success = $true
        $categorySummary = ($categoryPreview.Keys | Sort-Object | ForEach-Object { "$_ ($($categoryPreview[$_]))" }) -join ", "
        $Sync.Summary = if ($rebootRequired) {
            "Installed $totalInstalled of $($allUpdates.Count) update(s)$(if ($totalFailed -gt 0) { ", $totalFailed could not be installed" }). Categories found: $categorySummary. A restart is required to finish applying them."
        } else {
            "Installed $totalInstalled of $($allUpdates.Count) update(s)$(if ($totalFailed -gt 0) { ", $totalFailed could not be installed" }). Categories found: $categorySummary. No restart is currently required."
        }
    }
}
