$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Get-BadgeLetter','Get-ProfileAumid','Get-LauncherScript','Get-ProfileRelaunchCommand','Initialize-TaskbarIdentity')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
$assignment = $ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and
                         $n.Left.Extent.Text -eq '$script:TaskbarIdentitySource'}, $true)
if (-not $assignment) { throw 'Missing $script:TaskbarIdentitySource' }
$script:TaskbarIdentitySource = $assignment.Right.Expression.Value
function Assert($condition, $message) { if (-not $condition) { throw $message } }
$onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('claude-identity-test-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null

    # Identities: valid, stable, distinct per profile, and new when the badge letter changes.
    $work    = [pscustomobject]@{ Id = 'Work';      Name = 'Work' }
    $renamed = [pscustomobject]@{ Id = 'Work';      Name = 'Wonder' }
    $moved   = [pscustomobject]@{ Id = 'Work';      Name = 'Personal' }
    $spaced  = [pscustomobject]@{ Id = 'Account 2'; Name = 'Account 2' }
    $joined  = [pscustomobject]@{ Id = 'Account2';  Name = 'Account2' }
    $long    = [pscustomobject]@{ Id = ('x' * 40);  Name = 'Long' }
    $symbol  = [pscustomobject]@{ Id = 'Caf-e 1';   Name = '#1 cafe' }
    foreach ($t in @($work, $spaced, $long, $symbol)) {
        $id = Get-ProfileAumid -Target $t
        Assert ($id -match '^[A-Za-z0-9.]+$') "Identity has characters Windows may reject: $id"
        Assert ($id.Length -le 128) "Identity too long: $id"
        Assert ($id -ceq (Get-ProfileAumid -Target $t)) "Identity not stable: $id"
    }
    Assert ((Get-ProfileAumid -Target $work) -ceq (Get-ProfileAumid -Target $renamed)) 'Same letter changed the identity'
    Assert ((Get-ProfileAumid -Target $work) -cne (Get-ProfileAumid -Target $moved)) 'New letter kept the old identity'
    Assert ((Get-ProfileAumid -Target $spaced) -cne (Get-ProfileAumid -Target $joined)) 'Two profiles share an identity'

    # The helper compiles; a typo in the C# would otherwise only show up on a real launch.
    Initialize-TaskbarIdentity
    Assert ('ClaudeSwitcher.TaskbarIdentity' -as [type]) 'Taskbar identity helper did not load'

    if (-not $onWindows) {
        Write-Output 'PASS (portable part): identity format, stability, rename and uniqueness, helper compiles.'
        return
    }

    # What a pinned button runs.
    $script:InstalledScript = Join-Path $fixture 'not-installed\ClaudeSwitcher.ps1'
    $script:ScriptPath      = 'C:\Tools\Claude Switcher\ClaudeSwitcher.ps1'
    $cmd = Get-ProfileRelaunchCommand -Target $spaced
    Assert ($cmd -like '*-File "C:\Tools\Claude Switcher\ClaudeSwitcher.ps1" -Launch "Account 2"') "Unexpected relaunch command: $cmd"

    # A shortcut carries the identity, so a pinned copy shares the window's button.
    $lnk  = Join-Path $fixture 'Claude - Work.lnk'
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $link.TargetPath = Join-Path $env:SystemRoot 'System32\notepad.exe'
    $link.Save()
    Assert ($null -eq [ClaudeSwitcher.TaskbarIdentity]::GetShortcutIdentity($lnk)) 'New shortcut already has an identity'
    $want = Get-ProfileAumid -Target $work
    [ClaudeSwitcher.TaskbarIdentity]::SetShortcutIdentity($lnk, $want)
    Assert ([ClaudeSwitcher.TaskbarIdentity]::GetShortcutIdentity($lnk) -ceq $want) 'Shortcut identity not saved'
    Assert ((New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath -like '*notepad.exe') 'Stamping changed the shortcut target'

    Write-Output 'PASS: identity format, stability, rename and uniqueness, helper compiles, relaunch command, shortcut identity.'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected fixture path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
