#!/usr/bin/env bash
# Tests for the Phase 7 release scripts in Tools/. Usage: Tools/tests/release-scripts.sh
# Runs only bash -n, --help, usage errors, --dry-run, the missing-keychain-profile path and one real hdiutil create from
# a fake .app. Never submits anything to Apple, never staples, never pushes, never calls the real gh, and never touches
# ~/Applications, /Applications or the installed app. Everything it writes lives in one mktemp -d folder that is removed
# on exit (a disk image it mounted is detached first). Prints "ok <n> <check>" per check and "PASS <n> checks" at the
# end; stops with "FAIL <n> <check>" and exit 1 at the first failure.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." >/dev/null && pwd)"
cd "$REPO"

TMPROOT="${TMPDIR:-/tmp}"
T="$(mktemp -d "${TMPROOT%/}/mad-release-scripts.XXXXXX")"
MNT=""

cleanup() {
    if [ -n "$MNT" ]; then
        hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || hdiutil detach "$MNT" -force -quiet >/dev/null 2>&1 || true
    fi
    rm -rf "$T" || true
}
trap cleanup EXIT

N=0

ok() {
    N=$((N + 1))
    echo "ok $N $1"
}

fail() {
    echo "FAIL $((N + 1)) $1" >&2
    if [ -s "$T/out" ]; then
        echo "--- stdout of the last command (first 40 lines)" >&2
        head -n 40 "$T/out" >&2
    fi
    if [ -s "$T/err" ]; then
        echo "--- stderr of the last command (first 40 lines)" >&2
        head -n 40 "$T/err" >&2
    fi
    exit 1
}

# expect_exit <code> <label> <command...>: runs the command with stdout in $T/out and stderr in $T/err and checks its
# exit status.
expect_exit() {
    local want="$1" label="$2" got=0
    shift 2
    "$@" >"$T/out" 2>"$T/err" || got=$?
    if [ "$got" -ne "$want" ]; then
        fail "$label (exit $got, expected $want)"
    fi
    ok "$label"
}

# has / lacks <file> <text> <label>: fixed-string search in $T/<file> (out and err hold the last command's output).
has() {
    if grep -qF -- "$2" "$T/$1"; then
        ok "$3"
    else
        fail "$3 (no \"$2\" in $1)"
    fi
}

lacks() {
    if [ -f "$T/$1" ] && grep -qF -- "$2" "$T/$1"; then
        fail "$3 (unexpected \"$2\" in $1)"
    fi
    ok "$3"
}

# shown <arg>: one argument the way the scripts' dry-run lines print it (double-quoted when it holds a space or any
# character outside A-Za-z0-9_./:=@%+,-).
shown() {
    case "$1" in
        "" | *[!A-Za-z0-9_./:=@%+,-]*) printf '"%s"' "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

# git with a throwaway identity and no hooks or signing, for the temporary repositories only.
tgit() {
    git -c user.name="Release Test" -c user.email="release-test@example.invalid" -c commit.gpgsign=false \
        -c tag.gpgsign=false -c core.hooksPath=/dev/null -c init.defaultBranch=main "$@"
}

# --- Task 1: build-app.sh secure timestamp and no get-task-allow ---
expect_exit 0 "build-app.sh passes bash -n" bash -n Tools/build-app.sh
SIGN_LINE="$(grep -F '"CODE_SIGN_IDENTITY=$IDENTITY"' Tools/build-app.sh || true)"
case "$SIGN_LINE" in
    *'"OTHER_CODE_SIGN_FLAGS=--timestamp"'*) ok "build-app.sh adds --timestamp to identity builds" ;;
    *) fail "build-app.sh adds --timestamp to identity builds (line: $SIGN_LINE)" ;;
esac
case "$SIGN_LINE" in
    *'"CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO"'*) ok "build-app.sh stops Xcode injecting get-task-allow into identity builds" ;;
    *) fail "build-app.sh stops Xcode injecting get-task-allow into identity builds (line: $SIGN_LINE)" ;;
esac
TS_COUNT="$(grep -c 'OTHER_CODE_SIGN_FLAGS' Tools/build-app.sh || true)"
INJECT_COUNT="$(grep -c 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS' Tools/build-app.sh || true)"
if [ "$TS_COUNT" = "1" ] && [ "$INJECT_COUNT" = "1" ]; then
    ok "build-app.sh sets both overrides once, on the identity line only"
else
    fail "build-app.sh sets both overrides once, on the identity line only (found $TS_COUNT and $INJECT_COUNT)"
fi

# --- Task 2: notarize.sh ---
mkdir -p "$T/Fake.app/Contents/MacOS"
cat > "$T/Fake.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Fake</string>
    <key>CFBundleIdentifier</key>
    <string>com.mikekuta.MacAppDuplicator.release-test</string>
    <key>CFBundleName</key>
    <string>Fake</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
</dict>
</plist>
PLIST
printf '#!/bin/sh\nexit 0\n' > "$T/Fake.app/Contents/MacOS/Fake"
chmod 755 "$T/Fake.app/Contents/MacOS/Fake"
printf 'not a real disk image\n' > "$T/dummy.dmg"
printf 'not a real zip\n' > "$T/dummy.zip"
printf 'plain text\n' > "$T/notes.txt"

expect_exit 0 "notarize.sh passes bash -n" bash -n Tools/notarize.sh
if [ -x Tools/notarize.sh ]; then ok "notarize.sh is executable"; else fail "notarize.sh is executable"; fi
expect_exit 0 "notarize.sh --help exits 0" Tools/notarize.sh --help
has out "Usage: Tools/notarize.sh <path> [--profile NAME] [--dry-run]" "notarize.sh --help prints the usage line"
expect_exit 64 "notarize.sh without a path exits 64" Tools/notarize.sh
has err "error: missing <path>" "notarize.sh names the missing path"
expect_exit 64 "notarize.sh rejects a .txt path" Tools/notarize.sh "$T/notes.txt" --dry-run
has err "must be a .app, .dmg or .zip" "notarize.sh explains the accepted path types"
expect_exit 64 "notarize.sh rejects a missing file" Tools/notarize.sh "$T/missing.dmg" --dry-run
has err "no such file" "notarize.sh names the missing file"
expect_exit 64 "notarize.sh refuses an Apple ID option" Tools/notarize.sh "$T/Fake.app" --apple-id someone --dry-run
has err "unknown option: --apple-id" "notarize.sh reports the unknown option"
expect_exit 64 "notarize.sh needs a value after --profile" Tools/notarize.sh "$T/Fake.app" --profile
expect_exit 64 "notarize.sh takes one path only" Tools/notarize.sh "$T/Fake.app" "$T/dummy.dmg" --dry-run
expect_exit 69 "notarize.sh exits 69 when the keychain profile is missing" Tools/notarize.sh "$T/Fake.app" --profile MAD-notary-does-not-exist
has err "xcrun notarytool store-credentials MAD-notary-does-not-exist --apple-id <your Apple ID> --team-id 4NQ2UVJ4EZ" "missing profile prints the store-credentials command"
has err "app-specific password" "missing profile mentions the app-specific password"
expect_exit 0 "notarize.sh --dry-run on a .app exits 0" Tools/notarize.sh "$T/Fake.app" --dry-run
has out "dry-run: xcrun notarytool history --keychain-profile MAD-notary" "dry run checks the default profile"
has out "dry-run: ditto -c -k --keepParent $(shown "$T/Fake.app") dist/Fake.zip" "dry run zips the .app into dist/"
has out "dry-run: xcrun notarytool submit dist/Fake.zip --keychain-profile MAD-notary --wait --output-format json" "dry run submits the zip and waits"
has out "dry-run: xcrun stapler staple $(shown "$T/Fake.app")" "dry run staples the original .app"
has out "dry-run: xcrun stapler validate $(shown "$T/Fake.app")" "dry run validates the staple"
if [ -e dist/Fake.zip ]; then fail "dry run writes nothing"; else ok "dry run writes nothing"; fi
expect_exit 0 "notarize.sh --dry-run on a .dmg exits 0" Tools/notarize.sh "$T/dummy.dmg" --profile Other-profile --dry-run
has out "dry-run: xcrun notarytool submit $(shown "$T/dummy.dmg") --keychain-profile Other-profile --wait --output-format json" "dry run submits the .dmg itself with the chosen profile"
lacks out "ditto" "dry run does not zip a .dmg"
has out "dry-run: xcrun stapler staple $(shown "$T/dummy.dmg")" "dry run staples the .dmg"
expect_exit 0 "notarize.sh --dry-run on a .zip exits 0" Tools/notarize.sh "$T/dummy.zip" --dry-run
has out "dry-run: xcrun notarytool submit $(shown "$T/dummy.zip") --keychain-profile MAD-notary --wait --output-format json" "dry run submits the .zip as is"
lacks out "stapler" "dry run never staples a .zip"
# --- Task 3: make-dmg.sh ---
mkdir -p "$T/dmg" "$T/Empty.app/Contents"
expect_exit 0 "make-dmg.sh passes bash -n" bash -n Tools/make-dmg.sh
if [ -x Tools/make-dmg.sh ]; then ok "make-dmg.sh is executable"; else fail "make-dmg.sh is executable"; fi
expect_exit 0 "make-dmg.sh --help exits 0" Tools/make-dmg.sh --help
has out 'Usage: Tools/make-dmg.sh <app> [--output dist/<name>.dmg] [--identity "<display name>"] [--volname "<name>"]' "make-dmg.sh --help prints the usage line"
expect_exit 64 "make-dmg.sh without an app exits 64" Tools/make-dmg.sh
has err "error: missing <app>" "make-dmg.sh names the missing app"
expect_exit 64 "make-dmg.sh rejects a path that is not a .app" Tools/make-dmg.sh "$T/notes.txt" --output "$T/dmg/x.dmg"
expect_exit 64 "make-dmg.sh rejects a .app without Contents/Info.plist" Tools/make-dmg.sh "$T/Empty.app" --output "$T/dmg/x.dmg"
expect_exit 64 "make-dmg.sh wants an --output ending in .dmg" Tools/make-dmg.sh "$T/Fake.app" --output "$T/dmg/Fake.img"
expect_exit 64 "make-dmg.sh rejects an unknown option" Tools/make-dmg.sh "$T/Fake.app" --background "$T/notes.txt"
expect_exit 0 "make-dmg.sh builds a DMG from the fake app" Tools/make-dmg.sh "$T/Fake.app" --output "$T/dmg/Fake.dmg" --volname "Fake Test"
LAST="$(tail -n 1 "$T/out")"
if [ "$LAST" = "$T/dmg/Fake.dmg" ]; then ok "make-dmg.sh prints the DMG path last"; else fail "make-dmg.sh prints the DMG path last (got: $LAST)"; fi
expect_exit 0 "hdiutil verify accepts the DMG" hdiutil verify "$T/dmg/Fake.dmg"
expect_exit 0 "hdiutil imageinfo reads the DMG" hdiutil imageinfo "$T/dmg/Fake.dmg"
has out "Format: UDZO" "the DMG is UDZO (compressed, read-only)"
MNT="$(mktemp -d "$T/mnt.XXXXXX")"
expect_exit 0 "the DMG mounts read-only" hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$T/dmg/Fake.dmg"
if [ -f "$MNT/Fake.app/Contents/Info.plist" ]; then ok "the DMG holds Fake.app"; else fail "the DMG holds Fake.app"; fi
LINK="$(readlink "$MNT/Applications" || true)"
if [ "$LINK" = "/Applications" ]; then ok "the DMG has the Applications symlink"; else fail "the DMG has the Applications symlink (got: $LINK)"; fi
expect_exit 0 "diskutil reads the mounted volume" diskutil info "$MNT"
has out "Fake Test" "the volume is named by --volname"
# Spotlight can hold a fresh volume busy for a moment; a forced detach is the fallback.
if hdiutil detach "$MNT" >"$T/out" 2>"$T/err" || hdiutil detach "$MNT" -force >"$T/out" 2>"$T/err"; then
    ok "the DMG detaches"
else
    fail "the DMG detaches"
fi
MNT=""
mkdir -p "$T/mini/Tools" "$T/mini/App"
cp Tools/make-dmg.sh "$T/mini/Tools/make-dmg.sh"
printf 'settings:\n  base:\n    CURRENT_PROJECT_VERSION: "1"\n    MARKETING_VERSION: "9.8.7"\n' > "$T/mini/App/project.yml"
expect_exit 0 "make-dmg.sh without --output builds dist/macOS-App-Duplicator-<version>.dmg" "$T/mini/Tools/make-dmg.sh" "$T/Fake.app"
if [ -f "$T/mini/dist/macOS-App-Duplicator-9.8.7.dmg" ]; then ok "the default DMG name carries MARKETING_VERSION"; else fail "the default DMG name carries MARKETING_VERSION"; fi
LAST="$(tail -n 1 "$T/out")"
if [ "$LAST" = "$T/mini/dist/macOS-App-Duplicator-9.8.7.dmg" ]; then ok "the default DMG path is printed last"; else fail "the default DMG path is printed last (got: $LAST)"; fi
# --- Task 4: release.sh and publish-release.sh ---
TEST_ID="Developer ID Application: Release Test (TEAM000000)"
# Stand-ins that log their call and fail: a dry run must never build, sign, notarize or touch a disk image. The xcrun
# stand-in has its own folder because the missing-profile check needs the real xcrun.
mkdir -p "$T/trap" "$T/trap-xcrun"
for tool in xcodegen xcodebuild swift hdiutil codesign spctl ditto; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/trap.log"\nexit 1\n' "$tool" "$T" > "$T/trap/$tool"
    chmod 755 "$T/trap/$tool"
done
printf '#!/bin/sh\necho "xcrun $*" >> "%s/trap.log"\nexit 1\n' "$T" > "$T/trap-xcrun/xcrun"
chmod 755 "$T/trap-xcrun/xcrun"
TRAP_PATH="$T/trap-xcrun:$T/trap:$PATH"
expect_exit 0 "release.sh passes bash -n" bash -n Tools/release.sh
if [ -x Tools/release.sh ]; then ok "release.sh is executable"; else fail "release.sh is executable"; fi
expect_exit 0 "release.sh --help exits 0" Tools/release.sh --help
has out 'Usage: Tools/release.sh --identity "Developer ID Application: <name> (<team>)" [--profile NAME] [--skip-notarize] [--allow-dirty] [--dry-run]' "release.sh --help prints the usage line"
expect_exit 64 "release.sh without --identity exits 64" Tools/release.sh --dry-run
has err "--identity is required" "release.sh asks for --identity"
expect_exit 64 "release.sh refuses an identity that is not Developer ID Application" Tools/release.sh --identity "Apple Development: Release Test (TEAM000000)" --dry-run
expect_exit 64 "release.sh rejects an unknown option" Tools/release.sh --identity "$TEST_ID" --notary-password x --dry-run
V="$(grep -E 'MARKETING_VERSION:' App/project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
REL_APP="$REPO/.build/DerivedData/Build/Products/Release/macOS App Duplicator.app"
expect_exit 0 "release.sh --dry-run exits 0" env PATH="$TRAP_PATH" Tools/release.sh --identity "$TEST_ID" --allow-dirty --dry-run
has out "release: macOS App Duplicator $V (" "dry run reports the version from App/project.yml"
has out "dry-run: xcrun notarytool history --keychain-profile MAD-notary" "dry run checks the notary profile first"
has out "dry-run: Tools/build-app.sh --identity $(shown "$TEST_ID") --configuration Release" "dry run builds Release with the identity"
has out "dry-run: codesign --verify --deep --strict --verbose=2 $(shown "$REL_APP")" "dry run verifies the signature"
has out "Timestamp=" "dry run checks the secure timestamps"
has out "dry-run: Tools/notarize.sh $(shown "$REL_APP") --profile MAD-notary" "dry run notarizes the app"
has out "dry-run: Tools/make-dmg.sh $(shown "$REL_APP") --identity $(shown "$TEST_ID") --output dist/macOS-App-Duplicator-$V.dmg" "dry run builds the signed DMG"
has out "dry-run: Tools/notarize.sh dist/macOS-App-Duplicator-$V.dmg --profile MAD-notary" "dry run notarizes the DMG"
has out "dry-run: spctl --assess --type open --context context:primary-signature -v dist/macOS-App-Duplicator-$V.dmg" "dry run asks Gatekeeper about the DMG"
has out "SHA256SUMS" "dry run writes dist/SHA256SUMS"
if [ -e "$T/trap.log" ]; then fail "dry run runs no build, signing, notary or disk-image tool"; else ok "dry run runs no build, signing, notary or disk-image tool"; fi
expect_exit 0 "release.sh --skip-notarize --dry-run exits 0" env PATH="$TRAP_PATH" Tools/release.sh --identity "$TEST_ID" --allow-dirty --skip-notarize --dry-run
lacks out "notarytool" "--skip-notarize never calls notarytool"
lacks out "Tools/notarize.sh" "--skip-notarize never calls notarize.sh"
has out "spctl --assess --type execute" "--skip-notarize still prints the Gatekeeper checks"
expect_exit 69 "release.sh exits 69 before building when the profile is missing" env PATH="$T/trap:$PATH" Tools/release.sh --identity "$TEST_ID" --allow-dirty --profile MAD-notary-does-not-exist
has err "xcrun notarytool store-credentials MAD-notary-does-not-exist --apple-id <your Apple ID> --team-id 4NQ2UVJ4EZ" "release.sh prints the store-credentials command"
if [ -e "$T/trap.log" ]; then fail "release.sh builds nothing without a profile"; else ok "release.sh builds nothing without a profile"; fi
mkdir -p "$T/rel/Tools" "$T/rel/App"
cp Tools/release.sh "$T/rel/Tools/release.sh"
printf 'settings:\n  base:\n    CURRENT_PROJECT_VERSION: "42"\n    MARKETING_VERSION: "9.8.7"\n' > "$T/rel/App/project.yml"
tgit -C "$T/rel" init -q
tgit -C "$T/rel" add Tools/release.sh App/project.yml
tgit -C "$T/rel" commit -q -m "release test fixture"
printf 'dirty\n' > "$T/rel/dirty-file"
expect_exit 1 "release.sh refuses a dirty tree" env PATH="$TRAP_PATH" "$T/rel/Tools/release.sh" --identity "$TEST_ID" --dry-run
has err "uncommitted changes" "release.sh names the problem"
has err "--allow-dirty" "release.sh names the override"
rm -f "$T/rel/dirty-file"
expect_exit 0 "release.sh accepts a clean tree" env PATH="$TRAP_PATH" "$T/rel/Tools/release.sh" --identity "$TEST_ID" --dry-run
has out "release: macOS App Duplicator 9.8.7 (42)" "release.sh reads both version keys"
expect_exit 0 "publish-release.sh passes bash -n" bash -n Tools/publish-release.sh
if [ -x Tools/publish-release.sh ]; then ok "publish-release.sh is executable"; else fail "publish-release.sh is executable"; fi
expect_exit 0 "publish-release.sh --help exits 0" Tools/publish-release.sh --help
has out 'Usage: Tools/publish-release.sh <tag> <dmg> --notes <file> [--title "<title>"] [--dry-run]' "publish-release.sh --help prints the usage line"
expect_exit 64 "publish-release.sh without arguments exits 64" Tools/publish-release.sh
expect_exit 64 "publish-release.sh requires --notes" Tools/publish-release.sh v9.9.9 "$T/dummy.dmg" --dry-run
expect_exit 64 "publish-release.sh rejects a missing DMG" Tools/publish-release.sh v9.9.9 "$T/missing.dmg" --notes "$T/notes.txt" --dry-run
expect_exit 64 "publish-release.sh rejects a malformed tag" Tools/publish-release.sh 'v9 9' "$T/dummy.dmg" --notes "$T/notes.txt" --dry-run
# Stand-in gh scripts: gh-out answers "not logged in", gh-in answers "logged in"; both only log their arguments.
mkdir -p "$T/gh-out" "$T/gh-in"
printf '#!/bin/sh\necho "$*" >> "%s/gh.log"\nexit 1\n' "$T" > "$T/gh-out/gh"
printf '#!/bin/sh\necho "$*" >> "%s/gh.log"\nexit 0\n' "$T" > "$T/gh-in/gh"
chmod 755 "$T/gh-out/gh" "$T/gh-in/gh"
expect_exit 69 "publish-release.sh exits 69 when gh is not logged in" env PATH="$T/gh-out:$PATH" Tools/publish-release.sh v0.6.0 "$T/dummy.dmg" --notes "$T/notes.txt" --dry-run
has err "gh auth login" "publish-release.sh says how to log in"
expect_exit 64 "publish-release.sh refuses a tag that does not exist" env PATH="$T/gh-in:$PATH" Tools/publish-release.sh v0.0.0-missing "$T/dummy.dmg" --notes "$T/notes.txt" --dry-run
has err "does not exist" "publish-release.sh names the missing tag"
expect_exit 64 "publish-release.sh refuses a tag that is not at HEAD" env PATH="$T/gh-in:$PATH" Tools/publish-release.sh v0.6.0 "$T/dummy.dmg" --notes "$T/notes.txt" --dry-run
has err "not at HEAD" "publish-release.sh explains the tag mismatch"
mkdir -p "$T/pub/Tools"
cp Tools/publish-release.sh "$T/pub/Tools/publish-release.sh"
printf '/dist/\n' > "$T/pub/.gitignore"
tgit -C "$T/pub" init -q
tgit -C "$T/pub" add .gitignore Tools/publish-release.sh
tgit -C "$T/pub" commit -q -m "publish test fixture"
tgit -C "$T/pub" tag -a v9.9.9 -m "v9.9.9"
printf 'First notarized release.\n' > "$T/notes.md"
SUM="$(cd "$T" >/dev/null && shasum -a 256 dummy.dmg)"
rm -f "$T/gh.log"
expect_exit 0 "publish-release.sh --dry-run exits 0 for a tag at HEAD" env PATH="$T/gh-in:$PATH" "$T/pub/Tools/publish-release.sh" v9.9.9 "$T/dummy.dmg" --notes "$T/notes.md" --dry-run
has out "dry-run: git push origin v9.9.9" "dry run pushes the tag"
has out "dry-run: gh release create v9.9.9 $(shown "$T/dummy.dmg") --title v9.9.9 --notes-file $(shown "$T/pub/dist/release-notes-v9.9.9.md") --verify-tag" "dry run creates the release from the pushed tag with the DMG and the notes copy"
has out "nothing was pushed or published" "dry run says nothing was published"
if [ -f "$T/pub/dist/release-notes-v9.9.9.md" ]; then ok "dry run writes the notes copy into dist/"; else fail "dry run writes the notes copy into dist/"; fi
has pub/dist/release-notes-v9.9.9.md "First notarized release." "the notes copy keeps the notes"
has pub/dist/release-notes-v9.9.9.md "## SHA-256" "the notes copy gains a SHA-256 section"
has pub/dist/release-notes-v9.9.9.md "$SUM" "the SHA-256 section holds shasum -a 256 of the DMG"
has gh.log "auth status" "publish-release.sh checks gh auth status"
lacks gh.log "release create" "dry run never calls gh release create"

echo "PASS $N checks"
