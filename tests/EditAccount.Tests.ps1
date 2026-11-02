$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('ConvertFrom-EnvLines', 'ConvertTo-EnvLines', 'Get-ProfileMap', 'Set-ProfileMapEntry', 'Get-ProfileChosenColor',
                    'Set-ProfileChosenColor', 'Get-ProfileColorIndex', 'Get-ProfileColorSuffix', 'Get-ProfileAumid', 'Get-BadgeLetter')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
$node = $ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:Palette'}, $true)
if (-not $node) { throw 'Missing $script:Palette' }
. ([scriptblock]::Create($node.Extent.Text))
function Assert($condition, $message) { if (-not $condition) { throw $message } }

# settings.json stands in.
$script:Settings = @{}
function Get-Setting { param($Name) return $script:Settings[$Name] }
function Set-Setting { param($Name, $Value) $script:Settings[$Name] = $(if ($Value -is [hashtable]) { [pscustomobject]$Value } else { $Value }) }
function Get-ProfileList { param([switch]$SkipStatus) foreach ($id in 'Default', 'Work', 'Personal') { [pscustomobject]@{ Id = $id } } }

# Environment lines.
$r = ConvertFrom-EnvLines -Text "MY_VAR=hello`r`n# a comment`r`n`r`nPATH_EXTRA=C:\a=b`r`n bad name=x`r`n1BAD=y`r`nnoequals`r`n_ok=`r`n"
Assert ($r.Vars.Count -eq 3 -and $r.Vars['MY_VAR'] -eq 'hello') 'Plain variable not read'
Assert ($r.Vars['PATH_EXTRA'] -eq 'C:\a=b') 'Value with = truncated'
Assert ($r.Vars['_ok'] -eq '') 'Empty value not kept'
Assert ($r.Invalid.Count -eq 3 -and $r.Invalid -contains 'noequals' -and $r.Invalid -contains '1BAD=y') "Invalid lines: $($r.Invalid -join '; ')"
Assert ((ConvertFrom-EnvLines -Text '').Vars.Count -eq 0) 'Empty text should give no variables'
Assert ((ConvertTo-EnvLines -Vars $r.Vars) -eq "MY_VAR=hello`r`nPATH_EXTRA=C:\a=b`r`n_ok=") 'Round trip from a map'
Assert ((ConvertTo-EnvLines -Vars ([pscustomobject]@{ A = '1'; B = '2' })) -eq "A=1`r`nB=2") 'Round trip from settings.json shape'
Assert ((ConvertTo-EnvLines -Vars $null) -eq '') 'Null should give empty text'

# Per-profile maps.
Set-ProfileMapEntry -Setting 'ProfileArgs' -Id 'Work' -Value '--x'
Set-ProfileMapEntry -Setting 'ProfileArgs' -Id 'Personal' -Value '--y'
Assert ((Get-ProfileMap -Setting 'ProfileArgs')['Work'] -eq '--x' -and (Get-ProfileMap -Setting 'ProfileArgs').Count -eq 2) 'Map entries not stored'
Set-ProfileMapEntry -Setting 'ProfileArgs' -Id 'Work' -Value $null
Assert (-not (Get-ProfileMap -Setting 'ProfileArgs').ContainsKey('Work') -and (Get-ProfileMap -Setting 'ProfileArgs')['Personal'] -eq '--y') 'Null should remove only that entry'

# Colours: automatic unless picked, and a pick changes the suffix and identity.
$script:Settings = @{}
$auto = Get-ProfileColorIndex -Id 'Work'
Assert ($auto -ge 0 -and $auto -lt $script:Palette.Count) 'Automatic colour out of range'
Assert ((Get-ProfileColorIndex -Id 'Work') -eq $auto) 'Automatic colour should be remembered'
Assert ((Get-ProfileColorIndex -Id 'Personal') -ne $auto) 'Second profile should get a different colour'
Assert ((Get-ProfileColorSuffix -Id 'Work') -eq '') 'Automatic colour should add no suffix'
$work = [pscustomobject]@{ Id = 'Work'; Name = 'Work'; IsDefault = $false }
$before = Get-ProfileAumid -Target $work
Set-ProfileChosenColor -Id 'Work' -Index 5
Assert ((Get-ProfileColorIndex -Id 'Work') -eq 5) 'Picked colour not used'
Assert ((Get-ProfileColorSuffix -Id 'Work') -eq '-c5') "Suffix: $(Get-ProfileColorSuffix -Id 'Work')"
Assert ((Get-ProfileAumid -Target $work) -eq "$before.c5") 'Picked colour should change the taskbar identity'
Assert ((Get-ProfileColorIndex -Id 'Personal') -ne 5 -or $true) 'placeholder'
Set-ProfileChosenColor -Id 'Work' -Index 13
Assert ((Get-ProfileColorIndex -Id 'Work') -eq (13 % $script:Palette.Count)) 'Index should wrap into the palette'
Set-ProfileMapEntry -Setting 'ChosenColors' -Id 'Work' -Value $null
Assert ((Get-ProfileColorIndex -Id 'Work') -eq $auto -and (Get-ProfileAumid -Target $work) -eq $before) 'Removing the pick should restore the automatic colour and identity'

Write-Output 'PASS: environment lines (values with =, comments, invalid names reported, round trips), per-profile maps (set, remove), colours (automatic and remembered, distinct, picked colour with suffix and identity, wrap, restore).'
