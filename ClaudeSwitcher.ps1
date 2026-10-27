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
    Launch the named profile, or bring its window forward if it is already running,
    then exit without showing the switcher. Used by shortcuts.

.PARAMETER List
    Print profiles and their running state to the console, then exit.

.PARAMETER Shortcut
    Create desktop and Start menu shortcuts for the named profile, then exit.

.PARAMETER To
    Directory to write the -Shortcut shortcut into instead of the desktop and Start menu.

.PARAMETER Install
    Copy the switcher to a fixed location under %LOCALAPPDATA%\ClaudeProfiles and put a
    "Claude Profile Switcher" shortcut on the desktop and in the Start menu.

.PARAMETER ClaudePath
    Full path to Claude.exe, for installs this script cannot find on its own.
    The choice is remembered, so it only needs to be given once.

.PARAMETER Tray
    Start in the notification area without opening the window. Used by "Start with Windows".

.PARAMETER AddAccount
    Create a new profile and open Claude at its sign-in screen. Used by the
    "Claude - Add account" Start menu shortcut.

.PARAMETER RouteSignIns
    Turn on sign-in routing: make the switcher the handler for claude:// links, so a
    browser sign-in comes back to the account that asked for it instead of Default.

.PARAMETER Status
    Print the state of sign-in routing and of each open account, then exit.

.PARAMETER Revert
    Turn sign-in routing off and put the original claude:// handler back.

.PARAMETER HandleLink
    Used by Windows once sign-in routing is on: the claude:// link to forward. Not meant
    to be typed, and refused when combined with any other parameter.

.EXAMPLE
    .\ClaudeSwitcher.ps1
    .\ClaudeSwitcher.ps1 -Launch Work
    .\ClaudeSwitcher.ps1 -Shortcut Work
    .\ClaudeSwitcher.ps1 -AddAccount
    .\ClaudeSwitcher.ps1 -RouteSignIns
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
    [string]$ClaudePath,
    [switch]$Tray,
    [switch]$AddAccount,
    [switch]$RouteSignIns,
    [switch]$Status,
    [switch]$Revert,
    [string]$HandleLink
)

$ErrorActionPreference = 'Stop'

# When launched from a shortcut there is no console to print to, so anything fatal
# goes to a log file and a message box.
$script:LogPath = Join-Path $env:LOCALAPPDATA 'ClaudeProfiles\switcher-error.log'

trap {
    $detail = "[{0}] {1}`r`n{2}`r`n{3}`r`n" -f (Get-Date -Format 's'), $_.Exception.Message, $_.InvocationInfo.PositionMessage, $_.ScriptStackTrace
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $script:LogPath -Parent) | Out-Null
        Add-Content -LiteralPath $script:LogPath -Value $detail
    } catch { }
    # -Launch never loads WinForms, but a shortcut-launched failure with no message box
    # looks exactly like nothing happening, so load it just to report the error.
    try { Add-Type -AssemblyName System.Windows.Forms } catch { }
    if ('System.Windows.Forms.MessageBox' -as [type]) {
        [System.Windows.Forms.MessageBox]::Show(
            "$($_.Exception.Message)`r`n`r`nDetails written to:`r`n$($script:LogPath)",
            'Claude Profile Switcher', 'OK', 'Error') | Out-Null
    }
    Write-Error $detail -ErrorAction Continue
    exit 1
}

# ---------------------------------------------------------------- discovery --

# Everything we create lives here, well clear of anything Claude owns. The switcher's
# own files sit in a dot-folder so they can never be mistaken for a profile.
$script:ProfileRoot     = Join-Path $env:LOCALAPPDATA 'ClaudeProfiles'
# Extra profiles' data lives directly under %LOCALAPPDATA%, never nested: see Get-ProfilePath.
$script:ProfileDirPrefix = 'ClaudeProfile-'
$script:SwitcherHome    = Join-Path $script:ProfileRoot '.switcher'
$script:IconDir         = Join-Path $script:SwitcherHome 'icons'
$script:InstalledScript = Join-Path $script:SwitcherHome 'ClaudeSwitcher.ps1'
$script:SettingsPath    = Join-Path $script:ProfileRoot 'settings.json'
$script:DefaultName     = 'Default'
$script:ScriptPath      = $MyInvocation.MyCommand.Path
$script:RouterLogPath   = Join-Path $script:SwitcherHome 'sign-in-router.log'

function Test-HandleLinkAlone {
    # -HandleLink carries a link from the browser, and Windows hands a quote inside it to
    # this script as separate arguments, so a crafted link can bring parameters of its own.
    # With -HandleLink, nothing else may be bound.
    param([Collections.IDictionary]$Bound)
    return ($Bound.Keys -notcontains 'HandleLink') -or ($Bound.Count -eq 1)
}

# Checked before any parameter is acted on: -ClaudePath, for one, is saved to settings.json
# further down, and every later run would launch it. Write-RouterLog is not defined yet,
# hence the direct write.
if (-not (Test-HandleLinkAlone -Bound $PSBoundParameters)) {
    try {
        New-Item -ItemType Directory -Force -Path $script:SwitcherHome | Out-Null
        Add-Content -LiteralPath $script:RouterLogPath -Value ('[{0}] Refused: -HandleLink arrived together with other parameters.' -f (Get-Date -Format 's'))
    } catch { }
    return
}

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
    ($bag | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
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

    The install path contains the version number and therefore changes each time the
    app updates itself, so a found path is only ever trusted while it still exists.
#>
function Find-ClaudeInstall {
    # Store build.
    $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg -and $pkg.InstallLocation) {
        $exe = Join-Path $pkg.InstallLocation 'app\Claude.exe'
        if (-not (Test-Path -LiteralPath $exe)) {
            $exe = Get-ChildItem -LiteralPath $pkg.InstallLocation -Filter 'Claude.exe' -Recurse -ErrorAction SilentlyContinue |
                   Select-Object -First 1 -ExpandProperty FullName
        }
        if ($exe -and (Test-Path -LiteralPath $exe)) {
            return New-InstallInfo 'Msix' $exe ([string]$pkg.Version) "$($pkg.PackageFamilyName)!Claude" `
                (Join-Path $env:LOCALAPPDATA "Packages\$($pkg.PackageFamilyName)\LocalCache\Roaming\Claude")
        }
    }

    # Installer build: registry entries first, then the usual locations.
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

function Resolve-ClaudeInstall {
    param([string]$Override, [switch]$AllowCache)

    # 1. A path given on this run. A typo here used to be silently ignored, which only
    # hid the problem, so it is an error now.
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        if (-not (Test-Path -LiteralPath $Override -PathType Leaf)) {
            throw "-ClaudePath points at '$Override', which does not exist."
        }
        $full = (Resolve-Path -LiteralPath $Override).ProviderPath
        return New-InstallInfo 'Classic' $full 'unknown' $null (Join-Path $env:APPDATA 'Claude')
    }

    # 2. A path given on a previous run.
    $saved = Get-Setting 'ClaudePath'
    if ($saved -and (Test-Path -LiteralPath $saved -PathType Leaf)) {
        return New-InstallInfo 'Classic' $saved 'unknown' $null (Join-Path $env:APPDATA 'Claude')
    }

    # 3. The last search result. Get-AppxPackage alone costs a noticeable fraction of a
    # second and shortcuts pay it on every click. Only -Launch uses this: an update makes
    # the versioned path vanish and we fall through, and the window and tray always do a
    # fresh search, which keeps the cache from pointing at a superseded build for long.
    if ($AllowCache) {
        $cached = Get-Setting 'InstallCache'
        if ($cached -and $cached.Exe -and (Test-Path -LiteralPath $cached.Exe -PathType Leaf)) {
            return New-InstallInfo $cached.Kind $cached.Exe $cached.Version $cached.AppUserModelId $cached.DefaultProfilePath
        }
    }

    $found = Find-ClaudeInstall
    try { Set-Setting 'InstallCache' $found } catch { }
    return $found
}

function Update-ClaudeInstall {
    param([switch]$AllowCache)
    $script:ClaudeApp          = Resolve-ClaudeInstall -Override $ClaudePath -AllowCache:$AllowCache
    $script:ClaudeExe          = $script:ClaudeApp.Exe
    $script:DefaultProfilePath = $script:ClaudeApp.DefaultProfilePath
}

Update-ClaudeInstall -AllowCache:([bool]$Launch -or [bool]$HandleLink)
if ($ClaudePath) { Set-Setting 'ClaudePath' $script:ClaudeApp.Exe }

# ------------------------------------------------------------------- native --

# Compiling this costs a moment, so it only happens on paths that need it.
function Initialize-Native {
    Add-Type -AssemblyName System.Drawing
    if ('Native.WinApi' -as [type]) { return }
    Add-Type -Name WinApi -Namespace Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")]   public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")]   public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")]   public static extern bool AllowSetForegroundWindow(int dwProcessId);
[DllImport("user32.dll")]   public static extern bool DestroyIcon(IntPtr hIcon);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern uint PrivateExtractIcons(string file, int index, int cx, int cy, IntPtr[] icons, uint[] ids, uint count, uint flags);
[DllImport("user32.dll")]   public static extern IntPtr GetTopWindow(IntPtr hWnd);
[DllImport("user32.dll")]   public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
[DllImport("user32.dll")]   public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll")]   public static extern int GetWindowTextLength(IntPtr hWnd);
[DllImport("user32.dll")]   public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
[DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
public static extern int AssocQueryString(int flags, int str, string assoc, string extra, System.Text.StringBuilder result, ref uint size);
'@
}

# ----------------------------------------------------------------- profiles --

# The junction left at a moved profile's old place (see Move-LegacyProfileFolder).
function Test-Junction {
    param([Parameter(Mandatory)][string]$Path)
    $i = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return [bool]($i -and ($i.Attributes -band [IO.FileAttributes]::ReparsePoint))
}

function Get-ProfilePath {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -eq $script:DefaultName) { return $script:DefaultProfilePath }
    # Directly under %LOCALAPPDATA%: Cowork's VM service is told only the data folder's
    # name and looks for its Linux image in %LOCALAPPDATA%\<name>, so in a nested folder
    # the VM never starts ("VHDX file not found"). A junction there is refused.
    $path   = Join-Path $env:LOCALAPPDATA ($script:ProfileDirPrefix + $Id)
    $legacy = Join-Path $script:ProfileRoot $Id
    # Not moved yet (it was running, see Move-LegacyProfileFolder): keep using the old
    # folder rather than start an empty profile. Also when only an empty leftover sits
    # at the new place, which a half-finished manual move can leave behind.
    if ((Test-Path -LiteralPath $legacy) -and -not (Test-Junction $legacy) -and -not (Test-Path -LiteralPath (Join-Path $path 'config.json'))) { return $legacy }
    return $path
}

# Matches the desktop app's own executable, whichever version of it is running.
function Get-DesktopExePattern {
    $dir = Split-Path $script:ClaudeExe -Parent
    if ($script:ClaudeApp.Kind -eq 'Msix') {
        # ...\WindowsApps\Claude_1.2.3.0_x64__<publisher>\app\Claude.exe. Any version is
        # accepted so an instance still on the previous build after an update is not missed.
        $pkgDir = Split-Path $dir -Parent
        if ((Split-Path $pkgDir -Leaf) -match '^([^_]+)_.*__(.+)$') {
            return '^' + [regex]::Escape((Split-Path $pkgDir -Parent)) + '\\' +
                   [regex]::Escape($Matches[1]) + '_[^\\]*__' + [regex]::Escape($Matches[2]) + '\\'
        }
    }
    if ((Split-Path $dir -Leaf) -like 'app-*') { $dir = Split-Path $dir -Parent }
    return '^' + [regex]::Escape($dir) + '\\'
}

function Get-RunningProfileMap {
    # Maps a profile directory to the PID of the top-level Claude window process.
    # Child processes carry --type=renderer and friends, so they are filtered out. The
    # path check matters just as much: the Claude Code CLI is also called claude.exe,
    # the desktop app runs one per Code session, and WMI matches names case-insensitively.
    $map     = @{}
    $pattern = Get-DesktopExePattern
    $procs = Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' -and
                            $_.ExecutablePath -and $_.ExecutablePath -match $pattern }

    foreach ($p in $procs) {
        # Quoted paths may contain spaces (C:\Users\John Doe\...), unquoted ones cannot.
        if ($p.CommandLine -match '--user-data-dir=(?:"([^"]+)"|(\S+))') {
            $key = $(if ($Matches[1]) { $Matches[1] } else { $Matches[2] }).TrimEnd('\')
        } else {
            $key = $script:DefaultProfilePath.TrimEnd('\')
        }
        if (-not $map.ContainsKey($key)) { $map[$key] = $p.ProcessId }
    }
    return $map
}

# Display names. A profile's folder name is its permanent id: Electron keeps absolute
# paths inside its data, so renaming the folder could break the profile, and existing
# shortcuts refer to profiles by folder name. Renaming only ever changes this label.
function Get-ProfileLabels {
    $map = @{}
    $raw = Get-Setting 'Labels'
    if ($raw) { $raw.PSObject.Properties | ForEach-Object { $map[$_.Name] = [string]$_.Value } }
    return $map
}

function Set-ProfileLabel {
    param([Parameter(Mandatory)][string]$Id, [string]$Label)
    $map = Get-ProfileLabels
    if ([string]::IsNullOrWhiteSpace($Label) -or $Label -ceq $Id) { $map.Remove($Id) } else { $map[$Id] = $Label }
    Set-Setting 'Labels' $map
}

function Get-LastUsed {
    param([Parameter(Mandatory)][string]$Path)
    # A directory's own timestamp only moves when direct children are added or removed,
    # so look at files Electron and Claude rewrite while running.
    $stamps = foreach ($f in 'Preferences', 'Local State', 'config.json', 'window-state.json', 'Network\Cookies') {
        $full = Join-Path $Path $f
        if (Test-Path -LiteralPath $full) { (Get-Item -LiteralPath $full -Force).LastWriteTime }
    }
    # None of those files means Claude has never run against this profile.
    return ($stamps | Sort-Object -Descending | Select-Object -First 1)
}

function Get-ProfileList {
    param([switch]$SkipStatus)
    $running = $(if ($SkipStatus) { @{} } else { Get-RunningProfileMap })
    $labels  = Get-ProfileLabels
    $result  = New-Object System.Collections.Generic.List[object]

    $ids = New-Object System.Collections.Generic.List[string]
    $ids.Add($script:DefaultName)
    $found = @(Get-ChildItem -LiteralPath $env:LOCALAPPDATA -Directory -Filter "$($script:ProfileDirPrefix)*" -ErrorAction SilentlyContinue |
               ForEach-Object { $_.Name.Substring($script:ProfileDirPrefix.Length) })
    # Plus any still in the old place, because they were running when the move was tried.
    if (Test-Path -LiteralPath $script:ProfileRoot) {
        $found += @(Get-ChildItem -LiteralPath $script:ProfileRoot -Directory -ErrorAction SilentlyContinue |
                    Where-Object { -not $_.Name.StartsWith('.') -and -not (Test-Junction $_.FullName) } | ForEach-Object { $_.Name })
    }
    $found | Where-Object { $_ -and $_ -ne $script:DefaultName } | Sort-Object -Unique | ForEach-Object { $ids.Add($_) }

    foreach ($id in $ids) {
        $path = Get-ProfilePath -Id $id
        $result.Add([pscustomobject]@{
            Id        = $id
            Name      = $(if ($labels[$id]) { $labels[$id] } else { $id })
            Path      = $path
            IsDefault = ($id -eq $script:DefaultName)
            Pid       = $running[$path.TrimEnd('\')]
            LastUsed  = $(if ($SkipStatus) { $null } else { Get-LastUsed -Path $path })
        })
    }
    return $result
}

function Resolve-ClaudeProfile {
    param([Parameter(Mandatory)][string]$Name, [switch]$SkipStatus)
    $all = Get-ProfileList -SkipStatus:$SkipStatus
    $hit = $all | Where-Object { $_.Id -eq $Name } | Select-Object -First 1
    if (-not $hit) { $hit = $all | Where-Object { $_.Name -eq $Name } | Select-Object -First 1 }
    return $hit
}

function Test-ProfileName {
    param([string]$Name, [string]$ExceptId)
    if ([string]::IsNullOrWhiteSpace($Name))              { return 'Name cannot be empty.' }
    if ($Name -match '[\\/:*?"<>|\x00-\x1f]')             { return 'Name cannot contain \ / : * ? " < > |' }
    # Windows silently strips a trailing dot or space, so "Work." would quietly become "Work".
    if ($Name -match '^\.|[. ]$')                         { return 'Name cannot start with a dot or end with a dot or space.' }
    if ($Name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { return "'$Name' is a reserved name on Windows." }
    if ($Name.Length -gt 40)                              { return 'Name is too long (40 characters max).' }
    if ($Name -eq 'Add account')                          { return "'Add account' is the name of the switcher's own shortcut." }
    foreach ($p in (Get-ProfileList -SkipStatus)) {
        if ($p.Id -eq $ExceptId) { continue }
        if ($p.Id -eq $Name -or $p.Name -eq $Name)        { return "A profile named '$Name' already exists." }
    }
    if (-not $ExceptId) {
        foreach ($taken in (Join-Path $env:LOCALAPPDATA ($script:ProfileDirPrefix + $Name)), (Join-Path $script:ProfileRoot $Name)) {
            if (Test-Path -LiteralPath $taken) { return "'$Name' is already taken by $taken." }
        }
    }
    return $null
}

function New-ClaudeProfile {
    param([Parameter(Mandatory)][string]$Name)
    $path = Get-ProfilePath -Id $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return (Resolve-ClaudeProfile -Name $Name -SkipStatus)
}

function Get-NextAccountName {
    # New accounts are created before anyone knows which login will go in them, so they
    # start out numbered after Default and can be renamed once signed in.
    for ($n = 2; ; $n++) {
        if (-not (Test-ProfileName -Name "Account $n")) { return "Account $n" }
    }
}

function Add-ClaudeAccount {
    $created = New-ClaudeProfile -Name (Get-NextAccountName)
    # Straight to the sign-in screen: there is nothing else to do with an empty profile.
    Start-ClaudeProfile -Id $created.Id | Out-Null
    return $created
}

function Show-ProfileWindow {
    param([Parameter(Mandatory)][int]$ProcessId)
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc -or $proc.MainWindowHandle -eq [IntPtr]::Zero) { return $false }
    Initialize-Native
    $handle = $proc.MainWindowHandle
    if ([Native.WinApi]::IsIconic($handle)) { [Native.WinApi]::ShowWindow($handle, 9) | Out-Null }   # SW_RESTORE
    [Native.WinApi]::SetForegroundWindow($handle) | Out-Null
    return $true
}

# Runs $Action with the profile's ProfileEnv variables set in this process, so the Claude
# it starts inherits them, then puts the previous values back (or removes them), so a
# later launch of another profile from this process does not get them too.
function Invoke-WithProfileEnv {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][scriptblock]$Action)
    $saved = @{}
    $vars  = (Get-Setting 'ProfileEnv').$Id
    if ($vars) {
        foreach ($p in $vars.PSObject.Properties) {
            if ($p.Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or $saved.ContainsKey($p.Name)) { continue }
            $saved[$p.Name] = [Environment]::GetEnvironmentVariable($p.Name, 'Process')
            [Environment]::SetEnvironmentVariable($p.Name, [string]$p.Value, 'Process')
        }
    }
    try { & $Action }
    finally { foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') } }
}

# Returns 'focused' when the profile was already open, 'started' otherwise.
function Start-ClaudeProfile {
    param([Parameter(Mandatory)][string]$Id)

    $path = Get-ProfilePath -Id $Id
    $open = (Get-RunningProfileMap)[$path.TrimEnd('\')]
    # A window hidden to the tray has no main window handle. Launching again is still
    # right then: Electron's single instance lock hands it to the running copy.
    if ($open -and (Show-ProfileWindow -ProcessId $open)) { return 'focused' }

    # The tray can outlive a Claude update, which removes the versioned exe under us.
    if (-not (Test-Path -LiteralPath $script:ClaudeExe)) { Update-ClaudeInstall }

    if ($Id -eq $script:DefaultName) {
        if ($script:ClaudeApp.Kind -eq 'Msix') {
            # Through the shell app model, so the instance keeps package identity.
            Start-Process 'explorer.exe' -ArgumentList "shell:AppsFolder\$($script:ClaudeApp.AppUserModelId)"
        } else {
            Invoke-WithProfileEnv -Id $Id { Start-Process -FilePath $script:ClaudeExe -WindowStyle Normal }
        }
        return $(if ($open) { 'focused' } else { 'started' })
    }

    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    if (Test-SignInRoutingOn) {
        try { Update-SignInRouting -Id $Id } catch { Write-RouterLog "Could not prepare sign-in routing: $($_.Exception.Message)" }
    }
    # The taskbar takes a custom group's icon from the Start menu shortcut carrying the
    # same identity, and shows Claude's plain icon without one. Made before Claude starts,
    # so it is there when the button is created. Cosmetic, so a failure is ignored.
    $startMenu = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
    $target = Resolve-ClaudeProfile -Name $Id -SkipStatus
    $script:ShortcutJustCreated = $false
    if ($target -and -not (Test-Path -LiteralPath (Join-Path $startMenu "Claude - $($target.Name).lnk"))) {
        try { New-ProfileShortcut -Target $target -Directory $startMenu | Out-Null; $script:ShortcutJustCreated = $true } catch { }
    }
    # -WindowStyle Normal matters: shortcuts run us without a window, and without an
    # explicit show state Claude would inherit ours and start with an invisible window.
    # The process is kept so its window can be given the profile's taskbar identity.
    $script:LaunchedProcess = Invoke-WithProfileEnv -Id $Id { Start-Process -FilePath $script:ClaudeExe -ArgumentList "--user-data-dir=`"$path`"" -WindowStyle Normal -PassThru }
    return $(if ($open) { 'focused' } else { 'started' })
}

# -------------------------------------------------------------------- icons --

# Shortcuts used to point their icon at Claude.exe itself. On the Store build that path
# contains the version, so every update left them blank. These copies never move.

function Get-ProfileColor {
    param([Parameter(Mandatory)][string]$Id)
    $palette = @(
        @(66, 133, 180), @(76, 150, 96), @(150, 96, 180), @(190, 80, 110),
        @(60, 150, 150), @(90, 110, 200), @(200, 150, 50), @(80, 86, 100))
    # Assigned once and remembered: a hash of the name would regularly give two profiles
    # the same colour, and a colour that changes later would defeat the point.
    $assigned = @{}
    $raw = Get-Setting 'Colors'
    if ($raw) { $raw.PSObject.Properties | ForEach-Object { $assigned[$_.Name] = [int]$_.Value } }
    if (-not $assigned.ContainsKey($Id)) {
        $alive = @(Get-ProfileList -SkipStatus | ForEach-Object { $_.Id })
        $use = New-Object int[] $palette.Count
        foreach ($k in @($assigned.Keys)) { if ($alive -contains $k) { $use[$assigned[$k] % $palette.Count]++ } }
        $pick = 0
        for ($i = 1; $i -lt $palette.Count; $i++) { if ($use[$i] -lt $use[$pick]) { $pick = $i } }
        $assigned[$Id] = $pick
        Set-Setting 'Colors' $assigned
    }
    $rgb = $palette[$assigned[$Id] % $palette.Count]
    return [System.Drawing.Color]::FromArgb($rgb[0], $rgb[1], $rgb[2])
}

function Get-BadgeLetter {
    param([string]$Label)
    $c = @($Label.ToCharArray() | Where-Object { [char]::IsLetterOrDigit($_) }) | Select-Object -First 1
    if (-not $c) { $c = $Label.Substring(0, 1) }
    return ([string]$c).ToUpperInvariant()
}

function Get-ClaudeBaseBitmap {
    if ($script:BaseBitmap) { return $script:BaseBitmap }
    Initialize-Native
    $handles = New-Object IntPtr[] 1
    $ids     = New-Object uint32[] 1
    $n = [Native.WinApi]::PrivateExtractIcons($script:ClaudeExe, 0, 256, 256, $handles, $ids, 1, 0)
    if ($n -ge 1 -and $handles[0] -ne [IntPtr]::Zero) {
        $script:BaseBitmap = ([System.Drawing.Icon]::FromHandle($handles[0])).ToBitmap()
        [Native.WinApi]::DestroyIcon($handles[0]) | Out-Null
    } else {
        $script:BaseBitmap = ([System.Drawing.Icon]::ExtractAssociatedIcon($script:ClaudeExe)).ToBitmap()
    }
    return $script:BaseBitmap
}

function New-BadgedBitmap {
    param([Parameter(Mandatory)][int]$Size, [string]$Letter, $Color)
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = 'AntiAlias'
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.DrawImage((Get-ClaudeBaseBitmap), 0, 0, $Size, $Size)
    if ($Letter) {
        $d    = [int][math]::Round($Size * 0.6)
        $ring = [math]::Max(1, [int]($Size / 24))
        $g.FillEllipse([System.Drawing.Brushes]::White, $Size - $d - $ring, $Size - $d - $ring, $d + $ring, $d + $ring)
        $brush = New-Object System.Drawing.SolidBrush($Color)
        $g.FillEllipse($brush, $Size - $d, $Size - $d, $d - $ring, $d - $ring)
        # Below this size a letter is an unreadable smudge. The colour alone still tells them apart.
        if ($Size -ge 24) {
            $font = New-Object System.Drawing.Font('Segoe UI Semibold', [single]($d * 0.52), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
            $fmt  = New-Object System.Drawing.StringFormat
            $fmt.Alignment     = 'Center'
            $fmt.LineAlignment = 'Center'
            $rect = New-Object System.Drawing.RectangleF([single]($Size - $d), [single]($Size - $d), [single]($d - $ring), [single]($d - $ring))
            $g.DrawString($Letter, $font, [System.Drawing.Brushes]::White, $rect, $fmt)
            $font.Dispose()
        }
        $brush.Dispose()
    }
    $g.Dispose()
    return $bmp
}

function Save-IconFile {
    param([Parameter(Mandatory)][System.Drawing.Bitmap[]]$Frames, [Parameter(Mandatory)][string]$Path)
    # PNG-compressed frames, which every Windows version this supports can read.
    $pngs = New-Object System.Collections.Generic.List[byte[]]
    foreach ($f in $Frames) {
        $ms = New-Object System.IO.MemoryStream
        $f.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngs.Add($ms.ToArray())
        $ms.Dispose()
    }
    $fs = [System.IO.File]::Create($Path)
    $w  = New-Object System.IO.BinaryWriter($fs)
    try {
        $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$Frames.Count)
        $offset = 6 + 16 * $Frames.Count
        for ($i = 0; $i -lt $Frames.Count; $i++) {
            $dim = $(if ($Frames[$i].Width -ge 256) { 0 } else { $Frames[$i].Width })
            $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
            $w.Write([uint16]1); $w.Write([uint16]32)
            $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
            $offset += $pngs[$i].Length
        }
        foreach ($png in $pngs) { $w.Write($png) }
    } finally {
        $w.Close()
    }
}

function Get-ProfileIconPath {
    param([Parameter(Mandatory)]$Target, [switch]$Refresh, $Color)
    Initialize-Native
    $letter = $(if ($Target.IsDefault) { '' } else { Get-BadgeLetter -Label $Target.Name })
    # The letter is part of the file name because Explorer caches icons by path, so
    # rewriting the same file after a rename would keep showing the old letter.
    $base = $(if ($letter) { "$($Target.Id)-$letter" } else { $Target.Id })
    $file = Join-Path $script:IconDir "$base.ico"
    if ((Test-Path -LiteralPath $file) -and -not $Refresh) { return $file }

    New-Item -ItemType Directory -Force -Path $script:IconDir | Out-Null
    $stale = '^' + [regex]::Escape($Target.Id) + '(-.)?$'
    Get-ChildItem -LiteralPath $script:IconDir -Filter '*.ico' -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match $stale } | Remove-Item -Force -ErrorAction SilentlyContinue

    $color  = $(if ($Color) { $Color } elseif ($letter) { Get-ProfileColor -Id $Target.Id } else { $null })
    $frames = [System.Drawing.Bitmap[]]@(16, 24, 32, 48, 256 | ForEach-Object { New-BadgedBitmap -Size $_ -Letter $letter -Color $color })
    Save-IconFile -Frames $frames -Path $file
    $frames | ForEach-Object { $_.Dispose() }
    return $file
}

# --------------------------------------------------------- taskbar identity --

<#
    Windows groups taskbar buttons by an AppUserModelID, and every Claude window carries the
    same one, so all accounts pile onto one button with one icon. Each extra profile's
    window is given an identity of its own, together with its badged icon, so it gets its
    own button. Default is never touched: it keeps Claude's identity, so a pinned Claude
    icon still matches it.

    The identity is read when the taskbar button is created, so it is best set in the
    moment between Electron creating the window and showing it. A window that is already
    showing has its button rebuilt instead.

    Windows reads a group's icon once per identity and never again. The badge letter is
    therefore part of the identity: a rename that changes the letter moves the window to a
    new identity, which brings the new icon with it. A profile's colour never changes.

    Original idea and window identity code by Sukarth (Sukarth/Claude-Code-Desktop-Switcher).
#>

$script:TaskbarIdentitySource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace ClaudeSwitcher
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PropertyKey
    {
        public Guid FormatId; public uint PropertyId;
        public PropertyKey(Guid formatId, uint propertyId) { FormatId = formatId; PropertyId = propertyId; }
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore
    {
        int GetCount(out uint count);
        int GetAt(uint index, out PropertyKey key);
        int GetValue(ref PropertyKey key, IntPtr value);
        int SetValue(ref PropertyKey key, IntPtr value);
        int Commit();
    }

    [ComImport, Guid("0000010b-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPersistFile
    {
        int GetClassID(out Guid classId);
        int IsDirty();
        int Load([MarshalAs(UnmanagedType.LPWStr)] string fileName, uint mode);
        int Save([MarshalAs(UnmanagedType.LPWStr)] string fileName, bool remember);
        int SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string fileName);
        int GetCurFile(out IntPtr fileName);
    }

    [ComImport, Guid("56FDF342-FD6D-11d0-958A-006097C9A090"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ITaskbarList
    {
        int HrInit(); int AddTab(IntPtr hwnd); int DeleteTab(IntPtr hwnd);
        int ActivateTab(IntPtr hwnd); int SetActiveAlt(IntPtr hwnd);
    }

    [ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090")] public class TaskbarListClass { }
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")] public class ShellLinkClass { }

    public static class TaskbarIdentity
    {
        static readonly Guid AppUserModel = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
        const uint PidRelaunchCommand = 2, PidRelaunchIcon = 3, PidRelaunchName = 4, PidId = 5;
        const short VT_LPWSTR = 31;
        const uint WM_SETICON = 0x0080, WM_GETICON = 0x007F, GW_OWNER = 4;
        const int GWL_EXSTYLE = -20;
        const long WS_EX_TOOLWINDOW = 0x80L;

        delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int size);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")] static extern IntPtr GetWindowLongPtr64(IntPtr hwnd, int index);
        [DllImport("user32.dll", EntryPoint = "GetWindowLong")] static extern int GetWindowLong32(IntPtr hwnd, int index);
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
        [DllImport("shell32.dll", PreserveSig = false)]
        static extern void SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
        [DllImport("ole32.dll")] static extern int PropVariantClear(IntPtr value);

        static long ExStyle(IntPtr hwnd)
        {
            return IntPtr.Size == 8 ? GetWindowLongPtr64(hwnd, GWL_EXSTYLE).ToInt64() : (long)GetWindowLong32(hwnd, GWL_EXSTYLE);
        }

        static string ClassOf(IntPtr hwnd)
        {
            var name = new StringBuilder(64); GetClassName(hwnd, name, name.Capacity); return name.ToString();
        }

        /// Top-level Electron windows of a process that can have a taskbar button. Hidden
        /// ones are included on request: that is the moment to set an identity.
        public static IntPtr[] WindowsForPid(uint pid, bool includeHidden)
        {
            var found = new List<IntPtr>();
            EnumWindows(delegate(IntPtr hwnd, IntPtr lParam)
            {
                uint owner; GetWindowThreadProcessId(hwnd, out owner);
                if (owner != pid) return true;
                if (!includeHidden && !IsWindowVisible(hwnd)) return true;
                if (GetWindow(hwnd, GW_OWNER) != IntPtr.Zero) return true;
                if ((ExStyle(hwnd) & WS_EX_TOOLWINDOW) != 0) return true;
                if (ClassOf(hwnd) != "Chrome_WidgetWin_1") return true;
                found.Add(hwnd);
                return true;
            }, IntPtr.Zero);
            return found.ToArray();
        }

        public static bool IsVisible(IntPtr hwnd) { return IsWindowVisible(hwnd); }

        // A PROPVARIANT built by hand, because InitPropVariantFromString is an inline SDK
        // helper rather than an export: vt at offset 0, the string pointer at offset 8.
        static void SetString(IPropertyStore store, uint propertyId, string value)
        {
            var key = new PropertyKey(AppUserModel, propertyId);
            IntPtr pv = Marshal.AllocCoTaskMem(32);
            for (int i = 0; i < 32; i++) Marshal.WriteByte(pv, i, 0);
            try
            {
                Marshal.WriteInt16(pv, 0, VT_LPWSTR);
                Marshal.WriteIntPtr(pv, 8, Marshal.StringToCoTaskMemUni(value));   // freed by PropVariantClear
                Marshal.ThrowExceptionForHR(store.SetValue(ref key, pv));
            }
            finally { PropVariantClear(pv); Marshal.FreeCoTaskMem(pv); }
        }

        static string GetString(IPropertyStore store, uint propertyId)
        {
            var key = new PropertyKey(AppUserModel, propertyId);
            IntPtr pv = Marshal.AllocCoTaskMem(32);
            for (int i = 0; i < 32; i++) Marshal.WriteByte(pv, i, 0);
            try
            {
                if (store.GetValue(ref key, pv) != 0) return null;
                if (Marshal.ReadInt16(pv, 0) != VT_LPWSTR) return null;
                return Marshal.PtrToStringUni(Marshal.ReadIntPtr(pv, 8));
            }
            finally { PropVariantClear(pv); Marshal.FreeCoTaskMem(pv); }
        }

        public static void SetWindowIdentity(IntPtr hwnd, string id, string relaunchCommand, string displayName, string iconResource)
        {
            Guid iid = typeof(IPropertyStore).GUID; IPropertyStore store;
            SHGetPropertyStoreForWindow(hwnd, ref iid, out store);
            try
            {
                SetString(store, PidId, id);
                SetString(store, PidRelaunchCommand, relaunchCommand);
                SetString(store, PidRelaunchName, displayName);
                SetString(store, PidRelaunchIcon, iconResource);
                Marshal.ThrowExceptionForHR(store.Commit());
            }
            finally { Marshal.ReleaseComObject(store); }
        }

        public static string GetWindowIdentity(IntPtr hwnd)
        {
            Guid iid = typeof(IPropertyStore).GUID; IPropertyStore store;
            SHGetPropertyStoreForWindow(hwnd, ref iid, out store);
            try { return GetString(store, PidId); }
            finally { Marshal.ReleaseComObject(store); }
        }

        /// The identity of a .lnk, so a pinned copy of it shares a button with its window.
        public static void SetShortcutIdentity(string path, string id)
        {
            object link = new ShellLinkClass();
            try
            {
                var file = (IPersistFile)link;
                Marshal.ThrowExceptionForHR(file.Load(path, 0x00000002));   // STGM_READWRITE
                var store = (IPropertyStore)link;
                SetString(store, PidId, id);
                Marshal.ThrowExceptionForHR(store.Commit());
                Marshal.ThrowExceptionForHR(file.Save(path, true));
            }
            finally { Marshal.ReleaseComObject(link); }
        }

        public static string GetShortcutIdentity(string path)
        {
            object link = new ShellLinkClass();
            try
            {
                Marshal.ThrowExceptionForHR(((IPersistFile)link).Load(path, 0));   // STGM_READ
                return GetString((IPropertyStore)link, PidId);
            }
            finally { Marshal.ReleaseComObject(link); }
        }

        /// Only for a visible window: AddTab on a hidden one would leave a phantom button.
        public static void RebuildTaskbarButton(IntPtr hwnd)
        {
            var taskbar = (ITaskbarList)new TaskbarListClass();
            try { taskbar.HrInit(); taskbar.DeleteTab(hwnd); taskbar.AddTab(hwnd); }
            finally { Marshal.ReleaseComObject(taskbar); }
        }

        public static IntPtr GetIcon(IntPtr hwnd) { return SendMessage(hwnd, WM_GETICON, (IntPtr)1, IntPtr.Zero); }

        public static void SetIcon(IntPtr hwnd, IntPtr icon)
        {
            SendMessage(hwnd, WM_SETICON, (IntPtr)0, icon);
            SendMessage(hwnd, WM_SETICON, (IntPtr)1, icon);
        }
    }
}
'@

# Compiled in memory, only on the paths that tag a window or a shortcut.
function Initialize-TaskbarIdentity {
    if ('ClaudeSwitcher.TaskbarIdentity' -as [type]) { return }
    Add-Type -TypeDefinition $script:TaskbarIdentitySource
}

function Get-ProfileAumid {
    # Unique per profile (the readable part loses spaces and symbols, the hash does not) and
    # per badge letter. Letters only, digits and dots, well under the 128 character limit.
    param([Parameter(Mandatory)]$Target)
    $readable = ($Target.Id -replace '[^A-Za-z0-9]', '')
    if ($readable.Length -gt 32) { $readable = $readable.Substring(0, 32) }
    $sha  = [System.Security.Cryptography.SHA256]::Create()
    $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Target.Id))).Replace('-', '').Substring(0, 10)
    $sha.Dispose()
    $letter = [int][char](Get-BadgeLetter -Label $Target.Name)
    return 'ClaudeProfileSwitcher.Profile{0}.h{1}.b{2:x4}' -f $readable, $hash, $letter
}

function Get-ProfileRelaunchCommand {
    # What a pinned taskbar button runs: the same launcher as the profile's shortcuts.
    param([Parameter(Mandatory)]$Target)
    $ps      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $cmd     = "-NoProfile -ExecutionPolicy Bypass -File `"$(Get-LauncherScript)`" -Launch `"$($Target.Id)`""
    if ([Environment]::OSVersion.Version.Build -ge 17763 -and (Test-Path -LiteralPath $conhost)) {
        return "`"$conhost`" --headless `"$ps`" $cmd"
    }
    return "`"$ps`" -WindowStyle Hidden $cmd"
}

# Icon handles live as long as this process: a window draws with the handle it was given,
# so it must not be freed while any window may still use it. One per profile and letter.
$script:IdentityIcons = @{}

function Get-ProfileIconHandle {
    param([Parameter(Mandatory)]$Target)
    # Loads System.Drawing, which Get-ProfileColor needs: -Launch reaches here before
    # anything else in that process has loaded it.
    Initialize-Native
    $letter = Get-BadgeLetter -Label $Target.Name
    $key = "$($Target.Id)|$letter"
    if (-not $script:IdentityIcons.ContainsKey($key)) {
        # 256 px: Windows 11 applies a smaller WM_SETICON icon to the window frame only
        # and leaves the taskbar button as it was.
        $bmp = New-BadgedBitmap -Size 256 -Letter $letter -Color (Get-ProfileColor -Id $Target.Id)
        $script:IdentityIcons[$key] = $bmp.GetHicon()
        $bmp.Dispose()
    }
    return $script:IdentityIcons[$key]
}

# Tags every window of one profile's process that lacks the profile's identity or icon.
# Returns whether a visible window carries the identity now.
function Update-ProfileWindowIdentity {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)][int]$ProcessId)
    if ($Target.IsDefault) { return $true }
    Initialize-TaskbarIdentity
    $want  = Get-ProfileAumid -Target $Target
    $icon  = Get-ProfileIconHandle -Target $Target
    $shown = $false
    foreach ($hwnd in [ClaudeSwitcher.TaskbarIdentity]::WindowsForPid([uint32]$ProcessId, $true)) {
        try {
            if ([ClaudeSwitcher.TaskbarIdentity]::GetWindowIdentity($hwnd) -ne $want) {
                [ClaudeSwitcher.TaskbarIdentity]::SetWindowIdentity($hwnd, $want, (Get-ProfileRelaunchCommand -Target $Target),
                    "Claude - $($Target.Name)", "$(Get-ProfileIconPath -Target $Target),0")
                [ClaudeSwitcher.TaskbarIdentity]::SetIcon($hwnd, $icon)
                if ([ClaudeSwitcher.TaskbarIdentity]::IsVisible($hwnd)) { [ClaudeSwitcher.TaskbarIdentity]::RebuildTaskbarButton($hwnd) }
            } elseif ([ClaudeSwitcher.TaskbarIdentity]::GetIcon($hwnd) -ne $icon) {
                # Tagged by a shortcut's -Launch, which has exited since, and its icon handle
                # with it. This process outlives that one, so it supplies the icon from now on.
                [ClaudeSwitcher.TaskbarIdentity]::SetIcon($hwnd, $icon)
            }
            if ([ClaudeSwitcher.TaskbarIdentity]::IsVisible($hwnd)) { $shown = $true }
        } catch { }
    }
    return $shown
}

function Update-RunningProfileIdentity {
    foreach ($p in @(Get-ProfileList | Where-Object { $_.Pid -and -not $_.IsDefault })) {
        try { Update-ProfileWindowIdentity -Target $p -ProcessId $p.Pid | Out-Null } catch { }
    }
}

# Watches one launch for the window Claude is about to show. Polled every 150 ms by the
# caller, so the window is usually tagged before its taskbar button exists.
function New-IdentityWatch {
    param([Parameter(Mandatory)]$Target, $Process, [int]$Seconds = 25)
    return [pscustomobject]@{
        Target     = $Target
        Process    = $Process
        ProcessId  = $(if ($Process) { $Process.Id } else { 0 })
        Until      = (Get-Date).AddSeconds($Seconds)
        NextLookup = [datetime]::MinValue
        # Set when this launch created the Start menu shortcut: see Step-IdentityWatch.
        Rebuild    = [bool]$script:ShortcutJustCreated
        RebuildAt  = $null
    }
}

# One poll. Returns $true when the watch is over: the window is tagged and showing, or
# time ran out.
function Step-IdentityWatch {
    param([Parameter(Mandatory)]$Watch)
    if ((Get-Date) -gt $Watch.Until) { return $true }
    if ($Watch.Process -and $Watch.Process.HasExited) { $Watch.Process = $null; $Watch.ProcessId = 0 }
    if (-not $Watch.ProcessId) {
        # Handed to a copy that was already running, or started through a stub. Found by
        # its profile folder instead, at most once a second since that asks WMI.
        if ((Get-Date) -lt $Watch.NextLookup) { return $false }
        $Watch.NextLookup = (Get-Date).AddSeconds(1)
        $Watch.ProcessId  = [int]((Get-RunningProfileMap)[$Watch.Target.Path.TrimEnd('\')])
        if (-not $Watch.ProcessId) { return $false }
    }
    $shown = Update-ProfileWindowIdentity -Target $Watch.Target -ProcessId $Watch.ProcessId
    if (-not $shown -or -not $Watch.Rebuild) { return $shown }
    # Windows indexes a new Start menu shortcut a few seconds after it is written, and a
    # button created before that shows Claude's plain icon. Rebuilt once, a little later,
    # it picks up the shortcut's badge.
    if (-not $Watch.RebuildAt) { $Watch.RebuildAt = (Get-Date).AddSeconds(5); return $false }
    if ((Get-Date) -lt $Watch.RebuildAt) { return $false }
    foreach ($hwnd in [ClaudeSwitcher.TaskbarIdentity]::WindowsForPid([uint32]$Watch.ProcessId, $false)) {
        try { [ClaudeSwitcher.TaskbarIdentity]::RebuildTaskbarButton($hwnd) } catch { }
    }
    return $true
}

# ---------------------------------------------------------------- shortcuts --

function Get-ShortcutDirs {
    return @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'))
}

function Get-LauncherScript {
    # Shortcuts point at the installed copy when there is one, so moving or deleting
    # the folder the switcher was downloaded to cannot break them.
    if (Test-Path -LiteralPath $script:InstalledScript) { return $script:InstalledScript }
    return $script:ScriptPath
}

function Set-LauncherTarget {
    param([Parameter(Mandatory)]$Link, [string]$ScriptArgs, [switch]$Window)
    $ps      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $cmd     = ("-NoProfile -ExecutionPolicy Bypass -File `"$(Get-LauncherScript)`" $ScriptArgs").TrimEnd()
    if ([Environment]::OSVersion.Version.Build -ge 17763 -and (Test-Path -LiteralPath $conhost)) {
        # A headless console host gives PowerShell a console that never becomes a window,
        # so nothing flashes on screen. Unlike -WindowStyle Hidden it also puts no hidden
        # show state into STARTUPINFO for the windows we open afterwards to inherit.
        $Link.TargetPath = $conhost
        $Link.Arguments  = "--headless `"$ps`" $cmd"
    } elseif ($Window) {
        $Link.TargetPath  = $ps
        $Link.Arguments   = $cmd
        $Link.WindowStyle = 7   # minimised, so the console never flashes into view
    } else {
        $Link.TargetPath = $ps
        $Link.Arguments  = "-WindowStyle Hidden $cmd"
    }
}

function New-ProfileShortcut {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$Directory
    )
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $shell = New-Object -ComObject WScript.Shell
    $link  = $shell.CreateShortcut((Join-Path $Directory "Claude - $($Target.Name).lnk"))

    if ($Target.IsDefault -and $script:ClaudeApp.Kind -eq 'Msix') {
        $link.TargetPath = 'explorer.exe'
        $link.Arguments  = "shell:AppsFolder\$($script:ClaudeApp.AppUserModelId)"
    } else {
        # Re-runs this script so the executable path is resolved at click time, which
        # keeps the shortcut working across Claude updates, and so a click on a profile
        # that is already open brings its window forward.
        Set-LauncherTarget -Link $link -ScriptArgs "-Launch `"$($Target.Id)`""
    }

    $link.IconLocation     = "$(Get-ProfileIconPath -Target $Target),0"
    $link.Description      = "Open Claude with the '$($Target.Name)' account"
    $link.WorkingDirectory = $script:SwitcherHome
    New-Item -ItemType Directory -Force -Path $script:SwitcherHome | Out-Null
    $link.Save()
    if (-not $Target.IsDefault) {
        # The window's identity, so a pinned copy of this shortcut shares its button
        # instead of sitting beside it. Cosmetic, so a failure leaves a plain shortcut.
        try {
            Initialize-TaskbarIdentity
            [ClaudeSwitcher.TaskbarIdentity]::SetShortcutIdentity($link.FullName, (Get-ProfileAumid -Target $Target))
        } catch { }
    }
    return $link.FullName
}

function Remove-ProfileShortcuts {
    param([Parameter(Mandatory)][string]$Label)
    foreach ($dir in Get-ShortcutDirs) {
        $lnk = Join-Path $dir "Claude - $Label.lnk"
        if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force; $lnk }
    }
}

function New-SwitcherShortcut {
    param([Parameter(Mandatory)][string]$Directory, [string]$FileName = 'Claude Profile Switcher.lnk', [switch]$StartInTray)
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
    $shell = New-Object -ComObject WScript.Shell
    $link  = $shell.CreateShortcut((Join-Path $Directory $FileName))
    Set-LauncherTarget -Link $link -ScriptArgs $(if ($StartInTray) { '-Tray' } else { '' }) -Window
    $link.IconLocation     = "$(Get-ProfileIconPath -Target (Resolve-ClaudeProfile -Name $script:DefaultName -SkipStatus)),0"
    $link.Description      = 'Switch between Claude desktop accounts'
    New-Item -ItemType Directory -Force -Path $script:SwitcherHome | Out-Null
    $link.WorkingDirectory = $script:SwitcherHome
    $link.Save()
    return $link.FullName
}

function New-AddAccountShortcut {
    param([Parameter(Mandatory)][string]$Directory)
    Initialize-Native
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $shell = New-Object -ComObject WScript.Shell
    $link  = $shell.CreateShortcut((Join-Path $Directory 'Claude - Add account.lnk'))
    Set-LauncherTarget -Link $link -ScriptArgs '-AddAccount'
    $plus = [pscustomobject]@{ Id = 'add-account'; Name = '+'; IsDefault = $false }
    $link.IconLocation     = "$(Get-ProfileIconPath -Target $plus -Color ([System.Drawing.Color]::FromArgb(46, 125, 74))),0"
    $link.Description      = 'Sign in to another Claude account in its own window'
    New-Item -ItemType Directory -Force -Path $script:SwitcherHome | Out-Null
    $link.WorkingDirectory = $script:SwitcherHome
    $link.Save()
    return $link.FullName
}

function Start-SwitcherWindow {
    $ps      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $cmd     = "-NoProfile -ExecutionPolicy Bypass -File `"$(Get-LauncherScript)`""
    if ([Environment]::OSVersion.Version.Build -ge 17763 -and (Test-Path -LiteralPath $conhost)) {
        Start-Process -FilePath $conhost -ArgumentList "--headless `"$ps`" $cmd"
    } else {
        Start-Process -FilePath $ps -ArgumentList $cmd -WindowStyle Minimized
    }
}

function Get-StartupShortcutPath {
    return (Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Profile Switcher.lnk')
}

function Rename-ClaudeProfile {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)][string]$NewName)
    $err = Test-ProfileName -Name $NewName -ExceptId $Target.Id
    if ($err) { throw $err }
    $removed = @(Remove-ProfileShortcuts -Label $Target.Name)
    Set-ProfileLabel -Id $Target.Id -Label $NewName
    $renamed = Resolve-ClaudeProfile -Name $Target.Id -SkipStatus
    # Shortcuts are named after the label, so put back any we just took away.
    foreach ($lnk in $removed) { New-ProfileShortcut -Target $renamed -Directory (Split-Path $lnk -Parent) | Out-Null }
    return $renamed
}

function Remove-ClaudeProfile {
    param([Parameter(Mandatory)]$Target)
    if ($Target.IsDefault) { throw 'The Default profile cannot be deleted.' }
    $path = Get-ProfilePath -Id $Target.Id
    # Never recurse into anything but a profile folder of ours: ClaudeProfile-<id> directly
    # under %LOCALAPPDATA%, or <id> in the old place.
    $leaf = Split-Path $path -Leaf; $parent = Split-Path $path -Parent
    $ours = ($parent -eq $env:LOCALAPPDATA.TrimEnd('\') -and $leaf -eq ($script:ProfileDirPrefix + $Target.Id)) -or
            ($parent -eq $script:ProfileRoot -and $leaf -eq $Target.Id)
    if ($Target.Id -match '^\.|[\\/]' -or -not $ours) {
        throw "Refusing to delete '$path'."
    }
    if ((Get-RunningProfileMap)[$path.TrimEnd('\')]) {
        throw "Close the '$($Target.Name)' window before deleting it."
    }
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    # Takes the junction at the old place with it (Directory.Delete leaves its target alone).
    $link = Join-Path $script:ProfileRoot $Target.Id
    if (Test-Junction $link) { [IO.Directory]::Delete($link, $false) }
    Remove-ProfileShortcuts -Label $Target.Name | Out-Null
    $stale = '^' + [regex]::Escape($Target.Id) + '(-.)?$'
    Get-ChildItem -LiteralPath $script:IconDir -Filter '*.ico' -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match $stale } | Remove-Item -Force -ErrorAction SilentlyContinue
    Set-ProfileLabel -Id $Target.Id -Label $null
}

function Install-Switcher {
    New-Item -ItemType Directory -Force -Path $script:SwitcherHome | Out-Null
    if ($script:ScriptPath -ne $script:InstalledScript) {
        Copy-Item -LiteralPath $script:ScriptPath -Destination $script:InstalledScript -Force
        try { Unblock-File -LiteralPath $script:InstalledScript } catch { }
    }
    New-SwitcherShortcut -Directory ([Environment]::GetFolderPath('Desktop'))
    New-SwitcherShortcut -Directory (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs')
    # Lets people add an account from Start search without opening the switcher first.
    New-AddAccountShortcut -Directory (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs')
    if (Test-Path -LiteralPath (Get-StartupShortcutPath)) {
        New-SwitcherShortcut -Directory ([Environment]::GetFolderPath('Startup')) -StartInTray | Out-Null
    }
    # Shortcuts made earlier may still point at wherever the script was downloaded to.
    foreach ($p in (Get-ProfileList -SkipStatus)) {
        foreach ($dir in Get-ShortcutDirs) {
            if (Test-Path -LiteralPath (Join-Path $dir "Claude - $($p.Name).lnk")) {
                New-ProfileShortcut -Target $p -Directory $dir
            }
        }
    }
}

# ------------------------------------------------------- Claude Code chats --

<#
    The desktop app keeps one small JSON file per Claude Code chat, at
        <profile>\claude-code-sessions\<account id>\<organisation id>\local_<id>.json
    The chat transcript itself is kept by the Claude Code CLI, outside the profile.
    Copying a chat to another account means placing that file into the other profile's
    store, under the account and organisation that profile is signed in to.
#>

function Get-FirstValue {
    param($Object, [string[]]$Names)
    if (-not $Object) { return $null }
    foreach ($n in $Names) {
        $prop = $Object.PSObject.Properties[$n]
        if ($prop -and $prop.Value -is [string] -and $prop.Value.Trim()) { return $prop.Value.Trim() }
    }
    return $null
}

function Get-CodeSessionRoot {
    param([Parameter(Mandatory)]$TargetProfile)
    $root = Join-Path $TargetProfile.Path 'claude-code-sessions'
    # Store apps redirect LocalAppData writes into their package's LocalCache.
    # Keep the launch path unchanged; only resolve where the session files live.
    $localPrefix = $env:LOCALAPPDATA.TrimEnd('\') + '\'
    if ($script:ClaudeApp.Kind -eq 'Msix' -and
        $TargetProfile.Path.StartsWith($localPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        $cache = Split-Path (Split-Path $script:ClaudeApp.DefaultProfilePath -Parent) -Parent
        $relative = $TargetProfile.Path.Substring($localPrefix.Length)
        $redirected = Join-Path (Join-Path (Join-Path $cache 'Local') $relative) 'claude-code-sessions'
        if (Test-Path -LiteralPath $redirected -PathType Container) { return $redirected }
    }
    return $root
}

function Get-CodeSessions {
    param([Parameter(Mandatory)]$Source)
    $root = Get-CodeSessionRoot -TargetProfile $Source
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $found = @{}
    Get-ChildItem -LiteralPath $root -Directory | ForEach-Object {
        $account = $_
        Get-ChildItem -LiteralPath $account.FullName -Directory | ForEach-Object {
            $org = $_
            Get-ChildItem -LiteralPath $org.FullName -File -Filter 'local_*.json' | ForEach-Object {
                $data = $null
                try { $data = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
                $folder = Get-FirstValue $data 'cwd', 'workingDirectory', 'projectPath', 'folder', 'path'
                $entry = [pscustomobject]@{
                    File    = $_
                    Account = $account.Name
                    Org     = $org.Name
                    Title   = $(Get-FirstValue $data 'title', 'name', 'summary', 'customTitle', 'displayName')
                    Folder  = $(if (-not $folder) { '' } elseif ($folder -match '\\scratch-workspaces\\') { '(no folder)' } else { Split-Path $folder -Leaf })
                    Updated = $_.LastWriteTime
                }
                if (-not $entry.Title) { $entry.Title = "Chat $($_.BaseName.Substring(6, [math]::Min(8, $_.BaseName.Length - 6)))" }
                # The same chat can sit under two accounts after an earlier copy. List it once.
                if (-not $found.ContainsKey($_.Name) -or $found[$_.Name].Updated -lt $entry.Updated) { $found[$_.Name] = $entry }
            }
        }
    }
    return @($found.Values | Sort-Object Updated -Descending)
}

function Get-CodeSessionStore {
    param([Parameter(Mandatory)]$Target)
    $root = Get-CodeSessionRoot -TargetProfile $Target
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    # A profile that has been signed in to more than one account keeps a folder for each;
    # the one written to most recently belongs to whoever is signed in now.
    return Get-ChildItem -LiteralPath $root -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory } |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# Returns 'copied' or 'exists'.
function Copy-CodeSession {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Store)
    $dest = Join-Path $Store.FullName $Session.File.Name
    if (Test-Path -LiteralPath $dest) { return 'exists' }
    $targetAccount = Split-Path $Store.Parent.FullName -Leaf
    $targetOrg     = $Store.Name
    $text = [System.IO.File]::ReadAllText($Session.File.FullName)
    # If the file records which account and organisation it belongs to, swap in the
    # target's. Only whole JSON string values are replaced, so paths that merely contain
    # the same ids (scratch folders are named after them) are left alone.
    $text = $text.Replace("`"$($Session.Account)`"", "`"$targetAccount`"").Replace("`"$($Session.Org)`"", "`"$targetOrg`"")
    [System.IO.File]::WriteAllText($dest, $text, (New-Object System.Text.UTF8Encoding($false)))
    return 'copied'
}

# ------------------------------------------------------------------- layout --

function Move-LegacyProfileFolder {
    # Profiles used to live in %LOCALAPPDATA%\ClaudeProfiles\<id>, where Cowork's VM never
    # starts (see Get-ProfilePath). Each moves to its new place once. Same volume, so the
    # move is a rename: it happens whole or not at all. A running profile holds its files
    # open, so it stays put (Get-ProfilePath keeps finding it) and moves on a later start.
    # An existing target is never overwritten, unless it holds no files at all.
    if (-not (Test-Path -LiteralPath $script:ProfileRoot)) { return }
    $old = @(Get-ChildItem -LiteralPath $script:ProfileRoot -Directory -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.StartsWith('.') -and -not (Test-Junction $_.FullName) })
    if (-not $old) { return }
    $running = Get-RunningProfileMap
    foreach ($d in $old) {
        if ($running.ContainsKey($d.FullName.TrimEnd('\'))) { continue }
        $target = Join-Path $env:LOCALAPPDATA ($script:ProfileDirPrefix + $d.Name)
        # Not moving is safe (Get-ProfilePath keeps using the old folder) but worth a line in
        # the log: otherwise nobody learns why Cowork still fails in that profile.
        $why = $null
        if (Test-Path -LiteralPath $target) {
            if (@(Get-ChildItem -LiteralPath $target -Recurse -File -Force -ErrorAction SilentlyContinue).Count) {
                $why = 'the new folder already holds files'
            } else {
                try { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop } catch { $why = "the empty new folder is in use: $($_.Exception.Message)" }
            }
        }
        if (-not $why) { try { Move-Item -LiteralPath $d.FullName -Destination $target -ErrorAction Stop } catch { $why = $_.Exception.Message } }
        if ($why) {
            try { Add-Content -LiteralPath $script:LogPath -Value ("[{0}] Left profile '{1}' in {2}, not moved to {3}: {4}" -f (Get-Date -Format 's'), $d.Name, $d.FullName, $target, $why) } catch { }
            continue
        }
        # Claude writes absolute paths into a profile, the working folder of a Code chat
        # started without a project among them. A junction at the old place keeps them
        # resolving. Cowork's VM service only looks at the new name, so it never sees it.
        try { New-Item -ItemType Junction -Path $d.FullName -Target $target -ErrorAction Stop | Out-Null }
        catch { try { Add-Content -LiteralPath $script:LogPath -Value ("[{0}] Moved profile '{1}' but could not leave a junction at {2}: {3}" -f (Get-Date -Format 's'), $d.Name, $d.FullName, $_.Exception.Message) } catch { } }
        # The Store build can keep part of a profile's files in the package's LocalCache,
        # under the same relative path (see Get-CodeSessionRoot). That part moves along.
        # Left behind, those files (Code sessions among them) no longer show in the profile.
        if ($script:ClaudeApp.Kind -eq 'Msix') {
            $cache = Join-Path (Split-Path (Split-Path $script:ClaudeApp.DefaultProfilePath -Parent) -Parent) 'Local'
            $from  = Join-Path $cache "ClaudeProfiles\$($d.Name)"
            $to    = Join-Path $cache ($script:ProfileDirPrefix + $d.Name)
            if (Test-Path -LiteralPath $from) {
                $why = if (Test-Path -LiteralPath $to) { 'that folder already exists' } else { $null }
                if (-not $why) { try { Move-Item -LiteralPath $from -Destination $to -ErrorAction Stop } catch { $why = $_.Exception.Message } }
                if ($why) {
                    try { Add-Content -LiteralPath $script:LogPath -Value ("[{0}] Left part of profile '{1}' in {2}, not moved to {3}: {4}" -f (Get-Date -Format 's'), $d.Name, $from, $to, $why) } catch { }
                }
            }
        }
    }
}

# Cheap when there is nothing to move: one directory listing. Not from the sign-in handler:
# Windows runs that for every claude:// link and it has to forward the link at once.
# -Status only reports, so it must not change anything either.
if (-not $PSBoundParameters.ContainsKey('HandleLink') -and -not $Status) {
    try { Move-LegacyProfileFolder } catch { }
}

# --------------------------------------------------------- sign-in routing --

<#
    Signing in from a browser ends with a claude:// link, and Windows has one handler per
    user for those, so without help every sign-in lands in Default. When the user turns
    routing on, this script becomes that handler (-HandleLink) and forwards each sign-in
    link to, in order:

      1. the profile launched while signed out, which is expecting the sign-in
      2. the one open profile that is signed out
      3. the open profile whose window was most recently in front
      4. Default, exactly as before

    Every other claude:// link goes to Default untouched.

    Two builds, two ways to become the handler:

      Installer  - HKCU\Software\Classes\claude. Claude rewrites that key every time it
                   starts, so the switcher takes it back whenever it notices.
      Store      - the package manifest declares claude://, and Windows prefers it over
                   that key. Only the user's choice in Settings > Default apps beats it,
                   and Windows protects that choice with a hash nothing else can write.
                   So the router is registered as an app the user can pick there, once.

    Original idea and router by Sukarth (Sukarth/Claude-Code-Desktop-Switcher).
#>

$script:LinkScheme        = 'claude'
$script:RouterProgId      = 'ClaudeProfileRouter.claude'
$script:RouterAppName     = 'ClaudeProfileRouter'
$script:RouterDisplayName = 'Claude Profile Router'
$script:RouterRegistry    = [pscustomobject]@{
    Classes    = 'HKCU:\Software\Classes'
    Capability = 'HKCU:\Software\ClaudeProfileSwitcher\Capabilities'
    AppList    = 'HKCU:\Software\RegisteredApplications'
}
$script:PendingSignInPath = Join-Path $script:SwitcherHome 'pending-sign-in.json'
$script:HandlerBackupPath = Join-Path $script:SwitcherHome 'claude-handler-backup.json'
# $script:RouterLogPath is set near the top, where a link arriving with other parameters is refused.

function Test-SignInRoutingOn { return ((Get-Setting 'SignInRouting') -eq $true) }

function Write-RouterLog {
    param([string]$Message)
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $script:RouterLogPath -Parent) | Out-Null
        # One line per sign-in, so this only grows large over years. Start over past 100 KB.
        if ((Test-Path -LiteralPath $script:RouterLogPath) -and (Get-Item -LiteralPath $script:RouterLogPath).Length -gt 100KB) {
            Remove-Item -LiteralPath $script:RouterLogPath -Force
        }
        Add-Content -LiteralPath $script:RouterLogPath -Value ('[{0}] {1}' -f (Get-Date -Format 's'), $Message)
    } catch { }
}

function Test-SafeLink {
    # The link arrives from the browser through the shell, so it is untrusted, and it ends
    # up inside a command line for Claude.exe. Windows PowerShell 5.1 cannot pass an
    # argument vector (ProcessStartInfo.ArgumentList is .NET Core only) and its own
    # -ArgumentList array is joined without reliable quoting, so the link is validated
    # instead: claude:// followed only by characters RFC 3986 permits in a URI. That
    # excludes the quote, backslash, space and control characters an injection needs.
    # Anchored with \z, not $: in .NET $ also matches before a trailing newline.
    param([string]$Link)
    if ([string]::IsNullOrEmpty($Link) -or $Link.Length -gt 2048) { return $false }
    return ($Link -cmatch "^claude://[A-Za-z0-9._~:/?#\[\]@!\$&'()*+,;=%-]*\z")
}

function Test-SignInLink {
    # Two shapes: claude://login/... on older builds, and claude://claude.ai/sso-callback?...
    # on current ones (Store 2.7032). The boundary after sso-callback keeps a link such as
    # claude://claude.ai/sso-callbackother from being taken for a sign-in.
    param([string]$Link)
    return ($Link -match '^claude://(login/|claude\.ai/sso-callback(?:[/?#]|\z))')
}

function Get-ProfileDataPath {
    # Where Claude actually writes a profile's files. On the Store build, writes under
    # %LOCALAPPDATA% are redirected into the package's LocalCache (see Get-CodeSessionRoot).
    param([Parameter(Mandatory)]$Target)
    $localPrefix = $env:LOCALAPPDATA.TrimEnd('\') + '\'
    if ($script:ClaudeApp.Kind -eq 'Msix' -and -not $Target.IsDefault -and
        $Target.Path.StartsWith($localPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        $cache = Split-Path (Split-Path $script:ClaudeApp.DefaultProfilePath -Parent) -Parent
        $redirected = Join-Path (Join-Path $cache 'Local') $Target.Path.Substring($localPrefix.Length)
        if (Test-Path -LiteralPath (Join-Path $redirected 'config.json')) { return $redirected }
    }
    return $Target.Path
}

function Test-ProfileSignedIn {
    # $true or $false, or $null when there is no config.json to read yet. Observed on a
    # real install: signing out flips windowSizeWasSignedIn to false and shrinks
    # oauth:tokenCacheV2 to a 44 character placeholder (about 1400 to 2200 signed in).
    # Only key presence and value length are looked at, never the token itself.
    param([Parameter(Mandatory)][string]$Path)
    $cfg = Join-Path $Path 'config.json'
    if (-not (Test-Path -LiteralPath $cfg)) { return $null }
    try {
        $json  = Get-Content -LiteralPath $cfg -Raw -ErrorAction Stop | ConvertFrom-Json
        $names = @($json.PSObject.Properties.Name)
        if ($names -contains 'windowSizeWasSignedIn') { return [bool]$json.windowSizeWasSignedIn }
        if ($names -contains 'oauth:tokenCacheV2') { return ([string]$json.'oauth:tokenCacheV2').Length -gt 100 }
        return $false
    } catch { return $null }
}

function Set-PendingSignIn {
    param([Parameter(Mandatory)][string]$Id, [int]$Minutes = 15)
    New-Item -ItemType Directory -Force -Path (Split-Path $script:PendingSignInPath -Parent) | Out-Null
    @{ Profile = $Id; Expires = (Get-Date).AddMinutes($Minutes).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $script:PendingSignInPath -Encoding UTF8
}

function Clear-PendingSignIn { Remove-Item -LiteralPath $script:PendingSignInPath -Force -ErrorAction SilentlyContinue }

function Get-PendingSignIn {
    if (-not (Test-Path -LiteralPath $script:PendingSignInPath)) { return $null }
    try {
        $marker = Get-Content -LiteralPath $script:PendingSignInPath -Raw | ConvertFrom-Json
        if ([datetime]$marker.Expires -lt (Get-Date)) { Clear-PendingSignIn; return $null }
        return [string]$marker.Profile
    } catch { Clear-PendingSignIn; return $null }
}

# Returns the profile a sign-in link belongs to and why, or $null to leave it to Default.
function Select-SignInTarget {
    param([object[]]$Profiles, [string]$PendingId, [int]$FrontmostPid)
    if ($PendingId) {
        $hit = @($Profiles | Where-Object { $_.Id -eq $PendingId -and -not $_.IsDefault }) | Select-Object -First 1
        if ($hit) { return [pscustomobject]@{ Target = $hit; Reason = 'launched while signed out' } }
    }
    $open = @($Profiles | Where-Object { $_.Pid -and -not $_.IsDefault })
    $signedOut = @($open | Where-Object { $_.SignedIn -eq $false })
    if ($signedOut.Count -eq 1) { return [pscustomobject]@{ Target = $signedOut[0]; Reason = 'the only open account that is signed out' } }
    if ($FrontmostPid) {
        $hit = @($open | Where-Object { $_.Pid -eq $FrontmostPid }) | Select-Object -First 1
        if ($hit) { return [pscustomobject]@{ Target = $hit; Reason = 'its window was used most recently' } }
    }
    return $null
}

function Get-FrontmostPid {
    # Top-level windows are enumerated front to back, so the first visible, unowned, titled
    # one belonging to these processes is the one used most recently. The browser is in
    # front while the sign-in completes, which is why the foreground window cannot be used.
    param([int[]]$ProcessIds)
    if (-not $ProcessIds) { return 0 }
    Initialize-Native
    $hwnd = [Native.WinApi]::GetTopWindow([IntPtr]::Zero)
    for ($i = 0; $i -lt 10000 -and $hwnd -ne [IntPtr]::Zero; $i++) {
        if ([Native.WinApi]::IsWindowVisible($hwnd) -and
            [Native.WinApi]::GetWindow($hwnd, 4) -eq [IntPtr]::Zero -and          # GW_OWNER
            [Native.WinApi]::GetWindowTextLength($hwnd) -gt 0) {
            $owner = [uint32]0
            [Native.WinApi]::GetWindowThreadProcessId($hwnd, [ref]$owner) | Out-Null
            if ($ProcessIds -contains [int]$owner) { return [int]$owner }
        }
        $hwnd = [Native.WinApi]::GetWindow($hwnd, 2)                                 # GW_HWNDNEXT
    }
    return 0
}

function Start-ClaudeWithLink {
    # Only ever called with a link Test-SafeLink accepted, because it is embedded in a
    # command line. If the profile is already open, Electron's single instance lock hands
    # the link to that window instead of starting a second copy.
    param([Parameter(Mandatory)][string]$Link, $Target)
    if (-not (Test-Path -LiteralPath $script:ClaudeExe)) { Update-ClaudeInstall }
    $argLine = $(if ($Target -and -not $Target.IsDefault) { "--user-data-dir=`"$($Target.Path)`" `"$Link`"" } else { "`"$Link`"" })
    $id = $(if ($Target) { $Target.Id } else { $script:DefaultName })
    Invoke-WithProfileEnv -Id $id { Start-Process -FilePath $script:ClaudeExe -ArgumentList $argLine -WindowStyle Normal }
}

function Get-RouterCommand {
    # Same launcher as the shortcuts: a headless console host, so nothing flashes on screen.
    $ps      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $cmd     = "-NoProfile -ExecutionPolicy Bypass -File `"$(Get-LauncherScript)`" -HandleLink `"%1`""
    if ([Environment]::OSVersion.Version.Build -ge 17763 -and (Test-Path -LiteralPath $conhost)) {
        return "`"$conhost`" --headless `"$ps`" $cmd"
    }
    return "`"$ps`" -WindowStyle Hidden $cmd"
}

function Get-RegistryDefault {
    param([Parameter(Mandatory)][string]$Key)
    return [string](Get-ItemProperty -LiteralPath $Key -ErrorAction SilentlyContinue).'(default)'
}

function Set-RegistryValue {
    # Creates the key only when missing: New-Item -Force on an existing registry key
    # replaces it, and that would wipe whatever else lives there.
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Name, [string]$Value)
    if (-not (Test-Path -LiteralPath $Key)) { New-Item -Path $Key -Force | Out-Null }
    Set-ItemProperty -LiteralPath $Key -Name $Name -Value $Value
}

function Get-RouterRegistryPath {
    $reg = $script:RouterRegistry
    return [pscustomobject]@{
        Scheme        = "$($reg.Classes)\$($script:LinkScheme)"
        SchemeCommand = "$($reg.Classes)\$($script:LinkScheme)\shell\open\command"
        ProgId        = "$($reg.Classes)\$($script:RouterProgId)"
        ProgIdCommand = "$($reg.Classes)\$($script:RouterProgId)\shell\open\command"
        Capability    = $reg.Capability
        AppList       = $reg.AppList
        # RegisteredApplications holds the capability path relative to the hive.
        CapabilityRef = ($reg.Capability -replace '^HKCU:\\', '')
    }
}

function Test-RouterRegistered {
    # Both entries, pointing at the current copy of this script. Claude rewrites the first
    # on every start; -Install moves the script. Either makes this false.
    $keys = Get-RouterRegistryPath
    $want = Get-RouterCommand
    return ((Get-RegistryDefault $keys.SchemeCommand) -eq $want -and (Get-RegistryDefault $keys.ProgIdCommand) -eq $want)
}

function Register-SignInRouter {
    $keys = Get-RouterRegistryPath
    $cmd  = Get-RouterCommand
    # Whatever Claude registered is saved once, before the first change, so -Revert can
    # put it back exactly. A command of ours is never saved as the original. The claude
    # key itself is saved too, with the two values registration sets (null when absent):
    # the Store build can leave a bare key behind, with no command and only some of them.
    if (-not (Test-Path -LiteralPath $script:HandlerBackupPath)) {
        $existing = Get-RegistryDefault $keys.SchemeCommand
        if ($existing -notlike '* -HandleLink *') {
            $values = Get-ItemProperty -LiteralPath $keys.Scheme -ErrorAction SilentlyContinue
            $names  = @(if ($values) { $values.PSObject.Properties.Name })
            New-Item -ItemType Directory -Force -Path (Split-Path $script:HandlerBackupPath -Parent) | Out-Null
            @{
                Command     = $existing
                KeyExisted  = (Test-Path -LiteralPath $keys.Scheme)
                Description = $(if ($names -contains '(default)') { [string]$values.'(default)' } else { $null })
                UrlProtocol = $(if ($names -contains 'URL Protocol') { [string]$values.'URL Protocol' } else { $null })
            } | ConvertTo-Json | Set-Content -LiteralPath $script:HandlerBackupPath -Encoding UTF8
        }
    }
    Set-RegistryValue $keys.Scheme '(default)' "URL:$($script:LinkScheme)"
    Set-RegistryValue $keys.Scheme 'URL Protocol' ''
    Set-RegistryValue $keys.SchemeCommand '(default)' $cmd

    # The same command under a ProgID of our own, declared as an app that handles
    # claude://, which is what lets the user pick it in Settings > Default apps.
    Set-RegistryValue $keys.ProgId '(default)' "URL:$($script:LinkScheme)"
    Set-RegistryValue $keys.ProgId 'URL Protocol' ''
    Set-RegistryValue $keys.ProgIdCommand '(default)' $cmd
    Set-RegistryValue "$($keys.ProgId)\Application" 'ApplicationName' $script:RouterDisplayName
    Set-RegistryValue $keys.Capability 'ApplicationName' $script:RouterDisplayName
    Set-RegistryValue $keys.Capability 'ApplicationDescription' 'Sends each Claude sign-in to the account that asked for it'
    Set-RegistryValue "$($keys.Capability)\URLAssociations" $script:LinkScheme $script:RouterProgId
    Set-RegistryValue $keys.AppList $script:RouterAppName $keys.CapabilityRef
}

function Get-LinkHandlerProgId {
    # The ProgID Windows will really use for claude:// links. Asked of the shell rather than
    # read from UserChoice: Windows ignores a choice whose protecting hash does not verify,
    # and only the shell knows whether it does.
    Initialize-Native
    $size   = [uint32]260
    $result = New-Object System.Text.StringBuilder 260
    $hr = [Native.WinApi]::AssocQueryString(0x1000, 20, $script:LinkScheme, $null, $result, [ref]$size)   # ASSOCF_IS_PROTOCOL, ASSOCSTR_PROGID
    if ($hr -ne 0) { return $null }
    return $result.ToString()
}

function Test-RouterChosen {
    # Whether claude:// links reach the router at all.
    $progId = Get-LinkHandlerProgId
    if ($progId -eq $script:RouterProgId) { return $true }
    # The installer build has no manifest claim, so with no choice made the links follow
    # the Classes key, which is ours while routing is on.
    if ($script:ClaudeApp.Kind -ne 'Msix' -and (-not $progId -or $progId -eq $script:LinkScheme)) {
        return (Test-RouterRegistered)
    }
    return $false
}

function Unregister-SignInRouter {
    # Returns one line per thing done, for -Revert and the tray to report.
    $keys = Get-RouterRegistryPath
    $done = New-Object System.Collections.Generic.List[string]
    $backup = $null
    if (Test-Path -LiteralPath $script:HandlerBackupPath) {
        try { $backup = Get-Content -LiteralPath $script:HandlerBackupPath -Raw | ConvertFrom-Json } catch { }
    }
    if ($backup -and $backup.Command) {
        Set-RegistryValue $keys.SchemeCommand '(default)' $backup.Command
        $done.Add('put back the claude:// handler Claude had registered')
    } elseif ((Get-RegistryDefault $keys.SchemeCommand) -like '* -HandleLink *') {
        # No command of Claude's to put back. Remove the whole key only when the backup
        # says we created it; otherwise (or without a backup) keep the key and take out
        # just the command we added.
        if ($backup -and $backup.PSObject.Properties.Name -contains 'KeyExisted' -and -not $backup.KeyExisted) {
            Remove-Item -LiteralPath $keys.Scheme -Recurse -Force
        } else {
            Remove-Item -LiteralPath $keys.SchemeCommand -Recurse -Force
            foreach ($k in "$($keys.Scheme)\shell\open", "$($keys.Scheme)\shell") {
                if ((Test-Path -LiteralPath $k) -and -not (Get-ChildItem -LiteralPath $k) -and -not (Get-Item -LiteralPath $k).Property) {
                    Remove-Item -LiteralPath $k -Force
                }
            }
        }
        $done.Add('removed our claude:// handler; Claude registers its own the next time it starts')
    }
    # A key that was there before gets its own two values back, including their absence.
    if ($backup -and $backup.KeyExisted -and (Test-Path -LiteralPath $keys.Scheme)) {
        foreach ($pair in @(@('(default)', 'Description'), @('URL Protocol', 'UrlProtocol'))) {
            if ($backup.PSObject.Properties.Name -notcontains $pair[1]) { continue }   # a backup from before this was saved
            $value = $backup.($pair[1])
            if ($null -ne $value) { Set-ItemProperty -LiteralPath $keys.Scheme -Name $pair[0] -Value $value; continue }
            # Through .NET: Remove-ItemProperty cannot delete the default value, whose real
            # name is empty; '(default)' is only how PowerShell displays it.
            $sub = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(($keys.Scheme -replace '^HKCU:\\', ''), $true)
            if ($sub) {
                try { $sub.DeleteValue($(if ($pair[0] -eq '(default)') { '' } else { $pair[0] }), $false) } finally { $sub.Close() }
            }
        }
    }
    if (Test-Path -LiteralPath $script:HandlerBackupPath) { Remove-Item -LiteralPath $script:HandlerBackupPath -Force }

    if ((Get-LinkHandlerProgId) -eq $script:RouterProgId) {
        # Picked in Settings > Default apps, and only Settings can change that. Deleting the
        # ProgID would leave claude:// pointing at nothing, so it stays. With routing off,
        # -HandleLink passes every link straight to Default, and the next -Revert after
        # Claude is picked again removes the rest.
        $done.Add("kept '$($script:RouterDisplayName)': it is still your choice for claude:// links in Settings > Default apps. Links go straight to Default until you pick Claude there, then run -Revert again to remove it")
        return $done
    }
    $removed = $false
    if (Test-Path -LiteralPath $keys.ProgId) { Remove-Item -LiteralPath $keys.ProgId -Recurse -Force; $removed = $true }
    if (Test-Path -LiteralPath $keys.Capability) {
        Remove-Item -LiteralPath $keys.Capability -Recurse -Force; $removed = $true
        $parent = Split-Path $keys.Capability -Parent
        if ((Test-Path -LiteralPath $parent) -and -not (Get-ChildItem -LiteralPath $parent) -and
            -not (Get-Item -LiteralPath $parent).Property) {
            Remove-Item -LiteralPath $parent -Force
        }
    }
    if ((Get-ItemProperty -LiteralPath $keys.AppList -ErrorAction SilentlyContinue).$($script:RouterAppName)) {
        Remove-ItemProperty -LiteralPath $keys.AppList -Name $script:RouterAppName; $removed = $true
    }
    if ($removed) { $done.Add("removed '$($script:RouterDisplayName)' from the apps Windows offers for claude:// links") }
    return $done
}

function Get-RouterStateText {
    if (-not (Test-SignInRoutingOn)) { return 'off' }
    if (-not (Test-RouterRegistered)) { return 'on, but Claude has the claude:// handler back (taken again at the next launch)' }
    if (-not (Test-RouterChosen)) { return "on, waiting for one step: Settings > Default apps > $($script:RouterDisplayName) > set it for CLAUDE" }
    return 'on: sign-ins go to the account that asked'
}

function Open-RouterDefaultAppsPage {
    # Opens straight at the router's page on Windows 11 with the 2023-04 update or later,
    # and at the Default apps list everywhere else.
    Start-Process ('ms-settings:defaultapps?registeredAppUser=' + [uri]::EscapeDataString($script:RouterAppName))
}

# Returns $true when sign-ins now reach the router, $false while the Store build still
# needs the user's pick in Settings.
function Enable-SignInRouting {
    Register-SignInRouter
    Set-Setting 'SignInRouting' $true
    Write-RouterLog 'Sign-in routing turned on.'
    return (Test-RouterChosen)
}

function Disable-SignInRouting {
    Set-Setting 'SignInRouting' $false
    Clear-PendingSignIn
    Write-RouterLog 'Sign-in routing turned off.'
    # Passed straight through: capturing and returning nothing would hand callers a $null
    # that @() counts as one item.
    Unregister-SignInRouter
}

function Update-SignInRouting {
    # Called as a profile launches while routing is on. A profile that is not signed in
    # yet is about to be, so its sign-in is the one to expect.
    param([Parameter(Mandatory)][string]$Id)
    $target = [pscustomobject]@{ Id = $Id; Path = (Get-ProfilePath -Id $Id); IsDefault = ($Id -eq $script:DefaultName) }
    if (-not $target.IsDefault -and (Test-ProfileSignedIn -Path (Get-ProfileDataPath -Target $target)) -ne $true) {
        Set-PendingSignIn -Id $Id
    }
    if (-not (Test-RouterRegistered)) { Register-SignInRouter }
}

function Wait-RouterRetake {
    # Claude rewrites the claude:// key a few seconds into starting. Shortcuts run without
    # the tray's timer, so the launching process stays a little while to take it back.
    param([int]$Seconds = 20)
    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) {
        Start-Sleep -Seconds 1
        if (-not (Test-RouterRegistered)) {
            try { Register-SignInRouter; Write-RouterLog 'Took the claude:// handler back after Claude started.' } catch { }
        }
    }
}

function Request-SignInRouting {
    # Asked once, the first time an account is added, because it changes a Windows setting
    # outside the switcher's own folder. The answer is remembered either way; -Again asks
    # regardless, for turning it on later from the tray.
    param($Owner, [switch]$Again)
    if (-not $Again -and $null -ne (Get-Setting 'SignInRouting')) { return }
    Add-Type -AssemblyName System.Windows.Forms
    $text = "Send browser sign-ins to the account that asked for them?`n`n" +
            "Signing in to Claude finishes with a claude:// link, and Windows sends all of those to your original account. " +
            "With this on, the switcher handles those links and passes each sign-in to the new account instead. Other links still go to your original account.`n`n" +
            "This changes which program Windows uses for claude:// links. The original is saved, and turning it off from the tray menu (or -Revert) puts it back."
    $answer = $(if ($Owner) { [System.Windows.Forms.MessageBox]::Show($Owner, $text, 'Sign-in routing', 'YesNo', 'Question') }
                else        { [System.Windows.Forms.MessageBox]::Show($text, 'Sign-in routing', 'YesNo', 'Question') })
    if ($answer -ne 'Yes') { Set-Setting 'SignInRouting' $false; return }
    if (-not (Enable-SignInRouting)) { Show-RouterPickHint -Owner $Owner }
}

function Show-RouterPickHint {
    param($Owner)
    Add-Type -AssemblyName System.Windows.Forms
    $text = "One more step, which only you can do: Windows lets the Store version of Claude keep claude:// links unless you choose otherwise.`n`n" +
            "In the Settings page that opens next, set CLAUDE to '$($script:RouterDisplayName)', then sign in."
    if ($Owner) { [System.Windows.Forms.MessageBox]::Show($Owner, $text, 'Sign-in routing', 'OK', 'Information') | Out-Null }
    else        { [System.Windows.Forms.MessageBox]::Show($text, 'Sign-in routing', 'OK', 'Information') | Out-Null }
    Open-RouterDefaultAppsPage
}

function Invoke-SignInRouter {
    # Not Mandatory: an empty link must reach Test-SafeLink and be refused quietly, not
    # stop at parameter binding with an error dialog.
    param([string]$Link)
    if (-not (Test-SafeLink -Link $Link)) {
        # Refused rather than passed on: a link that fails is malformed or an attempt to
        # smuggle extra arguments. Never logged, because a sign-in link carries a code.
        Write-RouterLog 'Refused a claude:// link that failed validation.'
        return
    }
    if (-not (Test-SignInRoutingOn) -or -not (Test-SignInLink -Link $Link)) {
        Start-ClaudeWithLink -Link $Link
        Write-RouterLog $(if (Test-SignInRoutingOn) { 'Not a sign-in link; passed to Default.' } else { 'Routing is off; passed a link to Default.' })
        return
    }
    try {
        $profiles = @(Get-ProfileList | ForEach-Object {
            $signedIn = $(if ($_.Pid -and -not $_.IsDefault) { Test-ProfileSignedIn -Path (Get-ProfileDataPath -Target $_) } else { $null })
            $_ | Add-Member -NotePropertyName SignedIn -NotePropertyValue $signedIn -PassThru
        })
        $front = Get-FrontmostPid -ProcessIds @($profiles | Where-Object { $_.Pid } | ForEach-Object { [int]$_.Pid })
        $pick  = Select-SignInTarget -Profiles $profiles -PendingId (Get-PendingSignIn) -FrontmostPid $front
        if ($pick) {
            Start-ClaudeWithLink -Link $Link -Target $pick.Target
            Write-RouterLog "Sign-in sent to '$($pick.Target.Name)' ($($pick.Reason))."
        } else {
            Start-ClaudeWithLink -Link $Link
            Write-RouterLog 'Sign-in sent to Default (no other account was waiting for one).'
        }
        Clear-PendingSignIn
    } catch {
        # Losing the sign-in would be worse than sending it to the wrong account.
        Write-RouterLog "Routing failed, sign-in passed to Default: $($_.Exception.Message)"
        Start-ClaudeWithLink -Link $Link
        return
    }
    # Claude may rewrite the claude:// key as the account starts; take it back so the next
    # sign-in is routed too.
    Start-Sleep -Seconds 4
    try { if (-not (Test-RouterRegistered)) { Register-SignInRouter } } catch { }
}

# ------------------------------------------------------------ console modes --

if ($PSBoundParameters.ContainsKey('HandleLink')) {
    # Windows runs this for every claude:// link once routing is on. The link is untrusted:
    # anything that rode along with it (-Revert, -ClaudePath, a stray positional argument)
    # was refused at the top, before any parameter was acted on (Test-HandleLinkAlone). An
    # empty link is refused by the router, never the window.
    Invoke-SignInRouter -Link $HandleLink
    return
}

if ($Status) {
    $backup = $(if (Test-Path -LiteralPath $script:HandlerBackupPath) { $script:HandlerBackupPath } else { 'none' })
    "Sign-in routing:  $(Get-RouterStateText)"
    "Handler backup:   $backup"
    "Pending sign-in:  $(if ($p = Get-PendingSignIn) { $p } else { 'none' })"
    "Router log:       $($script:RouterLogPath)"
    ''
    'Open accounts:'
    foreach ($p in @(Get-ProfileList | Where-Object { $_.Pid })) {
        $signedIn = Test-ProfileSignedIn -Path (Get-ProfileDataPath -Target $p)
        $state = $(if ($signedIn) { 'signed in' } elseif ($signedIn -eq $false) { 'signed out' } else { 'unknown' })
        '  {0,-24} pid {1,-7} {2}' -f $p.Name, $p.Pid, $state
    }
    return
}

if ($Revert) {
    $done = @(Disable-SignInRouting)
    if ($done.Count) { $done } else { 'Nothing to put back: sign-in routing had not changed anything.' }
    return
}

if ($RouteSignIns) {
    if (Enable-SignInRouting) {
        'Sign-in routing is on. Browser sign-ins now go to the account that asked for them.'
    } else {
        'Sign-in routing is on, with one step left that only you can do. In the Settings page'
        "that just opened, set CLAUDE to '$($script:RouterDisplayName)'. Check with -Status."
        Open-RouterDefaultAppsPage
    }
    return
}

if ($Install) {
    Install-Switcher
    # Land on the switcher itself, which is where the next step (adding an account) is.
    Start-SwitcherWindow
    return
}

if ($AddAccount) {
    Request-SignInRouting
    $created = Add-ClaudeAccount
    "Added '$($created.Name)'. Sign in with the other account in the Claude window that just opened."
    try {
        $watch = New-IdentityWatch -Target $created -Process $script:LaunchedProcess
        while (-not (Step-IdentityWatch -Watch $watch)) { Start-Sleep -Milliseconds 150 }
    } catch { }
    if (Test-SignInRoutingOn) { Wait-RouterRetake }
    return
}

if ($Launch) {
    $target = Resolve-ClaudeProfile -Name $Launch -SkipStatus
    if (-not $target) {
        # Used to create a fresh, empty profile, so a typo quietly became a new account.
        $known = (Get-ProfileList -SkipStatus | ForEach-Object { $_.Name }) -join ', '
        throw "There is no Claude profile called '$Launch'.`r`n`r`nProfiles: $known"
    }
    $how = Start-ClaudeProfile -Id $target.Id
    if ($how -eq 'started' -and -not $target.IsDefault) {
        # The window first: its identity has to be set before it is shown.
        try {
            $watch = New-IdentityWatch -Target $target -Process $script:LaunchedProcess
            while (-not (Step-IdentityWatch -Watch $watch)) { Start-Sleep -Milliseconds 150 }
        } catch { }
        if (Test-SignInRoutingOn) { Wait-RouterRetake }
    }
    return
}

if ($Shortcut) {
    $target = Resolve-ClaudeProfile -Name $Shortcut -SkipStatus
    if (-not $target) { throw "There is no Claude profile called '$Shortcut'." }
    $dirs = $(if ([string]::IsNullOrWhiteSpace($To)) { Get-ShortcutDirs } else { @($To) })
    foreach ($dir in $dirs) { New-ProfileShortcut -Target $target -Directory $dir }
    return
}

if ($List) {
    Get-ProfileList | ForEach-Object {
        $state = if ($_.Pid) { "running (pid $($_.Pid))" } else { 'stopped' }
        $name  = if ($_.Name -ne $_.Id) { "$($_.Name) [$($_.Id)]" } else { $_.Name }
        '{0,-24} {1,-22} {2}' -f $name, $state, $_.Path
    }
    return
}

# ------------------------------------------------------------------ the GUI --

Add-Type -AssemblyName System.Windows.Forms
Initialize-Native

# One switcher at a time. A second copy, for example from clicking the shortcut while
# the first sits in the tray, asks the first to show itself and then leaves.
$instanceIsNew = $false
$script:InstanceMutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeProfileSwitcher', [ref]$instanceIsNew)
$script:ShowSignal    = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\ClaudeProfileSwitcher.Show')
if (-not $instanceIsNew) {
    if (-not $Tray) {
        # Hands our right to take the foreground, from the user's click, to the other copy.
        [Native.WinApi]::AllowSetForegroundWindow(-1) | Out-Null
        $script:ShowSignal.Set() | Out-Null
    }
    return
}

$SW_HIDE       = 0
$SW_SHOWNORMAL = 1

# Hide our own console window rather than launching with -WindowStyle Hidden: that
# flag lands in the process STARTUPINFO, and WinForms applies it to the first window
# it shows, so the form itself would come up invisible. Shortcuts use a headless
# console, which has nothing to hide, but the .cmd launcher does not.
$console = [Native.WinApi]::GetConsoleWindow()
if ($console -ne [IntPtr]::Zero) { [Native.WinApi]::ShowWindow($console, $SW_HIDE) | Out-Null }

[System.Windows.Forms.Application]::EnableVisualStyles()

$bg      = [System.Drawing.Color]::FromArgb(250, 249, 245)
$ink     = [System.Drawing.Color]::FromArgb(38, 38, 36)
$muted   = [System.Drawing.Color]::FromArgb(120, 118, 112)
$accent  = [System.Drawing.Color]::FromArgb(203, 123, 93)
$running = [System.Drawing.Color]::FromArgb(46, 125, 74)
$border  = [System.Drawing.Color]::FromArgb(220, 217, 210)

$fontUI    = New-Object System.Drawing.Font('Segoe UI', 9.5)
$fontBold  = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$fontTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
$fontSmall = New-Object System.Drawing.Font('Segoe UI', 8.5)

$defaultProfile = Resolve-ClaudeProfile -Name $script:DefaultName -SkipStatus
$null           = Get-ProfileIconPath -Target $defaultProfile
$appIcon        = [System.Drawing.Icon]::FromHandle((New-BadgedBitmap -Size 32).GetHicon())

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'Claude Profile Switcher'
$form.Size            = New-Object System.Drawing.Size(760, 520)
$form.MinimumSize     = New-Object System.Drawing.Size(700, 440)
$form.StartPosition   = 'CenterScreen'
$form.BackColor       = $bg
$form.Font            = $fontUI
$form.KeyPreview      = $true
$form.Icon            = $appIcon

$title           = New-Object System.Windows.Forms.Label
$title.Text      = 'Claude accounts'
$title.Font      = $fontTitle
$title.ForeColor = $ink
$title.Location  = New-Object System.Drawing.Point(20, 16)
$title.Size      = New-Object System.Drawing.Size(400, 28)
$form.Controls.Add($title)

$subtitle           = New-Object System.Windows.Forms.Label
$subtitle.Text      = 'Each profile is a separate login. Several can run at the same time. Right-click a profile for more.'
$subtitle.Font      = $fontSmall
$subtitle.ForeColor = $muted
$subtitle.Location  = New-Object System.Drawing.Point(21, 44)
$subtitle.Size      = New-Object System.Drawing.Size(700, 18)
$form.Controls.Add($subtitle)

$images            = New-Object System.Windows.Forms.ImageList
$images.ColorDepth = 'Depth32Bit'
$images.ImageSize  = New-Object System.Drawing.Size(20, 20)

$listView                       = New-Object System.Windows.Forms.ListView
$listView.Location              = New-Object System.Drawing.Point(20, 72)
$listView.Size                  = New-Object System.Drawing.Size(704, 318)
$listView.View                  = 'Details'
$listView.FullRowSelect         = $true
$listView.MultiSelect           = $false
$listView.HideSelection         = $false
$listView.BackColor             = [System.Drawing.Color]::White
$listView.ForeColor             = $ink
$listView.Anchor                = 'Top,Left,Right,Bottom'
$listView.SmallImageList        = $images
$listView.Columns.Add('Profile', 210)  | Out-Null
$listView.Columns.Add('Status', 150)   | Out-Null
$listView.Columns.Add('Last used', 170)| Out-Null
$listView.Columns.Add('', 150)         | Out-Null
$form.Controls.Add($listView)

# First run: only the original account exists, so say what to do next.
$emptyHint           = New-Object System.Windows.Forms.Label
$emptyHint.Text      = "Only your original account is here so far.`r`nClick Add account to sign in to another one in its own window."
$emptyHint.TextAlign = 'MiddleCenter'
$emptyHint.ForeColor = $muted
$emptyHint.BackColor = [System.Drawing.Color]::White
$emptyHint.Location  = New-Object System.Drawing.Point(1, 120)
$emptyHint.Size      = New-Object System.Drawing.Size(700, 60)
$emptyHint.Anchor    = 'Top,Left,Right'
$emptyHint.Visible   = $false
$listView.Controls.Add($emptyHint)

$statusLine           = New-Object System.Windows.Forms.Label
$statusLine.Font      = $fontSmall
$statusLine.ForeColor = $muted
$statusLine.Location  = New-Object System.Drawing.Point(21, 398)
$statusLine.Size      = New-Object System.Drawing.Size(500, 18)
$statusLine.Anchor    = 'Left,Right,Bottom'
$form.Controls.Add($statusLine)

$chkTray           = New-Object System.Windows.Forms.CheckBox
$chkTray.Text      = 'Keep running in the tray'
$chkTray.Font      = $fontSmall
$chkTray.ForeColor = $muted
$chkTray.Location  = New-Object System.Drawing.Point(544, 396)
$chkTray.Size      = New-Object System.Drawing.Size(180, 22)
$chkTray.Anchor    = 'Right,Bottom'
$chkTray.Checked   = ((Get-Setting 'KeepInTray') -ne $false)
$chkTray.Add_CheckedChanged({ Set-Setting 'KeepInTray' $chkTray.Checked })
$form.Controls.Add($chkTray)

function New-Button {
    param([string]$Text, [int]$X, [int]$Width = 108, [switch]$Primary, [string]$Anchor = 'Left,Bottom')
    $b           = New-Object System.Windows.Forms.Button
    $b.Text      = $Text
    $b.Location  = New-Object System.Drawing.Point($X, 426)
    $b.Size      = New-Object System.Drawing.Size($Width, 34)
    $b.FlatStyle = 'Flat'
    $b.Anchor    = $Anchor
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
    if ($Primary) {
        $b.BackColor                 = $accent
        $b.ForeColor                 = [System.Drawing.Color]::White
        $b.FlatAppearance.BorderSize = 0
        $b.Font                      = $fontBold
    } else {
        $b.BackColor                  = [System.Drawing.Color]::White
        $b.ForeColor                  = $ink
        $b.FlatAppearance.BorderColor = $border
        $b.FlatAppearance.BorderSize  = 1
    }
    $form.Controls.Add($b)
    return $b
}

$btnLaunch   = New-Button -Text 'Launch'          -X 20  -Width 116 -Primary
$btnNew      = New-Button -Text 'Add account'     -X 144
$btnRename   = New-Button -Text 'Rename'          -X 260 -Width 92
$btnShortcut = New-Button -Text 'Add shortcuts'   -X 360 -Width 116
$btnTransfer = New-Button -Text 'Transfer chats'  -X 484 -Width 116
$btnDelete   = New-Button -Text 'Delete'          -X 616 -Anchor 'Right,Bottom'

$tips = New-Object System.Windows.Forms.ToolTip
$tips.SetToolTip($btnNew, 'Opens Claude at a fresh sign-in screen for another account (Ctrl+N)')
$tips.SetToolTip($btnShortcut, 'Desktop and Start menu shortcuts that open this account directly')
$tips.SetToolTip($btnTransfer, 'Copy Claude Code chats from this account to another one')

function Get-ProfileImageKey {
    param([Parameter(Mandatory)]$Target)
    $letter = $(if ($Target.IsDefault) { '' } else { Get-BadgeLetter -Label $Target.Name })
    $key = "$($Target.Id)|$letter"
    if (-not $images.Images.ContainsKey($key)) {
        $color = $(if ($letter) { Get-ProfileColor -Id $Target.Id } else { $null })
        $images.Images.Add($key, (New-BadgedBitmap -Size 20 -Letter $letter -Color $color))
    }
    return $key
}

$script:ListSignature = ''

function Update-List {
    param([switch]$Force)
    $selectedId = $null
    if ($listView.SelectedItems.Count -gt 0) { $selectedId = $listView.SelectedItems[0].Tag.Id }

    $profiles = @(Get-ProfileList)
    # The timer calls this every few seconds. Rebuilding an unchanged list only flickers.
    $sig = ($profiles | ForEach-Object { "$($_.Id)|$($_.Name)|$($_.Pid)|$($_.LastUsed)" }) -join ';'
    if (-not $Force -and $sig -eq $script:ListSignature) { return }
    $script:ListSignature = $sig

    $listView.BeginUpdate()
    $listView.Items.Clear()
    foreach ($p in $profiles) {
        $item = New-Object System.Windows.Forms.ListViewItem($p.Name)
        $item.ImageKey = Get-ProfileImageKey -Target $p
        $item.UseItemStyleForSubItems = $false
        if ($p.Pid) {
            $item.SubItems.Add('Running') | Out-Null
            $item.SubItems[1].ForeColor = $running
        } else {
            $item.SubItems.Add('Not running') | Out-Null
            $item.SubItems[1].ForeColor = $muted
        }
        if ($p.Pid) {
            $item.SubItems.Add('now') | Out-Null
        } elseif ($p.LastUsed) {
            $item.SubItems.Add($p.LastUsed.ToString('d MMM yyyy, HH:mm')) | Out-Null
        } else {
            $item.SubItems.Add('never') | Out-Null
        }
        $item.SubItems[2].ForeColor = $muted
        $note = $(if ($p.IsDefault) { 'your original' }
                  elseif ($p.Id -eq $script:JustAdded -and $p.Name -eq $p.Id) { 'new - F2 to rename' }
                  elseif ($p.Name -ne $p.Id) { "folder: $($p.Id)" }
                  else { '' })
        $item.SubItems.Add($note) | Out-Null
        $item.SubItems[3].ForeColor = $muted
        $item.Tag = $p
        $listView.Items.Add($item) | Out-Null
    }
    $listView.EndUpdate()
    $emptyHint.Visible = ($profiles.Count -eq 1)

    foreach ($i in $listView.Items) { if ($i.Tag.Id -eq $selectedId) { $i.Selected = $true; $i.Focused = $true } }
    if ($listView.SelectedItems.Count -eq 0 -and $listView.Items.Count -gt 0) { $listView.Items[0].Selected = $true }

    $count = @($profiles | Where-Object { $_.Pid }).Count
    $label = $(if ($script:ClaudeApp.Version -eq 'unknown') { $script:ClaudeApp.Kind } else { $script:ClaudeApp.Version })
    # Kept deliberately ASCII only: without a BOM, Windows PowerShell 5.1 reads this file
    # using the system codepage, so non-ASCII here renders as garbage on other locales.
    $statusLine.Text = "$($profiles.Count) profile(s), $count running   |   Claude $label"
    Update-Buttons
}

function Get-SelectedProfile {
    if ($listView.SelectedItems.Count -eq 0) { return $null }
    return $listView.SelectedItems[0].Tag
}

function Update-Buttons {
    $p = Get-SelectedProfile
    $btnLaunch.Text    = $(if ($p -and $p.Pid) { 'Switch to' } else { 'Launch' })
    $btnDelete.Enabled = [bool]($p -and -not $p.IsDefault)
}

function Select-ProfileRow {
    param([string]$Id)
    foreach ($i in $listView.Items) { if ($i.Tag.Id -eq $Id) { $i.Selected = $true; $i.Focused = $true; $i.EnsureVisible() } }
}

function Show-Prompt {
    param([string]$Message, [string]$Title, [string]$OkText = 'OK', [string]$Initial = '')
    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = $Title
    $dlg.Size            = New-Object System.Drawing.Size(420, 180)
    $dlg.StartPosition   = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.ShowInTaskbar   = $false
    $dlg.BackColor       = $bg
    $dlg.Font            = $fontUI

    $lbl           = New-Object System.Windows.Forms.Label
    $lbl.Text      = $Message
    $lbl.Location  = New-Object System.Drawing.Point(16, 16)
    $lbl.Size      = New-Object System.Drawing.Size(376, 34)
    $lbl.ForeColor = $ink
    $dlg.Controls.Add($lbl)

    $box          = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(18, 56)
    $box.Size     = New-Object System.Drawing.Size(372, 26)
    $box.Text     = $Initial
    $box.SelectAll()
    $dlg.Controls.Add($box)

    $y = 96

    $ok              = New-Object System.Windows.Forms.Button
    $ok.Text         = $OkText
    $ok.Location     = New-Object System.Drawing.Point(202, $y)
    $ok.Size         = New-Object System.Drawing.Size(90, 32)
    $ok.DialogResult = 'OK'
    $dlg.Controls.Add($ok)

    $cancel              = New-Object System.Windows.Forms.Button
    $cancel.Text         = 'Cancel'
    $cancel.Location     = New-Object System.Drawing.Point(300, $y)
    $cancel.Size         = New-Object System.Drawing.Size(90, 32)
    $cancel.DialogResult = 'Cancel'
    $dlg.Controls.Add($cancel)

    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel

    if ($dlg.ShowDialog($form) -eq 'OK') {
        return [pscustomobject]@{ Text = $box.Text.Trim() }
    }
    return $null
}

function Show-Message {
    param([string]$Text, [string]$Caption, [string]$Buttons = 'OK', [string]$Icon = 'Information')
    # Owned by the window only while it is on screen. From the tray, an owner that is
    # hidden would push the message box behind everything else.
    if ($form.Visible) { return [System.Windows.Forms.MessageBox]::Show($form, $Text, $Caption, $Buttons, $Icon) }
    return [System.Windows.Forms.MessageBox]::Show($Text, $Caption, $Buttons, $Icon)
}

function Invoke-LaunchProfile {
    param([Parameter(Mandatory)]$Target)
    try {
        $how = Start-ClaudeProfile -Id $Target.Id
        if ($how -eq 'started') { Add-IdentityWatch -Target $Target }
        # The refresh timer flips the row to Running once the window is up.
        $statusLine.Text = $(if ($how -eq 'focused') { "Switched to '$($Target.Name)'." } else { "Starting '$($Target.Name)'..." })
    } catch {
        Show-Message $_.Exception.Message 'Could not launch' 'OK' 'Error' | Out-Null
    }
}

$script:IdentityWatches = New-Object System.Collections.Generic.List[object]

function Add-IdentityWatch {
    param([Parameter(Mandatory)]$Target)
    if ($Target.IsDefault) { return }
    $script:IdentityWatches.Add((New-IdentityWatch -Target $Target -Process $script:LaunchedProcess))
    $watchTimer.Start()
}

function Invoke-AddAccount {
    try {
        Request-SignInRouting -Owner $(if ($form.Visible) { $form } else { $null })
        $created = Add-ClaudeAccount
    } catch {
        Show-Message $_.Exception.Message 'Could not add an account' 'OK' 'Error' | Out-Null
        return
    }
    Add-IdentityWatch -Target $created
    $script:JustAdded = $created.Id
    Update-List -Force
    Select-ProfileRow -Id $created.Id
    $statusLine.Text = "Sign in to '$($created.Name)' in the new Claude window. Press F2 here to give it a better name."
}

function Switch-SignInRouting {
    $owner = $(if ($form.Visible) { $form } else { $null })
    try {
        if (Test-SignInRoutingOn) {
            $done = @(Disable-SignInRouting)
            $msg  = 'Sign-in routing is off. Browser sign-ins go to your original account again.'
            if ($done.Count) { $msg += "`n`n- " + ($done -join "`n- ") }
            Show-Message $msg 'Sign-in routing' | Out-Null
            return
        }
        Request-SignInRouting -Owner $owner -Again
        if ((Test-SignInRoutingOn) -and (Test-RouterChosen)) {
            Show-Message 'Sign-in routing is on. Browser sign-ins now go to the account that asked for them.' 'Sign-in routing' | Out-Null
        }
    } catch {
        Show-Message $_.Exception.Message 'Sign-in routing' 'OK' 'Error' | Out-Null
    }
}

function Invoke-RenameProfile {
    $p = Get-SelectedProfile
    if (-not $p) { return }
    $answer = Show-Prompt -Message "New name for '$($p.Name)'. Its sign-in and data stay as they are." -Title 'Rename profile' `
                          -OkText 'Rename' -Initial $p.Name
    if (-not $answer -or -not $answer.Text -or $answer.Text -ceq $p.Name) { return }
    try {
        $renamed = Rename-ClaudeProfile -Target $p -NewName $answer.Text
        # A new badge letter is a new identity and icon; an open window moves to it now.
        try { Update-RunningProfileIdentity } catch { }
        Update-List -Force
        Select-ProfileRow -Id $renamed.Id
        $statusLine.Text = "Renamed '$($p.Name)' to '$($renamed.Name)'."
    } catch {
        Show-Message $_.Exception.Message 'Could not rename' 'OK' 'Warning' | Out-Null
    }
}

function Invoke-AddShortcuts {
    $p = Get-SelectedProfile
    if (-not $p) { return }
    try {
        foreach ($dir in Get-ShortcutDirs) { New-ProfileShortcut -Target $p -Directory $dir | Out-Null }
        $statusLine.Text = "Added 'Claude - $($p.Name)' to the desktop and Start menu."
    } catch {
        Show-Message $_.Exception.Message 'Could not create shortcut' 'OK' 'Error' | Out-Null
    }
}

function Invoke-OpenFolder {
    $p = Get-SelectedProfile
    if (-not $p) { return }
    if (Test-Path -LiteralPath $p.Path) {
        Start-Process 'explorer.exe' -ArgumentList "`"$($p.Path)`""
    } else {
        Show-Message 'This profile has no folder yet. It is created the first time you launch it.' 'Nothing there yet' | Out-Null
    }
}

function Invoke-DeleteProfile {
    $p = Get-SelectedProfile
    if (-not $p -or $p.IsDefault) { return }
    $answer = Show-Message "Delete the '$($p.Name)' profile and sign that account out on this computer?`n`nIts folder, saved login and shortcuts are removed. Your other profiles are untouched." `
                           'Delete profile' 'YesNo' 'Warning'
    if ($answer -ne 'Yes') { return }
    try {
        Remove-ClaudeProfile -Target $p
        Update-List -Force
        $statusLine.Text = "Deleted '$($p.Name)'."
    } catch {
        Show-Message $_.Exception.Message 'Could not delete' 'OK' 'Warning' | Out-Null
    }
}

function Show-TransferDialog {
    param([Parameter(Mandatory)]$Source)

    $sessions = @(Get-CodeSessions -Source $Source)
    $targets  = @(Get-ProfileList | Where-Object { $_.Id -ne $Source.Id })
    if ($sessions.Count -eq 0) {
        Show-Message "'$($Source.Name)' has no Claude Code chats to transfer." 'Nothing to transfer' | Out-Null
        return
    }
    if ($targets.Count -eq 0) {
        Show-Message 'Create a second profile first, then transfer chats to it.' 'No other account' | Out-Null
        return
    }

    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Transfer Claude Code chats'
    $dlg.Size            = New-Object System.Drawing.Size(700, 500)
    $dlg.MinimumSize     = New-Object System.Drawing.Size(560, 400)
    $dlg.StartPosition   = 'CenterParent'
    $dlg.ShowInTaskbar   = $false
    $dlg.MinimizeBox     = $false
    $dlg.BackColor       = $bg
    $dlg.Font            = $fontUI

    $hdr           = New-Object System.Windows.Forms.Label
    $hdr.Text      = "Chats in '$($Source.Name)'"
    $hdr.Font      = $fontBold
    $hdr.ForeColor = $ink
    $hdr.Location  = New-Object System.Drawing.Point(16, 14)
    $hdr.Size      = New-Object System.Drawing.Size(400, 22)
    $dlg.Controls.Add($hdr)

    $all          = New-Object System.Windows.Forms.CheckBox
    $all.Text     = 'Select all'
    $all.AutoSize = $true
    $all.Location = New-Object System.Drawing.Point(560, 14)
    $all.Anchor   = 'Top,Right'
    $dlg.Controls.Add($all)

    $lv               = New-Object System.Windows.Forms.ListView
    $lv.Location      = New-Object System.Drawing.Point(16, 40)
    $lv.Size          = New-Object System.Drawing.Size(652, 300)
    $lv.View          = 'Details'
    $lv.CheckBoxes    = $true
    $lv.FullRowSelect = $true
    $lv.BackColor     = [System.Drawing.Color]::White
    $lv.Anchor        = 'Top,Left,Right,Bottom'
    $lv.Columns.Add('Chat', 340)    | Out-Null
    $lv.Columns.Add('Folder', 150)  | Out-Null
    $lv.Columns.Add('Updated', 140) | Out-Null
    foreach ($s in $sessions) {
        $item = New-Object System.Windows.Forms.ListViewItem($s.Title)
        $item.SubItems.Add($s.Folder) | Out-Null
        $item.SubItems.Add($s.Updated.ToString('d MMM yyyy, HH:mm')) | Out-Null
        $item.Tag = $s
        $lv.Items.Add($item) | Out-Null
    }
    $all.Tag = $lv
    $all.Add_CheckedChanged({ foreach ($i in $this.Tag.Items) { $i.Checked = $this.Checked } })
    $dlg.Controls.Add($lv)

    $lblTo          = New-Object System.Windows.Forms.Label
    $lblTo.Text     = 'Copy to'
    $lblTo.Location = New-Object System.Drawing.Point(16, 356)
    $lblTo.Size     = New-Object System.Drawing.Size(60, 22)
    $lblTo.Anchor   = 'Left,Bottom'
    $dlg.Controls.Add($lblTo)

    $combo               = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = 'DropDownList'
    $combo.Location      = New-Object System.Drawing.Point(78, 352)
    $combo.Size          = New-Object System.Drawing.Size(220, 26)
    $combo.Anchor        = 'Left,Bottom'
    foreach ($t in $targets) { $combo.Items.Add($t.Name) | Out-Null }
    $combo.SelectedIndex = 0
    $dlg.Controls.Add($combo)

    $note           = New-Object System.Windows.Forms.Label
    $note.Text      = 'The chat stays in this account too. Finish a chat in one account before continuing it in the other, since both continue the same history.'
    $note.Font      = $fontSmall
    $note.ForeColor = $muted
    $note.Location  = New-Object System.Drawing.Point(16, 388)
    $note.Size      = New-Object System.Drawing.Size(652, 32)
    $note.Anchor    = 'Left,Right,Bottom'
    $dlg.Controls.Add($note)

    $ok              = New-Object System.Windows.Forms.Button
    $ok.Text         = 'Copy chats'
    $ok.Location     = New-Object System.Drawing.Point(480, 420)
    $ok.Size         = New-Object System.Drawing.Size(92, 32)
    $ok.Anchor       = 'Right,Bottom'
    $ok.DialogResult = 'OK'
    $dlg.Controls.Add($ok)

    $cancel              = New-Object System.Windows.Forms.Button
    $cancel.Text         = 'Cancel'
    $cancel.Location     = New-Object System.Drawing.Point(578, 420)
    $cancel.Size         = New-Object System.Drawing.Size(90, 32)
    $cancel.Anchor       = 'Right,Bottom'
    $cancel.DialogResult = 'Cancel'
    $dlg.Controls.Add($cancel)
    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel

    if ($dlg.ShowDialog($form) -ne 'OK') { return }
    $picked = @($lv.CheckedItems | ForEach-Object { $_.Tag })
    if ($picked.Count -eq 0) { return }
    $target = $targets[$combo.SelectedIndex]

    $store = Get-CodeSessionStore -Target $target
    if (-not $store) {
        Show-Message "'$($target.Name)' has not used Claude Code yet, so there is nowhere to put the chats.`n`nOpen it, sign in, visit the Code tab once, then try again." 'Not ready yet' | Out-Null
        return
    }
    $live = (Get-RunningProfileMap)[$target.Path.TrimEnd('\')]
    if ($live) {
        $go = Show-Message "'$($target.Name)' is open. It may only show the copied chats after you quit and reopen it.`n`nCopy anyway?" 'Account is open' 'YesNo' 'Question'
        if ($go -ne 'Yes') { return }
    }

    $copied = 0; $skipped = 0
    try {
        foreach ($s in $picked) {
            if ((Copy-CodeSession -Session $s -Store $store) -eq 'copied') { $copied++ } else { $skipped++ }
        }
    } catch {
        Show-Message $_.Exception.Message 'Transfer failed' 'OK' 'Error' | Out-Null
        return
    }

    $msg = "Copied $copied chat(s) to '$($target.Name)'."
    if ($skipped) { $msg += " $skipped were already there." }
    $statusLine.Text = $msg
    if ($copied -and -not $live) {
        if ((Show-Message "$msg`n`nOpen '$($target.Name)' now?" 'Chats copied' 'YesNo') -eq 'Yes') { Invoke-LaunchProfile -Target $target }
    } else {
        Show-Message $msg 'Chats copied' | Out-Null
    }
}

# ---- list interaction

$menu = New-Object System.Windows.Forms.ContextMenuStrip
function Add-MenuItem {
    param($Menu, [string]$Text, [scriptblock]$OnClick, [string]$Keys)
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($Text)
    if ($Keys) { $mi.ShortcutKeyDisplayString = $Keys }
    $mi.Add_Click($OnClick)
    $Menu.Items.Add($mi) | Out-Null
    return $mi
}
$miLaunch   = Add-MenuItem $menu 'Launch'                 { $btnLaunch.PerformClick() } 'Enter'
$miLaunch.Font = $fontBold
$null       = Add-MenuItem $menu 'Rename...'              { Invoke-RenameProfile } 'F2'
$null       = Add-MenuItem $menu 'Add shortcuts'          { Invoke-AddShortcuts }
$null       = Add-MenuItem $menu 'Transfer Code chats...' { $btnTransfer.PerformClick() }
$null       = Add-MenuItem $menu 'Open folder'            { Invoke-OpenFolder }
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miDelete   = Add-MenuItem $menu 'Delete'                 { Invoke-DeleteProfile } 'Del'
$menu.Add_Opening({
    $p = Get-SelectedProfile
    if (-not $p) { $_.Cancel = $true; return }
    $miLaunch.Text    = $(if ($p.Pid) { 'Switch to' } else { 'Launch' })
    $miDelete.Enabled = -not $p.IsDefault
})
$listView.ContextMenuStrip = $menu

$btnLaunch.Add_Click({
    $p = Get-SelectedProfile
    if ($p) { Invoke-LaunchProfile -Target $p }
})
$btnNew.Add_Click({ Invoke-AddAccount })
$btnRename.Add_Click({ Invoke-RenameProfile })
$btnShortcut.Add_Click({ Invoke-AddShortcuts })
$btnDelete.Add_Click({ Invoke-DeleteProfile })
$btnTransfer.Add_Click({
    $p = Get-SelectedProfile
    if ($p) { Show-TransferDialog -Source $p }
})

$listView.Add_SelectedIndexChanged({ Update-Buttons })
$listView.Add_DoubleClick({ $btnLaunch.PerformClick() })
$listView.Add_KeyDown({
    # Inside switch, $_ becomes the value being switched on, so keep the event args aside.
    $keyArgs = $_
    switch ($keyArgs.KeyCode) {
        'Enter'  { $btnLaunch.PerformClick() }
        'F2'     { Invoke-RenameProfile }
        'Delete' { Invoke-DeleteProfile }
        'F5'     { Update-List -Force }
        default  { return }
    }
    $keyArgs.Handled = $true
})
$form.Add_KeyDown({
    if ($_.Control -and $_.KeyCode -eq 'N') { Invoke-AddAccount; $_.Handled = $true }
})

# ---- tray

$notify         = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon    = $appIcon
$notify.Text    = 'Claude Profile Switcher'
$trayMenu       = New-Object System.Windows.Forms.ContextMenuStrip
$notify.ContextMenuStrip = $trayMenu

function Show-Switcher {
    $form.Show()
    if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal' }
    # Forced explicitly because a hidden show state can arrive through STARTUPINFO.
    [Native.WinApi]::ShowWindow($form.Handle, $SW_SHOWNORMAL) | Out-Null
    [Native.WinApi]::SetForegroundWindow($form.Handle) | Out-Null
    $form.Activate()
    Update-List
}

function Exit-Switcher {
    $script:ExitRequested = $true
    $notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
}

$trayMenu.Add_Opening({
    $trayMenu.Items.Clear()
    foreach ($p in (Get-ProfileList)) {
        $mi       = New-Object System.Windows.Forms.ToolStripMenuItem($p.Name)
        $mi.Image = $images.Images[(Get-ProfileImageKey -Target $p)]
        # Next to an icon a check mark is barely visible, so open accounts are spelled out.
        if ($p.Pid) { $mi.Font = $fontBold; $mi.ShortcutKeyDisplayString = 'open' }
        $mi.Tag   = $p
        $mi.Add_Click({ Invoke-LaunchProfile -Target $this.Tag })
        $trayMenu.Items.Add($mi) | Out-Null
    }
    $trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $null = Add-MenuItem $trayMenu 'Add account...' { Invoke-AddAccount }
    $null = Add-MenuItem $trayMenu 'Open switcher' { Show-Switcher }
    $boot = Add-MenuItem $trayMenu 'Start with Windows' {
        $lnk = Get-StartupShortcutPath
        if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
        else { New-SwitcherShortcut -Directory (Split-Path $lnk -Parent) -StartInTray | Out-Null }
    }
    $boot.Checked = (Test-Path -LiteralPath (Get-StartupShortcutPath))
    $route = Add-MenuItem $trayMenu 'Send sign-ins to the right account' { Switch-SignInRouting }
    $route.Checked = (Test-SignInRoutingOn)
    $trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $null = Add-MenuItem $trayMenu 'Exit' { Exit-Switcher }
    $_.Cancel = $false
})
$notify.Add_MouseClick({ if ($_.Button -eq 'Left') { Show-Switcher } })

$form.Add_FormClosing({
    if (-not $script:ExitRequested -and $_.CloseReason -eq 'UserClosing' -and $chkTray.Checked) {
        $_.Cancel = $true
        $form.Hide()
        if (-not (Get-Setting 'TrayHintShown')) {
            $notify.ShowBalloonTip(4000, 'Still here', 'The switcher is in the notification area. Right-click it to switch accounts or exit.', 'Info')
            Set-Setting 'TrayHintShown' $true
        }
    }
})
$form.Add_FormClosed({ if (-not $script:ExitRequested) { Exit-Switcher } })

# Status only matters while someone is looking. The tray menu reads it fresh on open.
$refresh = New-Object System.Windows.Forms.Timer
$refresh.Interval = 5000
$refresh.Add_Tick({ Update-List })
$form.Add_VisibleChanged({ if ($form.Visible) { $refresh.Start() } else { $refresh.Stop() } })

$signalTimer = New-Object System.Windows.Forms.Timer
$signalTimer.Interval = 250
$signalTimer.Add_Tick({ if ($script:ShowSignal.WaitOne(0)) { Show-Switcher } })
$signalTimer.Start()

# Fast, for about 25 s after the switcher launches a profile, so the window is tagged
# before it is shown and its taskbar button is created with the right identity.
$watchTimer = New-Object System.Windows.Forms.Timer
$watchTimer.Interval = 150
$watchTimer.Add_Tick({
    for ($i = $script:IdentityWatches.Count - 1; $i -ge 0; $i--) {
        $finished = $true
        try { $finished = Step-IdentityWatch -Watch $script:IdentityWatches[$i] } catch { }
        if ($finished) { $script:IdentityWatches.RemoveAt($i) }
    }
    if ($script:IdentityWatches.Count -eq 0) { $watchTimer.Stop() }
})

# Slow, for profiles started some other way: a shortcut, or Claude restarting itself.
# A full pass asks WMI, so it only runs while the set of Claude processes has changed in
# the last 30 s. The first tick always counts as a change, which tags what is already open.
$script:ClaudeProcessSet  = $null
$script:IdentityPassUntil = [datetime]::MinValue
$identityTimer = New-Object System.Windows.Forms.Timer
$identityTimer.Interval = 4000
$identityTimer.Add_Tick({
    $now = (@(Get-Process -Name Claude -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) | Sort-Object) -join ','
    if ($now -ne $script:ClaudeProcessSet) { $script:ClaudeProcessSet = $now; $script:IdentityPassUntil = (Get-Date).AddSeconds(30) }
    if ((Get-Date) -lt $script:IdentityPassUntil) { try { Update-RunningProfileIdentity } catch { } }
})
$identityTimer.Start()

# Claude rewrites the claude:// key every time an account starts. Two registry reads per
# tick; anything is written only when the handler has actually been lost.
$routerTimer = New-Object System.Windows.Forms.Timer
$routerTimer.Interval = 5000
$routerTimer.Add_Tick({
    if ((Test-SignInRoutingOn) -and -not (Test-RouterRegistered)) {
        try { Register-SignInRouter; Write-RouterLog 'Took the claude:// handler back.' } catch { }
    }
})
$routerTimer.Start()

# Left behind by -Revert while the router was still the Default apps choice. Once the user
# has picked something else, nothing points at it any more.
if (-not (Test-SignInRoutingOn) -and (Test-Path -LiteralPath (Get-RouterRegistryPath).ProgId)) {
    try { if ((Get-LinkHandlerProgId) -ne $script:RouterProgId) { Unregister-SignInRouter | Out-Null } } catch { }
}

$script:ExitRequested = $false
$notify.Visible = $true
Update-List -Force
if (-not $Tray) { Show-Switcher }
try {
    [System.Windows.Forms.Application]::Run()
} finally {
    $notify.Visible = $false
    $notify.Dispose()
    try { $script:InstanceMutex.ReleaseMutex() } catch { }
}
