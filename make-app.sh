#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MeetRec"
BUNDLE_ID="com.local.meetrec"
APP_DIR="${APP_NAME}.app"
SIGN_ID="${CODESIGN_IDENTITY:--}"
RESET_PERMISSIONS=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --sign)
            [ "$#" -ge 2 ] || { echo "--sign requires an identity" >&2; exit 2; }
            SIGN_ID="$2"; shift 2 ;;
        --reset-permissions) RESET_PERMISSIONS=true; shift ;;
        --help)
            echo "Usage: $0 [--sign IDENTITY] [--reset-permissions]"
            echo "Default: ad-hoc signing; no keychain identity selection, process killing, or TCC reset."
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

refuse_running() {
    if pgrep -x "$APP_NAME" >/dev/null; then
        echo "MeetRec is running. Stop/save recording and quit before rebuilding." >&2
        exit 1
    fi
}
refuse_running
if [ -L "$APP_DIR" ]; then
    echo "Refusing to replace a symbolic-link app bundle." >&2
    exit 1
fi

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
STAGING="$(mktemp -d "$PWD/.MeetRec-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
CONTENTS="$STAGING/$APP_DIR/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_DIR/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
fi

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleVersion</key><string>5</string>
    <key>CFBundleShortVersionString</key><string>0.3.1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>MeetRec records your microphone into a local audio file.</string>
    <key>NSAudioCaptureUsageDescription</key><string>MeetRec records system audio, including other audible apps, into a local file.</string>
    <key>NSScreenCaptureUsageDescription</key><string>MeetRec uses ScreenCaptureKit for system audio. No video is saved.</string>
</dict></plist>
EOF
cat > "$STAGING/entitlements.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
EOF
codesign --force --options runtime --entitlements "$STAGING/entitlements.plist" \
    --sign "$SIGN_ID" "$STAGING/$APP_DIR"
codesign --verify --deep --strict "$STAGING/$APP_DIR"
refuse_running
rm -rf "$APP_DIR"
mv "$STAGING/$APP_DIR" "$APP_DIR"

if "$RESET_PERMISSIONS"; then
    tccutil reset ScreenCapture "$BUNDLE_ID"
    tccutil reset Microphone "$BUNDLE_ID"
fi
printf '\nBuilt %s (not installed or launched).\n' "$APP_DIR"
echo "Default ad-hoc builds may need permissions re-granted after rebuilding."
echo "Use --sign IDENTITY explicitly for stable signing. No notarization is performed."
