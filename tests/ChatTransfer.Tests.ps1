$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Get-FirstValue','Get-CodeSessionRoot','Get-CodeSessions','Get-CodeSessionStore','Copy-CodeSession','Get-PackageCachePath','Resolve-ClaudeDataPath')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
$marker = $ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:DataLeftMarker'}, $true)
if (-not $marker) { throw 'Missing $script:DataLeftMarker' }
$script:DataLeftMarker = $marker.Right.Expression.Value
function Assert($condition, $message) { if (-not $condition) { throw $message } }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('claude-transfer-test-' + [guid]::NewGuid().ToString('N'))
$originalLocal = $env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA = Join-Path $fixture 'Local'
    $cache = Join-Path $env:LOCALAPPDATA 'Packages\TestPackage\LocalCache'
    $script:ClaudeApp = [pscustomobject]@{Kind='Msix'; DefaultProfilePath=(Join-Path $cache 'Roaming\Claude')}
    $secondary = [pscustomobject]@{Path=(Join-Path $env:LOCALAPPDATA 'ClaudeProfiles\Secondary')}
    $sourceProfile = [pscustomobject]@{Path=$script:ClaudeApp.DefaultProfilePath}
    $sourceStore = Join-Path $sourceProfile.Path 'claude-code-sessions\source-account\source-org'
    $targetStore = Join-Path $cache 'Local\ClaudeProfiles\Secondary\claude-code-sessions\target-account\target-org'
    New-Item -ItemType Directory -Path $sourceStore,$targetStore,$secondary.Path -Force | Out-Null
    $chat = '{"title":"Sample","cwd":"C:\\project","account":"source-account","org":"source-org","sessionId":"same-transcript","path":"C:\\source-account\\scratch"}'
    [IO.File]::WriteAllText((Join-Path $sourceStore 'local_test.json'), $chat)
    $sessions = @(Get-CodeSessions -Source $sourceProfile)
    Assert ($sessions.Count -eq 1) 'Default MSIX source chat missing'
    $store = Get-CodeSessionStore -Target $secondary
    Assert ($null -ne $store -and $store.FullName -eq $targetStore) 'MSIX redirected target not found'
    Assert ((Copy-CodeSession -Session $sessions[0] -Store $store) -eq 'copied') 'Copy failed'
    $copied = Get-Content -LiteralPath (Join-Path $targetStore 'local_test.json') -Raw | ConvertFrom-Json
    Assert ($copied.account -eq 'target-account' -and $copied.org -eq 'target-org') 'Target identity not rewritten'
    Assert ($copied.sessionId -eq 'same-transcript' -and $copied.path -eq 'C:\source-account\scratch') 'Transcript or path changed'
    Assert (@(Get-CodeSessions -Source $secondary).Count -eq 1) 'Redirected source chat missing'
    Assert ((Copy-CodeSession -Session $sessions[0] -Store $store) -eq 'exists') 'Existing chat overwritten'
    $script:ClaudeApp.Kind = 'Classic'
    Assert ((Get-CodeSessionRoot -TargetProfile $secondary) -eq (Join-Path $secondary.Path 'claude-code-sessions')) 'Classic profile redirected'
    $script:ClaudeApp.Kind = 'Msix'
    $missing = [pscustomobject]@{Path=(Join-Path $env:LOCALAPPDATA 'ClaudeProfiles\Unused')}
    Assert ($null -eq (Get-CodeSessionStore -Target $missing)) 'Unused profile incorrectly accepted'
    $fallback = Join-Path $missing.Path 'claude-code-sessions\account\org'
    New-Item -ItemType Directory -Path $fallback -Force | Out-Null
    Assert ((Get-CodeSessionStore -Target $missing).FullName -eq $fallback) 'Direct store fallback failed'

    # Newer builds move Default's data to %LOCALAPPDATA%\Claude-Data\<name> and leave only a
    # .user-data-left.<name> marker in the install's folder.
    $installed = Join-Path $cache 'Roaming\ClaudeMoved'
    $dataRoot  = Join-Path $env:LOCALAPPDATA 'Claude-Data'
    $moved     = Join-Path $dataRoot 'testpackage'
    New-Item -ItemType Directory -Path $installed, $moved -Force | Out-Null
    Assert ((Resolve-ClaudeDataPath -Path $installed) -eq $installed) 'Folder without a marker treated as moved'
    [IO.File]::WriteAllText((Join-Path $installed "$($script:DataLeftMarker)testpackage"), '{"v":1}')
    Assert ((Resolve-ClaudeDataPath -Path $installed) -eq $installed) 'Marker followed to a folder Claude never wrote config.json in'
    [IO.File]::WriteAllText((Join-Path $moved 'config.json'), '{}')
    Assert ((Resolve-ClaudeDataPath -Path $installed) -eq $moved) 'Moved data folder not found from the marker'
    Assert ((Resolve-ClaudeDataPath -Path '') -eq '') 'Empty path not passed through'
    # A marker's name is used as a plain folder name only, and a bare marker is no name at all.
    $sneaky = Join-Path $cache 'Roaming\ClaudeSneaky'
    New-Item -ItemType Directory -Path $sneaky, (Join-Path $dataRoot 'not plain') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $dataRoot 'not plain\config.json'), '{}')
    [IO.File]::WriteAllText((Join-Path $sneaky "$($script:DataLeftMarker)not plain"), '')
    [IO.File]::WriteAllText((Join-Path $sneaky $script:DataLeftMarker.TrimEnd('.')), '')
    Assert ((Resolve-ClaudeDataPath -Path $sneaky) -eq $sneaky) 'Marker name that is not a plain folder name followed'
    # No marker and no data of its own: a Store build's folder is named after its package family.
    $bare = Join-Path $cache 'Roaming\ClaudeBare'
    New-Item -ItemType Directory -Path $bare -Force | Out-Null
    Assert ((Resolve-ClaudeDataPath -Path $bare -AppUserModelId 'TestPackage!Claude') -eq $moved) 'Package family fallback not used'
    [IO.File]::WriteAllText((Join-Path $bare 'config.json'), '{}')
    Assert ((Resolve-ClaudeDataPath -Path $bare -AppUserModelId 'TestPackage!Claude') -eq $bare) 'Folder with its own data replaced by the package family guess'

    # Transfer from and to Default once its data has moved.
    $movedDefault = [pscustomobject]@{Path=$moved}
    $movedStore = Join-Path $moved 'claude-code-sessions\default-account\default-org'
    New-Item -ItemType Directory -Path $movedStore -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $movedStore 'local_moved.json'), '{"title":"Moved","cwd":"C:\\other","account":"default-account","org":"default-org"}')
    $fromMoved = @(Get-CodeSessions -Source $movedDefault)
    Assert ($fromMoved.Count -eq 1 -and $fromMoved[0].Title -eq 'Moved') 'Chat in the moved Default folder not listed'
    Assert ((Copy-CodeSession -Session $fromMoved[0] -Store (Get-CodeSessionStore -Target $secondary)) -eq 'copied') 'Copy from the moved Default failed'
    $intoSecondary = Get-Content -LiteralPath (Join-Path $targetStore 'local_moved.json') -Raw | ConvertFrom-Json
    Assert ($intoSecondary.account -eq 'target-account' -and $intoSecondary.org -eq 'target-org') 'Identity not rewritten for a chat from the moved Default'
    Assert ((Get-CodeSessionStore -Target $movedDefault).FullName -eq $movedStore) 'Moved Default not accepted as a target'
    # Extra profiles keep finding the package's redirected files: the LocalCache is anchored on
    # the folder Claude was installed with, not on where Default's data went.
    Assert ((Get-PackageCachePath) -eq $cache) 'Package LocalCache derived from the wrong folder'
    Assert ((Get-CodeSessionRoot -TargetProfile $secondary) -eq (Split-Path $targetStore -Parent | Split-Path -Parent)) 'Redirected extra profile lost after Default moved'
    Write-Output 'PASS: MSIX source/target, copy identity, shared transcript, duplicate preservation, classic and direct paths, unused profile, Default data moved to Claude-Data (marker, guards, package family fallback, transfer both ways, LocalCache anchor).'
} finally {
    $env:LOCALAPPDATA = $originalLocal
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected fixture path' }
    if (Test-Path -LiteralPath $resolved) {
        Get-ChildItem -LiteralPath $resolved -Recurse -File -Force | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
        Get-ChildItem -LiteralPath $resolved -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
        Remove-Item -LiteralPath $resolved
    }
}
