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
