#!/bin/bash
# Builds the Linux downloads into OUT (default: dist):
#   claude-switcher                               the program itself (also what --update fetches)
#   claude-profile-switcher_all.deb               for Ubuntu and Debian (a stable name, so
#                                                 releases/latest/download links keep working)
#   ClaudeProfileSwitcher-linux.tar.gz            the program and install.sh, for any distribution
# Usage: linux/build.sh [OUT]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-dist}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
version="$(sed -n 's/^VERSION = "\(.*\)"/\1/p' "$here/claude-switcher")"
[ -n "$version" ] || { echo "no VERSION line in claude-switcher" >&2; exit 1; }
python3 -m py_compile "$here/claude-switcher"

icon() {  # the app icon, from the program so there is one source
    python3 - "$here/claude-switcher" "$1" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("claude_switcher", sys.argv[1])
spec = importlib.util.spec_from_loader("claude_switcher", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
open(sys.argv[2], "w").write(mod.APP_ICON_SVG)
PY
}

install -m 755 "$here/claude-switcher" "$out/claude-switcher"

# .deb, xz-compressed: zstd (the newer default) is not understood by older dpkg
pkg="$(mktemp -d)/claude-profile-switcher_${version}_all"
install -Dm 755 "$here/claude-switcher" "$pkg/usr/bin/claude-switcher"
mkdir -p "$pkg/usr/share/icons/hicolor/scalable/apps" "$pkg/usr/share/applications" "$pkg/usr/share/doc/claude-profile-switcher" "$pkg/DEBIAN"
icon "$pkg/usr/share/icons/hicolor/scalable/apps/claude-profile-switcher.svg"
cat > "$pkg/usr/share/applications/claude-profile-switcher.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Claude Profile Switcher
GenericName=Claude account switcher
Comment=Run several Claude desktop accounts at once
Exec=claude-switcher
Icon=claude-profile-switcher
Categories=Utility;
Keywords=Claude;Anthropic;account;profile;switch;
Terminal=false
StartupNotify=true
EOF
cp "$here/../LICENSE" "$pkg/usr/share/doc/claude-profile-switcher/copyright"
cat > "$pkg/DEBIAN/control" <<EOF
Package: claude-profile-switcher
Version: ${version}
Architecture: all
Maintainer: Claude Profile Switcher <https://github.com/PriyanshuGeTRekT/Claude-Code-Desktop-Switcher>
Depends: python3 (>= 3.8)
Recommends: python3-gi, python3-gi-cairo, gir1.2-gtk-3.0
Suggests: claude-desktop, wmctrl
Section: utils
Priority: optional
Homepage: https://github.com/PriyanshuGeTRekT/Claude-Code-Desktop-Switcher
Description: Run several Claude desktop accounts at once
 Each account of the Claude desktop app gets a folder of its own, so a work and a
 personal account (or several) stay signed in side by side. Includes a window, app menu
 launchers per account, Claude Code chat transfer between accounts and sign-in routing.
 Unofficial; not affiliated with Anthropic.
EOF
dpkg-deb --root-owner-group -Zxz --build "$pkg" "$out/claude-profile-switcher_all.deb" >/dev/null

# tarball
tarroot="$(mktemp -d)/ClaudeProfileSwitcher-linux"
mkdir -p "$tarroot"
install -m 755 "$here/claude-switcher" "$tarroot/claude-switcher"
install -m 755 "$here/install.sh" "$tarroot/install.sh"
cp "$here/../LICENSE" "$tarroot/LICENSE"
tar -C "$(dirname "$tarroot")" -czf "$out/ClaudeProfileSwitcher-linux.tar.gz" ClaudeProfileSwitcher-linux

ls -l "$out"
