<#
    Feature.Network.ps1
    ---------------------
    Dashboard card 4: "Network Troubleshooter"

    Nine escalating fix levels, least intrusive first. Tests connectivity
    before/after every step and stops the moment it's restored. Levels 6-9
    (removing DNS/static IP/Wi-Fi profiles/full reset) pause and require
    explicit user approval via Request-WorkConfirm.

    Levels that run an actual external command (ipconfig, netsh) do so via
    Invoke-LiveProcess, so they stream live and can be killed immediately -
    same as every other module - if Stop is clicked mid-command. Levels 5-7
    use PowerShell networking cmdlets directly (Disable/Enable-NetAdapter
    etc.) rather than external processes - these run near-instantly in-
    process, so there's no separate executable to stream or kill.
    Exposes $Worker_Network.
#>

$Worker_Network = New-WorkerScript {
    function Report-ConnectivityAndMaybeStop {
        param($Sync, [int]$Percent)
        Set-WorkProgress -Sync $Sync -Phase "Testing connectivity" -Status "Checking your internet connection..." -Percent $Percent
        Add-WorkCommand -Sync $Sync -Command 'Test-Connection www.msftconnecttest.com'
        $ok = Test-Connectivity
        Add-WorkLog -Sync $Sync -Text "Connectivity test result: $(if ($ok) { 'Connected' } else { 'Not connected' })" -Level $(if ($ok) { "Success" } else { "Warning" })
        return $ok
    }

    # Each "Processes" entry is run through Invoke-LiveProcess (live streamed,
    # cancellable). Levels without Processes use a plain PowerShell Action
    # instead (see levels 5-7 below).
    $levels = @(
        @{ N = 1; Title = "Flush DNS cache"; Impact = "No impact - clears temporary DNS records only."; NeedsConfirm = $false;
           Processes = @(@{ FilePath = "ipconfig"; Args = @("/flushdns") }) }
        @{ N = 2; Title = "Register DNS and renew DHCP lease"; Impact = "Briefly refreshes your IP address; a short connectivity blip is possible.";
           NeedsConfirm = $false;
           Processes = @(
               @{ FilePath = "ipconfig"; Args = @("/registerdns") }
               @{ FilePath = "ipconfig"; Args = @("/release") }
               @{ FilePath = "ipconfig"; Args = @("/renew") }
           ) }
        @{ N = 3; Title = "Reset Winsock"; Impact = "Resets network socket settings; usually safe, may require sign-out.";
           NeedsConfirm = $false; Processes = @(@{ FilePath = "netsh"; Args = @("winsock", "reset") }) }
        @{ N = 4; Title = "Reset TCP/IP"; Impact = "Resets the TCP/IP stack to default. Resetting TCP/IP may require a reboot.";
           NeedsConfirm = $false; Processes = @(@{ FilePath = "netsh"; Args = @("int", "ip", "reset") }) }
        @{ N = 5; Title = "Disable and re-enable network adapter"; Impact = "Your network will briefly disconnect while the adapter restarts.";
           NeedsConfirm = $false;
           Action = {
               $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
               if ($adapter) {
                   "Disabling adapter: $($adapter.Name)"
                   Disable-NetAdapter -Name $adapter.Name -Confirm:$false
                   Start-Sleep -Seconds 3
                   "Re-enabling adapter: $($adapter.Name)"
                   Enable-NetAdapter -Name $adapter.Name -Confirm:$false
                   Start-Sleep -Seconds 3
               } else {
                   "No active adapter found to cycle."
               }
           } }
        @{ N = 6; Title = "Remove custom DNS settings"; Impact = "Removing custom DNS settings may revert your network adapter to automatic settings.";
           NeedsConfirm = $true;
           Action = {
               Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
                   "Resetting DNS servers on: $($_.Name)"
                   Set-DnsClientServerAddress -InterfaceIndex $_.IfIndex -ResetServerAddresses
               }
           } }
        @{ N = 7; Title = "Remove static IP configuration"; Impact = "Removing static IP settings could temporarily disconnect network services.";
           NeedsConfirm = $true;
           Action = {
               Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
                   $ifIndex = $_.IfIndex
                   "Switching $($_.Name) back to automatic (DHCP) addressing."
                   Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                       Where-Object { $_.PrefixOrigin -eq "Manual" } |
                       ForEach-Object { Remove-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $_.IPAddress -Confirm:$false -ErrorAction SilentlyContinue }
                   Set-NetIPInterface -InterfaceIndex $ifIndex -Dhcp Enabled -ErrorAction SilentlyContinue
               }
           } }
        @{ N = 8; Title = "Forget saved Wi-Fi profile(s)"; Impact = "Resetting Wi-Fi profiles may remove saved wireless networks and passwords.";
           NeedsConfirm = $true;
           # Two stages: first discover the profile names (live process, its
           # output parsed below), then delete each one found (also a live
           # process). Handled specially in the main loop via ProfileFlow
           # rather than a static Processes list, since the delete commands
           # depend on what the discovery step finds.
           ProfileFlow = $true }
        @{ N = 9; Title = "Full network reset"; Impact = "This reinstalls all network adapters and resets networking components to factory defaults. A restart will be required, and all network settings (Wi-Fi passwords, VPN configs) will be removed.";
           NeedsConfirm = $true;
           Processes = @(
               @{ FilePath = "netsh"; Args = @("int", "ip", "reset") }
               @{ FilePath = "netsh"; Args = @("winsock", "reset") }
           );
           PostNote = "A restart is required to complete the full network reset." }
    )

    Set-WorkProgress -Sync $Sync -Phase "Level 1: Initial check" -Status "Testing your connection before making any changes..." -Percent 1
    if (Report-ConnectivityAndMaybeStop -Sync $Sync -Percent 2) {
        Set-WorkProgress -Sync $Sync -Phase "Complete" -Status "Your connection is already working." -Percent 100 -ETA "Done"
        $Sync.Done = $true; $Sync.Success = $true; $Sync.Summary = "No problem detected - your internet connection is working."
        return
    }

    $total = $levels.Count
    $progressIncrement = [math]::Floor(100 / $total)

    foreach ($lvl in $levels) {
        if ($Sync.StopRequested) { $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled by user."; return }

        $currentPercent = $lvl.N * $progressIncrement

        if ($lvl.NeedsConfirm) {
            Set-WorkProgress -Sync $Sync -Phase "Level $($lvl.N): $($lvl.Title)" -Status "Waiting for your confirmation..." -Percent ($currentPercent - [math]::Ceiling($progressIncrement / 2))
            $approved = Request-WorkConfirm -Sync $Sync -Title "Confirm: $($lvl.Title)" -Message $lvl.Impact
            if ($Sync.StopRequested) { $Sync.Done = $true; $Sync.Success = $false; $Sync.Summary = "Cancelled by user."; return }
            if (-not $approved) {
                Add-WorkLog -Sync $Sync -Text "User declined: $($lvl.Title). Stopping troubleshooter here." -Level "Warning"
                Set-WorkProgress -Sync $Sync -Phase "Stopped" -Status "Troubleshooting stopped at your request." -Percent ($currentPercent - [math]::Ceiling($progressIncrement / 2)) -ETA "-"
                $Sync.Done = $true
                $Sync.Success = $false
                $Sync.Summary = "Stopped before '$($lvl.Title)' because it wasn't approved. Basic fixes did not resolve the issue - consider contacting your ISP or a technician."
                return
            }
        }

        Set-WorkProgress -Sync $Sync -Phase "Level $($lvl.N): $($lvl.Title)" -Status "Applying fix: $($lvl.Title)..." -Percent ($currentPercent - [math]::Ceiling($progressIncrement / 2))
        Add-WorkLog -Sync $Sync -Text "Attempting: $($lvl.Title) - $($lvl.Impact)"

        $levelCancelled = $false

        if ($lvl.Processes) {
            foreach ($proc in $lvl.Processes) {
                Add-WorkCommand -Sync $Sync -Command "$($proc.FilePath) $($proc.Args -join ' ')"
                $exitCode = Invoke-LiveProcess -Sync $Sync -FilePath $proc.FilePath -ArgumentList $proc.Args -OnLine {
                    param($Sync, $line)
                    Add-TerminalOutput -Sync $Sync -Text ([string]$line)
                }
                if ($Sync.StopRequested) { $levelCancelled = $true; break }
            }
            if (-not $levelCancelled -and $lvl.PostNote) {
                Add-WorkLog -Sync $Sync -Text $lvl.PostNote -Level "Warning"
            }
        } elseif ($lvl.ProfileFlow) {
            # Discover saved Wi-Fi profile names first...
            Add-WorkCommand -Sync $Sync -Command "netsh wlan show profiles"
            $profileLines = New-Object System.Collections.Generic.List[string]
            Invoke-LiveProcess -Sync $Sync -FilePath "netsh" -ArgumentList @("wlan", "show", "profiles") -OnLine {
                param($Sync, $line)
                Add-TerminalOutput -Sync $Sync -Text ([string]$line)
                $profileLines.Add([string]$line)
            } | Out-Null

            if ($Sync.StopRequested) {
                $levelCancelled = $true
            } else {
                $profileNames = $profileLines | ForEach-Object {
                    if ($_ -match '\s:\s(.+)$') { $Matches[1].Trim() }
                }
                # ...then delete each one found.
                foreach ($p in $profileNames) {
                    if ($Sync.StopRequested) { $levelCancelled = $true; break }
                    Add-WorkLog -Sync $Sync -Text "Forgetting Wi-Fi profile: $p"
                    Add-WorkCommand -Sync $Sync -Command "netsh wlan delete profile name=`"$p`""
                    Invoke-LiveProcess -Sync $Sync -FilePath "netsh" -ArgumentList @("wlan", "delete", "profile", "name=$p") -OnLine {
                        param($Sync, $line)
                        Add-TerminalOutput -Sync $Sync -Text ([string]$line)
                    } | Out-Null
                }
            }
        } elseif ($lvl.Action) {
            try {
                $actionOutput = & $lvl.Action 2>&1
                foreach ($line in $actionOutput) {
                    if ("$line".Trim().Length -gt 0) {
                        Add-TerminalOutput -Sync $Sync -Text ([string]$line)
                        Add-WorkLog -Sync $Sync -Text ([string]$line) -Kind "Technical"
                    }
                }
            } catch {
                Add-WorkLog -Sync $Sync -Text "$($lvl.Title) failed: $($_.Exception.Message)" -Level "Warning"
            }
        }

        if ($levelCancelled -or $Sync.StopRequested) {
            $Sync.Done = $true
            $Sync.Success = $false
            $Sync.Summary = "Cancelled during: $($lvl.Title)."
            return
        }

        Add-WorkLog -Sync $Sync -Text "$($lvl.Title) completed." -Level "Success"

        Start-Sleep -Seconds 2
        if (Report-ConnectivityAndMaybeStop -Sync $Sync -Percent $currentPercent) {
            Set-WorkProgress -Sync $Sync -Phase "Complete" -Status "Connectivity restored after: $($lvl.Title)" -Percent 100 -ETA "Done"
            $Sync.Done = $true
            $Sync.Success = $true
            $Sync.Summary = "Connection restored after applying: $($lvl.Title)."
            return
        }
    }

    Set-WorkProgress -Sync $Sync -Phase "Complete" -Status "All available fixes attempted." -Percent 100 -ETA "Done"
    $Sync.Done = $true
    $Sync.Success = $false
    $Sync.Summary = "All troubleshooting steps were attempted, but connectivity was not restored. Your ISP or hardware may need attention."
}
