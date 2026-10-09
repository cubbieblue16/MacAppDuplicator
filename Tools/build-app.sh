#!/bin/bash
# Builds macOS App Duplicator.app. Usage: Tools/build-app.sh [--identity "Developer ID Application: ..."] [--configuration Debug|Release]
# Without --identity the app and the embedded Launcher are ad hoc signed.
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
/usr/local/bin/xcodegen generate --spec App/project.yml --project App --quiet
swift build -c release --product Launcher

ARGS=(
  -project App/MacAppDuplicator.xcodeproj
  -scheme MacAppDuplicator
  -configuration "$CONFIG"
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath .build/DerivedData
)
if [ -n "$IDENTITY" ]; then
  ARGS+=("CODE_SIGN_IDENTITY=$IDENTITY" "DEVELOPMENT_TEAM=4NQ2UVJ4EZ")
fi
xcodebuild "${ARGS[@]}" build | grep -E '^(\*\* BUILD|error:|warning: .*\.swift)' || true

APP="$REPO/.build/DerivedData/Build/Products/$CONFIG/macOS App Duplicator.app"
test -d "$APP"
echo "$APP"
