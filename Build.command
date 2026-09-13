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

if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--check" ]; }; then
  die "Usage: Build.command [--check]"
fi

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

say "compiling…"
xcrun swiftc -O -whole-module-optimization \
       -target "$(uname -m)-apple-macos12.0" \
       -framework AppKit \
       -o "$OUT/JustGit" Sources/*.swift || die "compile failed (see errors above)"
ok "compiled"

# Never install a binary that fails its own checks.
say "self-test…"
"$OUT/JustGit" --selftest || die "self-test failed — nothing was installed"
ok "self-test passed"

if [ "${1:-}" = "--check" ]; then
  ok "verification complete — nothing installed or launched"
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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$OUT/JustGit" "$APP/Contents/MacOS/JustGit"
cp LICENCE "$APP/Contents/Resources/LICENCE"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>JustGit</string>
  <key>CFBundleDisplayName</key><string>JustGit</string>
  <key>CFBundleExecutable</key><string>JustGit</string>
  <key>CFBundleIdentifier</key><string>local.justgit.app</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.1</string>
  <key>CFBundleVersion</key><string>3</string>
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

xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - "$APP" >/dev/null 2>&1 || say "ad-hoc signing skipped"

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
