# Security Policy

## Scope

This tool is a launcher. It creates a folder per account (under `%LOCALAPPDATA%` on Windows,
`~/Library/Application Support/ClaudeProfiles` on macOS, `~/.config/ClaudeProfiles` on
Linux), starts the Claude desktop app with a `--user-data-dir` argument, and creates
shortcuts or launchers. It does not modify the Claude application or handle credentials.

Its only network requests are for its own updates, to this repository's GitHub releases:
once a day the window fetches the latest release's `SHA256SUMS.txt` (about 300 bytes),
and the script itself only when that checksum differs from the installed copy. A
downloaded script is installed only when it matches the published checksum, parses, and
is newer than the installed one, and only after you say yes. Nothing about you or your
accounts is sent. `"UpdateCheck": false` in `settings.json` stops the daily look
entirely; `-Update` and the tray's **Check for updates** are the only other times it
goes online.

If you turn on sign-in routing, the switcher also becomes the handler for `claude://` links,
which means it receives text from your browser. Each link is checked before use: only
`claude://` followed by characters a URL may contain, at most 2048 of them, is passed on to
Claude, so quotes, spaces and control characters cannot add arguments to Claude's command
line. The handler refuses to run when anything other than the link is passed to it, and it
never writes a link to its log, because a sign-in link carries a one-time code. Reports
about this part are especially welcome.

If you mark an account as kept running, the switcher creates one per-user scheduled task
(`Claude Profile Switcher watchdog`, no admin rights) that runs the script with `-Watch`
every two minutes and at logon. It reads each kept account's own `logs\main.log` to tell a
forced close from a quit, and starts Claude; nothing else. `-RemoveWatchdog` deletes it.

`-Uninstall` (or the tray's **Uninstall...**) removes all of that: shortcuts, the task, the
`claude://` handler and the installed copy. Accounts and settings stay unless you add
`-RemoveProfiles`.

### macOS and Linux

The same rules apply. Updates: once a day (unless `"UpdateCheck": false`) one HEAD request to
this repository's latest release, to read its version; a newer release is downloaded and
installed only when it matches the release's `SHA256SUMS.txt`. On macOS the new app must also
pass `codesign --verify --deep --strict` and carry the switcher's bundle id.

Sign-in routing validates links in the same way and never logs them. On macOS it registers the
app as the `claude://` handler with Launch Services and sends the link to one Claude process as
a GetURL Apple Event, which macOS lets you allow or refuse once. On Linux it writes one line to
your `~/.config/mimeapps.list` and a hidden `claude-profile-router.desktop`, and remembers the
previous handler so `--revert` restores it.

Keep running on macOS installs a per-user launch agent
(`io.github.priyanshugetrekt.claude-profile-switcher.watchdog`) that runs the app with
`--watch` every two minutes; Open at Login installs a second one. The Linux app menu launchers
are `.desktop` files and SVG icons under `~/.local/share`. `--uninstall` removes all of these.

Profile directories contain live login sessions for whichever account signed in there.
Treat them like any other browser profile. Anyone with read access to your user account
can use them, and deleting a profile directory signs that account out on that machine.

## Reporting a vulnerability

Please report suspected vulnerabilities privately using GitHub's
[private vulnerability reporting](https://docs.github.com/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability)
on this repository, rather than opening a public issue.

Include what you found, how to reproduce it, and what an attacker could achieve. You can
expect an initial response within a couple of weeks. This is a hobby project maintained in
spare time, so please be patient.

## Out of scope

Issues in the Claude desktop app itself belong to Anthropic, not here. Report those
through their channels.
