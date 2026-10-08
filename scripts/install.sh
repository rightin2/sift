#!/bin/bash
# Builds Sift in Release and installs (or updates) it in /Applications.
# Builds land in Xcode's DerivedData: building inside the Desktop folder breaks code signing.
set -euo pipefail

cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project Sift.xcodeproj -scheme Sift -configuration Release -destination 'platform=macOS' build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

BUILT=$(xcodebuild -project Sift.xcodeproj -scheme Sift -configuration Release -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR =/ { print $3; exit }')/Sift.app
[ -d "$BUILT" ] || { echo "Build failed: no app at $BUILT"; exit 1; }

osascript -e 'quit app "Sift"' 2>/dev/null || true
sleep 1
ditto "$BUILT" /Applications/Sift.app
codesign --verify --deep --strict /Applications/Sift.app

# Only the installed copy should show up in Spotlight and Launchpad.
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LS" -u "$BUILT" 2>/dev/null || true
"$LS" -f /Applications/Sift.app
echo "Installed /Applications/Sift.app"
