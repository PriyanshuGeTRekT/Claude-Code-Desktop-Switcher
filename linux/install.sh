#!/bin/sh
# Installs Claude Profile Switcher for this user only: no sudo, nothing outside your home.
#   ~/.local/bin/claude-switcher, plus app menu entries for the switcher and each account.
# Remove it again with: claude-switcher --uninstall
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
bin="${XDG_BIN_HOME:-$HOME/.local/bin}"
mkdir -p "$bin"
install -m 755 "$here/claude-switcher" "$bin/claude-switcher"
"$bin/claude-switcher" --install-launchers >/dev/null
echo "Installed $bin/claude-switcher"
echo "Open \"Claude Profile Switcher\" from your app menu, or run: claude-switcher"
case ":$PATH:" in
    *":$bin:"*) ;;
    *) echo "Note: $bin is not on your PATH yet; log out and back in, or add it to PATH." ;;
esac
if ! python3 -c 'import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk' 2>/dev/null; then
    echo "The window needs GTK 3 for Python. On Ubuntu or Debian: sudo apt install python3-gi python3-gi-cairo gir1.2-gtk-3.0"
    echo "Everything also works from the command line: claude-switcher --help"
fi
if ! command -v claude-desktop >/dev/null 2>&1 && ! command -v claude-desktop-unofficial >/dev/null 2>&1; then
    echo "Claude for Linux was not found. Install it from https://claude.com/download, or use --claude-path PATH."
fi
