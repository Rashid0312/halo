#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$PWD/build/Halo.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Halo "$APP/Contents/MacOS/Halo"
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
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Add :HaloDevelopmentEnvFile string $PWD/../.env" "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
