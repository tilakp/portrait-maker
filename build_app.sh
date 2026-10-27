#!/bin/bash
# Builds a .app bundle from a SwiftPM executable target: release build,
# assemble Contents/{MacOS,Resources}, copy Info.plist, icon and resources,
# sign, and optionally install to /Applications.
#
# Configure the four variables below, then:
#   ./build_app.sh            # builds ./AppName.app
#   ./build_app.sh --install  # also copies it to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PortraitMaker"                          # SwiftPM executable product name
BUNDLE_ID="com.tilak.portraitmaker"
SIGN_NAME="${APP_NAME} Local Signing"     # from mac-app-signing/setup_signing.sh
RESOURCES=()                              # files under Sources/$APP_NAME/Resources to copy, e.g. (data.sqlite)

# SwiftUI macros need the Xcode toolchain, not only the Command Line Tools.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c release
./scripts/fetch_model.sh

APP="$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Models/DepthAnything.mlmodelc "$APP/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
for resource in ${RESOURCES[@]+"${RESOURCES[@]}"}; do
    cp "Sources/$APP_NAME/Resources/$resource" "$APP/Contents/Resources/$resource"
done

SIGN_IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_NAME"; then
    SIGN_IDENTITY="$SIGN_NAME"
else
    echo "WARNING: '$SIGN_NAME' identity not found; falling back to ad-hoc signing." >&2
    echo "         TCC permissions will reset on every rebuild. Run setup_signing.sh once to fix it." >&2
fi
codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"

echo "Built $APP (signed with: $SIGN_IDENTITY)"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/$APP"
    cp -R "$APP" "/Applications/$APP"
    echo "Installed to /Applications/$APP"
fi
