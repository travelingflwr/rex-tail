#!/bin/sh
# Builds Rex Widgets.app into ./build and signs it.
#
#   scripts/build.sh          build and sign
#   scripts/build.sh --run    build, sign, then (re)launch the app
#
# Signing with a stable identity (your Apple Development certificate) keeps the
# Accessibility permission valid across rebuilds. Override with SIGN_IDENTITY.
set -eu
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Rex's Tail.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/RexWidgets "$APP/Contents/MacOS/RexWidgets"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/agent_reader.py "$APP/Contents/Resources/agent_reader.py"

IDENTITY="${SIGN_IDENTITY:-Apple Development}"
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/RexWidgets.entitlements --sign "$IDENTITY" "$APP"
echo "built $APP"

if [ "${1:-}" = "--run" ]; then
  pkill -x RexWidgets 2>/dev/null && sleep 0.5 || true
  open "$APP"
fi
