#!/bin/bash
# Builds "Claude Profile Switcher.app" (Apple Silicon and Intel) and a zip of it.
# Usage: macos/build.sh [output-folder]    (default: macos/build)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/build}"
version="$(sed -n 's/^let switcherVersion = "\(.*\)"$/\1/p' "$here/ClaudeSwitcher.swift")"
[ -n "$version" ] || { echo "No version line in ClaudeSwitcher.swift" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"
for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos12.0" -framework AppKit \
        -o "$out/ClaudeSwitcher-$arch" "$here/ClaudeSwitcher.swift"
done
lipo -create -output "$out/ClaudeSwitcher" "$out/ClaudeSwitcher-arm64" "$out/ClaudeSwitcher-x86_64"
rm "$out/ClaudeSwitcher-arm64" "$out/ClaudeSwitcher-x86_64"

app="$out/Claude Profile Switcher.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$out/ClaudeSwitcher" "$app/Contents/MacOS/ClaudeSwitcher"
sed "s/__VERSION__/$version/g" "$here/Info.plist" > "$app/Contents/Info.plist"
"$out/ClaudeSwitcher" --render-icon "$out/AppIcon.iconset"
iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$out/AppIcon.iconset"
rm -rf "$out/AppIcon.iconset"

# Ad hoc: enough for Apple Silicon to run it. Not notarized, so the first open from a
# download needs right-click > Open (see the README).
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

(cd "$out" && ditto -c -k --sequesterRsrc --keepParent "Claude Profile Switcher.app" "ClaudeProfileSwitcher-macOS.zip")
echo "Built $version: $app"
lipo -info "$app/Contents/MacOS/ClaudeSwitcher"
