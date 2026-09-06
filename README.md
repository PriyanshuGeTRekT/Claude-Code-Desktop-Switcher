# Claude Profile Switcher

Run two or more Claude desktop accounts on the same Windows machine **at the same time**,
without ever signing out of the one you already have. Each account gets its own window,
its own taskbar button and its own badged icon, and signing in lands in the right window.

No patching, no proxying, no credential juggling. The Claude desktop app is an Electron
app, so it honours `--user-data-dir`. This is a small launcher built around that.

```
+- Claude accounts ---------------------------------------------------------+
|  (D) Default               Running  |  Signed in       your original      |
|  (W) Work                  Running  |  Signed in                          |
|  (P) Personal              Not running  |  Signed out                     |
|                                                                           |
|  [Open] [New profile] [Edit] [Shortcut] [Folder] [Refresh icons] [Delete] |
+---------------------------------------------------------------------------+
```

## Why

Claude desktop signs in one account at a time. The usual workaround is signing out and
back in, which is slow and loses your place. A profile directory is all that actually
distinguishes one logged in account from another, so pointing separate instances at
separate directories gets you genuinely concurrent sessions.

Two things Claude does not do on its own make that awkward, and this tool handles both:

- **Every window looks the same.** All instances share one taskbar button and one icon.
  The switcher gives each profile its own colour-badged icon and its own button, the way
  browsers do for profiles.
- **Sign-in goes to the wrong window.** Claude signs in through your browser, and Windows
  hands the result back to whichever instance registered the `claude://` link, which is
  always your original one. The switcher forwards it to the profile that is signed out.

## Requirements

- Windows 10 (1809 or later) or Windows 11
- Windows PowerShell 5.1, which ships with Windows, so there is nothing to install
- The Claude desktop app

## Install

```powershell
git clone https://github.com/PriyanshuGeTRekT/Claude-Code-Desktop-Switcher.git
cd Claude-Code-Desktop-Switcher
powershell -ExecutionPolicy Bypass -File .\ClaudeSwitcher.ps1 -Install
```

That puts a **Claude Profile Switcher** shortcut on your desktop and in the Start menu.
You can also just double click `Claude Profile Switcher.cmd`. Neither shows a console.

If you downloaded a ZIP instead of cloning, Windows marks the files as untrusted. Unblock
them first:

```powershell
Get-ChildItem -Recurse | Unblock-File
```

## Use

1. **New profile**, then name it, for example `Work`. It opens straight away.
2. Sign in with your other account. The sign-in lands in that window.

Both accounts now stay signed in indefinitely. Everything else is optional:

- **Edit** changes a profile's display name, colour and badge letter. The taskbar icon,
  window and shortcuts follow. `Default` can be renamed too, and there is an option to
  badge its taskbar icon as well (off by default, see below).
- **Shortcut** puts a profile on the desktop with its badged icon. Pin that to the
  taskbar and it shares a button with the running window.
- **Refresh icons** redraws every icon, for example after a Claude update changes the
  base artwork.
- **Tools > Revert all changes** undoes everything this tool sets up. See below.

## Command line

```powershell
.\ClaudeSwitcher.ps1                  # open the window
.\ClaudeSwitcher.ps1 -Launch Work     # launch a profile directly (this is what shortcuts do)
.\ClaudeSwitcher.ps1 -List            # print profiles, running state and sign-in state
.\ClaudeSwitcher.ps1 -Status          # everything -List shows plus install and handler state
.\ClaudeSwitcher.ps1 -Shortcut Work   # desktop shortcut for one profile
.\ClaudeSwitcher.ps1 -Install         # create the switcher's own shortcuts
.\ClaudeSwitcher.ps1 -Icons           # regenerate icon files
.\ClaudeSwitcher.ps1 -Revert          # undo everything this tool changed
.\ClaudeSwitcher.ps1 -ClaudePath "C:\path\to\Claude.exe"   # if auto detection fails
```

Re-run `-Install` if you move the folder, since shortcuts point at the script by path.

## How it works

A profile is just a directory. It holds its own cookie jar, `Local Storage` and
`config.json`, so each one is a fully independent login. Electron's single instance lock
is per user-data-dir, which is why instances pointed at different directories run
concurrently instead of focusing each other's window.

Claude ships in two shapes on Windows, and they store data in different places:

| Build | Executable | Profile data |
| --- | --- | --- |
| Store / MSIX | inside the package's `WindowsApps` folder | `%LOCALAPPDATA%\Packages\Claude_<id>\LocalCache\Roaming\Claude` |
| Installer | for example `%LOCALAPPDATA%\AnthropicClaude` | `%APPDATA%\Claude` |

The tool resolves whichever you have and remembers the answer, because the Store lookup
alone can take ten seconds. It re-resolves only if the remembered executable disappears.

**Taskbar identity.** Windows groups taskbar buttons by an identifier called the
AppUserModelID. Every Claude window normally carries the same one. Each extra profile's
window is given its own, together with an icon file, so it gets its own button. Windows
reads that icon once per identity and never again, so when you change a profile's colour
or badge the identity changes with it; that is how the taskbar picks up the new look.
The switcher applies this in the fraction of a second between Claude creating its window
and showing it, so the button is right from the start.

**Sign-in routing.** Windows keeps one handler per user for `claude://` links, and Claude
re-registers itself as that handler every time it starts. The switcher takes the slot
whenever it launches a profile, and `ClaudeAuthRouter.ps1` forwards each login callback
to, in order: a profile explicitly expecting a login, otherwise the one running profile
that is signed out, otherwise the profile whose window you most recently used, otherwise
`Default`. Only `claude://login/...` links are routed; anything else behaves as before.
Sign-in state is read from each profile's `config.json` by key presence and value length
only; no token is ever read.

**`Default` is left alone.** Your existing account keeps its directory, its own taskbar
identity and, on the Store build, full package identity. The only thing that changes is
the `claude://` handler, and only while an extra profile might need it. Profiles this
tool creates live in `%LOCALAPPDATA%\ClaudeProfiles`, nowhere near Claude's own data.

**Install paths contain the version number**, so they change on every update. The
executable is resolved at click time rather than baked into shortcuts, which keeps
shortcuts working after Claude updates itself.

## Files

| Where | What |
| --- | --- |
| `%LOCALAPPDATA%\ClaudeProfiles\<Name>\` | a profile's data. Claude's, never modified by this tool |
| `%LOCALAPPDATA%\ClaudeProfiles\settings.json` | this tool's settings: remembered install, display names, colours, badges |
| `%LOCALAPPDATA%\ClaudeProfileSwitcher\` | generated files: icons, logs, the compiled helper, a backup of the original `claude://` handler. Disposable |
| `HKCU\Software\Classes\claude\shell\open\command` | the one registry value this tool changes, backed up before the first change |

## Revert

`-Revert`, or **Tools > Revert all changes**, puts the original `claude://` handler back,
resets any shortcuts this tool made to a plain Claude icon, removes display names,
colours and badges, restores `Default`'s taskbar identity if it was badged, and deletes
the `ClaudeProfileSwitcher` folder. Profile directories and logins are not touched.

Windows that already carry a profile identity/icon keep it until Claude is restarted; that is
a Windows limitation.

## Limitations

- **Changing a profile's colour or badge changes its taskbar identity.** A pinned copy of
  its shortcut stops matching until you unpin it and pin the refreshed shortcut. Desktop
  and Start menu shortcuts are updated automatically; pinned items cannot be.
- **Badging `Default`** (an option in its Edit dialog) has the same effect on a pinned
  Claude icon, which is why it is off by default.
- **Sign-in routing is a strong heuristic, not a guarantee.** It is exact whenever one
  profile is signed out, which is the normal case. If two profiles are signed out at the
  same moment it picks the window you were using.
- The `claude://` handler is taken back a few seconds after each profile launch, because
  Claude re-registers it on start. Launch profiles through the switcher or its shortcuts,
  not by running `Claude.exe --user-data-dir` yourself, or the handler will be Claude's.

## What has been verified

Tested end to end on Windows 11 (build 26200) against the **installer build**, Claude
`1.46388.4`: concurrent instances, independent logins, sign-in routing into a signed-out
profile, per-profile taskbar buttons and icons appearing before the window is shown,
pinning, editing colour and badge with the taskbar following, `Default` badging on and
off, and a full `-Revert`.

The **Store (MSIX) build** was the original development target and its detection and
launch code is unchanged, but it has not been re-tested since the taskbar and sign-in
features were added. Reports either way are welcome; there is an
[issue template](.github/ISSUE_TEMPLATE/installer_build_report.yml) for them.

## Troubleshooting

`.\ClaudeSwitcher.ps1 -Status` prints the state of everything in one screen. Errors from
the window go to `%LOCALAPPDATA%\ClaudeProfileSwitcher\switcher-error.log`; sign-in
routing decisions go to `auth-router.log` next to it.

**"Could not find the Claude desktop app"**. Pass `-ClaudePath` once, pointing at your
`Claude.exe`. The choice is saved.

**Sign-in went to the wrong window**. Check `auth-router.log` for which rule fired. If
the handler was Claude's at the time (`-Status` says so), the profile was launched
outside the switcher; open it from the switcher or its shortcut instead.

**Script will not run**. Use `-ExecutionPolicy Bypass` as shown above, and `Unblock-File`
if you downloaded a ZIP. The generated shortcuts already handle this.

## Notes

- Deleting a profile removes its directory, which signs that account out on this machine.
  `Default` is protected.
- A profile grows to a few hundred MB, mostly caches.
- Each running instance is a full app, so budget roughly one Claude's worth of memory per
  account.
- This is only about the desktop app. The `claude` CLI is separate and uses its own
  `CLAUDE_CONFIG_DIR` environment variable for the same purpose. Its executable is also
  called `claude.exe`, which is why the switcher matches processes by path, not by name.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup,
what to test before opening a PR, and the Windows specific traps that have already caused
bugs here. Please also read the [Code of Conduct](CODE_OF_CONDUCT.md).

## Disclaimer

Unofficial, and not affiliated with, endorsed by, or supported by Anthropic. It uses only
documented Electron command line switches and documented Windows shell APIs, and does not
modify the Claude application. Using multiple accounts is subject to Anthropic's terms of
service.

## License

MIT, see [LICENSE](LICENSE).
