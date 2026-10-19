#!/bin/bash
# Inspect a real release bundle; then execute each architecture when supported.
set -euo pipefail
APP="${1:?Usage: bash Tests/CompatibilityTests.sh /path/to/JustGit.app}"
BINARY="$APP/Contents/MacOS/JustGit"
MINIMUM=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")
[ "$MINIMUM" = 11.0 ] || { echo "Bundle must target macOS 11.0" >&2; exit 1; }
for architecture in arm64 x86_64; do
  xcrun lipo "$BINARY" -verify_arch "$architecture"
  minimum=$(xcrun otool -arch "$architecture" -l "$BINARY" | awk '
    $1 == "cmd" { version = ($2 == "LC_BUILD_VERSION" || $2 == "LC_VERSION_MIN_MACOSX") }
    version && !found && ($1 == "minos" || $1 == "version") { print $2; found = 1 }')
  [ "$minimum" = 11.0 ] || { echo "$architecture targets $minimum, expected 11.0" >&2; exit 1; }
  echo "$architecture: macOS 11.0 deployment verified"
  if /usr/bin/arch -"$architecture" /usr/bin/true 2>/dev/null; then
    /usr/bin/arch -"$architecture" "$BINARY" --selftest
  else
    echo "$architecture execution unavailable on this host; binary inspection passed only."
  fi
done
codesign --verify --deep --strict "$APP"
