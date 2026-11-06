#!/bin/bash
# Builds a release and publishes it on GitHub; running copies of Takes pick it up as an update.
#   ./scripts/release.sh 0.2.0 "这次更新的内容"
# Must run on the machine that holds the "Takes Local Signing" keychain: the app only installs
# updates signed with the same certificate.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?用法: release.sh <版本号> [更新说明]}"
NOTES="${2:-修复和改进。}"
REPO="ai-suifeng/takes"

# Version shown in the app and compared by the updater; build number always goes up.
BUILD=$(( $(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml) + 1 ))
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml

./scripts/build.sh Release

mkdir -p dist
ZIP="dist/Takes-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Takes.app "$ZIP"
echo "Packed $ZIP ($(du -h "$ZIP" | cut -f1))"

# A fixed-name copy gives the website a stable link: releases/latest/download/Takes.zip
cp "$ZIP" dist/Takes.zip
gh release create "v$VERSION" "$ZIP" dist/Takes.zip --repo "$REPO" --title "Takes $VERSION" --notes "$NOTES"
echo "Published https://github.com/$REPO/releases/tag/v$VERSION"
