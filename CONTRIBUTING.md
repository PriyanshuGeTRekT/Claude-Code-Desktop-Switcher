# Contributing

Thanks for taking an interest. This is a small tool and contributions of any size are
welcome, including typo fixes and bug reports.

## The most useful thing you can contribute

Confirmation or fixes for the **installer build** of Claude desktop. Development happened
on the Store (MSIX) build, so that path is well tested. The code that detects a regular
installer build is written but has never run against a real install.

If you have Claude desktop installed from an installer rather than the Microsoft Store,
running this and pasting the output into an issue is genuinely helpful:

```powershell
Get-AppxPackage -Name Claude | Select-Object PackageFamilyName, InstallLocation
Test-Path "$env:LOCALAPPDATA\AnthropicClaude"
Test-Path "$env:APPDATA\Claude"
.\ClaudeSwitcher.ps1 -List
```

Reports from Windows 10 are also welcome, since testing happened on Windows 11.

## Getting set up

There is no build step and no dependencies. Clone the repo and run the script:

```powershell
powershell -ExecutionPolicy Bypass -File .\ClaudeSwitcher.ps1
```

If you downloaded a ZIP instead of cloning, unblock the files first:

```powershell
Get-ChildItem -Recurse | Unblock-File
```

## Before you open a pull request

Run the linter. CI runs the same check, and it only fails on errors, but please look at
warnings too:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path .\ClaudeSwitcher.ps1
```

Then actually run the thing. There are no automated tests, because almost everything here
touches real processes, real windows and real profile directories. At minimum, check that:

- The window opens and lists your profiles with correct running state.
- Creating a profile, launching it and deleting it all work.
- `-List`, `-Shortcut` and `-Install` still behave.
- A profile launched from a desktop shortcut opens a **visible** Claude window.

That last one matters more than it looks. See the notes below.

## Two traps worth knowing about

Both of these have already caused bugs in this repo, so they are worth reading before you
change anything.

**PowerShell variable names are case insensitive, and parameters live in script scope.**
A script scope variable that shares a name with a parameter will silently reassign that
parameter and fail its type constraint. `$list` clobbering `[switch]$List` broke startup
once, and `$script:Install` clobbering `[switch]$Install` broke it again later. Keep
internal state named clearly away from anything in the param block.

**Show state is inherited through STARTUPINFO.** If a process is started hidden, the first
window a WinForms app shows will also be hidden, and any child process it launches
inherits the same show state unless told otherwise. This is why the script hides its own
console rather than being launched with `-WindowStyle Hidden`, and why Claude is launched
with an explicit `-WindowStyle Normal`. If you touch launching or shortcut creation,
verify a real window actually appears rather than trusting that the process started.

## Style

Match what is already there. Comments explain why something is done, not what the line
does. If a piece of code exists to work around a Windows quirk, say so, because the next
person will otherwise remove it.

## Reporting bugs

Open an issue with your Windows version, whether your Claude desktop is the Store build or
an installer build, and the contents of `%LOCALAPPDATA%\ClaudeProfiles\switcher-error.log`
if there is anything in it.
