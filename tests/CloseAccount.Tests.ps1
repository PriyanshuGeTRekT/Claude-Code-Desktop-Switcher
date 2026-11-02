$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Stop-ProcessGroup', 'Get-ClaudeProcessFamily')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert($condition, $message) { if (-not $condition) { throw $message } }
$engine = (Get-Process -Id $PID).Path

# Ending a process that has no window to close politely: it is ended and waited for.
$child = Start-Process -FilePath $engine -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120' -PassThru -WindowStyle Hidden
try {
    Assert (-not $child.HasExited) 'Stand-in process did not start'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Stop-ProcessGroup -ProcessIds @($child.Id) -MainProcessId $child.Id -GraceSeconds 1
    Assert ($child.HasExited) 'Process still running after Stop-ProcessGroup'
    Assert ($sw.Elapsed.TotalSeconds -lt 20) "Stopping took $([int]$sw.Elapsed.TotalSeconds) s"
    # A process that is already gone is not an error.
    Stop-ProcessGroup -ProcessIds @($child.Id) -MainProcessId $child.Id -GraceSeconds 1
} finally {
    if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
}

# The family of a process with no Claude.exe children is the process alone.
$family = @(Get-ClaudeProcessFamily -MainProcessId $PID)
Assert ($family.Count -eq 1 -and $family[0] -eq $PID) "Unexpected family: $($family -join ',')"

# -Version answers before the script looks for Claude, so it works anywhere.
$out = & $engine -NoProfile -ExecutionPolicy Bypass -File $source -Version 2>&1
Assert ("$out" -match '^\d+\.\d+\.\d+\S*$') "Unexpected -Version output: $out"

Write-Output 'PASS: stand-in process ended and waited for, already-gone process tolerated, process family, -Version without Claude.'
