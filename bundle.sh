#!/usr/bin/env bash
# Build DisplayAlign and wrap it in a macOS .app bundle.
#
# Usage: ./bundle.sh [VERSION [APP_BUNDLE]]
#
#   VERSION     embedded as CFBundleVersion / CFBundleShortVersionString
#               (default: git describe --tags --always, else 0.0.0-dev)
#   APP_BUNDLE  output .app path
#               (default: $HOME/Applications/DisplayAlign.app)

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DisplayAlign"
VERSION="${1:-$(git describe --tags --always 2>/dev/null || echo 0.0.0-dev)}"
APP_BUNDLE="${2:-$HOME/Applications/${APP_NAME}.app}"
CONTENTS="${APP_BUNDLE}/Contents"

echo "Building ${APP_NAME} ${VERSION}..."
swift build -c release 2>&1

echo "Bundling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${CONTENTS}/MacOS"
mkdir -p "${CONTENTS}/Resources"
cp ".build/release/${APP_NAME}" "${CONTENTS}/MacOS/"

echo "Generating app icon..."
swift generate-icon.swift
iconutil -c icns /tmp/DisplayAlign.iconset -o "${CONTENTS}/Resources/AppIcon.icns"

cat > "${CONTENTS}/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>me.d34dl0ck.display-align</string>
    <key>CFBundleName</key>
    <string>DisplayAlign</string>
    <key>CFBundleExecutable</key>
    <string>DisplayAlign</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Sven Kanoldt. Distributed under the MIT License.</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

echo
echo "Installed: ${APP_BUNDLE}"
echo "Run: open '${APP_BUNDLE}'"
