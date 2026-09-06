<#
.SYNOPSIS
    Run several Claude desktop accounts side by side, each with its own window and icon.

.DESCRIPTION
    Claude for Windows keeps everything about the signed-in account under one data
    folder. Point it at a different folder and it starts as a fresh, separate login.
    This tool manages those folders as named profiles and adds what Claude does not:

      - a distinct taskbar button and colour-badged icon per profile
      - browser sign-ins that land in the profile that asked for them
      - display names, colours and badges you can change
      - one command that undoes all of it (-Revert)

    Your original account is the "Default" profile. It is never modified.

    Files:
      %LOCALAPPDATA%\ClaudeProfiles\<Name>\    a profile's data (Claude's, untouched)
      %LOCALAPPDATA%\ClaudeProfiles\settings.json   this tool's settings
      %LOCALAPPDATA%\ClaudeProfileSwitcher\    icons, logs, compiled helper (all disposable)

.EXAMPLE
    .\ClaudeSwitcher.ps1                 # open the window
    .\ClaudeSwitcher.ps1 -Launch Work    # start a profile directly (what shortcuts do)
    .\ClaudeSwitcher.ps1 -List
    .\ClaudeSwitcher.ps1 -Status
    .\ClaudeSwitcher.ps1 -Install        # put a shortcut to this window on the desktop
    .\ClaudeSwitcher.ps1 -Revert         # undo everything this tool changed
#>
[CmdletBinding()]
param(
    [string]$Launch,
    [switch]$List,
    [string]$Shortcut,
    [string]$To,
    [switch]$Install,
    [switch]$Status,
    [switch]$Revert,
    [switch]$Icons,
    [string]$ClaudePath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeProfileLib.ps1')

# ========================================================================= CLI ==

function Exit-WithError {
    param([string]$Message)
    if ($script:Gui) {
        [System.Windows.Forms.MessageBox]::Show($Message, 'Claude Profile Switcher', 'OK', 'Error') | Out-Null
    } else {
        [Console]::Error.WriteLine($Message)
    }
    exit 1
}

$script:Gui = -not ($Launch -or $List -or $Shortcut -or $Install -or $Status -or $Revert -or $Icons)
if ($script:Gui) { Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing }

try { Initialize-ClaudeLib -ClaudePathOverride $ClaudePath } catch { Exit-WithError $_.Exception.Message }

if ($Revert) {
    'Undoing everything this tool changed (profile folders and logins are not touched):'
    foreach ($line in (Undo-SwitcherChange)) { "  - $line" }
    ''
    'Done. To go back to the original script as well:  git checkout main'
    exit 0
}

if ($Status) {
    "Install:        $($script:ClaudeApp.Kind)  $($script:ClaudeExe)"
    "Default data:   $($script:DefaultProfilePath)"
    "Profiles root:  $($script:ProfileRoot)"
    "Tool files:     $($script:ToolRoot)"
    "Login handler:  $(if (Test-RouterActive) { 'ours' } else { "Claude's (taken back when a profile is launched)" })"
    "Handler backup: $(Test-Path -LiteralPath $script:BackupPath)"
    "Pending login:  $(if ($p = Get-PendingLogin) { $p } else { 'none' })"
    ''
    foreach ($pr in (Get-ProfileList)) {
        $state = if ($pr.Pid) { "running (pid $($pr.Pid))" } else { 'not running' }
        $auth  = if ($pr.SignedIn) { 'signed in' } elseif ($pr.SignedIn -eq $false) { 'signed out' } else { 'never used' }
        ("  {0,-22} {1,-22} {2,-11} {3} {4}" -f $pr.Label, $state, $auth, $pr.Color, $pr.Badge)
    }
    exit 0
}

if ($List) {
    foreach ($pr in (Get-ProfileList)) {
        $state = if ($pr.Pid) { "running (pid $($pr.Pid))" } else { 'not running' }
        $auth  = if ($pr.SignedIn) { 'signed in' } elseif ($pr.SignedIn -eq $false) { 'signed out' } else { '' }
        $name  = if ($pr.Label -ne $pr.Name) { "$($pr.Label) [$($pr.Name)]" } else { $pr.Name }
        '{0,-28} {1,-22} {2,-11} {3}' -f $name, $state, $auth, $pr.Path
    }
    exit 0
}

if ($Icons) {
    foreach ($pr in (Get-ProfileList)) {
        Remove-ProfileIcon -Name $pr.Name
        "  $($pr.Label) -> $(Get-ProfileIcoPath -Name $pr.Name)"
    }
    exit 0
}

if ($Launch) {
    if ($Launch -ne $script:DefaultName -and -not (Test-Path -LiteralPath (Get-ProfilePath -Name $Launch))) {
        Exit-WithError "No profile named '$Launch'. Run .\ClaudeSwitcher.ps1 -List to see them."
    }
    Start-ClaudeProfile -Name $Launch -Wait
    exit 0
}

if ($Shortcut) {
    if ($Shortcut -ne $script:DefaultName -and -not (Test-Path -LiteralPath (Get-ProfilePath -Name $Shortcut))) { Exit-WithError "No profile named '$Shortcut'." }
    $dir = if ($To) { $To } else { [Environment]::GetFolderPath('Desktop') }
    "Created $(New-ProfileShortcut -Name $Shortcut -Directory $dir)"
    exit 0
}

if ($Install) {
    "Created $(New-SwitcherShortcut -Directory ([Environment]::GetFolderPath('Desktop')))"
    "Created $(New-SwitcherShortcut -Directory (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'))"
    exit 0
}

# ========================================================================= GUI ==

[System.Windows.Forms.Application]::EnableVisualStyles()

# A failure inside a button handler would otherwise surface as the raw .NET "Unhandled
# exception" dialog. Log it and show something readable instead.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode('CatchException')
[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    Write-ErrorLog "$($e.Exception.GetType().Name): $($e.Exception.Message)`r`n$($e.Exception.StackTrace)"
    [System.Windows.Forms.MessageBox]::Show("Something went wrong:`r`n`r`n$($e.Exception.Message)`r`n`r`nDetails were written to:`r`n$($script:ErrorLog)", 'Claude Profile Switcher', 'OK', 'Error') | Out-Null
})

# When started from a console (the .cmd launcher), hide that console. Started headless
# there is no console window and this is a no-op.
try {
    if (-not ('ClaudeProfiles.ConsoleWin' -as [type])) {
        Add-Type -Namespace ClaudeProfiles -Name ConsoleWin -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
    }
    $cw = [ClaudeProfiles.ConsoleWin]::GetConsoleWindow()
    if ($cw -ne [IntPtr]::Zero) { [ClaudeProfiles.ConsoleWin]::ShowWindow($cw, 0) | Out-Null }
} catch { }

# ---- palette ------------------------------------------------------------------
$Pal = @{
    Page     = [System.Drawing.Color]::FromArgb(247, 245, 240)
    Card     = [System.Drawing.Color]::White
    CardSel  = [System.Drawing.Color]::FromArgb(255, 247, 242)
    Border   = [System.Drawing.Color]::FromArgb(225, 222, 216)
    BorderSel= [System.Drawing.Color]::FromArgb(217, 119, 87)
    Text     = [System.Drawing.Color]::FromArgb(38, 38, 38)
    Muted    = [System.Drawing.Color]::FromArgb(110, 110, 110)
    Accent   = [System.Drawing.Color]::FromArgb(217, 119, 87)
    Running  = [System.Drawing.Color]::FromArgb(24, 128, 56)
    Stopped  = [System.Drawing.Color]::FromArgb(170, 170, 170)
}
$FontTitle = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$FontName  = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
$FontBody  = New-Object System.Drawing.Font('Segoe UI', 9)
$FontSmall = New-Object System.Drawing.Font('Segoe UI', 8.5)

function ConvertFrom-Hex { param([string]$Hex) [System.Drawing.ColorTranslator]::FromHtml($Hex) }

function Write-Avatar {
    # Shared by the cards and the edit dialog preview: filled circle plus badge text.
    param($g, [int]$Left, [int]$Top, [int]$Size, [string]$Hex, [string]$Glyph)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'
    $brush = New-Object System.Drawing.SolidBrush((ConvertFrom-Hex $Hex))
    $g.FillEllipse($brush, $Left, $Top, $Size, $Size); $brush.Dispose()
    $font = New-Object System.Drawing.Font('Segoe UI', [float]($Size * $(if ($Glyph.Length -gt 1) { 0.34 } else { 0.42 })), [System.Drawing.FontStyle]::Bold)
    $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $g.DrawString($Glyph, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF($Left, $Top, $Size, $Size)), $fmt)
    $font.Dispose(); $fmt.Dispose()
}

# ---- form ---------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Claude Profile Switcher'
$form.Size = New-Object System.Drawing.Size(700, 600)
$form.MinimumSize = New-Object System.Drawing.Size(680, 460)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $Pal.Page
$form.Font = $FontBody
try {
    # Own icon and own taskbar identity (otherwise the button shows PowerShell's icon).
    $form.Icon = New-Object System.Drawing.Icon((Get-SwitcherIcoPath), 32, 32)
    Set-SwitcherWindowIdentity -Hwnd $form.Handle
} catch { try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($script:ClaudeExe) } catch { } }

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Claude accounts'; $title.Font = $FontTitle; $title.ForeColor = $Pal.Text
$title.Location = New-Object System.Drawing.Point(24, 18); $title.AutoSize = $true
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Each profile is a separate login with its own window and icon. Several can run at once.'
$subtitle.ForeColor = $Pal.Muted; $subtitle.Location = New-Object System.Drawing.Point(26, 50); $subtitle.AutoSize = $true
$form.Controls.Add($subtitle)

$toolsBtn = New-Object System.Windows.Forms.Button
$toolsBtn.Text = 'Tools'; $toolsBtn.Size = New-Object System.Drawing.Size(72, 28)
$toolsBtn.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - 96), 22)
$toolsBtn.Anchor = 'Top,Right'; $toolsBtn.FlatStyle = 'Flat'; $toolsBtn.FlatAppearance.BorderColor = $Pal.Border
$toolsBtn.BackColor = $Pal.Card
$form.Controls.Add($toolsBtn)

$cards = New-Object System.Windows.Forms.FlowLayoutPanel
$cards.Location = New-Object System.Drawing.Point(24, 84)
$cards.Size = New-Object System.Drawing.Size(($form.ClientSize.Width - 48), ($form.ClientSize.Height - 84 - 118))
$cards.Anchor = 'Top,Bottom,Left,Right'
$cards.FlowDirection = 'TopDown'; $cards.WrapContents = $false; $cards.AutoScroll = $true
$cards.BackColor = $Pal.Page
$form.Controls.Add($cards)

$statusLbl = New-Object System.Windows.Forms.Label
$statusLbl.ForeColor = $Pal.Muted; $statusLbl.Font = $FontSmall
$statusLbl.Location = New-Object System.Drawing.Point(26, ($form.ClientSize.Height - 104))
$statusLbl.AutoSize = $true; $statusLbl.Anchor = 'Bottom,Left'
$form.Controls.Add($statusLbl)

# Buttons: one row, primary first.
$btnDefs = @(
    @{ Name = 'Open';        Text = 'Open';            W = 88 },
    @{ Name = 'New';         Text = 'New profile';     W = 96 },
    @{ Name = 'Edit';        Text = 'Edit';            W = 70 },
    @{ Name = 'Desktop';     Text = 'Shortcut';        W = 84 },
    @{ Name = 'Folder';      Text = 'Folder';          W = 70 },
    @{ Name = 'Refresh';     Text = 'Refresh icons';   W = 104 },
    @{ Name = 'Delete';      Text = 'Delete';          W = 74 }
)
$Btn = @{}
$x = 24
foreach ($d in $btnDefs) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $d.Text; $b.Size = New-Object System.Drawing.Size($d.W, 36)
    $b.Location = New-Object System.Drawing.Point($x, ($form.ClientSize.Height - 66))
    $b.Anchor = 'Bottom,Left'; $b.FlatStyle = 'Flat'; $b.Font = $FontBody
    $b.FlatAppearance.BorderColor = $Pal.Border; $b.BackColor = $Pal.Card; $b.ForeColor = $Pal.Text
    if ($d.Name -eq 'Open') { $b.BackColor = $Pal.Accent; $b.ForeColor = [System.Drawing.Color]::White; $b.FlatAppearance.BorderColor = $Pal.Accent; $b.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold) }
    $form.Controls.Add($b); $Btn[$d.Name] = $b
    $x += $d.W + 8
}

# ---- state --------------------------------------------------------------------
$script:Profiles  = @()
$script:Selected  = $script:DefaultName
$script:Signature = ''
$script:FastUntil = [datetime]::MinValue
$script:FastFor   = $null

function Get-SelectedProfile { $script:Profiles | Where-Object { $_.Name -eq $script:Selected } | Select-Object -First 1 }

function Update-Buttons {
    $p = Get-SelectedProfile
    $Btn.Open.Enabled    = [bool]$p
    $Btn.Edit.Enabled    = [bool]$p
    $Btn.Desktop.Enabled = [bool]$p
    $Btn.Folder.Enabled  = [bool]$p -and $p.Exists
    $Btn.Delete.Enabled  = [bool]$p -and -not $p.IsDefault -and -not $p.Pid
    $Btn.Open.Text = if ($p -and $p.Pid) { 'Show' } else { 'Open' }
}

function New-Card {
    param($Prof)
    $card = New-Object System.Windows.Forms.Panel
    $card.Size = New-Object System.Drawing.Size(($cards.ClientSize.Width - 8), 68)
    $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    $card.Cursor = 'Hand'
    $card.Tag = $Prof.Name
    $card.Add_Paint({
        param($s, $e)
        $p = $script:Profiles | Where-Object { $_.Name -eq $s.Tag } | Select-Object -First 1
        if (-not $p) { return }
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'
        $sel = ($p.Name -eq $script:Selected)
        $rect = New-Object System.Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
        $bg = New-Object System.Drawing.SolidBrush($(if ($sel) { $Pal.CardSel } else { $Pal.Card }))
        $g.FillRectangle($bg, $rect); $bg.Dispose()
        $pen = New-Object System.Drawing.Pen($(if ($sel) { $Pal.BorderSel } else { $Pal.Border }), $(if ($sel) { 2 } else { 1 }))
        $g.DrawRectangle($pen, $rect); $pen.Dispose()

        Write-Avatar $g 16 14 40 $p.Color $p.Badge

        $tb = New-Object System.Drawing.SolidBrush($Pal.Text)
        $g.DrawString($p.Label, $FontName, $tb, 70, 12); $tb.Dispose()

        $dot = New-Object System.Drawing.SolidBrush($(if ($p.Pid) { $Pal.Running } else { $Pal.Stopped }))
        $g.FillEllipse($dot, 71, 41, 8, 8); $dot.Dispose()
        $state = if ($p.Pid) { 'Running' } else { 'Not running' }
        $auth  = if ($p.SignedIn) { 'Signed in' } elseif ($p.SignedIn -eq $false) { 'Signed out' } elseif (-not $p.Exists) { 'New' } else { '' }
        $line  = if ($auth) { "$state   |   $auth" } else { $state }
        $mb = New-Object System.Drawing.SolidBrush($Pal.Muted)
        $g.DrawString($line, $FontBody, $mb, 84, 36)

        $right = if ($p.IsDefault) { 'your original account' } else { '' }
        if ($right) {
            $sz = $g.MeasureString($right, $FontSmall)
            $g.DrawString($right, $FontSmall, $mb, ($s.Width - $sz.Width - 16), 26)
        }
        $mb.Dispose()
    })
    $card.Add_MouseDown({ param($s, $e) $script:Selected = $s.Tag; Update-Buttons; $cards.Invalidate($true) })
    $card.Add_DoubleClick({ param($s, $e) $script:Selected = $s.Tag; Open-Selected })
    return $card
}

function Update-ProfileCard {
    param([switch]$Force)
    $script:Profiles = @(Get-ProfileList)
    $sig = ($script:Profiles | ForEach-Object { "$($_.Name)|$($_.Label)|$($_.Color)|$($_.Badge)|$($_.Pid)|$($_.SignedIn)|$($_.Exists)" }) -join ';'
    if ($Force -or $sig -ne $script:Signature) {
        $script:Signature = $sig
        if (-not ($script:Profiles | Where-Object { $_.Name -eq $script:Selected })) { $script:Selected = $script:DefaultName }
        $cards.SuspendLayout()
        foreach ($c in @($cards.Controls)) { $cards.Controls.Remove($c); $c.Dispose() }
        foreach ($p in $script:Profiles) { $cards.Controls.Add((New-Card $p)) }
        $cards.ResumeLayout()
        $running = @($script:Profiles | Where-Object Pid).Count
        $statusLbl.Text = "$($script:Profiles.Count) profile(s), $running running   |   Claude $($script:ClaudeApp.Kind)"
        Update-Buttons
    }
}

function Open-Selected {
    $p = Get-SelectedProfile; if (-not $p) { return }
    try {
        Start-ClaudeProfile -Name $p.Name
        if (Test-ProfileTaggable -Name $p.Name) {
            # Tag the new window as early as possible; the fast timer takes over for a while.
            $script:FastFor = $p.Name
            $script:FastUntil = (Get-Date).AddSeconds(25)
            $fast.Start()
        }
    } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Could not start Claude', 'OK', 'Error') | Out-Null }
}

# ---- dialogs ------------------------------------------------------------------

function Show-EditDialog {
    # Name, colour and badge. Nothing here touches the profile folder.
    param($Prof)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Edit '$($Prof.Label)'"; $dlg.Size = New-Object System.Drawing.Size(440, $(if ($Prof.IsDefault) { 360 } else { 330 }))
    $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.BackColor = $Pal.Page; $dlg.Font = $FontBody

    # A hashtable, because event handlers can read outer variables but cannot assign
    # to them; mutating a shared object is the reliable way to share state.
    $look = @{ Label = $Prof.Label; Color = $Prof.Color; Badge = $Prof.Badge; Touched = $false }

    $preview = New-Object System.Windows.Forms.Panel
    $preview.Size = New-Object System.Drawing.Size(72, 72); $preview.Location = New-Object System.Drawing.Point(24, 24)
    $preview.BackColor = $Pal.Page
    $preview.Add_Paint({ param($s, $e) Write-Avatar $e.Graphics 0 0 72 $look.Color $look.Badge })
    $dlg.Controls.Add($preview)

    $lbl1 = New-Object System.Windows.Forms.Label; $lbl1.Text = 'Display name'; $lbl1.Location = New-Object System.Drawing.Point(116, 22); $lbl1.AutoSize = $true; $lbl1.ForeColor = $Pal.Muted
    $name = New-Object System.Windows.Forms.TextBox; $name.Text = $Prof.Label; $name.Location = New-Object System.Drawing.Point(116, 42); $name.Size = New-Object System.Drawing.Size(280, 26); $name.MaxLength = 40
    $dlg.Controls.AddRange(@($lbl1, $name))

    $lbl2 = New-Object System.Windows.Forms.Label; $lbl2.Text = 'Badge (1-2 characters)'; $lbl2.Location = New-Object System.Drawing.Point(116, 76); $lbl2.AutoSize = $true; $lbl2.ForeColor = $Pal.Muted
    $badge = New-Object System.Windows.Forms.TextBox; $badge.Text = $Prof.Badge; $badge.Location = New-Object System.Drawing.Point(116, 96); $badge.Size = New-Object System.Drawing.Size(60, 26); $badge.MaxLength = 2
    $dlg.Controls.AddRange(@($lbl2, $badge))

    $lbl3 = New-Object System.Windows.Forms.Label; $lbl3.Text = 'Colour'; $lbl3.Location = New-Object System.Drawing.Point(24, 132); $lbl3.AutoSize = $true; $lbl3.ForeColor = $Pal.Muted
    $dlg.Controls.Add($lbl3)
    $sx = 24
    foreach ($sw in $script:Palette) {
        $s = New-Object System.Windows.Forms.Button
        $s.Size = New-Object System.Drawing.Size(32, 32); $s.Location = New-Object System.Drawing.Point($sx, 152)
        $s.FlatStyle = 'Flat'; $s.BackColor = (ConvertFrom-Hex $sw.Hex); $s.Tag = $sw.Hex
        $s.FlatAppearance.BorderSize = $(if ($sw.Hex -eq $look.Color) { 3 } else { 0 })
        $s.FlatAppearance.BorderColor = $Pal.Text
        $s.Add_Click({
            param($b, $e)
            $look.Color = $b.Tag
            foreach ($o in $b.Parent.Controls) { if ($o -is [System.Windows.Forms.Button] -and $o.Tag -is [string] -and $o.Tag.StartsWith('#')) { $o.FlatAppearance.BorderSize = $(if ($o.Tag -eq $look.Color) { 3 } else { 0 }) } }
            $preview.Invalidate()
        })
        $dlg.Controls.Add($s); $sx += 38
    }

    $name.Add_TextChanged({ $look.Label = $name.Text; if (-not $look.Touched -and $name.Text) { $badge.Text = $name.Text.Substring(0, 1).ToUpper() } })
    $badge.Add_TextChanged({ $look.Badge = $(if ($badge.Text) { $badge.Text } else { '?' }); $preview.Invalidate() })
    $badge.Add_KeyDown({ $look.Touched = $true })

    $tagChk = $null
    $rowY = 200
    if ($Prof.IsDefault) {
        $tagChk = New-Object System.Windows.Forms.CheckBox
        $tagChk.Text = 'Badge the taskbar icon of my original account too'
        $tagChk.Checked = [bool]$Prof.TagDefault
        $tagChk.Location = New-Object System.Drawing.Point(24, 198); $tagChk.AutoSize = $true
        $dlg.Controls.Add($tagChk)
        $rowY = 224
    }
    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = $(if ($Prof.IsDefault) { 'Leave this off if you keep Claude pinned to the taskbar: a badged window no longer matches the pinned icon and shows as a second button.' } else { 'Applies to the taskbar icon, the window and desktop shortcuts. If this profile is pinned to the taskbar, unpin it and pin the refreshed shortcut again.' })
    $hint.Location = New-Object System.Drawing.Point(24, $rowY); $hint.Size = New-Object System.Drawing.Size(390, 40); $hint.ForeColor = $Pal.Muted; $hint.Font = $FontSmall
    $dlg.Controls.Add($hint)

    $btnY = $rowY + 48
    $reset = New-Object System.Windows.Forms.Button; $reset.Text = 'Reset'; $reset.Size = New-Object System.Drawing.Size(80, 30); $reset.Location = New-Object System.Drawing.Point(24, $btnY); $reset.FlatStyle = 'Flat'; $reset.FlatAppearance.BorderColor = $Pal.Border; $reset.BackColor = $Pal.Card
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Save'; $ok.Size = New-Object System.Drawing.Size(90, 30); $ok.Location = New-Object System.Drawing.Point(232, $btnY); $ok.FlatStyle = 'Flat'; $ok.BackColor = $Pal.Accent; $ok.ForeColor = [System.Drawing.Color]::White; $ok.FlatAppearance.BorderColor = $Pal.Accent
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Size = New-Object System.Drawing.Size(80, 30); $cancel.Location = New-Object System.Drawing.Point(330, $btnY); $cancel.FlatStyle = 'Flat'; $cancel.FlatAppearance.BorderColor = $Pal.Border; $cancel.BackColor = $Pal.Card
    $cancel.DialogResult = 'Cancel'; $dlg.CancelButton = $cancel; $dlg.AcceptButton = $ok
    $dlg.Controls.AddRange(@($reset, $ok, $cancel))

    $reset.Add_Click({
        Set-ProfileAppearance -Name $Prof.Name -Label '' -Color '' -Badge '' -TagDefault $false
        $dlg.Tag = 'reset'; $dlg.DialogResult = 'OK'; $dlg.Close()
    })
    $ok.Add_Click({
        $err = Test-ProfileLabel $name.Text
        if ($err) { [System.Windows.Forms.MessageBox]::Show($err, 'Edit profile', 'OK', 'Warning') | Out-Null; return }
        $glyph = if ($badge.Text.Trim()) { $badge.Text.Trim() } else { $name.Text.Trim().Substring(0, 1).ToUpper() }
        if ($tagChk) { Set-ProfileAppearance -Name $Prof.Name -Label $name.Text.Trim() -Color $look.Color -Badge $glyph -TagDefault $tagChk.Checked }
        else         { Set-ProfileAppearance -Name $Prof.Name -Label $name.Text.Trim() -Color $look.Color -Badge $glyph }
        $dlg.DialogResult = 'OK'; $dlg.Close()
    })

    if ($dlg.ShowDialog($form) -eq 'OK') {
        # Regenerate the icon and push the new look to any running window and shortcuts.
        Reset-ProfileIconHandle
        Get-ProfileIcoPath -Name $Prof.Name | Out-Null
        if ($Prof.IsDefault -and $Prof.TagDefault -and -not (Test-ProfileTaggable -Name $Prof.Name)) {
            # Option was just turned off: hand the live window back to Claude's identity.
            if (-not (Restore-DefaultIdentity)) {
                [System.Windows.Forms.MessageBox]::Show("Default's taskbar icon goes back to normal the next time Claude is restarted.", 'Edit profile', 'OK', 'Information') | Out-Null
            }
        }
        Update-ProfileIdentity -Force | Out-Null
        Update-ProfileShortcut -Name $Prof.Name
        Update-ProfileCard -Force
    }
    $dlg.Dispose()
}

function Show-NewDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'New profile'; $dlg.Size = New-Object System.Drawing.Size(420, 220)
    $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.BackColor = $Pal.Page; $dlg.Font = $FontBody

    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = 'Name for the new profile (e.g. Work, Personal):'; $lbl.Location = New-Object System.Drawing.Point(24, 22); $lbl.AutoSize = $true
    $tb = New-Object System.Windows.Forms.TextBox; $tb.Location = New-Object System.Drawing.Point(24, 48); $tb.Size = New-Object System.Drawing.Size(356, 26); $tb.MaxLength = 40
    $open = New-Object System.Windows.Forms.CheckBox; $open.Text = 'Open it now so I can sign in'; $open.Checked = $true; $open.Location = New-Object System.Drawing.Point(24, 84); $open.AutoSize = $true
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Create'; $ok.Size = New-Object System.Drawing.Size(90, 30); $ok.Location = New-Object System.Drawing.Point(202, 130); $ok.FlatStyle = 'Flat'; $ok.BackColor = $Pal.Accent; $ok.ForeColor = [System.Drawing.Color]::White; $ok.FlatAppearance.BorderColor = $Pal.Accent
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Size = New-Object System.Drawing.Size(80, 30); $cancel.Location = New-Object System.Drawing.Point(300, 130); $cancel.FlatStyle = 'Flat'; $cancel.FlatAppearance.BorderColor = $Pal.Border; $cancel.BackColor = $Pal.Card
    $cancel.DialogResult = 'Cancel'; $dlg.CancelButton = $cancel; $dlg.AcceptButton = $ok
    $dlg.Controls.AddRange(@($lbl, $tb, $open, $ok, $cancel))

    $ok.Add_Click({
        $n = $tb.Text.Trim()
        $err = Test-ProfileName $n
        if ($err) { [System.Windows.Forms.MessageBox]::Show($err, 'New profile', 'OK', 'Warning') | Out-Null; return }
        $dlg.Tag = $n; $dlg.DialogResult = 'OK'; $dlg.Close()
    })
    if ($dlg.ShowDialog($form) -eq 'OK') {
        $n = $dlg.Tag
        New-ClaudeProfile -Name $n | Out-Null
        Get-ProfileIcoPath -Name $n | Out-Null
        $script:Selected = $n
        Update-ProfileCard -Force
        if ($open.Checked) { Open-Selected }
    }
    $dlg.Dispose()
}

function Show-StatusDialog {
    $lines = @(
        "Install:         $($script:ClaudeApp.Kind)",
        "Claude.exe:      $($script:ClaudeExe)",
        "Default data:    $($script:DefaultProfilePath)",
        "Profiles:        $($script:ProfileRoot)",
        "Tool files:      $($script:ToolRoot)",
        "Login handler:   $(if (Test-RouterActive) { 'ours (sign-ins go to the profile that asked)' } else { "Claude's (taken back when you open a profile)" })",
        "Handler backup:  $(Test-Path -LiteralPath $script:BackupPath)",
        "Pending login:   $(if ($p = Get-PendingLogin) { $p } else { 'none' })",
        ''
    )
    foreach ($pr in $script:Profiles) {
        $lines += ("{0,-20} {1,-22} {2}" -f $pr.Label, $(if ($pr.Pid) { "running (pid $($pr.Pid))" } else { 'not running' }), $(if ($pr.SignedIn) { 'signed in' } elseif ($pr.SignedIn -eq $false) { 'signed out' } else { '' }))
    }
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Status'; $dlg.Size = New-Object System.Drawing.Size(700, 380); $dlg.StartPosition = 'CenterParent'
    $tb = New-Object System.Windows.Forms.TextBox; $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Both'; $tb.WordWrap = $false
    $tb.Font = New-Object System.Drawing.Font('Consolas', 9); $tb.Dock = 'Fill'; $tb.Text = ($lines -join "`r`n")
    $dlg.Controls.Add($tb); $dlg.ShowDialog($form) | Out-Null; $dlg.Dispose()
}

# ---- tools menu ---------------------------------------------------------------
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$mi = $menu.Items.Add('Status...')
$mi.Add_Click({ Show-StatusDialog })
$menu.Items.Add('-') | Out-Null
$mi = $menu.Items.Add('Revert all changes made by this tool...')
$mi.Add_Click({
    $msg = "This puts back the original claude:// login handler, deletes the generated icons, logs and markers, resets profile shortcuts to the plain Claude icon, and removes display names, colours and badges.`r`n`r`nYour profiles, their folders and your logins are NOT touched.`r`n`r`nContinue?"
    if ([System.Windows.Forms.MessageBox]::Show($msg, 'Revert', 'YesNo', 'Warning') -ne 'Yes') { return }
    # The timers would re-register the login handler again within seconds; stop them,
    # revert, report, and close - the next launch starts clean.
    $tick.Stop(); $fast.Stop()
    try { $done = Undo-SwitcherChange } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Revert', 'OK', 'Error') | Out-Null; $tick.Start(); return }
    Reset-ProfileIconHandle
    [System.Windows.Forms.MessageBox]::Show(("Done:`r`n - " + ($done -join "`r`n - ") + "`r`n`r`nThe switcher will now close. To restore the original script too, run:  git checkout main"), 'Revert', 'OK', 'Information') | Out-Null
    $form.Close()
})
$toolsBtn.Add_Click({ $menu.Show($toolsBtn, (New-Object System.Drawing.Point(0, $toolsBtn.Height))) })

# ---- button actions -----------------------------------------------------------
$Btn.Open.Add_Click({ Open-Selected })
$Btn.New.Add_Click({ Show-NewDialog })
$Btn.Edit.Add_Click({ $p = Get-SelectedProfile; if ($p) { Show-EditDialog $p } })
$Btn.Desktop.Add_Click({
    $p = Get-SelectedProfile; if (-not $p) { return }
    try {
        $path = New-ProfileShortcut -Name $p.Name -Directory ([Environment]::GetFolderPath('Desktop'))
        [System.Windows.Forms.MessageBox]::Show("Created:`r`n$path`r`n`r`nPin it to the taskbar and it shares a button with the running window.", 'Claude Profile Switcher', 'OK', 'Information') | Out-Null
    } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Claude Profile Switcher', 'OK', 'Error') | Out-Null }
})
$Btn.Folder.Add_Click({ $p = Get-SelectedProfile; if ($p -and $p.Exists) { Start-Process explorer.exe -ArgumentList "`"$($p.Path)`"" } })
$Btn.Refresh.Add_Click({
    # Rebuild every icon file and push it to running windows and shortcuts.
    foreach ($pr in $script:Profiles) { Remove-ProfileIcon -Name $pr.Name; Get-ProfileIcoPath -Name $pr.Name | Out-Null; Update-ProfileShortcut -Name $pr.Name }
    Reset-ProfileIconHandle; Update-ProfileIdentity -Force | Out-Null
    Update-ProfileCard -Force
})
$Btn.Delete.Add_Click({
    $p = Get-SelectedProfile; if (-not $p -or $p.IsDefault) { return }
    if ($p.Pid) { [System.Windows.Forms.MessageBox]::Show("'$($p.Label)' is running. Close that Claude window first.", 'Delete', 'OK', 'Warning') | Out-Null; return }
    $msg = "Delete the profile '$($p.Label)'?`r`n`r`nThis removes its folder and everything Claude stored in it (the login, local settings, cache). The account itself is not affected.`r`n`r`n$($p.Path)"
    if ([System.Windows.Forms.MessageBox]::Show($msg, 'Delete profile', 'YesNo', 'Warning') -ne 'Yes') { return }
    try {
        Remove-ClaudeProfile -Name $p.Name
        foreach ($s in (Get-ProfileShortcut | Where-Object { $_.Profile -eq $p.Name })) { Remove-Item -LiteralPath $s.Path -Force -ErrorAction SilentlyContinue }
        $script:Selected = $script:DefaultName
        Update-ProfileCard -Force
    } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Delete profile', 'OK', 'Error') | Out-Null }
})

# ---- timers -------------------------------------------------------------------
# Slow: refresh the list and fix any profile window that is missing its identity.
# Cheap (a few ms) since process info is read directly rather than through WMI.
$tick = New-Object System.Windows.Forms.Timer
$tick.Interval = 4000
$tick.Add_Tick({
    try {
        Update-ProfileCard
        $extraRunning = @($script:Profiles | Where-Object { $_.Pid -and -not $_.IsDefault }).Count -gt 0
        if ($extraRunning -or ($script:Profiles | Where-Object { $_.IsDefault -and $_.Pid -and $_.TagDefault })) {
            Update-ProfileIdentity | Out-Null
            # Claude reclaims claude:// each time it starts; keep ours in place while a
            # profile that might need to sign in is running.
            if (-not (Test-RouterActive)) { try { Set-RouterRegistration } catch { } }
        }
    } catch { }
})

# Fast: for ~25 s after launching a profile, poll quickly so the window is tagged
# before it is shown and the taskbar button is created with the right identity.
$fast = New-Object System.Windows.Forms.Timer
$fast.Interval = 200
$fast.Add_Tick({
    try {
        if ((Get-Date) -gt $script:FastUntil) { $fast.Stop(); Update-ProfileCard; return }
        $running = Get-RunningProfileMap
        $procId = $running[(Get-ProfilePath -Name $script:FastFor).TrimEnd('\')]
        if (-not $procId) { return }
        Update-ProfileIdentity | Out-Null
        if ([ClaudeProfiles.Native]::WindowsForPid([uint32]$procId, $false).Count -gt 0) {
            # Visible now; one last pass shortly after, then hand over to the slow timer.
            $script:FastUntil = [datetime]::MinValue
            $fast.Stop()
            Update-ProfileCard
        }
    } catch { }
})

$form.Add_Shown({
    Update-ProfileCard -Force
    try { Update-ProfileIdentity | Out-Null } catch { }
    try { Update-SwitcherShortcut } catch { }
    $tick.Start()
})
$form.Add_FormClosed({ $tick.Stop(); $fast.Stop() })
$cards.Add_Resize({ foreach ($c in $cards.Controls) { $c.Width = $cards.ClientSize.Width - 8 } })

try {
    [void]$form.ShowDialog()
} catch {
    Write-ErrorLog "$($_.Exception.GetType().Name): $($_.Exception.Message)`r`n$($_.ScriptStackTrace)"
    [System.Windows.Forms.MessageBox]::Show("The switcher hit an error and has to close:`r`n`r`n$($_.Exception.Message)`r`n`r`nDetails: $($script:ErrorLog)", 'Claude Profile Switcher', 'OK', 'Error') | Out-Null
    exit 1
}
