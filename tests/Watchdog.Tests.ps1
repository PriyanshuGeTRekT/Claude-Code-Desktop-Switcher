$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Get-ClaudeExitKind', 'Select-WatchdogTargets', 'Get-WatchdogCommand', 'Get-LauncherCommand', 'Get-ShortcutStyle', 'Get-LauncherScript', 'Get-KeptProfiles', 'Get-ProfileMap')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
foreach ($name in @('UserQuitMarkers', 'ForcedCloseMarkers')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq "`$script:$name"}, $true)
    if (-not $node) { throw "Missing `$script:$name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert($condition, $message) { if (-not $condition) { throw $message } }

# The log tails from issue #9, as the desktop app writes them.
$forcedByUpdate = @(
    '[stealth-update] Triggering stealth update after idle timeout',
    '[CCD] restart: queued 0 waiting-input snapshot(s)',
    'Session stop before update took 312ms',
    'beforeQuitForUpdate handler fired, going down for update',
    'Windows session ending (close-app) - quitting the app')
$forcedBystander = @('bridge started', 'Windows session ending (close-app) - quitting the app')
$userQuit = @('something earlier', 'beforeQuit: handler fired', 'willQuit: handler fired')
$quitThenForced = @('beforeQuit: handler fired', 'willQuit: handler fired', 'app started again', 'Windows session ending (close-app) - quitting the app')
$forcedThenQuit = @('Windows session ending (close-app) - quitting the app', 'app started again', 'willQuit: handler fired')
Assert ((Get-ClaudeExitKind -LogTail $forcedByUpdate) -eq 'forced') 'Update close not seen as forced'
Assert ((Get-ClaudeExitKind -LogTail $forcedBystander) -eq 'forced') 'Session-ending close not seen as forced'
Assert ((Get-ClaudeExitKind -LogTail $userQuit) -eq 'user') 'User quit not seen as such'
Assert ((Get-ClaudeExitKind -LogTail @('beforeQuitForUpdate handler fired, going down for update')) -eq 'forced') 'beforeQuitForUpdate taken for a user quit'
Assert ((Get-ClaudeExitKind -LogTail $quitThenForced) -eq 'forced') 'The newest marker should win (forced after quit)'
Assert ((Get-ClaudeExitKind -LogTail $forcedThenQuit) -eq 'user') 'The newest marker should win (quit after forced)'
Assert ((Get-ClaudeExitKind -LogTail @('nothing of note', 'still nothing')) -eq 'unknown') 'Unrelated lines should be unknown'
Assert ((Get-ClaudeExitKind -LogTail @()) -eq 'unknown') 'An empty tail should be unknown'

# Which accounts to reopen.
$now = Get-Date
$profiles = @(
    [pscustomobject]@{ Id = 'Default'; Name = 'Default'; Pid = 10 },
    [pscustomobject]@{ Id = 'Work';    Name = 'Work';    Pid = $null },
    [pscustomobject]@{ Id = 'Night';   Name = 'Night';   Pid = $null },
    [pscustomobject]@{ Id = 'Quit';    Name = 'Quit';    Pid = $null },
    [pscustomobject]@{ Id = 'Open';    Name = 'Open';    Pid = 20 },
    [pscustomobject]@{ Id = 'Recent';  Name = 'Recent';  Pid = $null })
$kept  = @{ Work = $true; Night = $true; Quit = $true; Open = $true; Recent = $true }
$kinds = @{ Work = 'forced'; Night = 'unknown'; Quit = 'user'; Recent = 'forced' }
$last  = @{ Recent = $now.AddMinutes(-3).ToString('o'); Work = $now.AddMinutes(-30).ToString('o') }
$targets = @(Select-WatchdogTargets -Profiles $profiles -Kept $kept -ExitKinds $kinds -LastReopened $last -Now $now)
Assert ($targets.Count -eq 1 -and $targets[0].Id -eq 'Work') "Expected only Work, got: $(($targets | ForEach-Object { $_.Id }) -join ',')"
Assert (@(Select-WatchdogTargets -Profiles $profiles -Kept @{} -ExitKinds $kinds -LastReopened @{} -Now $now).Count -eq 0) 'Nothing kept should reopen nothing'
$targets = @(Select-WatchdogTargets -Profiles $profiles -Kept $kept -ExitKinds $kinds -LastReopened @{} -Now $now)
Assert (($targets | ForEach-Object { $_.Id }) -join ',' -eq 'Work,Recent') 'Without a cooldown both forced accounts should reopen'

# The kept map reads only true values.
$script:Settings = @{ KeepRunning = [pscustomobject]@{ A = $true; B = $false; C = 'yes' } }
function Get-Setting { param($Name) return $script:Settings[$Name] }
$k = Get-KeptProfiles
Assert ($k.Count -eq 1 -and $k['A']) "Kept map: $($k.Keys -join ',')"

# The task runs this script headless with -Watch.
$script:InstalledScript = 'C:\nowhere\ClaudeSwitcher.ps1'
$script:ScriptPath = $source
$cmd = Get-WatchdogCommand
Assert ($cmd.Argument -like "*-File `"$source`" -Watch" -and ($cmd.Execute -like '*conhost.exe' -or $cmd.Execute -like '*powershell.exe')) "Unexpected task command: $($cmd.Execute) $($cmd.Argument)"

Write-Output 'PASS: exit kinds from real log tails (update, session ending, user quit, newest marker wins, unknown), target selection (kept, closed, forced, cooldown), kept map, task command.'
