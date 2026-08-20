<#
    Logging.ps1
    -----------
    Centralized, in-memory log used across every feature, plus export-to-file.
    $Global:LogListBox is set by GUI.ps1 once the log panel control exists;
    Add-CenterLog writes to it live whenever it's available.
#>

$Global:LogEntries = New-Object System.Collections.ArrayList

# Every command + raw output line from every task run this session, in order.
# Populated by Save-SessionTerminalHistory when each task finishes, so the
# exported log always has the full technical record - not just whichever
# task happens to be $Global:CurrentSync at the moment Export Log is clicked.
$Global:AllTerminalOutputHistory = New-Object System.Collections.ArrayList

function Save-SessionTerminalHistory {
    <# Call once, right when a task finishes (Sync.Done), before $Global:CurrentSync
       is cleared. Copies that task's complete technical output (every command and
       every line of raw output, from every function it called) into the
       session-wide store used by Export-CenterLog. #>
    param([string]$TaskName, [hashtable]$Sync)
    if (-not $Sync -or -not $Sync.TerminalOutputHistory -or $Sync.TerminalOutputHistory.Count -eq 0) { return }
    [void]$Global:AllTerminalOutputHistory.Add("")
    [void]$Global:AllTerminalOutputHistory.Add("===== $TaskName - finished $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') =====")
    foreach ($line in $Sync.TerminalOutputHistory) {
        [void]$Global:AllTerminalOutputHistory.Add($line)
    }
}

function Add-CenterLog {
    param(
        [string]$Task,
        [string]$Action,
        [string]$Result,
        [ValidateSet("Info", "Success", "Warning", "Error")][string]$Level = "Info"
    )
    $entry = [PSCustomObject]@{
        Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Task      = $Task
        Action    = $Action
        Result    = $Result
        Level     = $Level
    }
    [void]$Global:LogEntries.Add($entry)

    if ($Global:LogListBox -and -not $Global:LogListBox.IsDisposed) {
        $line = "[{0}] {1} | {2} -> {3}" -f $entry.Timestamp, $entry.Task, $entry.Action, $entry.Result
        $Global:LogListBox.Items.Add($line)
        $Global:LogListBox.TopIndex = $Global:LogListBox.Items.Count - 1
    }
    return $entry
}

function Export-CenterLog {
    param([string]$Path)

    # Technical output = every completed task this session (from the
    # session-wide store), plus whatever the in-progress task (if any) has
    # produced so far. This is what makes Export Log complete even after
    # you've run several features back to back, or export mid-run.
    $technicalLines = New-Object System.Collections.ArrayList
    foreach ($line in $Global:AllTerminalOutputHistory) { [void]$technicalLines.Add($line) }
    if ($Global:CurrentSync -and $Global:CurrentSync.TerminalOutputHistory -and $Global:CurrentSync.TerminalOutputHistory.Count -gt 0) {
        [void]$technicalLines.Add("")
        [void]$technicalLines.Add("===== $Global:CurrentTaskName - in progress (as of $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) =====")
        foreach ($line in $Global:CurrentSync.TerminalOutputHistory) { [void]$technicalLines.Add($line) }
    }

    # Combine friendly logs with all technical terminal output
    $lines = New-Object System.Collections.ArrayList

    # Add header
    [void]$lines.Add("================================================================================")
    [void]$lines.Add("DEVICE CARE CENTER - COMPLETE LOG EXPORT")
    [void]$lines.Add("Exported: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$lines.Add("================================================================================")
    [void]$lines.Add("")

    # Add friendly logs first
    if ($Global:LogEntries -and $Global:LogEntries.Count -gt 0) {
        [void]$lines.Add("FRIENDLY LOG ENTRIES:")
        [void]$lines.Add("-" * 80)
        foreach ($entry in $Global:LogEntries) {
            [void]$lines.Add("[$($entry.Timestamp)] [$($entry.Level)] $($entry.Task) | $($entry.Action) -> $($entry.Result)")
        }
        [void]$lines.Add("")
    }

    # Add all technical terminal output (every command and raw output, from
    # every function of every feature module, across every task run this
    # session - not just whichever task is currently on screen)
    if ($technicalLines.Count -gt 0) {
        [void]$lines.Add("TECHNICAL TERMINAL OUTPUT (All commands and responses, every task this session):")
        [void]$lines.Add("-" * 80)
        foreach ($line in $technicalLines) {
            [void]$lines.Add($line)
        }
        [void]$lines.Add("")
    }

    [void]$lines.Add("================================================================================")
    [void]$lines.Add("END OF LOG")
    [void]$lines.Add("================================================================================")

    $lines -join "`r`n" | Out-File -FilePath $Path -Encoding UTF8
}
