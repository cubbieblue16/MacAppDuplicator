#!/usr/bin/env bash
# Dock identity smoke check. Run from the repo root after `swift build -c release`
# and `Tools/build-fixture.sh`. Leaves one Dock tile on screen for 30 s so a human
# can verify that it reads "Smoke Tile" rather than "FixtureApp".
set -euo pipefail

for path in .build/release/madctl .build/release/Launcher .build/fixtures/FixtureApp.app; do
    if [ ! -e "$path" ]; then
        echo "missing: $path"
        exit 1
    fi
done

OUT=$(mktemp -d)
cleanup() {
    pkill -f 'FixtureApp.app/Contents/MacOS/FixtureApp' || true
    rm -rf "$OUT"
}
trap cleanup EXIT

.build/release/madctl new .build/fixtures/FixtureApp.app \
    --name "Smoke Tile" --data-mode disabled \
    --env MAD_FIXTURE_LIFETIME=30 --out "$OUT" >/dev/null

open "$OUT/Smoke Tile.app"
sleep 2

PID=$(pgrep -f 'FixtureApp.app/Contents/MacOS/FixtureApp' | head -1 || true)
if [ -z "$PID" ]; then
    echo "FAIL: no FixtureApp process found"
    exit 1
fi
ASN=$(lsappinfo find pid="$PID")
if lsappinfo info -only bundlepath "$ASN" | grep -q 'FixtureApp.app'; then
    echo "PASS: lsappinfo reports the target bundle"
else
    echo "FAIL: lsappinfo does not report the target bundle"
    exit 1
fi

echo 'LOOK NOW: the Dock tile should read "Smoke Tile" and show the generic application icon, not "FixtureApp"'
sleep 30
