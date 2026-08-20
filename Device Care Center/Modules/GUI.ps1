<#
    GUI.ps1
    -------
    Everything visual lives here: the main window, the dashboard cards, the
    task-progress screen, and the preflight dialogs for each feature.

    This file only DEFINES Show-MainForm - it doesn't run anything by itself.
    The launcher (DeviceCareCenter.ps1) dot-sources this along with the other
    modules and then calls Show-MainForm to actually build and run the window.

    Depends on (all dot-sourced by the launcher before this file):
      Theme.ps1        - $Theme, New-Font
      Controls.ps1      - Set-RoundedRegion, New-ToggleSwitch
      Logging.ps1        - Add-CenterLog, Export-CenterLog, $Global:LogListBox
      TaskEngine.ps1     - New-SyncHash, Start-BackgroundTask, Stop-BackgroundTask
      Feature.*.ps1      - $Worker_UpdateApps, Get-Worker_SystemUpdate,
                            $Worker_Repair, $Worker_Network
#>

function Show-MainForm {

    $Global:TechnicalModeEnabled = $false
    $Global:CurrentJob = $null
    $Global:CurrentSync = $null
    $Global:CurrentTaskName = ""
    $Global:TaskQueue = $null
    $Global:AllowClose = $false
    $Global:ClosingAfterStop = $false
    $Global:PollTimer = New-Object System.Windows.Forms.Timer
    $Global:PollTimer.Interval = 200

    # --------------------------------------------------------------
    # Main window
    # --------------------------------------------------------------
    $Form = New-Object System.Windows.Forms.Form
    $Form.Text = "Device Care Center"
    $Form.Size = New-Object System.Drawing.Size(980, 760)
    $Form.StartPosition = "CenterScreen"
    $Form.BackColor = $Theme.Background
    $Form.ForeColor = $Theme.TextPrimary
    $Form.Font = New-Font 10
    $Form.FormBorderStyle = "FixedSingle"
    $Form.MaximizeBox = $false

    # Window icon (title bar, top-left, and taskbar) - set from the app's .ico
    # file if it's present next to the script/exe. Wrapped in try/catch so a
    # missing or locked icon file never prevents the app from starting.
    try {
        if ($Global:AppIconPath -and (Test-Path $Global:AppIconPath)) {
            $Form.Icon = New-Object System.Drawing.Icon($Global:AppIconPath)
        }
    } catch {
        # Non-fatal: app still runs fine with the default .NET icon.
    }

    # --------------------------------------------------------------
    # System tray icon (used by the "minimize to tray" close option)
    # --------------------------------------------------------------
    $Global:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
    $Global:TrayIcon.Icon = if ($Form.Icon) { $Form.Icon } else { [System.Drawing.SystemIcons]::Application }
    $Global:TrayIcon.Text = "Device Care Center"
    $Global:TrayIcon.Visible = $false

    function Restore-FromTray {
        $Form.Show()
        $Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $Form.ShowInTaskbar = $true
        $Global:TrayIcon.Visible = $false
        $Form.Activate()
    }

    $TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    [void]$TrayMenu.Items.Add("Open Device Care Center").Add_Click({ Restore-FromTray })
    [void]$TrayMenu.Items.Add("Exit").Add_Click({ $Form.Close() })
    $Global:TrayIcon.ContextMenuStrip = $TrayMenu
    $Global:TrayIcon.Add_DoubleClick({ Restore-FromTray })

    # --------------------------------------------------------------
    # Header
    # --------------------------------------------------------------
    $HeaderPanel = New-Object System.Windows.Forms.Panel
    $HeaderPanel.Size = New-Object System.Drawing.Size(980, 74)
    $HeaderPanel.Location = New-Object System.Drawing.Point(0, 0)
    $HeaderPanel.BackColor = $Theme.Surface
    $Form.Controls.Add($HeaderPanel)

    $TitleLabel = New-Object System.Windows.Forms.Label
    $TitleLabel.Text = "Device Care Center"
    $TitleLabel.Font = New-Font 16 ([System.Drawing.FontStyle]::Bold)
    $TitleLabel.ForeColor = $Theme.TextPrimary
    $TitleLabel.AutoSize = $true
    $TitleLabel.Location = New-Object System.Drawing.Point(24, 10)
    $HeaderPanel.Controls.Add($TitleLabel)

    $SubtitleLabel = New-Object System.Windows.Forms.Label
    $SubtitleLabel.Text = "Guided maintenance for your PC - safe, transparent, and easy to follow"
    $SubtitleLabel.Font = New-Font 9
    $SubtitleLabel.ForeColor = $Theme.TextSecondary
    $SubtitleLabel.AutoSize = $true
    $SubtitleLabel.Location = New-Object System.Drawing.Point(26, 42)
    $HeaderPanel.Controls.Add($SubtitleLabel)

    # Right-hand controls: Technical Mode toggle, then Export Log - spaced
    # out with enough room that nothing overlaps at this window width.
    $TechModeLabel = New-Object System.Windows.Forms.Label
    $TechModeLabel.Text = "Technical Mode"
    $TechModeLabel.Font = New-Font 9.5
    $TechModeLabel.ForeColor = $Theme.TextPrimary
    $TechModeLabel.AutoSize = $true
    $TechModeLabel.Location = New-Object System.Drawing.Point(636, 27)
    $HeaderPanel.Controls.Add($TechModeLabel)

    $null = New-ToggleSwitch -Parent $HeaderPanel -X 760 -Y 26 -Checked $false -OnChange {
        param($isOn)
        $Global:TechnicalModeEnabled = $isOn
        if ($isOn) {
            $Global:LogListBox.Visible = $false
            $TerminalOutputLabel.Visible = $true
            $Global:TerminalOutputBox.Visible = $true
            
            # Backfill TerminalOutputBox with all historical output from the current task
            $currentSync = $Global:CurrentSync
            if ($currentSync -and $currentSync.TerminalOutputHistory -and $currentSync.TerminalOutputHistory.Count -gt 0) {
                $Global:TerminalOutputBox.Clear()
                foreach ($line in $currentSync.TerminalOutputHistory) {
                    $Global:TerminalOutputBox.AppendText("$line`r`n")
                }
                # CRITICAL: Update TerminalOutputLastIndex so poll loop doesn't duplicate
                $currentSync.TerminalOutputLastIndex = $currentSync.TerminalOutputHistory.Count
                $Global:TerminalOutputBox.SelectionStart = $Global:TerminalOutputBox.TextLength
                $Global:TerminalOutputBox.ScrollToCaret()
            }
        } else {
            $Global:LogListBox.Visible = $true
            $TerminalOutputLabel.Visible = $false
            $Global:TerminalOutputBox.Visible = $false
        }
    }

    $ViewLogButton = New-Object System.Windows.Forms.Button
    $ViewLogButton.Text = "Export Log"
    $ViewLogButton.Size = New-Object System.Drawing.Size(130, 32)
    $ViewLogButton.Location = New-Object System.Drawing.Point(826, 21)
    $ViewLogButton.FlatStyle = "Flat"
    $ViewLogButton.FlatAppearance.BorderColor = $Theme.Border
    $ViewLogButton.BackColor = $Theme.SurfaceAlt
    $ViewLogButton.ForeColor = $Theme.TextPrimary
    $ViewLogButton.Font = New-Font 9
    $ViewLogButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.InitialDirectory = [Environment]::GetFolderPath("Desktop")
        $dialog.FileName = "DeviceCareCenter-Log-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
        $dialog.Filter = "Text File|*.txt"
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Export-CenterLog -Path $dialog.FileName
            [System.Windows.Forms.MessageBox]::Show("Log saved to:`n$($dialog.FileName)", "Log Exported", "OK", "Information") | Out-Null
        }
    })
    $HeaderPanel.Controls.Add($ViewLogButton)

    # --------------------------------------------------------------
    # Dashboard panel (four feature cards)
    # --------------------------------------------------------------
    $DashboardPanel = New-Object System.Windows.Forms.Panel
    $DashboardPanel.Location = New-Object System.Drawing.Point(0, 74)
    $DashboardPanel.Size = New-Object System.Drawing.Size(980, 686)
    $DashboardPanel.BackColor = $Theme.Background
    $Form.Controls.Add($DashboardPanel)

    function New-DashboardCard {
        param([string]$Title, [string]$Desc, [int]$X, [int]$Y, [scriptblock]$OnClick, [int]$Width = 440, [int]$Height = 180, [string]$ButtonText = "Start", [int]$ButtonWidth = 110)

        $card = New-Object System.Windows.Forms.Panel
        $card.Size = New-Object System.Drawing.Size($Width, $Height)
        $card.Location = New-Object System.Drawing.Point($X, $Y)
        $card.BackColor = $Theme.Surface
        $card.Cursor = [System.Windows.Forms.Cursors]::Hand

        $titleLbl = New-Object System.Windows.Forms.Label
        $titleLbl.Text = $Title
        $titleLbl.Font = New-Font 13 ([System.Drawing.FontStyle]::Bold)
        $titleLbl.ForeColor = $Theme.TextPrimary
        $titleLbl.AutoSize = $true
        $titleLbl.Location = New-Object System.Drawing.Point(20, 20)
        $card.Controls.Add($titleLbl)

        $descLbl = New-Object System.Windows.Forms.Label
        $descLbl.Text = $Desc
        $descLbl.Font = New-Font 9.5
        $descLbl.ForeColor = $Theme.TextSecondary
        $descLbl.Size = New-Object System.Drawing.Size(($Width - 40), ($Height - 110))
        $descLbl.Location = New-Object System.Drawing.Point(20, 55)
        $card.Controls.Add($descLbl)

        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $ButtonText
        $btn.Size = New-Object System.Drawing.Size($ButtonWidth, 34)
        $btn.Location = New-Object System.Drawing.Point(20, ($Height - 50))
        $btn.FlatStyle = "Flat"
        $btn.FlatAppearance.BorderSize = 0
        $btn.BackColor = $Theme.Accent
        $btn.ForeColor = [System.Drawing.Color]::White
        $btn.Font = New-Font 9.5 ([System.Drawing.FontStyle]::Bold)
        $btn.Add_Click($OnClick)
        $card.Controls.Add($btn)

        Set-RoundedRegion -Control $card -Radius 12
        $DashboardPanel.Controls.Add($card)
        return $card
    }

    $FooterLabel = New-Object System.Windows.Forms.Label
    $FooterLabel.Text = "All actions run with Administrator privileges. Nothing destructive happens without your approval."
    $FooterLabel.Font = New-Font 8.5
    $FooterLabel.ForeColor = $Theme.TextSecondary
    $FooterLabel.AutoSize = $true
    $FooterLabel.Location = New-Object System.Drawing.Point(24, 600)
    $DashboardPanel.Controls.Add($FooterLabel)

    # --------------------------------------------------------------
    # Task panel (shown while a feature is running)
    # --------------------------------------------------------------
    $TaskPanel = New-Object System.Windows.Forms.Panel
    $TaskPanel.Location = New-Object System.Drawing.Point(0, 74)
    $TaskPanel.Size = New-Object System.Drawing.Size(980, 686)
    $TaskPanel.BackColor = $Theme.Background
    $TaskPanel.Visible = $false
    $Form.Controls.Add($TaskPanel)

    $TaskNameLabel = New-Object System.Windows.Forms.Label
    $TaskNameLabel.Font = New-Font 15 ([System.Drawing.FontStyle]::Bold)
    $TaskNameLabel.ForeColor = $Theme.TextPrimary
    $TaskNameLabel.AutoSize = $true
    $TaskNameLabel.Location = New-Object System.Drawing.Point(24, 20)
    $TaskPanel.Controls.Add($TaskNameLabel)

    $PhaseLabel = New-Object System.Windows.Forms.Label
    $PhaseLabel.Font = New-Font 10.5
    $PhaseLabel.ForeColor = $Theme.Accent
    $PhaseLabel.AutoSize = $true
    $PhaseLabel.Location = New-Object System.Drawing.Point(26, 54)
    $TaskPanel.Controls.Add($PhaseLabel)

    $StatusLabel = New-Object System.Windows.Forms.Label
    $StatusLabel.Font = New-Font 9.5
    $StatusLabel.ForeColor = $Theme.TextSecondary
    $StatusLabel.Size = New-Object System.Drawing.Size(700, 40)
    $StatusLabel.Location = New-Object System.Drawing.Point(26, 78)
    $TaskPanel.Controls.Add($StatusLabel)

    $ProgressBar = New-Object System.Windows.Forms.ProgressBar
    $ProgressBar.Location = New-Object System.Drawing.Point(26, 125)
    $ProgressBar.Size = New-Object System.Drawing.Size(700, 24)
    $ProgressBar.Style = "Continuous"
    $TaskPanel.Controls.Add($ProgressBar)

    $PercentLabel = New-Object System.Windows.Forms.Label
    $PercentLabel.Font = New-Font 9.5 ([System.Drawing.FontStyle]::Bold)
    $PercentLabel.ForeColor = $Theme.TextPrimary
    $PercentLabel.AutoSize = $true
    $PercentLabel.Location = New-Object System.Drawing.Point(736, 128)
    $TaskPanel.Controls.Add($PercentLabel)

    $ETALabel = New-Object System.Windows.Forms.Label
    $ETALabel.Font = New-Font 9
    $ETALabel.ForeColor = $Theme.TextSecondary
    $ETALabel.AutoSize = $true
    $ETALabel.Location = New-Object System.Drawing.Point(26, 154)
    $TaskPanel.Controls.Add($ETALabel)

    $OutputLabel = New-Object System.Windows.Forms.Label
    $OutputLabel.Text = "Detailed status output"
    $OutputLabel.Font = New-Font 9.5 ([System.Drawing.FontStyle]::Bold)
    $OutputLabel.ForeColor = $Theme.TextPrimary
    $OutputLabel.AutoSize = $true
    $OutputLabel.Location = New-Object System.Drawing.Point(26, 185)
    $TaskPanel.Controls.Add($OutputLabel)

     $Global:LogListBox = New-Object System.Windows.Forms.ListBox
    $Global:LogListBox.Location = New-Object System.Drawing.Point(26, 210)
    $Global:LogListBox.Size = New-Object System.Drawing.Size(700, 336)
    $Global:LogListBox.BackColor = $Theme.Surface
    $Global:LogListBox.ForeColor = $Theme.TextPrimary
    $Global:LogListBox.BorderStyle = "None"
    $Global:LogListBox.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $TaskPanel.Controls.Add($Global:LogListBox)

    $TerminalOutputLabel = New-Object System.Windows.Forms.Label
    $TerminalOutputLabel.Text = "Live terminal output"
    $TerminalOutputLabel.Font = New-Font 9.5 ([System.Drawing.FontStyle]::Bold)
    $TerminalOutputLabel.ForeColor = $Theme.TextPrimary
    $TerminalOutputLabel.AutoSize = $true
    $TerminalOutputLabel.Location = New-Object System.Drawing.Point(26, 185)
    $TerminalOutputLabel.Visible = $false
    $TaskPanel.Controls.Add($TerminalOutputLabel)

    $Global:TerminalOutputBox = New-Object System.Windows.Forms.RichTextBox
    $Global:TerminalOutputBox.Location = New-Object System.Drawing.Point(26, 210)
    $Global:TerminalOutputBox.Size = New-Object System.Drawing.Size(700, 336)
    $Global:TerminalOutputBox.BackColor = [System.Drawing.Color]::Black
    $Global:TerminalOutputBox.ForeColor = [System.Drawing.Color]::LimeGreen
    $Global:TerminalOutputBox.BorderStyle = "None"
    $Global:TerminalOutputBox.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $Global:TerminalOutputBox.ReadOnly = $true
    $Global:TerminalOutputBox.Visible = $false
    $TaskPanel.Controls.Add($Global:TerminalOutputBox)

    $StopButton = New-Object System.Windows.Forms.Button
    $StopButton.Text = "STOP"
    $StopButton.Size = New-Object System.Drawing.Size(180, 60)
    $StopButton.Location = New-Object System.Drawing.Point(750, 210)
    $StopButton.FlatStyle = "Flat"
    $StopButton.FlatAppearance.BorderSize = 0
    $StopButton.BackColor = $Theme.Error
    $StopButton.ForeColor = [System.Drawing.Color]::White
    $StopButton.Font = New-Font 13 ([System.Drawing.FontStyle]::Bold)
    $TaskPanel.Controls.Add($StopButton)
    Set-RoundedRegion -Control $StopButton -Radius 10

    $SidePanelLabel = New-Object System.Windows.Forms.Label
    $SidePanelLabel.Text = "This task is running in the background. You can stop it safely at any time."
    $SidePanelLabel.Font = New-Font 8.5
    $SidePanelLabel.ForeColor = $Theme.TextSecondary
    $SidePanelLabel.Size = New-Object System.Drawing.Size(180, 60)
    $SidePanelLabel.Location = New-Object System.Drawing.Point(750, 280)
    $TaskPanel.Controls.Add($SidePanelLabel)

    # --------------------------------------------------------------
    # Task orchestration
    # --------------------------------------------------------------
    function Show-TaskScreen {
        param([string]$Name)
        $Global:LogListBox.Items.Clear()
        $Global:TerminalOutputBox.Clear()
        $TaskNameLabel.Text = $Name
        $PhaseLabel.Text = ""
        $StatusLabel.Text = ""
        $ProgressBar.Value = 0
        $PercentLabel.Text = "0%"
        $ETALabel.Text = ""
        $DashboardPanel.Visible = $false
        $TaskPanel.Visible = $true
    }

    function Show-Dashboard {
        $TaskPanel.Visible = $false
        $DashboardPanel.Visible = $true
    }

    function Start-Task {
        param([string]$Name, [scriptblock]$Worker, [switch]$Chained, [bool]$AutoReboot = $false)
        if (-not $Chained) {
            # Starting a task directly from a dashboard card - any leftover
            # chain from a previous "Full Maintenance" run should not resume.
            $Global:TaskQueue = $null
        }
        Show-TaskScreen -Name $Name
        Add-CenterLog -Task $Name -Action "Task started" -Result "In progress" -Level "Info"

        $sync = New-SyncHash
        # Set directly on the hashtable (not via a captured function parameter
        # inside the worker scriptblock) - workers are reconstructed from
        # plain source text to run in an isolated runspace (see
        # New-WorkerScript), so a parameter closure like $AutoReboot would
        # silently resolve to $null there. $sync itself is explicitly
        # injected into that runspace, so setting a property on it here,
        # before the worker starts, is what actually survives the boundary.
        $sync.AutoReboot = $AutoReboot
        $Global:CurrentSync = $sync
        $Global:CurrentTaskName = $Name
        $Global:CurrentJob = Start-BackgroundTask -TaskName $Name -Worker $Worker -Sync $sync
        $Global:PollTimer.Start()
    }

    function Start-TaskChain {
        <#
            Queues up a sequence of tasks - {Name; Worker} hashtables - to run
            one after another, each one starting automatically as soon as the
            previous one reports Done. Used by the "Full Maintenance" card.
        #>
        param([object[]]$Tasks)
        $Global:TaskQueue = New-Object System.Collections.Generic.Queue[object]
        foreach ($t in $Tasks) { $Global:TaskQueue.Enqueue($t) }
        Start-NextQueuedTask
    }

    function Start-NextQueuedTask {
        if ($Global:TaskQueue -and $Global:TaskQueue.Count -gt 0) {
            $next = $Global:TaskQueue.Dequeue()
            $autoReboot = if ($next.ContainsKey('AutoReboot')) { $next.AutoReboot } else { $false }
            Start-Task -Name $next.Name -Worker $next.Worker -Chained -AutoReboot $autoReboot
        } else {
            $Global:TaskQueue = $null
            Show-Dashboard
        }
    }

    $StopButton.Add_Click({
        if ($Global:CurrentSync) {
            # Pause polling while this confirmation is up, same as the
            # NeedsConfirm dialog does - avoids the Done handler and this
            # dialog both firing modal popups at the same moment.
            $Global:PollTimer.Stop()
            $confirm = [System.Windows.Forms.MessageBox]::Show(
                "Stop the current task? Any changes already made will remain, but no further steps will run.",
                "Confirm Stop", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
                $Global:CurrentSync.StopRequested = $true
                $Global:CurrentSync.StopRequestedAt = Get-Date
                $Global:CurrentSync.ConfirmResult = $false
            }
            $Global:PollTimer.Start()
        }
    })

    $Global:PollTimer.Add_Tick({
        if (-not $Global:CurrentSync) { return }
        $sync = $Global:CurrentSync

        # Drain new log lines. Friendly lines always show; Technical lines
        # (exact commands + raw output) only show when Technical Mode is on.
        # This applies uniformly to every feature module, present or future,
        # since it's driven purely by the Kind each module tags its own
        # log lines with - see TaskEngine.ps1.
        while ($sync.Log.Count -gt 0) {
            $item = $sync.Log[0]
            $sync.Log.RemoveAt(0)
            $showThis = ($item.Kind -ne "Technical") -or $Global:TechnicalModeEnabled
            if ($showThis) {
                $line = "[$($item.Time)] $($item.Text)"
                $Global:LogListBox.Items.Add($line)
                $Global:LogListBox.TopIndex = $Global:LogListBox.Items.Count - 1
            }
        }

        # Drain terminal output (live command output) for Technical Mode display
        # Only display new items since last poll (using TerminalOutputLastIndex)
        if ($Global:TechnicalModeEnabled -and $sync.TerminalOutputHistory.Count -gt $sync.TerminalOutputLastIndex) {
            for ($i = $sync.TerminalOutputLastIndex; $i -lt $sync.TerminalOutputHistory.Count; $i++) {
                $line = $sync.TerminalOutputHistory[$i]
                $Global:TerminalOutputBox.AppendText("$line`r`n")
            }
            $sync.TerminalOutputLastIndex = $sync.TerminalOutputHistory.Count
            
            # Keep caret at end to show latest output
            $Global:TerminalOutputBox.SelectionStart = $Global:TerminalOutputBox.TextLength
            $Global:TerminalOutputBox.ScrollToCaret()
        }

        if ($sync.StopRequested -and -not $sync.Done) {
            # Uniform "safely stopping" state for every feature - this is
            # deliberately handled here in one place, rather than requiring
            # every worker script to remember to set it, so it applies
            # consistently no matter which step/level a feature is on when
            # Stop is clicked. The live elapsed counter is what makes clear
            # this is actively wrapping up and not just hanging.
            $stoppedAt = if ($sync.StopRequestedAt) { $sync.StopRequestedAt } else { Get-Date }
            $elapsed = [int](((Get-Date) - $stoppedAt).TotalSeconds)
            $PhaseLabel.Text  = $sync.Phase
            $StatusLabel.Text = "Safely stopping task... finishing the current step cleanly, then it will stop."
            $ProgressBar.Value = [Math]::Max(0, [Math]::Min(100, [int]$sync.Percent))
            $PercentLabel.Text = "$([int]$sync.Percent)%"
            $ETALabel.Text = "Estimated time remaining: stopping now - $elapsed`s elapsed"
        } else {
            $PhaseLabel.Text  = $sync.Phase
            $StatusLabel.Text = $sync.Status
            $ProgressBar.Value = [Math]::Max(0, [Math]::Min(100, [int]$sync.Percent))
            $PercentLabel.Text = "$([int]$sync.Percent)%"
            $ETALabel.Text = "Estimated time remaining: $($sync.ETA)"
        }

        if ($sync.NeedsConfirm) {
            $Global:PollTimer.Stop()
            $result = [System.Windows.Forms.MessageBox]::Show(
                $sync.ConfirmMessage + "`n`nDo you want to continue?",
                $sync.ConfirmTitle,
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            $sync.ConfirmResult = ($result -eq [System.Windows.Forms.DialogResult]::Yes)
            Add-CenterLog -Task $Global:CurrentTaskName -Action $sync.ConfirmTitle -Result $(if ($sync.ConfirmResult) { "Approved by user" } else { "Declined by user" }) -Level $(if ($sync.ConfirmResult) { "Info" } else { "Warning" })
            $Global:PollTimer.Start()
            return
        }

        if ($sync.Done) {
            $Global:PollTimer.Stop()
            $level = if ($sync.Success) { "Success" } else { "Warning" }
            Add-CenterLog -Task $Global:CurrentTaskName -Action "Task finished" -Result $sync.Summary -Level $level

            # Mid-chain steps (Full Maintenance) don't stop for a click - only
            # the last step in the queue shows the "Finished" notification, so
            # the whole run can be left unattended once it's started. Also
            # skipped entirely when closing after a "safely stop, then close"
            # request - the app is on its way out, nothing to show.
            $isMidChain = ($Global:TaskQueue -and $Global:TaskQueue.Count -gt 0)
            if (-not $isMidChain -and -not $Global:ClosingAfterStop) {
                if ($Form.Visible) {
                    $icon = if ($sync.Success) { [System.Windows.Forms.MessageBoxIcon]::Information } else { [System.Windows.Forms.MessageBoxIcon]::Warning }
                    [System.Windows.Forms.MessageBox]::Show($sync.Summary, "$($Global:CurrentTaskName) - Finished", [System.Windows.Forms.MessageBoxButtons]::OK, $icon) | Out-Null
                } else {
                    # Minimized to tray - a modal popup from a hidden window
                    # would be jarring, so surface it as a balloon tip instead.
                    $Global:TrayIcon.BalloonTipTitle = "$($Global:CurrentTaskName) - Finished"
                    $Global:TrayIcon.BalloonTipText = $sync.Summary
                    $Global:TrayIcon.BalloonTipIcon = if ($sync.Success) { [System.Windows.Forms.ToolTipIcon]::Info } else { [System.Windows.Forms.ToolTipIcon]::Warning }
                    $Global:TrayIcon.ShowBalloonTip(6000)
                }
            }

            if ($sync.RebootRequired -and -not $Global:ClosingAfterStop) {
                if ($sync.AutoReboot) {
                    # User already chose auto-restart in the preflight dialog -
                    # don't ask again, just do it (with the usual short countdown).
                    Add-CenterLog -Task $Global:CurrentTaskName -Action "Restart" -Result "Restarting automatically (chosen in preflight)" -Level "Info"
                    Start-Process shutdown -ArgumentList "/r /t 10"
                } else {
                    $rebootChoice = [System.Windows.Forms.MessageBox]::Show(
                        "A restart is required to finish applying updates. Restart now?",
                        "Restart Required", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                    if ($rebootChoice -eq [System.Windows.Forms.DialogResult]::Yes) {
                        Add-CenterLog -Task $Global:CurrentTaskName -Action "Restart" -Result "User approved restart" -Level "Info"
                        Start-Process shutdown -ArgumentList "/r /t 10"
                    }
                }
            }

            Save-SessionTerminalHistory -TaskName $Global:CurrentTaskName -Sync $sync

            Stop-BackgroundTask -Job $Global:CurrentJob -Sync $sync
            $Global:CurrentJob = $null
            $Global:CurrentSync = $null

            if ($Global:ClosingAfterStop) {
                # This Done event is the task finishing in response to the
                # "safely stop current task, then close" choice on the close
                # prompt - now that it's actually stopped, finish closing.
                $Global:TaskQueue = $null
                $Global:AllowClose = $true
                $Form.Close()
                return
            }

            if ($sync.StopRequested) {
                # User explicitly stopped this task - don't auto-continue any
                # queued chain (e.g. mid-way through Full Maintenance).
                $Global:TaskQueue = $null
                Show-Dashboard
            } else {
                Start-NextQueuedTask
            }
        }
    })

    # --------------------------------------------------------------
    # Preflight dialogs (shown before a feature starts)
    # --------------------------------------------------------------
    function Show-SystemUpdatePreflight {
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = "Windows, Driver & Firmware Updates"
        $dlg.Size = New-Object System.Drawing.Size(520, 460)
        $dlg.StartPosition = "CenterParent"
        $dlg.BackColor = $Theme.Surface
        $dlg.ForeColor = $Theme.TextPrimary
        $dlg.FormBorderStyle = "FixedDialog"
        $dlg.MaximizeBox = $false
        $dlg.MinimizeBox = $false

        $text = New-Object System.Windows.Forms.Label
        $text.Font = New-Font 9.5
        $text.Location = New-Object System.Drawing.Point(20, 20)
        $text.Size = New-Object System.Drawing.Size(470, 260)
        $text.Text = @"
This does exactly what Settings > Windows Update does, in two passes:

1. Check for updates, then download and install
   - Security fixes, feature updates, cumulative updates

2. Advanced options > Optional updates, download and install all
   - Driver updates (graphics, audio, network, chipset, Bluetooth)
   - Firmware updates (BIOS/UEFI, SSD, other device firmware)
   - Any other optional/preview updates offered

Some updates may require a restart to finish installing.
"@
        $dlg.Controls.Add($text)

        $autoRebootLabel = New-Object System.Windows.Forms.Label
        $autoRebootLabel.Text = "Automatically restart after completion:"
        $autoRebootLabel.Font = New-Font 9.5 ([System.Drawing.FontStyle]::Bold)
        $autoRebootLabel.AutoSize = $true
        $autoRebootLabel.Location = New-Object System.Drawing.Point(20, 290)
        $dlg.Controls.Add($autoRebootLabel)

        $rebootState = @{ Value = $false }
        $rebootToggle = New-ToggleSwitch -Parent $dlg -X 20 -Y 318 -Checked $false -OnChange {
            param($isOn)
            $rebootState.Value = $isOn
        }

        $toggleCaption = New-Object System.Windows.Forms.Label
        $toggleCaption.Text = "OFF = you'll be told a restart is needed and can restart later.`nON = restart automatically with a short countdown."
        $toggleCaption.ForeColor = $Theme.TextSecondary
        $toggleCaption.Font = New-Font 8.5
        $toggleCaption.Size = New-Object System.Drawing.Size(400, 40)
        $toggleCaption.Location = New-Object System.Drawing.Point(75, 316)
        $dlg.Controls.Add($toggleCaption)

        $result = @{ Value = $null }

        $okBtn = New-Object System.Windows.Forms.Button
        $okBtn.Text = "Start"
        $okBtn.Size = New-Object System.Drawing.Size(110, 34)
        $okBtn.Location = New-Object System.Drawing.Point(280, 385)
        $okBtn.BackColor = $Theme.Accent
        $okBtn.ForeColor = [System.Drawing.Color]::White
        $okBtn.FlatStyle = "Flat"
        $okBtn.FlatAppearance.BorderSize = 0
        $okBtn.Add_Click({ $result.Value = $rebootState.Value; $dlg.Close() }.GetNewClosure())
        $dlg.Controls.Add($okBtn)

        $cancelBtn = New-Object System.Windows.Forms.Button
        $cancelBtn.Text = "Cancel"
        $cancelBtn.Size = New-Object System.Drawing.Size(110, 34)
        $cancelBtn.Location = New-Object System.Drawing.Point(160, 385)
        $cancelBtn.BackColor = $Theme.SurfaceAlt
        $cancelBtn.ForeColor = $Theme.TextPrimary
        $cancelBtn.FlatStyle = "Flat"
        $cancelBtn.FlatAppearance.BorderSize = 0
        $cancelBtn.Add_Click({ $result.Value = $null; $dlg.Close() }.GetNewClosure())
        $dlg.Controls.Add($cancelBtn)

        $dlg.ShowDialog($Form) | Out-Null
        return $result.Value
    }

    function Show-RepairPreflight {
        $msg = @"
This will run three repair tools in order:

CHKDSK
  Checks your drive for filesystem problems.
  If a scan is needed, it will be scheduled to run automatically
  the next time you restart your PC (this typically adds
  10-30 minutes to your next startup).

DISM
  Repairs the Windows image used to restore damaged files.
  (Can take 10-20 minutes)

SFC (System File Checker)
  Checks Windows system files and repairs corruption.
  (Can take 5-15 minutes)

Nothing destructive will happen without telling you first.
Continue?
"@
        $result = [System.Windows.Forms.MessageBox]::Show($msg, "Windows Repair Tools",
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
        return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
    }

    function Show-NetworkPreflight {
        $msg = @"
This tool diagnoses network problems using the least intrusive
fix first, testing your connection after every step, and stopping
automatically as soon as it's restored.

Early steps (flushing DNS, renewing your IP, resetting Winsock/TCP-IP)
are low-risk and applied automatically.

Later steps that could remove saved settings - like Wi-Fi passwords,
custom DNS, or static IP configuration - will always ask for your
approval first, with a plain-English explanation of the impact.

Continue?
"@
        $result = [System.Windows.Forms.MessageBox]::Show($msg, "Network Troubleshooter",
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
        return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
    }

    function Show-FullMaintenancePreflight {
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = "Full Maintenance"
        $dlg.Size = New-Object System.Drawing.Size(520, 460)
        $dlg.StartPosition = "CenterParent"
        $dlg.BackColor = $Theme.Surface
        $dlg.ForeColor = $Theme.TextPrimary
        $dlg.FormBorderStyle = "FixedDialog"
        $dlg.MaximizeBox = $false
        $dlg.MinimizeBox = $false

        $text = New-Object System.Windows.Forms.Label
        $text.Font = New-Font 9.5
        $text.Location = New-Object System.Drawing.Point(20, 20)
        $text.Size = New-Object System.Drawing.Size(470, 260)
        $text.Text = @"
Runs everything below automatically, one after another - each
step starts as soon as the previous one finishes:

1. Update Installed Applications
   Updates your apps using winget.

2. Windows Repair Tools
   CHKDSK, DISM, and SFC - fixes disk errors and corrupted
   system files.

3. Windows / Driver / Firmware Updates
   Installs the latest Windows security, driver, and firmware
   updates (same as Settings > Windows Update).

You can stop the whole sequence at any time with the STOP button.
Nothing destructive happens without telling you first.
"@
        $dlg.Controls.Add($text)

        $autoRebootLabel = New-Object System.Windows.Forms.Label
        $autoRebootLabel.Text = "Automatically restart after completion:"
        $autoRebootLabel.Font = New-Font 9.5 ([System.Drawing.FontStyle]::Bold)
        $autoRebootLabel.AutoSize = $true
        $autoRebootLabel.Location = New-Object System.Drawing.Point(20, 290)
        $dlg.Controls.Add($autoRebootLabel)

        $rebootState = @{ Value = $false }
        $rebootToggle = New-ToggleSwitch -Parent $dlg -X 20 -Y 318 -Checked $false -OnChange {
            param($isOn)
            $rebootState.Value = $isOn
        }

        $toggleCaption = New-Object System.Windows.Forms.Label
        $toggleCaption.Text = "Only applies to the last step (Windows Updates), if a restart is needed.`nOFF = you'll be told a restart is needed and can restart later.`nON = restart automatically with a short countdown."
        $toggleCaption.ForeColor = $Theme.TextSecondary
        $toggleCaption.Font = New-Font 8.5
        $toggleCaption.Size = New-Object System.Drawing.Size(400, 50)
        $toggleCaption.Location = New-Object System.Drawing.Point(75, 314)
        $dlg.Controls.Add($toggleCaption)

        $result = @{ Value = $null }

        $okBtn = New-Object System.Windows.Forms.Button
        $okBtn.Text = "Start"
        $okBtn.Size = New-Object System.Drawing.Size(110, 34)
        $okBtn.Location = New-Object System.Drawing.Point(280, 385)
        $okBtn.BackColor = $Theme.Accent
        $okBtn.ForeColor = [System.Drawing.Color]::White
        $okBtn.FlatStyle = "Flat"
        $okBtn.FlatAppearance.BorderSize = 0
        $okBtn.Add_Click({ $result.Value = $rebootState.Value; $dlg.Close() }.GetNewClosure())
        $dlg.Controls.Add($okBtn)

        $cancelBtn = New-Object System.Windows.Forms.Button
        $cancelBtn.Text = "Cancel"
        $cancelBtn.Size = New-Object System.Drawing.Size(110, 34)
        $cancelBtn.Location = New-Object System.Drawing.Point(160, 385)
        $cancelBtn.BackColor = $Theme.SurfaceAlt
        $cancelBtn.ForeColor = $Theme.TextPrimary
        $cancelBtn.FlatStyle = "Flat"
        $cancelBtn.FlatAppearance.BorderSize = 0
        $cancelBtn.Add_Click({ $result.Value = $null; $dlg.Close() }.GetNewClosure())
        $dlg.Controls.Add($cancelBtn)

        $dlg.ShowDialog($Form) | Out-Null
        return $result.Value
    }

    # --------------------------------------------------------------
    # Dashboard cards
    # --------------------------------------------------------------
    New-DashboardCard -Title "Update Installed Applications" `
        -Desc "Keep your apps up to date using winget (installed automatically if it's missing)." `
        -X 24 -Y 24 -OnClick {
            Start-Task -Name "Update Installed Applications" -Worker $Worker_UpdateApps
        }

    New-DashboardCard -Title "Windows / Driver / Firmware Updates" `
        -Desc "Install the latest Windows security, driver, and firmware updates." `
        -X 496 -Y 24 -OnClick {
            $autoReboot = Show-SystemUpdatePreflight
            if ($null -ne $autoReboot) {
                $worker = Get-Worker_SystemUpdate
                Start-Task -Name "Windows / Driver / Firmware Updates" -Worker $worker -AutoReboot $autoReboot
            }
        }

    New-DashboardCard -Title "Windows Repair Tools" `
        -Desc "Run CHKDSK, DISM, and SFC to fix disk errors and corrupted system files." `
        -X 24 -Y 236 -OnClick {
            if (Show-RepairPreflight) {
                Start-Task -Name "Windows Repair Tools" -Worker $Worker_Repair
            }
        }

    New-DashboardCard -Title "Network Troubleshooter" `
        -Desc "Diagnose and fix internet problems safely, starting with the least intrusive steps." `
        -X 496 -Y 236 -OnClick {
            if (Show-NetworkPreflight) {
                Start-Task -Name "Network Troubleshooter" -Worker $Worker_Network
            }
        }

    New-DashboardCard -Title "Full Maintenance" `
        -Desc "Runs everything in order, automatically: update installed apps, then repair tools (CHKDSK, DISM, SFC), then Windows/driver/firmware updates." `
        -X 24 -Y 448 -Width 912 -Height 140 -ButtonText "Run Full Maintenance" -ButtonWidth 220 -OnClick {
            $autoReboot = Show-FullMaintenancePreflight
            if ($null -ne $autoReboot) {
                Start-TaskChain -Tasks @(
                    @{ Name = "Update Installed Applications"; Worker = $Worker_UpdateApps },
                    @{ Name = "Windows Repair Tools"; Worker = $Worker_Repair },
                    @{ Name = "Windows / Driver / Firmware Updates"; Worker = (Get-Worker_SystemUpdate); AutoReboot = $autoReboot }
                )
            }
        }

    # --------------------------------------------------------------
    # Close confirmation (shown by the X button when a task is running)
    # --------------------------------------------------------------
    function Show-CloseConfirmDialog {
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = "Task Still Running"
        $dlg.Size = New-Object System.Drawing.Size(480, 430)
        $dlg.StartPosition = "CenterParent"
        $dlg.BackColor = $Theme.Surface
        $dlg.ForeColor = $Theme.TextPrimary
        $dlg.FormBorderStyle = "FixedDialog"
        $dlg.MaximizeBox = $false
        $dlg.MinimizeBox = $false

        $warnLbl = New-Object System.Windows.Forms.Label
        $warnLbl.Font = New-Font 9.5
        $warnLbl.Location = New-Object System.Drawing.Point(20, 20)
        $warnLbl.Size = New-Object System.Drawing.Size(430, 70)
        $warnLbl.Text = "'$($Global:CurrentTaskName)' is still running. Force-closing while it's mid-task can leave changes half-applied (for example, an interrupted update or repair tool), so pick how you'd like to proceed:"
        $dlg.Controls.Add($warnLbl)

        function Add-CloseOption {
            param([string]$Title, [string]$Desc, [int]$Y, [string]$Tag, $ResultBag, $Dialog)
            $panel = New-Object System.Windows.Forms.Panel
            $panel.Size = New-Object System.Drawing.Size(430, 90)
            $panel.Location = New-Object System.Drawing.Point(20, $Y)
            $panel.BackColor = $Theme.SurfaceAlt
            $panel.Cursor = [System.Windows.Forms.Cursors]::Hand
            $panel.Tag = $Tag

            $t = New-Object System.Windows.Forms.Label
            $t.Text = $Title
            $t.Font = New-Font 10.5 ([System.Drawing.FontStyle]::Bold)
            $t.ForeColor = $Theme.TextPrimary
            $t.AutoSize = $true
            $t.Location = New-Object System.Drawing.Point(16, 12)
            $t.Cursor = [System.Windows.Forms.Cursors]::Hand
            $t.Tag = $Tag
            $panel.Controls.Add($t)

            $d = New-Object System.Windows.Forms.Label
            $d.Text = $Desc
            $d.Font = New-Font 8.75
            $d.ForeColor = $Theme.TextSecondary
            $d.Size = New-Object System.Drawing.Size(398, 44)
            $d.Location = New-Object System.Drawing.Point(16, 38)
            $d.Cursor = [System.Windows.Forms.Cursors]::Hand
            $d.Tag = $Tag
            $panel.Controls.Add($d)

            Set-RoundedRegion -Control $panel -Radius 8

            # NOTE: $ResultBag/$Dialog are real parameters of THIS function,
            # not just visible-via-scope-chain outer variables - that matters
            # because GetNewClosure() only snapshots the scriptblock's own
            # immediate local scope. Referencing $result/$dlg directly here
            # (the outer Show-CloseConfirmDialog variables) would silently
            # capture nothing and null-ref the moment the button is clicked.
            $handler = { $ResultBag.Value = $this.Tag; $Dialog.Close() }.GetNewClosure()
            $panel.Add_Click($handler)
            $t.Add_Click($handler)
            $d.Add_Click($handler)

            $Dialog.Controls.Add($panel)
        }

        $result = @{ Value = $null }
        Add-CloseOption -Title "Continue running and minimize to tray" -Desc "The task keeps running in the background. Device Care Center no longer appears in the taskbar - reopen it from the system tray icon." -Y 100 -Tag "Tray" -ResultBag $result -Dialog $dlg
        Add-CloseOption -Title "Safely stop current task, then close" -Desc "Stops the task the same way the STOP button does, waits for it to finish stopping cleanly, then closes the app." -Y 198 -Tag "StopThenClose" -ResultBag $result -Dialog $dlg
        Add-CloseOption -Title "Force close (not recommended)" -Desc "Closes immediately without waiting. The task is interrupted mid-step, which can leave things partially applied." -Y 296 -Tag "Force" -ResultBag $result -Dialog $dlg

        $dlg.ShowDialog($Form) | Out-Null
        return $result.Value
    }

    # --------------------------------------------------------------
    # Cleanup + run
    # --------------------------------------------------------------
    $Form.Add_FormClosing({
        param($sender, $e)

        if ($Global:AllowClose) {
            # Programmatic close already fully decided (currently only reached
            # after a completed "safely stop, then close") - clean up and let
            # it proceed.
            if ($Global:CurrentSync -and -not $Global:CurrentSync.Done) {
                $Global:CurrentSync.StopRequested = $true
            }
            Stop-BackgroundTask -Job $Global:CurrentJob -Sync $Global:CurrentSync
            if ($Global:TrayIcon) {
                $Global:TrayIcon.Visible = $false
                $Global:TrayIcon.Dispose()
            }
            return
        }

        $taskRunning = $Global:CurrentSync -and -not $Global:CurrentSync.Done
        if (-not $taskRunning) {
            # Nothing running - close normally (still clean up defensively).
            Stop-BackgroundTask -Job $Global:CurrentJob -Sync $Global:CurrentSync
            if ($Global:TrayIcon) {
                $Global:TrayIcon.Visible = $false
                $Global:TrayIcon.Dispose()
            }
            return
        }

        $choice = Show-CloseConfirmDialog
        switch ($choice) {
            "Tray" {
                $e.Cancel = $true
                $Form.Hide()
                $Form.ShowInTaskbar = $false
                $Global:TrayIcon.Visible = $true
            }
            "StopThenClose" {
                $e.Cancel = $true
                $Global:ClosingAfterStop = $true
                $Global:TaskQueue = $null
                if ($Global:CurrentSync) {
                    $Global:CurrentSync.StopRequested = $true
                    $Global:CurrentSync.StopRequestedAt = Get-Date
                    $Global:CurrentSync.ConfirmResult = $false
                }
                $Form.Text = "Device Care Center - Safely stopping, then closing..."
            }
            "Force" {
                # Let THIS same close event proceed - no need to cancel and
                # re-trigger a second Close() from inside this handler.
                if ($Global:CurrentSync -and -not $Global:CurrentSync.Done) {
                    $Global:CurrentSync.StopRequested = $true
                }
                Stop-BackgroundTask -Job $Global:CurrentJob -Sync $Global:CurrentSync
                if ($Global:TrayIcon) {
                    $Global:TrayIcon.Visible = $false
                    $Global:TrayIcon.Dispose()
                }
                $Global:AllowClose = $true
            }
            default {
                # Dialog closed without picking an option - stay open, no change.
                $e.Cancel = $true
            }
        }
    })

    [System.Windows.Forms.Application]::Run($Form)
}
