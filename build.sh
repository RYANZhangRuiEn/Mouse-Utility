#!/bin/zsh
set -eu
ROOT="${0:A:h}"
OUT="${MOUSERING_OUTPUT_DIR:-$ROOT/dist}"
STAGE=$(mktemp -d /tmp/mousering-preview.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/鼠环 Preview.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/module-cache"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx27.0 -sdk "$(xcrun --show-sdk-path)" -module-cache-path "$ROOT/build/module-cache" -framework IOKit -framework AppKit -framework Carbon -framework CoreAudio -framework AudioToolbox -framework ApplicationServices "$ROOT"/Sources/*.swift -o "$APP/Contents/MacOS/OrbitDial"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
for file in Orbit.icns NativeZoom.html THIRD_PARTY_NOTICES.md LICENSE PROVENANCE.md PRIVACY.md; do cp "$ROOT/$file" "$APP/Contents/Resources/$file"; done
/usr/bin/codesign --force --sign - --identifier local.mousering.preview "$APP"
"$APP/Contents/MacOS/OrbitDial" --self-test
/usr/bin/codesign --verify --strict --verbose=2 "$APP"
mkdir -p "$OUT"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$APP" "$OUT/MouseRing-1.0-Preview-4-macOS.zip"
