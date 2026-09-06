# Security Policy

## Scope

This tool is a launcher. It creates directories under `%LOCALAPPDATA%\ClaudeProfiles`,
starts the Claude desktop app with a `--user-data-dir` argument, creates shortcuts, and
sets taskbar identity properties on Claude's windows. It does not modify the Claude
application, handle credentials, or make network requests of its own.

Beyond that, it does three things worth knowing about:

- **It replaces the `claude://` link handler** for the current user
  (`HKCU\Software\Classes\claude\shell\open\command`) with `ClaudeAuthRouter.ps1`, so
  that browser sign-ins can be forwarded to the right profile. The router receives the
  sign-in callback URL, which contains a one-time authorization code, and passes it
  unchanged to `Claude.exe`. It does not log or store the URL. The original handler value
  is backed up before the first change and restored by `-Revert`.
- **It reads two keys from each profile's `config.json`** to tell signed in from signed
  out: whether `windowSizeWasSignedIn` is true, and the *length* of `oauth:tokenCacheV2`.
  The token value itself is never read, logged or transmitted.
- **It compiles a small C# helper** (Win32 and COM interop for windows, the taskbar and
  shortcuts) to `%LOCALAPPDATA%\ClaudeProfileSwitcher\native-<hash>.dll` on first run.
  The source is in `ClaudeProfileLib.ps1`; the hash in the file name is of that source.

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
