#!/bin/bash
# Publishes a new version on GitHub: ./release.sh 0.2 "What's new"
# Sets the version, builds the disk image, commits, tags, pushes and creates the GitHub release
# with Mixtape.dmg and the guide attached. --dry-run stops before anything leaves this Mac.
set -euo pipefail
cd "$(dirname "$0")"

DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi
VERSION="${1:?usage: ./release.sh [--dry-run] <version> [notes]}"
NOTES="${2:-}"
TAG="v$VERSION"
GUIDE="build/Zuerst lesen – Read me first.pdf"

if [ $DRY = 0 ]; then
    gh auth status >/dev/null 2>&1 || { echo "Not logged in to GitHub. Run: gh auth login"; exit 1; }
    git remote get-url origin >/dev/null 2>&1 || { echo "No GitHub repository yet. Run: gh repo create mixtape --public --source . --push"; exit 1; }
    git diff --quiet HEAD -- . ':!Info.plist' || { echo "Commit your changes first."; exit 1; }
    ! git rev-parse "$TAG" >/dev/null 2>&1 || { echo "$TAG already exists."; exit 1; }
fi

BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" Info.plist
./package.sh

if [ $DRY = 1 ]; then
    echo "Dry run: built $TAG (build $BUILD). Nothing was committed or uploaded."
    git checkout -- Info.plist 2>/dev/null || true
    exit 0
fi

git commit -m "Mixtape $VERSION" Info.plist
git tag "$TAG"
git push origin HEAD "$TAG"
gh release create "$TAG" build/Mixtape.dmg "$GUIDE" --title "Mixtape $VERSION" --notes "${NOTES:-Mixtape $VERSION}"
echo "Released $TAG: $(gh release view "$TAG" --json url -q .url)"
