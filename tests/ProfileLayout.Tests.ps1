$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Get-Setting','Get-ProfilePath','Get-ProfileLabels','Get-ProfileList','Resolve-ClaudeProfile','Test-ProfileName','Move-LegacyProfileFolder')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
$prefix = $ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:ProfileDirPrefix'}, $true)
if (-not $prefix) { throw 'Missing $script:ProfileDirPrefix' }
$script:ProfileDirPrefix = $prefix.Right.Expression.Value
function Assert($condition, $message) { if (-not $condition) { throw $message } }
# Stands in for WMI: which profile folders a running Claude holds open.
$script:Running = @{}
function Get-RunningProfileMap { return $script:Running }
function Get-LastUsed { param($Path) return $null }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('claude-layout-test-' + [guid]::NewGuid().ToString('N'))
$originalLocal = $env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA = Join-Path $fixture 'Local'
    $script:ProfileRoot  = Join-Path $env:LOCALAPPDATA 'ClaudeProfiles'
    $script:SettingsPath = Join-Path $script:ProfileRoot 'settings.json'
    $script:DefaultName  = 'Default'
    $cache = Join-Path $env:LOCALAPPDATA 'Packages\TestPackage\LocalCache'
    $script:ClaudeApp = [pscustomobject]@{ Kind = 'Msix'; DefaultProfilePath = (Join-Path $cache 'Roaming\Claude') }
    $script:DefaultProfilePath = $script:ClaudeApp.DefaultProfilePath
    New-Item -ItemType Directory -Path $script:ProfileRoot, (Join-Path $script:ProfileRoot '.switcher') -Force | Out-Null
    $new = { param($id) Join-Path $env:LOCALAPPDATA ($script:ProfileDirPrefix + $id) }
    $old = { param($id) Join-Path $script:ProfileRoot $id }

    # Where a profile lives: directly under %LOCALAPPDATA%, as Cowork's VM needs.
    Assert ((Get-ProfilePath -Id 'Work') -eq (& $new 'Work')) 'New profile not placed directly under LOCALAPPDATA'
    Assert ((Split-Path (Get-ProfilePath -Id 'Work') -Parent) -eq $env:LOCALAPPDATA) 'Profile folder nested'
    Assert ((Get-ProfilePath -Id 'Default') -eq $script:DefaultProfilePath) 'Default moved'
    New-Item -ItemType Directory -Path (& $old 'Busy') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path (& $old 'Busy') 'config.json'), '{}')
    Assert ((Get-ProfilePath -Id 'Busy') -eq (& $old 'Busy')) 'Not-yet-moved profile not found in the old place'
    # An empty leftover at the new place must not win over the real data.
    New-Item -ItemType Directory -Path (Join-Path (& $new 'Busy') 'ChromeNativeHost') -Force | Out-Null
    Assert ((Get-ProfilePath -Id 'Busy') -eq (& $old 'Busy')) 'Empty leftover chosen over the real profile'

    # Listing finds both places, once each, and never the switcher's own folder.
    New-Item -ItemType Directory -Path (& $new 'Work') -Force | Out-Null
    $ids = @(Get-ProfileList -SkipStatus | ForEach-Object { $_.Id })
    Assert (($ids -join ',') -eq 'Default,Busy,Work') "Unexpected profile list: $($ids -join ',')"
    New-Item -ItemType Directory -Path (Join-Path $env:LOCALAPPDATA 'ClaudeProfileSwitcher') -Force | Out-Null
    Assert (@(Get-ProfileList -SkipStatus).Count -eq 3) 'A folder that is not a profile was listed'

    # Names already taken in either place are refused.
    Assert ((Test-ProfileName -Name 'Work') -like '*already exists*') 'Existing profile name accepted'
    New-Item -ItemType File -Path (& $new 'Taken') -Force | Out-Null
    Assert ((Test-ProfileName -Name 'Taken') -like '*already taken*') 'Name of an existing file accepted'
    Assert ($null -eq (Test-ProfileName -Name 'Fresh')) 'Free name refused'
    Remove-Item -LiteralPath (& $new 'Taken') -Force

    # The one-time move.
    New-Item -ItemType Directory -Path (& $old 'Running'), (& $old 'Blocked'), (& $old 'Personal') -Force | Out-Null
    foreach ($id in 'Running', 'Blocked', 'Personal') { [IO.File]::WriteAllText((Join-Path (& $old $id) 'config.json'), "{""id"":""$id""}") }
    New-Item -ItemType Directory -Path (& $new 'Blocked') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path (& $new 'Blocked') 'keep.txt'), 'someone else''s data')
    $redirectedOld = Join-Path $cache 'Local\ClaudeProfiles\Personal\claude-code-sessions'
    New-Item -ItemType Directory -Path $redirectedOld -Force | Out-Null
    $script:Running = @{ (& $old 'Running') = 42 }
    Move-LegacyProfileFolder
    Assert ((Test-Path (Join-Path (& $new 'Personal') 'config.json')) -and -not (Test-Path (& $old 'Personal'))) 'Profile not moved'
    Assert (Test-Path (Join-Path $cache 'Local\ClaudeProfile-Personal\claude-code-sessions')) 'Store-redirected files not moved along'
    Assert (Test-Path (Join-Path (& $old 'Running') 'config.json')) 'Running profile moved'
    Assert ((Test-Path (Join-Path (& $old 'Blocked') 'config.json')) -and (Test-Path (Join-Path (& $new 'Blocked') 'keep.txt'))) 'Non-empty target overwritten'
    Assert ((Test-Path (Join-Path (& $new 'Busy') 'config.json')) -and -not (Test-Path (& $old 'Busy'))) 'Empty leftover target not replaced'
    Assert (Test-Path (Join-Path $script:ProfileRoot '.switcher')) 'Switcher folder moved'
    Assert ((Get-ProfilePath -Id 'Running') -eq (& $old 'Running')) 'Running profile not found where it stayed'
    $script:Running = @{}
    Move-LegacyProfileFolder
    Assert ((Test-Path (Join-Path (& $new 'Running') 'config.json')) -and -not (Test-Path (& $old 'Running'))) 'Profile not moved once it stopped'

    Write-Output 'PASS: profiles directly under LOCALAPPDATA, old place still found, empty leftover ignored, listing, taken names, one-time move (running, non-empty and empty targets, Store redirect).'
} finally {
    $env:LOCALAPPDATA = $originalLocal
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected fixture path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
