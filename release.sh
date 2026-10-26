#!/usr/bin/env bash
# Build Llasso, zip it, and publish it as a GitHub release that install.sh downloads.
# The version comes from CFBundleShortVersionString in Resources/Info.plist; raise it first.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
TAG="v$VERSION"
ZIP="dist/Llasso-$VERSION-mac-arm64.zip"

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG exists already. Raise CFBundleShortVersionString in Resources/Info.plist." >&2
    exit 1
fi
[ -z "$(git status --porcelain -- Sources Resources Package.swift)" ] || { echo "Commit the source changes first." >&2; exit 1; }

./build.sh release
mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent "$HOME/Applications/Llasso.app" "$ZIP"
echo "▸ $ZIP ($(du -h "$ZIP" | cut -f 1))"

git push -q
gh release create "$TAG" "$ZIP" --title "Llasso $VERSION" --target "$(git rev-parse HEAD)" \
    --notes "Install or update:

    curl -fsSL https://raw.githubusercontent.com/jamiejefferson/llasso/main/install.sh | sh

Needs a Mac with Apple silicon and macOS 26 or later."
echo "✓ Released $TAG"
