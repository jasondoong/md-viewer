#!/bin/bash
# Build MDPreview (Release) and install it to /Applications.
#   ./build.sh               build + install to /Applications
#   ./build.sh --no-install  build only (output in build.noindex/Release)
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

# ".noindex" keeps Spotlight / the Applications search from listing the build copy
# as a second MDPreview next to the installed one.
BUILD_DIR="$PWD/build.noindex"
APP="$BUILD_DIR/Release/MDPreview.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

xcodebuild -project MDPreview.xcodeproj -target MDPreview -configuration Release SYMROOT="$BUILD_DIR" build

# Make sure Finder's "Open With" only knows about the installed copy.
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true

echo
if [ "${1:-}" = "--no-install" ]; then
  echo "Built: $APP"
  exit 0
fi

rm -rf /Applications/MDPreview.app
cp -R "$APP" /Applications/
"$LSREGISTER" -f /Applications/MDPreview.app
echo "Installed: /Applications/MDPreview.app"
