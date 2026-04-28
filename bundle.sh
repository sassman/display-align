#!/usr/bin/env bash
# Build DisplayAlign and wrap it in a macOS .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="DisplayAlign"
APP_BUNDLE="$HOME/Applications/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"

echo "Building..."
swift build -c release 2>&1

echo "Bundling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${CONTENTS}/MacOS"
mkdir -p "${CONTENTS}/Resources"
cp ".build/release/${APP_NAME}" "${CONTENTS}/MacOS/"

# Generate app icon from SF Symbol
echo "Generating app icon..."
swift generate-icon.swift
iconutil -c icns /tmp/DisplayAlign.iconset -o "${CONTENTS}/Resources/AppIcon.icns"

cat > "${CONTENTS}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.local.display-align</string>
    <key>CFBundleName</key>
    <string>DisplayAlign</string>
    <key>CFBundleExecutable</key>
    <string>DisplayAlign</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

echo ""
echo "Installed: ${APP_BUNDLE}"
echo "Run: open '${APP_BUNDLE}'"
