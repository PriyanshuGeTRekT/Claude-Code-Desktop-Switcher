#!/bin/bash
# End-to-end tests for the Linux switcher, against a stand-in Claude that records how it
# was started. Never touches a real Claude, real accounts or the real desktop settings:
# HOME and the XDG folders point into a temporary folder whose path has a space in it.
# Usage: linux/tests/run-tests.sh [screenshot-folder]
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../claude-switcher"
shots="${1:-}"
py=/usr/bin/python3
[ -x "$py" ] || py="$(command -v python3)"
root="$(mktemp -d)/switcher test"
export HOME="$root/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
unset CLAUDE_SWITCHER_SUPPORT_DIR
fake="$root/fake bin/claude-desktop"
export CLAUDE_SWITCHER_APP="$fake" CLAUDE_SWITCHER_NO_FOCUS=1
export FAKE_CLAUDE_LOG="$root/fake.log" FAKE_DEFAULT_DIR="$XDG_CONFIG_HOME/Claude"
P="$XDG_CONFIG_HOME/ClaudeProfiles"
APPS="$XDG_DATA_HOME/applications"
log="$FAKE_CLAUDE_LOG"
fails=0
pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi }
sw() { "$py" "$src" "$@" 2>&1; }
mains() { pgrep -f "fake bin/claude-desktop" -a | grep -v -- "--type=" | wc -l | tr -d ' '; }
pid_of() { sw --list | grep -F "$1" | sed -n 's/.*open (pid \([0-9]*\)).*/\1/p' | head -1; }
wait_open() {  # account name, then open or closed
    for _ in $(seq 1 40); do
        if sw --list | grep -F "$1" | grep -q "open (pid"; then [ "$2" = open ] && return 0; else [ "$2" = closed ] && return 0; fi
        sleep 0.25
    done
    return 1
}
# A link with this marker reached that account's running Claude.
reached() {
    local pid line=""
    pid="$(pid_of "$2")"
    for _ in $(seq 1 20); do
        line="$(grep -F "$1" "$log" | tail -1)"
        [ -n "$line" ] && break
        sleep 0.25
    done
    echo "      $line"
    [ -n "$pid" ] && case "$line" in *"forwarded-to=$pid "*) return 0 ;; esac
    return 1
}

echo "== building the stand-in Claude"
mkdir -p "$(dirname "$fake")" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
gcc -O2 -Wall -o "$fake" "$here/fake-claude.c" || exit 1
rm -f "$log"

echo "== command line"
check "--version prints the version" '[[ "$(sw --version)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]'
out="$(sw --list)"
check "--list shows only Default at first" '[ "$(echo "$out" | wc -l | tr -d " ")" = 1 ] && echo "$out" | grep -q "^Default"'
out="$(sw --add-account)"
check "--add-account reports Account 2" 'echo "$out" | grep -q "Added .Account 2."'
check "Account 2 folder made" '[ -d "$P/Account 2" ]'
check "Account 2 opened" 'wait_open "Account 2" open'
check "it was started with its own folder and window class" 'grep -qF "args=[--user-data-dir=$P/Account 2|--class=ClaudeProfile-account-2]" "$log"'
main_pid="$(grep -F "args=[--user-data-dir=$P/Account 2|" "$log" | head -1 | sed "s/^pid=\([0-9]*\) .*/\1/")"
check "its helper process is not taken for the account" '[ "$(pid_of "Account 2")" = "$main_pid" ] && pgrep -f -- "--type=renderer --user-data-dir=$P/Account 2" >/dev/null'
before="$(mains)"
out="$(sw --launch "Account 2")"
sleep 1
check "--launch on an open account switches to it" 'echo "$out" | grep -q "Switched to"'
check "... through the copy already running, not a second one" '[ "$(mains)" = "$before" ] && grep -q "forwarded-to=$main_pid " "$log"'
sw --launch Default >/dev/null
check "Default opened" 'wait_open "Default" open'
check "Default was started without a folder or class" 'grep -q "args=\[\] MY_PEER" "$log"'
check "both show as open" '[ "$(sw --list | grep -c "open (pid")" = 2 ]'

echo "== flags and environment per account"
cat > "$P/settings.json" <<'EOF'
{ "ProfileArgs": { "Account 2": ["--lang", "a b"] }, "ProfileEnv": { "Account 2": { "MY_PEER": "peer-2", "bad name": "x" } } }
EOF
out="$(sw --restart "Account 2")"
check "--restart reports a restart" 'echo "$out" | grep -q "Restarted"'
check "Account 2 open again" 'wait_open "Account 2" open'
last="$(grep -F "args=[--user-data-dir=$P/Account 2|" "$log" | tail -1)"
check "restart passed the folder, then each flag as its own argument" 'echo "$last" | grep -qF "Account 2|--class=ClaudeProfile-account-2|--lang|a b]"'
check "restart passed the environment variable" 'echo "$last" | grep -qF "MY_PEER=[peer-2]"'
sw --edit "Account 2" --color 3 --flags="--x-one --x-two" --env EXTRA=1 >/dev/null
setting() { "$py" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d.get(sys.argv[2],{}).get(sys.argv[3])))' "$P/settings.json" "$@"; }
check "--edit saves the colour" '[ "$(setting ChosenColors "Account 2")" = 3 ]'
check "--edit saves the flags" 'setting ProfileArgs "Account 2" | grep -qF -- "--x-one --x-two"'
check "--edit adds the variable and keeps the others" 'setting ProfileEnv "Account 2" | grep -qF "\"EXTRA\": \"1\"" && setting ProfileEnv "Account 2" | grep -qF "peer-2"'
check "--edit refuses a taken name and saves nothing" '! sw --edit "Account 2" --name Default --color 5 >/dev/null && grep -q "\"Account 2\": 3" "$P/settings.json"'

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
check "Work is no longer open, helper included" 'wait_open Work closed && sleep 0.5 && ! pgrep -f -- "--user-data-dir=$P/Account 2" >/dev/null'
check "--quit on a closed account says so" 'sw --quit Work | grep -q "was not open"'
check "Default is still open" 'sw --list | grep "^Default" | grep -q "open (pid"'
check "Default cannot be deleted" '! sw --delete Default >/dev/null'
out="$(sw --delete Work)"
check "--delete reports it" 'echo "$out" | grep -q "Deleted .Work."'
check "its folder is gone" '[ ! -d "$P/Account 2" ]'
check "its settings are gone" '! grep -q "\"Account 2\"" "$P/settings.json"'
check "an unknown option is refused" '! sw --bogus >/dev/null'
sw --quit Default >/dev/null

echo "== Claude Code chats"
srcs="$P/Alpha/claude-code-sessions/acct-a/org-a"
dst="$P/Beta/claude-code-sessions/acct-b/org-b"
mkdir -p "$srcs" "$dst"
cat > "$srcs/local_abc123.json" <<'EOF'
{"title":"Fix the login page","cwd":"/home/someone/code/shop","accountUuid":"acct-a","organizationUuid":"org-a","note":"/keep/acct-a/as/is"}
EOF
out="$(sw --chats Alpha)"
check "--chats lists the chat with its id, folder and title" 'echo "$out" | grep -q "^abc123 .* shop  Fix the login page"'
out="$(sw --transfer Alpha Beta --all)"
check "--transfer reports one copied" 'echo "$out" | grep -q "Copied 1 chat"'
check "... with the account and organisation ids swapped" 'grep -q "\"acct-b\"" "$dst/local_abc123.json" && grep -q "\"org-b\"" "$dst/local_abc123.json"'
check "... and paths that only contain an id left alone" 'grep -qF "/keep/acct-a/as/is" "$dst/local_abc123.json"'
check "a second transfer skips it" 'sw --transfer Alpha Beta --chat abc123 | grep -q "1 were already there"'
mkdir -p "$P/Gamma"
out="$(sw --transfer Alpha Gamma --all)"; status=$?
check "a target that never used Claude Code is refused with advice" '[ "$status" -ne 0 ] && echo "$out" | grep -q "has not used Claude Code yet"'
rm -rf "$P/Gamma"

echo "== app menu launchers"
sw --install-launchers >/dev/null
check "each account gets a launcher" '[ -f "$APPS/claude-profile-alpha.desktop" ] && [ -f "$APPS/claude-profile-beta.desktop" ]'
check "... that opens it through the switcher" 'grep -q "^Exec=.*claude-switcher --launch Alpha$" "$APPS/claude-profile-alpha.desktop"'
check "... and matches its windows" 'grep -q "^StartupWMClass=ClaudeProfile-alpha$" "$APPS/claude-profile-alpha.desktop"'
check "... with a coloured icon" '[ -s "$XDG_DATA_HOME/icons/hicolor/scalable/apps/claude-profile-alpha.svg" ]'
check "the switcher entry lists every account as an action" 'grep -q "^Actions=open-default;open-alpha;open-beta;add-account;$" "$APPS/claude-profile-switcher.desktop"'
if command -v desktop-file-validate >/dev/null; then
    check "the desktop files are valid" 'desktop-file-validate "$APPS"/claude-profile-*.desktop'
fi
sw --rename Beta "Client Acme" >/dev/null
check "a rename updates the launcher" 'grep -q "^Name=Claude (Client Acme)$" "$APPS/claude-profile-beta.desktop"'

echo "== sign-in routing"
mkdir -p "$XDG_CONFIG_HOME"
printf '[Default Applications]\ntext/html=firefox.desktop\nx-scheme-handler/claude=claude-desktop.desktop\n\n[Added Associations]\nimage/png=eog.desktop;\n' > "$XDG_CONFIG_HOME/mimeapps.list"
out="$(sw --route-sign-ins)"; status=$?
echo "$out" | sed "s/^/      /"
check "--route-sign-ins succeeds" '[ "$status" -eq 0 ]'
check "the switcher is the claude:// handler" 'grep -q "^x-scheme-handler/claude=claude-profile-router.desktop$" "$XDG_CONFIG_HOME/mimeapps.list"'
check "... and every other line is kept" 'grep -q "^text/html=firefox.desktop$" "$XDG_CONFIG_HOME/mimeapps.list" && grep -q "^image/png=eog.desktop;$" "$XDG_CONFIG_HOME/mimeapps.list"'
check "the router entry takes the link" 'grep -q "^Exec=.*claude-switcher --handle-link %u$" "$APPS/claude-profile-router.desktop"'
sw --launch Default >/dev/null; wait_open Default open
check "a launch leaves a helper watching the handler" 'pgrep -f "claude-switcher --hold-handler" >/dev/null'
sed -i "s/^x-scheme-handler\/claude=.*/x-scheme-handler\/claude=claude-desktop.desktop/" "$XDG_CONFIG_HOME/mimeapps.list"
sleep 1.5
check "... which takes it back when Claude claims it" 'grep -q "^x-scheme-handler/claude=claude-profile-router.desktop$" "$XDG_CONFIG_HOME/mimeapps.list"'
out="$(sw --add-account)"
new="$(echo "$out" | sed -n "s/^Added '\([^']*\)'.*/\1/p")"
check "an account started signed out is expected to sign in" 'grep -qF "\"$new\"" "$P/.switcher/pending-sign-in.json"'
wait_open "$new" open
sw --handle-link "claude://claude.ai/sso-callback?code=one" >/dev/null
check "its sign-in reaches it, not Default" 'reached "code=one" "$new"'
check "the log names the reason" 'grep -q "Sign-in sent to .$new. (launched while signed out" "$P/.switcher/router.log"'
check "the log never holds the link" '! grep -q "code=" "$P/.switcher/router.log"'
check "the marker is cleared" '[ ! -f "$P/.switcher/pending-sign-in.json" ]'
printf '{"windowSizeWasSignedIn":true}' > "$P/$new/config.json"
printf '{"windowSizeWasSignedIn":false}' > "$P/Beta/config.json"
sw --launch Beta >/dev/null; wait_open Beta open
rm -f "$P/.switcher/pending-sign-in.json"
sw --handle-link "claude://claude.ai/sso-callback?code=two" >/dev/null
check "with nothing pending, the only signed-out account gets it" 'reached "code=two" "Client Acme"'
printf '{"windowSizeWasSignedIn":true}' > "$P/Beta/config.json"
sw --handle-link "claude://claude.ai/chat/x?n=three" >/dev/null
check "other links go to Default" 'reached "n=three" Default'
sw --open-links-in "Client Acme" >/dev/null
sw --handle-link "claude://claude.ai/chat/x?n=four" >/dev/null
check "... or to the account Open Other Links In names" 'reached "n=four" "Client Acme"'
sw --handle-link 'claude://claude.ai/sso-callback?code=five six' >/dev/null; sleep 0.5
check "a malformed link is refused" '! grep -q "code=five" "$log" && grep -q "Refused" "$P/.switcher/router.log"'
if command -v gio >/dev/null; then
    gio open "claude://claude.ai/chat/x?n=seven" >/dev/null 2>&1
    check "a link opened through the desktop reaches the router" 'reached "n=seven" "Client Acme"'
fi
echo "  --- router log"; sed "s/^/      /" "$P/.switcher/router.log"
pkill -f "claude-switcher --hold-handler"
out="$(sw --revert)"
echo "$out" | sed "s/^/      /"
check "--revert gives links back to Claude's own entry" 'grep -q "^x-scheme-handler/claude=claude-desktop.desktop$" "$XDG_CONFIG_HOME/mimeapps.list" && [ ! -f "$APPS/claude-profile-router.desktop" ]'
sw --handle-link "claude://claude.ai/sso-callback?code=six" >/dev/null
check "with routing off, a sign-in goes to Default" 'reached "code=six" Default'
sw --open-links-in Default >/dev/null
pkill -f "fake bin/claude-desktop"; sleep 0.5

echo "== doctor, uninstall"
sw --route-sign-ins >/dev/null; pkill -f "claude-switcher --hold-handler"
out="$(sw --doctor)"
echo "$out" | sed "s/^/      /"
check "--doctor names the version, the accounts and routing" 'echo "$out" | grep -q "Claude Profile Switcher .* (Linux)" && echo "$out" | grep -q "Alpha" && echo "$out" | grep -q "routing:  on"'
check "--doctor leaves out the user name" '! echo "$out" | grep -qiw "$(id -un)"'
out="$(sw --uninstall)"
check "--uninstall gives links back and removes the launchers" 'grep -q "^x-scheme-handler/claude=claude-desktop.desktop$" "$XDG_CONFIG_HOME/mimeapps.list" && ! ls "$APPS"/claude-profile-* >/dev/null 2>&1'
check "... and keeps the accounts" '[ -d "$P/Alpha" ] && [ -f "$P/settings.json" ] && echo "$out" | grep -q "remove-profiles"'
out="$(sw --uninstall --remove-profiles)"
check "--uninstall --remove-profiles deletes the added accounts and settings" '[ ! -d "$P/Alpha" ] && [ ! -d "$P/Beta" ] && [ ! -f "$P/settings.json" ]'
check "... but never the original account" '[ -d "$XDG_CONFIG_HOME/Claude" ] && sw --list | grep -q "^Default"'

echo "== self-update"
bin="$root/bin"; feed="$root/feed"
mkdir -p "$bin" "$feed"
cp "$src" "$bin/claude-switcher"; chmod +x "$bin/claude-switcher"
sed 's/^VERSION = ".*"/VERSION = "99.0.0"/' "$src" > "$feed/claude-switcher"
(cd "$feed" && sha256sum claude-switcher > SHA256SUMS.txt)
echo 99.0.0 > "$feed/latest-version"
upd() { CLAUDE_SWITCHER_RELEASE_DIR="$feed" "$py" "$bin/claude-switcher" "$@" 2>&1; }
installed() { sed -n 's/^VERSION = "\(.*\)"/\1/p' "$bin/claude-switcher"; }
before_v="$(installed)"
check "--check-update finds the newer release" 'upd --check-update | grep -q "Version 99.0.0 is available"'
cp "$feed/SHA256SUMS.txt" "$feed/good"
echo "0000000000000000000000000000000000000000000000000000000000000000  claude-switcher" > "$feed/SHA256SUMS.txt"
out="$(upd --update)"; status=$?
check "a download that fails its checksum is refused" '[ "$status" -ne 0 ] && echo "$out" | grep -q "checksum"'
check "... and the switcher is left as it was" '[ "$(installed)" = "$before_v" ]'
mv "$feed/good" "$feed/SHA256SUMS.txt"
out="$(upd --update)"; status=$?
echo "$out" | sed "s/^/      /"
check "--update installs the newer release" '[ "$status" -eq 0 ] && echo "$out" | grep -q "Updated to 99.0.0" && [ "$(installed)" = 99.0.0 ] && [ -x "$bin/claude-switcher" ]'
echo 1.0.0 > "$feed/latest-version"
check "an older release is not offered" 'upd --check-update | grep -q "is up to date"'

if [ -n "$shots" ]; then
    echo "== screenshots"
    if "$py" -c 'import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk' 2>/dev/null && command -v xvfb-run >/dev/null; then
        mkdir -p "$shots"
        sw --add-account >/dev/null && sw --rename "Account 2" Work >/dev/null
        mkdir -p "$P/Account 3" && sw --rename "Account 3" Personal >/dev/null
        mkdir -p "$P/Account 4" && sw --rename "Account 4" "Client Acme" >/dev/null
        sw --edit Work --env ANTHROPIC_LOG=debug --env HTTPS_PROXY=http://proxy.example:8080 --flags=--lang=en-GB >/dev/null
        sw --launch Default >/dev/null; wait_open Work open; wait_open Default open
        gui() { xvfb-run -a -s "-screen 0 1280x800x24" dbus-run-session -- "$py" "$src" "$@" 2>&1 | grep -v "^$" | sed "s/^/      /"; }
        gui --snapshot "$shots/linux-switcher-light.png" --appearance light
        gui --snapshot "$shots/linux-switcher-dark.png" --appearance dark
        gui --snapshot-edit "$shots/linux-edit-light.png" --account Work --appearance light
        check "light screenshot written" '[ -s "$shots/linux-switcher-light.png" ]'
        check "dark screenshot written" '[ -s "$shots/linux-switcher-dark.png" ]'
        check "edit dialog screenshot written" '[ -s "$shots/linux-edit-light.png" ]'
    else
        echo "  skipped: GTK 3 for Python or xvfb-run is not installed"
    fi
fi

pkill -f "fake bin/claude-desktop" 2>/dev/null
pkill -f "claude-switcher --hold-handler" 2>/dev/null
echo
if [ "$fails" -eq 0 ]; then echo "PASS: all Linux checks"; else echo "FAILED: $fails check(s)"; echo "--- stand-in log"; cat "$log"; fi
exit "$fails"
