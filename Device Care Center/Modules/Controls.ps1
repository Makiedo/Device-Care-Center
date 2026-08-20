<#
    Controls.ps1
    ------------
    Small reusable UI building blocks. Depends on $Theme and New-Font from
    Theme.ps1 (must be dot-sourced first).
#>

function Set-RoundedRegion {
    <# Gives any control rounded corners by clipping it to a rounded-rect region. #>
    param([System.Windows.Forms.Control]$Control, [int]$Radius = 10)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $w = $Control.Width; $h = $Control.Height; $r = $Radius
    $path.AddArc(0, 0, $r, $r, 180, 90)
    $path.AddArc($w - $r, 0, $r, $r, 270, 90)
    $path.AddArc($w - $r, $h - $r, $r, $r, 0, 90)
    $path.AddArc(0, $h - $r, $r, $r, 90, 90)
    $path.CloseFigure()
    $Control.Region = New-Object System.Drawing.Region($path)
}

function Set-ToggleVisual {
    <# Repaints a toggle switch (track + knob) to match its current on/off state. #>
    param($Track, $Knob)
    $isOn = [bool]$Track.Tag
    $Track.BackColor = if ($isOn) { $Theme.Accent } else { $Theme.Border }
    $targetX = if ($isOn) { $Track.Width - $Knob.Width - 2 } else { 2 }
    $Knob.Location = New-Object System.Drawing.Point($targetX, 2)
}

function New-ToggleSwitch {
    <#
        Creates a modern sliding toggle switch (like Windows 11 Settings toggles).

        Parameters:
          Parent   - control to add the toggle to
          X, Y     - top-left position
          Checked  - initial state
          OnChange - scriptblock invoked with one argument ($true/$false) whenever
                     the user flips the switch

        Returns the track Panel. Its current state is always available via
        [bool]$toggle.Tag.
    #>
    param(
        [System.Windows.Forms.Control]$Parent,
        [int]$X,
        [int]$Y,
        [bool]$Checked = $false,
        [scriptblock]$OnChange
    )

    $width = 44
    $height = 22

    $track = New-Object System.Windows.Forms.Panel
    $track.Size = New-Object System.Drawing.Size($width, $height)
    $track.Location = New-Object System.Drawing.Point($X, $Y)
    $track.Cursor = [System.Windows.Forms.Cursors]::Hand
    $track.Tag = $Checked
    Set-RoundedRegion -Control $track -Radius ([int]($height / 2))

    $knob = New-Object System.Windows.Forms.Panel
    $knobSize = $height - 4
    $knob.Size = New-Object System.Drawing.Size($knobSize, $knobSize)
    $knob.BackColor = [System.Drawing.Color]::White
    $knob.Cursor = [System.Windows.Forms.Cursors]::Hand
    Set-RoundedRegion -Control $knob -Radius ([int]($knobSize / 2))
    $track.Controls.Add($knob)

    Set-ToggleVisual -Track $track -Knob $knob

    # GetNewClosure() snapshots $track/$knob/$OnChange so the handler still
    # works after this function returns (they'd otherwise fall out of scope).
    $clickHandler = {
        $track.Tag = -not [bool]$track.Tag
        Set-ToggleVisual -Track $track -Knob $knob
        if ($OnChange) { & $OnChange ([bool]$track.Tag) }
    }.GetNewClosure()

    $track.Add_Click($clickHandler)
    $knob.Add_Click($clickHandler)

    $Parent.Controls.Add($track)
    return $track
}
