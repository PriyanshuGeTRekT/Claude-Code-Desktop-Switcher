# ClaudeProfileLib.ps1 - shared code for ClaudeSwitcher.ps1 and ClaudeAuthRouter.ps1.
# Dot-source it; it defines functions and $script: state, and runs nothing on its own.
#
# Kept ASCII only: without a BOM, Windows PowerShell 5.1 reads this file using the
# system codepage, so non-ASCII here renders as garbage on other locales.

Set-StrictMode -Off

# ------------------------------------------------------------------- layout --
#
#   %LOCALAPPDATA%\ClaudeProfiles\<Name>\   one folder per extra profile (Claude's data)
#   %LOCALAPPDATA%\ClaudeProfiles\settings.json   this tool's settings (pre-existing location)
#   %LOCALAPPDATA%\ClaudeProfileSwitcher\   everything this tool generates, so it can be
#                                           removed in one go and never shows up as a profile
#
$script:ProfileRoot  = Join-Path $env:LOCALAPPDATA 'ClaudeProfiles'
$script:SettingsPath = Join-Path $script:ProfileRoot 'settings.json'
$script:ToolRoot     = Join-Path $env:LOCALAPPDATA 'ClaudeProfileSwitcher'
$script:IconDir      = Join-Path $script:ToolRoot 'icons'
$script:MarkerPath   = Join-Path $script:ToolRoot 'pending-login.json'
$script:BackupPath   = Join-Path $script:ToolRoot 'protocol-backup.json'
$script:RouterLog    = Join-Path $script:ToolRoot 'auth-router.log'
$script:ErrorLog     = Join-Path $script:ToolRoot 'switcher-error.log'
$script:DefaultName  = 'Default'
$script:LibDir       = Split-Path $MyInvocation.MyCommand.Path -Parent
$script:RouterScript = Join-Path $script:LibDir 'ClaudeAuthRouter.ps1'
$script:SwitcherScript = Join-Path $script:LibDir 'ClaudeSwitcher.ps1'
$script:Scheme       = 'claude'
$script:AumidPrefix  = 'Anthropic.Claude.Profile.'

$script:Palette = @(
    @{ Name = 'Blue';   Hex = '#1A73E8' }, @{ Name = 'Red';    Hex = '#D93025' },
    @{ Name = 'Green';  Hex = '#188038' }, @{ Name = 'Orange'; Hex = '#E37400' },
    @{ Name = 'Purple'; Hex = '#9334E6' }, @{ Name = 'Teal';   Hex = '#00838F' },
    @{ Name = 'Indigo'; Hex = '#3949AB' }, @{ Name = 'Slate';  Hex = '#5F6368' },
    @{ Name = 'Pink';   Hex = '#D01884' }, @{ Name = 'Amber';  Hex = '#F9AB00' }
)

# ----------------------------------------------------------------- settings --

function Get-Setting {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return $null }
    try { return (Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json).$Name } catch { return $null }
}

function Set-Setting {
    param([Parameter(Mandatory)][string]$Name, $Value)
    $bag = [ordered]@{}
    if (Test-Path -LiteralPath $script:SettingsPath) {
        try {
            (Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json).PSObject.Properties |
                ForEach-Object { $bag[$_.Name] = $_.Value }
        } catch { }
    }
    if ($null -eq $Value) { $bag.Remove($Name) } else { $bag[$Name] = $Value }
    New-Item -ItemType Directory -Force -Path $script:ProfileRoot | Out-Null
    ($bag | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
}

# ---------------------------------------------------------- install detection --

function New-InstallInfo {
    param([string]$Kind, [string]$Exe, [string]$Version, [string]$AppUserModelId, [string]$DefaultProfilePath)
    return [pscustomobject]@{
        Kind               = $Kind
        Exe                = $Exe
        Version            = $Version
        AppUserModelId     = $AppUserModelId
        DefaultProfilePath = $DefaultProfilePath
        InstallRoot        = (Split-Path $Exe -Parent)
    }
}

<#
    Claude ships in two shapes on Windows and they keep their data in different places:
      Store / MSIX  - the package container redirects %APPDATA%\Claude to
                      %LOCALAPPDATA%\Packages\<family>\LocalCache\Roaming\Claude
      Installer     - a plain Electron app (Squirrel) using %APPDATA%\Claude directly
    Resolved fresh on every run, because the installer path contains the version number.
#>
function Resolve-ClaudeInstall {
    param([string]$Override)

    $manual = $Override
    if ([string]::IsNullOrWhiteSpace($manual)) { $manual = Get-Setting 'ClaudePath' }
    if ($manual -and (Test-Path -LiteralPath $manual)) {
        return New-InstallInfo 'Classic' $manual 'unknown' $null (Join-Path $env:APPDATA 'Claude')
    }

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
        # Prefer the Squirrel stub at the root: it survives updates and forwards arguments.
        $exe = Join-Path $dir 'Claude.exe'
        if (-not (Test-Path -LiteralPath $exe)) {
            $exe = Get-ChildItem -LiteralPath $dir -Filter 'Claude.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        }
        if ($exe -and (Test-Path -LiteralPath $exe)) {
            return New-InstallInfo 'Classic' $exe 'unknown' $null (Join-Path $env:APPDATA 'Claude')
        }
    }

    throw "Could not find the Claude desktop app on this computer.`r`n`r`nIf it is installed somewhere unusual, point at it once and the choice is remembered:`r`n    .\ClaudeSwitcher.ps1 -ClaudePath `"C:\path\to\Claude.exe`""
}

function Initialize-ClaudeLib {
    param([string]$ClaudePathOverride, [switch]$NoCache)

    # Get-AppxPackage alone can take 10+ seconds, so the answer is remembered in
    # settings.json and only recomputed when the remembered exe has gone away.
    $cached = if ($NoCache -or $ClaudePathOverride) { $null } else { Get-Setting 'Install' }
    if ($cached -and $cached.Exe -and (Test-Path -LiteralPath $cached.Exe)) {
        $script:ClaudeApp = New-InstallInfo $cached.Kind $cached.Exe $cached.Version $cached.AppUserModelId $cached.DefaultProfilePath
    } else {
        $script:ClaudeApp = Resolve-ClaudeInstall -Override $ClaudePathOverride
        Set-Setting 'Install' ([pscustomobject]@{
            Kind = $script:ClaudeApp.Kind; Exe = $script:ClaudeApp.Exe; Version = $script:ClaudeApp.Version
            AppUserModelId = $script:ClaudeApp.AppUserModelId; DefaultProfilePath = $script:ClaudeApp.DefaultProfilePath
        })
    }
    $script:ClaudeExe          = $script:ClaudeApp.Exe
    $script:DefaultProfilePath = $script:ClaudeApp.DefaultProfilePath
    if ($ClaudePathOverride) { Set-Setting 'ClaudePath' $script:ClaudeApp.Exe }
}

# Squirrel leaves app.ico next to the stub; otherwise pull from the exe.
function Resolve-ClaudeIconSource {
    $ico = Join-Path $script:ClaudeApp.InstallRoot 'app.ico'
    if (Test-Path -LiteralPath $ico) { return $ico }
    return $script:ClaudeExe
}

# --------------------------------------------------------------- appearance --
#
# settings.json holds a "Profiles" map:  { "<Name>": { "Label": "...", "Color": "#rrggbb", "Badge": "S" } }
# Every field is optional; missing ones get stable defaults derived from the folder name.

function Get-DefaultColor {
    param([string]$Name)
    # FNV-1a in uint64: a uint32 multiply promotes to Double in PowerShell and loses
    # precision, and the literal 0xFFFFFFFF parses as Int32 -1, so mask with 0xFFFFFFFFL.
    $h = [uint64]2166136261
    foreach ($c in $Name.ToCharArray()) {
        $h = ($h -bxor [uint64][int]$c)
        $h = (($h * [uint64]16777619) -band 0xFFFFFFFFL)
    }
    return $script:Palette[[int]([uint32]$h % [uint32]$script:Palette.Count)].Hex
}

function Get-ProfileAppearance {
    param([Parameter(Mandatory)][string]$Name)
    $all = Get-Setting 'Profiles'
    $entry = if ($all) { $all.$Name } else { $null }
    $label = if ($entry -and $entry.Label) { [string]$entry.Label } else { $Name }
    $color = if ($entry -and $entry.Color -match '^#[0-9A-Fa-f]{6}$') { [string]$entry.Color } else { Get-DefaultColor $Name }
    $badge = if ($entry -and $entry.Badge) { [string]$entry.Badge } else { $label.Substring(0, 1).ToUpper() }
    if ($badge.Length -gt 2) { $badge = $badge.Substring(0, 2) }
    # TagDefault: opt-in for the Default profile to get a badge and its own taskbar
    # identity too. Off by default because a pinned Claude icon then stops matching it.
    $tagDefault = [bool]($entry -and $entry.TagDefault)
    return [pscustomobject]@{ Name = $Name; Label = $label; Color = $color; Badge = $badge; TagDefault = $tagDefault }
}

function Test-ProfileTaggable {
    # Extra profiles always; Default only when the user opted in.
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -ne $script:DefaultName) { return $true }
    return (Get-ProfileAppearance -Name $Name).TagDefault
}

function Set-ProfileAppearance {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Label, [string]$Color, [string]$Badge,
        [object]$TagDefault
    )
    $all = Get-Setting 'Profiles'
    $bag = [ordered]@{}
    if ($all) { $all.PSObject.Properties | ForEach-Object { $bag[$_.Name] = $_.Value } }
    $entry = [ordered]@{}
    if ($bag.Contains($Name) -and $bag[$Name]) { $bag[$Name].PSObject.Properties | ForEach-Object { $entry[$_.Name] = $_.Value } }
    if ($PSBoundParameters.ContainsKey('Label')) { if ($Label) { $entry['Label'] = $Label.Trim() } else { $entry.Remove('Label') } }
    if ($PSBoundParameters.ContainsKey('Color')) { if ($Color) { $entry['Color'] = $Color } else { $entry.Remove('Color') } }
    if ($PSBoundParameters.ContainsKey('Badge')) { if ($Badge) { $entry['Badge'] = $Badge.Trim() } else { $entry.Remove('Badge') } }
    if ($PSBoundParameters.ContainsKey('TagDefault')) { if ($TagDefault) { $entry['TagDefault'] = $true } else { $entry.Remove('TagDefault') } }
    if ($entry.Count -eq 0) { $bag.Remove($Name) } else { $bag[$Name] = [pscustomobject]$entry }
    Set-Setting 'Profiles' $(if ($bag.Count) { [pscustomobject]$bag } else { $null })
    # Icons are derived from appearance; drop every old variant for this profile.
    Remove-ProfileIcon -Name $Name
}

function Test-ProfileLabel {
    param([string]$Label)
    if ([string]::IsNullOrWhiteSpace($Label)) { return 'Name cannot be empty.' }
    if ($Label.Length -gt 40)                 { return 'Name is too long (40 characters max).' }
    return $null
}

# ----------------------------------------------------------------- profiles --

function Get-ProfilePath {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -eq $script:DefaultName) { return $script:DefaultProfilePath }
    return (Join-Path $script:ProfileRoot $Name)
}

function Get-ClaudeMainProcess {
    # Main (window-owning) processes of the desktop app only. Two filters matter:
    #   --type=        excludes Electron's renderer/gpu/utility children
    #   ExecutablePath excludes Claude Code's CLI, which is also called claude.exe
    # Command lines are read straight from each process (see Native.ListProcesses);
    # WMI would give the same answer but costs 0.6-2 s per call.
    $root = $script:ClaudeApp.InstallRoot
    foreach ($p in [ClaudeProfiles.Native]::ListProcesses('Claude')) {
        if (-not $p.CommandLine -or $p.CommandLine -match '--type=') { continue }
        if (-not $p.ExecutablePath -or -not $p.ExecutablePath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { continue }
        [pscustomobject]@{ ProcessId = $p.ProcessId; ExecutablePath = $p.ExecutablePath; CommandLine = $p.CommandLine }
    }
}

function Get-RunningProfileMap {
    # profile directory -> PID of its main process
    $map = @{}
    foreach ($p in (Get-ClaudeMainProcess)) {
        if ($p.CommandLine -match '--user-data-dir="?([^"]+?)"?(\s|$)') {
            $key = $Matches[1].TrimEnd('\')
        } else {
            $key = $script:DefaultProfilePath.TrimEnd('\')
        }
        if (-not $map.ContainsKey($key)) { $map[$key] = [int]$p.ProcessId }
    }
    return $map
}

function Test-ProfileSignedIn {
    # $true / $false, or $null when there is no config.json to read yet.
    # Observed on a real install: signing out flips windowSizeWasSignedIn to false and
    # shrinks oauth:tokenCacheV2 to a 44-char placeholder (it is ~1400-2200 signed in).
    # Only key presence and value length are read; never the token itself.
    param([Parameter(Mandatory)][string]$Path)
    $cfg = Join-Path $Path 'config.json'
    if (-not (Test-Path -LiteralPath $cfg)) { return $null }
    try {
        $j = Get-Content -LiteralPath $cfg -Raw -ErrorAction Stop | ConvertFrom-Json
        $names = $j.PSObject.Properties.Name
        if ($names -contains 'windowSizeWasSignedIn') { return [bool]$j.windowSizeWasSignedIn }
        if ($names -contains 'oauth:tokenCacheV2') { return ([string]$j.'oauth:tokenCacheV2').Length -gt 100 }
        return $false
    } catch { return $null }
}

function Get-ProfileList {
    $running = Get-RunningProfileMap
    $result  = New-Object System.Collections.Generic.List[object]

    $add = {
        param($Name, $Path, $IsDefault)
        $exists = Test-Path -LiteralPath $Path
        $look = Get-ProfileAppearance -Name $Name
        $result.Add([pscustomobject]@{
            Name      = $Name
            Label     = $look.Label
            Color     = $look.Color
            Badge     = $look.Badge
            TagDefault= $look.TagDefault
            Path      = $Path
            IsDefault = $IsDefault
            Exists    = $exists
            Pid       = $running[$Path.TrimEnd('\')]
            SignedIn  = $(if ($exists) { Test-ProfileSignedIn -Path $Path } else { $null })
            LastUsed  = $(if ($exists) { (Get-Item -LiteralPath $Path -Force).LastWriteTime } else { $null })
        })
    }

    & $add $script:DefaultName $script:DefaultProfilePath $true
    if (Test-Path -LiteralPath $script:ProfileRoot) {
        Get-ChildItem -LiteralPath $script:ProfileRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '.*' } |   # never treat a hidden/tool folder as a profile
            Sort-Object Name | ForEach-Object { & $add $_.Name $_.FullName $false }
    }
    return $result
}

function Test-ProfileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name))        { return 'Name cannot be empty.' }
    if ($Name -eq $script:DefaultName)              { return "'$($script:DefaultName)' is reserved for your existing account." }
    if ($Name -match '[\\/:*?"<>|]')                { return 'Name cannot contain \ / : * ? " < > |' }
    if ($Name.StartsWith('.'))                      { return 'Name cannot start with a dot.' }
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

function Remove-ClaudeProfile {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -eq $script:DefaultName) { throw 'The Default profile cannot be deleted.' }
    $path = Join-Path $script:ProfileRoot $Name
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    Set-ProfileAppearance -Name $Name -Label '' -Color '' -Badge ''
    Remove-ProfileIcon -Name $Name
}

# ------------------------------------------------------------------ interop --

$script:NativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace ClaudeProfiles
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PropertyKey
    {
        public Guid fmtid; public uint pid;
        public PropertyKey(Guid g, uint p) { fmtid = g; pid = p; }
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore
    {
        int GetCount(out uint cProps);
        int GetAt(uint iProp, out PropertyKey pkey);
        int GetValue(ref PropertyKey key, IntPtr pv);
        int SetValue(ref PropertyKey key, IntPtr pv);
        int Commit();
    }

    [ComImport, Guid("0000010b-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPersistFile
    {
        int GetClassID(out Guid pClassID);
        int IsDirty();
        int Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
        int Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, bool fRemember);
        int SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
        int GetCurFile(out IntPtr ppszFileName);
    }

    [ComImport, Guid("56FDF342-FD6D-11d0-958A-006097C9A090"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ITaskbarList
    {
        int HrInit(); int AddTab(IntPtr hwnd); int DeleteTab(IntPtr hwnd);
        int ActivateTab(IntPtr hwnd); int SetActiveAlt(IntPtr hwnd);
    }

    [ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090")] public class TaskbarInstance { }
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")] public class ShellLinkInstance { }

    public static class Native
    {
        public static readonly Guid AppUserModel = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
        public const uint PID_RELAUNCHCMD = 2, PID_RELAUNCHICON = 3, PID_RELAUNCHNAME = 4, PID_ID = 5;
        const short VT_LPWSTR = 31;
        const uint WM_SETICON = 0x0080, GW_OWNER = 4;
        const int GWL_EXSTYLE = -20;
        const long WS_EX_TOOLWINDOW = 0x80L;

        public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
        [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")] static extern IntPtr GetWindowLongPtr64(IntPtr h, int i);
        [DllImport("user32.dll", EntryPoint = "GetWindowLong")] static extern int GetWindowLong32(IntPtr h, int i);
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int PrivateExtractIcons(string file, int index, int cx, int cy, IntPtr[] phicon, int[] piconid, int nIcons, int flags);
        [DllImport("shell32.dll", PreserveSig = false)]
        static extern void SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
        [DllImport("ole32.dll")] static extern int PropVariantClear(IntPtr pvar);

        static long ExStyle(IntPtr h)
        {
            return IntPtr.Size == 8 ? GetWindowLongPtr64(h, GWL_EXSTYLE).ToInt64() : (long)GetWindowLong32(h, GWL_EXSTYLE);
        }

        static string ClassOf(IntPtr h)
        {
            var sb = new StringBuilder(64); GetClassName(h, sb, sb.Capacity); return sb.ToString();
        }

        /// Top-level, un-owned, non-tool windows of a process, in Z order (front first).
        /// includeHidden also returns windows Electron has created but not yet shown,
        /// which is the moment to set an AUMID: the taskbar button does not exist yet.
        public static IntPtr[] WindowsForPid(uint pid, bool includeHidden)
        {
            var found = new List<IntPtr>();
            EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                uint wpid; GetWindowThreadProcessId(h, out wpid);
                if (wpid != pid) return true;
                if (!includeHidden && !IsWindowVisible(h)) return true;
                if (GetWindow(h, GW_OWNER) != IntPtr.Zero) return true;
                if ((ExStyle(h) & WS_EX_TOOLWINDOW) != 0) return true;
                if (ClassOf(h) != "Chrome_WidgetWin_1") return true;
                if (!includeHidden && GetWindowTextLength(h) == 0) return true;
                found.Add(h);
                return true;
            }, IntPtr.Zero);
            return found.ToArray();
        }

        /// PID of the frontmost visible window among the given processes, or 0.
        public static uint FrontmostPid(uint[] pids)
        {
            uint result = 0;
            EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                uint wpid; GetWindowThreadProcessId(h, out wpid);
                if (Array.IndexOf(pids, wpid) < 0) return true;
                if (!IsWindowVisible(h) || GetWindow(h, GW_OWNER) != IntPtr.Zero) return true;
                if (GetWindowTextLength(h) == 0) return true;
                result = wpid;
                return false;
            }, IntPtr.Zero);
            return result;
        }

        public static bool IsVisible(IntPtr h) { return IsWindowVisible(h); }

        public static string TitleOf(IntPtr h)
        {
            int n = GetWindowTextLength(h); if (n == 0) return "";
            var sb = new StringBuilder(n + 1); GetWindowText(h, sb, sb.Capacity); return sb.ToString();
        }

        // PROPVARIANT is built by hand (InitPropVariantFromString is an inline SDK
        // helper, not an export): vt at offset 0, string pointer at offset 8.
        static void SetString(IPropertyStore store, uint propId, string value)
        {
            var key = new PropertyKey(AppUserModel, propId);
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

        static string GetString(IPropertyStore store, uint propId)
        {
            var key = new PropertyKey(AppUserModel, propId);
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

        public static void SetWindowIdentity(IntPtr hwnd, string aumid, string relaunchCmd, string displayName, string iconRes)
        {
            Guid iid = typeof(IPropertyStore).GUID; IPropertyStore store;
            SHGetPropertyStoreForWindow(hwnd, ref iid, out store);
            try
            {
                SetString(store, PID_ID, aumid);
                SetString(store, PID_RELAUNCHCMD, relaunchCmd);
                SetString(store, PID_RELAUNCHNAME, displayName);
                SetString(store, PID_RELAUNCHICON, iconRes);
                Marshal.ThrowExceptionForHR(store.Commit());
            }
            finally { Marshal.ReleaseComObject(store); }
        }

        public static string GetWindowAumid(IntPtr hwnd)
        {
            Guid iid = typeof(IPropertyStore).GUID; IPropertyStore store;
            SHGetPropertyStoreForWindow(hwnd, ref iid, out store);
            try { return GetString(store, PID_ID); }
            finally { Marshal.ReleaseComObject(store); }
        }

        /// Stamp an AUMID on a .lnk so a pinned copy of it groups with the profile's window.
        public static void SetShortcutAumid(string lnkPath, string aumid)
        {
            object link = new ShellLinkInstance();
            try
            {
                var pf = (IPersistFile)link;
                Marshal.ThrowExceptionForHR(pf.Load(lnkPath, 0x00000002 /* STGM_READWRITE */));
                var store = (IPropertyStore)link;
                SetString(store, PID_ID, aumid);
                Marshal.ThrowExceptionForHR(store.Commit());
                Marshal.ThrowExceptionForHR(pf.Save(lnkPath, true));
            }
            finally { Marshal.ReleaseComObject(link); }
        }

        /// Windows reads the AUMID when it creates the taskbar button, so a live window
        /// keeps its old grouping until the button is rebuilt. Only for visible windows:
        /// AddTab on a hidden one would create a phantom button.
        public static void RebuildTaskbarButton(IntPtr hwnd)
        {
            var tb = (ITaskbarList)new TaskbarInstance();
            try { tb.HrInit(); tb.DeleteTab(hwnd); tb.AddTab(hwnd); }
            finally { Marshal.ReleaseComObject(tb); }
        }

        public static void ApplyIcon(IntPtr hwnd, IntPtr small, IntPtr big)
        {
            SendMessage(hwnd, WM_SETICON, (IntPtr)0, small);
            SendMessage(hwnd, WM_SETICON, (IntPtr)1, big);
        }

        public static IntPtr ExtractIconAt(string file, int size)
        {
            var h = new IntPtr[1]; var ids = new int[1];
            return PrivateExtractIcons(file, 0, size, size, h, ids, 1, 0) > 0 ? h[0] : IntPtr.Zero;
        }

        // ---- process listing without WMI -------------------------------------
        // Command line comes from the target's PEB (RTL_USER_PROCESS_PARAMETERS),
        // which is the same place WMI reads it from, minus the management stack.

        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_BASIC_INFORMATION
        {
            public IntPtr Reserved1; public IntPtr PebBaseAddress; public IntPtr Reserved2_0;
            public IntPtr Reserved2_1; public IntPtr UniqueProcessId; public IntPtr Reserved3;
        }

        [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PROCESS_BASIC_INFORMATION pbi, int len, out int ret);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder exe, ref int size);

        const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000, PROCESS_VM_READ = 0x0010;

        public class ProcInfo { public uint ProcessId; public string ExecutablePath; public string CommandLine; }

        static IntPtr ReadPtr(IntPtr h, IntPtr addr)
        {
            var b = new byte[IntPtr.Size]; IntPtr n;
            if (!ReadProcessMemory(h, addr, b, (IntPtr)b.Length, out n)) return IntPtr.Zero;
            return IntPtr.Size == 8 ? (IntPtr)BitConverter.ToInt64(b, 0) : (IntPtr)BitConverter.ToInt32(b, 0);
        }

        static string ReadCommandLine(IntPtr h)
        {
            var pbi = new PROCESS_BASIC_INFORMATION(); int ret;
            if (NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(pbi), out ret) != 0) return null;
            // PEB.ProcessParameters, then RTL_USER_PROCESS_PARAMETERS.CommandLine (UNICODE_STRING)
            int ppOff = IntPtr.Size == 8 ? 0x20 : 0x10, clOff = IntPtr.Size == 8 ? 0x70 : 0x40;
            IntPtr pp = ReadPtr(h, (IntPtr)(pbi.PebBaseAddress.ToInt64() + ppOff));
            if (pp == IntPtr.Zero) return null;
            var us = new byte[IntPtr.Size == 8 ? 16 : 8]; IntPtr n;
            if (!ReadProcessMemory(h, (IntPtr)(pp.ToInt64() + clOff), us, (IntPtr)us.Length, out n)) return null;
            int len = BitConverter.ToUInt16(us, 0);
            IntPtr buf = IntPtr.Size == 8 ? (IntPtr)BitConverter.ToInt64(us, 8) : (IntPtr)BitConverter.ToInt32(us, 4);
            if (len == 0 || buf == IntPtr.Zero) return "";
            var chars = new byte[len];
            if (!ReadProcessMemory(h, buf, chars, (IntPtr)len, out n)) return null;
            return Encoding.Unicode.GetString(chars, 0, (int)n);
        }

        public static ProcInfo[] ListProcesses(string name)
        {
            var list = new List<ProcInfo>();
            foreach (var p in System.Diagnostics.Process.GetProcessesByName(name))
            {
                IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, false, (uint)p.Id);
                if (h == IntPtr.Zero) { p.Dispose(); continue; }
                try
                {
                    var sb = new StringBuilder(1024); int cap = sb.Capacity;
                    string exe = QueryFullProcessImageName(h, 0, sb, ref cap) ? sb.ToString() : null;
                    list.Add(new ProcInfo { ProcessId = (uint)p.Id, ExecutablePath = exe, CommandLine = ReadCommandLine(h) });
                }
                finally { CloseHandle(h); p.Dispose(); }
            }
            return list.ToArray();
        }
    }
}
'@

function Import-NativeType {
    # Compiling the C# above costs ~6 s on every run. Compile once to a DLL named by a
    # hash of the source and load that; a source change gets a new name automatically.
    if ('ClaudeProfiles.Native' -as [type]) { return }
    $md5  = [System.Security.Cryptography.MD5]::Create()
    $hash = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:NativeSource))).Replace('-', '').Substring(0, 12)
    $dll  = Join-Path $script:ToolRoot "native-$hash.dll"
    if (-not (Test-Path -LiteralPath $dll)) {
        New-Item -ItemType Directory -Force -Path $script:ToolRoot | Out-Null
        Get-ChildItem -LiteralPath $script:ToolRoot -Filter 'native-*.dll' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        try { Add-Type -Language CSharp -TypeDefinition $script:NativeSource -OutputAssembly $dll -OutputType Library | Out-Null }
        catch { Add-Type -Language CSharp -TypeDefinition $script:NativeSource | Out-Null; return }   # e.g. folder not writable
    }
    # Loaded from bytes so the file is never locked; -Revert can then delete the folder.
    [void][System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($dll))
}
Import-NativeType

# -------------------------------------------------------------------- icons --

function New-BadgedBitmap {
    param([Parameter(Mandatory)]$Look, [int]$Size)
    Add-Type -AssemblyName System.Drawing
    $col = [System.Drawing.ColorTranslator]::FromHtml($Look.Color)
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)

    $hIcon = [ClaudeProfiles.Native]::ExtractIconAt((Resolve-ClaudeIconSource), $Size)
    if ($hIcon -ne [IntPtr]::Zero) {
        $ico = [System.Drawing.Icon]::FromHandle($hIcon)
        $base = $ico.ToBitmap()
        $g.DrawImage($base, 0, 0, $Size, $Size)
        $base.Dispose(); $ico.Dispose()
        [void][ClaudeProfiles.Native]::DestroyIcon($hIcon)
    }

    # Small sizes get a proportionally larger badge so the letter stays legible.
    $ratio = if ($Size -le 24) { 0.62 } elseif ($Size -le 48) { 0.52 } else { 0.48 }
    $d    = [int]($Size * $ratio)
    $x    = $Size - $d
    $y    = $Size - $d
    $ring = [Math]::Max(1, [int]($Size * 0.055))
    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 255, 255, 255))
    $fill  = New-Object System.Drawing.SolidBrush($col)
    $g.FillEllipse($white, ($x - $ring), ($y - $ring), ($d + 2 * $ring), ($d + 2 * $ring))
    $g.FillEllipse($fill, $x, $y, $d, $d)
    $white.Dispose(); $fill.Dispose()

    if ($Size -ge 16) {
        $scale = if ($Look.Badge.Length -gt 1) { 0.5 } else { 0.7 }
        $font = New-Object System.Drawing.Font('Segoe UI', [float]($d * $scale), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
        $g.DrawString($Look.Badge, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF($x, $y, $d, $d)), $fmt)
        $font.Dispose(); $fmt.Dispose()
    }
    $g.Dispose()
    return $bmp
}

# The switcher's own icon: Claude's mark with a slate badge holding two dots, so the
# switcher window is told apart from any Claude window on the taskbar.
function New-SwitcherBitmap {
    param([int]$Size)
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'
    $g.Clear([System.Drawing.Color]::Transparent)
    $hIcon = [ClaudeProfiles.Native]::ExtractIconAt((Resolve-ClaudeIconSource), $Size)
    if ($hIcon -ne [IntPtr]::Zero) {
        $ico = [System.Drawing.Icon]::FromHandle($hIcon); $base = $ico.ToBitmap()
        $g.DrawImage($base, 0, 0, $Size, $Size); $base.Dispose(); $ico.Dispose()
        [void][ClaudeProfiles.Native]::DestroyIcon($hIcon)
    }
    $ratio = if ($Size -le 24) { 0.62 } elseif ($Size -le 48) { 0.52 } else { 0.48 }
    $d = [int]($Size * $ratio); $x = $Size - $d; $y = $Size - $d
    $ring = [Math]::Max(1, [int]($Size * 0.055))
    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 255, 255, 255))
    $fill  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(95, 99, 104))
    $g.FillEllipse($white, ($x - $ring), ($y - $ring), ($d + 2 * $ring), ($d + 2 * $ring))
    $g.FillEllipse($fill, $x, $y, $d, $d)
    # two dots side by side = several accounts
    $r = [Math]::Max(1, [int]($d * 0.2)); $cy = $y + [int]($d / 2) - $r
    $g.FillEllipse($white, ($x + [int]($d * 0.22)), $cy, (2 * $r), (2 * $r))
    $g.FillEllipse($white, ($x + [int]($d * 0.58)), $cy, (2 * $r), (2 * $r))
    $white.Dispose(); $fill.Dispose(); $g.Dispose()
    return $bmp
}

# PNG-compressed .ico (Vista+): 6-byte header, 16-byte entry per image, then the PNGs.
function Save-Ico {
    param([Parameter(Mandatory)][scriptblock]$Draw, [Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.Drawing
    $blobs = @()
    foreach ($s in @(16, 24, 32, 48, 64, 256)) {
        $bmp = & $Draw $s
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $blobs += ,@{ Size = $s; Bytes = $ms.ToArray() }
        $ms.Dispose(); $bmp.Dispose()
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    $fs = [System.IO.File]::Create($Path)
    $bw = New-Object System.IO.BinaryWriter($fs)
    try {
        $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$blobs.Count)
        $offset = 6 + (16 * $blobs.Count)
        foreach ($b in $blobs) {
            $dim = if ($b.Size -ge 256) { 0 } else { $b.Size }
            $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
            $bw.Write([uint16]1); $bw.Write([uint16]32)
            $bw.Write([uint32]$b.Bytes.Length); $bw.Write([uint32]$offset)
            $offset += $b.Bytes.Length
        }
        foreach ($b in $blobs) { $bw.Write($b.Bytes) }
    } finally { $bw.Dispose(); $fs.Dispose() }
    return $Path
}

function Save-ProfileIco {
    param([Parameter(Mandatory)]$Look, [Parameter(Mandatory)][string]$Path)
    Save-Ico -Path $Path -Draw { param($sz) New-BadgedBitmap -Look $Look -Size $sz }
}

function Get-SwitcherIcoPath {
    $p = Join-Path $script:IconDir 'switcher.ico'
    if (-not (Test-Path -LiteralPath $p)) { Save-Ico -Path $p -Draw { param($sz) New-SwitcherBitmap -Size $sz } | Out-Null }
    return $p
}

function Get-AppearanceTag {
    # Six hex chars derived from colour + badge. Used in both the icon file name and the
    # taskbar identity, so a change of look is a new file and a new identity: the Windows
    # 11 taskbar reads a group's icon once per identity and never refreshes it.
    param([Parameter(Mandatory)]$Look)
    return [BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash(
        [Text.Encoding]::UTF8.GetBytes("$($Look.Color)|$($Look.Badge)"))).Replace('-', '').Substring(0, 6).ToLower()
}

function Get-ProfileIcoPath {
    param([Parameter(Mandatory)][string]$Name, [switch]$NoCreate)
    $look = Get-ProfileAppearance -Name $Name
    $tag  = Get-AppearanceTag -Look $look
    $p = Join-Path $script:IconDir (($Name -replace '[^\w\-]', '_') + "-$tag.ico")
    if (-not $NoCreate -and -not (Test-Path -LiteralPath $p)) {
        Save-ProfileIco -Look $look -Path $p | Out-Null
    }
    return $p
}

function Remove-ProfileIcon {
    param([Parameter(Mandatory)][string]$Name)
    $stem = ($Name -replace '[^\w\-]', '_')
    if (Test-Path -LiteralPath $script:IconDir) {
        Get-ChildItem -LiteralPath $script:IconDir -Filter "$stem-*.ico" -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# ----------------------------------------------------------------- identity --
#
# Default is deliberately never touched: it keeps Claude's own AppUserModelID so an
# existing pinned Claude icon still matches it. Only extra profiles get identities.

function Get-ProfileAumid {
    # Includes the appearance tag: see Get-AppearanceTag for why.
    param([Parameter(Mandatory)][string]$Name)
    $tag = Get-AppearanceTag -Look (Get-ProfileAppearance -Name $Name)
    return $script:AumidPrefix + ($Name -replace '[^\w\.]', '_') + '.' + $tag
}

function Get-HeadlessLauncher {
    # conhost --headless runs a console program with no window at all, which avoids
    # the flash powershell.exe -WindowStyle Hidden always shows. Present since Win10 1809.
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $ps      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ([Environment]::OSVersion.Version.Build -ge 17763 -and (Test-Path -LiteralPath $conhost)) {
        return [pscustomobject]@{ Exe = $conhost; Prefix = "--headless `"$ps`" -NoProfile -ExecutionPolicy Bypass" }
    }
    return [pscustomobject]@{ Exe = $ps; Prefix = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass' }
}

function Get-ProfileRelaunchCommand {
    param([Parameter(Mandatory)][string]$Name)
    $l = Get-HeadlessLauncher
    return ('"{0}" {1} -File "{2}" -Launch "{3}"' -f $l.Exe, $l.Prefix, $script:SwitcherScript, $Name)
}

$script:IconHandles = @{}
$script:RetiredIcons = New-Object System.Collections.Generic.List[IntPtr]

function Set-WindowIdentity {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][IntPtr]$Hwnd)
    if (-not (Test-ProfileTaggable -Name $Name)) { return }
    if ($Name -eq $script:DefaultName -and -not (Get-Setting 'DefaultOriginalAumid')) {
        # Remember what Claude set, so the option can be turned off cleanly later.
        $orig = try { [ClaudeProfiles.Native]::GetWindowAumid($Hwnd) } catch { $null }
        if ($orig -and $orig -notlike "$($script:AumidPrefix)*") { Set-Setting 'DefaultOriginalAumid' $orig }
    }
    $look  = Get-ProfileAppearance -Name $Name
    $ico   = Get-ProfileIcoPath -Name $Name
    $aumid = Get-ProfileAumid -Name $Name

    [ClaudeProfiles.Native]::SetWindowIdentity($Hwnd, $aumid, (Get-ProfileRelaunchCommand -Name $Name), "Claude - $($look.Label)", "$ico,0")

    if (-not $script:IconHandles.ContainsKey($Name)) {
        # Windows 11 applies WM_SETICON icons below a DPI-dependent size to the window
        # frame only and leaves the taskbar untouched; a 256 px icon updates both.
        $small = New-BadgedBitmap -Look $look -Size 256
        $big   = New-BadgedBitmap -Look $look -Size 256
        $script:IconHandles[$Name] = @{ Small = $small.GetHicon(); Big = $big.GetHicon() }
        $small.Dispose(); $big.Dispose()
    }
    $h = $script:IconHandles[$Name]
    [ClaudeProfiles.Native]::ApplyIcon($Hwnd, $h.Small, $h.Big)
    if ([ClaudeProfiles.Native]::IsVisible($Hwnd)) { [ClaudeProfiles.Native]::RebuildTaskbarButton($Hwnd) }
}

function Update-ProfileIdentity {
    # One pass: every running extra-profile window that does not carry its AUMID yet
    # gets one. Cheap: one process query plus one property read per Claude window.
    param([switch]$Force)
    $tagged = 0
    $running = Get-RunningProfileMap
    foreach ($dir in $running.Keys) {
        $name = if ($dir -eq $script:DefaultProfilePath.TrimEnd('\')) { $script:DefaultName } else { Split-Path $dir -Leaf }
        if (-not (Test-ProfileTaggable -Name $name)) { continue }
        $want = Get-ProfileAumid -Name $name
        foreach ($h in [ClaudeProfiles.Native]::WindowsForPid([uint32]$running[$dir], $true)) {
            $have = try { [ClaudeProfiles.Native]::GetWindowAumid($h) } catch { $null }
            # $want already reflects the current look, so an appearance change shows up
            # here as a mismatch and the window moves to its new identity on its own.
            if ($Force -or $have -ne $want) {
                try { Set-WindowIdentity -Name $name -Hwnd $h; $tagged++ } catch { }
            }
        }
    }
    # New icons are on the windows now, so the previous generation can go.
    Clear-RetiredIcon
    return $tagged
}

function Reset-ProfileIconHandle {
    # Retired rather than destroyed on the spot: a window is still drawing the current
    # handle, and freeing it out from under the window leaves a broken icon. They are
    # released by Clear-RetiredIcon once the replacements have been applied.
    foreach ($entry in $script:IconHandles.Values) {
        foreach ($k in @('Small', 'Big')) {
            if ($entry[$k] -and $entry[$k] -ne [IntPtr]::Zero) { $script:RetiredIcons.Add($entry[$k]) }
        }
    }
    $script:IconHandles = @{}
}

function Clear-RetiredIcon {
    if ($script:RetiredIcons.Count -eq 0) { return }
    foreach ($h in $script:RetiredIcons) { try { [void][ClaudeProfiles.Native]::DestroyIcon($h) } catch { } }
    $script:RetiredIcons.Clear()
}

$script:SwitcherAumid = 'Anthropic.Claude.ProfileSwitcher'

function Set-SwitcherWindowIdentity {
    # Gives the switcher window its own taskbar button and icon instead of PowerShell's.
    # Must run before the window is shown: the taskbar reads these when it creates the button.
    param([Parameter(Mandatory)][IntPtr]$Hwnd)
    $l = Get-HeadlessLauncher
    $cmd = '"{0}" {1} -File "{2}"' -f $l.Exe, $l.Prefix, $script:SwitcherScript
    [ClaudeProfiles.Native]::SetWindowIdentity($Hwnd, $script:SwitcherAumid, $cmd, 'Claude Profile Switcher', "$(Get-SwitcherIcoPath),0")
}

function Restore-DefaultIdentity {
    # Put Default's live window back to Claude's own identity and icon. Used when the
    # option is turned off and by -Revert. Without a remembered original AUMID the
    # window keeps ours until Claude is restarted.
    $running = Get-RunningProfileMap
    $procId = $running[$script:DefaultProfilePath.TrimEnd('\')]
    if (-not $procId) { return $false }
    $orig = Get-Setting 'DefaultOriginalAumid'
    Add-Type -AssemblyName System.Drawing
    $ico = try { [System.Drawing.Icon]::ExtractAssociatedIcon($script:ClaudeExe) } catch { $null }
    foreach ($h in [ClaudeProfiles.Native]::WindowsForPid([uint32]$procId, $true)) {
        $have = try { [ClaudeProfiles.Native]::GetWindowAumid($h) } catch { $null }
        if ($have -notlike "$($script:AumidPrefix)*") { continue }
        if ($orig) {
            try { [ClaudeProfiles.Native]::SetWindowIdentity($h, $orig, "`"$($script:ClaudeExe)`"", 'Claude', "$($script:ClaudeExe),0") } catch { }
        }
        if ($ico) { [ClaudeProfiles.Native]::ApplyIcon($h, $ico.Handle, $ico.Handle) }
        if ([ClaudeProfiles.Native]::IsVisible($h)) { try { [ClaudeProfiles.Native]::RebuildTaskbarButton($h) } catch { } }
    }
    return [bool]$orig
}

# ------------------------------------------------------------- login router --
#
# Windows has one handler per user for claude:// links, and Claude re-registers itself
# every time it starts. The router script takes that slot and forwards login callbacks
# to the profile that is signed out. The original handler is saved for -Revert.

$script:KeyPath = "HKCU:\Software\Classes\$($script:Scheme)"
$script:CmdPath = "$($script:KeyPath)\shell\open\command"

function Test-RouterActive {
    if (-not (Test-Path -LiteralPath $script:CmdPath)) { return $false }
    return ((Get-ItemProperty $script:CmdPath).'(default)' -like '*ClaudeAuthRouter*')
}

function Set-RouterRegistration {
    if (-not (Test-Path -LiteralPath $script:RouterScript)) { throw "Router script not found: $($script:RouterScript)" }
    if ((Test-Path -LiteralPath $script:CmdPath) -and -not (Test-Path -LiteralPath $script:BackupPath)) {
        $existing = (Get-ItemProperty $script:CmdPath).'(default)'
        if ($existing -and $existing -notlike '*ClaudeAuthRouter*') {
            New-Item -ItemType Directory -Force -Path $script:ToolRoot | Out-Null
            @{ Command = $existing } | ConvertTo-Json | Set-Content -LiteralPath $script:BackupPath -Encoding UTF8
        }
    }
    New-Item -Path $script:CmdPath -Force | Out-Null
    Set-ItemProperty -Path $script:KeyPath -Name '(default)'    -Value "URL:$($script:Scheme)"
    Set-ItemProperty -Path $script:KeyPath -Name 'URL Protocol' -Value ''
    $l = Get-HeadlessLauncher
    Set-ItemProperty -Path $script:CmdPath -Name '(default)' -Value ('"{0}" {1} -File "{2}" -Url "%1"' -f $l.Exe, $l.Prefix, $script:RouterScript)
}

function Restore-RouterRegistration {
    if (Test-Path -LiteralPath $script:BackupPath) {
        $saved = (Get-Content -LiteralPath $script:BackupPath -Raw | ConvertFrom-Json).Command
        New-Item -Path $script:CmdPath -Force | Out-Null
        Set-ItemProperty -Path $script:CmdPath -Name '(default)' -Value $saved
        Remove-Item -LiteralPath $script:BackupPath -Force
        return 'restored the original claude:// handler'
    }
    if (Test-RouterActive) {
        # No backup means we never saw an original; Claude re-registers itself on launch.
        Remove-Item -LiteralPath $script:KeyPath -Recurse -Force -ErrorAction SilentlyContinue
        return 'removed the claude:// handler; Claude recreates it next time it starts'
    }
    return 'claude:// handler was not ours; left alone'
}

function Set-PendingLogin {
    param([Parameter(Mandatory)][string]$Name, [int]$Minutes = 15)
    New-Item -ItemType Directory -Force -Path $script:ToolRoot | Out-Null
    @{ Profile = $Name; Expires = (Get-Date).AddMinutes($Minutes).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $script:MarkerPath -Encoding UTF8
}

function Get-PendingLogin {
    if (-not (Test-Path -LiteralPath $script:MarkerPath)) { return $null }
    try {
        $m = Get-Content -LiteralPath $script:MarkerPath -Raw | ConvertFrom-Json
        if ([datetime]$m.Expires -lt (Get-Date)) { Clear-PendingLogin; return $null }
        return [string]$m.Profile
    } catch { Clear-PendingLogin; return $null }
}

function Clear-PendingLogin { Remove-Item -LiteralPath $script:MarkerPath -Force -ErrorAction SilentlyContinue }

function Write-ErrorLog {
    param([string]$Message)
    try {
        New-Item -ItemType Directory -Force -Path $script:ToolRoot | Out-Null
        Add-Content -LiteralPath $script:ErrorLog -Value ("[{0}] {1}" -f (Get-Date -Format 's'), $Message)
    } catch { }
}

function Write-RouterLog {
    param([string]$Message)
    try {
        New-Item -ItemType Directory -Force -Path $script:ToolRoot | Out-Null
        Add-Content -LiteralPath $script:RouterLog -Value ("[{0}] {1}" -f (Get-Date -Format 's'), $Message)
    } catch { }
}

# ---------------------------------------------------------------- shortcuts --

function Get-SafeFileName {
    # Display labels are free text, so they can hold characters Windows forbids in a file
    # name. Without this the shortcut fails to save, and Update-ProfileShortcut would have
    # already deleted the old one.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $clean = ($Text -replace '[\\/:*?"<>|]', '-').Trim(" .`t")
    if (-not $clean) { $clean = 'Profile' }
    if ($clean.Length -gt 60) { $clean = $clean.Substring(0, 60).TrimEnd(' ', '.') }
    return $clean
}

function New-ProfileShortcut {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Directory)
    $look  = Get-ProfileAppearance -Name $Name
    $shell = New-Object -ComObject WScript.Shell
    $path  = Join-Path $Directory "Claude - $(Get-SafeFileName $look.Label).lnk"
    $link  = $shell.CreateShortcut($path)

    if ($Name -eq $script:DefaultName -and $script:ClaudeApp.Kind -eq 'Msix') {
        $link.TargetPath = 'explorer.exe'
        $link.Arguments  = "shell:AppsFolder\$($script:ClaudeApp.AppUserModelId)"
        $link.IconLocation = "$($script:ClaudeExe),0"
    } elseif ($Name -eq $script:DefaultName) {
        $link.TargetPath = $script:ClaudeExe
        $link.Arguments  = ''
        $link.IconLocation = "$($script:ClaudeExe),0"
    } else {
        # Re-runs the switcher so the exe path is resolved at click time (survives updates)
        # and so the window gets its identity the moment it appears.
        $l = Get-HeadlessLauncher
        $link.TargetPath = $l.Exe
        $link.Arguments  = "$($l.Prefix) -File `"$($script:SwitcherScript)`" -Launch `"$Name`""
        $link.IconLocation = "$(Get-ProfileIcoPath -Name $Name),0"
    }
    $link.Description      = "Launch Claude using the '$($look.Label)' account profile"
    $link.WorkingDirectory = $script:LibDir
    $link.Save()

    if ($Name -ne $script:DefaultName) {
        # Lets a pinned copy of the shortcut share a taskbar button with the running window.
        try { [ClaudeProfiles.Native]::SetShortcutAumid($path, (Get-ProfileAumid -Name $Name)) } catch { }
    }
    return $path
}

function New-SwitcherShortcut {
    param([Parameter(Mandatory)][string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $shell = New-Object -ComObject WScript.Shell
    $link  = $shell.CreateShortcut((Join-Path $Directory 'Claude Profile Switcher.lnk'))
    $l = Get-HeadlessLauncher
    $link.TargetPath       = $l.Exe
    $link.Arguments        = "$($l.Prefix) -File `"$($script:SwitcherScript)`""
    $link.IconLocation     = "$(Get-SwitcherIcoPath),0"
    $link.Description      = 'Switch between Claude desktop accounts'
    $link.WorkingDirectory = $script:LibDir
    $link.Save()
    try { [ClaudeProfiles.Native]::SetShortcutAumid($link.FullName, $script:SwitcherAumid) } catch { }
    return $link.FullName
}

function Update-SwitcherShortcut {
    # Self-heal: after -Revert the switcher's own shortcuts carry the plain Claude icon
    # and no identity. Recreate any that do not point at the current switcher icon.
    $ico = Get-SwitcherIcoPath
    foreach ($d in @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'))) {
        $lnk = Join-Path $d 'Claude Profile Switcher.lnk'
        if (-not (Test-Path -LiteralPath $lnk)) { continue }
        $shell = New-Object -ComObject WScript.Shell
        if ($shell.CreateShortcut($lnk).IconLocation -notlike "$ico*") {
            Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
            New-SwitcherShortcut -Directory $d | Out-Null
        }
    }
}

function Get-ProfileShortcut {
    # Every .lnk on the desktop or Start menu that launches one of our profiles.
    $dirs = @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'))
    $shell = New-Object -ComObject WScript.Shell
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $d -Filter '*.lnk' -File -ErrorAction SilentlyContinue)) {
            $s = $shell.CreateShortcut($f.FullName)
            if ($s.Arguments -match '-Launch "([^"]+)"' -and $s.Arguments -like "*ClaudeSwitcher.ps1*") {
                [pscustomobject]@{ Path = $f.FullName; Profile = $Matches[1] }
            }
        }
    }
}

function Update-ProfileShortcut {
    # After an appearance change: rewrite each shortcut for that profile in place.
    param([Parameter(Mandatory)][string]$Name)
    foreach ($s in (Get-ProfileShortcut | Where-Object { $_.Profile -eq $Name })) {
        $dir = Split-Path $s.Path -Parent
        Remove-Item -LiteralPath $s.Path -Force -ErrorAction SilentlyContinue
        New-ProfileShortcut -Name $Name -Directory $dir | Out-Null
    }
}

# ------------------------------------------------------------------- launch --

function Start-ClaudeProfile {
    param([Parameter(Mandatory)][string]$Name, [switch]$Wait)

    $path = Get-ProfilePath -Name $Name
    if ($Name -eq $script:DefaultName) {
        if ($script:ClaudeApp.Kind -eq 'Msix') {
            Start-Process 'explorer.exe' -ArgumentList "shell:AppsFolder\$($script:ClaudeApp.AppUserModelId)"
        } else {
            Start-Process -FilePath $script:ClaudeExe -WindowStyle Normal
        }
    } else {
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        # -WindowStyle Normal matters: shortcuts run us hidden, and without an explicit
        # show state Claude would inherit ours and start with an invisible window.
        Start-Process -FilePath $script:ClaudeExe -ArgumentList "--user-data-dir=`"$path`"" -WindowStyle Normal

        # A signed-out profile being launched is very likely about to sign in.
        if ((Test-ProfileSignedIn -Path $path) -ne $true) { Set-PendingLogin -Name $Name }
        try { if (-not (Test-RouterActive)) { Set-RouterRegistration } } catch { }
    }

    if (-not $Wait -or -not (Test-ProfileTaggable -Name $Name)) { return }

    # Tag the window as early as possible: polling at 200 ms usually catches it while
    # Electron still has it hidden, so the taskbar button is born with the right identity.
    $deadline = (Get-Date).AddSeconds(25)
    $sawVisible = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $running = Get-RunningProfileMap
        $procId = $running[$path.TrimEnd('\')]
        if (-not $procId) { continue }
        $wins = [ClaudeProfiles.Native]::WindowsForPid([uint32]$procId, $true)
        foreach ($h in $wins) {
            try { if ([ClaudeProfiles.Native]::GetWindowAumid($h) -ne (Get-ProfileAumid -Name $Name)) { Set-WindowIdentity -Name $Name -Hwnd $h } } catch { }
            if ([ClaudeProfiles.Native]::IsVisible($h)) { $sawVisible = $true }
        }
        if ($sawVisible) { break }
    }
    # Claude has re-registered claude:// by now; take it back and make sure the icon stuck.
    Start-Sleep -Milliseconds 1500
    try { if (-not (Test-RouterActive)) { Set-RouterRegistration } } catch { }
    Update-ProfileIdentity | Out-Null
}

# ------------------------------------------------------------------- revert --

function Undo-SwitcherChange {
    # Undo everything this tool adds beyond the original switcher. Never touches a
    # profile folder or anything Claude owns. Returns the list of actions taken.
    $done = New-Object System.Collections.Generic.List[string]
    $done.Add((Restore-RouterRegistration))
    Clear-PendingLogin
    if (Get-Setting 'DefaultOriginalAumid') {
        if (Restore-DefaultIdentity) { $done.Add("restored Default's own taskbar identity") }
        Set-Setting 'DefaultOriginalAumid' $null
    }

    foreach ($s in @(Get-ProfileShortcut)) {
        # Recreate as a plain shortcut: Claude's icon, no AUMID stamp.
        $shell = New-Object -ComObject WScript.Shell
        $link  = $shell.CreateShortcut($s.Path)
        $link.IconLocation = "$($script:ClaudeExe),0"
        $link.Save()
        # WScript cannot clear a property store, so rebuild the file from scratch.
        $tmp = [System.IO.Path]::ChangeExtension($s.Path, '.tmp.lnk')   # WScript insists on a .lnk name
        $copy = $shell.CreateShortcut($tmp)
        $copy.TargetPath = $link.TargetPath; $copy.Arguments = $link.Arguments
        $copy.IconLocation = $link.IconLocation; $copy.Description = $link.Description
        $copy.WorkingDirectory = $link.WorkingDirectory; $copy.Save()
        Move-Item -LiteralPath $tmp -Destination $s.Path -Force
        $done.Add("reset shortcut $(Split-Path $s.Path -Leaf)")
    }

    foreach ($d in @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'))) {
        $lnk = Join-Path $d 'Claude Profile Switcher.lnk'
        if (-not (Test-Path -LiteralPath $lnk)) { continue }
        # Rebuild from scratch: plain Claude icon, no identity stamp, same target.
        $shell = New-Object -ComObject WScript.Shell
        $old = $shell.CreateShortcut($lnk); $tmp = [System.IO.Path]::ChangeExtension($lnk, '.tmp.lnk')
        $new = $shell.CreateShortcut($tmp)
        $new.TargetPath = $old.TargetPath; $new.Arguments = $old.Arguments; $new.WorkingDirectory = $old.WorkingDirectory
        $new.Description = $old.Description; $new.IconLocation = "$($script:ClaudeExe),0"; $new.Save()
        Move-Item -LiteralPath $tmp -Destination $lnk -Force
        $done.Add("reset shortcut $(Split-Path $lnk -Leaf)")
    }

    if (Get-Setting 'Profiles') { Set-Setting 'Profiles' $null; $done.Add('removed display names, colours and badges from settings.json') }

    if (Test-Path -LiteralPath $script:ToolRoot) {
        Remove-Item -LiteralPath $script:ToolRoot -Recurse -Force
        $done.Add("deleted $($script:ToolRoot) (icons, logs, markers)")
    }
    # Left over from the first prototype, which kept its files in the profiles folder.
    foreach ($old in @('.icons', 'auth-router.log', 'pending-auth.json', 'protocol-backup.json')) {
        $p = Join-Path $script:ProfileRoot $old
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force; $done.Add("deleted $p") }
    }
    return $done
}
