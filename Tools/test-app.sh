#!/bin/bash
# Runs the MacAppDuplicatorTests bundle. Usage: Tools/test-app.sh [-only-testing:MacAppDuplicatorTests/SomeTests]
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
# Homebrew installs xcodegen in /usr/local/bin on Intel and /opt/homebrew/bin on Apple Silicon.
XCODEGEN="$(command -v xcodegen || true)"
if [ -z "$XCODEGEN" ]; then
  for candidate in /usr/local/bin/xcodegen /opt/homebrew/bin/xcodegen; do
    if [ -x "$candidate" ]; then XCODEGEN="$candidate"; break; fi
  done
fi
if [ -z "$XCODEGEN" ]; then
  echo "error: xcodegen not found on PATH, in /usr/local/bin or in /opt/homebrew/bin; install it with 'brew install xcodegen'" >&2
  exit 69
fi
"$XCODEGEN" generate --spec App/project.yml --project App --quiet
swift build -c release --product Launcher
xcodebuild \
  -project App/MacAppDuplicator.xcodeproj \
  -scheme MacAppDuplicator \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  test "$@" 2>&1 | { grep -E 'Test Suite|Test Case.*(passed|failed)|error:|\.swift:[0-9]+:[0-9]+: warning:|\*\* TEST' || true; }
