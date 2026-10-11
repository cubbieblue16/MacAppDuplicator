#!/usr/bin/env bash
# Builds a compressed, read-only DMG holding an app and an Applications shortcut for drag-to-install.
# Usage: Tools/make-dmg.sh <app> [--output dist/<name>.dmg] [--identity "<display name>"] [--volname "<name>"]
# Stages the app with ditto in a mktemp -d folder next to an /Applications symlink, builds a UDZO image with hdiutil,
# signs it when --identity is given and always ends with hdiutil verify. Prints the DMG path as its last line.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: Tools/make-dmg.sh <app> [--output dist/<name>.dmg] [--identity "<display name>"] [--volname "<name>"]

Builds a compressed, read-only (UDZO) disk image holding <app> and an Applications shortcut,
so the app installs by dragging it onto the shortcut.

Options:
  --output PATH      where to write the DMG (default: dist/macOS-App-Duplicator-<MARKETING_VERSION>.dmg,
                     version read from App/project.yml); must end in .dmg
  --identity NAME    codesign the DMG with this identity, for example
                     "Developer ID Application: <name> (<team>)", with a secure timestamp
  --volname NAME     volume name shown in Finder (default: macOS App Duplicator)
  --help             show this help

Prints the DMG path as the last line. Exit status: 0 built and verified, 1 a step failed,
64 usage error, 69 missing tool.
USAGE
}

usage_error() {
    echo "error: $1" >&2
    echo "Run Tools/make-dmg.sh --help for usage." >&2
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

APP=""
OUT=""
IDENTITY=""
VOLNAME="macOS App Duplicator"
while [ $# -gt 0 ]; do
    case "$1" in
        --help | -h)
            usage
            exit 0
            ;;
        --output)
            need_value "$1" "${2-}"
            OUT="$(abspath "$2")"
            shift 2
            ;;
        --identity)
            need_value "$1" "${2-}"
            IDENTITY="$2"
            shift 2
            ;;
        --volname)
            need_value "$1" "${2-}"
            VOLNAME="$2"
            shift 2
            ;;
        -*)
            usage_error "unknown option: $1"
            ;;
        *)
            if [ -n "$APP" ]; then
                usage_error "unexpected argument: $1"
            fi
            APP="$(abspath "$1")"
            shift
            ;;
    esac
done

if [ -z "$APP" ]; then
    usage_error "missing <app> (a .app bundle)"
fi
case "$APP" in
    *.app) ;;
    *) usage_error "$APP is not a .app bundle" ;;
esac
if [ ! -d "$APP" ]; then
    usage_error "no such app: $APP"
fi
if [ ! -f "$APP/Contents/Info.plist" ]; then
    usage_error "$APP has no Contents/Info.plist"
fi
if [ -n "$OUT" ]; then
    case "$OUT" in
        *.dmg) ;;
        *) usage_error "--output must end in .dmg: $OUT" ;;
    esac
fi

TOOLS="hdiutil ditto"
if [ -n "$IDENTITY" ]; then
    TOOLS="$TOOLS codesign"
fi
for tool in $TOOLS; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool not found" >&2
        exit 69
    fi
done

cd "$REPO"
if [ -z "$OUT" ]; then
    VERSION="$(grep -E 'MARKETING_VERSION:' App/project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
    case "$VERSION" in
        "" | *[!0-9.]*)
            echo "error: could not read MARKETING_VERSION from App/project.yml (got \"$VERSION\")" >&2
            exit 1
            ;;
    esac
    OUT="$REPO/dist/macOS-App-Duplicator-$VERSION.dmg"
fi
if ! mkdir -p "$(dirname "$OUT")"; then
    echo "error: could not create the folder for $OUT" >&2
    exit 1
fi

STAGE=""
cleanup() {
    if [ -n "$STAGE" ]; then
        rm -rf "$STAGE"
    fi
}
trap cleanup EXIT
TMPROOT="${TMPDIR:-/tmp}"
STAGE="$(mktemp -d "${TMPROOT%/}/mad-dmg.XXXXXX")"
APP_NAME="$(basename "$APP")"

echo "make-dmg: staging $APP_NAME"
if ! ditto "$APP" "$STAGE/$APP_NAME"; then
    echo "error: ditto could not copy $APP" >&2
    exit 1
fi
ln -s /Applications "$STAGE/Applications"

echo "make-dmg: building $OUT"
if ! hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$OUT"; then
    echo "error: hdiutil create failed for $OUT" >&2
    exit 1
fi

if [ -n "$IDENTITY" ]; then
    echo "make-dmg: signing the DMG as $IDENTITY"
    if ! codesign --force --sign "$IDENTITY" --timestamp "$OUT"; then
        echo "error: codesign could not sign $OUT" >&2
        exit 1
    fi
    if ! codesign --verify --verbose=2 "$OUT"; then
        echo "error: codesign --verify failed for $OUT" >&2
        exit 1
    fi
fi

echo "make-dmg: verifying $OUT"
if ! hdiutil verify "$OUT"; then
    echo "error: hdiutil verify failed for $OUT" >&2
    exit 1
fi
echo "$OUT"
