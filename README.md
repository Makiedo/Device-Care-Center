How to run Device Care Centre:
 
1. Download this repository (the Modules folder, DeviceCareCenter.exe, and
   DeviceCareCenter.ico).
 
2. Open DeviceCareCenter.exe.
 
3. When Windows asks for administrator permission, click Yes. The app needs
   this to run system repair and update tools.
 
That's it - no installation required.

--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Requirements:

Windows 10 or Windows 11
Administrator privileges (the app requests elevation on launch)

--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Features:

1. Update Installed Applications

    a. Updates everything installed via winget, narrating each app's progress and result - "Found 3 apps with an update available," then success/failure for each one as it happens.

2. Windows Repair Tools

   a. Runs CHKDSK, DISM, and SFC in the right order to fix disk errors and corrupted system files, with live streaming output and a real time-remaining estimate - not just a spinner that might be stuck.

3. Windows / Driver / Firmware Updates

    a. Searches and installs updates through the Windows Update Agent API, including Microsoft Update content (Office, .NET, drivers, firmware, Defender security intelligence) alongside core Windows updates - mirroring what you'd get from Settings > Windows Update > Advanced options > Optional updates, not just the recommended list.

4. Network Troubleshooter

    a. Works through connectivity fixes from least to most invasive - DNS flush, DHCP renew, Winsock/TCP-IP reset, adapter cycling, then configuration changes - testing the connection after every step and stopping as soon as it's restored. Anything that could remove saved settings (Wi-Fi passwords, static IP, VPN configs) asks first, in plain language.

5. Full Maintenance

    a. Chains all of the above into a single unattended run: update apps, then repair, then Windows Update - one confirmation up front, then walk away.

6. Built for trust, not just function
    a. Live progress, not a guess. Long-running tools stream real output with a live percentage and a genuine time-remaining estimate calculated from actual progress, so nothing ever looks frozen.
    b. Stop actually stops. Every task can be safely interrupted mid-run. A clear "safely stopping" indicator with a live counter shows the app is still responding, not hung.
    c. Technical / Friendly modes. Plain-language activity log by default, with a full technical terminal view one toggle away for anyone who wants the raw command output.
    d. Closing mid-task offers a real choice, not a forced kill: minimize to the system tray and keep going, safely stop then close, or force close with a clear warning about what that risks.
    e. Nothing destructive happens without asking. Any step that changes settings or removes data - resetting network config, forgetting Wi-Fi profiles, a full network reset - requires explicit confirmation first.
