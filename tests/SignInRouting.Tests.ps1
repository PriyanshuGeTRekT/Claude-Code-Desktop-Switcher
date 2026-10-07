$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Get-Setting','Test-SignInRoutingOn','Test-SafeLink','Test-SignInLink','Get-ProfileDataPath','Test-ProfileSignedIn',
                    'Set-PendingSignIn','Get-PendingSignIn','Clear-PendingSignIn','Select-SignInTarget','Get-LauncherScript',
                    'Get-RouterCommand','Get-RegistryDefault','Set-RegistryValue','Get-RouterRegistryPath','Test-RouterRegistered',
                    'Register-SignInRouter','Test-RouterChosen','Unregister-SignInRouter')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert($condition, $message) { if (-not $condition) { throw $message } }
# Stands in for the shell, which a test cannot steer: what Windows would open claude:// links with.
$script:EffectiveProgId = $null
function Get-LinkHandlerProgId { return $script:EffectiveProgId }
$onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('claude-routing-test-' + [guid]::NewGuid().ToString('N'))
$sandbox = 'HKCU:\Software\ClaudeProfileSwitcherTests\' + [guid]::NewGuid().ToString('N')
$originalLocal = $env:LOCALAPPDATA
try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null

    # Link validation: what reaches Claude's command line.
    foreach ($ok in @('claude://login/abc123', 'claude://claude.ai/sso-callback?code=AbC-1_x.y~z&state=s%2Fq')) {
        Assert (Test-SafeLink -Link $ok) "Valid link refused: $ok"
    }
    foreach ($bad in @('', "claude://login/x`n", "claude://login/x`r", 'claude://login/x"', 'claude://login/x" -Revert "',
                       'claude://login/x y', 'claude://login/x\y', 'https://claude.ai/login', 'CLAUDE://login/x',
                       ('claude://login/' + ('a' * 2040)))) {
        Assert (-not (Test-SafeLink -Link $bad)) "Unsafe link accepted: $($bad -replace "`n", '<LF>' -replace "`r", '<CR>')"
    }

    # Which links count as sign-ins.
    foreach ($signIn in @('claude://login/abc', 'claude://claude.ai/sso-callback?code=1&state=2', 'claude://claude.ai/sso-callback',
                          'claude://claude.ai/sso-callback/x', 'claude://claude.ai/sso-callback#f')) {
        Assert (Test-SignInLink -Link $signIn) "Sign-in link not recognised: $signIn"
    }
    foreach ($other in @('claude://claude.ai/sso-callbackother', 'claude://claude.ai/sso-callback-other', 'claude://claude.ai/new',
                         'claude://loginx', 'claude://open?next=claude://login/x')) {
        Assert (-not (Test-SignInLink -Link $other)) "Other link taken for a sign-in: $other"
    }

    # Target selection.
    $default = [pscustomobject]@{ Id = 'Default'; Name = 'Default'; IsDefault = $true;  Pid = 10;    SignedIn = $null }
    $work    = [pscustomobject]@{ Id = 'Work';    Name = 'Work';    IsDefault = $false; Pid = 20;    SignedIn = $true }
    $fresh   = [pscustomobject]@{ Id = 'Fresh';   Name = 'Fresh';   IsDefault = $false; Pid = 30;    SignedIn = $false }
    $closed  = [pscustomobject]@{ Id = 'Closed';  Name = 'Closed';  IsDefault = $false; Pid = $null; SignedIn = $null }
    $all = @($default, $work, $fresh, $closed)
    Assert ((Select-SignInTarget -Profiles $all -PendingId 'Closed').Target.Id -eq 'Closed') 'Expected profile ignored'
    Assert ((Select-SignInTarget -Profiles $all -PendingId 'Default').Target.Id -eq 'Fresh') 'Pending Default not ignored'
    Assert ((Select-SignInTarget -Profiles $all -PendingId 'Deleted').Target.Id -eq 'Fresh') 'Missing pending profile not ignored'
    Assert ((Select-SignInTarget -Profiles $all).Target.Id -eq 'Fresh') 'Only signed-out profile not chosen'
    $work.SignedIn = $false
    Assert ((Select-SignInTarget -Profiles $all -FrontmostPid 20).Target.Id -eq 'Work') 'Frontmost window not used when two are signed out'
    Assert ($null -eq (Select-SignInTarget -Profiles $all -FrontmostPid 10)) 'Default in front did not keep the sign-in in Default'
    Assert ($null -eq (Select-SignInTarget -Profiles $all)) 'Guessed between two signed-out profiles'
    Assert ($null -eq (Select-SignInTarget -Profiles @($default, $closed) -FrontmostPid 10)) 'No open extra profile, yet not Default'

    # Signed-in detection reads key presence and length only.
    $cases = [ordered]@{
        '{"windowSizeWasSignedIn":true}'                          = $true
        '{"windowSizeWasSignedIn":false,"oauth:tokenCacheV2":"x"}' = $false
        ('{"oauth:tokenCacheV2":"' + ('t' * 1500) + '"}')         = $true
        ('{"oauth:tokenCacheV2":"' + ('t' * 44) + '"}')           = $false
        '{"somethingElse":1}'                                     = $false
        'not json'                                                = $null
    }
    $i = 0
    foreach ($json in $cases.Keys) {
        $dir = Join-Path $fixture "signed-$i"; $i++
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'config.json'), $json)
        Assert ((Test-ProfileSignedIn -Path $dir) -eq $cases[$json]) "Signed-in state wrong for $($json.Substring(0, [math]::Min(40, $json.Length)))"
    }
    Assert ($null -eq (Test-ProfileSignedIn -Path (Join-Path $fixture 'never-started'))) 'Profile without config.json not unknown'

    # The pending sign-in marker.
    $script:PendingSignInPath = Join-Path $fixture 'pending-sign-in.json'
    Set-PendingSignIn -Id 'Work'
    Assert ((Get-PendingSignIn) -eq 'Work') 'Pending sign-in not read back'
    Clear-PendingSignIn
    Assert ($null -eq (Get-PendingSignIn)) 'Pending sign-in not cleared'
    Set-PendingSignIn -Id 'Work' -Minutes -1
    Assert ($null -eq (Get-PendingSignIn) -and -not (Test-Path -LiteralPath $script:PendingSignInPath)) 'Expired marker kept'
    [IO.File]::WriteAllText($script:PendingSignInPath, 'garbage')
    Assert ($null -eq (Get-PendingSignIn) -and -not (Test-Path -LiteralPath $script:PendingSignInPath)) 'Unreadable marker kept'

    # The switch itself lives in settings.json.
    $script:SettingsPath = Join-Path $fixture 'settings.json'
    Assert (-not (Test-SignInRoutingOn)) 'Routing on without a setting'
    [IO.File]::WriteAllText($script:SettingsPath, '{"SignInRouting":true}')
    Assert (Test-SignInRoutingOn) 'Routing setting not read'

    if (-not $onWindows) {
        Write-Output 'PASS (portable part): link validation, sign-in shapes, target selection, signed-in detection, pending marker, setting.'
        return
    }

    # Store build: profile files are redirected into the package's LocalCache.
    $env:LOCALAPPDATA = Join-Path $fixture 'Local'
    $cache = Join-Path $env:LOCALAPPDATA 'Packages\TestPackage\LocalCache'
    $script:ClaudeApp = [pscustomobject]@{ Kind = 'Msix'; DefaultProfilePath = (Join-Path $cache 'Roaming\Claude') }
    $target = [pscustomobject]@{ Id = 'Work'; IsDefault = $false; Path = (Join-Path $env:LOCALAPPDATA 'ClaudeProfiles\Work') }
    Assert ((Get-ProfileDataPath -Target $target) -eq $target.Path) 'Redirected path used before Claude wrote there'
    $redirected = Join-Path $cache 'Local\ClaudeProfiles\Work'
    New-Item -ItemType Directory -Path $redirected -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $redirected 'config.json'), '{"windowSizeWasSignedIn":false}')
    Assert ((Get-ProfileDataPath -Target $target) -eq $redirected) 'Redirected profile data not found'
    $script:ClaudeApp.Kind = 'Classic'
    Assert ((Get-ProfileDataPath -Target $target) -eq $target.Path) 'Installer build redirected'

    # The command Windows runs for a link.
    $script:InstalledScript = Join-Path $fixture 'not-installed\ClaudeSwitcher.ps1'
    $script:ScriptPath      = 'C:\Tools\Claude Switcher\ClaudeSwitcher.ps1'
    $cmd = Get-RouterCommand
    Assert ($cmd -like '*-File "C:\Tools\Claude Switcher\ClaudeSwitcher.ps1" -HandleLink "%1"') "Unexpected router command: $cmd"

    # Registry round trip, inside a throwaway key.
    $script:RouterRegistry = [pscustomobject]@{
        Classes = "$sandbox\Classes"; Capability = "$sandbox\App\Capabilities"; AppList = "$sandbox\RegisteredApplications" }
    $script:HandlerBackupPath = Join-Path $fixture 'claude-handler-backup.json'
    $keys = Get-RouterRegistryPath
    $original = '"C:\Claude\Claude.exe" "%1"'
    Set-RegistryValue $keys.SchemeCommand '(default)' $original
    Set-RegistryValue $keys.AppList 'SomeOtherApp' 'Software\Other\Capabilities'

    Register-SignInRouter
    Assert (Test-RouterRegistered) 'Not registered after Register-SignInRouter'
    Assert ((Get-Content -LiteralPath $script:HandlerBackupPath -Raw | ConvertFrom-Json).Command -eq $original) 'Original handler not backed up'
    Assert ((Get-ItemProperty -LiteralPath "$($keys.Capability)\URLAssociations").claude -eq 'ClaudeProfileRouter.claude') 'URL association missing'
    Assert ((Get-ItemProperty -LiteralPath $keys.AppList).ClaudeProfileRouter -eq $keys.CapabilityRef) 'Not listed in RegisteredApplications'
    Assert ((Get-ItemProperty -LiteralPath $keys.AppList).SomeOtherApp -eq 'Software\Other\Capabilities') 'Another registered app was disturbed'

    # Claude takes the key back as it starts.
    Set-RegistryValue $keys.SchemeCommand '(default)' $original
    Assert (-not (Test-RouterRegistered)) 'Lost handler not noticed'
    Register-SignInRouter
    Assert ((Get-Content -LiteralPath $script:HandlerBackupPath -Raw | ConvertFrom-Json).Command -eq $original) 'Backup overwritten'

    # Whether links reach the router.
    $script:ClaudeApp.Kind = 'Msix'; $script:EffectiveProgId = 'AppXclaude'
    Assert (-not (Test-RouterChosen)) 'Store build reported routed while the package keeps claude://'
    $script:EffectiveProgId = 'ClaudeProfileRouter.claude'
    Assert (Test-RouterChosen) 'Default apps pick not recognised'
    $script:ClaudeApp.Kind = 'Classic'; $script:EffectiveProgId = $null
    Assert (Test-RouterChosen) 'Installer build without a pick not routed through the Classes key'

    # Revert while the router is still the Default apps choice: the ProgID has to stay.
    $script:EffectiveProgId = 'ClaudeProfileRouter.claude'
    $done = @(Unregister-SignInRouter)
    Assert ((Get-RegistryDefault $keys.SchemeCommand) -eq $original) 'Original handler not restored'
    Assert (Test-Path -LiteralPath $keys.ProgId) 'Chosen ProgID deleted'
    Assert (-not (Test-Path -LiteralPath $script:HandlerBackupPath)) 'Backup left behind'
    Assert (($done -join ' ') -like '*kept*') 'Kept ProgID not reported'

    # Once Claude is picked again, the rest goes.
    $script:EffectiveProgId = 'AppXclaude'
    $null = Unregister-SignInRouter
    Assert (-not (Test-Path -LiteralPath $keys.ProgId)) 'ProgID left behind'
    Assert (-not (Test-Path -LiteralPath (Split-Path $keys.Capability -Parent))) 'Capabilities left behind'
    Assert ($null -eq (Get-ItemProperty -LiteralPath $keys.AppList).ClaudeProfileRouter) 'Still listed in RegisteredApplications'
    Assert ((Get-ItemProperty -LiteralPath $keys.AppList).SomeOtherApp -eq 'Software\Other\Capabilities') 'Another registered app removed'
    Assert ((Get-RegistryDefault $keys.SchemeCommand) -eq $original) 'Original handler changed by the second revert'

    # No original handler at all, as on a Store build that never wrote one.
    Remove-Item -LiteralPath $keys.Scheme -Recurse -Force
    Register-SignInRouter
    $null = Unregister-SignInRouter
    Assert (-not (Test-Path -LiteralPath $keys.Scheme)) 'Handler key we created was left behind'

    Write-Output 'PASS: link validation, sign-in shapes, target selection, signed-in detection, pending marker, setting, Store paths, router command, registry round trip, revert with and without a Default apps pick.'
} finally {
    $env:LOCALAPPDATA = $originalLocal
    if ($onWindows) {
        $root = Split-Path $sandbox -Parent
        if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
        if ((Test-Path -LiteralPath $root) -and -not (Get-ChildItem -LiteralPath $root)) { Remove-Item -LiteralPath $root -Force }
    }
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected fixture path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
