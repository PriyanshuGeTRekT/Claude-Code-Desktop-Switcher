# Contributing

Thanks for taking an interest. This is a small tool and contributions of any size are
welcome, including typo fixes and bug reports.

## The most useful thing you can contribute

Confirmation or fixes for the **Store (MSIX) build** of Claude desktop. The original
version was developed against the Store build; the taskbar identity, sign-in routing and
edit features were developed and tested against the **installer build** on Windows 11, and
the Store path has not been re-tested since. If you have the Store build, running this and
pasting the output into an issue is genuinely helpful:

```powershell
Get-AppxPackage -Name Claude | Select-Object PackageFamilyName, InstallLocation
.\ClaudeSwitcher.ps1 -Status
```

Reports from Windows 10 are also welcome, since testing happened on Windows 11.

One request: those commands print paths containing your Windows username, and issues here
are public and permanent. Replace it with `USERNAME` before pasting. The shape of the path
is the useful part, never your actual account name. The same goes for the logs and for
any screenshots.

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
Invoke-ScriptAnalyzer -Path . -Recurse
```

Also keep every `.ps1` ASCII only. Without a byte order mark, Windows PowerShell 5.1 reads
the files in the system codepage, so a stray typographic quote or dash renders as garbage
on other locales. CI parse-checks every script.

Then actually run the thing. There are no automated tests, because almost everything here
touches real processes, real windows and real profile directories. At minimum, check that:

- The window opens and lists your profiles with correct running and signed-in state.
- Creating a profile, signing in to it, launching it and deleting it all work.
- A profile launched from a desktop shortcut opens a **visible** Claude window that has
  its own taskbar button and badged icon from the first frame.
- Editing a profile's colour or badge changes its taskbar icon within a few seconds.
- Signing out of a profile and back in lands in that profile's window, and
  `auth-router.log` says which rule decided it.
- `-Revert` leaves `-Status` reporting Claude's own `claude://` handler and no
  `ClaudeProfileSwitcher` folder, with profiles and logins intact.

The visible-window check matters more than it looks. See the notes below.

## Traps worth knowing about

All of these have already caused bugs in this repo, so they are worth reading before you
change anything.

**PowerShell variable names are case insensitive, and parameters live in script scope.**
A script scope variable that shares a name with a parameter will silently reassign that
parameter and fail its type constraint. `$list` clobbering `[switch]$List` broke startup
once, `$script:Install` clobbering `[switch]$Install` broke it again, and a hashtable
named `$B` was silently replaced by a loop variable named `$b` in the rewrite. Keep
internal state named clearly away from anything in the param block, and never rely on
case to tell two variables apart.

**Event handlers cannot assign to outer variables.** A script block wired to a WinForms
event can read variables from the enclosing function but an assignment inside it creates a
local copy. Share state through a hashtable or object and mutate that instead.

**Show state is inherited through STARTUPINFO.** If a process is started hidden, the first
window a WinForms app shows will also be hidden, and any child process it launches
inherits the same show state unless told otherwise. Claude is launched with an explicit
`-WindowStyle Normal` for this reason. The switcher itself is launched through
`conhost.exe --headless`, which gives it no console at all and so nothing to flash.

**The Windows 11 taskbar reads a window's icon once per identity.** For a window with an
explicit AppUserModelID, the taskbar takes its button icon from the identity's
`RelaunchIconResource`, on first sight, and ignores `WM_SETICON` entirely (that only
changes the window frame and hover thumbnail). Changing the icon means changing the
identity. Do not try to refresh it any other way; several ways were tried.

**`Get-AppxPackage` and WMI are slow.** The Store lookup can take ten seconds and every
WMI process query costs half a second or more. The install is resolved once and
remembered, and process command lines are read directly. Do not reintroduce either on a
path that runs at every launch or on the refresh timer.

**Claude Code's CLI is also `claude.exe`.** Match processes by executable path, never by
name alone, or the switcher will report a terminal session as a running profile.

**`Add-Type` compiles on every run** and costs several seconds. The C# helper is compiled
once to a DLL named by a hash of its source and loaded from bytes so the file is never
locked and `-Revert` can delete it. Change the source and a new DLL is built automatically.

## Style

Match what is already there. Comments explain why something is done, not what the line
does. If a piece of code exists to work around a Windows quirk, say so, because the next
person will otherwise remove it.

## Reporting bugs

Open an issue with your Windows version, whether your Claude desktop is the Store build or
an installer build, the output of `.\ClaudeSwitcher.ps1 -Status`, and the contents of
`%LOCALAPPDATA%\ClaudeProfileSwitcher\switcher-error.log` and `auth-router.log` if there
is anything in them. Remember to replace your username first.
