#!/usr/bin/env bash
# Publishes a release DMG on GitHub Releases for an existing tag at HEAD.
# Usage: Tools/publish-release.sh <tag> <dmg> --notes <file> [--title "<title>"] [--dry-run]
# Checks gh is logged in, the tag exists and points at HEAD, and the tree is clean; pushes the tag; writes a copy of the
# notes with a SHA-256 section into dist/; creates the release with the DMG attached. Never creates the tag itself.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: Tools/publish-release.sh <tag> <dmg> --notes <file> [--title "<title>"] [--dry-run]

Publishes <dmg> as a GitHub release for <tag>. The tag must already exist and point at HEAD
(create it on the release commit with git tag -a <tag> -m <tag>); this script never creates it.
Pushes the tag, copies the notes to dist/release-notes-<tag>.md with a "## SHA-256" section
holding shasum -a 256 of the DMG, then runs gh release create with the DMG attached.

Options:
  --notes FILE      release notes (Markdown); required
  --title TITLE     release title (default: the tag)
  --dry-run         check everything and write the notes copy, but print the push and gh
                    commands instead of running them
  --help            show this help

Exit status: 0 published (or dry run), 1 a step failed, 64 usage error or a tag that is
missing or not at HEAD, 69 missing tool or gh not logged in.
USAGE
}

usage_error() {
    echo "error: $1" >&2
    echo "Run Tools/publish-release.sh --help for usage." >&2
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

# run <command...>: runs the command, or only prints it under --dry-run.
run() {
    if [ "$DRY_RUN" = "1" ]; then
        show "$@"
    else
        "$@"
    fi
}

TAG=""
DMG=""
NOTES=""
TITLE=""
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --help | -h)
            usage
            exit 0
            ;;
        --notes)
            need_value "$1" "${2-}"
            NOTES="$(abspath "$2")"
            shift 2
            ;;
        --title)
            need_value "$1" "${2-}"
            TITLE="$2"
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
            if [ -z "$TAG" ]; then
                TAG="$1"
            elif [ -z "$DMG" ]; then
                DMG="$(abspath "$1")"
            else
                usage_error "unexpected argument: $1"
            fi
            shift
            ;;
    esac
done

if [ -z "$TAG" ]; then
    usage_error "missing <tag>"
fi
if [ -z "$DMG" ]; then
    usage_error "missing <dmg>"
fi
if [ -z "$NOTES" ]; then
    usage_error "--notes is required"
fi
case "$TAG" in
    -* | *[!A-Za-z0-9._-]*) usage_error "tag must use letters, digits, dots, dashes and underscores only: $TAG" ;;
esac
case "$DMG" in
    *.dmg) ;;
    *) usage_error "<dmg> must be a .dmg file: $DMG" ;;
esac
if [ ! -f "$DMG" ]; then
    usage_error "no such file: $DMG"
fi
if [ ! -f "$NOTES" ]; then
    usage_error "no such notes file: $NOTES"
fi
if [ -z "$TITLE" ]; then
    TITLE="$TAG"
fi

for tool in git shasum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool not found" >&2
        exit 69
    fi
done
if ! command -v gh >/dev/null 2>&1; then
    echo "error: gh not found (install it with: brew install gh)" >&2
    exit 69
fi
cd "$REPO"

if ! gh auth status >/dev/null 2>&1; then
    echo "error: gh is not logged in to GitHub; run: gh auth login" >&2
    exit 69
fi
if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "error: tag $TAG does not exist; create it on the release commit first: git tag -a $TAG -m \"$TAG\"" >&2
    exit 64
fi
# An annotated tag names a tag object; ^{commit} peels it to the commit it points at.
TAG_COMMIT="$(git rev-parse "$TAG^{commit}")"
HEAD_COMMIT="$(git rev-parse HEAD)"
if [ "$TAG_COMMIT" != "$HEAD_COMMIT" ]; then
    echo "error: tag $TAG points at ${TAG_COMMIT:0:7}, not at HEAD (${HEAD_COMMIT:0:7}); check out the tagged commit or re-tag" >&2
    exit 64
fi
if ! STATUS="$(git status --porcelain)"; then
    echo "error: git status failed" >&2
    exit 1
fi
if [ -n "$STATUS" ]; then
    echo "error: the working tree has uncommitted changes; commit or stash them before publishing:" >&2
    printf '%s\n' "$STATUS" >&2
    exit 1
fi

mkdir -p dist
NOTES_COPY="$REPO/dist/release-notes-$TAG.md"
if [ -e "$NOTES_COPY" ] && [ "$NOTES" -ef "$NOTES_COPY" ]; then
    usage_error "--notes must not be dist/release-notes-$TAG.md itself (that file is rewritten)"
fi
if ! SUM="$(cd "$(dirname "$DMG")" >/dev/null && shasum -a 256 "$(basename "$DMG")")"; then
    echo "error: shasum failed for $DMG" >&2
    exit 1
fi
if ! {
    cat "$NOTES"
    printf '\n## SHA-256\n\n    %s\n' "$SUM"
} > "$NOTES_COPY"; then
    echo "error: could not write $NOTES_COPY" >&2
    exit 1
fi
echo "publish: notes with SHA-256 written to dist/release-notes-$TAG.md"

if ! run git push origin "$TAG"; then
    echo "error: git push origin $TAG failed" >&2
    exit 1
fi
if ! run gh release create "$TAG" "$DMG" --title "$TITLE" --notes-file "$NOTES_COPY" --verify-tag; then
    echo "error: gh release create failed; the tag is pushed, so fix the problem and rerun this script" >&2
    exit 1
fi
if [ "$DRY_RUN" = "1" ]; then
    echo "publish: dry run; nothing was pushed or published"
else
    echo "publish: released $TAG"
fi
