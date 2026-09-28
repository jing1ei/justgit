#!/bin/bash
# Publish only complete artifacts; reruns may resume an existing draft.
set -euo pipefail
: "${GH_REPO:?GH_REPO is required}"
: "${RELEASE_TAG:?RELEASE_TAG is required}"
: "${RELEASE_SHA:?RELEASE_SHA is required}"
ARTIFACTS="${1:?Usage: PublishRelease.sh artifact-directory}"
[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "Invalid version tag" >&2; exit 1; }
VERSION="${RELEASE_TAG#v}"
for name in "JustGit-macOS-$VERSION.zip" "JustGit-Windows-$VERSION.zip" "JustGit-source-$VERSION.zip" SHA256SUMS.txt; do
  [ -s "$ARTIFACTS/$name" ] || { echo "Missing artifact: $name" >&2; exit 1; }
done
(cd "$ARTIFACTS" && sha256sum --check SHA256SUMS.txt)
# The remote tag must still identify the commit that was built.
REMOTE_SHA=$(gh api "repos/$GH_REPO/commits/$RELEASE_TAG" --jq .sha)
[ "$REMOTE_SHA" = "$RELEASE_SHA" ] || { echo "Tag moved since this build; refusing publication." >&2; exit 1; }
if DRAFT=$(gh release view "$RELEASE_TAG" --json isDraft --jq .isDraft 2>/dev/null); then
  [ "$DRAFT" = true ] || { echo "Release is already published; its assets will not be overwritten." >&2; exit 1; }
else
  # Authentication/network failures also stop here if creation cannot succeed.
  gh release create "$RELEASE_TAG" --verify-tag --draft --title "JustGit $VERSION" \
    --notes "Mac universal (Intel and Apple silicon), Windows x64, and source. Build commit: $RELEASE_SHA."
fi
gh release upload "$RELEASE_TAG" --clobber \
  "$ARTIFACTS/JustGit-macOS-$VERSION.zip" \
  "$ARTIFACTS/JustGit-Windows-$VERSION.zip" \
  "$ARTIFACTS/JustGit-source-$VERSION.zip" "$ARTIFACTS/SHA256SUMS.txt"
gh release edit "$RELEASE_TAG" --draft=false
