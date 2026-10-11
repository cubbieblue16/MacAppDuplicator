#!/usr/bin/env bash
# Notarizes macOS App Duplicator (or any Developer ID signed .app, .dmg or .zip) with Apple's notary service.
# Usage: Tools/notarize.sh <path> [--profile NAME] [--dry-run]
# A .app is zipped into dist/ with ditto first (notarytool does not take bare bundles). The submission waits for
# Apple's verdict; on Accepted the original .app or .dmg is stapled and validated. Credentials come from a keychain
# profile created once with xcrun notarytool store-credentials; this script never takes an Apple ID or password.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: Tools/notarize.sh <path> [--profile NAME] [--dry-run]

Submits <path> (a .app, .dmg or .zip) to Apple's notary service and waits for the verdict.
A .app is zipped into dist/<name>.zip with ditto first (the zip is deleted again on exit).
On Accepted the original .app or .dmg is stapled and validated (a .zip cannot be stapled).

Options:
  --profile NAME   notarytool keychain profile to use (default: MAD-notary)
  --dry-run        print every command instead of running it; nothing is submitted or written
  --help           show this help

Create the keychain profile once (it asks for an app-specific password from appleid.apple.com):
  xcrun notarytool store-credentials MAD-notary --apple-id <your Apple ID> --team-id 4NQ2UVJ4EZ

Exit status: 0 notarized (or dry run), 1 a step failed or Apple did not accept the submission
(the notary log is saved to dist/notary-<id>.json), 64 usage error, 69 missing tool or keychain profile.
USAGE
}

usage_error() {
    echo "error: $1" >&2
    echo "Run Tools/notarize.sh --help for usage." >&2
    exit 64
}

# need_value <option> <value>: the value after an option must be present and must not look like an option.
need_value() {
    case "$2" in
        "" | -*) usage_error "$1 needs a value" ;;
    esac
}

REPO="$(cd "$(dirname "$0")/.." >/dev/null && pwd)"
CALLER_PWD="$PWD"

# abspath <path>: an absolute path for <path>, read relative to the directory the script was started from.
abspath() {
    case "$1" in
        /*) printf '%s\n' "${1%/}" ;;
        *) printf '%s\n' "$CALLER_PWD/${1%/}" ;;
    esac
}

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

TARGET=""
PROFILE="MAD-notary"
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --help | -h)
            usage
            exit 0
            ;;
        --profile)
            need_value "$1" "${2-}"
            PROFILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -*)
            usage_error "unknown option: $1"
            ;;
        *)
            if [ -n "$TARGET" ]; then
                usage_error "unexpected argument: $1"
            fi
            TARGET="$(abspath "$1")"
            shift
            ;;
    esac
done

if [ -z "$TARGET" ]; then
    usage_error "missing <path> (a .app, .dmg or .zip)"
fi
case "$TARGET" in
    *.app) KIND=app ;;
    *.dmg) KIND=dmg ;;
    *.zip) KIND=zip ;;
    *) usage_error "$TARGET must be a .app, .dmg or .zip" ;;
esac
if [ "$KIND" = "app" ]; then
    if [ ! -d "$TARGET" ]; then
        usage_error "no such file: $TARGET"
    fi
elif [ ! -f "$TARGET" ]; then
    usage_error "no such file: $TARGET"
fi

for tool in xcrun ditto plutil; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool not found (install the Xcode command line tools)" >&2
        exit 69
    fi
done
for tool in notarytool stapler; do
    if ! xcrun --find "$tool" >/dev/null 2>&1; then
        echo "error: xcrun cannot find $tool (install Xcode 26 or later and select it with xcode-select)" >&2
        exit 69
    fi
done

cd "$REPO"
NAME="$(basename "$TARGET")"
NAME="${NAME%.*}"
ZIP="dist/$NAME.zip"
if [ "$KIND" = "app" ]; then
    SUBMIT="$ZIP"
else
    SUBMIT="$TARGET"
fi

if [ "$DRY_RUN" = "1" ]; then
    show xcrun notarytool history --keychain-profile "$PROFILE"
    if [ "$KIND" = "app" ]; then
        show ditto -c -k --keepParent "$TARGET" "$ZIP"
    fi
    show xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait --output-format json
    if [ "$KIND" = "zip" ]; then
        echo "notarize: a .zip cannot be stapled; staple the .app or .dmg it contains after it is accepted"
    else
        show xcrun stapler staple "$TARGET"
        show xcrun stapler validate "$TARGET"
    fi
    exit 0
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    profile_hint
    exit 69
fi

mkdir -p dist
JSON=""
cleanup() {
    if [ -n "$JSON" ]; then
        rm -f "$JSON"
    fi
    if [ "$KIND" = "app" ]; then
        rm -f "$ZIP"
    fi
}
trap cleanup EXIT
TMPROOT="${TMPDIR:-/tmp}"
JSON="$(mktemp "${TMPROOT%/}/mad-notary.XXXXXX")"

if [ "$KIND" = "app" ]; then
    rm -f "$ZIP"
    echo "notarize: zipping $TARGET into $ZIP"
    if ! ditto -c -k --keepParent "$TARGET" "$ZIP"; then
        echo "error: ditto could not zip $TARGET" >&2
        exit 1
    fi
fi

echo "notarize: submitting $SUBMIT with profile $PROFILE and waiting for Apple's verdict (usually a few minutes)"
SUBMIT_RC=0
xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait --output-format json > "$JSON" || SUBMIT_RC=$?
ID="$(plutil -extract id raw -o - "$JSON" 2>/dev/null || true)"
STATUS="$(plutil -extract status raw -o - "$JSON" 2>/dev/null || true)"
case "$ID" in
    "" | *[!A-Za-z0-9-]*)
        echo "error: notarytool submit returned no submission id (exit $SUBMIT_RC)" >&2
        exit 1
        ;;
esac
echo "notarize: submission $ID status ${STATUS:-unknown}"
if [ "$STATUS" != "Accepted" ]; then
    LOG="dist/notary-$ID.json"
    if xcrun notarytool log "$ID" "$LOG" --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        echo "error: Apple did not accept the submission (status ${STATUS:-unknown}); the notary log is in $LOG" >&2
    else
        echo "error: Apple did not accept the submission (status ${STATUS:-unknown}); fetch the log with: xcrun notarytool log $ID --keychain-profile $PROFILE" >&2
    fi
    exit 1
fi

if [ "$KIND" = "zip" ]; then
    echo "notarize: accepted; a .zip cannot be stapled, so staple the .app or .dmg it contains"
    exit 0
fi
if ! xcrun stapler staple "$TARGET"; then
    echo "error: stapler could not staple $TARGET" >&2
    exit 1
fi
if ! xcrun stapler validate "$TARGET"; then
    echo "error: stapler validate failed for $TARGET" >&2
    exit 1
fi
echo "notarize: stapled and validated $TARGET"
