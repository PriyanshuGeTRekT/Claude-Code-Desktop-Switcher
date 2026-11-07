#!/bin/bash
# End-to-end tests for the macOS switcher, against a stand-in Claude.app that records how
# it was started. Never touches a real Claude or real accounts: everything lives under a
# temporary folder whose path has a space in it, like Application Support.
# Usage: macos/tests/run-tests.sh path/to/ClaudeSwitcher [screenshot-folder]
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bin="$1"
shots="${2:-}"
root="$(mktemp -d)/switcher test"
export CLAUDE_SWITCHER_SUPPORT_DIR="$root/Application Support"
export CLAUDE_SWITCHER_APP="$root/Fake Apps/Claude.app"
# Launch agents go here, under labels ending in .test, never into ~/Library/LaunchAgents.
export CLAUDE_SWITCHER_LAUNCHAGENTS_DIR="$root/LaunchAgents"
P="$CLAUDE_SWITCHER_SUPPORT_DIR/ClaudeProfiles"
agent="io.github.priyanshugetrekt.claude-profile-switcher.test"
# Edits settings.json: python3 is on every GitHub macOS runner.
setting() { python3 - "$P/settings.json" "$@" <<'PY'
import json, sys, os
path, key, id_, value = sys.argv[1:5]
d = json.load(open(path)) if os.path.exists(path) else {}
d.setdefault(key, {})[id_] = json.loads(value)
json.dump(d, open(path, "w"))
PY
}
log=/tmp/fake-claude.log
fails=0
pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi }
sw() { "$bin" "$@" 2>&1; }
# Matched without the temp folder prefix: ps shows /var as /private/var.
open_count() { pgrep -f "Fake Apps/Claude.app/Contents/MacOS/Claude" | wc -l | tr -d ' '; }
wait_open() {  # account name, then expected state: open or not
    for _ in $(seq 1 40); do
        if sw --list | grep -F "$1" | grep -q "open (pid" ; then [ "$2" = open ] && return 0; else [ "$2" = closed ] && return 0; fi
        sleep 0.5
    done
    return 1
}

echo "== building the stand-in Claude.app"
mkdir -p "$CLAUDE_SWITCHER_APP/Contents/MacOS" "$CLAUDE_SWITCHER_SUPPORT_DIR"
swiftc -O -framework AppKit -o "$CLAUDE_SWITCHER_APP/Contents/MacOS/Claude" "$here/FakeClaude.swift" || exit 1
cat > "$CLAUDE_SWITCHER_APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Claude</string>
<key>CFBundleIdentifier</key><string>io.github.priyanshugetrekt.fake-claude</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>9.9.9</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
EOF
codesign --force --sign - "$CLAUDE_SWITCHER_APP" >/dev/null 2>&1
# A Claude.app changed in the last minute counts as mid-update, and the watchdog waits.
touch -t 202501010000 "$CLAUDE_SWITCHER_APP"
rm -f "$log"

echo "== command line"
check "--version prints the version" '[[ "$(sw --version)" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]'
out="$(sw --list)"
check "--list shows only Default at first" '[ "$(echo "$out" | wc -l | tr -d " ")" = 1 ] && echo "$out" | grep -q "^Default"'
out="$(sw --add-account)"
check "--add-account reports Account 2" 'echo "$out" | grep -q "Added .Account 2."'
check "Account 2 folder made" '[ -d "$CLAUDE_SWITCHER_SUPPORT_DIR/ClaudeProfiles/Account 2" ]'
check "Account 2 opened" 'wait_open "Account 2" open'
echo "  --- diagnostics: ps lines for the stand-in, and what the switcher lists"
ps -axww -o pid=,args= | grep -F "Fake Apps" | grep -v grep | sed "s/^/      /"
echo "      CLAUDE_SWITCHER_APP=$CLAUDE_SWITCHER_APP"
sw --list | sed "s/^/      /"
check "it was started with its own folder (path with spaces)" 'grep -qF "args=[--user-data-dir=$CLAUDE_SWITCHER_SUPPORT_DIR/ClaudeProfiles/Account 2]" "$log"'
before="$(open_count)"
out="$(sw --launch "Account 2")"
sleep 2
check "--launch on an open account switches to it" 'echo "$out" | grep -q "Switched to"'
check "... without starting a second copy" '[ "$(open_count)" = "$before" ]'
sw --launch Default >/dev/null
check "Default opened" 'wait_open "Default" open'
check "Default was started without --user-data-dir" 'grep -q "args=\[\]" "$log"'
check "both show as open" '[ "$(sw --list | grep -c "open (pid")" = 2 ]'

echo "== flags and environment per account"
cat > "$CLAUDE_SWITCHER_SUPPORT_DIR/ClaudeProfiles/settings.json" <<'EOF'
{ "ProfileArgs": { "Account 2": ["--lang", "a b"] }, "ProfileEnv": { "Account 2": { "MY_PEER": "peer-2", "bad name": "x" } } }
EOF
out="$(sw --restart "Account 2")"
check "--restart reports a restart" 'echo "$out" | grep -q "Restarted"'
check "Account 2 open again" 'wait_open "Account 2" open'
sleep 1
last="$(grep -F "ClaudeProfiles/Account 2" "$log" | tail -1)"
check "restart passed the folder, then each flag as its own argument" 'echo "$last" | grep -qF "Account 2|--lang|a b]"'
check "restart passed the environment variable" 'echo "$last" | grep -qF "MY_PEER=[peer-2]"'

echo "== rename, quit, delete"
out="$(sw --rename "Account 2" Work)"
check "--rename reports the new name" 'echo "$out" | grep -q "Renamed .Account 2. to .Work."'
check "--list shows the label and the folder" 'sw --list | grep -q "^Work \[Account 2\]"'
check "--launch finds it by its new name" 'sw --launch Work | grep -q "Switched to .Work."'
check "a taken name is refused" '! sw --rename Work Default >/dev/null'
out="$(sw --launch Nope)"; status=$?
check "an unknown name is refused, listing the accounts" '[ "$status" -ne 0 ] && echo "$out" | grep -q "Profiles: Default, Work"'
out="$(sw --quit Work)"
check "--quit reports it" 'echo "$out" | grep -q "Quit .Work."'
check "Work is no longer open" 'wait_open "Work" closed'
check "--quit on a closed account says so" 'sw --quit Work | grep -q "was not open"'
check "Default is still open" 'sw --list | grep "^Default" | grep -q "open (pid"'
check "Default cannot be deleted" '! sw --delete Default >/dev/null'
out="$(sw --delete Work)"
check "--delete reports it" 'echo "$out" | grep -q "Deleted .Work."'
check "its folder is gone" '[ ! -d "$CLAUDE_SWITCHER_SUPPORT_DIR/ClaudeProfiles/Account 2" ]'
check "its label is gone from settings.json" '! grep -q "\"Account 2\"" "$CLAUDE_SWITCHER_SUPPORT_DIR/ClaudeProfiles/settings.json"'
check "an unknown option is refused" '! sw --bogus >/dev/null'
sw --quit Default >/dev/null

echo "== Claude Code chats"
src="$P/Alpha/claude-code-sessions/acct-a/org-a"
dst="$P/Beta/claude-code-sessions/acct-b/org-b"
mkdir -p "$src" "$dst"
cat > "$src/local_abc123.json" <<'EOF'
{"title":"Fix the login page","cwd":"/Users/someone/code/shop","accountUuid":"acct-a","organizationUuid":"org-a","note":"/keep/acct-a/as/is"}
EOF
out="$(sw --chats Alpha)"
check "--chats lists the chat with its id, folder and title" 'echo "$out" | grep -q "^abc123 .* shop  Fix the login page"'
out="$(sw --transfer Alpha Beta --all)"
check "--transfer reports one copied" 'echo "$out" | grep -q "Copied 1 chat"'
check "the copy sits in the target account store" '[ -f "$dst/local_abc123.json" ]'
check "... with the account and organisation ids swapped" 'grep -q "\"acct-b\"" "$dst/local_abc123.json" && grep -q "\"org-b\"" "$dst/local_abc123.json"'
check "... and paths that only contain an id left alone" 'grep -qF "/keep/acct-a/as/is" "$dst/local_abc123.json"'
check "the original stays" '[ -f "$src/local_abc123.json" ]'
check "a second transfer skips it" 'sw --transfer Alpha Beta --chat abc123 | grep -q "1 were already there"'
mkdir -p "$P/Gamma"
out="$(sw --transfer Alpha Gamma --all)"; status=$?
check "a target that never used Claude Code is refused with advice" '[ "$status" -ne 0 ] && echo "$out" | grep -q "has not used Claude Code yet"'
out="$(sw --transfer Alpha Beta)"; status=$?
check "nothing picked is refused" '[ "$status" -ne 0 ] && echo "$out" | grep -q "No chats picked"'
rm -rf "$P/Gamma"

echo "== keep running"
out="$(sw --keep-running Alpha)"; status=$?
echo "$out" | sed "s/^/      /"
check "--keep-running succeeds" '[ "$status" -eq 0 ]'
check "the watchdog agent file exists" '[ -f "$CLAUDE_SWITCHER_LAUNCHAGENTS_DIR/$agent.watchdog.plist" ]'
check "the agent runs --watch every two minutes" 'plutil -p "$CLAUDE_SWITCHER_LAUNCHAGENTS_DIR/$agent.watchdog.plist" | grep -q "\"--watch\"" && plutil -p "$CLAUDE_SWITCHER_LAUNCHAGENTS_DIR/$agent.watchdog.plist" | grep -q "StartInterval.*120"'
check "the agent keeps the test folders" 'plutil -p "$CLAUDE_SWITCHER_LAUNCHAGENTS_DIR/$agent.watchdog.plist" | grep -qF "$CLAUDE_SWITCHER_SUPPORT_DIR"'
check "launchd has it loaded" 'launchctl print "gui/$(id -u)/$agent.watchdog" >/dev/null 2>&1'
check "--list shows nothing open yet" '! sw --list | grep "^Alpha" | grep -q "open (pid"'
mkdir -p "$P/Alpha/logs"
printf '%s
' "[info] beforeQuit: handler fired" > "$P/Alpha/logs/main.log"
sw --watch >/dev/null
sleep 2
check "a quit by the user is left alone" '! sw --list | grep "^Alpha" | grep -q "open (pid"'
printf '%s
' "[info] something" "[info] going down for update" > "$P/Alpha/logs/main.log"
out="$(sw --watch)"
check "a forced close is undone" 'echo "$out" | grep -q "Reopened: Alpha" || wait_open Alpha open'
check "Alpha is open again" 'wait_open Alpha open'
check "the watchdog logged it" 'grep -q "Reopened .Alpha." "$P/.switcher/watchdog.log"'
sw --quit Alpha >/dev/null; wait_open Alpha closed
out="$(sw --watch)"; sleep 2
check "not again within ten minutes" '! sw --list | grep "^Alpha" | grep -q "open (pid"'
out="$(sw --stop-keeping Alpha)"
check "--stop-keeping removes the agent with the last kept account" 'echo "$out" | grep -q "watchdog agent was removed" && [ ! -f "$CLAUDE_SWITCHER_LAUNCHAGENTS_DIR/$agent.watchdog.plist" ]'
check "launchd no longer has it" '! launchctl print "gui/$(id -u)/$agent.watchdog" >/dev/null 2>&1'

echo "== open at login, doctor, uninstall"
sw --open-at-login on >/dev/null
check "--open-at-login on writes the login agent" '[ -f "$CLAUDE_SWITCHER_LAUNCHAGENTS_DIR/$agent.login.plist" ]'
out="$(sw --doctor)"
echo "$out" | sed "s/^/      /"
check "--doctor names the version, Claude and the accounts" 'echo "$out" | grep -q "Claude Profile Switcher" && echo "$out" | grep -q "Claude: 9.9.9" && echo "$out" | grep -q "Alpha"'
check "--doctor reports Open at Login" 'echo "$out" | grep -q "Open at Login: on"'
check "--doctor leaves out the user name" '! echo "$out" | grep -qi "$(id -un)"'
sw --keep-running Beta >/dev/null
out="$(sw --uninstall)"
check "--uninstall removes both agents" '[ ! -f "$CLAUDE_SWITCHER_LAUNCHAGENTS_DIR/$agent.login.plist" ] && [ ! -f "$CLAUDE_SWITCHER_LAUNCHAGENTS_DIR/$agent.watchdog.plist" ]'
check "... and keeps the accounts" '[ -d "$P/Alpha" ] && [ -f "$P/settings.json" ] && echo "$out" | grep -q "remove-profiles"'
out="$(sw --uninstall --remove-profiles)"
check "--uninstall --remove-profiles deletes the added accounts and settings" '[ ! -d "$P/Alpha" ] && [ ! -d "$P/Beta" ] && [ ! -f "$P/settings.json" ]'
check "... but never the original account" 'sw --list | grep -q "^Default"'

if [ -n "$shots" ]; then
    echo "== screenshots"
    mkdir -p "$shots"
    rm -f "$CLAUDE_SWITCHER_SUPPORT_DIR/ClaudeProfiles/settings.json"
    sw --add-account >/dev/null && sw --rename "Account 2" Work >/dev/null
    mkdir -p "$CLAUDE_SWITCHER_SUPPORT_DIR/ClaudeProfiles/Account 3" && sw --rename "Account 3" Personal >/dev/null
    mkdir -p "$CLAUDE_SWITCHER_SUPPORT_DIR/ClaudeProfiles/Account 4" && sw --rename "Account 4" "Client Acme" >/dev/null
    sw --launch Default >/dev/null
    wait_open Work open; wait_open Default open
    sw --snapshot "$shots/macos-switcher-light.png" --appearance light
    sw --snapshot "$shots/macos-switcher-dark.png" --appearance dark
    setting ProfileEnv "Account 2" '{"ANTHROPIC_LOG":"debug","HTTPS_PROXY":"http://proxy.example:8080"}'
    setting ProfileArgs "Account 2" '"--lang=en-GB"'
    setting KeepRunning "Account 2" 'true'
    sw --snapshot-edit "$shots/macos-edit-light.png" --account Work --appearance light
    sw --snapshot-edit "$shots/macos-edit-dark.png" --account Work --appearance dark
    check "edit dialog screenshot written" '[ -s "$shots/macos-edit-light.png" ]'
    check "light screenshot written" '[ -s "$shots/macos-switcher-light.png" ]'
    check "dark screenshot written" '[ -s "$shots/macos-switcher-dark.png" ]'
    sw --quit Work >/dev/null; sw --quit Default >/dev/null
fi

pkill -f "Fake Apps/Claude.app/Contents/MacOS/Claude" 2>/dev/null
echo
if [ "$fails" -eq 0 ]; then echo "PASS: all macOS checks"; else echo "FAILED: $fails check(s)"; echo "--- stand-in log"; cat "$log"; fi
exit "$fails"
