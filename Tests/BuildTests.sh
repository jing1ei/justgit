#!/bin/bash
set -euo pipefail
export LLVM_PROFILE_FILE=/dev/null
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/justgit-build-tests.XXXXXX")"
trap 'rm -rf "$BASE"' EXIT
export HOME="$BASE/home"
mkdir -p "$HOME"

# Exercise installation control flow with an inert binary and no GUI launch.
xcrun() {
  if [ "${1:-}" = "--find" ]; then return 0; fi
  if [ "${1:-}" = "lipo" ]; then
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "-output" ]; then /bin/cp /usr/bin/true "$2"; return; fi
      shift
    done
    return 1
  fi
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "-target" ] && [[ "$2" != *-apple-macos11.0 ]]; then
      printf 'Unexpected deployment target: %s\n' "$2" >&2
      return 1
    fi
    if [ "$1" = "-o" ]; then /bin/cp /usr/bin/true "$2"; return; fi
    shift
  done
  return 1
}
pgrep() { return 1; }
codesign() { return 0; }
xattr() { return 0; }
open() { return 0; }
cp() {
  if [ "${FAIL_PACKAGE:-}" = assemble ] && [[ "$2" == */JustGit.app/* ]]; then
    return 1
  fi
  /bin/cp "$@"
}
mv() {
  if [[ "$1" == */.JustGit-package.*/JustGit.app ]]; then
    case "${FAIL_PACKAGE:-}" in
      move) return 1 ;;
      interrupt) kill -TERM "$$"; return 1 ;;
    esac
  fi
  case "$1" in
    "$HOME"/Applications/.JustGit-install.*/JustGit.app)
      case "${FAIL_INSTALL:-}" in
        move) return 1 ;;
        interrupt) kill -TERM "$$"; return 1 ;;
      esac
      ;;
  esac
  /bin/mv "$@"
}
export -f xcrun pgrep codesign xattr open cp mv

run_build() { /bin/bash "$ROOT/Build.command" "$@" > "$BASE/output.log" 2>&1 < /dev/null; }
check() {
  if "$@"; then
    printf 'ok  %s\n' "$*"
  else
    /bin/cat "$BASE/output.log"
    printf 'FAIL %s\n' "$*" >&2
    exit 1
  fi
}

check run_build --check
check test ! -e "$HOME/Applications/JustGit.app"
if JUSTGIT_VERSION='1.0.0<&' run_build --check; then
  printf 'FAIL invalid bundle version was accepted\n' >&2
  exit 1
fi
if JUSTGIT_BUILD='invalid' run_build --check; then
  printf 'FAIL invalid build number was accepted\n' >&2
  exit 1
fi
if run_build --unknown; then
  printf 'FAIL unknown build option was accepted\n' >&2
  exit 1
fi
check test ! -e "$HOME/Applications/JustGit.app"

# --package emits a bundle without installing or launching anything.
PKG="$BASE/pkg"
JUSTGIT_VERSION=9.9 JUSTGIT_BUILD=42 check run_build --package "$PKG"
check test -x "$PKG/JustGit.app/Contents/MacOS/JustGit"
check cmp "$ROOT/LICENCE" "$PKG/JustGit.app/Contents/Resources/LICENCE"
check cmp "$ROOT/Assets/AppIcon.icns" "$PKG/JustGit.app/Contents/Resources/AppIcon.icns"
check grep -q '<key>CFBundleIconFile</key><string>AppIcon</string>' "$PKG/JustGit.app/Contents/Info.plist"
check grep -q "<string>9.9</string>" "$PKG/JustGit.app/Contents/Info.plist"
check grep -q "<string>42</string>" "$PKG/JustGit.app/Contents/Info.plist"
check grep -q "<key>LSUIElement</key><true/>" "$PKG/JustGit.app/Contents/Info.plist"
check grep -q '<key>LSMinimumSystemVersion</key><string>11.0</string>' "$PKG/JustGit.app/Contents/Info.plist"
check test ! -e "$HOME/Applications/JustGit.app"
if run_build --package; then
  printf 'FAIL --package without a directory was accepted\n' >&2
  exit 1
fi

touch "$PKG/JustGit.app/previous"
for failure in assemble move interrupt; do
  export FAIL_PACKAGE="$failure"
  if run_build --package "$PKG"; then
    printf 'FAIL injected package %s failure was ignored\n' "$failure" >&2
    exit 1
  fi
  check test -f "$PKG/JustGit.app/previous"
  check test ! -e "$PKG/.JustGit-package.lock"
done
unset FAIL_PACKAGE
check run_build --package "$PKG"
check test ! -e "$PKG/JustGit.app/previous"
check test ! -e "$PKG/.JustGit-package.lock"

mkdir "$PKG/.JustGit-package.lock"
touch "$PKG/JustGit.app/previous"
if run_build --package "$PKG"; then
  printf 'FAIL concurrent package lock was ignored\n' >&2
  exit 1
fi
check test -f "$PKG/JustGit.app/previous"
check test -d "$PKG/.JustGit-package.lock"
rmdir "$PKG/.JustGit-package.lock"

mkdir -p "$HOME/Applications/JustGit.app"
touch "$HOME/Applications/JustGit.app/previous"
export FAIL_INSTALL=move
if run_build; then
  printf 'FAIL injected move failure was ignored\n' >&2
  exit 1
fi
check test -f "$HOME/Applications/JustGit.app/previous"
check test ! -e "$HOME/Applications/.JustGit-install.lock"

export FAIL_INSTALL=interrupt
if run_build; then
  printf 'FAIL interrupted install reported success\n' >&2
  exit 1
fi
check test -f "$HOME/Applications/JustGit.app/previous"
check test ! -e "$HOME/Applications/.JustGit-install.lock"

unset FAIL_INSTALL
check run_build
check test ! -e "$HOME/Applications/JustGit.app/previous"
check test -x "$HOME/Applications/JustGit.app/Contents/MacOS/JustGit"
check cmp "$ROOT/LICENCE" "$HOME/Applications/JustGit.app/Contents/Resources/LICENCE"
check test ! -e "$HOME/Applications/.JustGit-install.lock"
printf 'Installer checks passed; no real app was launched.\n'
