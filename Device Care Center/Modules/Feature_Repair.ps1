<#
    Feature.Repair.ps1
    -------------------
    Dashboard card 3: "Windows Repair Tools"

    Runs CHKDSK -> DISM -> SFC in order, parsing each tool's console output
    for a live progress percentage. CHKDSK on the system drive can't run
    live, so it's scheduled for the next restart instead.
    Exposes $Worker_Repair.
#>

$Worker_Repair = New-WorkerScript {
    $Sync.CheckDiskScheduled = $false

    if ($Sync.StopRequested) { $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled."; return }

    # ---- Step 1: CHKDSK ----
    Set-WorkProgress -Sync $Sync -Phase "Step 1 of 3: Disk Check" -Status "Checking the system drive for filesystem problems..." -Percent 3 -ETA "A few minutes to schedule"
    Add-WorkLog -Sync $Sync -Text "Checking the system drive for filesystem problems."
    Add-WorkCommand -Sync $Sync -Command "chkdsk.exe $env:SystemDrive /f"
    try {
        # CHKDSK /F on the boot volume can't run live; it schedules itself for
        # the next restart. Answering Y just confirms that schedule - non-destructive.
        $chkLines = New-Object System.Collections.Generic.List[string]
        $chkExitCode = Invoke-LiveProcess -Sync $Sync -FilePath "chkdsk.exe" -ArgumentList @($env:SystemDrive, "/f") -StandardInputLine "Y" -OnLine {
            param($Sync, $line)
            Add-TerminalOutput -Sync $Sync -Text ([string]$line)
            $chkLines.Add([string]$line)
        }
        $chkText = $chkLines -join "`n"
        if ($chkText -match 'scheduled to run' -or $chkText -match 'next time the system restarts' -or $chkExitCode -eq 0) {
            $Sync.CheckDiskScheduled = $true
            Add-WorkLog -Sync $Sync -Text "Disk check has been scheduled to run automatically on the next restart. It typically takes 10-30 minutes depending on drive size." -Level "Success"
        }
    } catch {
        Add-WorkLog -Sync $Sync -Text "CHKDSK failed to run: $($_.Exception.Message)" -Level "Error"
    }
    if ($Sync.StopRequested) { $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled during CHKDSK."; return }

    # ---- Step 2: DISM ----
    Set-WorkProgress -Sync $Sync -Phase "Step 2 of 3: DISM" -Status "Repairing the Windows component image. This can take 10-20 minutes..." -Percent 30 -ETA "~15 minutes"
    Add-WorkLog -Sync $Sync -Text "Repairing the Windows system image so damaged files can be restored."
    Add-WorkCommand -Sync $Sync -Command "dism.exe /Online /Cleanup-Image /RestoreHealth"
    $dismOk = $true
    try {
        # Streamed live via Invoke-LiveProcess - see TaskEngine.ps1 for why
        # "$out = & dism.exe ... 2>&1" made this look stuck for 15-20 minutes.
        $dismStart = Get-Date
        $dismExitCode = Invoke-LiveProcess -Sync $Sync -FilePath "dism.exe" -ArgumentList @("/Online", "/Cleanup-Image", "/RestoreHealth") -OnLine {
            param($Sync, $line)
            Add-TerminalOutput -Sync $Sync -Text ([string]$line)
            if ("$line" -match '(\d{1,3})\.\d%') {
                $pct = [int]$Matches[1]
                $eta = Get-EtaString -StartTime $dismStart -PercentComplete $pct
                Set-WorkProgress -Sync $Sync -Phase "Step 2 of 3: DISM" -Status "Repairing the Windows component image... ($pct% complete)" -Percent ([int](30 + ($pct * 0.32))) -ETA $eta
            }
        }
        if ($null -eq $dismExitCode -or $dismExitCode -ne 0) { $dismOk = $false }
    } catch {
        Add-WorkLog -Sync $Sync -Text "DISM failed to run: $($_.Exception.Message)" -Level "Error"
        $dismOk = $false
    }
    if ($Sync.StopRequested) { $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled during DISM."; return }
    Add-WorkLog -Sync $Sync -Text "DISM finished." -Level $(if ($dismOk) { "Success" } else { "Warning" })

    # ---- Step 3: SFC ----
    Set-WorkProgress -Sync $Sync -Phase "Step 3 of 3: System File Checker" -Status "Checking Windows system files for corruption..." -Percent 65 -ETA "~10 minutes"
    Add-WorkLog -Sync $Sync -Text "Checking Windows system files and repairing any corruption found."
    Add-WorkCommand -Sync $Sync -Command "sfc.exe /scannow"
    $sfcOk = $true
    try {
        $sfcStart = Get-Date
        $sfcExitCode = Invoke-LiveProcess -Sync $Sync -FilePath "sfc.exe" -ArgumentList @("/scannow") -OnLine {
            param($Sync, $line)
            Add-TerminalOutput -Sync $Sync -Text ([string]$line)
            if ("$line" -match '(\d{1,3})%') {
                $pct = [int]$Matches[1]
                $eta = Get-EtaString -StartTime $sfcStart -PercentComplete $pct
                Set-WorkProgress -Sync $Sync -Phase "Step 3 of 3: System File Checker" -Status "Checking Windows system files... ($pct% complete)" -Percent ([int](65 + ($pct * 0.30))) -ETA $eta
            }
        }
        if ($null -eq $sfcExitCode) { $sfcOk = $false }
    } catch {
        Add-WorkLog -Sync $Sync -Text "SFC failed to run: $($_.Exception.Message)" -Level "Error"
        $sfcOk = $false
    }
    if ($Sync.StopRequested) { $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled during SFC."; return }
    Add-WorkLog -Sync $Sync -Text "SFC finished." -Level $(if ($sfcOk) { "Success" } else { "Warning" })

    Set-WorkProgress -Sync $Sync -Phase "Complete" -Status "Repair sequence finished." -Percent 100 -ETA "Done"
    $Sync.Done = $true
    $Sync.Success = $true
    $Sync.Summary = if ($Sync.CheckDiskScheduled) {
        "DISM and SFC completed. A disk check has been scheduled for your next restart."
    } else {
        "DISM and SFC completed. Disk check scheduling could not be confirmed - you can run 'chkdsk /f' manually if problems persist."
    }
}
