#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/justgit-release-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
export RELEASE_TEST_DIR="$TEST_DIR"
export GH_REPO=example/fixture RELEASE_TAG=v1.0.0 RELEASE_SHA=0123456789abcdef
mkdir "$TEST_DIR/assets"
for platform in macOS Windows source; do
  printf 'fixture\n' > "$TEST_DIR/assets/JustGit-$platform-1.0.0.zip"
done
(cd "$TEST_DIR/assets" && shasum -a 256 ./*.zip > SHA256SUMS.txt)
sha256sum() { shasum -a 256 "$@"; }
gh() {
  printf '%s\n' "$*" >> "$RELEASE_TEST_DIR/calls"
  case "$1 $2" in
    'api '*)
      if [ "$SCENARIO" = moved ]; then printf 'changed\n'; else printf '%s\n' "$RELEASE_SHA"; fi ;;
    'release view')
      case "$SCENARIO" in
        draft|upload-fail) printf 'true\n' ;;
        published) printf 'false\n' ;;
        *) return 1 ;;
      esac ;;
    'release upload') [ "$SCENARIO" != upload-fail ] ;;
    'release create') [ "$SCENARIO" != denied ] ;;
    'release edit') return 0 ;;
    *) return 1 ;;
  esac
}
export -f gh sha256sum
run() {
  export SCENARIO="$1"
  : > "$TEST_DIR/calls"
  bash "$ROOT/Tools/PublishRelease.sh" "$TEST_DIR/assets" > "$TEST_DIR/output" 2>&1
}
for scenario in new draft; do
  run "$scenario"
  grep -q 'release upload .*--clobber' "$TEST_DIR/calls"
  grep -q 'release edit v1.0.0 --draft=false' "$TEST_DIR/calls"
done
for scenario in moved published upload-fail denied; do
  if run "$scenario"; then echo "Unexpected publication success: $scenario" >&2; exit 1; fi
  if grep -q 'release edit' "$TEST_DIR/calls"; then echo "Published after failure: $scenario" >&2; exit 1; fi
done
mv "$TEST_DIR/assets/JustGit-Windows-1.0.0.zip" "$TEST_DIR/missing.zip"
if run new; then echo 'Missing artifact accepted' >&2; exit 1; fi
[ ! -s "$TEST_DIR/calls" ]
mv "$TEST_DIR/missing.zip" "$TEST_DIR/assets/JustGit-Windows-1.0.0.zip"
printf 'corrupt\n' >> "$TEST_DIR/assets/JustGit-Windows-1.0.0.zip"
if run new; then echo 'Corrupt artifact accepted' >&2; exit 1; fi
[ ! -s "$TEST_DIR/calls" ]
echo 'Release checks passed: draft creation/resume, tag identity, permissions, upload failure, missing and corrupt artifacts.'
