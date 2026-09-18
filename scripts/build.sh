#!/usr/bin/env bash
# Builds a universal AudIO.app into build/, signs it and optionally notarizes it.
#
#   VERSION         marketing version (default 0.1.0)
#   SIGN_IDENTITY   codesign identity; defaults to the first "Developer ID Application"
#                   identity in the keychain, falling back to ad-hoc signing ("-")
#   NOTARY_PROFILE  notarytool keychain profile (see README); when set, the app is
#                   notarized and stapled
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUNDLE_ID="ng.balanci.audio"
OUT=build
APP="$OUT/AudIO.app"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

echo "==> Building universal binary"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/AudIO"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AudIO"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
    Support/Info.plist > "$APP/Contents/Info.plist"

ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"
"$BIN" --render-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "==> Ad-hoc signing (no Developer ID identity found; others will see Gatekeeper warnings)"
    codesign --force --sign - "$APP"
else
    echo "==> Signing with $SIGN_IDENTITY"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

ZIP="$OUT/AudIO-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        echo "error: notarization needs a Developer ID Application identity" >&2
        exit 1
    fi
    echo "==> Notarizing (this can take a few minutes)"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    # Re-zip so the distributed copy carries the stapled ticket
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    spctl --assess --type execute --verbose "$APP"
fi

echo "==> Done: $APP and $ZIP"
