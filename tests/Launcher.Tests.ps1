$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Get-ShortcutStyle', 'Get-LauncherCommand', 'Get-LauncherScript', 'Hide-UserName', 'Get-LogTailText')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
$node = $ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:ShortcutStyles'}, $true)
if (-not $node) { throw 'Missing $script:ShortcutStyles' }
. ([scriptblock]::Create($node.Extent.Text))
function Assert($condition, $message) { if (-not $condition) { throw $message } }

$script:Settings = @{}
function Get-Setting { param($Name) return $script:Settings[$Name] }
$script:InstalledScript = 'C:\Tools\Claude Switcher\ClaudeSwitcher.ps1'
$script:ScriptPath = $script:InstalledScript
function Test-Path { param($LiteralPath, $Path, $PathType) return $true }   # the installed copy and conhost both "exist"
$onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
if (-not $env:SystemRoot) { $env:SystemRoot = 'C:\Windows' }

# The style: a known value or the default.
Assert ((Get-ShortcutStyle) -eq 'headless') 'No setting should mean headless'
$script:Settings = @{ ShortcutStyle = 'nonsense' }
Assert ((Get-ShortcutStyle) -eq 'headless') 'An unknown style should fall back to headless'
foreach ($style in $script:ShortcutStyles) { $script:Settings = @{ ShortcutStyle = $style }; Assert ((Get-ShortcutStyle) -eq $style) "Style $style not read" }

# What each style builds. The script path, quoted, and the arguments are always there.
$script:Settings = @{}
$cmd = Get-LauncherCommand -ScriptArgs '-Launch "Work"'
Assert ($cmd.Argument -like '*-File "C:\Tools\Claude Switcher\ClaudeSwitcher.ps1" -Launch "Work"') "Script and arguments missing: $($cmd.Argument)"
if ($onWindows -and [Environment]::OSVersion.Version.Build -ge 17763) {
    Assert ($cmd.Execute -like '*\conhost.exe' -and $cmd.Argument -like '--headless "*powershell.exe" -NoProfile -ExecutionPolicy Bypass -File *') "Headless shape: $($cmd.Execute) $($cmd.Argument)"
    Assert ($null -eq $cmd.WindowStyle) 'Headless needs no window style'
}
$script:Settings = @{ ShortcutStyle = 'hidden' }
$cmd = Get-LauncherCommand -ScriptArgs '-Watch'
Assert ($cmd.Execute -like '*\powershell.exe' -and $cmd.Argument -eq '-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "C:\Tools\Claude Switcher\ClaudeSwitcher.ps1" -Watch') "Hidden shape: $($cmd.Argument)"
$cmd = Get-LauncherCommand -Visible
Assert ($cmd.Execute -like '*\powershell.exe' -and $cmd.Argument -eq '-NoProfile -ExecutionPolicy Bypass -File "C:\Tools\Claude Switcher\ClaudeSwitcher.ps1"' -and $cmd.WindowStyle -eq 7) "Visible hidden-style shape: $($cmd.Argument) / $($cmd.WindowStyle)"
$script:Settings = @{ ShortcutStyle = 'plain' }
$cmd = Get-LauncherCommand -ScriptArgs '-HandleLink "%1"'
Assert ($cmd.Argument -eq '-WindowStyle Hidden -NoProfile -File "C:\Tools\Claude Switcher\ClaudeSwitcher.ps1" -HandleLink "%1"') "Plain shape should drop the policy switch: $($cmd.Argument)"
Assert ($cmd.Argument -notlike '*conhost*' -and $cmd.Execute -notlike '*conhost*') 'Plain shape should not use conhost'

# The user name is replaced wherever it appears, whatever its case.
$me = $env:USERNAME
if ($me) {
    $text = "C:\Users\$me\AppData and c:\users\$($me.ToUpper())\x and $me"
    $hidden = Hide-UserName -Text $text
    Assert ($hidden -notmatch [regex]::Escape($me) -and $hidden -eq 'C:\Users\<user>\AppData and c:\users\<user>\x and <user>') "Redaction: $hidden"
}
Assert ((Hide-UserName -Text 'nothing personal') -eq 'nothing personal') 'Text without the name should be untouched'

# Log tails: a missing log is said so, not an error.
Remove-Item Function:\Test-Path   # the real one from here on
$tail = @(Get-LogTailText -Path (Join-Path ([IO.Path]::GetTempPath()) ('claude-switcher-missing-' + [guid]::NewGuid().ToString('N') + '.log')))
Assert ($tail.Count -eq 1 -and $tail[0] -like '  (no claude-switcher-missing-*.log)') "Missing log: $($tail -join '|')"

Write-Output 'PASS: shortcut style read and defaulted, launcher shapes (headless, hidden, visible, plain without the policy switch), user name redaction, missing log tail.'
