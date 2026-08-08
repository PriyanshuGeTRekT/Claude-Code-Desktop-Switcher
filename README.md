# Claude Profile Switcher

Run two or more Claude desktop accounts on the same Windows machine **at the same time**,
without ever signing out of the one you already have.

No patching, no proxying, no credential juggling. The Claude desktop app is an Electron
app, so it honours `--user-data-dir`. This is a small launcher built around that.

```
┌─ Claude accounts ─────────────────────────────────┐
│  Profile     Status                  Last used    │
│  Default     Running · pid 10760     today 14:02  │  <- your original account
│  Work        Not running             yesterday    │
│  Personal    Running · pid 23180     today 13:41  │
│                                                   │
│  [ Launch ] [ New profile ] [ Add to desktop ]    │
└───────────────────────────────────────────────────┘
```

## Why

Claude desktop signs in one account at a time. The usual workaround is signing out and
back in, which is slow and loses your place. A profile directory is all that actually
distinguishes one logged in account from another, so pointing separate instances at
separate directories gets you genuinely concurrent sessions.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1, which ships with Windows, so there is nothing to install
- The Claude desktop app

## Install

```powershell
git clone https://github.com/PriyanshuGeTRekT/Claude-Code-Desktop-Switcher.git
cd Claude-Code-Desktop-Switcher
powershell -ExecutionPolicy Bypass -File .\ClaudeSwitcher.ps1 -Install
```

That puts a **Claude Profile Switcher** shortcut on your desktop and in the Start menu.
You can also just double click `Claude Profile Switcher.cmd`.

If you downloaded a ZIP instead of cloning, Windows marks the files as untrusted. Unblock
them first:

```powershell
Get-ChildItem -Recurse | Unblock-File
```

## Use

1. **New profile**, then name it, for example `Work`.
2. Select it and click **Launch**. A second Claude window opens at the sign in screen.
3. Sign in with your other account.

Both accounts now stay signed in indefinitely. **Add to desktop** gives a profile its own
icon so you can skip the switcher entirely and go straight to the account you want. Those
shortcuts pin to the taskbar and Start menu like anything else.

## Command line

```powershell
.\ClaudeSwitcher.ps1                  # open the window
.\ClaudeSwitcher.ps1 -Launch Work     # launch a profile directly
.\ClaudeSwitcher.ps1 -List            # print profiles and what is running
.\ClaudeSwitcher.ps1 -Shortcut Work   # desktop shortcut for one profile
.\ClaudeSwitcher.ps1 -Install         # create the switcher's own shortcuts
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

The script resolves whichever you have. It checks the Store package first, then registry
uninstall entries, then the usual install directories, with `-ClaudePath` as a manual
override that gets remembered.

Two details that matter:

- **`Default` is never touched.** Your existing account keeps using its original
  directory. On the Store build it is launched through the shell app model rather than by
  running the `.exe` directly, so it keeps full package identity. `claude://` links, the
  native messaging host and auto update all behave exactly as before. Profiles this tool
  creates live in `%LOCALAPPDATA%\ClaudeProfiles`, nowhere near Claude's own data.
- **Install paths contain the version number**, so they change on every update. The
  executable is resolved at click time rather than baked into shortcuts, which keeps
  shortcuts working after Claude updates itself.

## What has been verified

Tested end to end on Windows 11 against the **Store (MSIX) build**, Claude `1.26832.0.0`.
That covers concurrent instances, independent cookie jars, profile creation and deletion,
shortcut generation, and launching from a shortcut.

The **installer build** detection path is implemented but has not been tested, because
there was no such install available to try it against. If you have one, `-List` is a
harmless way to check detection, and there is an
[issue template](.github/ISSUE_TEMPLATE/installer_build_report.yml) for reporting what
happened. That is the most useful contribution anyone can make right now.

## Troubleshooting

Anything fatal is written to `%LOCALAPPDATA%\ClaudeProfiles\switcher-error.log`, because a
shortcut launched script has no console to print to.

**"Could not find the Claude desktop app"**. Pass `-ClaudePath` once, pointing at your
`Claude.exe`. The choice is saved.

**Script will not run**. Use `-ExecutionPolicy Bypass` as shown above, and `Unblock-File`
if you downloaded a ZIP. The generated shortcuts already handle this.

## Notes

- Deleting a profile removes its directory, which signs that account out on this machine.
  `Default` is protected.
- A profile grows to a few hundred MB, mostly caches.
- Each running instance is a full app, so budget roughly one Claude's worth of memory per
  account.
- This is only about the desktop app. The `claude` CLI is separate and uses its own
  `CLAUDE_CONFIG_DIR` environment variable for the same purpose.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup,
what to test before opening a PR, and two Windows specific traps that have already caused
bugs here. Please also read the [Code of Conduct](CODE_OF_CONDUCT.md).

## Disclaimer

Unofficial, and not affiliated with, endorsed by, or supported by Anthropic. It uses only
documented Electron command line switches and does not modify the Claude application.
Using multiple accounts is subject to Anthropic's terms of service.

## License

MIT, see [LICENSE](LICENSE).
