# Security Policy

## Scope

This tool is a launcher. It creates directories under `%LOCALAPPDATA%\ClaudeProfiles`,
starts the Claude desktop app with a `--user-data-dir` argument, and creates shortcuts.
It does not modify the Claude application, handle credentials, or make network requests
of its own.

If you turn on sign-in routing, the switcher also becomes the handler for `claude://` links,
which means it receives text from your browser. Each link is checked before use: only
`claude://` followed by characters a URL may contain, at most 2048 of them, is passed on to
Claude, so quotes, spaces and control characters cannot add arguments to Claude's command
line. The handler refuses to run when anything other than the link is passed to it, and it
never writes a link to its log, because a sign-in link carries a one-time code. Reports
about this part are especially welcome.

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
