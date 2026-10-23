#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Pinned sherpa-onnx libraries and wake/VAD models, downloaded and verified once.
bash scripts/fetch-deps.sh
SIGN_IDENTITY="${HALO_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && [ -f .native/signing-identity.txt ]; then
    SIGN_IDENTITY="$(cat .native/signing-identity.txt)"
fi
if [ -z "$SIGN_IDENTITY" ]; then
    case "$(security find-identity -v -p codesigning 2>/dev/null)" in
        *'"Mercy Local Signing"'*) SIGN_IDENTITY="Mercy Local Signing" ;;
    esac
fi
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="-"
    printf 'Ad-hoc development signing: privacy grants can expire after code changes. Configure a stable signing identity for daily use.\n' >&2
fi
swift build -c release
# Sign outside the Desktop file-provider directory: Finder metadata can be
# reattached there between xattr cleanup and codesign.
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/halo-native.XXXXXX")"
APP="$STAGING/Halo.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/models"
cp .native/*.dylib "$APP/Contents/Frameworks/"
cp Resources/* "$APP/Contents/Resources/"
cp -R models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01 "$APP/Contents/Resources/models/"
cp models/silero_vad.onnx "$APP/Contents/Resources/models/"
cp .build/release/Halo "$APP/Contents/MacOS/Halo"
if [ -f .build/release/HaloNativeHost ]; then
    cp .build/release/HaloNativeHost "$APP/Contents/MacOS/HaloNativeHost"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Halo</string>
<key>CFBundleIdentifier</key><string>app.halo.native.dev</string>
<key>CFBundleName</key><string>Halo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Halo listens locally for Mercy or Hey Mercy when hands-free is enabled, and when you tap the microphone.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Halo transcribes what you say on this Mac.</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>app.halo.native.oauth</string>
<key>CFBundleURLSchemes</key><array><string>halo</string></array>
</dict></array>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Add :HaloDevelopmentEnvFile string $PWD/../.env" "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP/Contents/Frameworks/libonnxruntime.dylib"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP/Contents/Frameworks/libsherpa-onnx-c-api.dylib"
if [ -f "$APP/Contents/MacOS/HaloNativeHost" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP/Contents/MacOS/HaloNativeHost"
fi
xattr -cr "$APP"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$PWD/build"
ditto --norsrc --noextattr "$APP" "$PWD/build/Halo.app"
# Register halo:// (OAuth callbacks) with this copy, not the temporary one.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$PWD/build/Halo.app"
printf 'Built %s\n' "$PWD/build/Halo.app"
