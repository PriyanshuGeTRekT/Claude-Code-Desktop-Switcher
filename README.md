<div align="center">

# Claude Profile Switcher

**Run several Claude desktop accounts on one Windows PC, side by side, without ever signing out.**

[![Stars](https://img.shields.io/github/stars/PriyanshuGeTRekT/Claude-Code-Desktop-Switcher?style=flat-square&color=cb7b5d)](https://github.com/PriyanshuGeTRekT/Claude-Code-Desktop-Switcher/stargazers)
[![Downloads](https://img.shields.io/github/downloads/PriyanshuGeTRekT/Claude-Code-Desktop-Switcher/total?style=flat-square&color=cb7b5d)](https://github.com/PriyanshuGeTRekT/Claude-Code-Desktop-Switcher/releases)
[![Views](https://visitor-badge.laobi.icu/badge?page_id=PriyanshuGeTRekT.Claude-Code-Desktop-Switcher&left_text=views)](https://github.com/PriyanshuGeTRekT/Claude-Code-Desktop-Switcher)
[![Lint](https://img.shields.io/github/actions/workflow/status/PriyanshuGeTRekT/Claude-Code-Desktop-Switcher/lint.yml?branch=main&style=flat-square&label=lint)](https://github.com/PriyanshuGeTRekT/Claude-Code-Desktop-Switcher/actions/workflows/lint.yml)
[![License](https://img.shields.io/github/license/PriyanshuGeTRekT/Claude-Code-Desktop-Switcher?style=flat-square)](LICENSE)
<br>
![Windows 10 | 11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?style=flat-square&logo=windows)
![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE?style=flat-square&logo=powershell&logoColor=white)
![No dependencies](https://img.shields.io/badge/dependencies-none-2e7d4a?style=flat-square)

<img src="docs/images/switcher.png" alt="The Claude Profile Switcher window listing four accounts" width="720">

</div>

## Highlights

|  |  |
| --- | --- |
| **Add an account in one click** | **Add account** opens a fresh Claude window at the sign-in screen. Sign in and you're done. |
| **Concurrent accounts** | Every account runs in its own window. Open as many as you like at the same time. |
| **One click to switch** | Launch a profile, or bring it to the front if it is already open. Also from the tray. |
| **Move Claude Code chats** | Copy chats from one account to another and carry on where you left off. |
| **Sign-ins land in the right account** | Optional: a browser sign-in comes back to the account that asked for it, not to your original one. |
| **Icons you can tell apart** | Each profile gets a coloured badge for its desktop and Start menu shortcuts. |
| **Nothing to install** | One PowerShell script. No patching, no proxy, no credential juggling. |
| **Your original stays put** | The account you already have is never touched and keeps auto update and `claude://` links. |

## Quick start

**One line**, from the latest release:

```powershell
irm https://github.com/PriyanshuGeTRekT/Claude-Code-Desktop-Switcher/releases/latest/download/ClaudeSwitcher.ps1 -OutFile "$env:TEMP\ClaudeSwitcher.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\ClaudeSwitcher.ps1" -Install
```

**Or from a clone:**

```powershell
git clone https://github.com/PriyanshuGeTRekT/Claude-Code-Desktop-Switcher.git
powershell -ExecutionPolicy Bypass -File .\Claude-Code-Desktop-Switcher\ClaudeSwitcher.ps1 -Install
```

`-Install` copies the switcher to `%LOCALAPPDATA%\ClaudeProfiles\.switcher`, adds
**Claude Profile Switcher** to the desktop and Start menu, adds **Claude - Add account** to the
Start menu, and opens the switcher. The downloaded copy is no longer needed afterwards, so
moving or deleting it breaks nothing.

> [!TIP]
> Downloaded a ZIP instead? Run `Get-ChildItem -Recurse | Unblock-File` in the folder first.

## Using it

<img src="docs/images/first-run.png" alt="The switcher on first run, with only the original account and a prompt to click Add account" width="600">

1. Click **Add account**. A new Claude window opens at the sign-in screen.
2. Sign in with your other account. That's it: both accounts stay signed in from now on.
3. Optionally press <kbd>F2</kbd> to rename it from `Account 2` to something like `Work`.

You can also add an account without opening the switcher: search Start for
**Claude - Add account**, pick **Add account** from the tray icon, or run
`.\ClaudeSwitcher.ps1 -AddAccount`.

| Action | Button | Keyboard |
| --- | --- | --- |
| Open a profile, or switch to it if it is open | **Launch** / **Switch to**, or double-click | <kbd>Enter</kbd> |
| Add an account, opens straight to sign-in | **Add account** | <kbd>Ctrl</kbd>+<kbd>N</kbd> |
| Rename (only the label, sign-in is unaffected) | **Rename** | <kbd>F2</kbd> |
| Desktop and Start menu shortcuts | **Add shortcuts** | |
| Copy Claude Code chats to another account | **Transfer chats** | |
| Delete a profile and its shortcuts | **Delete** | <kbd>Del</kbd> |
| Open the profile folder | right-click, **Open folder** | |

Right-click any profile for the same actions.

### Tray

Closing the window keeps the switcher in the notification area. Right-click the tray icon to
jump to any account (open ones are ticked), add an account, or turn on **Start with Windows**. Untick
**Keep running in the tray** in the window if you would rather it quit on close.

### Signing in from the browser

Signing in to Claude in the browser finishes with a `claude://` link, and Windows sends every
one of those to your original account. The first time you add an account, the switcher offers
to handle those links instead and pass each sign-in to the account that asked for it. You can
turn this on or off later from the tray icon (**Send sign-ins to the right account**), or with
`-RouteSignIns` and `-Revert`.

A sign-in goes to the first of these that applies: the account you launched while it was
signed out, the only open account that is signed out, the open account whose window you used
last, and otherwise `Default`. Every other `claude://` link still opens in `Default`.

> [!NOTE]
> On the Store build, Windows keeps sending `claude://` links to Claude until you choose
> otherwise, and only you can make that choice. Turning this on opens Settings at the right
> page: set **CLAUDE** to **Claude Profile Router**. `-Status` shows whether that step is
> still to do.

### Shortcuts

<img src="docs/images/icons.png" alt="Shortcut icons: plain Claude for Default, then coloured W, P and C badges" width="600">

**Add shortcuts** puts a `Claude - <name>` shortcut on the desktop and in the Start menu, so
you can search for an account or pin it and skip the switcher entirely. Each profile keeps its
colour, and clicking a shortcut for an account that is already open simply brings it forward.

### Moving Claude Code chats between accounts

<img src="docs/images/transfer.png" alt="The transfer dialog with three chats ticked" width="600">

Select a profile, click **Transfer chats**, tick the chats and pick where they go. The chat
stays in the original account as well. Both copies continue the same history, so finish in
one account before picking it up in the other.

> [!NOTE]
> The target account needs to have opened the Code tab once, so it has somewhere to put
> the chats. If it is running, quit and reopen it to see them. This feature is new; please
> [open an issue](https://github.com/PriyanshuGeTRekT/Claude-Code-Desktop-Switcher/issues)
> if a transferred chat does not show up or resume.

## Command line

| Command | Does |
| --- | --- |
| `.\ClaudeSwitcher.ps1` | Open the window |
| `.\ClaudeSwitcher.ps1 -AddAccount` | Add an account and open Claude at its sign-in screen |
| `.\ClaudeSwitcher.ps1 -Launch Work` | Open a profile, or bring it forward if it is open |
| `.\ClaudeSwitcher.ps1 -List` | Print profiles and which are running |
| `.\ClaudeSwitcher.ps1 -Shortcut Work` | Desktop and Start menu shortcuts for one profile |
| `.\ClaudeSwitcher.ps1 -Shortcut Work -To <dir>` | A shortcut in a folder of your choice |
| `.\ClaudeSwitcher.ps1 -Tray` | Start in the tray without the window |
| `.\ClaudeSwitcher.ps1 -Install` | Install (or refresh an install and its shortcuts), then open the switcher |
| `.\ClaudeSwitcher.ps1 -ClaudePath <exe>` | Point at `Claude.exe` if detection fails (remembered) |
| `.\ClaudeSwitcher.ps1 -RouteSignIns` | Send browser sign-ins to the account that asked for them |
| `.\ClaudeSwitcher.ps1 -Status` | Show whether sign-in routing is working, and which open accounts are signed in |
| `.\ClaudeSwitcher.ps1 -Revert` | Turn sign-in routing off and put the original `claude://` handler back |

`-Launch` and `-Shortcut` accept either a profile's name or its folder name.

## How it works

The Claude desktop app is built on Electron, and Electron honours `--user-data-dir`. A
profile is nothing more than a directory with its own cookie jar, Local Storage and
`config.json`, so each one is a fully independent login. Electron's single instance lock is
per directory too, which is why instances pointed at different directories run side by side
instead of focusing each other.

```mermaid
flowchart LR
    S["Switcher<br/>window, tray, shortcuts"]
    S -->|shell:AppsFolder| D["Claude<br/>Default"]
    S -->|--user-data-dir| W["Claude<br/>Work"]
    S -->|--user-data-dir| P["Claude<br/>Personal"]
    D --- DD[("Claude's own data<br/>never touched")]
    W --- WD[("ClaudeProfiles\Work")]
    P --- PD[("ClaudeProfiles\Personal")]
```

Claude ships in two shapes on Windows, and the switcher detects whichever you have:

| Build | Executable | Default profile data |
| --- | --- | --- |
| Store / MSIX | inside the package's `WindowsApps` folder | `%LOCALAPPDATA%\Packages\Claude_<id>\LocalCache\Roaming\Claude` |
| Installer | for example `%LOCALAPPDATA%\AnthropicClaude` | `%APPDATA%\Claude` |

<details>
<summary><b>Details that matter</b></summary>

- **`Default` is never touched.** On the Store build it is started through the shell app model
  rather than by running the `.exe`, so it keeps full package identity: `claude://` links, the
  native messaging host and auto update behave exactly as before. Profiles this tool creates
  live in `%LOCALAPPDATA%\ClaudeProfiles`, nowhere near Claude's own data.
- **Sign-in routing is off until you turn it on.** It then writes the `claude://` handler under
  `HKCU\Software\Classes\claude`, a `ClaudeProfileRouter.claude` entry beside it, and an entry
  under `HKCU\Software\ClaudeProfileSwitcher` and `HKCU\Software\RegisteredApplications` so
  that Settings can offer it as an app for `claude://` links. Claude's own handler is saved to
  `.switcher\claude-handler-backup.json` first and put back by `-Revert`. Claude rewrites its
  handler every time it starts, so the switcher takes it back whenever it notices.
- **The router never logs a link**, because a sign-in link carries a one-time code. It
  refuses any link that is not `claude://` followed by ordinary URL characters, and decides
  whether an account is signed in from the presence and length of keys in its `config.json`,
  never from the token itself. `.switcher\sign-in-router.log` records where each sign-in went.
- **Install paths contain the version number**, so they change with every update. Shortcuts
  resolve the executable when clicked and carry their own icon files, so they keep working
  and keep their icons after Claude updates itself.
- **Running detection** only counts the desktop app's own process. The Claude Code CLI is also
  called `claude.exe` and the desktop app starts one per Code session; those are ignored.
- **Renaming** changes a label only. The folder name is a profile's permanent id, because
  Electron stores absolute paths inside its data.
- **Chat transfer** copies the small per-chat file the desktop app keeps under
  `claude-code-sessions\<account>\<organisation>` into the other profile, re-pointed at that
  profile's account. The transcript itself is kept by Claude Code outside the profile.

</details>

## What has been verified

Tested on Windows 11 against the **Store (MSIX) build**, Claude `2.16120.0.0`: `-Install`
and its shortcuts, **Add account** opening a real Claude window at the sign-in screen,
switching to (and restoring) an open account, running detection alongside Claude Code
sessions, shortcut icons, every tray menu item, and <kbd>Ctrl</kbd>+<kbd>N</kbd>. Rename,
delete, single instance behaviour and chat transfer (on sample data) were exercised end to
end against a stand-in `Claude.exe`.

**Not yet verified:** the **installer build** (no such install was available), **chat
transfer between two real signed-in accounts**, and **sign-in routing** in its current form.
If you can try any of these, `-List` is a harmless way to check detection, and there is an
[issue template](.github/ISSUE_TEMPLATE/installer_build_report.yml) for reporting back. That
is the most useful contribution anyone can make right now.

## Troubleshooting

<details>
<summary><b>"Could not find the Claude desktop app"</b></summary>

Pass `-ClaudePath` once, pointing at your `Claude.exe`. The choice is saved.
</details>

<details>
<summary><b>The script will not run</b></summary>

Use `-ExecutionPolicy Bypass` as shown above, and `Unblock-File` if you downloaded a ZIP. The
generated shortcuts already handle this.
</details>

<details>
<summary><b>A shortcut does nothing</b></summary>

Anything fatal is shown in a message box and written to
`%LOCALAPPDATA%\ClaudeProfiles\switcher-error.log`. If you deleted or renamed a profile
outside the switcher, its old shortcut will report that the profile no longer exists.
</details>

<details>
<summary><b>Known limitations</b></summary>

- Every instance shares Claude's taskbar identity, so open accounts group under one taskbar
  button with the same icon. Hover to see each window.
- A pinned profile shortcut shows up as a separate taskbar button from the window it opens.
- `claude://` links open in the `Default` account, except sign-ins once
  [sign-in routing](#signing-in-from-the-browser) is on.
- Each running account is a full copy of the app, so budget roughly one Claude's worth of
  memory per account. A profile grows to a few hundred MB, mostly caches.
- This is about the desktop app only. The `claude` CLI uses its own `CLAUDE_CONFIG_DIR`
  environment variable for the same purpose.
</details>

## Star history

<a href="https://star-history.com/#PriyanshuGeTRekT/Claude-Code-Desktop-Switcher&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=priyanshugetrekt/claude-code-desktop-switcher&type=Date&theme=dark">
    <img alt="Star history chart" src="https://api.star-history.com/svg?repos=priyanshugetrekt/claude-code-desktop-switcher&type=Date" width="600">
  </picture>
</a>

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, what to
test before opening a PR, and the Windows specific traps that have already caused bugs here.
Please also read the [Code of Conduct](CODE_OF_CONDUCT.md).

## Disclaimer

Unofficial, and not affiliated with, endorsed by, or supported by Anthropic. It uses only
documented Electron command line switches and does not modify the Claude application. Using
multiple accounts is subject to Anthropic's terms of service.

## License

MIT, see [LICENSE](LICENSE).
