$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Invoke-WithProfileEnv', 'Get-ProfileArgs', 'Get-LaunchArgLine', 'Get-OtherLinkTarget', 'Test-SafeLink')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert($condition, $message) { if (-not $condition) { throw $message } }
$script:DefaultName = 'Default'

# Stands in for settings.json: what Get-Setting would read.
$script:Settings = @{}
function Get-Setting { param($Name) return $script:Settings[$Name] }

# The profiles that exist, for Resolve-ClaudeProfile. One has a label unlike its id.
$script:Profiles = @(
    [pscustomobject]@{ Id = 'Default'; Name = 'Default'; IsDefault = $true;  Path = 'C:\d' },
    [pscustomobject]@{ Id = 'Work';    Name = 'Client';  IsDefault = $false; Path = 'C:\w' })
function Resolve-ClaudeProfile {
    param($Name, [switch]$SkipStatus)
    $hit = $script:Profiles | Where-Object { $_.Id -eq $Name } | Select-Object -First 1
    if (-not $hit) { $hit = $script:Profiles | Where-Object { $_.Name -eq $Name } | Select-Object -First 1 }
    return $hit
}

# Environment variables: set for one launch only, invalid names skipped, restored after.
$var = 'CLAUDE_SWITCHER_TEST_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$script:Settings = @{ ProfileEnv = [pscustomobject]@{ Work = [pscustomobject]@{ $var = 'work'; 'bad name' = 'x'; '1BAD' = 'y' } } }
[Environment]::SetEnvironmentVariable($var, 'preset', 'Process')
$out = Invoke-WithProfileEnv -Id 'Work' {
    [pscustomobject]@{ Seen = [Environment]::GetEnvironmentVariable($var, 'Process'); Bad = [Environment]::GetEnvironmentVariable('bad name', 'Process'); Digit = [Environment]::GetEnvironmentVariable('1BAD', 'Process') }
}
Assert ($out.Seen -eq 'work') 'Variable not set for the launch'
Assert (-not $out.Bad -and -not $out.Digit) 'Invalid variable name set'
Assert ([Environment]::GetEnvironmentVariable($var, 'Process') -eq 'preset') 'Preset value not restored'
[Environment]::SetEnvironmentVariable($var, $null, 'Process')
Invoke-WithProfileEnv -Id 'Work' { Assert ([Environment]::GetEnvironmentVariable($var, 'Process') -eq 'work') 'Variable not set when unset before' }
Assert ($null -eq [Environment]::GetEnvironmentVariable($var, 'Process')) 'Unset variable not removed again'
Invoke-WithProfileEnv -Id 'Other' { Assert ($null -eq [Environment]::GetEnvironmentVariable($var, 'Process')) 'Variable leaked to another profile' }
try { Invoke-WithProfileEnv -Id 'Work' { throw 'launch failed' } } catch { }
Assert ($null -eq [Environment]::GetEnvironmentVariable($var, 'Process')) 'Variable kept after a failed launch'
$script:Settings = @{}
Invoke-WithProfileEnv -Id 'Work' { Assert ($null -eq [Environment]::GetEnvironmentVariable($var, 'Process')) 'Variable set without a setting' }

# Extra flags per account.
Assert ((Get-ProfileArgs -Id 'Work') -eq '') 'Flags without a setting'
$script:Settings = @{ ProfileArgs = [pscustomobject]@{ Work = '--enable-logging --v=1' } }
Assert ((Get-ProfileArgs -Id 'Work') -eq '--enable-logging --v=1') 'String flags changed'
Assert ((Get-ProfileArgs -Id 'Other') -eq '') 'Flags leaked to another profile'
$script:Settings = @{ ProfileArgs = [pscustomobject]@{ Work = @('--a', 'b c', 'd"e') } }
Assert ((Get-ProfileArgs -Id 'Work') -eq '--a "b c" "d\"e"') "Array flags not quoted: $(Get-ProfileArgs -Id 'Work')"
$script:Settings = @{ ProfileArgs = [pscustomobject]@{ Work = "--a`r`n--b" } }
Assert ((Get-ProfileArgs -Id 'Work') -eq '--a --b') 'Line break kept in flags'

# The command line: the folder, then the flags, then the link.
$script:Settings = @{}
Assert ((Get-LaunchArgLine -Id 'Work' -Path 'C:\p q') -eq '--user-data-dir="C:\p q"') 'Plain launch line'
Assert ((Get-LaunchArgLine -Id 'Default') -eq '') 'Default without flags should have no arguments'
$script:Settings = @{ ProfileArgs = [pscustomobject]@{ Work = '--x'; Default = '--d' } }
Assert ((Get-LaunchArgLine -Id 'Work' -Path 'C:\p') -eq '--user-data-dir="C:\p" --x') 'Flags not appended'
Assert ((Get-LaunchArgLine -Id 'Work' -Path 'C:\p' -Link 'claude://claude.ai/new') -eq '--user-data-dir="C:\p" --x "claude://claude.ai/new"') 'Link not last'
Assert ((Get-LaunchArgLine -Id 'Default' -Link 'claude://claude.ai/new') -eq '--d "claude://claude.ai/new"') 'Default line with flags'

# Where links that are not sign-ins go.
$script:Settings = @{}
Assert ($null -eq (Get-OtherLinkTarget)) 'Target without a setting'
$script:Settings = @{ OpenLinksIn = 'Work' }
Assert ((Get-OtherLinkTarget).Id -eq 'Work') 'OpenLinksIn by id'
$script:Settings = @{ OpenLinksIn = 'Client' }
Assert ((Get-OtherLinkTarget).Id -eq 'Work') 'OpenLinksIn by label'
$script:Settings = @{ OpenLinksIn = 'Default' }
Assert ($null -eq (Get-OtherLinkTarget)) 'Default should mean Default, not a target'
$script:Settings = @{ OpenLinksIn = 'Gone' }
Assert ($null -eq (Get-OtherLinkTarget)) 'A deleted profile should fall back to Default'

# -OpenLink takes only what -HandleLink takes.
Assert (Test-SafeLink -Link 'claude://claude.ai/epitaxy/local_1234') 'Session link refused'
Assert (-not (Test-SafeLink -Link 'claude://claude.ai/new" --remote-debugging-port=1 "')) 'Link with a quote accepted'

# The router itself, with every launch recorded instead of started and nothing touching
# the registry: where each kind of link goes.
foreach ($name in @('Invoke-SignInRouter', 'Test-SignInLink', 'Select-SignInTarget')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:Launched = @()
function Start-ClaudeWithLink { param($Link, $Target) $script:Launched += ,@{ Link = $Link; Target = $(if ($Target) { $Target.Id } else { 'Default' }) } }
$script:Log = @()
function Write-RouterLog { param($Message) $script:Log += $Message }
function Test-SignInRoutingOn { return ($script:Settings['SignInRouting'] -eq $true) }
function Wait-LaunchedIdentity { param($Target) }
function Test-RouterRegistered { return $true }
function Start-Sleep { param($Seconds, $Milliseconds) }
function Get-ProfileList {
    param([switch]$SkipStatus)
    foreach ($p in $script:Profiles) {
        [pscustomobject]@{ Id = $p.Id; Name = $p.Name; IsDefault = $p.IsDefault; Path = $p.Path; Pid = $(if ($p.Id -eq 'Work') { 20 } else { 10 }) }
    }
}
function Get-ProfileDataPath { param($Target) return $Target.Path }
function Test-ProfileSignedIn { param($Path) return $false }
function Get-FrontmostPid { param($ProcessIds) return 0 }
$script:Pending = $null
function Get-PendingSignIn { return $script:Pending }
function Clear-PendingSignIn { $script:Pending = $null }

$script:Settings = @{}
Invoke-SignInRouter -Link 'claude://claude.ai/epitaxy/local_1'
Assert ($script:Launched[-1].Target -eq 'Default' -and $script:Log[-1] -like 'Routing is off*') 'With routing off a link should pass to Default'
$script:Settings = @{ SignInRouting = $true }
Invoke-SignInRouter -Link 'claude://claude.ai/epitaxy/local_1'
Assert ($script:Launched[-1].Target -eq 'Default' -and $script:Log[-1] -like 'Not a sign-in link; passed to Default*') 'Without OpenLinksIn an other link should go to Default'
$script:Settings = @{ SignInRouting = $true; OpenLinksIn = 'Work' }
Invoke-SignInRouter -Link 'claude://claude.ai/epitaxy/local_1'
Assert ($script:Launched[-1].Target -eq 'Work' -and $script:Launched[-1].Link -eq 'claude://claude.ai/epitaxy/local_1') 'Other link not sent to the OpenLinksIn account'
Assert ($script:Log[-1] -like "*opened in 'Client'*") "Unexpected log line: $($script:Log[-1])"
$script:Pending = 'Work'
Invoke-SignInRouter -Link 'claude://login/abc'
Assert ($script:Launched[-1].Target -eq 'Work' -and $script:Log[-1] -like 'Sign-in sent*') 'Sign-in link no longer routed by the sign-in rules'
$script:Settings = @{ SignInRouting = $true; OpenLinksIn = 'Gone' }
Invoke-SignInRouter -Link 'claude://claude.ai/new'
Assert ($script:Launched[-1].Target -eq 'Default') 'A missing OpenLinksIn account should fall back to Default'
$before = $script:Launched.Count
Invoke-SignInRouter -Link 'claude://claude.ai/new" -Revert'
Assert ($script:Launched.Count -eq $before -and $script:Log[-1] -like 'Refused*') 'An unsafe link was launched'

Write-Output 'PASS: environment per account (set, skipped, restored, not leaked, failed launch), flags per account (string, array, line breaks), launch line order, OpenLinksIn by id and label with Default and missing profiles, link check, router with routing off, other links with and without OpenLinksIn, sign-ins, unsafe links.'
