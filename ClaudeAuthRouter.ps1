<#
.SYNOPSIS
    Forwards claude:// login callbacks to the Claude profile that is signing in.

.DESCRIPTION
    Windows keeps one handler per user for claude:// links, so after a browser sign-in
    the callback always lands in the Default profile. ClaudeSwitcher.ps1 registers this
    script as the handler; on each callback it picks a target in this order:

      1. a profile explicitly marked as expecting a login (-Expect, or set by the
         switcher when it launches a signed-out profile)
      2. the one running profile that is currently signed out
      3. the running profile whose window was most recently in front
      4. Default, exactly as before

    Only claude://login/... links are routed. Anything else goes to Default untouched.
    Claude re-registers itself as the handler every time it starts; the switcher takes
    the slot back whenever it launches a profile.

.EXAMPLE
    .\ClaudeAuthRouter.ps1 -Status
    .\ClaudeAuthRouter.ps1 -Expect Work
#>
[CmdletBinding(DefaultParameterSetName = 'Route')]
param(
    [Parameter(ParameterSetName = 'Route')][string]$Url,
    [Parameter(ParameterSetName = 'Expect', Mandatory)][string]$Expect,
    [Parameter(ParameterSetName = 'Expect')][int]$Minutes = 15,
    [Parameter(ParameterSetName = 'Status')][switch]$Status,
    [Parameter(ParameterSetName = 'Register')][switch]$Register,
    [Parameter(ParameterSetName = 'Unregister')][switch]$Unregister
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeProfileLib.ps1')

try { Initialize-ClaudeLib } catch { Write-RouterLog "FAILED to locate Claude: $($_.Exception.Message)"; throw }

if ($Status) {
    "Handler key:     $($script:CmdPath)"
    "Current command: $(if (Test-Path -LiteralPath $script:CmdPath) { (Get-ItemProperty $script:CmdPath).'(default)' } else { '<none>' })"
    "Router active:   $(if (Test-RouterActive) { 'yes' } else { 'no - Claude owns the scheme until a profile is launched' })"
    "Backup saved:    $(Test-Path -LiteralPath $script:BackupPath)"
    "Pending login:   $(if ($p = Get-PendingLogin) { $p } else { '<none>' })"
    "Log:             $($script:RouterLog)"
    ''
    'Running profiles:'
    foreach ($pr in (Get-ProfileList | Where-Object Pid)) {
        ("  {0,-20} pid {1,-7} {2}" -f $pr.Label, $pr.Pid, $(if ($pr.SignedIn) { 'signed in' } elseif ($pr.SignedIn -eq $false) { 'SIGNED OUT' } else { 'unknown' }))
    }
    return
}

if ($Register)   { Set-RouterRegistration; 'Registered as the claude:// handler.'; return }
if ($Unregister) { Restore-RouterRegistration; Clear-PendingLogin; return }

if ($Expect) {
    Set-PendingLogin -Name $Expect -Minutes $Minutes
    if (-not (Test-RouterActive)) { Set-RouterRegistration }
    "Next login callback within $Minutes minutes goes to '$Expect'."
    return
}

# ----------------------------------------------------------------- routing --

if (-not $Url) { Write-RouterLog 'Invoked with no URL.'; return }

function Test-SafeLink {
    # This URL arrives from the browser through the shell, so it is untrusted, and it ends
    # up inside a command line for Claude.exe. Windows PowerShell 5.1 cannot pass an
    # argument vector (ProcessStartInfo.ArgumentList is .NET Core only) and its own
    # -ArgumentList array is joined without reliable quoting, so the input is validated
    # instead: claude:// followed only by characters RFC 3986 permits in a URI. That
    # excludes the quote, backslash, space and control characters an injection needs.
    param([string]$Link)
    if ([string]::IsNullOrEmpty($Link) -or $Link.Length -gt 2048) { return $false }
    return ($Link -cmatch "^claude://[A-Za-z0-9._~:/?#\[\]@!\$&'()*+,;=%-]*$")
}

function Start-ClaudeWithUrl {
    param([string]$ProfileDir, [string]$Link)
    # If that profile is already running, Electron's single-instance lock hands the URL
    # to the existing window instead of starting a second copy.
    $argLine = if ($ProfileDir) { '--user-data-dir="{0}" "{1}"' -f $ProfileDir, $Link } else { '"{0}"' -f $Link }
    Start-Process -FilePath $script:ClaudeExe -ArgumentList $argLine -WindowStyle Normal
}

try {
    if (-not (Test-SafeLink -Link $Url)) {
        # Refused rather than passed on: a rejected link is either malformed or an attempt
        # to smuggle extra arguments. The URL is not logged; it carries a login code.
        Write-RouterLog 'Refused a claude:// link that failed validation.'
        return
    }

    if ($Url -notmatch '^claude://login/') {
        Start-ClaudeWithUrl -Link $Url
        Write-RouterLog 'Non-login link; passed to Default.'
        return
    }

    $target = $null; $why = ''
    $running = Get-ProfileList | Where-Object { $_.Pid -and -not $_.IsDefault }

    $pending = Get-PendingLogin
    if ($pending -and $pending -ne $script:DefaultName) {
        $target = $pending; $why = 'explicitly expected'
    }
    if (-not $target) {
        $signedOut = @($running | Where-Object { $_.SignedIn -eq $false })
        if ($signedOut.Count -eq 1) { $target = $signedOut[0].Name; $why = 'only signed-out profile' }
    }
    if (-not $target -and $running) {
        $front = [ClaudeProfiles.Native]::FrontmostPid([uint32[]]@((Get-RunningProfileMap).Values))
        $hit = $running | Where-Object { $_.Pid -eq $front } | Select-Object -First 1
        if ($hit) { $target = $hit.Name; $why = 'most recently used window' }
    }

    if ($target) {
        Start-ClaudeWithUrl -ProfileDir (Get-ProfilePath -Name $target) -Link $Url
        Write-RouterLog "Login routed to '$target' ($why)."
    } else {
        Start-ClaudeWithUrl -Link $Url
        Write-RouterLog 'Login routed to Default (no other candidate).'
    }
    Clear-PendingLogin

    # Claude re-registers the scheme as it starts; take it back so the next login works too.
    Start-Sleep -Seconds 4
    try { if (-not (Test-RouterActive)) { Set-RouterRegistration } } catch { }
} catch {
    Write-RouterLog "FAILED: $($_.Exception.Message)"
    throw
}
