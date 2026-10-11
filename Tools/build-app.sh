#!/bin/bash
# Builds macOS App Duplicator.app. Usage: Tools/build-app.sh [--identity "Developer ID Application: ..."] [--configuration Debug|Release]
# Without --identity the app and the embedded Launcher and WebShell are ad hoc signed. With --identity every signature
# carries a secure timestamp and the app has no get-task-allow entitlement, as notarization requires.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY=""
CONFIG="Debug"
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --configuration) CONFIG="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

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
swift build -c release --product WebShell

ARGS=(
  -project App/MacAppDuplicator.xcodeproj
  -scheme MacAppDuplicator
  -configuration "$CONFIG"
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath .build/DerivedData
)
if [ -n "$IDENTITY" ]; then
  # Notarization rejects a signature without a secure timestamp and a hardened app that allows debugging; Xcode's
  # build action signs with --timestamp=none and injects get-task-allow unless these two settings say otherwise.
  ARGS+=("CODE_SIGN_IDENTITY=$IDENTITY" "DEVELOPMENT_TEAM=4NQ2UVJ4EZ" "OTHER_CODE_SIGN_FLAGS=--timestamp" "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO")
fi
xcodebuild "${ARGS[@]}" build | { grep -E '^(\*\* BUILD|error:|warning: .*\.swift|.*\.swift:[0-9]+:[0-9]+: (error|warning):)' || true; }

APP="$REPO/.build/DerivedData/Build/Products/$CONFIG/macOS App Duplicator.app"
test -d "$APP"
echo "$APP"
