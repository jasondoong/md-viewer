#!/bin/bash
# Build a Release MDPreview.app into ./build/Release without opening Xcode.
set -euo pipefail
cd "$(dirname "$0")"

# xcodebuild needs full Xcode, not just the Command Line Tools.
# If the active developer dir is CLT, fall back to an installed Xcode.app for this build only.
if ! xcodebuild -version >/dev/null 2>&1; then
  XCODE_APP=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort | tail -1)
  if [ -n "$XCODE_APP" ]; then
    export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
    echo "Using $XCODE_APP"
  else
    echo "Error: full Xcode is required (Command Line Tools alone can't build macOS apps)." >&2
    echo "Install Xcode from the App Store, then run:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
  fi
fi
xcodebuild -project MDPreview.xcodeproj -target MDPreview -configuration Release SYMROOT="$PWD/build" build
echo
echo "Built: $PWD/build/Release/MDPreview.app"
echo "Install: cp -R build/Release/MDPreview.app /Applications/"
