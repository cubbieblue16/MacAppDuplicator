#!/usr/bin/env bash
# Builds the FixtureApp test bundle at .build/fixtures/FixtureApp.app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/fixtures/FixtureApp.app"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

swiftc -target arm64-apple-macos26.0 -swift-version 5 -O \
    -o "$OUT/Contents/MacOS/FixtureApp" \
    "$ROOT/Tests/Fixtures/FixtureApp/main.swift"

cp /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns \
    "$OUT/Contents/Resources/AppIcon.icns"

cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.mikekuta.appduplicator.fixture</string>
    <key>CFBundleName</key><string>FixtureApp</string>
    <key>CFBundleDisplayName</key><string>FixtureApp</string>
    <key>CFBundleExecutable</key><string>FixtureApp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$OUT"
codesign --verify --strict "$OUT"

echo "$OUT"
