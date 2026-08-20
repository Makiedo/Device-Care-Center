<#
    TaskEngine.ps1
    --------------
    Runs feature workers in a background runspace so the UI thread never
    blocks, and gives workers a small, consistent API for reporting progress.

    A "worker" is a scriptblock built with New-WorkerScript. It receives a
    synchronized hashtable ($Sync) and cooperatively reports progress into it:

        Phase, Status, Percent (0-100), ETA (string)
        Log                   - {Text, Level, Kind, Time} for the "Detailed
                                 status output" list (Friendly/Technical split)
        TerminalOutputHistory - every command + every raw output line, in
                                 order, for the whole task (this is what
                                 Technical Mode's live terminal box shows,
                                 and what Export Log includes in full)
        Done, Success, Summary
        StopRequested         - worker should check this often and exit if true
        CurrentProcess        - the live System.Diagnostics.Process a module
                                 is currently running, if any - this is what
                                 makes Stop actually kill the right thing
        NeedsConfirm / ConfirmTitle / ConfirmMessage / ConfirmResult
                              - used by Request-WorkConfirm to pause for
                                user approval

    GUI.ps1's poll timer reads these keys on the UI thread ~5x/sec.

    TECHNICAL MODE - how every module (current and future) should log:
    Every log line has a Kind of either "Friendly" or "Technical":
      - Friendly (the default)  - plain-English narration of what's happening.
        Always visible, toggle on or off.
      - Technical               - the exact command being run, and its raw,
        unfiltered output. Only visible when Technical Mode is switched on.

    Use Add-WorkLog for Friendly narration (the default Kind), Add-WorkCommand
    right before running anything, and Invoke-LiveProcess (not "&" / 2>&1) to
    actually run an external tool, so its output streams live instead of
    appearing all at once after the tool finishes. As long as new feature
    modules follow this pattern, Technical Mode and Stop both "just work"
    for them with no changes needed anywhere else.
#>

function New-SyncHash {
    return [hashtable]::Synchronized(@{
        Phase                   = "Starting..."
        Status                  = "Initializing task"
        Percent                 = 0
        ETA                     = "Calculating..."
        Log                     = New-Object System.Collections.ArrayList
        TerminalOutputHistory   = New-Object System.Collections.ArrayList
        TerminalOutputLastIndex = 0
        Done                    = $false
        Success                 = $false
        Summary                 = ""
        StopRequested           = $false
        CurrentProcess          = $null
        NeedsConfirm            = $false
        ConfirmTitle            = ""
        ConfirmMessage          = ""
        ConfirmResult           = $null   # set by the UI thread after the user responds
        RebootRequired          = $false
    })
}

function Start-BackgroundTask {
    param(
        [string]$TaskName,
        [scriptblock]$Worker,
        [hashtable]$Sync
    )
    $rs = [runspacefactory]::CreateRunspace()
    # STA + ReuseThread: required for the Windows Update Agent COM API
    # (Feature_SystemUpdate.ps1's Microsoft.Update.Installer). WUA's
    # IUpdateInstaller specifically requires an STA thread - calling
    # BeginInstall()/Install() from the default MTA runspace throws
    # "Object reference not set to an instance of an object", which looks
    # like a null-reference bug in the script but is actually a COM
    # apartment-threading mismatch. ReuseThread additionally pins the whole
    # script to ONE dedicated OS thread for the runspace's lifetime, since
    # STA COM objects (the Session, Searcher, Downloader, Installer, and
    # their Job objects) are all affinitized to whichever thread created
    # them - without this, a worker could start on one thread and later
    # touch those objects from another, breaking COM marshaling the same
    # way. Harmless for every other module (DISM/SFC/winget/netsh are all
    # external processes via Invoke-LiveProcess, not COM, so apartment
    # state doesn't affect them).
    $rs.ApartmentState = [System.Threading.ApartmentState]::STA
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.Open()
    $rs.SessionStateProxy.SetVariable("Sync", $Sync)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Worker)
    $handle = $ps.BeginInvoke()
    return [PSCustomObject]@{ PowerShell = $ps; Handle = $handle; Runspace = $rs; TaskName = $TaskName }
}

# ------------------------------------------------------------------------
# Process-tree termination - defined once, used from BOTH the UI thread
# (for an immediate kill the instant Stop is clicked, or the app is closed
# mid-task) AND from inside a module's own background runspace (via the
# WorkerPreamble injection below). One implementation, reused everywhere,
# so "how do we safely kill a process tree" never gets duplicated or drifts.
# ------------------------------------------------------------------------
$ProcessTreeHelpers = {
    function Stop-ProcessTree {
        <# Kills a process and every descendant it spawned, so nothing from
           a cancelled task (DISM's helper processes, driver installers,
           etc.) is ever left running as an orphan. #>
        param([int]$ProcessId)
        if (-not $ProcessId) { return }
        try {
            $toKill = New-Object System.Collections.Generic.List[int]
            $queue  = New-Object System.Collections.Generic.Queue[int]
            $queue.Enqueue($ProcessId)
            while ($queue.Count -gt 0) {
                $currentId = $queue.Dequeue()
                $toKill.Add($currentId)
                Get-CimInstance Win32_Process -Filter "ParentProcessId=$currentId" -ErrorAction SilentlyContinue |
                    ForEach-Object { $queue.Enqueue($_.ProcessId) }
            }
            # Kill children before parents so nothing gets a chance to re-spawn.
            for ($i = $toKill.Count - 1; $i -ge 0; $i--) {
                try { Stop-Process -Id $toKill[$i] -Force -ErrorAction SilentlyContinue } catch {}
            }
        } catch {
            # Reliable one-shot fallback if the CIM query itself is unavailable.
            try { & taskkill.exe /PID $ProcessId /T /F 2>&1 | Out-Null } catch {}
        }
    }
}
. $ProcessTreeHelpers

function Stop-CurrentProcess {
    <# Called by the UI thread (Stop button, or the app closing mid-task) for
       an immediate kill, rather than waiting on a module's own poll cycle
       to notice StopRequested - this is what prevents an orphaned dism.exe/
       sfc.exe/chkdsk.exe if the app is closed while one is still running. #>
    param($Sync)
    if ($Sync -and $Sync.CurrentProcess) {
        try {
            if (-not $Sync.CurrentProcess.HasExited) {
                Stop-ProcessTree -ProcessId $Sync.CurrentProcess.Id
            }
        } catch {}
    }
}

function Stop-BackgroundTask {
    param($Job, $Sync)
    if ($Sync) {
        try { Stop-CurrentProcess -Sync $Sync } catch {}
    }
    if ($null -eq $Job) { return }
    try {
        if (-not $Job.Handle.IsCompleted) { $Job.PowerShell.Stop() | Out-Null }
    } catch {}
    try { $Job.PowerShell.Dispose() } catch {}
    try { $Job.Runspace.Close() } catch {}
}

# Injected as text at the top of every worker scriptblock, since each worker
# runs in its own isolated runspace and can't see functions defined out here.
$WorkerPreamble = {
    function Add-WorkLog {
        <# Friendly (default) or Technical narration line. Also mirrors into
           TerminalOutputHistory so Technical Mode's live terminal view and
           the exported log both show absolutely everything - including
           lines logged from inside a helper function of a feature module,
           not just the module's top-level code. #>
        param($Sync, [string]$Text, [string]$Level = "Info", [ValidateSet("Friendly", "Technical")][string]$Kind = "Friendly")
        [void]$Sync.Log.Add(@{ Text = $Text; Level = $Level; Kind = $Kind; Time = (Get-Date).ToString("HH:mm:ss") })

        $timeStamp = (Get-Date).ToString("HH:mm:ss")
        $levelPrefix = switch ($Level) {
            "Error" { "[ERROR]" }
            "Warning" { "[WARN]" }
            "Success" { "[OK]" }
            default { "[INFO]" }
        }
        [void]$Sync.TerminalOutputHistory.Add("[$timeStamp] $levelPrefix $Text")
    }
    function Add-WorkCommand {
        <# Logs the literal command about to run. #>
        param($Sync, [string]$Command)
        Add-WorkLog -Sync $Sync -Text "> $Command" -Level "Info" -Kind "Technical"
    }
    function Add-TerminalOutput {
        <# Adds a raw output line (e.g. one line of a running tool's stdout)
           to the live terminal history, with no [INFO]-style prefix added,
           since it's not our narration - it's the tool's own words. #>
        param($Sync, [string]$Text)
        if ("$Text".Trim().Length -gt 0) {
            [void]$Sync.TerminalOutputHistory.Add($Text)
        }
    }
    function Invoke-LiveProcess {
        <#
            Runs an external exe and streams its console output back to the
            caller line-by-line AS IT IS PRODUCED, via -OnLine (called once
            per line as & $OnLine $Sync $line).

            WHY THIS EXISTS: PowerShell's usual "$out = & cmd.exe 2>&1"
            pattern fully buffers ALL of a process's output internally and
            only assigns it to the variable once the process has completely
            exited - so a "foreach ($line in $out)" loop never runs until
            the tool is entirely done. For something like
            "dism.exe /online /cleanup-image /restorehealth", which can take
            15-20 minutes, that makes the task look completely stuck: no
            progress percentage moves, no terminal output appears, nothing -
            even though the tool is working fine in the background the
            whole time. Reading the process's output stream directly, as
            each line is written, is what actually fixes that.

            Also honors $Sync.StopRequested by killing the ENTIRE process
            tree (not just the immediate process) early, so the Stop button
            works even mid-run of a long external tool, and nothing it
            spawned is left running as an orphan.

            Returns the process's exit code, or $null if it couldn't start.
        #>
        param(
            $Sync,
            [Parameter(Mandatory)][string]$FilePath,
            [string[]]$ArgumentList = @(),
            [Parameter(Mandatory)][scriptblock]$OnLine,
            [string]$StandardInputLine = $null
        )

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        # NOTE: ProcessStartInfo.ArgumentList can come back $null on some
        # Windows PowerShell 5.1 / older .NET Framework combinations
        # (throwing "cannot call a method on a null-valued expression" the
        # instant you .Add() to it) - so build a plain Arguments string
        # instead, which is supported everywhere.
        $psi.Arguments = (($ArgumentList | ForEach-Object {
            if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        }) -join ' ')
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.RedirectStandardInput  = [bool]$StandardInputLine
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true

        # OutputDataReceived/ErrorDataReceived fire on background thread-pool
        # threads, not this one - so lines land in this thread-safe queue and
        # get drained on this thread below, keeping $OnLine (which touches
        # $Sync) running on a single, predictable thread.
        $lineQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi

        $stdOutSub = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action {
            if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
        } -MessageData $lineQueue
        $stdErrSub = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action {
            if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
        } -MessageData $lineQueue

        try {
            try {
                [void]$proc.Start()
            } catch {
                & $OnLine $Sync "Failed to start $FilePath`: $($_.Exception.Message)"
                return $null
            }

            $Sync.CurrentProcess = $proc
            $proc.BeginOutputReadLine()
            $proc.BeginErrorReadLine()

            if ($StandardInputLine) {
                try { $proc.StandardInput.WriteLine($StandardInputLine); $proc.StandardInput.Close() } catch {}
            }

            while (-not $proc.HasExited) {
                $line = $null
                while ($lineQueue.TryDequeue([ref]$line)) { & $OnLine $Sync $line }

                if ($Sync.StopRequested) {
                    & $OnLine $Sync "--- Stopping $FilePath (and any child processes it started) ---"
                    try { if (-not $proc.HasExited) { Stop-ProcessTree -ProcessId $proc.Id } } catch {}
                    break
                }
                Start-Sleep -Milliseconds 100
            }

            # Let any already-in-flight events land, then drain the rest.
            Start-Sleep -Milliseconds 150
            $line = $null
            while ($lineQueue.TryDequeue([ref]$line)) { & $OnLine $Sync $line }

            try { $proc.WaitForExit(3000) } catch {}
            return $(try { $proc.ExitCode } catch { $null })
        } finally {
            $Sync.CurrentProcess = $null
            Unregister-Event -SourceIdentifier $stdOutSub.Name -ErrorAction SilentlyContinue
            Unregister-Event -SourceIdentifier $stdErrSub.Name -ErrorAction SilentlyContinue
            Remove-Job -Name $stdOutSub.Name -Force -ErrorAction SilentlyContinue
            Remove-Job -Name $stdErrSub.Name -Force -ErrorAction SilentlyContinue
            $proc.Dispose()
        }
    }
    function Get-EtaString {
        <#
            Estimates remaining time from elapsed time and percent complete,
            via simple linear extrapolation (rate-so-far -> projected finish).
            This is what turns "Working... (45% complete)" into an actual
            countdown like "About 2m 15s remaining", so long-running tools
            (DISM, SFC, winget) give a genuine sense of progress instead of
            just restating the percentage back at you.
        #>
        param([datetime]$StartTime, [double]$PercentComplete)
        if ($PercentComplete -le 0) { return "Calculating remaining time..." }
        if ($PercentComplete -ge 100) { return "Almost done..." }
        $elapsedSeconds = ((Get-Date) - $StartTime).TotalSeconds
        if ($elapsedSeconds -le 1) { return "Calculating remaining time..." }
        $estimatedTotalSeconds = $elapsedSeconds / ($PercentComplete / 100.0)
        $remainingSeconds = [Math]::Max(0, $estimatedTotalSeconds - $elapsedSeconds)
        if ($remainingSeconds -lt 60) {
            return "About $([Math]::Ceiling($remainingSeconds))s remaining"
        } elseif ($remainingSeconds -lt 3600) {
            $mins = [Math]::Floor($remainingSeconds / 60)
            $secs = [Math]::Ceiling($remainingSeconds % 60)
            return "About ${mins}m ${secs}s remaining"
        } else {
            $hours = [Math]::Floor($remainingSeconds / 3600)
            $mins = [Math]::Floor(($remainingSeconds % 3600) / 60)
            return "About ${hours}h ${mins}m remaining"
        }
    }
    function Set-WorkProgress {
        param($Sync, [string]$Phase, [string]$Status, [int]$Percent, [string]$ETA = "")
        $Sync.Phase = $Phase
        $Sync.Status = $Status
        $Sync.Percent = [Math]::Max(0, [Math]::Min(100, $Percent))
        if ($ETA) { $Sync.ETA = $ETA }
    }
    function Request-WorkConfirm {
        param($Sync, [string]$Title, [string]$Message)
        $Sync.ConfirmResult = $null
        $Sync.ConfirmTitle = $Title
        $Sync.ConfirmMessage = $Message
        $Sync.NeedsConfirm = $true
        while ($Sync.ConfirmResult -eq $null -and -not $Sync.StopRequested) {
            Start-Sleep -Milliseconds 150
        }
        $Sync.NeedsConfirm = $false
        return [bool]$Sync.ConfirmResult
    }
    function Test-Connectivity {
        try {
            return [bool](Test-Connection -ComputerName "www.msftconnecttest.com" -Count 2 -Quiet -ErrorAction Stop)
        } catch {
            try { return [bool](Test-Connection -ComputerName "8.8.8.8" -Count 2 -Quiet -ErrorAction Stop) }
            catch { return $false }
        }
    }
    function Wait-CancellableJob {
        <#
            Generic poller for any async operation that exposes an
            IsCompleted flag and an abort action - used for things that
            aren't external processes (e.g. Windows Update's COM download/
            install jobs) but still need to be safely cancellable the
            moment Stop is clicked, without every module reinventing this
            polling loop itself. Returns $true if it was cancelled.
        #>
        param($Sync, $Job, [scriptblock]$AbortAction, [int]$PollMilliseconds = 200)
        while (-not $Job.IsCompleted) {
            if ($Sync.StopRequested) {
                try { & $AbortAction } catch {}
                return $true
            }
            Start-Sleep -Milliseconds $PollMilliseconds
        }
        return $false
    }
}

function New-WorkerScript {
    param([scriptblock]$Body)
    return [scriptblock]::Create($ProcessTreeHelpers.ToString() + "`n" + $WorkerPreamble.ToString() + "`n" + $Body.ToString())
}
