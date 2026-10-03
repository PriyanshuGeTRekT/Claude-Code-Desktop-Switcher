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

One request: those commands print paths containing your Windows username, and issues here
are public and permanent. Replace it with `USERNAME` before pasting. The shape of the path
is the useful part, never your actual account name. The same goes for the error log and
for any screenshots.

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

Run the isolated chat-transfer regression tests with Windows PowerShell 5.1 and PowerShell 7:

    powershell -NoProfile -File .\tests\ChatTransfer.Tests.ps1
    pwsh -NoProfile -File .\tests\ChatTransfer.Tests.ps1

These tests use temporary session stores and never launch Claude or read real chats.

Then actually run the thing. Most other behavior still needs manual checks because it
touches real processes, real windows and real profile directories. At minimum, check that:

- The window opens and lists your profiles with correct running state, including while
  Claude Code sessions are open (they run a `claude.exe` of their own).
- **Add account** (and `-AddAccount`) creates `Account N` and opens it at the sign-in
  screen, and **Switch to** on an open profile brings its window forward rather than
  starting a second copy.
- Rename, delete (refused while the profile is open) and **Transfer chats** work.
- Closing the window leaves it in the tray, and launching the switcher again brings the
  same window back instead of starting a second one.
- `-List`, `-Launch`, `-Shortcut`, `-Tray` and `-Install` still behave.
- A profile launched from a desktop shortcut opens a **visible** Claude window, and no
  console window flashes up on the way.

That last one matters more than it looks. See the notes below.

### Testing without touching your real accounts

Everything the switcher writes lives under `%LOCALAPPDATA%` and `%APPDATA%`, and it will
launch whatever `-ClaudePath` points at. So in a fresh PowerShell window:

```powershell
$env:LOCALAPPDATA = "$env:TEMP\ccsw\local"; $env:APPDATA = "$env:TEMP\ccsw\roaming"
.\ClaudeSwitcher.ps1 -ClaudePath C:\path\to\any-windowed-app.exe
```

gives you a throwaway set of profiles. Any small windowed program renamed to `Claude.exe`
works as a stand-in, which also makes running detection work. Desktop and Start menu
shortcuts still go to the real locations, so prefer `-Shortcut <name> -To <folder>` there.

## Traps worth knowing about

All of these have already caused bugs in this repo, so they are worth reading before you
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
Shortcuts now run PowerShell under `conhost.exe --headless`, which has no window at all and
passes no hidden show state on, so keep them that way.

**`$_` changes meaning inside `switch`.** In a WinForms event handler `$_` is the event
args, but inside a `switch` block it becomes the value being switched on. Setting
`$_.Handled` there fails, and WinForms reports it with its own "Unhandled exception"
dialog. Copy the event args to a variable before the `switch`.

**Keep the script ASCII only.** Without a BOM, Windows PowerShell 5.1 reads the file in
the system codepage, so any non-ASCII character renders as garbage on other locales.

## Style

Match what is already there. Comments explain why something is done, not what the line
does. If a piece of code exists to work around a Windows quirk, say so, because the next
person will otherwise remove it.

## Reporting bugs

Open an issue with your Windows version, whether your Claude desktop is the Store build or
an installer build, and the contents of `%LOCALAPPDATA%\ClaudeProfiles\switcher-error.log`
if there is anything in it.

The switcher's own files (installed copy, icons) live in
`%LOCALAPPDATA%\ClaudeProfiles\.switcher`, and settings, labels and colours in
`%LOCALAPPDATA%\ClaudeProfiles\settings.json`.
