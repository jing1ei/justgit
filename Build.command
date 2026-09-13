#!/bin/bash
# Build JustGit.app and drop it into ~/Applications. Double-click me.
set -euo pipefail
export LLVM_PROFILE_FILE=/dev/null
cd "$(cd "$(dirname "$0")" && pwd)"

B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; R=$'\033[31m'; N=$'\033[0m'
say() { printf "%s·%s %s\n" "$D" "$N" "$1"; }
ok()  { printf "%s✓%s %s\n" "$G" "$N" "$1"; }

# Only wait for a keypress when a human is actually watching a terminal.
pause() {
  [ -t 0 ] || return 0
  printf "\n%s—— %s ——%s" "$D" "$1" "$N"
  read -n 1 -s -r || true
  printf "\n"
}
die() { printf "%s✗%s %s\n" "$R" "$N" "$1"; pause "press any key"; exit 1; }

USAGE="Usage: Build.command [--check | --package <dir>]"
MODE=install
PACKAGE_DIR=""
case "${1:-}" in
  "")        [ "$#" -eq 0 ] || die "$USAGE" ;;
  --check)   MODE=check;   [ "$#" -eq 1 ] || die "$USAGE" ;;
  --package) MODE=package; [ "$#" -eq 2 ] || die "$USAGE"; PACKAGE_DIR="$2" ;;
  *)         die "$USAGE" ;;
esac

# Release metadata. CI overrides these from the tag; local builds keep the defaults.
VERSION="${JUSTGIT_VERSION:-2.1}"
BUILD_NUMBER="${JUSTGIT_BUILD:-3}"

printf "\n%sBuilding JustGit%s\n\n" "$B" "$N"

xcrun --find swiftc >/dev/null 2>&1 || {
  say "Swift compiler missing, asking macOS to install the Xcode command line tools…"
  xcode-select --install >/dev/null 2>&1 || true
  die "Click Install in the popup, wait for it to finish, then double-click this file again."
}

APP="$HOME/Applications/JustGit.app"
DEST="$APP"
OUT="$(mktemp -d "./.justgit-build.XXXXXX")"
STAGE=""
LOCK=""
INSTALLED=0
cleanup() {
  local result=$?
  trap - EXIT
  if [ -n "$STAGE" ] && [ "$INSTALLED" -eq 0 ] && [ -e "$STAGE/previous.app" ]; then
    if [ ! -e "$DEST" ] && mv "$STAGE/previous.app" "$DEST"; then
      say "previous installation restored"
    else
      printf "Previous installation preserved at %s/previous.app\n" "$STAGE" >&2
      STAGE=""
      result=1
    fi
  fi
  rm -rf "$OUT"
  [ -z "$STAGE" ] || rm -rf "$STAGE"
  [ -z "$LOCK" ] || rmdir "$LOCK" 2>/dev/null || true
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Assemble JustGit.app at $1. Used by both --package and the installer.
make_app() {
  mkdir -p "$1/Contents/MacOS" "$1/Contents/Resources"
  cp "$OUT/JustGit" "$1/Contents/MacOS/JustGit"
  cp LICENCE "$1/Contents/Resources/LICENCE"

  cat > "$1/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>JustGit</string>
  <key>CFBundleDisplayName</key><string>JustGit</string>
  <key>CFBundleExecutable</key><string>JustGit</string>
  <key>CFBundleIdentifier</key><string>local.justgit.app</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>JustGit runs git in the folder you pick.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>JustGit runs git in the folder you pick.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>JustGit runs git in the folder you pick.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>JustGit runs git in the folder you pick.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string></array>
      <key>LSHandlerRank</key><string>Alternate</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

  xattr -cr "$1" 2>/dev/null || true
  codesign --force --sign - "$1" >/dev/null 2>&1 || say "ad-hoc signing skipped"
}

compile_slice() { # $1 = arch, $2 = output path
  xcrun swiftc -O -whole-module-optimization \
         -target "$1-apple-macos12.0" \
         -framework AppKit \
         -o "$2" Sources/*.swift || die "compile failed for $1 (see errors above)"
}

if [ "$MODE" = package ]; then
  # Releases must run on both Apple silicon and Intel.
  say "compiling universal (arm64 + x86_64)…"
  compile_slice arm64  "$OUT/JustGit-arm64"
  compile_slice x86_64 "$OUT/JustGit-x86_64"
  xcrun lipo -create "$OUT/JustGit-arm64" "$OUT/JustGit-x86_64" -output "$OUT/JustGit" \
    || die "could not combine architectures"
  rm -f "$OUT/JustGit-arm64" "$OUT/JustGit-x86_64"
  ok "compiled universal"
else
  say "compiling…"
  compile_slice "$(uname -m)" "$OUT/JustGit"
  ok "compiled"
fi

# Never install a binary that fails its own checks.
say "self-test…"
"$OUT/JustGit" --selftest || die "self-test failed — nothing was installed"
ok "self-test passed"

if [ "$MODE" = check ]; then
  ok "verification complete — nothing installed or launched"
  exit 0
fi

if [ "$MODE" = package ]; then
  mkdir -p "$PACKAGE_DIR" || die "could not create $PACKAGE_DIR"
  PACKAGED="$PACKAGE_DIR/JustGit.app"
  rm -rf "$PACKAGED"
  make_app "$PACKAGED"
  ok "packaged → $PACKAGED (version $VERSION, build $BUILD_NUMBER)"
  exit 0
fi

# Never kill an app that may be in the middle of a Git mutation.
if pgrep -x JustGit >/dev/null 2>&1; then
  die "Quit JustGit after its current operation finishes, then run this build again."
fi

mkdir -p "$HOME/Applications"
INSTALL_LOCK="$HOME/Applications/.JustGit-install.lock"
mkdir "$INSTALL_LOCK" 2>/dev/null || die "Another install is active. If none is running, remove $INSTALL_LOCK and retry."
LOCK="$INSTALL_LOCK"
STAGE="$(mktemp -d "$HOME/Applications/.JustGit-install.XXXXXX")"
APP="$STAGE/JustGit.app"
make_app "$APP"

if [ -e "$DEST" ]; then
  mv "$DEST" "$STAGE/previous.app" || die "could not preserve existing installation"
fi
mv "$APP" "$DEST" || die "install failed"
INSTALLED=1
APP="$DEST"
ok "installed → $APP"
say "launching…"
open "$APP" || die "could not launch"

printf "\n%sTip: keep it in the Dock — right-click the icon › Options › Keep in Dock%s\n" "$D" "$N"
printf "%s提示：右键 Dock 图标 › 选项 › 在程序坞中保留，以后点一下就开%s\n" "$D" "$N"
pause "press any key to close"
