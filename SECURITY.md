# Security Policy

## Scope

This tool is a launcher. It creates directories under `%LOCALAPPDATA%\ClaudeProfiles`,
starts the Claude desktop app with a `--user-data-dir` argument, and creates shortcuts.
It does not modify the Claude application, handle credentials, or make network requests
of its own.

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
