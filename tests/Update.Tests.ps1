$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Get-PublishedHash', 'Get-ScriptVersion', 'Compare-SwitcherVersion', 'Test-DownloadedScript', 'Get-UpdateTarget', 'Get-UpdateTargetVersion', 'New-TempFileName')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert($condition, $message) { if (-not $condition) { throw $message } }
# No network here: everything below works on local files.

# The checksum file, as the release builds it, and in the sha256sum binary form.
$sums = "abc123`r`n0123456789abcdef0123456789abcdef0123456789abcdef0123456789ABCDEF  ClaudeSwitcher.ps1`r`nffff  *Other.ps1`r`n" +
        "1111111111111111111111111111111111111111111111111111111111111111 *ClaudeProfileSwitcher-v9.zip`r`n"
Assert ((Get-PublishedHash -Sums $sums -File 'ClaudeSwitcher.ps1') -eq '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef') 'Checksum not read (lower-cased)'
Assert ((Get-PublishedHash -Sums $sums -File 'ClaudeProfileSwitcher-v9.zip') -eq ('1' * 64)) 'Checksum with the binary marker not read'
Assert ($null -eq (Get-PublishedHash -Sums $sums -File 'Missing.ps1')) 'A missing file should give no checksum'
Assert ($null -eq (Get-PublishedHash -Sums $sums -File 'Other.ps1')) 'A short hash should not count'

# The version line, read from the real script.
$real = Get-Content -LiteralPath $source -Raw
$version = Get-ScriptVersion -Text $real
Assert ($version -match '^\d+\.\d+\.\d+') "Version not read from the script: $version"
Assert ($null -eq (Get-ScriptVersion -Text 'nothing here')) 'A version was found in text without one'

# Version order.
Assert ((Compare-SwitcherVersion -A '2.3.0' -B '2.10.0') -eq -1) '2.3.0 should be older than 2.10.0'
Assert ((Compare-SwitcherVersion -A '2.10.0' -B '2.3.0') -eq 1) '2.10.0 should be newer than 2.3.0'
Assert ((Compare-SwitcherVersion -A '2.3.0' -B '2.3.0') -eq 0) 'Equal versions'
Assert ((Compare-SwitcherVersion -A '2.3' -B '2.3.0') -eq 0) 'A missing part should count as 0'
Assert ((Compare-SwitcherVersion -A '2.4.0-beta' -B '2.3.0') -eq 1) 'A pre-release tag should be ignored for the order'
Assert ((Compare-SwitcherVersion -A '3.0.0' -B '2.99.99') -eq 1) 'Major version should win'

# A downloaded script: accepted with the right checksum, refused otherwise.
$copy = New-TempFileName -Suffix '.ps1'
try {
    Copy-Item -LiteralPath $source -Destination $copy
    $hash = (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash
    Assert ((Test-DownloadedScript -Path $copy -ExpectedHash $hash.ToUpper()) -eq $version) 'A matching script should give its version'
    $refused = $false
    try { Test-DownloadedScript -Path $copy -ExpectedHash ('0' * 64) | Out-Null } catch { $refused = $_.Exception.Message -like '*checksum*' }
    Assert $refused 'A wrong checksum was accepted'
    [IO.File]::WriteAllText($copy, "`$script:SwitcherVersion = '9.9.9'`r`nfunction broken {`r`n")
    $hash = (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash
    $refused = $false
    try { Test-DownloadedScript -Path $copy -ExpectedHash $hash | Out-Null } catch { $refused = $_.Exception.Message -like '*parse*' }
    Assert $refused 'A script that does not parse was accepted'
    # A release from before the version line (2.3.0) verifies but has no version: never newer.
    [IO.File]::WriteAllText($copy, "Write-Output 'no version here'`r`n")
    $hash = (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash
    Assert ($null -eq (Test-DownloadedScript -Path $copy -ExpectedHash $hash)) 'A script without a version should give no version'
} finally { Remove-Item -LiteralPath $copy -Force -ErrorAction SilentlyContinue }

# Where an update goes: the installed copy when there is one, else the running script.
$script:ScriptPath = $source
$script:InstalledScript = New-TempFileName -Suffix '.ps1'
Assert ((Get-UpdateTarget) -eq $source) 'Without an installed copy the running script should be the target'
[IO.File]::WriteAllText($script:InstalledScript, '')
try { Assert ((Get-UpdateTarget) -eq $script:InstalledScript) 'The installed copy should be the target' }
finally { Remove-Item -LiteralPath $script:InstalledScript -Force -ErrorAction SilentlyContinue }

# The version compared is the target's, not the running script's: a repo copy running
# while an older installed copy exists must compare with the installed one.
$script:SwitcherVersion = '9.9.9'
$script:InstalledScript = New-TempFileName -Suffix '.ps1'
try {
    [IO.File]::WriteAllText($script:InstalledScript, "`$script:SwitcherVersion = '2.1.0'`r`n")
    Assert ((Get-UpdateTargetVersion) -eq '2.1.0') "Target version: $(Get-UpdateTargetVersion)"
    [IO.File]::WriteAllText($script:InstalledScript, "Write-Output 'from before the version line'`r`n")
    Assert ((Get-UpdateTargetVersion) -eq '0') 'An installed copy without a version should count as 0'
} finally { Remove-Item -LiteralPath $script:InstalledScript -Force -ErrorAction SilentlyContinue }
Assert ((Get-UpdateTargetVersion) -eq '9.9.9') 'Without an installed copy the running version should be used'

Write-Output 'PASS: published checksum parsing, version line, version order, downloaded script accepted or refused (checksum, parse), no version for old releases, update target, the version of the target.'
