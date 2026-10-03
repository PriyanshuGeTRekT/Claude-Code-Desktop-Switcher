$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Get-FirstValue','Get-CodeSessionRoot','Get-CodeSessions','Get-CodeSessionStore','Copy-CodeSession')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
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
    Write-Output 'PASS: MSIX source/target, copy identity, shared transcript, duplicate preservation, classic and direct paths, unused profile.'
} finally {
    $env:LOCALAPPDATA = $originalLocal
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected fixture path' }
    if (Test-Path -LiteralPath $resolved) {
        Get-ChildItem -LiteralPath $resolved -Recurse -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
        Get-ChildItem -LiteralPath $resolved -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
        Remove-Item -LiteralPath $resolved
    }
}