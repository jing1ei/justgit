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
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then /bin/cp /usr/bin/true "$2"; return; fi
    shift
  done
  return 1
}
pgrep() { return 1; }
codesign() { return 0; }
xattr() { return 0; }
open() { return 0; }
mv() {
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
export -f xcrun pgrep codesign xattr open mv

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
if run_build --unknown; then
  printf 'FAIL unknown build option was accepted\n' >&2
  exit 1
fi
check test ! -e "$HOME/Applications/JustGit.app"

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
