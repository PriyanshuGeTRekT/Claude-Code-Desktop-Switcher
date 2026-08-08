<#
.SYNOPSIS
    Claude Profile Switcher - run multiple Claude desktop accounts side by side.

.DESCRIPTION
    The Claude desktop app is an Electron app, so it accepts --user-data-dir.
    Each profile directory holds its own cookie jar, Local Storage and config.json,
    which means each one is an independent logged-in account. Instances launched
    against different profile directories run at the same time without conflicting.

    The "Default" profile is your existing install: because Claude ships as an MSIX
    (Store) package, its real data lives inside the package container. Default is
    launched through the shell app model so it keeps full package identity
    (protocol handlers, native messaging host, auto-update).

.PARAMETER Launch
    Launch the named profile and exit without showing the window. Used by shortcuts.

.PARAMETER List
    Print profiles and their running state to the console, then exit.

.PARAMETER Shortcut
    Create a desktop shortcut for the named profile, then exit.

.PARAMETER To
    Directory to write the shortcut into instead of the desktop.

.PARAMETER Install
    Put a "Claude Profile Switcher" shortcut on the desktop and in the Start menu.

.PARAMETER ClaudePath
    Full path to Claude.exe, for installs this script cannot find on its own.
    The choice is remembered, so it only needs to be given once.

.EXAMPLE
    .\ClaudeSwitcher.ps1
    .\ClaudeSwitcher.ps1 -Launch Work
    .\ClaudeSwitcher.ps1 -Shortcut Work
#>

# Note for anyone editing this: PowerShell variable names are case-insensitive and
# parameters live in script scope, so a script-scope variable sharing a parameter's
# name silently reassigns that parameter and fails its type constraint. Keep internal
# state named well away from anything in this param block.
[CmdletBinding()]
param(
    [string]$Launch,
    [switch]$List,
    [string]$Shortcut,
    [string]$To,
    [switch]$Install,
    [string]$ClaudePath
)

$ErrorActionPreference = 'Stop'

# When launched from a shortcut there is no console to print to, so anything fatal
# goes to a log file and, if we got far enough to have WinForms, a message box.
$script:LogPath = Join-Path $env:LOCALAPPDATA 'ClaudeProfiles\switcher-error.log'

trap {
    $detail = "[{0}] {1}`r`n{2}`r`n{3}`r`n" -f (Get-Date -Format 's'), $_.Exception.Message, $_.InvocationInfo.PositionMessage, $_.ScriptStackTrace
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $script:LogPath -Parent) | Out-Null
        Add-Content -LiteralPath $script:LogPath -Value $detail
    } catch { }
    if ('System.Windows.Forms.MessageBox' -as [type]) {
        [System.Windows.Forms.MessageBox]::Show(
            "$($_.Exception.Message)`r`n`r`nDetails written to:`r`n$($script:LogPath)",
            'Claude Profile Switcher', 'OK', 'Error') | Out-Null
    }
    Write-Error $detail -ErrorAction Continue
    exit 1
}

# ---------------------------------------------------------------- discovery --

# Everything we create lives here, well clear of anything Claude owns.
$script:ProfileRoot  = Join-Path $env:LOCALAPPDATA 'ClaudeProfiles'
$script:SettingsPath = Join-Path $script:ProfileRoot 'settings.json'
$script:DefaultName  = 'Default'
$script:ScriptPath   = $MyInvocation.MyCommand.Path

function Get-Setting {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return $null }
    try { return (Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json).$Name } catch { return $null }
}

function Set-Setting {
    param([Parameter(Mandatory)][string]$Name, $Value)
    $bag = @{}
    if (Test-Path -LiteralPath $script:SettingsPath) {
        try {
            (Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json).PSObject.Properties |
                ForEach-Object { $bag[$_.Name] = $_.Value }
        } catch { }
    }
    $bag[$Name] = $Value
    New-Item -ItemType Directory -Force -Path $script:ProfileRoot | Out-Null
    ($bag | ConvertTo-Json) | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
}

function New-InstallInfo {
    param([string]$Kind, [string]$Exe, [string]$Version, [string]$AppUserModelId, [string]$DefaultProfilePath)
    return [pscustomobject]@{
        Kind               = $Kind
        Exe                = $Exe
        Version            = $Version
        AppUserModelId     = $AppUserModelId
        DefaultProfilePath = $DefaultProfilePath
    }
}

<#
    Claude ships in two shapes on Windows and they keep their data in different places:

      Store / MSIX  - the package container redirects %APPDATA%\Claude to
                      %LOCALAPPDATA%\Packages\<family>\LocalCache\Roaming\Claude
      Installer     - a plain Electron app using %APPDATA%\Claude directly

    Resolved fresh on every run, because the install path contains the version number
    and therefore changes each time the app updates itself.
#>
function Resolve-ClaudeInstall {
    param([string]$Override)

    # 1. A path given by the user, this run or a previous one.
    $manual = $Override
    if ([string]::IsNullOrWhiteSpace($manual)) { $manual = Get-Setting 'ClaudePath' }
    if ($manual -and (Test-Path -LiteralPath $manual)) {
        return New-InstallInfo 'Classic' $manual 'unknown' $null (Join-Path $env:APPDATA 'Claude')
    }

    # 2. Store build.
    $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg -and $pkg.InstallLocation) {
        $exe = Join-Path $pkg.InstallLocation 'app\Claude.exe'
        if (-not (Test-Path -LiteralPath $exe)) {
            $exe = Get-ChildItem -LiteralPath $pkg.InstallLocation -Filter 'Claude.exe' -Recurse -ErrorAction SilentlyContinue |
                   Select-Object -First 1 -ExpandProperty FullName
        }
        if ($exe -and (Test-Path -LiteralPath $exe)) {
            return New-InstallInfo 'Msix' $exe $pkg.Version "$($pkg.PackageFamilyName)!Claude" `
                (Join-Path $env:LOCALAPPDATA "Packages\$($pkg.PackageFamilyName)\LocalCache\Roaming\Claude")
        }
    }

    # 3. Installer build: registry entries first, then the usual locations.
    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($root in @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        Get-ItemProperty $root -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*Claude*' -and $_.InstallLocation } |
            ForEach-Object { $dirs.Add($_.InstallLocation) }
    }
    $dirs.Add((Join-Path $env:LOCALAPPDATA 'AnthropicClaude'))
    $dirs.Add((Join-Path $env:LOCALAPPDATA 'Programs\Claude'))
    $dirs.Add((Join-Path $env:ProgramFiles 'Claude'))
    if (${env:ProgramFiles(x86)}) { $dirs.Add((Join-Path ${env:ProgramFiles(x86)} 'Claude')) }

    foreach ($dir in $dirs) {
        if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir)) { continue }
        $exe = Join-Path $dir 'Claude.exe'
        if (-not (Test-Path -LiteralPath $exe)) {
            # Squirrel-style installs park the current build in a versioned app-* folder.
            $exe = Get-ChildItem -LiteralPath $dir -Filter 'Claude.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        }
        if ($exe -and (Test-Path -LiteralPath $exe)) {
            return New-InstallInfo 'Classic' $exe 'unknown' $null (Join-Path $env:APPDATA 'Claude')
        }
    }

    throw "Could not find the Claude desktop app on this computer.`r`n`r`nIf it is installed somewhere unusual, point at it once and the choice is remembered:`r`n    .\ClaudeSwitcher.ps1 -ClaudePath `"C:\path\to\Claude.exe`""
}

$script:ClaudeApp            = Resolve-ClaudeInstall -Override $ClaudePath
$script:ClaudeExe          = $script:ClaudeApp.Exe
$script:DefaultProfilePath = $script:ClaudeApp.DefaultProfilePath
if ($ClaudePath) { Set-Setting 'ClaudePath' $script:ClaudeApp.Exe }

# ----------------------------------------------------------------- profiles --

function Get-ProfilePath {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -eq $script:DefaultName) { return $script:DefaultProfilePath }
    return (Join-Path $script:ProfileRoot $Name)
}

function Get-RunningProfileMap {
    # Maps a profile directory to the PID of the top-level Claude window process.
    # Child processes carry --type=renderer and friends, so they are filtered out.
    $map = @{}
    $procs = Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' }

    foreach ($p in $procs) {
        if ($p.CommandLine -match '--user-data-dir="?([^"]+?)"?(\s|$)') {
            $key = $Matches[1].TrimEnd('\')
        } else {
            $key = $script:DefaultProfilePath.TrimEnd('\')
        }
        if (-not $map.ContainsKey($key)) { $map[$key] = $p.ProcessId }
    }
    return $map
}

function Get-ProfileList {
    $running = Get-RunningProfileMap
    $result  = New-Object System.Collections.Generic.List[object]

    $defaultPath = $script:DefaultProfilePath
    $result.Add([pscustomobject]@{
        Name      = $script:DefaultName
        Path      = $defaultPath
        IsDefault = $true
        Exists    = (Test-Path -LiteralPath $defaultPath)
        Pid       = $running[$defaultPath.TrimEnd('\')]
        LastUsed  = $(if (Test-Path -LiteralPath $defaultPath) { (Get-Item -LiteralPath $defaultPath -Force).LastWriteTime } else { $null })
    })

    if (Test-Path -LiteralPath $script:ProfileRoot) {
        Get-ChildItem -LiteralPath $script:ProfileRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name | ForEach-Object {
                $result.Add([pscustomobject]@{
                    Name      = $_.Name
                    Path      = $_.FullName
                    IsDefault = $false
                    Exists    = $true
                    Pid       = $running[$_.FullName.TrimEnd('\')]
                    LastUsed  = $_.LastWriteTime
                })
            }
    }
    return $result
}

function Test-ProfileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name))        { return 'Name cannot be empty.' }
    if ($Name -eq $script:DefaultName)              { return "'$($script:DefaultName)' is reserved for your existing account." }
    if ($Name -match '[\\/:*?"<>|]')                { return 'Name cannot contain \ / : * ? " < > |' }
    if ($Name.Length -gt 40)                        { return 'Name is too long (40 characters max).' }
    if (Test-Path -LiteralPath (Join-Path $script:ProfileRoot $Name)) { return "A profile named '$Name' already exists." }
    return $null
}

function New-ClaudeProfile {
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path $script:ProfileRoot $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Start-ClaudeProfile {
    param([Parameter(Mandatory)][string]$Name)

    if ($Name -eq $script:DefaultName) {
        if ($script:ClaudeApp.Kind -eq 'Msix') {
            # Through the shell app model, so the instance keeps package identity.
            Start-Process 'explorer.exe' -ArgumentList "shell:AppsFolder\$($script:ClaudeApp.AppUserModelId)"
        } else {
            Start-Process -FilePath $script:ClaudeExe -WindowStyle Normal
        }
        return
    }

    $path = Get-ProfilePath -Name $Name
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    # -WindowStyle Normal matters: shortcuts run us hidden, and without an explicit
    # show state Claude would inherit ours and start with an invisible window.
    Start-Process -FilePath $script:ClaudeExe -ArgumentList "--user-data-dir=`"$path`"" -WindowStyle Normal
}

function Remove-ClaudeProfile {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -eq $script:DefaultName) { throw 'The Default profile cannot be deleted.' }
    $path = Join-Path $script:ProfileRoot $Name
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

function New-ProfileShortcut {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Directory
    )
    $shell = New-Object -ComObject WScript.Shell
    $link  = $shell.CreateShortcut((Join-Path $Directory "Claude - $Name.lnk"))

    if ($Name -eq $script:DefaultName -and $script:ClaudeApp.Kind -eq 'Msix') {
        $link.TargetPath = 'explorer.exe'
        $link.Arguments  = "shell:AppsFolder\$($script:ClaudeApp.AppUserModelId)"
    } elseif ($Name -eq $script:DefaultName) {
        $link.TargetPath = $script:ClaudeExe
        $link.Arguments  = ''
    } else {
        # Re-runs this script so the executable path is resolved at click time,
        # which keeps the shortcut working across Claude updates.
        $link.TargetPath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
        $link.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($script:ScriptPath)`" -Launch `"$Name`""
    }

    $link.IconLocation     = "$($script:ClaudeExe),0"
    $link.Description      = "Launch Claude using the '$Name' account profile"
    $link.WorkingDirectory = (Split-Path $script:ScriptPath -Parent)
    $link.Save()
    return $link.FullName
}

function New-SwitcherShortcut {
    param([Parameter(Mandatory)][string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
    $shell = New-Object -ComObject WScript.Shell
    $link  = $shell.CreateShortcut((Join-Path $Directory 'Claude Profile Switcher.lnk'))
    $link.TargetPath       = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $link.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$($script:ScriptPath)`""
    $link.IconLocation     = "$($script:ClaudeExe),0"
    $link.Description      = 'Switch between Claude desktop accounts'
    $link.WorkingDirectory = (Split-Path $script:ScriptPath -Parent)
    $link.WindowStyle      = 7   # minimised, so the console never flashes into view
    $link.Save()
    return $link.FullName
}

# ------------------------------------------------------------ console modes --

if ($Install) {
    New-SwitcherShortcut -Directory ([Environment]::GetFolderPath('Desktop'))
    New-SwitcherShortcut -Directory (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs')
    return
}

if ($Launch) {
    Start-ClaudeProfile -Name $Launch
    return
}

if ($Shortcut) {
    $dir = $To
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = [Environment]::GetFolderPath('Desktop') }
    New-ProfileShortcut -Name $Shortcut -Directory $dir
    return
}

if ($List) {
    Get-ProfileList | ForEach-Object {
        $state = if ($_.Pid) { "running (pid $($_.Pid))" } else { 'stopped' }
        '{0,-20} {1,-22} {2}' -f $_.Name, $state, $_.Path
    }
    return
}

# ------------------------------------------------------------------ the GUI --

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('Native.WinApi' -as [type])) {
    Add-Type -Name WinApi -Namespace Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")]   public static extern bool SetForegroundWindow(IntPtr hWnd);
'@
}

$SW_HIDE = 0
$SW_SHOW = 5

# Hide our own console window rather than launching with -WindowStyle Hidden: that
# flag lands in the process STARTUPINFO, and WinForms applies it to the first window
# it shows, so the form itself would come up invisible.
$console = [Native.WinApi]::GetConsoleWindow()
if ($console -ne [IntPtr]::Zero) { [Native.WinApi]::ShowWindow($console, $SW_HIDE) | Out-Null }

try { [System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::SystemAware) | Out-Null } catch { }
[System.Windows.Forms.Application]::EnableVisualStyles()

$bg      = [System.Drawing.Color]::FromArgb(250, 249, 245)
$ink     = [System.Drawing.Color]::FromArgb(38, 38, 36)
$muted   = [System.Drawing.Color]::FromArgb(120, 118, 112)
$accent  = [System.Drawing.Color]::FromArgb(203, 123, 93)
$running = [System.Drawing.Color]::FromArgb(46, 125, 74)

$fontUI    = New-Object System.Drawing.Font('Segoe UI', 9.5)
$fontTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
$fontSmall = New-Object System.Drawing.Font('Segoe UI', 8.5)

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'Claude Profile Switcher'
$form.Size            = New-Object System.Drawing.Size(640, 480)
$form.MinimumSize     = New-Object System.Drawing.Size(560, 420)
$form.StartPosition   = 'CenterScreen'
$form.BackColor       = $bg
$form.Font            = $fontUI
try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($script:ClaudeExe) } catch { }

$title           = New-Object System.Windows.Forms.Label
$title.Text      = 'Claude accounts'
$title.Font      = $fontTitle
$title.ForeColor = $ink
$title.Location  = New-Object System.Drawing.Point(20, 16)
$title.Size      = New-Object System.Drawing.Size(400, 28)
$form.Controls.Add($title)

$subtitle           = New-Object System.Windows.Forms.Label
$subtitle.Text      = 'Each profile is a separate login. Several can run at the same time.'
$subtitle.Font      = $fontSmall
$subtitle.ForeColor = $muted
$subtitle.Location  = New-Object System.Drawing.Point(21, 44)
$subtitle.Size      = New-Object System.Drawing.Size(500, 18)
$form.Controls.Add($subtitle)

$listView                   = New-Object System.Windows.Forms.ListView
$listView.Location              = New-Object System.Drawing.Point(20, 72)
$listView.Size                  = New-Object System.Drawing.Size(590, 268)
$listView.View                  = 'Details'
$listView.FullRowSelect         = $true
$listView.MultiSelect           = $false
$listView.HideSelection         = $false
$listView.BackColor             = [System.Drawing.Color]::White
$listView.ForeColor             = $ink
$listView.Anchor                = 'Top,Left,Right,Bottom'
$listView.Columns.Add('Profile', 170)  | Out-Null
$listView.Columns.Add('Status', 140)   | Out-Null
$listView.Columns.Add('Last used', 150)| Out-Null
$listView.Columns.Add('', 100)         | Out-Null
$form.Controls.Add($listView)

$status           = New-Object System.Windows.Forms.Label
$status.Font      = $fontSmall
$status.ForeColor = $muted
$status.Location  = New-Object System.Drawing.Point(21, 348)
$status.Size      = New-Object System.Drawing.Size(590, 18)
$status.Anchor    = 'Left,Right,Bottom'
$form.Controls.Add($status)

function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 108, [switch]$Primary)
    $b           = New-Object System.Windows.Forms.Button
    $b.Text      = $Text
    $b.Location  = New-Object System.Drawing.Point($X, $Y)
    $b.Size      = New-Object System.Drawing.Size($Width, 34)
    $b.FlatStyle = 'Flat'
    $b.Anchor    = 'Left,Bottom'
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
    if ($Primary) {
        $b.BackColor                 = $accent
        $b.ForeColor                 = [System.Drawing.Color]::White
        $b.FlatAppearance.BorderSize = 0
        $b.Font                      = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
    } else {
        $b.BackColor                       = [System.Drawing.Color]::White
        $b.ForeColor                       = $ink
        $b.FlatAppearance.BorderColor      = [System.Drawing.Color]::FromArgb(220, 217, 210)
        $b.FlatAppearance.BorderSize       = 1
    }
    $form.Controls.Add($b)
    return $b
}

$btnLaunch   = New-Button -Text 'Launch'          -X 20  -Y 378 -Width 116 -Primary
$btnNew      = New-Button -Text 'New profile'     -X 144 -Y 378
$btnShortcut = New-Button -Text 'Add to desktop'  -X 260 -Y 378
$btnFolder   = New-Button -Text 'Open folder'     -X 376 -Y 378
$btnDelete   = New-Button -Text 'Delete'          -X 492 -Y 378 -Width 118

function Update-List {
    $selectedName = $null
    if ($listView.SelectedItems.Count -gt 0) { $selectedName = $listView.SelectedItems[0].Text }

    $listView.BeginUpdate()
    $listView.Items.Clear()
    $profiles = Get-ProfileList
    foreach ($p in $profiles) {
        $item = New-Object System.Windows.Forms.ListViewItem($p.Name)
        if ($p.Pid) {
            $item.SubItems.Add("Running (pid $($p.Pid))") | Out-Null
            $item.UseItemStyleForSubItems = $false
            $item.SubItems[1].ForeColor = $running
        } else {
            $item.SubItems.Add('Not running') | Out-Null
            $item.UseItemStyleForSubItems = $false
            $item.SubItems[1].ForeColor = $muted
        }
        if ($p.LastUsed) {
            $item.SubItems.Add($p.LastUsed.ToString('d MMM yyyy, HH:mm')) | Out-Null
        } else {
            $item.SubItems.Add('never') | Out-Null
        }
        $item.SubItems[2].ForeColor = $muted
        if ($p.IsDefault) {
            $item.SubItems.Add('your original') | Out-Null
        } else {
            $item.SubItems.Add('') | Out-Null
        }
        $item.SubItems[3].ForeColor = $muted
        $item.Tag = $p
        $listView.Items.Add($item) | Out-Null
    }
    $listView.EndUpdate()

    if ($selectedName) {
        foreach ($i in $listView.Items) { if ($i.Text -eq $selectedName) { $i.Selected = $true } }
    }
    if ($listView.SelectedItems.Count -eq 0 -and $listView.Items.Count -gt 0) { $listView.Items[0].Selected = $true }

    $count = ($profiles | Where-Object { $_.Pid }).Count
    $label = $(if ($script:ClaudeApp.Version -eq 'unknown') { $script:ClaudeApp.Kind } else { $script:ClaudeApp.Version })
    # Kept deliberately ASCII only: without a BOM, Windows PowerShell 5.1 reads this file
    # using the system codepage, so non-ASCII here renders as garbage on other locales.
    $status.Text = "$($profiles.Count) profile(s), $count running   |   Claude $label"
}

function Get-SelectedProfile {
    if ($listView.SelectedItems.Count -eq 0) { return $null }
    return $listView.SelectedItems[0].Tag
}

function Show-Prompt {
    param([string]$Message, [string]$Title)
    $dlg              = New-Object System.Windows.Forms.Form
    $dlg.Text         = $Title
    $dlg.Size         = New-Object System.Drawing.Size(400, 178)
    $dlg.StartPosition= 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox  = $false
    $dlg.MinimizeBox  = $false
    $dlg.BackColor    = $bg
    $dlg.Font         = $fontUI

    $lbl          = New-Object System.Windows.Forms.Label
    $lbl.Text     = $Message
    $lbl.Location = New-Object System.Drawing.Point(16, 16)
    $lbl.Size     = New-Object System.Drawing.Size(356, 34)
    $lbl.ForeColor= $ink
    $dlg.Controls.Add($lbl)

    $box          = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(18, 56)
    $box.Size     = New-Object System.Drawing.Size(352, 26)
    $dlg.Controls.Add($box)

    $ok           = New-Object System.Windows.Forms.Button
    $ok.Text      = 'Create'
    $ok.Location  = New-Object System.Drawing.Point(182, 96)
    $ok.Size      = New-Object System.Drawing.Size(90, 32)
    $ok.DialogResult = 'OK'
    $dlg.Controls.Add($ok)

    $cancel       = New-Object System.Windows.Forms.Button
    $cancel.Text  = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(280, 96)
    $cancel.Size  = New-Object System.Drawing.Size(90, 32)
    $cancel.DialogResult = 'Cancel'
    $dlg.Controls.Add($cancel)

    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel

    if ($dlg.ShowDialog($form) -eq 'OK') { return $box.Text.Trim() }
    return $null
}

$btnLaunch.Add_Click({
    $p = Get-SelectedProfile
    if (-not $p) { return }
    if ($p.Pid) {
        [System.Windows.Forms.MessageBox]::Show(
            "'$($p.Name)' is already running. Look for its window on the taskbar.",
            'Already running', 'OK', 'Information') | Out-Null
        return
    }
    try {
        Start-ClaudeProfile -Name $p.Name
        # The refresh timer flips the row to Running once the window is up.
        $status.Text = "Starting '$($p.Name)'..."
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Could not launch', 'OK', 'Error') | Out-Null
    }
})

$btnNew.Add_Click({
    $name = Show-Prompt -Message "Name for the new account profile, for example Work or Personal." -Title 'New profile'
    if (-not $name) { return }
    $err = Test-ProfileName -Name $name
    if ($err) {
        [System.Windows.Forms.MessageBox]::Show($err, 'Invalid name', 'OK', 'Warning') | Out-Null
        return
    }
    New-ClaudeProfile -Name $name | Out-Null
    Update-List
    foreach ($i in $listView.Items) { if ($i.Text -eq $name) { $i.Selected = $true } }
    $status.Text = "Created '$name'. Launch it and sign in with your other account."
})

$btnShortcut.Add_Click({
    $p = Get-SelectedProfile
    if (-not $p) { return }
    try {
        $path = New-ProfileShortcut -Name $p.Name -Directory ([Environment]::GetFolderPath('Desktop'))
        $status.Text = "Shortcut created: $path"
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Could not create shortcut', 'OK', 'Error') | Out-Null
    }
})

$btnFolder.Add_Click({
    $p = Get-SelectedProfile
    if (-not $p) { return }
    if (Test-Path -LiteralPath $p.Path) {
        Start-Process 'explorer.exe' -ArgumentList "`"$($p.Path)`""
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            "This profile has no folder yet. It is created the first time you launch it.",
            'Nothing there yet', 'OK', 'Information') | Out-Null
    }
})

$btnDelete.Add_Click({
    $p = Get-SelectedProfile
    if (-not $p) { return }
    if ($p.IsDefault) {
        [System.Windows.Forms.MessageBox]::Show(
            "The Default profile is your original Claude install and cannot be deleted here.",
            'Not allowed', 'OK', 'Warning') | Out-Null
        return
    }
    if ($p.Pid) {
        [System.Windows.Forms.MessageBox]::Show(
            "Close the '$($p.Name)' window before deleting it.",
            'Still running', 'OK', 'Warning') | Out-Null
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Delete the '$($p.Name)' profile and sign that account out on this computer?`n`nThe folder and its saved login are removed. Your other profiles are untouched.",
        'Delete profile', 'YesNo', 'Warning')
    if ($answer -eq 'Yes') {
        try {
            Remove-ClaudeProfile -Name $p.Name
            Update-List
            $status.Text = "Deleted '$($p.Name)'."
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Could not delete', 'OK', 'Error') | Out-Null
        }
    }
})

$listView.Add_DoubleClick({ $btnLaunch.PerformClick() })

# Keep the running/stopped column honest while the window is open.
$refresh = New-Object System.Windows.Forms.Timer
$refresh.Interval = 5000
$refresh.Add_Tick({ Update-List })
$form.Add_Shown({
    $refresh.Start()
    # Force the window visible and frontmost even if the process was started hidden.
    [Native.WinApi]::ShowWindow($form.Handle, $SW_SHOW) | Out-Null
    [Native.WinApi]::SetForegroundWindow($form.Handle) | Out-Null
    $form.Activate()
})
$form.Add_FormClosed({ $refresh.Stop() })

Update-List
[System.Windows.Forms.Application]::Run($form)
