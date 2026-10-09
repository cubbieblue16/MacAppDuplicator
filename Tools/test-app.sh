#!/bin/bash
# Runs the MacAppDuplicatorTests bundle. Usage: Tools/test-app.sh [-only-testing:MacAppDuplicatorTests/SomeTests]
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
/usr/local/bin/xcodegen generate --spec App/project.yml --project App --quiet
swift build -c release --product Launcher
xcodebuild \
  -project App/MacAppDuplicator.xcodeproj \
  -scheme MacAppDuplicator \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  test "$@" 2>&1 | grep -E 'Test Suite|Test Case.*(passed|failed)|error:|\*\* TEST' || true
