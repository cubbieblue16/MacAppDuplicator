#!/usr/bin/env bash
# Builds, signs, notarizes and packages a macOS App Duplicator release into dist/.
# Usage: Tools/release.sh --identity "Developer ID Application: <name> (<team>)" [--profile NAME] [--skip-notarize] [--allow-dirty] [--dry-run]
# Order: clean-tree check, version, Release build with the identity (secure timestamps, no get-task-allow), signature
# checks, notarize + staple the app, signed DMG, notarize + staple the DMG, Gatekeeper verdicts, dist/SHA256SUMS.
# Never installs anything, never touches ~/Applications or /Applications, never pushes or tags.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: Tools/release.sh --identity "Developer ID Application: <name> (<team>)" [--profile NAME] [--skip-notarize] [--allow-dirty] [--dry-run]

Builds the Release configuration with the Developer ID identity, checks every signature for a
secure timestamp and no get-task-allow entitlement, notarizes and staples the app, builds the
signed DMG with Tools/make-dmg.sh, notarizes and staples the DMG, prints the Gatekeeper
verdicts and writes dist/SHA256SUMS. Output: dist/macOS-App-Duplicator-<version>.dmg.

Options:
  --identity NAME   codesign identity, "Developer ID Application: <name> (<team>)" (required)
  --profile NAME    notarytool keychain profile (default: MAD-notary)
  --skip-notarize   build and package without notarizing; Gatekeeper rejects the result,
                    which is reported but does not fail the run
  --allow-dirty     build even if the working tree has uncommitted changes
  --dry-run         print every step instead of running it; builds nothing, writes nothing
  --help            show this help

Create the keychain profile once:
  xcrun notarytool store-credentials MAD-notary --apple-id <your Apple ID> --team-id 4NQ2UVJ4EZ

Exit status: 0 released into dist/ (or dry run), 1 a step failed, 64 usage error,
69 missing tool or keychain profile.
USAGE
}

usage_error() {
    echo "error: $1" >&2
    echo "Run Tools/release.sh --help for usage." >&2
    exit 64
}

# need_value <option> <value>: the value after an option must be present and must not look like an option.
need_value() {
    case "$2" in
        "" | -*) usage_error "$1 needs a value" ;;
    esac
}

REPO="$(cd "$(dirname "$0")/.." >/dev/null && pwd)"

# Prints a command the way --dry-run reports it: one line, arguments with spaces or shell metacharacters double-quoted.
show() {
    local out="dry-run:" arg
    for arg in "$@"; do
        case "$arg" in
            "" | *[!A-Za-z0-9_./:=@%+,-]*) out="$out \"$arg\"" ;;
            *) out="$out $arg" ;;
        esac
    done
    printf '%s\n' "$out"
}

profile_hint() {
    echo "error: notarytool could not use the keychain profile \"$PROFILE\": it is missing, its credentials no longer work, or Apple's notary service is unreachable." >&2
    echo "Create it once with:" >&2
    echo "  xcrun notarytool store-credentials $PROFILE --apple-id <your Apple ID> --team-id 4NQ2UVJ4EZ" >&2
    echo "and then enter an app-specific password from appleid.apple.com at the prompt." >&2
}

IDENTITY=""
PROFILE="MAD-notary"
SKIP_NOTARIZE=0
ALLOW_DIRTY=0
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --help | -h)
            usage
            exit 0
            ;;
        --identity)
            need_value "$1" "${2-}"
            IDENTITY="$2"
            shift 2
            ;;
        --profile)
            need_value "$1" "${2-}"
            PROFILE="$2"
            shift 2
            ;;
        --skip-notarize)
            SKIP_NOTARIZE=1
            shift
            ;;
        --allow-dirty)
            ALLOW_DIRTY=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        *)
            usage_error "unknown argument: $1"
            ;;
    esac
done

if [ -z "$IDENTITY" ]; then
    usage_error "--identity is required, for example --identity \"Developer ID Application: <name> (<team>)\""
fi
case "$IDENTITY" in
    "Developer ID Application: "*) ;;
    *) usage_error "--identity must be a Developer ID Application identity (notarization rejects other certificates)" ;;
esac

for tool in git codesign spctl shasum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool not found" >&2
        exit 69
    fi
done
cd "$REPO"

if ! STATUS="$(git status --porcelain)"; then
    echo "error: git status failed; run Tools/release.sh from a clone of the repository" >&2
    exit 1
fi
if [ -n "$STATUS" ]; then
    if [ "$ALLOW_DIRTY" = "1" ]; then
        echo "warning: --allow-dirty: building with uncommitted changes" >&2
    else
        echo "error: the working tree has uncommitted changes; commit them first or pass --allow-dirty:" >&2
        printf '%s\n' "$STATUS" >&2
        exit 1
    fi
fi

VERSION="$(grep -E 'MARKETING_VERSION:' App/project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
case "$VERSION" in
    "" | *[!0-9.]*)
        echo "error: could not read MARKETING_VERSION from App/project.yml (got \"$VERSION\")" >&2
        exit 1
        ;;
esac
BUILD="$(grep -E 'CURRENT_PROJECT_VERSION:' App/project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
case "$BUILD" in
    "" | *[!0-9]*)
        echo "error: could not read CURRENT_PROJECT_VERSION from App/project.yml (got \"$BUILD\")" >&2
        exit 1
        ;;
esac
echo "release: macOS App Duplicator $VERSION ($BUILD)"

APP="$REPO/.build/DerivedData/Build/Products/Release/macOS App Duplicator.app"
DMG_NAME="macOS-App-Duplicator-$VERSION.dmg"
DMG="dist/$DMG_NAME"

if [ "$DRY_RUN" = "1" ]; then
    if [ "$SKIP_NOTARIZE" = "0" ]; then
        show xcrun notarytool history --keychain-profile "$PROFILE"
    fi
    show Tools/build-app.sh --identity "$IDENTITY" --configuration Release
    show codesign --verify --deep --strict --verbose=2 "$APP"
    echo "dry-run: check one Timestamp= line and no get-task-allow entitlement in: $APP, Contents/Resources/Launcher, Contents/Resources/WebShell"
    if [ "$SKIP_NOTARIZE" = "0" ]; then
        show Tools/notarize.sh "$APP" --profile "$PROFILE"
    else
        echo "dry-run: skip notarizing the app (--skip-notarize)"
    fi
    show Tools/make-dmg.sh "$APP" --identity "$IDENTITY" --output "$DMG"
    if [ "$SKIP_NOTARIZE" = "0" ]; then
        show Tools/notarize.sh "$DMG" --profile "$PROFILE"
    else
        echo "dry-run: skip notarizing the DMG (--skip-notarize)"
    fi
    show spctl --assess --type execute -v "$APP"
    show spctl --assess --type open --context context:primary-signature -v "$DMG"
    echo "dry-run: (cd dist && shasum -a 256 $DMG_NAME > SHA256SUMS)"
    exit 0
fi

# Fail in seconds, not after a multi-minute build, when the keychain profile is missing or no longer works.
if [ "$SKIP_NOTARIZE" = "0" ]; then
    if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find notarytool >/dev/null 2>&1; then
        echo "error: xcrun notarytool not found (install Xcode 26 or later)" >&2
        exit 69
    fi
    echo "release: checking the notarytool keychain profile $PROFILE"
    if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        profile_hint
        exit 69
    fi
fi

mkdir -p dist
BUILD_LOG=""
cleanup() {
    if [ -n "$BUILD_LOG" ]; then
        rm -f "$BUILD_LOG"
    fi
}
trap cleanup EXIT
TMPROOT="${TMPDIR:-/tmp}"
BUILD_LOG="$(mktemp "${TMPROOT%/}/mad-release-build.XXXXXX")"

echo "release: building the Release configuration (a few minutes)"
if ! Tools/build-app.sh --identity "$IDENTITY" --configuration Release | tee "$BUILD_LOG"; then
    echo "error: Tools/build-app.sh failed" >&2
    exit 1
fi
BUILT="$(tail -n 1 "$BUILD_LOG")"
if [ ! -d "$BUILT" ]; then
    echo "error: Tools/build-app.sh did not print the app path (last line: $BUILT)" >&2
    exit 1
fi
APP="$BUILT"

echo "release: verifying the signature"
if ! codesign --verify --deep --strict --verbose=2 "$APP"; then
    echo "error: codesign --verify failed for $APP" >&2
    exit 1
fi

# check_signature <path> <label>: notarization needs a secure timestamp on every signature and no get-task-allow
# entitlement; codesign -dvv prints "Timestamp=" for a secure timestamp and "Signed Time=" for a local clock time.
check_signature() {
    local path="$1" label="$2" info count entitlements
    info="$(codesign -dvv "$path" 2>&1 || true)"
    count="$(printf '%s\n' "$info" | grep -c '^Timestamp=' || true)"
    if [ "$count" != "1" ]; then
        echo "error: $label has no secure timestamp (codesign -dvv shows no Timestamp= line); notarization would reject it" >&2
        exit 1
    fi
    echo "release: secure timestamp ok: $label"
    entitlements="$(codesign -d --entitlements - "$path" 2>&1 || true)"
    case "$entitlements" in
        *get-task-allow*)
            echo "error: $label carries the com.apple.security.get-task-allow entitlement; notarization would reject it" >&2
            exit 1
            ;;
    esac
    echo "release: no get-task-allow entitlement: $label"
}
check_signature "$APP" "macOS App Duplicator.app"
check_signature "$APP/Contents/Resources/Launcher" "Contents/Resources/Launcher"
check_signature "$APP/Contents/Resources/WebShell" "Contents/Resources/WebShell"

if [ "$SKIP_NOTARIZE" = "1" ]; then
    echo "warning: --skip-notarize: the app is not notarized, so Gatekeeper will reject it" >&2
elif ! Tools/notarize.sh "$APP" --profile "$PROFILE"; then
    echo "error: notarizing the app failed" >&2
    exit 1
fi

echo "release: building $DMG"
if ! Tools/make-dmg.sh "$APP" --identity "$IDENTITY" --output "$DMG"; then
    echo "error: Tools/make-dmg.sh failed" >&2
    exit 1
fi

if [ "$SKIP_NOTARIZE" = "1" ]; then
    echo "warning: --skip-notarize: the DMG is not notarized, so Gatekeeper will reject it" >&2
elif ! Tools/notarize.sh "$DMG" --profile "$PROFILE"; then
    echo "error: notarizing the DMG failed" >&2
    exit 1
fi

APP_RC=0
APP_VERDICT="$(spctl --assess --type execute -v "$APP" 2>&1)" || APP_RC=$?
DMG_RC=0
DMG_VERDICT="$(spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1)" || DMG_RC=$?
echo "release: Gatekeeper verdicts:"
printf '%s\n' "$APP_VERDICT" "$DMG_VERDICT" | sed 's/^/  /'
if [ "$SKIP_NOTARIZE" = "0" ] && { [ "$APP_RC" -ne 0 ] || [ "$DMG_RC" -ne 0 ]; }; then
    echo "error: Gatekeeper rejected the notarized build" >&2
    exit 1
fi

# The checksum line names the DMG by its basename, so "cd dist && shasum -a 256 -c SHA256SUMS" checks it.
if ! (cd "$REPO/dist" >/dev/null && shasum -a 256 "$DMG_NAME" > SHA256SUMS); then
    echo "error: could not write dist/SHA256SUMS" >&2
    exit 1
fi
echo "release: dist/SHA256SUMS"
cat dist/SHA256SUMS
echo "release: done: $DMG"
