# macOS App Duplicator Phase 7 (Release) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship macOS App Duplicator the way spec §9 and §12 item 7 describe: a Developer ID signed, hardened-runtime, notarized and stapled app inside a signed UDZO DMG, published on GitHub Releases. Phase 7 adds the release scripts in `Tools/` (secure-timestamp build fix, `notarize.sh`, `make-dmg.sh`, `release.sh`, `publish-release.sh`) with a bash test file, a Help → Check for Updates… menu item backed by a pure `ReleaseLinks` enum, one new known limitation, README install and release sections, a Mike-present acceptance doc, two spec touch-ups and the 0.7.0 (6) version bump, and ends with a verified `--skip-notarize` release build of 0.7.0.

**Architecture:** Five bash scripts chain together. `Tools/release.sh` refuses a dirty tree, reads the version from `App/project.yml`, runs `Tools/build-app.sh --identity … --configuration Release` (which now adds a secure timestamp to every Xcode signature and stops Xcode injecting the `get-task-allow` entitlement, both notarization requirements), verifies the signatures, notarizes the app with `Tools/notarize.sh` (keychain profile `MAD-notary`, `ditto` zip staging, `notarytool submit --wait`, `stapler staple` and `validate`), builds and signs the DMG with `Tools/make-dmg.sh` (hdiutil UDZO from a `mktemp -d` staging folder holding the app and an Applications symlink), notarizes the DMG, prints both Gatekeeper verdicts and writes `dist/SHA256SUMS`. `Tools/publish-release.sh` pushes an existing tag and creates the GitHub release with `gh`. Every artefact lands in the git-ignored `dist/`. `Tools/tests/release-scripts.sh` tests the scripts through `bash -n`, `--help`, usage errors, `--dry-run`, the missing-profile path and one real `hdiutil create` from a fake `.app`, with trap binaries and a fake `gh` on `PATH` so nothing reaches Apple or GitHub. The app side is one pure enum, one Help button that hands its URL to `NSWorkspace`, and one `KnownLimitation`.

**Tech Stack:** bash 3.2 (`/usr/bin/env bash` on macOS 26; no associative arrays, no `mapfile`), `xcodebuild` through `Tools/build-app.sh`, `codesign`, `xcrun notarytool` 1.1.3, `xcrun stapler`, `hdiutil`, `ditto`, `spctl`, `shasum`, `plutil`, `gh`; Swift 6 language mode, SwiftUI + AppKit and XCTest for the app change (XcodeGen folder globs pick up the new Swift files).

## Global Constraints

Phase 6 constraints carry over verbatim unless a Phase 7 line below overrides them. In particular: macOS 26+ / arm64 only (`ARCHS = arm64`, `MACOSX_DEPLOYMENT_TARGET = 26.0`, `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`); Core imports Foundation, Security and Darwin only; XCTest only; no new `try?`, no empty `catch`, no `@unchecked Sendable`, no `swiftlint:disable`; never copy, repackage, patch or re-sign a target app; the signing identity is referred to by display name only; tests stay in their sandbox (per-test temp folders, never the real `~/Library`, `~/Applications`, `/Applications`, `UserDefaults.standard` or the network).

Phase 7 (Release) additions, from spec §9 ("The main app is Developer ID signed, hardened runtime, notarized (`notarytool`), shipped as DMG. Keychain-stored notarization credentials are referenced by profile name only."), §7 line 244 ("Sparkle deferred; releases via GitHub Releases + notarized DMG.") and §12 item 7 ("Release: notarization + DMG scripts, README, GitHub repo public, first tagged release."):

- **Scripts are bash, live in `Tools/`, start with `#!/usr/bin/env bash` and `set -euo pipefail`, take `--help`, and are executable (`chmod 755`).** They follow the shape of `Tools/build-app.sh` and `Tools/test-app.sh` (resolve `REPO` from `$0`, `cd "$REPO"`, flag parsing with a `case` loop, errors to stderr with `error:` prefix, exit 64 for usage errors, 69 for a missing tool, 1 for a failed step). No `create-dmg`, no Homebrew dependency beyond xcodegen (already required by `build-app.sh`); DMGs are made with `hdiutil`. No `shellcheck` is installed; `bash -n` is the syntax gate.
- **Secure timestamp.** The 0.6.0 build's main executable has `Signed Time=` but no `Timestamp=` in `codesign -dvv` (Xcode's plain `build` action does not add `--timestamp` for Developer ID), and notarization rejects signatures without a secure timestamp. `Tools/build-app.sh` must pass `OTHER_CODE_SIGN_FLAGS=--timestamp` to `xcodebuild` whenever `--identity` is given. Acceptance of this fix: `codesign -dvv "<app>" 2>&1 | grep -c '^Timestamp='` prints `1` for the main app and for `Contents/Resources/Launcher` and `Contents/Resources/WebShell` (the two embed phases in `App/project.yml` already pass `--timestamp`).
- **Notarization credentials are a keychain profile referenced by name only.** Default profile name `MAD-notary`, overridable with `--profile <name>`. No script ever takes an Apple ID, team id or password argument, and none ever runs `xcrun notarytool store-credentials`. When the profile is missing (`xcrun notarytool history --keychain-profile "$PROFILE"` fails), the notarize script prints exactly how to create it (`xcrun notarytool store-credentials MAD-notary --apple-id <your Apple ID> --team-id 4NQ2UVJ4EZ` and then enter an app-specific password from appleid.apple.com at the prompt) and exits 69. Nothing in any script or its output prints the Apple ID or password; the submission id and status from `notarytool` are fine to print. On a non-`Accepted` status the script saves `xcrun notarytool log <id>` to `dist/notary-<id>.json` and exits 1.
- **Notarize script: `Tools/notarize.sh <path> [--profile NAME] [--dry-run]`.** `<path>` is a `.app`, `.dmg` or `.zip`. A `.app` is zipped first with `ditto -c -k --keepParent` into `dist/` (notarytool does not take bare bundles); the zip is submitted with `xcrun notarytool submit <zip|dmg> --keychain-profile "$PROFILE" --wait --output-format json`; on `Accepted` the script runs `xcrun stapler staple <app|dmg>` on the original `.app` or `.dmg` (not the zip) and then `xcrun stapler validate`. `--dry-run` prints every command it would run (`notarytool`, `stapler`) without executing them and exits 0, and is the only path a test may exercise end to end apart from `--help` and the missing-profile message (use `--profile MAD-notary-does-not-exist`).
- **DMG script: `Tools/make-dmg.sh <app> [--output dist/<name>.dmg] [--identity "<display name>"] [--volname "<name>"]`.** Stages into `mktemp -d` (cleaned with an `EXIT` trap): `ditto "<app>" "$STAGE/<App>.app"` plus `ln -s /Applications "$STAGE/Applications"`; builds with `hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$OUT"` (default volname `macOS App Duplicator`, default output `dist/macOS-App-Duplicator-<MARKETING_VERSION>.dmg`, version read from `App/project.yml` with `grep -E 'MARKETING_VERSION:' | head -1 | sed -E 's/.*"([^"]+)".*/\1/'`); with `--identity` the DMG is signed `codesign --force --sign "$IDENTITY" --timestamp "$OUT"` and verified with `codesign --verify --verbose=2 "$OUT"`; always ends with `hdiutil verify "$OUT"`. No background image, no window layout (`.DS_Store` tricks) — YAGNI; recorded in Deferred. Verification in the plan: `hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$OUT"` (`MNT=$(mktemp -d)`), assert `"$MNT/<App>.app/Contents/Info.plist"` exists and `readlink "$MNT/Applications"` prints `/Applications`, then `hdiutil detach "$MNT"`.
- **Release script: `Tools/release.sh --identity "<display name>" [--profile NAME] [--skip-notarize] [--allow-dirty]`.** Order: refuse a dirty tree (`git status --porcelain` non-empty) unless `--allow-dirty`; read `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` from `App/project.yml`; `Tools/build-app.sh --identity "$IDENTITY" --configuration Release`; `codesign --verify --deep --strict --verbose=2 "$APP"`; assert the three `Timestamp=` lines (above); `Tools/notarize.sh "$APP" --profile "$PROFILE"` (skipped with a `warning:` line under `--skip-notarize`); `Tools/make-dmg.sh "$APP" --identity "$IDENTITY" --output "dist/macOS-App-Duplicator-$VERSION.dmg"`; `Tools/notarize.sh "$DMG" --profile "$PROFILE"` (same skip); `spctl --assess --type open --context context:primary-signature -v "$DMG"` and `spctl --assess --type execute -v "$APP"` are run and their verdicts printed, and they fail the script only when notarization ran (an un-notarized build is `rejected` by design); finally `shasum -a 256 "$DMG"` is written to `dist/SHA256SUMS` and printed. The script never installs anything and never touches `~/Applications`.
- **Publish script: `Tools/publish-release.sh <tag> <dmg> --notes <file> [--title "<title>"]`.** Checks `gh auth status` (exit 69 with a message if not logged in), that `<tag>` exists locally and points at `HEAD` (`git rev-parse "$tag"` equals `git rev-parse HEAD`, exit 64 otherwise), that `git status --porcelain` is empty, that `<dmg>` exists; pushes the tag (`git push origin "$tag"`); appends a `## SHA-256` section with `shasum -a 256` of the DMG to a copy of the notes in `dist/`; runs `gh release create "$tag" "$dmg" --title "$TITLE" --notes-file "$NOTES_COPY"`. Default title `<tag>`. It never creates the tag itself (the human tags after the version-bump commit). `--dry-run` prints the commands instead.
- **Help menu: "Check for Updates…" opens the latest-release page.** Sparkle stays deferred (spec line 244). The App gains a pure `ReleaseLinks` enum in `App/Sources/Services/ReleaseLinks.swift` with `static let repository: URL` (`https://github.com/cubbieblue16/MacAppDuplicator`) and `static let latestRelease: URL` (`https://github.com/cubbieblue16/MacAppDuplicator/releases/latest`). Build both without a force unwrap: a private `static func gitHub(path: String) -> URL` fills `URLComponents` (scheme `https`, host `github.com`, path) and reads `components.url`; if that is nil (it cannot be for these literals) fall back to `URL(fileURLWithPath: "/")` — no `!`, no `try?`. Unit test (`App/Tests/Services/ReleaseLinksTests.swift`) asserts the exact `absoluteString` of both URLs. The Help `CommandGroup(after: .help)` in `App/Sources/App/MacAppDuplicatorApp.swift:89-91` gains a `Button("Check for Updates…") { NSWorkspace.shared.open(ReleaseLinks.latestRelease) }` after the existing `KnownLimitationsMenuItem()`. No network call, no background check, no `URLSession`.
- **Known limitation entry:** one new `KnownLimitation` (id `updates-manual`) stating that the app does not check for updates by itself; Help → Check for Updates… opens the GitHub releases page, and a new version is installed by dragging the DMG's app over the old one. `KnownLimitations.all` grows from 35 to 36; update the count assertion if a test pins it.
- **Version bump:** `MARKETING_VERSION "0.7.0"`, `CURRENT_PROJECT_VERSION "6"` in `App/project.yml`, as the last task, after `Tools/test-app.sh` passes. (Whether the first notarized release is called 0.7.0 or 1.0.0 is Mike's decision; the plan uses 0.7.0 and records the alternative in Deferred.)
- **README gains two sections and keeps the phase sections:** `## Install` right after the intro (download the `.dmg` from the GitHub Releases page, open it, drag the app to Applications, first launch opens without a Gatekeeper prompt because the app is notarized; releases before 0.7.0 were not notarized and need right-click → Open once), and `## Releasing (maintainers)` before `## Core API used by the app` (one-time `xcrun notarytool store-credentials MAD-notary --apple-id <your Apple ID> --team-id 4NQ2UVJ4EZ`; then `Tools/release.sh --identity "Developer ID Application: <name> (<team>)"`; then tag and `Tools/publish-release.sh`). No LICENSE file is added and the README does not name a license (Mike has not picked one).
- **Acceptance doc `docs/acceptance/phase7-release.md`** (Mike-present): create the notary profile, run `Tools/release.sh`, confirm `Accepted`, `xcrun stapler validate` on app and DMG, `spctl --assess` prints `accepted` with `source=Notarized Developer ID`, mount the DMG and drag-install over the installed copy, launch with no Gatekeeper dialog, Help → Check for Updates… opens the browser, tag `v0.7.0`, `Tools/publish-release.sh`, download the published DMG with `gh release download` and compare the SHA-256. Teardown: eject the DMG, keep `dist/` (git-ignored).
- **Spec touch-ups:** §9 line 280 gains "(`Tools/notarize.sh`, `Tools/make-dmg.sh`, `Tools/release.sh`, `Tools/publish-release.sh`; profile `MAD-notary` by default)"; §7 line 244 gains "Help → Check for Updates… opens the GitHub releases page."; §12 item 7 unchanged.
- **Never commit `dist/`, `.dmg` or `.zip` artefacts** (`.gitignore` already lists `/dist/` and `*.dmg`; add `*.zip` only if a zip ever lands outside `dist/`, which the scripts prevent).

## Implementer contract

Repo: `~/Developer/MacAppDuplicator` (git main). Every Bash call starts in a different cwd, so prefix commands with `cd ~/Developer/MacAppDuplicator &&`. No `timeout` binary; foreground `sleep` is blocked. Nobody else builds in this repo while you work.

Liveness: append one line `<HH:MM> step N <what>` to the PROGRESS file named in your dispatch after EVERY step (tests run, file written, commit made). A file idle for 10 minutes is treated as a stall and you are killed; write to it even when a build is slow (write before starting the build).

Tests: `swift test --filter DuplicatorCoreTests.<SuiteName>` runs one suite (dot form only; slash form runs 0 tests). Whole Core: `swift test --filter DuplicatorCoreTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`. App suite: `Tools/test-app.sh` (look for `** TEST SUCCEEDED **`; `grep error:` is swallowed by linkd XPC noise, count SUCCEEDED/FAILED lines instead). Shell scripts: `bash -n <script>` must pass and every script must run `set -euo pipefail`. Swift 6 strict concurrency applies to tests too: never `@unchecked Sendable`, no new `try?`, no empty `catch`, no `swiftlint:disable`. XCTest only.

Release tooling rules: never run `xcrun notarytool submit` or `store-credentials` yourself (Mike-present, needs his Apple ID); exercise only the scripts' `--help`, `--dry-run` and missing-profile paths. Never print a codesign identity hash, certificate fingerprint, Apple ID or password; refer to the signing identity by display name only (`Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)`). Never commit a `.dmg` or `.zip` (`dist/` is git-ignored). Never touch `~/Applications`, `/Applications` or the installed `macOS App Duplicator.app`; scripts write only under `dist/` or a `mktemp -d` staging folder. Never add a `LICENSE` file (Mike has not picked one). Never push.

Commits: `git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit ...`, message body ends with the line `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Stage only the files your task names.

Scope: touch only the files the brief lists. Tests never write outside mktemp dirs; never touch `UserDefaults.standard`, `~/Library/*` or the network.

Report: write the full report to the REPORT file named in your dispatch: what you changed (file list), exact commands run with their final summary lines, deviations from the brief and why, self-review notes, concerns. Your return message is at most 8 lines: STATUS (DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED), commit sha(s), one-line test summary, concerns or `none`.

## Inputs and conventions

- Spec: `docs/superpowers/specs/2026-10-09-macos-app-duplicator-design.md` line 5 (distribution: Developer ID signed for personal use, notarized DMG on GitHub releases), line 43 (`Tools/` holds the notarize and DMG scripts), line 244 (§7: Sparkle deferred; releases via GitHub Releases + notarized DMG), line 280 (§9: Developer ID, hardened runtime, `notarytool`, DMG, keychain credentials referenced by profile name only), line 318 (§12 item 7: Release).
- Baselines at HEAD `62aedeb` (v0.6.0, "Release: 0.6.0 (5)", tree clean): Core 286, WebShell 56, CompatProfiles 37, Integration 5 (gated), `Tools/test-app.sh` 361.
- Running totals: App 363 after Task 5 (`ReleaseLinksTests` adds 2; the known-limitation change edits one existing assertion and adds no test). Core, WebShell, CompatProfiles and Integration stay at 286 / 56 / 37 / 5: no Phase 7 task touches `Packages/`, `Launcher/`, `WebShell/`, `Tests/` or `Tools/madctl`, so the gated integration suite is not re-run (Task 7 proves the untouched paths with `git diff`). `Tools/tests/release-scripts.sh` prints `PASS 4 checks` after Task 1, `PASS 35 checks` after Task 2, `PASS 59 checks` after Task 3 and `PASS 115 checks` after Task 4, unchanged after that.
- Commands (always prefix `cd ~/Developer/MacAppDuplicator &&`; the shell cwd resets per call; there is no `timeout` binary and foreground `sleep` is blocked):
  - Release scripts: `Tools/tests/release-scripts.sh 2>&1 | tail -1` prints `PASS <n> checks`. A failure prints `FAIL <n> <check>` and the first 40 lines of the failing command's stdout and stderr, and exits 1.
  - One script's syntax: `bash -n Tools/<script>.sh` prints nothing and exits 0 (no `shellcheck` is installed).
  - Whole Core: `swift test --filter DuplicatorCoreTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` prints `Executed 286 tests, with 0 failures`.
  - WebShell: `swift test --filter WebShellTests 2>&1 | grep "'Selected tests' passed" -A1` prints `Executed 56 tests, with 0 failures`.
  - CompatProfiles: `swift test --filter CompatProfilesTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` prints `Executed 37 tests, with 0 failures`.
  - App: `Tools/test-app.sh 2>&1 | tail -3` ends with `** TEST SUCCEEDED **`; count with `Tools/test-app.sh 2>&1 | grep -cE "Test Case .* passed"`. One class: `Tools/test-app.sh -only-testing:MacAppDuplicatorTests/<Class> 2>&1 | tail -3`.
  - Forbidden constructs (every Swift file a task touches, expect no output): `grep -nE 'try\?|@unchecked|swiftlint:disable|nonisolated\(unsafe\)' <files>`.
  - Secrets: never paste whole `codesign -dvv` output or a raw build log into a report. Grep single fields (`^Timestamp=`, `^Authority=`, `flags=`), and pipe any xcactivitylog line through `sed -E 's/--sign [^ ]+/--sign <redacted>/g'`. The identity is only ever written as `Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)`.
- Commit identity: `git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit`, every message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Stage only the files the task names.
- Script conventions (Tasks 1-4, binding): `#!/usr/bin/env bash`; a header comment carrying the Usage line; `set -euo pipefail`; `usage()` prints a quoted heredoc to stdout; `usage_error` prints `error: <message>` and `Run Tools/<script> --help for usage.` to stderr and exits 64; `need_value <option> "${2-}"` rejects a missing or option-looking value; `REPO="$(cd "$(dirname "$0")/.." >/dev/null && pwd)"` (the redirect keeps a `CDPATH` echo out of the value); `CALLER_PWD` plus `abspath` so a relative path argument means the caller's directory even after `cd "$REPO"`; tools checked with `command -v` (exit 69); every failed step prints `error: …` and exits 1; `show` prints `dry-run: <command>` on one line with any argument holding a character outside `A-Za-z0-9_./:=@%+,-` double-quoted (the test file rebuilds that form with its `shown` helper); 4-space indentation; bash 3.2 only (no associative arrays, no `mapfile`, no `${var,,}`); never pipe into `grep -q` under `pipefail` (capture first, then `case` or `grep -c … || true`).
- Signing facts gathered read-only on 2026-10-11 (identity hashes not shown):

| Item | Evidence | Consequence |
|---|---|---|
| Installed 0.6.0 main app (`~/Applications/macOS App Duplicator.app`) | `codesign -dvv` shows `Signed Time=` and no `Timestamp=`; its entitlements include `com.apple.security.get-task-allow` | notarization would reject it twice over |
| Installed 0.6.0 `Contents/Resources/Launcher` and `Contents/Resources/WebShell` | `Timestamp=` present (the two Embed phases in `App/project.yml` sign with `--options runtime --timestamp`); no entitlements | nothing to change |
| 0.6.0 (5) Developer ID Release build in `.build/DerivedData/Build/Products/Release/` | `flags=0x10000(runtime)`, `Signed Time=` only, entitlements `com.apple.security.get-task-allow = true` | a Release configuration alone does not drop get-task-allow; Task 1 adds `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` (deviation D1) |
| Xcode's own codesign call for the app (xcactivitylog, identity redacted) | `codesign --force --sign <redacted> -o runtime --entitlements … --timestamp=none --generate-entitlement-der …` | Xcode asks for no timestamp explicitly; `OTHER_CODE_SIGN_FLAGS=--timestamp` is proven to win only by Task 7's real build, which has a contingency |
| `spctl --assess --type execute -v` on an un-notarized Developer ID app | `<path>: rejected` and `source=Unnotarized Developer ID`, non-zero exit | `release.sh --skip-notarize` prints the verdict and carries on |
| `xcrun notarytool` 1.1.3 | the planner ran only `--version` and the `submit`, `history` and `log` `--help` pages; the brief records that no `MAD-notary` profile exists yet | `history --keychain-profile <name>` is the profile check: without the keychain item notarytool cannot authenticate, so it fails before any submission; tests use `MAD-notary-does-not-exist`, and Task 2 Step 3 is that path's first real run |
| `gh` | logged in as `cubbieblue16`; repo `cubbieblue16/MacAppDuplicator`; releases v0.3.0-v0.6.0 carry zips | `publish-release.sh` attaches the DMG; tests always put a fake `gh` first on `PATH` |

- Existing patterns to mirror: `Tools/build-app.sh` (REPO from `$0`, `case` loop, exits 64 and 69, last stdout line is the app path), `Tools/smoke-dock-identity.sh` (header comment, `set -euo pipefail`, `mktemp -d` plus `EXIT` trap), `App/Sources/Services/ExportInstructions.swift` and `App/Tests/Services/ProfileSummaryTests.swift` (small pure services and their tests), `KnownLimitationsMenuItem` in `App/Sources/App/MacAppDuplicatorApp.swift`.
- `App/project.yml` lists sources as folder globs (`- path: Sources`, `- path: Tests`), so the new Swift files need no project edit (`Tools/test-app.sh` regenerates the project). `Package.swift` targets use explicit paths, so `Tools/tests/` is invisible to SwiftPM.

## File structure

Create:
- `Tools/tests/release-scripts.sh`: bash tests for the release scripts (Task 1 creates it; Tasks 2-4 insert their sections).
- `Tools/notarize.sh`: notarize a `.app`, `.dmg` or `.zip` with a keychain profile; staple and validate.
- `Tools/make-dmg.sh`: UDZO DMG holding the app and an Applications symlink; optional signing; `hdiutil verify`.
- `Tools/release.sh`: build, check, notarize, package and checksum a release into `dist/`.
- `Tools/publish-release.sh`: push an existing tag and create the GitHub release with the DMG.
- `App/Sources/Services/ReleaseLinks.swift`: the GitHub repository and latest-release URLs.
- `App/Tests/Services/ReleaseLinksTests.swift`: 2 tests.
- `docs/acceptance/phase7-release.md`: the Mike-present release checklist.

Modify:
- `Tools/build-app.sh` (header line 3; identity block lines 39-41): secure timestamp and no injected get-task-allow for identity builds.
- `App/Sources/App/KnownLimitations.swift` (doc comment lines 15-16; new entry after `system-launch-helper`): `updates-manual`.
- `App/Tests/App/KnownLimitationsTests.swift` (lines 92-97): count 35 → 36.
- `App/Sources/App/MacAppDuplicatorApp.swift` (lines 89-91): Help → Check for Updates….
- `README.md` (after line 3; line 81; after line 157): `## Install`, the Known Limitations count, `## Releasing (maintainers)`.
- `docs/superpowers/specs/2026-10-09-macos-app-duplicator-design.md` (lines 244 and 280).
- `App/project.yml` (lines 56-57): 0.7.0 (6).

Unchanged: `.gitignore` (already ignores `/dist/` and `*.dmg`; the scripts never leave a `.zip` outside `dist/`), `Tools/test-app.sh`, `Package.swift`.

---

### Task 1: `Tools/build-app.sh` secure timestamp and no `get-task-allow`; `Tools/tests/release-scripts.sh`

**Files:**
- Create: `Tools/tests/release-scripts.sh`
- Modify: `Tools/build-app.sh` (header line 3; identity block lines 39-41)

**Interfaces:**
- Consumes: `Tools/build-app.sh [--identity "<display name>"] [--configuration Debug|Release]` (CLI unchanged; still prints the app path as its last stdout line).
- Produces: identity builds pass `OTHER_CODE_SIGN_FLAGS=--timestamp` and `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` to `xcodebuild`; ad hoc builds (no `--identity`) are byte-for-byte the same command as before. `Tools/tests/release-scripts.sh` (no arguments): `ok <n> <check>` per check, `PASS <n> checks` at the end, `FAIL <n> <check>` and exit 1 at the first failure. Helpers for later tasks: `ok <label>`, `fail <label>`, `expect_exit <code> <label> <command…>` (stdout to `$T/out`, stderr to `$T/err`), `has <file> <text> <label>` and `lacks <file> <text> <label>` (fixed-string search in `$T/<file>`), `shown <arg>`, `tgit <git args…>`; scratch folder `$T` (removed on exit) and `MNT` (detached on exit when non-empty). Tasks 2-4 insert their sections directly above the final `echo "PASS $N checks"` line.

Do not run `Tools/build-app.sh` in this task; Task 7 runs it (Release, Developer ID) and checks the real signatures.

- [ ] **Step 1: Write the failing check.** Create `Tools/tests/release-scripts.sh` with exactly this content:

```bash
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
```

Run: `cd ~/Developer/MacAppDuplicator && chmod 755 Tools/tests/release-scripts.sh && bash -n Tools/tests/release-scripts.sh && Tools/tests/release-scripts.sh; echo "exit=$?"`
Expected: `ok 1 build-app.sh passes bash -n`, then on stderr `FAIL 2 build-app.sh adds --timestamp to identity builds (line:   ARGS+=("CODE_SIGN_IDENTITY=$IDENTITY" "DEVELOPMENT_TEAM=4NQ2UVJ4EZ"))`, then `exit=1`.

- [ ] **Step 2: Fix `Tools/build-app.sh`.** Keep its existing 2-space style and `#!/bin/bash` line. Replace line 3:

```bash
# Without --identity the app and the embedded Launcher and WebShell are ad hoc signed.
```

with:

```bash
# Without --identity the app and the embedded Launcher and WebShell are ad hoc signed. With --identity every signature
# carries a secure timestamp and the app has no get-task-allow entitlement, as notarization requires.
```

Then replace the identity block (old lines 39-41):

```bash
if [ -n "$IDENTITY" ]; then
  ARGS+=("CODE_SIGN_IDENTITY=$IDENTITY" "DEVELOPMENT_TEAM=4NQ2UVJ4EZ")
fi
```

with:

```bash
if [ -n "$IDENTITY" ]; then
  # Notarization rejects a signature without a secure timestamp and a hardened app that allows debugging; Xcode's
  # build action signs with --timestamp=none and injects get-task-allow unless these two settings say otherwise.
  ARGS+=("CODE_SIGN_IDENTITY=$IDENTITY" "DEVELOPMENT_TEAM=4NQ2UVJ4EZ" "OTHER_CODE_SIGN_FLAGS=--timestamp" "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO")
fi
```

The comment must not contain either setting name (the fourth check counts each name once).

- [ ] **Step 3: Run the checks.**

Run: `cd ~/Developer/MacAppDuplicator && bash -n Tools/build-app.sh && Tools/tests/release-scripts.sh 2>&1 | tail -1 && git status --porcelain`
Expected: `PASS 4 checks`, then ` M Tools/build-app.sh` and `?? Tools/tests/` (nothing else).

- [ ] **Step 4: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add Tools/build-app.sh Tools/tests/release-scripts.sh && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -m "Release tooling: secure timestamp and no get-task-allow for Developer ID builds" -m "Tools/build-app.sh passes OTHER_CODE_SIGN_FLAGS=--timestamp and CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO to xcodebuild when --identity is given. The 0.6.0 main executable carried only Signed Time, and a Developer ID Release build still carried com.apple.security.get-task-allow; notarization rejects both. Adds Tools/tests/release-scripts.sh, the bash test file for the Phase 7 release scripts (4 checks)." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Deviations

- D1: `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` joins the constraint's `OTHER_CODE_SIGN_FLAGS=--timestamp`. Evidence: the 0.6.0 (5) Developer ID Release build and the installed 0.6.0 both carry `com.apple.security.get-task-allow`, which notarization rejects for hardened-runtime apps. Without it every local check in Task 7 would pass and the first real `notarytool submit` would come back `Invalid`. `release.sh` (Task 4) also checks each signature for the entitlement.
- Header line 3 grows a second comment line describing identity builds.
- Per the brief, the checks read the source line instead of building; Task 7 checks the real signatures.

---

### Task 2: `Tools/notarize.sh`

**Files:**
- Create: `Tools/notarize.sh`
- Modify: `Tools/tests/release-scripts.sh` (insert the Task 2 section directly above the final `echo "PASS $N checks"`)

**Interfaces:**
- Consumes: Task 1's test helpers (`expect_exit`, `has`, `lacks`, `shown`, `ok`, `fail`, `$T`); `xcrun notarytool` (`history`, `submit`, `log`), `xcrun stapler` (`staple`, `validate`), `ditto`, `plutil`.
- Produces: `Tools/notarize.sh <path> [--profile NAME] [--dry-run]`. Exit 0 notarized (or dry run); 1 a step failed or the status is not `Accepted` (log saved to `dist/notary-<id>.json`); 64 usage error; 69 missing tool or keychain profile. Dry-run lines, in order: `dry-run: xcrun notarytool history --keychain-profile <profile>`; for a `.app` only `dry-run: ditto -c -k --keepParent <app> dist/<name>.zip`; `dry-run: xcrun notarytool submit <dist/<name>.zip|dmg|zip> --keychain-profile <profile> --wait --output-format json`; for a `.app` or `.dmg` `dry-run: xcrun stapler staple <path>` and `dry-run: xcrun stapler validate <path>`. Paths print absolute (a relative argument resolves against the caller's directory). Task 4's `Tools/release.sh` calls `Tools/notarize.sh "$APP" --profile "$PROFILE"` and `Tools/notarize.sh "$DMG" --profile "$PROFILE"` and copies `show` and `profile_hint` verbatim. Test fixtures created here and reused by Tasks 3 and 4: `$T/Fake.app` (a minimal bundle with `Contents/Info.plist` and an executable), `$T/dummy.dmg`, `$T/dummy.zip`, `$T/notes.txt`.

- [ ] **Step 1: Write the failing checks.** Insert this block directly above the final line `echo "PASS $N checks"` of `Tools/tests/release-scripts.sh`, keeping one blank line before that line:

```bash
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
```

Run: `cd ~/Developer/MacAppDuplicator && bash -n Tools/tests/release-scripts.sh && Tools/tests/release-scripts.sh; echo "exit=$?"`
Expected: `ok 1` to `ok 4`, then on stderr `FAIL 5 notarize.sh passes bash -n (exit 127, expected 0)` followed by the excerpt `bash: Tools/notarize.sh: No such file or directory`, then `exit=1`.

- [ ] **Step 2: Create `Tools/notarize.sh`** with exactly this content, then run `chmod 755 Tools/notarize.sh`:

```bash
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
```

- [ ] **Step 3: Run the checks.** The exit-69 check is the first real run of `xcrun notarytool history --keychain-profile MAD-notary-does-not-exist`; it must fail because that keychain item does not exist. If that check fails with any exit other than 69, put the first five stderr lines in the report (they contain no Apple ID) and stop with NEEDS_CONTEXT instead of changing the check.

Run: `cd ~/Developer/MacAppDuplicator && bash -n Tools/notarize.sh && Tools/tests/release-scripts.sh 2>&1 | tail -1 && git status --porcelain`
Expected: `PASS 35 checks`, then ` M Tools/tests/release-scripts.sh` and `?? Tools/notarize.sh` (no `dist/` entry: it is git-ignored, and the checks leave nothing in it).

- [ ] **Step 4: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add Tools/notarize.sh Tools/tests/release-scripts.sh && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -m "Release tooling: Tools/notarize.sh" -m "Notarizes a Developer ID signed .app, .dmg or .zip with a notarytool keychain profile (default MAD-notary, --profile to override; never an Apple ID or password). A .app is zipped into dist/ with ditto first and the zip is deleted on exit; the submission waits for Apple's verdict; on Accepted the original .app or .dmg is stapled and validated; any other status saves the notary log to dist/notary-<id>.json and exits 1. A missing profile exits 69 with the store-credentials command. --dry-run prints every command. 31 new checks in Tools/tests/release-scripts.sh (35 in all)." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Deviations

- The missing-profile hint names the profile the run asked for (`--profile X` prints `store-credentials X …`); with the default it is the constraint's exact `MAD-notary` command.
- The staged `dist/<name>.zip` is deleted on exit, success or failure, so `dist/` keeps only deliverables and notary logs; the constraint does not say whether to keep it.
- A `.zip` is submitted as is and never stapled (stapler cannot staple a zip); the script says so and exits 0 on `Accepted`.
- Every failed sub-step prints `error: …` and exits 1, including a failed `notarytool log` fetch, which also prints the manual fetch command.
- `--dry-run` prints the `history` profile check instead of running it, so a dry run touches neither the keychain nor the network.
- Unknown options, including `--apple-id`, `--password` and `--team-id`, exit 64 (one check covers `--apple-id`).

---

### Task 3: `Tools/make-dmg.sh`

**Files:**
- Create: `Tools/make-dmg.sh`
- Modify: `Tools/tests/release-scripts.sh` (insert the Task 3 section directly above the final `echo "PASS $N checks"`)

**Interfaces:**
- Consumes: Task 1's helpers and Task 2's fixtures (`$T/Fake.app`, `$T/notes.txt`); `hdiutil`, `ditto`, and `codesign` when `--identity` is given; `MARKETING_VERSION` in `App/project.yml` for the default name.
- Produces: `Tools/make-dmg.sh <app> [--output dist/<name>.dmg] [--identity "<display name>"] [--volname "<name>"]`. Writes a UDZO image whose root holds `<App>.app` and an `Applications` symlink to `/Applications`; default output `dist/macOS-App-Duplicator-<MARKETING_VERSION>.dmg` under the repository, default volume name `macOS App Duplicator`; with `--identity` the image is signed with a secure timestamp and verified; always ends with `hdiutil verify`. The absolute DMG path is the last stdout line. Exit 0 built and verified, 1 a step failed, 64 usage error, 69 missing tool. Task 4's `Tools/release.sh` calls `Tools/make-dmg.sh "$APP" --identity "$IDENTITY" --output "dist/macOS-App-Duplicator-$VERSION.dmg"`.

These checks create two real disk images (one with `--output` into `$T/dmg/`, one with the default name inside a throwaway copy of the script under `$T/mini/`), mount the first read-only at a `mktemp -d` mount point and detach it. Nothing is signed (no `--identity`), and the repository's own `dist/` is never written. If `hdiutil` fails with a permission or sandbox error rather than a script error, stop and report BLOCKED with the error line instead of changing a check.

- [ ] **Step 1: Write the failing checks.** Insert this block directly above the final line `echo "PASS $N checks"` of `Tools/tests/release-scripts.sh`, keeping one blank line before that line:

```bash
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
```

Run: `cd ~/Developer/MacAppDuplicator && bash -n Tools/tests/release-scripts.sh && Tools/tests/release-scripts.sh; echo "exit=$?"`
Expected: `ok 1` to `ok 35`, then on stderr `FAIL 36 make-dmg.sh passes bash -n (exit 127, expected 0)` and the excerpt `bash: Tools/make-dmg.sh: No such file or directory`, then `exit=1`.

- [ ] **Step 2: Create `Tools/make-dmg.sh`** with exactly this content, then run `chmod 755 Tools/make-dmg.sh`:

```bash
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
```

- [ ] **Step 3: Run the checks and confirm nothing is left behind.**

Run: `cd ~/Developer/MacAppDuplicator && bash -n Tools/make-dmg.sh && Tools/tests/release-scripts.sh 2>&1 | tail -1 && hdiutil info | grep -c 'mad-release-scripts' ; test ! -e dist/macOS-App-Duplicator-9.8.7.dmg && echo "repository dist/ untouched" && git status --porcelain`
Expected: `PASS 59 checks`, then `0` (no test image still attached), `repository dist/ untouched`, then ` M Tools/tests/release-scripts.sh` and `?? Tools/make-dmg.sh`.

- [ ] **Step 4: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add Tools/make-dmg.sh Tools/tests/release-scripts.sh && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -m "Release tooling: Tools/make-dmg.sh" -m "Builds a compressed, read-only UDZO DMG with hdiutil from a mktemp -d staging folder holding the app (copied with ditto) and an /Applications symlink. Default output dist/macOS-App-Duplicator-<MARKETING_VERSION>.dmg, default volume name macOS App Duplicator; --identity signs the image with a secure timestamp and verifies it; hdiutil verify always runs; the DMG path is the last stdout line. 24 new checks in Tools/tests/release-scripts.sh (59 in all), including a real image built from a fake .app, mounted read-only and detached." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Deviations

- The absolute DMG path is printed as the last stdout line (mirrors `Tools/build-app.sh`), and progress lines start with `make-dmg:`.
- A `.app` without `Contents/Info.plist` is refused with exit 64, so a wrong folder is never packaged.
- `--output` is resolved against the caller's directory and its folder is created when missing; the default path is absolute under the repository's `dist/`.
- The default-name check runs a copy of the script inside `$T/mini/` with a two-key `App/project.yml`, so the test never writes the repository's own `dist/`.
- The detach check falls back to `hdiutil detach -force` (Spotlight can briefly hold a fresh volume busy); the harness's `EXIT` trap detaches the same way if a check fails while the image is mounted.
- Every failed step (folder creation, `ditto`, `hdiutil create`, `codesign`, `hdiutil verify`) prints `error: …` and exits 1.

---


### Task 4: `Tools/release.sh` and `Tools/publish-release.sh`

**Files:**
- Create: `Tools/release.sh`
- Create: `Tools/publish-release.sh`
- Modify: `Tools/tests/release-scripts.sh` (insert the Task 4 section directly above the final `echo "PASS $N checks"`)

**Interfaces:**
- Consumes: Task 1's helpers and Task 2's fixtures (`$T/dummy.dmg`, `$T/notes.txt`); `Tools/build-app.sh --identity "<display name>" --configuration Release` (Task 1 signing settings; the app path is its last stdout line); `Tools/notarize.sh <path> --profile <name>` (Task 2); `Tools/make-dmg.sh <app> --identity "<display name>" --output <dmg>` (Task 3); `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `App/project.yml`; `git`, `codesign`, `spctl`, `shasum`, `xcrun notarytool`; `gh` logged in to the account that owns `cubbieblue16/MacAppDuplicator`.
- Produces: `Tools/release.sh --identity "Developer ID Application: <name> (<team>)" [--profile NAME] [--skip-notarize] [--allow-dirty] [--dry-run]`. It writes `dist/macOS-App-Duplicator-<MARKETING_VERSION>.dmg` and `dist/SHA256SUMS` (one `shasum -a 256` line naming the DMG by its basename), prints progress as `release: …` and dry-run steps as `dry-run: …` (same quoting as `Tools/notarize.sh`). Exit 0 released into `dist/` (or dry run), 1 a step failed, 64 usage error, 69 missing tool or keychain profile. `Tools/publish-release.sh <tag> <dmg> --notes <file> [--title "<title>"] [--dry-run]` writes `dist/release-notes-<tag>.md` (the notes plus a `## SHA-256` section), runs `git push origin <tag>` and `gh release create <tag> <dmg> --title <title> --notes-file dist/release-notes-<tag>.md --verify-tag`. Exit 0 published (or dry run), 1 a step failed, 64 usage error or a tag that is missing or not at HEAD, 69 missing tool or `gh` not logged in. Task 6 documents both scripts in the README; Task 7 runs `Tools/release.sh --skip-notarize` for real; the acceptance checklist runs both for real with Mike present.

Do not run `Tools/release.sh` yourself in this task; the test file runs it only with `--dry-run` or into the missing-profile stop (exit 69, before anything is built), with logging stand-ins for the build, signing, notary and disk-image tools first on `PATH`. Never run `Tools/publish-release.sh` outside the test file: its real path pushes a tag and publishes a release. The test file runs it with a stand-in `gh` first on `PATH` and always with `--dry-run`; in this repository it only reaches paths that stop at a usage, login or tag check, and its one complete dry run happens inside a throwaway repository under `$T/pub/`, so the repository's own `dist/` is never written.

- [ ] **Step 1: Write the failing checks.** Insert this block directly above the final line `echo "PASS $N checks"` of `Tools/tests/release-scripts.sh`, keeping one blank line before that line:

```bash
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
```

Run: `cd ~/Developer/MacAppDuplicator && bash -n Tools/tests/release-scripts.sh && Tools/tests/release-scripts.sh; echo "exit=$?"`
Expected: `ok 1` to `ok 59`, then on stderr `FAIL 60 release.sh passes bash -n (exit 127, expected 0)` and the excerpt `bash: Tools/release.sh: No such file or directory`, then `exit=1`.

- [ ] **Step 2: Create `Tools/release.sh`** with exactly this content, then run `chmod 755 Tools/release.sh`. `show` and `profile_hint` are copied verbatim from `Tools/notarize.sh`.

```bash
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
```

Run: `cd ~/Developer/MacAppDuplicator && chmod 755 Tools/release.sh && bash -n Tools/release.sh && Tools/tests/release-scripts.sh; echo "exit=$?"`
Expected: `ok 1` to `ok 91` (the last is `ok 91 release.sh reads both version keys`), then on stderr `FAIL 92 publish-release.sh passes bash -n (exit 127, expected 0)` and the excerpt `bash: Tools/publish-release.sh: No such file or directory`, then `exit=1`. Check 84 is the first run of `release.sh` into the missing-profile stop; if it fails with any exit other than 69, put the first five stderr lines in the report (they contain no Apple ID) and stop with NEEDS_CONTEXT instead of changing the check.

- [ ] **Step 3: Create `Tools/publish-release.sh`** with exactly this content, then run `chmod 755 Tools/publish-release.sh`. `need_value`, `abspath` and `show` match `Tools/notarize.sh`.

```bash
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
```

- [ ] **Step 4: Run the checks and confirm the repository's `dist/` holds no notes copy.**

Run: `cd ~/Developer/MacAppDuplicator && bash -n Tools/release.sh && bash -n Tools/publish-release.sh && Tools/tests/release-scripts.sh 2>&1 | tail -1 && { ls dist 2>/dev/null | grep -c 'release-notes-' ; git status --porcelain ; }`
Expected: `PASS 115 checks`, then `0`, then ` M Tools/tests/release-scripts.sh`, `?? Tools/publish-release.sh` and `?? Tools/release.sh` (nothing else).

- [ ] **Step 5: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add Tools/release.sh Tools/publish-release.sh Tools/tests/release-scripts.sh && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -m "Release tooling: Tools/release.sh and Tools/publish-release.sh" -m "Tools/release.sh checks the tree is clean, reads the version from App/project.yml, checks the notarytool keychain profile before building, builds Release with the Developer ID identity, checks every signature for a secure timestamp and no get-task-allow entitlement, notarizes and staples the app, builds the signed DMG, notarizes and staples the DMG, prints the Gatekeeper verdicts and writes dist/SHA256SUMS; --skip-notarize, --allow-dirty and --dry-run. Tools/publish-release.sh checks gh is logged in, the tag exists at HEAD and the tree is clean, writes dist/release-notes-<tag>.md with a SHA-256 section, pushes the tag and runs gh release create --verify-tag with the DMG; --dry-run prints the push and gh commands. 56 new checks in Tools/tests/release-scripts.sh (115 in all) with logging stand-ins for the build, signing, notary, disk-image and gh tools." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Deviations

- `Tools/release.sh` gains `--dry-run`, so its step order is testable without building, signing or contacting Apple.
- The keychain-profile check runs before the build (exit 69 in seconds instead of after a multi-minute build); `Tools/notarize.sh` repeats it before each submission.
- `--identity` must start with `Developer ID Application: ` (exit 64 otherwise): notarization rejects Apple Development and ad hoc signatures.
- Next to each `Timestamp=` check, `release.sh` checks the same three signatures for `com.apple.security.get-task-allow` (D1's second half).
- The build output is copied with `tee` to a `mktemp` log, and the app path is taken from its last line (the `Tools/build-app.sh` contract) instead of being recomputed.
- `dist/SHA256SUMS` names the DMG by its basename (written from inside `dist/`), so `cd dist && shasum -a 256 -c SHA256SUMS` works for Mike and for anyone who downloads both files.
- `publish-release.sh` peels the tag with `^{commit}` (an annotated tag's own object id never equals HEAD), exits 64 for a tag that is missing or not at HEAD as the constraint says, and passes `--verify-tag` (gh 2.94.0 has it) so `gh` can never create a fresh tag on the remote's default branch.
- `publish-release.sh --dry-run` still writes `dist/release-notes-<tag>.md` (git-ignored), so the SHA-256 section can be read before anything is published; the SHA line is an indented code block so GitHub shows it in monospace.
- Every failed step prints `error: …` and exits 1; usage errors stay 64 and missing tools, profile or login stay 69.
- The checks put logging stand-ins first on `PATH` (build, signing, notary and disk-image tools for `release.sh`; `gh` for `publish-release.sh`) and run the complete publish dry run inside a throwaway repository with its own annotated tag, so no check can build, sign, notarize, push or publish.

---

### Task 5: App: Help → Check for Updates… and the manual-updates known limitation

**Files:**
- Create: `App/Sources/Services/ReleaseLinks.swift`, `App/Tests/Services/ReleaseLinksTests.swift` (the Xcode project is generated by `Tools/test-app.sh` from the folder globs in `App/project.yml` and is gitignored, so new files need no project edit and there is no project file to stage).
- Modify: `App/Tests/App/KnownLimitationsTests.swift` (lines 92-97: doc comment and the pinned entry count), `App/Sources/App/KnownLimitations.swift` (doc comment lines 15-16; new entry after `system-launch-helper`, the last entry), `App/Sources/App/MacAppDuplicatorApp.swift` (lines 89-91: the Help `CommandGroup`).

**Interfaces:**
- Consumes: `KnownLimitation(id:title:detail:)` and `KnownLimitations.all` (`App/Sources/App/KnownLimitations.swift`); `KnownLimitationsMenuItem()` inside `CommandGroup(after: .help)` (`App/Sources/App/MacAppDuplicatorApp.swift:89-91`); `NSWorkspace.shared.open(_:)` from AppKit, which `import SwiftUI` already makes visible in that file (`App/Sources/Views/Wizard/InstalledAppsGrid.swift:19` calls `NSWorkspace.shared` with only `import SwiftUI`), so no import changes.
- Produces: `enum ReleaseLinks { static let repository: URL; static let latestRelease: URL }` whose `absoluteString`s are `https://github.com/cubbieblue16/MacAppDuplicator` and `https://github.com/cubbieblue16/MacAppDuplicator/releases/latest`; a Help menu item `Check for Updates…`, directly after `Known Limitations`, that hands `ReleaseLinks.latestRelease` to the default browser (the app itself makes no network request and runs no background check); `KnownLimitations.all` with 36 entries, the new last one with id `updates-manual`. Task 6's README and acceptance doc name the menu item and the entry. App tests: 361 → 363.

- [ ] **Step 1: Pin the new entry count.** In `App/Tests/App/KnownLimitationsTests.swift` replace lines 92-97:

```swift
    /// Phase 4 (web apps): the four web limits are present with their prescribed ids and titles, the earlier 20 are
    /// kept (35 in all with Phase 5's five and Phase 6's six), ids stay unique, and each entry states its point.
    func testPhase4WebEntriesStateTheirPoint() throws {
        let ids = KnownLimitations.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate known-limitation ids")
        XCTAssertEqual(ids.count, 35, "20 earlier, four web, five launcher and six helper entries")
```

with:

```swift
    /// Phase 4 (web apps): the four web limits are present with their prescribed ids and titles, the earlier 20 are
    /// kept (36 in all with Phase 5's five, Phase 6's six and Phase 7's one), ids stay unique, and each entry states
    /// its point.
    func testPhase4WebEntriesStateTheirPoint() throws {
        let ids = KnownLimitations.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate known-limitation ids")
        XCTAssertEqual(ids.count, 36, "20 earlier, four web, five launcher, six helper and one release entry")
```

The rest of the test (the four web topics) is unchanged. `testEntriesAreUniqueAndNonEmpty` (line 9, `>= 6`) and `testKeepsEveryPhase3EntryThePlanPrescribes` (`>= 20`) need no change.

- [ ] **Step 2: Run the known-limitation tests and watch them fail.**

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/KnownLimitationsTests 2>&1 | grep -oE 'XCTAssertEqual failed: \("35"\) is not equal to \("36"\)|\*\* TEST FAILED \*\*' | LC_ALL=C sort -u`
Expected: exactly these two lines:

```
** TEST FAILED **
XCTAssertEqual failed: ("35") is not equal to ("36")
```

- [ ] **Step 3: Add the `updates-manual` entry.** In `App/Sources/App/KnownLimitations.swift` replace the last two doc comment lines (15-16):

```swift
/// AppleLanguages, colour menu bar icon, New Window command, System Launch helper). Shown in the Known Limitations
/// window and linked from the wizard's compatibility line.
```

with:

```swift
/// AppleLanguages, colour menu bar icon, New Window command, System Launch helper). Phase 7 adds the manual-updates
/// limit (the app never updates itself; Help > Check for Updates… opens the GitHub releases page). Shown in the Known
/// Limitations window and linked from the wizard's compatibility line.
```

Then insert the new entry after the `system-launch-helper` entry. The file currently ends with that entry's closing `        ),`, then `    ]`, then `}`; the new entry goes between `        ),` and `    ]`:

```swift
        KnownLimitation(
            id: "updates-manual",
            title: "App Duplicator does not update itself",
            detail: "App Duplicator never checks for a newer version of itself, and nothing runs in the background to look for one. Help > Check for Updates… opens the GitHub releases page in your browser; to update, download the new .dmg, open it and drag the app over the copy you already have. Your shortcuts and the app's settings are kept."
        ),
```

The file must end with the new entry's `        ),`, then `    ]`, then `}`.

- [ ] **Step 4: Run the known-limitation tests.**

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/KnownLimitationsTests 2>&1 | tee "${TMPDIR:-/tmp}/p7-kl-tests.log" | tail -3`
Expected: the last line is `** TEST SUCCEEDED **`.

Run: `cd ~/Developer/MacAppDuplicator && grep -cE "Test Case .* passed" "${TMPDIR:-/tmp}/p7-kl-tests.log"`
Expected: `9` (the class's nine existing tests; none is added).

- [ ] **Step 5: Write the failing `ReleaseLinks` tests.** Create `App/Tests/Services/ReleaseLinksTests.swift`:

```swift
import XCTest
@testable import MacAppDuplicator

final class ReleaseLinksTests: XCTestCase {
    func testRepositoryIsTheGitHubProject() {
        XCTAssertEqual(ReleaseLinks.repository.absoluteString, "https://github.com/cubbieblue16/MacAppDuplicator")
    }

    func testLatestReleaseIsTheGitHubLatestReleasePage() {
        XCTAssertEqual(
            ReleaseLinks.latestRelease.absoluteString,
            "https://github.com/cubbieblue16/MacAppDuplicator/releases/latest"
        )
    }
}
```

- [ ] **Step 6: Run the new tests and watch them fail to compile.**

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/ReleaseLinksTests 2>&1 | grep -oE "error: cannot find 'ReleaseLinks' in scope|\*\* TEST FAILED \*\*" | LC_ALL=C sort -u`
Expected: exactly these two lines:

```
** TEST FAILED **
error: cannot find 'ReleaseLinks' in scope
```

- [ ] **Step 7: Write `App/Sources/Services/ReleaseLinks.swift`.**

```swift
import Foundation

/// The GitHub addresses behind Help → Check for Updates… (spec §7: Sparkle is deferred; releases are notarized DMGs on
/// GitHub Releases). Nothing here touches the network; the menu item hands the URL to the default browser.
enum ReleaseLinks {
    static let repository: URL = gitHub(path: "/cubbieblue16/MacAppDuplicator")
    static let latestRelease: URL = gitHub(path: "/cubbieblue16/MacAppDuplicator/releases/latest")

    private static func gitHub(path: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = path
        return components.url ?? URL(fileURLWithPath: "/")
    }
}
```

`components.url` cannot be nil for these literals (an `https` scheme, a host and a path that starts with `/`); the fallback exists only so the file has no force unwrap and no `try?`.

- [ ] **Step 8: Run the new tests.**

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/ReleaseLinksTests 2>&1 | tee "${TMPDIR:-/tmp}/p7-links-tests.log" | tail -3`
Expected: the last line is `** TEST SUCCEEDED **`.

Run: `cd ~/Developer/MacAppDuplicator && grep -cE "Test Case .* passed" "${TMPDIR:-/tmp}/p7-links-tests.log"`
Expected: `2`.

- [ ] **Step 9: Add Help → Check for Updates….** In `App/Sources/App/MacAppDuplicatorApp.swift` replace lines 89-91:

```swift
            CommandGroup(after: .help) {
                KnownLimitationsMenuItem()
            }
```

with:

```swift
            CommandGroup(after: .help) {
                KnownLimitationsMenuItem()
                Button("Check for Updates…") { NSWorkspace.shared.open(ReleaseLinks.latestRelease) }
            }
```

The title ends in the single character `…` (U+2026), as `New Shortcut…` at line 81 does. `NSWorkspace.shared.open(_:)` returns a `Bool` that a single-expression `Void` closure discards, so there is no warning. No other line in the file changes.

- [ ] **Step 10: Run the whole app suite and the source checks.**

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh 2>&1 | tee "${TMPDIR:-/tmp}/p7-app-tests.log" | tail -3`
Expected: the last line is `** TEST SUCCEEDED **`.

Run: `cd ~/Developer/MacAppDuplicator && grep -cE "Test Case .* passed" "${TMPDIR:-/tmp}/p7-app-tests.log"`
Expected: `363` (361 at `62aedeb` plus `ReleaseLinksTests`' two).

Run: `cd ~/Developer/MacAppDuplicator && grep -nE 'try\?|@unchecked|swiftlint:disable|nonisolated\(unsafe\)' App/Sources/Services/ReleaseLinks.swift App/Tests/Services/ReleaseLinksTests.swift App/Sources/App/KnownLimitations.swift App/Tests/App/KnownLimitationsTests.swift App/Sources/App/MacAppDuplicatorApp.swift`
Expected: no output.

Run: `cd ~/Developer/MacAppDuplicator && grep -nE 'URLSession|!' App/Sources/Services/ReleaseLinks.swift; grep -n 'URLSession' App/Sources/App/MacAppDuplicatorApp.swift`
Expected: no output (`ReleaseLinks.swift` contains no `!` at all, so no force unwrap, and neither file opens a network session).

Run: `cd ~/Developer/MacAppDuplicator && grep -c 'KnownLimitation($' App/Sources/App/KnownLimitations.swift && grep -c 'id: "updates-manual"' App/Sources/App/KnownLimitations.swift && grep -n -A1 'KnownLimitationsMenuItem()$' App/Sources/App/MacAppDuplicatorApp.swift`
Expected:

```
36
1
90:                KnownLimitationsMenuItem()
91-                Button("Check for Updates…") { NSWorkspace.shared.open(ReleaseLinks.latestRelease) }
```

Run: `cd ~/Developer/MacAppDuplicator && git status --porcelain`
Expected:

```
 M App/Sources/App/KnownLimitations.swift
 M App/Sources/App/MacAppDuplicatorApp.swift
 M App/Tests/App/KnownLimitationsTests.swift
?? App/Sources/Services/ReleaseLinks.swift
?? App/Tests/Services/ReleaseLinksTests.swift
```

- [ ] **Step 11: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add App/Sources/Services/ReleaseLinks.swift App/Tests/Services/ReleaseLinksTests.swift App/Sources/App/KnownLimitations.swift App/Tests/App/KnownLimitationsTests.swift App/Sources/App/MacAppDuplicatorApp.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -m "App: Help → Check for Updates… and the manual-updates known limitation" -m "ReleaseLinks holds the GitHub repository and latest-release URLs, built with URLComponents and no force unwrap. Help → Check for Updates…, after Known Limitations, hands the latest-release URL to the default browser through NSWorkspace; the app makes no network request and runs no background check (Sparkle stays deferred, spec §7). Known Limitations gains updates-manual (36 entries). ReleaseLinksTests adds 2 tests (363 app tests)." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Run: `cd ~/Developer/MacAppDuplicator && git log -1 --format=%s`
Expected: `App: Help → Check for Updates… and the manual-updates known limitation`

### Deviations

- The brief says `KnownLimitationsTests` asserts `>= 6`. That assertion exists (line 9) and stays, but `testPhase4WebEntriesStateTheirPoint` also pins the exact count at line 97 (35). Step 1 moves that pin to 36, as the constraint says to, and it is this task's failing check. No known-limitation test is added, so the app total is the brief's 363.
- The new id `updates-manual` is distinct from the existing `updates` (the target app updates itself; the shortcut does not) and `profile-updates` (compatibility profiles) entries. Its title calls the app "App Duplicator", as the other 35 entries and the Known Limitations window do, and it writes the menu path `Help > Check for Updates…` in the style of the entries' `System Settings > …` paths.
- The menu button is the constraint's code on one line. No import is added.
- The full suite runs once and is counted from a `tee` log instead of being run a second time to count.

---

### Task 6: Docs: README install and releasing sections, Phase 7 acceptance checklist, spec touch-ups

**Files:**
- Modify: `README.md`: insert `## Install` between the intro paragraph (line 3) and `## Phase 1 engine` (line 5); replace line 81 (the Known Limitations bullet); insert `## Releasing (maintainers)` between ``Acceptance checklist: `docs/acceptance/phase6-helper.md`.`` (line 157) and `## Core API used by the app` (line 159).
- Modify: `docs/superpowers/specs/2026-10-09-macos-app-duplicator-design.md` (line 244 in §7, line 280 in §9).
- Create: `docs/acceptance/phase7-release.md`.
- Unchanged: `.gitignore`. No `LICENSE` file, and no license is named anywhere.

**Interfaces:**
- Consumes: the script names, flags and exit codes of Tasks 2-4 (usage lines in Tasks 2-4); their output lines `release: macOS App Duplicator <version> (<build>)`, `release: secure timestamp ok: <label>`, `release: no get-task-allow entitlement: <label>`, `release: Gatekeeper verdicts:`, `release: done: dist/macOS-App-Duplicator-<version>.dmg`, `notarize: submission <id> status <status>`, `notarize: stapled and validated <path>`, `publish: notes with SHA-256 written to dist/release-notes-<tag>.md`, `publish: dry run; nothing was pushed or published` and `publish: released <tag>`; the `dist/SHA256SUMS` line format (`<sha256>  macOS-App-Duplicator-<version>.dmg`); `ReleaseLinks.latestRelease` and the known limitation `App Duplicator does not update itself` from Task 5.
- Produces: README `## Install` and `## Releasing (maintainers)`; README line 81 at 36 entries; spec lines 244 and 280; `docs/acceptance/phase7-release.md` (7 steps and a Record table), which the Acceptance gate points at.

Edit the README bottom-up (Releasing, then line 81, then Install) so the line numbers above stay valid, or match on the quoted anchor text.

- [ ] **Step 1: Run the doc checks and see them fail.**

Run: `cd ~/Developer/MacAppDuplicator && for p in '^## Install$' '^## Releasing \(maintainers\)$' 'Known Limitations \(36 entries since Phase 7' 'docs/acceptance/phase7-release\.md'; do printf '%s %s\n' "$(grep -cE "$p" README.md)" "$p"; done; grep -c 'Check for Updates…' docs/superpowers/specs/2026-10-09-macos-app-duplicator-design.md; if test -f docs/acceptance/phase7-release.md; then echo "acceptance doc present"; else echo "acceptance doc missing"; fi`
Expected:

```
0 ^## Install$
0 ^## Releasing \(maintainers\)$
0 Known Limitations \(36 entries since Phase 7
0 docs/acceptance/phase7-release\.md
0
acceptance doc missing
```

- [ ] **Step 2: Insert `## Releasing (maintainers)` into `README.md`.** Directly after the line ``Acceptance checklist: `docs/acceptance/phase6-helper.md`.`` and its blank line, and before `## Core API used by the app`, insert exactly this block followed by one blank line:

````markdown
## Releasing (maintainers)

A release is a Developer ID signed, notarized and stapled app inside a signed, notarized DMG on GitHub Releases. It needs a `Developer ID Application` identity in the login keychain, Xcode 26 or later, `xcodegen`, and `gh` logged in (`gh auth login`). Everything the scripts produce goes to `dist/`, which is git-ignored.

One-time setup: store the notarization credentials as a keychain profile. The scripts refer to it only by name (`MAD-notary` unless you pass `--profile`) and never take an Apple ID or password.

```sh
xcrun notarytool store-credentials MAD-notary --apple-id <your Apple ID> --team-id 4NQ2UVJ4EZ
xcrun notarytool history --keychain-profile MAD-notary   # exits 0 once the profile works
```

`store-credentials` prompts for an app-specific password; create one at appleid.apple.com (Sign-In and Security → App-Specific Passwords).

Each release:

1. Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `App/project.yml`, run the tests, commit as `Release: <version> (<build>)` and push it with `git push origin main`.
2. Build, notarize and package from the clean release commit:

   ```sh
   Tools/release.sh --identity "Developer ID Application: <name> (<team>)"
   ```

   It refuses a dirty tree, checks the keychain profile before building, builds the Release configuration, checks every signature for a secure timestamp and no `get-task-allow` entitlement, notarizes and staples the app, builds and signs `dist/macOS-App-Duplicator-<version>.dmg`, notarizes and staples the DMG, prints both Gatekeeper verdicts and writes `dist/SHA256SUMS`. `--profile NAME` uses another keychain profile, `--dry-run` prints the steps without running them, `--skip-notarize` builds an un-notarized DMG for testing (Gatekeeper rejects it) and `--allow-dirty` builds with uncommitted changes.
3. Tag the release commit: `git tag -a v<version> -m "v<version>"`.
4. Write the release notes in Markdown under `dist/` (for example `dist/notes-<version>.md`; the publish script refuses a tree with untracked files), check the run with `--dry-run`, then publish:

   ```sh
   Tools/publish-release.sh v<version> dist/macOS-App-Duplicator-<version>.dmg --notes dist/notes-<version>.md --dry-run
   Tools/publish-release.sh v<version> dist/macOS-App-Duplicator-<version>.dmg --notes dist/notes-<version>.md
   ```

   It checks that `gh` is logged in, that the tag points at `HEAD` and that the tree is clean, writes `dist/release-notes-v<version>.md` (your notes plus a `SHA-256` section), pushes the tag and creates the release with the DMG attached. `--title` sets a title other than the tag; `--dry-run` writes the notes copy and prints the push and `gh` commands instead of running them.

`Tools/notarize.sh <path>` and `Tools/make-dmg.sh <app>` also work on their own; each takes `--help`. `Tools/tests/release-scripts.sh` tests the four scripts without submitting anything to Apple or publishing anything to GitHub: stand-ins replace the build, signing, notary and `gh` tools, the only real `notarytool` calls name a keychain profile that does not exist, and the DMG checks build a real image from a fake app in a temporary folder.

Acceptance checklist: `docs/acceptance/phase7-release.md`.
````

- [ ] **Step 3: Replace README line 81.** The line that now reads

```markdown
- Help → Known Limitations (35 entries since Phase 6; the six profile entries are listed under Phase 3 profiles, the four web entries under Phase 4 web apps, the five launcher entries under Phase 5 files, folders and commands and the six helper entries under Phase 6 helper).
```

becomes exactly

```markdown
- Help → Known Limitations (36 entries since Phase 7; the six profile entries are listed under Phase 3 profiles, the four web entries under Phase 4 web apps, the five launcher entries under Phase 5 files, folders and commands, the six helper entries under Phase 6 helper and the manual-updates entry under Install). Help → Check for Updates… opens the GitHub releases page.
```

- [ ] **Step 4: Insert `## Install` into `README.md`.** Between the intro paragraph (line 3, ending `(Apple Silicon, macOS 26+).`) and `## Phase 1 engine`, insert exactly this block, keeping one blank line before and after it:

````markdown
## Install

1. Download `macOS-App-Duplicator-<version>.dmg` from the [latest release](https://github.com/cubbieblue16/MacAppDuplicator/releases/latest).
2. Open the DMG and drag `macOS App Duplicator.app` onto the `Applications` shortcut beside it.
3. Eject the DMG and open macOS App Duplicator from Applications.

From 0.7.0 the app and its DMG are notarized by Apple, so the first launch only shows macOS's one-time question about an app downloaded from the Internet; choose Open. Releases before 0.7.0 (the 0.3.0 to 0.6.0 zips) are not notarized, and on macOS 26 right-click (Control-click) → Open no longer gets them past Gatekeeper: open the app once, then choose Open Anyway in System Settings → Privacy & Security and confirm with your password or Touch ID.

Requirements: Apple silicon and macOS 26 or later.

App Duplicator does not update itself and never checks for updates in the background. Help → Check for Updates… opens the latest release page. To update, quit the app, open the new DMG and drag the app over your existing copy (onto the `Applications` shortcut if you installed it there), then choose Replace. Your shortcuts and settings are kept.

Each release's notes end with the DMG's SHA-256. To check a download, compare it with the output of `shasum -a 256 ~/Downloads/macOS-App-Duplicator-<version>.dmg`.
````

- [ ] **Step 5: Update the spec.** In `docs/superpowers/specs/2026-10-09-macos-app-duplicator-design.md`, line 244, which now reads

```markdown
- App bundle id `com.mikekuta.MacAppDuplicator`, display name "macOS App Duplicator". Sparkle deferred; releases via GitHub Releases + notarized DMG.
```

becomes exactly

```markdown
- App bundle id `com.mikekuta.MacAppDuplicator`, display name "macOS App Duplicator". Sparkle deferred; releases via GitHub Releases + notarized DMG. Help → Check for Updates… opens the GitHub releases page.
```

and line 280, which now reads

```markdown
- The main app is Developer ID signed, hardened runtime, notarized (`notarytool`), shipped as DMG. Keychain-stored notarization credentials are referenced by profile name only.
```

becomes exactly

```markdown
- The main app is Developer ID signed, hardened runtime, notarized (`notarytool`), shipped as DMG. Keychain-stored notarization credentials are referenced by profile name only (`Tools/notarize.sh`, `Tools/make-dmg.sh`, `Tools/release.sh`, `Tools/publish-release.sh`; profile `MAD-notary` by default).
```

Line 22 ("The only network action is the user-triggered "Check Profile Updates" …") and §12 item 7 (line 318) stay as they are.

- [ ] **Step 6: Create `docs/acceptance/phase7-release.md`** with exactly this content:

````markdown
# Phase 7 acceptance: release

Manual checks for the first notarized release, with Mike present: the notary keychain profile, a real `Tools/release.sh` run in which Apple notarizes the app and the DMG, the stapled tickets and Gatekeeper verdicts, a drag-install over the installed copy, Help → Check for Updates…, the GitHub release and a check of the published download. Run them in order on the `Release: 0.7.0 (6)` commit. Steps 1, 2, 6 and 7 use Mike's Apple ID, app-specific password or GitHub login, so only Mike runs them. Finder's Replace overwrites the installed 0.6.0 app (0.6.0 stays downloadable from GitHub Releases); downloads go to the Trash at the end, and nothing else is removed.

## Preconditions

- macOS 26 on Apple silicon with Xcode 26 or later (`xcrun notarytool --version` prints a version), `xcodegen` and `gh` on `PATH`.
- `gh auth status` reports a github.com login that can write to `cubbieblue16/MacAppDuplicator`.
- The signing identity is in the login keychain exactly once: `security find-identity -v -p codesigning | grep -c 'Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)'` prints `1`. Print only the count; the full listing shows certificate hashes.
- An app-specific password for the Apple ID, created at appleid.apple.com (Sign-In and Security → App-Specific Passwords), ready to paste at the prompt in Step 1. Do not save it in a file or type it on a command line.
- The repository is on `main` at the `Release: 0.7.0 (6)` commit with a clean tree: `git log -1 --format=%s` prints `Release: 0.7.0 (6)`, `git status --porcelain` prints nothing and `Tools/tests/release-scripts.sh 2>&1 | tail -1` prints `PASS 115 checks`.
- `~/Applications/macOS App Duplicator.app` is the installed 0.6.0 (About App Duplicator shows `Version 0.6.0 (5)`). Write down how many shortcuts its library window lists.
- In Terminal, from the repository (keep this window open; later steps use `$LOG`, `$APP` and `$DMG`):
  `cd ~/Developer/MacAppDuplicator`
  `LOG="${TMPDIR:-/tmp}/p7-release.log"`
  `APP="$PWD/.build/DerivedData/Build/Products/Release/macOS App Duplicator.app"`
  `DMG=dist/macOS-App-Duplicator-0.7.0.dmg`

## Step 1: Notary keychain profile

- [ ] **1.1** `xcrun notarytool store-credentials MAD-notary --apple-id <your Apple ID> --team-id 4NQ2UVJ4EZ`, with the Apple ID typed in place of `<your Apple ID>`, then paste the app-specific password at the prompt. notarytool validates the credentials with Apple and saves them in the login keychain under the profile name `MAD-notary`; any error stops the checklist here.
- [ ] **1.2** `xcrun notarytool history --keychain-profile MAD-notary > /dev/null; echo "exit=$?"` prints `exit=0`.
- [ ] **1.3** `Tools/release.sh --identity "Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)" --dry-run | grep -cE '^dry-run: (xcrun notarytool history|Tools/notarize\.sh) '` prints `3` (the profile check, then notarizing the app and the DMG). Run without the `| grep …` part, the first line reads `release: macOS App Duplicator 0.7.0 (6)` and no line mentions `--skip-notarize`.

## Step 2: Notarized release build

- [ ] **2.1** `Tools/release.sh --identity "Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)" 2>&1 | tee "$LOG"` runs to the end: a few minutes of build, then two notarizations that usually take a few minutes each while notarytool waits for Apple's verdict. The last line reads `release: done: dist/macOS-App-Duplicator-0.7.0.dmg`, and `grep -c '^release: done: ' "$LOG"` prints `1`. If the run stops on an `error:` line, record it and stop; when Apple did not accept a submission, its log is in `dist/notary-<id>.json`.
- [ ] **2.2** `grep -cE '^release: (secure timestamp ok|no get-task-allow entitlement): ' "$LOG"` prints `6` (both checks for the app, `Contents/Resources/Launcher` and `Contents/Resources/WebShell`).
- [ ] **2.3** `grep -E '^notarize: submission ' "$LOG"` prints two lines, the app's zip first and then the DMG, each ending `status Accepted`. Write both submission ids in the Record notes.
- [ ] **2.4** `grep -c '^notarize: stapled and validated ' "$LOG"` prints `2`.
- [ ] **2.5** After `release: Gatekeeper verdicts:` the app and the DMG are each `accepted` with `source=Notarized Developer ID`: `grep -cE ': accepted$' "$LOG"` prints `2` and `grep -c 'source=Notarized Developer ID' "$LOG"` prints `2`.
- [ ] **2.6** `cat dist/SHA256SUMS` prints one line: 64 hexadecimal characters, two spaces and `macOS-App-Duplicator-0.7.0.dmg`. Write the hash in the Record notes.

## Step 3: Stapled tickets, signatures and checksum

- [ ] **3.1** `xcrun stapler validate "$APP"; echo "exit=$?"` and `xcrun stapler validate "$DMG"; echo "exit=$?"` each end with `exit=0`.
- [ ] **3.2** `spctl --assess --type execute -v "$APP"` prints a line ending `macOS App Duplicator.app: accepted` and then `source=Notarized Developer ID`.
- [ ] **3.3** `spctl --assess --type open --context context:primary-signature -v "$DMG"` prints `dist/macOS-App-Duplicator-0.7.0.dmg: accepted` and then `source=Notarized Developer ID`.
- [ ] **3.4** `codesign -dvv "$DMG" 2>&1 | grep -E '^(Authority=Developer ID Application|Timestamp=)'` prints `Authority=Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)` and one `Timestamp=` line. Grep these fields only; the full output includes certificate details.
- [ ] **3.5** `(cd dist && shasum -a 256 -c SHA256SUMS)` prints `macOS-App-Duplicator-0.7.0.dmg: OK`.

## Step 4: Install over the installed copy

- [ ] **4.1** Quit macOS App Duplicator (⌘Q) if it is running: `pgrep -lf 'macOS App Duplicator.app/Contents/MacOS'` prints nothing.
- [ ] **4.2** `open "$DMG"`: Finder mounts `macOS App Duplicator`, and its window shows `macOS App Duplicator.app` and an `Applications` shortcut. `readlink "/Volumes/macOS App Duplicator/Applications"` prints `/Applications`.
- [ ] **4.3** Open a second Finder window on the Applications folder in your home folder (Go → Home, then `Applications`). Drag `macOS App Duplicator.app` from the DMG window onto the `macOS App Duplicator.app` there and choose `Replace`. Do not drop it on the DMG's `Applications` shortcut: that is `/Applications`, and it would add a second copy instead of replacing the installed one.
- [ ] **4.4** Eject the DMG: `hdiutil detach "/Volumes/macOS App Duplicator"` (or the eject button in Finder's sidebar).
- [ ] **4.5** `open "$HOME/Applications/macOS App Duplicator.app"`: the library window opens with no dialog. A locally built DMG carries no quarantine flag, so no first-launch question is expected here; Step 7 checks a downloaded copy.
- [ ] **4.6** About App Duplicator shows `Version 0.7.0 (6)`, and the library lists as many shortcuts as written down in Preconditions.
- [ ] **4.7** `codesign -dvv "$HOME/Applications/macOS App Duplicator.app" 2>&1 | grep -c '^Timestamp='` prints `1`, and `spctl --assess --type execute -v "$HOME/Applications/macOS App Duplicator.app"` prints `accepted` and `source=Notarized Developer ID`.

## Step 5: Help menu

- [ ] **5.1** Help → Check for Updates… opens `https://github.com/cubbieblue16/MacAppDuplicator/releases/latest` in the default browser. Until Step 6 publishes 0.7.0 the page shows v0.6.0 (or GitHub's not-found page if the repository is private and the browser is not signed in to GitHub).
- [ ] **5.2** Help → Known Limitations lists `App Duplicator does not update itself`, and its text names Help > Check for Updates….

## Step 6: Publish v0.7.0

- [ ] **6.1** `git push origin main`, then `git status -sb | head -1` prints `## main...origin/main` with no `ahead` count.
- [ ] **6.2** `gh repo view cubbieblue16/MacAppDuplicator --json isPrivate --jq .isPrivate` prints `true` or `false`. Spec §12 item 7 asks for a public repository; whether to make it public now is Mike's decision. To make it public: `gh repo edit cubbieblue16/MacAppDuplicator --visibility public --accept-visibility-change-consequences`, after which the same `gh repo view` command prints `false`. Record the decision.
- [ ] **6.3** Write the release notes to `dist/notes-0.7.0.md` (Markdown; `dist/` is git-ignored, so the tree stays clean for the publish script): what changed since 0.6.0 (the notarized DMG, Help → Check for Updates…), the install steps from the README's Install section, and that 0.3.0 to 0.6.0 are not notarized.
- [ ] **6.4** `git tag -a v0.7.0 -m "v0.7.0"`, then `[ "$(git rev-parse 'v0.7.0^{commit}')" = "$(git rev-parse HEAD)" ] && echo "tag at HEAD"` prints `tag at HEAD`.
- [ ] **6.5** `Tools/publish-release.sh v0.7.0 "$DMG" --notes dist/notes-0.7.0.md --dry-run` prints `publish: notes with SHA-256 written to dist/release-notes-v0.7.0.md`, `dry-run: git push origin v0.7.0`, a `dry-run: gh release create v0.7.0 …` line ending `--verify-tag`, and `publish: dry run; nothing was pushed or published`. `tail -1 dist/release-notes-v0.7.0.md` prints four spaces and then the same line as `dist/SHA256SUMS`.
- [ ] **6.6** `Tools/publish-release.sh v0.7.0 "$DMG" --notes dist/notes-0.7.0.md` pushes the tag, uploads the DMG and ends with `publish: released v0.7.0`.
- [ ] **6.7** `gh release view v0.7.0 --json tagName,assets --jq '.tagName, .assets[].name'` prints `v0.7.0` and `macOS-App-Duplicator-0.7.0.dmg`.

## Step 7: Published download

- [ ] **7.1** `DL=$(mktemp -d "${TMPDIR:-/tmp}/p7-download.XXXXXX") && gh release download v0.7.0 --pattern 'macOS-App-Duplicator-0.7.0.dmg' --dir "$DL" && ls "$DL"` lists `macOS-App-Duplicator-0.7.0.dmg`.
- [ ] **7.2** `[ "$(shasum -a 256 "$DL/macOS-App-Duplicator-0.7.0.dmg" | cut -d ' ' -f 1)" = "$(cut -d ' ' -f 1 dist/SHA256SUMS)" ] && echo "sha256 match"` prints `sha256 match`, and the release page's `SHA-256` section shows the same hash.
- [ ] **7.3** Help → Check for Updates… now opens the v0.7.0 release page. Download `macOS-App-Duplicator-0.7.0.dmg` from it in the browser (a browser download carries the quarantine flag a user's copy has; the `gh` download in 7.1 is only for the checksum). `spctl --assess --type open --context context:primary-signature -v ~/Downloads/macOS-App-Duplicator-0.7.0.dmg` prints `accepted` and `source=Notarized Developer ID`.
- [ ] **7.4** Quit macOS App Duplicator, open the downloaded DMG and drag its app over `~/Applications/macOS App Duplicator.app` again as in 4.3 (the same build, now carrying the quarantine flag), choose `Replace` and eject the DMG.
- [ ] **7.5** `open "$HOME/Applications/macOS App Duplicator.app"`: macOS asks once whether to open an app downloaded from the Internet; choose Open and the library window appears. No warning says the app cannot be opened, and Privacy & Security offers no Open Anyway step. Quit and open it again: no question this time.

## Teardown

- No `macOS App Duplicator` volume stays mounted: `hdiutil info | grep -c '/Volumes/macOS App Duplicator'` prints `0`.
- Keep `dist/` (git-ignored): the DMG, `SHA256SUMS`, `notes-0.7.0.md` and `release-notes-v0.7.0.md` are the release record.
- In Finder, move to the Trash the `$DL` folder (`open -R "$DL"` shows it) and `~/Downloads/macOS-App-Duplicator-0.7.0.dmg`. Do not empty the Trash as part of this checklist.
- `git status --porcelain` prints nothing.

## Record

| Step | Date | Result | Notes |
|------|------|--------|-------|
| 1 | | | |
| 2 | | | |
| 3 | | | |
| 4 | | | |
| 5 | | | |
| 6 | | | |
| 7 | | | |
````

- [ ] **Step 7: Run the doc checks again.**

Run: the Step 1 command.
Expected:

```
1 ^## Install$
1 ^## Releasing \(maintainers\)$
1 Known Limitations \(36 entries since Phase 7
1 docs/acceptance/phase7-release\.md
1
acceptance doc present
```

Run: `cd ~/Developer/MacAppDuplicator && grep '^## ' README.md`
Expected:

```
## Install
## Phase 1 engine
## Phase 2 library app
## Phase 3 profiles
## Phase 4 web apps
## Phase 5 launchers
## Phase 6 helper
## Releasing (maintainers)
## Core API used by the app
```

Run: `cd ~/Developer/MacAppDuplicator && sed -n '244p;280p' docs/superpowers/specs/2026-10-09-macos-app-duplicator-design.md`
Expected: the two new lines from Step 5, exactly.

Every flag the Releasing section names exists in the four scripts:

Run: `cd ~/Developer/MacAppDuplicator && sed -n '/^## Releasing (maintainers)$/,/^## Core API used by the app$/p' README.md | grep -oE -- '--[a-z][a-z-]+' | LC_ALL=C sort -u | while read -r f; do printf '%s %s\n' "$f" "$(cat Tools/notarize.sh Tools/make-dmg.sh Tools/release.sh Tools/publish-release.sh | grep -c -- "$f")"; done`
Expected: 11 lines, `--allow-dirty`, `--apple-id`, `--dry-run`, `--help`, `--identity`, `--keychain-profile`, `--notes`, `--profile`, `--skip-notarize`, `--team-id` and `--title` in that order, each followed by a number greater than 0.

No license, no certificate hash, no Apple ID:

Run: `cd ~/Developer/MacAppDuplicator && sed -n '/^## Install$/,/^## Phase 1 engine$/p;/^## Releasing (maintainers)$/,/^## Core API used by the app$/p' README.md | grep -ciE 'licen[cs]e|[0-9a-f]{40}|@[a-z0-9.-]+\.[a-z]+'; grep -ciE 'licen[cs]e|[0-9a-f]{40}|@[a-z0-9.-]+\.[a-z]+' docs/acceptance/phase7-release.md; if test -e LICENSE; then echo "LICENSE exists"; else echo "no LICENSE"; fi`
Expected: `0`, `0`, `no LICENSE`.

Run: `cd ~/Developer/MacAppDuplicator && git status --porcelain`
Expected:

```
 M README.md
 M docs/superpowers/specs/2026-10-09-macos-app-duplicator-design.md
?? docs/acceptance/phase7-release.md
```

- [ ] **Step 8: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add README.md docs/superpowers/specs/2026-10-09-macos-app-duplicator-design.md docs/acceptance/phase7-release.md && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -m "Docs: README install and releasing sections, Phase 7 acceptance checklist, spec touch-ups" -m "README gains Install (download the DMG, drag to Applications, notarized from 0.7.0, Open Anyway for the un-notarized 0.3.0-0.6.0 zips on macOS 26, manual updates through Help → Check for Updates…, SHA-256 check) and Releasing (maintainers) (the MAD-notary keychain profile, Tools/release.sh, the tag, Tools/publish-release.sh), and the Known Limitations count moves to 36. docs/acceptance/phase7-release.md is the Mike-present checklist: profile, notarized release run, stapler and spctl checks, drag-install, Help menu, push, visibility decision, tag v0.7.0, publish and a checksum of the published download. Spec §7 and §9 name the Help item and the release scripts. No license is added or named." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Run: `cd ~/Developer/MacAppDuplicator && git log -1 --format=%s`
Expected: `Docs: README install and releasing sections, Phase 7 acceptance checklist, spec touch-ups`

### Deviations

- The constraint says releases before 0.7.0 "need right-click → Open once". Since macOS 15, Control-click → Open no longer overrides Gatekeeper; on macOS 26 the user opens the app once and then chooses Open Anyway in System Settings → Privacy & Security. The README says that instead.
- The constraint says the first launch of a notarized download "opens without a Gatekeeper prompt". A notarized app that carries the quarantine flag still gets macOS's one-time downloaded-from-the-Internet question (with no block and no Open Anyway step), so the README and acceptance Step 7.5 say that. Acceptance Step 4 launches a locally built DMG's copy, which carries no quarantine flag, so it expects no dialog at all.
- README line 81 (the Known Limitations count, 35 → 36) is updated as well, so the README matches Task 5.
- The Releasing steps and acceptance Step 6.1 push `main` before tagging: `publish-release.sh` pushes only the tag.
- Release notes go under the git-ignored `dist/` because `publish-release.sh` refuses a tree with untracked files.
- Acceptance Step 4 drags the app over `~/Applications/macOS App Duplicator.app` (where the 0.6.0 copy is installed), not onto the DMG's `/Applications` shortcut, which would leave a second copy.
- Acceptance Step 6.2 records the repository visibility decision (spec §12 item 7 says "GitHub repo public"); the plan does not make it public. It uses the `isPrivate` JSON field, and Step 6.7 uses `tagName` and `assets`; the planner checked that the local `gh` lists all three fields.
- Acceptance Step 7 adds a browser download (Steps 7.3-7.5) to the constraint's `gh release download` checksum, because only a browser download carries the quarantine flag that triggers Gatekeeper's first-launch check.
- Spec line 22 ("The only network action is the user-triggered "Check Profile Updates" …") is left alone: Check for Updates… hands a URL to the browser and the app itself makes no request. Recorded in Deferred.

---

### Task 7: Release: 0.7.0 (6)

**Files:**
- Modify: `App/project.yml` (line 56 `CURRENT_PROJECT_VERSION` "5" → "6"; line 57 `MARKETING_VERSION` "0.6.0" → "0.7.0").
- Generated, git-ignored, never staged: `dist/macOS-App-Duplicator-0.7.0.dmg`, `dist/SHA256SUMS`.

**Interfaces:**
- Consumes: `Tools/release.sh --identity "<display name>" --skip-notarize --allow-dirty` (Task 4), which runs `Tools/build-app.sh --identity "<display name>" --configuration Release` (Task 1) and `Tools/make-dmg.sh` (Task 3); `Tools/test-app.sh`; `Tools/tests/release-scripts.sh` (Tasks 1-4).
- Produces: the commit `Release: 0.7.0 (6)`, and a Developer ID signed, not yet notarized `dist/macOS-App-Duplicator-0.7.0.dmg` that proves the build, signing and packaging chain end to end. Acceptance Step 2 rebuilds the release with notarization while Mike is present.

- [ ] **Step 1: Confirm the version is still 0.6.0 (5).** This is the failing check for the 0.7.0 (6) target.

Run: `cd ~/Developer/MacAppDuplicator && grep -nE '^        (CURRENT_PROJECT_VERSION|MARKETING_VERSION): ' App/project.yml`
Expected:
```
56:        CURRENT_PROJECT_VERSION: "5"
57:        MARKETING_VERSION: "0.6.0"
```
If either line number or value differs, stop and report BLOCKED: Tasks 1-6 do not touch this file.

- [ ] **Step 2: Bump the version.** In `App/project.yml`, change line 56 to `        CURRENT_PROJECT_VERSION: "6"` and line 57 to `        MARKETING_VERSION: "0.7.0"`. Keep the 8-space indentation and the double quotes, and change nothing else in the file.

Run: `cd ~/Developer/MacAppDuplicator && grep -nE '^        (CURRENT_PROJECT_VERSION|MARKETING_VERSION): ' App/project.yml && git diff --stat`
Expected:
```
56:        CURRENT_PROJECT_VERSION: "6"
57:        MARKETING_VERSION: "0.7.0"
 App/project.yml | 4 ++--
 1 file changed, 2 insertions(+), 2 deletions(-)
```

- [ ] **Step 3: Run every suite on the bumped tree.** The bump commit is the release commit, so every suite must pass on it. Integration (5, gated) is not re-run, as in Phases 1-6.

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh 2>&1 | tee "${TMPDIR:-/tmp}/p7-bump-app-tests.log" | tail -3`
Expected: the last line is `** TEST SUCCEEDED **`.

Run: `cd ~/Developer/MacAppDuplicator && grep -cE "Test Case .* passed" "${TMPDIR:-/tmp}/p7-bump-app-tests.log"`
Expected: `363`

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: a line starting `Executed 286 tests, with 0 failures`.

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter WebShellTests 2>&1 | grep "'Selected tests' passed" -A1`
Expected: the output includes a line starting `Executed 56 tests, with 0 failures`.

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter CompatProfilesTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: a line starting `Executed 37 tests, with 0 failures`.

Run: `cd ~/Developer/MacAppDuplicator && Tools/tests/release-scripts.sh 2>&1 | tail -1`
Expected: `PASS 115 checks` (the real-repository `--dry-run` checks pass `--allow-dirty`, so the uncommitted bump does not trip the clean-tree refusal).

- [ ] **Step 4: Prove the release diff stays inside the File structure list.** The first count is the 15 files that Tasks 1-7 change. The second count is any other changed file, and must be 0; the plan file itself is allowed, in case it was committed after `62aedeb`. The third count is a sweep of the added Swift lines for constructs the implementer contract forbids.

Run: `cd ~/Developer/MacAppDuplicator && R='App/project\.yml|App/Sources/App/(KnownLimitations|MacAppDuplicatorApp)\.swift|App/Sources/Services/ReleaseLinks\.swift|App/Tests/App/KnownLimitationsTests\.swift|App/Tests/Services/ReleaseLinksTests\.swift|README\.md|Tools/(build-app|notarize|make-dmg|release|publish-release)\.sh|Tools/tests/release-scripts\.sh|docs/acceptance/phase7-release\.md|docs/superpowers/specs/2026-10-09-macos-app-duplicator-design\.md' && git diff 62aedeb --name-only | grep -cxE "$R"; git diff 62aedeb --name-only | grep -vxE "$R|docs/superpowers/plans/2026-10-11-phase7-release\.md" | grep -c .; git diff 62aedeb -- '*.swift' | grep -E '^\+' | grep -cE 'try\?|@unchecked|swiftlint:disable|nonisolated\(unsafe\)'; git status --porcelain`
Expected:
```
15
0
0
 M App/project.yml
```

- [ ] **Step 5: Build, sign and package 0.7.0 without notarizing.** A Release build, three signatures and `hdiutil` take several minutes, so run this with the Bash tool timeout at 600000 ms (there is no `timeout` binary). If the tool call still times out, run the same command once with `run_in_background: true` and wait for its completion notice. Never start a second build while one is running. Never add `--profile` and never drop `--skip-notarize`: notarization is Mike-present (acceptance Step 2). Never print the log whole, because Xcode's build output inside it can include codesign command lines; read it only with the greps in Step 6.

Run: `cd ~/Developer/MacAppDuplicator && Tools/release.sh --identity "Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)" --skip-notarize --allow-dirty > "${TMPDIR:-/tmp}/p7-release.log" 2>&1; echo "exit=$?"; tail -1 "${TMPDIR:-/tmp}/p7-release.log"`
Expected:
```
exit=0
release: done: dist/macOS-App-Duplicator-0.7.0.dmg
```

If the exit code is not 0, print only the script's own diagnostic lines: `cd ~/Developer/MacAppDuplicator && grep -E '^(error|warning|hdiutil|codesign)' "${TMPDIR:-/tmp}/p7-release.log" | sed -E 's/--sign [^ ]+/--sign <redacted>/g' | head -10`. Then stop and report BLOCKED. Do not commit, leave `App/project.yml` modified, and include the matching case below:
- **No secure timestamp.** `release.sh` stops on its `Timestamp=` check. This means D1 (Task 1's `OTHER_CODE_SIGN_FLAGS=--timestamp` and `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`) did not override Xcode's `--timestamp=none`. Add the redacted codesign line from the newest build log: `cd ~/Developer/MacAppDuplicator && LOGF="$(ls -t .build/DerivedData/Logs/Build/*.xcactivitylog | head -1)" && gunzip -c "$LOGF" | tr '\r' '\n' | grep 'codesign --force' | grep 'macOS App Duplicator.app' | sed -E 's/--sign [^ ]+/--sign <redacted>/g' | head -3`.
- **Keychain.** The output shows `errSecInternalComponent` or the run waits on a keychain prompt. The login keychain is locked or codesign lacks access to the key, and Mike has to unlock it. Do not retry in a loop.
- **hdiutil.** The output shows `hdiutil:` errors (for example `Device not configured` or `Operation not permitted` from a sandboxed shell). Report those lines and never retry with `sudo`.

- [ ] **Step 6: Check the release log.** Each line prints a count, then the pattern it counts.

Run: `cd ~/Developer/MacAppDuplicator && L="${TMPDIR:-/tmp}/p7-release.log" && for p in '^release: macOS App Duplicator 0\.7\.0 \(6\)$' '^warning: --allow-dirty: ' '^release: secure timestamp ok: ' '^release: no get-task-allow entitlement: ' '^warning: --skip-notarize: ' 'checking the notarytool keychain profile' '^notarize: ' 'macOS App Duplicator\.app: rejected$' '^release: dist/SHA256SUMS$'; do printf '%s  %s\n' "$(grep -cE "$p" "$L")" "$p"; done`
Expected:
```
1  ^release: macOS App Duplicator 0\.7\.0 \(6\)$
1  ^warning: --allow-dirty: 
3  ^release: secure timestamp ok: 
3  ^release: no get-task-allow entitlement: 
2  ^warning: --skip-notarize: 
0  checking the notarytool keychain profile
0  ^notarize: 
1  macOS App Duplicator\.app: rejected$
1  ^release: dist/SHA256SUMS$
```
How to read these counts:
- The timestamp and get-task-allow counts cover the app, `Contents/Resources/Launcher` and `Contents/Resources/WebShell`.
- The two zeros prove that `--skip-notarize` never reached `notarytool`.
- The rejected app verdict is expected, because the app is signed but not notarized.

Run: `cd ~/Developer/MacAppDuplicator && grep -E '^  (dist/macOS-App-Duplicator-0\.7\.0\.dmg: |source=)' "${TMPDIR:-/tmp}/p7-release.log"`
Expected: three lines:
- The first line is exactly `  source=Unnotarized Developer ID` (the app).
- The second starts `  dist/macOS-App-Duplicator-0.7.0.dmg: ` and ends with `rejected` or `accepted`.
- The third is that DMG's `  source=` line.

Copy lines two and three into the report. Either DMG verdict passes here. Gatekeeper's verdict on a signed DMG that has not been notarized is not what this task tests; acceptance Step 2 requires `accepted` and `source=Notarized Developer ID` for both items on the notarized build.

- [ ] **Step 7: Verify the checksum file.**

Run: `cd ~/Developer/MacAppDuplicator && (cd dist && shasum -a 256 -c SHA256SUMS) && grep -cE '^[0-9a-f]{64}  macOS-App-Duplicator-0\.7\.0\.dmg$' dist/SHA256SUMS`
Expected: `macOS-App-Duplicator-0.7.0.dmg: OK` with no `FAILED` line, then `1`.

- [ ] **Step 8: Check the DMG's own signature.** Grep single fields only; the timestamp value is masked.

Run: `cd ~/Developer/MacAppDuplicator && codesign -dvv dist/macOS-App-Duplicator-0.7.0.dmg 2>&1 | grep -E '^(Authority=Developer ID Application|Timestamp=)' | sed -E 's/^Timestamp=.*/Timestamp=<present>/' && codesign --verify --verbose=2 dist/macOS-App-Duplicator-0.7.0.dmg 2>&1`
Expected:
```
Authority=Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)
Timestamp=<present>
dist/macOS-App-Duplicator-0.7.0.dmg: valid on disk
dist/macOS-App-Duplicator-0.7.0.dmg: satisfies its Designated Requirement
```

- [ ] **Step 9: Check the app inside the DMG.** These checks run on the copy users install. The DMG is mounted read-only at a `mktemp -d` mount point without showing it in Finder, and it is always detached, with a `-force` fallback.

Run: `cd ~/Developer/MacAppDuplicator && MNT="$(mktemp -d "${TMPDIR:-/tmp}/p7-mnt.XXXXXX")" && hdiutil attach -nobrowse -readonly -mountpoint "$MNT" dist/macOS-App-Duplicator-0.7.0.dmg >/dev/null && A="$MNT/macOS App Duplicator.app" && /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$A/Contents/Info.plist" && /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$A/Contents/Info.plist" && readlink "$MNT/Applications" && for p in "$A" "$A/Contents/Resources/Launcher" "$A/Contents/Resources/WebShell"; do printf '%s %s %s %s\n' "$(basename "$p")" "$(codesign -dvv "$p" 2>&1 | grep -c '^Timestamp=')" "$(codesign -d --entitlements - "$p" 2>&1 | grep -c 'get-task-allow')" "$(codesign -dvv "$p" 2>&1 | grep -cE 'flags=0x[0-9a-f]+\([a-z,-]*runtime')"; done && codesign --verify --deep --strict "$A" && echo verify-ok; hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach -force "$MNT" >/dev/null; rmdir "$MNT" && echo detached`
Expected:
```
0.7.0
6
/Applications
macOS App Duplicator.app 1 0 1
Launcher 1 0 1
WebShell 1 0 1
verify-ok
detached
```
Each part line reads: name, `Timestamp=` count, `get-task-allow` count, hardened-runtime flag count.

- [ ] **Step 10: Commit.** Stage `App/project.yml` only. `dist/` is git-ignored, and the DMG and checksum file are never staged.

```bash
cd ~/Developer/MacAppDuplicator && git add App/project.yml && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -m "Release: 0.7.0 (6)" -m "Bump MARKETING_VERSION to 0.7.0 and CURRENT_PROJECT_VERSION to 6. Every suite passes on the bumped tree (App 363, Core 286, WebShell 56, CompatProfiles 37, release scripts 115 checks). Tools/release.sh --skip-notarize builds, signs and packages dist/macOS-App-Duplicator-0.7.0.dmg with a secure timestamp and no get-task-allow entitlement on the app, Launcher and WebShell; notarization, tagging and publishing are the Mike-present steps in docs/acceptance/phase7-release.md." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Run: `cd ~/Developer/MacAppDuplicator && git log -1 --format=%s && git status --porcelain | grep -c . ; test -f dist/macOS-App-Duplicator-0.7.0.dmg && test -f dist/SHA256SUMS && git check-ignore -q dist/macOS-App-Duplicator-0.7.0.dmg && echo artifacts-present-and-ignored`
Expected:
```
Release: 0.7.0 (6)
0
artifacts-present-and-ignored
```
Do not push and do not tag. `git push origin main`, the `v0.7.0` tag and the GitHub release are acceptance Step 6.

### Deviations

- The brief's order is kept: bump, tests, `release.sh --skip-notarize --allow-dirty`, then commit. `--allow-dirty` is needed because the bump is still uncommitted at build time. Committing only after a verified build means a failed build leaves nothing committed.
- The implementer contract limits release tooling to the `--help`, `--dry-run` and missing-profile paths. The brief's item 7 nevertheless calls for this real `--skip-notarize` build, which runs `xcodebuild`, `codesign --sign` and `hdiutil create`, so Step 5 follows the brief. `notarytool` is still never reached: Step 6 asserts zero `notarize:` and profile-check lines.
- The DMG's Gatekeeper verdict is recorded, not asserted. The app's `rejected` / `Unnotarized Developer ID` verdict is asserted, because it is deterministic for a signed app that has not been notarized.
- The release log goes to a `TMPDIR` file and only counts and single fields are printed, because Xcode's output can carry codesign command lines that name the identity by hash.
- Step 9's per-part signature check runs on the app inside the mounted DMG, which is the artifact users install, rather than on the build folder.
- Step 4's changed-file allow-list is added to prove that Phase 7 changed exactly the File structure list.
- Core, WebShell and CompatProfiles are re-run even though Phase 7 does not touch them, because this commit is the release commit. Integration is not re-run.

---

## Self-review

**Spec coverage.** These are the lines of `docs/superpowers/specs/2026-10-09-macos-app-duplicator-design.md` that the brief names:

| Spec line | Covered by | How |
|---|---|---|
| 5 | Tasks 1, 2, 3, 4, 7 | Developer ID builds get a secure timestamp and no `get-task-allow` (1). The app and DMG are notarized, stapled and validated (2). The signed DMG holds the app and an Applications symlink (3). `release.sh` and `publish-release.sh` drive the release (4). The 0.7.0 (6) build goes through the whole chain (7). |
| 43 | Tasks 2-4 | `release.sh` builds the notarized, stapled DMG and `publish-release.sh` attaches it to the GitHub release. |
| 244 | Tasks 4, 5, 6 | Updates stay manual. Help → Check for Updates… opens the latest-release page, and the `updates-manual` known limitation says so (5). The releases page exists once `publish-release.sh` has run (4). Line 244 gains the Check for Updates… sentence (6). |
| 280 | Tasks 1, 2, 4, 6 | Hardened runtime with a secure timestamp on every signature (1). Notarization uses a keychain profile referenced by name (2). `release.sh` checks the signatures before notarizing (4). Line 280 names the four scripts and the `MAD-notary` default (6). |
| 318 | Tasks 2-4, 6; Acceptance gate | §12 item 7. The scripts come from Tasks 2-4, the README and acceptance checklist from Task 6, and the notarized run from the Mike-present Acceptance gate. Making the repository public is Mike's decision, recorded in acceptance Step 6.2. |

**Brief coverage.** Brief items 1-7 map one to one onto Tasks 1-7, in the same order.

**Global constraint coverage:**

| Constraint | Where |
|---|---|
| Bash scripts in `Tools/` with `set -euo pipefail`, `--help` and exit codes 64/69/1 | Tasks 2-4 (one script each) and Task 1's harness; checked by `Tools/tests/release-scripts.sh` |
| Secure timestamp | Task 1 (`build-app.sh`); Task 4 (`release.sh` `Timestamp=` and `get-task-allow` checks); Task 7 Steps 6, 8, 9 on the real build |
| Keychain profile by name only, default `MAD-notary` | Tasks 2, 4, 6 |
| Notarize, DMG, release and publish scripts | Tasks 2, 3, 4, 4 |
| Help → Check for Updates…; known limitation `updates-manual` | Task 5 (README count in Task 6) |
| README sections, acceptance doc, spec lines 244 and 280 | Task 6 |
| Version bump last | Task 7 |
| Never commit `dist/`, `.dmg` or `.zip` | `.gitignore` already ignores `/dist/` and `*.dmg`; `notarize.sh` deletes its staged zip on exit (Task 2); Task 7 Step 10 checks the DMG is ignored |

The implementer contract's release-tooling rules hold in every Run line: no `notarytool submit` or `store-credentials`, no identity hash printed, no `LICENSE`, no push, and test writes only under `mktemp -d`. The one real build-and-sign run is Task 7 Step 5, which the brief's item 7 calls for. Task 6 Step 7 greps the docs for a `LICENSE` file, identity hashes and Apple IDs.

**Scan for unfinished text.** `grep -nE 'TODO|TBD|FIXME|placeholder' docs/superpowers/plans/2026-10-11-phase7-release.md` has exactly one hit, this line.

**Consistency:**
- Script names and flags match across the Global Constraints, each script's usage text and checks, the README `## Releasing (maintainers)` section and the acceptance doc. `release.sh` and `publish-release.sh` also take `--dry-run`. Task 6 Step 7 checks that the README documents all 11 flags.
- These names are used identically in Tasks 2-7 and the acceptance doc:
  - DMG: `dist/macOS-App-Duplicator-<version>.dmg`
  - checksum file: `dist/SHA256SUMS` (DMG named by basename)
  - profile: `MAD-notary`
  - annotated tag: `v<version>`, peeled with `^{commit}`
  - identity: `Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)`
- Exit codes: 64 for usage errors, 69 for a missing tool, profile or login, 1 for a failed step.
- Swift names: `ReleaseLinks` (Task 5) is referenced by the Help button and its 2 tests under the same names; the id `updates-manual` and the count 36 match the README (Task 6).

**Test totals:**

| Suite | At `62aedeb` | After Phase 7 | Changed by |
|---|---|---|---|
| Core (`DuplicatorCoreTests`) | 286 | 286 | none; re-run in Task 7 |
| WebShell | 56 | 56 | none; re-run in Task 7 |
| CompatProfiles | 37 | 37 | none; re-run in Task 7 |
| Integration (gated) | 5 | 5 | none; not re-run |
| App (`Tools/test-app.sh`) | 361 | 363 | Task 5: +2 `ReleaseLinksTests`; one `KnownLimitationsTests` assertion 35 → 36 |
| `Tools/tests/release-scripts.sh` | none | 115 checks | cumulative 4 (Task 1), 35 (Task 2), 59 (Task 3), 115 (Task 4) |

**What the planner verified (read-only).**
- Checked: `bash -n` on every script and test block, and each script's `--help`, usage-error and `--dry-run` paths.
- Not checked: the 4/35/59/115 check totals were counted from the plan's test code, because the planner did not run the harness end to end. Its missing-profile check calls the real `xcrun notarytool history`, which the planner may not run.
- Not yet proven: whether D1 yields `Timestamp=` on all three signatures. Task 7's real build is the first proof.

**Execution notes:**
- Commit this plan before Task 1. Every task's expected `git status --porcelain` output, and `release.sh`'s clean-tree refusal, assume that the plan is not an untracked file.
- Run the tasks in order. Task 4's checks read the Task 2 and 3 scripts, Task 6 documents Task 4's flags, and Task 7 needs all of them.

## Acceptance gate

Phase 7 is accepted when every box in `docs/acceptance/phase7-release.md` (Task 6) is ticked and its Record table is filled in. Implementers stop after Task 7. Everything else needs Mike present, because it uses his Apple ID, app-specific password, login keychain and GitHub account:

1. **Profile.** `xcrun notarytool store-credentials MAD-notary …` and the `history` check (acceptance Step 1).
2. **Notarized release.** Run `Tools/release.sh --identity "Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)"` without `--skip-notarize` (Step 2). Then check the stapled tickets, Gatekeeper `accepted` / `Notarized Developer ID` for the app and the DMG, and the checksum (Step 3).
3. **Install.** Drag the app over the 0.6.0 copy in `~/Applications`. Check About shows `Version 0.7.0 (6)`, the shortcut count, the installed copy's signature, and Help → Check for Updates… (Steps 4-5).
4. **Publish.** In order:
   - `git push origin main`;
   - the repository visibility decision (spec §12 item 7);
   - `git tag -a v0.7.0 -m "v0.7.0"`;
   - `Tools/publish-release.sh` with `--dry-run` first, then for real (Step 6).
5. **Download check.** Check the `gh release download` checksum, then a quarantined browser download that shows only the one-time downloaded-from-the-Internet question (Step 7), then teardown.

Before handing over to Mike, the reviewer checks Task 7's evidence:
- `exit=0` and the Step 6 counts;
- the three `1 0 1` part lines from the mounted DMG;
- the recorded DMG verdict;
- the `Release: 0.7.0 (6)` commit and a clean tree;
- nothing pushed (`git status -sb` still shows `main` ahead of `origin/main`).

## Deferred

- **Sparkle or any other in-app self-update.** Help → Check for Updates… opens the releases page, and the `updates-manual` known limitation says the app does not update itself.
- **DMG background image and Finder window layout** (icon positions, window size). `make-dmg.sh` ships a plain UDZO image holding the app and an Applications symlink.
- **1.0.0 naming.** This phase ships 0.7.0 per the brief. Whether the first notarized public release should be called 1.0.0 is Mike's call.
- **`LICENSE`.** Mike has not picked one, and no task adds the file. A public repository without a license is all rights reserved by default, so decide with the visibility change in acceptance Step 6.2.
- **Homebrew cask.**
- **`--help` for `Tools/build-app.sh` and `Tools/test-app.sh`.** Their usage handling is unchanged.
- **CI or automated notarization and publishing.** It needs repository secrets for Apple credentials. Releases stay Mike-present.
- **Spec line 22 wording.** It could say that Check for Updates… hands a URL to the browser without the app making a request (see Task 6 Deviations).
- **README Phase 1 "Known limitations" list.** It does not list the new `updates-manual` entry; only the count on line 81 changes (Task 6). The in-app Known Limitations window shows every entry.
