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

echo "PASS $N checks"
