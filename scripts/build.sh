#!/bin/sh
# Builds Rex's Tail.app into ./build and signs it.
#
#   scripts/build.sh          build and sign
#   scripts/build.sh --run    build, sign, then (re)launch the app
#
# Signing with a stable identity (your Apple Development certificate) keeps the
# Accessibility permission valid across rebuilds. Override with SIGN_IDENTITY.
# Without a certificate, the app is signed for this Mac only (ad hoc), and
# macOS asks for the Accessibility permission again after each rebuild.
set -eu
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Rex's Tail.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/RexWidgets "$APP/Contents/MacOS/RexWidgets"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/agent_reader.py "$APP/Contents/Resources/agent_reader.py"
cp Resources/menubar.svg "$APP/Contents/Resources/menubar.svg"

IDENTITY="${SIGN_IDENTITY:-Apple Development}"
if [ "$IDENTITY" != "-" ] && ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "note: no \"$IDENTITY\" signing certificate found; signing ad hoc for this Mac only." >&2
  echo "      macOS will ask for the Accessibility permission again after each rebuild." >&2
  IDENTITY="-"
fi
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/RexWidgets.entitlements --sign "$IDENTITY" "$APP"
echo "built $APP"

if [ "${1:-}" = "--run" ]; then
  pkill -x RexWidgets 2>/dev/null && sleep 0.5 || true
  open "$APP"
fi
