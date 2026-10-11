# macOS App Duplicator Phase 6 (Helper) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give application shortcuts the spec §4.6 helper: an optional menu bar icon (Show, New Window, Quit <Name>) and erase-on-quit of the shortcut's data folder after the target app exits, with the §4.3 guards; and finish the §4.5 language override with validation, a Diagnostics row, an acceptance step and a known limitation (spec §3.4, §4.3, §4.5, §4.6, §4.7, §7, §12 item 6).

**Architecture:** Every decision lives in pure Core types with XCTest coverage: `HelperPlan` (does this shortcut need a helper, which data folder), `HelperArguments` (the `--helper` argv), `ProcessStartTime` (`proc_pidinfo` start time, the pid-reuse guard), `HelperEnvironment` (the helper keeps the real HOME so its log and erase guard never point into the data folder), `EraseOnQuitPolicy` and `EraseOnQuitPerformer` (the hard erase guard and the symlink-safe erase), `NewWindowCommandBuilder`, `HelperMenuText`, `HelperLogLine`, `ProcessWatcher` (kqueue `EVFILT_PROC` with `NOTE_EXEC | NOTE_EXIT`) and `HelperWatchState` (the reducer that decides erase, failure or pid reuse). In Dock Shortcut mode the Launcher starts its own binary as `--helper <pid> <startSec> <startUsec> <bundle> <data|->` with `posix_spawn` just before `execve`; `main.swift` dispatches that role before it logs or reads `MADConfig`. The helper erases only after it saw the parent exec into the target and then exit, and it creates `NSApplication` and an `NSStatusItem` only when `menuBarIcon` is on. In System Launch mode the Launcher process itself becomes the helper for the pid `NSWorkspace` returns. The app copies `newWindowCommand` from profiles, turns the Phase-6-disabled controls on behind a pure `HelperEditorPolicy`, and shows the new values in Diagnostics, the profile summary and the launch plan preview.

**Tech Stack:** Swift 6 language mode (Xcode 27.0, Swift 6.4), macOS 26+ arm64, SwiftUI + AppKit (app), Foundation + Darwin (Core: `kqueue`, `proc_pidinfo`, `proc_pidpath`), AppKit (Launcher: `NSStatusItem`, `NSWorkspace`, `posix_spawn`), swift-argument-parser (madctl), xcodegen 2.45.3 (/usr/local/bin/xcodegen), XCTest.

## Global Constraints

Phase 5 constraints carry over verbatim unless a Phase 6 line below overrides them. In particular: macOS 26+ / arm64 only (`ARCHS = arm64`, `MACOSX_DEPLOYMENT_TARGET = 26.0`, `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`); Core imports Foundation, Security and Darwin only; XCTest only; no new `try?` except where this plan shows one, no empty `catch`, no `@unchecked Sendable`, no `swiftlint:disable`; never copy, repackage, patch or re-sign a target app; `SecretMasking` pattern `(?i)secret|token|key|password|passwd|credential` masks values as `••••••`; the Info.plist key set and `BundleWriter.forbiddenInfoPlistKeys` are unchanged; bundle ids are `com.mikekuta.appduplicator.<slug>`; shortcuts are written only to the chosen output directory; logs go to `~/Library/Logs/App Duplicator/<name>.log`; commands are argv arrays, never shell strings; no `osascript` in tests; tests stay in their sandbox (per-test temp folders, injected `home`/`fileManager`, never the real `~/Library`, `~/Applications`, `UserDefaults.standard` or the network).

Phase 6 additions:

- **The helper exists for `.app` shortcuts only.** `.webApp` shortcuts already own a status item and background mode inside WebShell (`StatusItemController`, `BackgroundModePolicy`); `.file`, `.folder` and `.cli` shortcuts exit immediately and have no resident process. `ShortcutConfig.menuBarIcon` and `eraseOnQuit` are therefore honoured only when `kind == .app`; for every other kind the Launcher ignores them and the editor hides or disables the controls.
- **The helper is a second process started with `posix_spawn`, not `fork()`.** Swift marks `fork()` unavailable, so the Launcher starts its own binary (`Bundle.main.executableURL`) with `POSIX_SPAWN_SETSID` (reuse `spawnDetached`) and the argv `--helper <parentPid> <startSeconds> <startMicroseconds> <bundlePath> <dataPath|->` *before* `execve`. The helper never shares memory or AppKit state with the parent. Spec §3.4 step 5 says `fork()`; the plan records this deviation and updates the spec wording.
- **Helper role dispatch happens first.** `main.swift` checks `CommandLine.arguments` for `--helper` before reading `MADConfig`, before any logging and before any AppKit use. `HelperArguments.parse(_:)` (Core, pure) rejects anything malformed; a malformed helper invocation exits 1 silently (log line only).
- **A failed launch never erases data.** The helper registers `EVFILT_PROC` with `NOTE_EXIT | NOTE_EXEC` on the parent pid. Erase-on-quit runs only if `NOTE_EXEC` was observed (the parent became the target) and then `NOTE_EXIT` arrives. `NOTE_EXIT` without a prior `NOTE_EXEC` means the Launcher itself failed (exit 2/3/4): the helper logs and exits without erasing. If the kqueue registration fails with `ESRCH` the parent is already gone: no erase, exit.
- **Pid reuse is detected by start time.** The parent captures its own `proc_pidinfo(PROC_PIDTBSDINFO)` `pbi_start_tvsec`/`pbi_start_tvusec` (exec does not change a process's start time) and passes both. The helper re-reads the start time for the pid on startup and after every kevent; a mismatch means the pid was reused, and the helper exits without erasing or signalling.
- **System Launch: the Launcher process itself becomes the helper.** There is no second process. After `NSWorkspace.openApplication`'s callback returns the `NSRunningApplication`, if `menuBarIcon || eraseOnQuit` the Launcher calls the same `HelperRunner` entry with the target pid, the target's start time (read at that moment) and the plan's data path, instead of `exit(0)`. `NOTE_EXEC` is not required on this path (the target was never the Launcher). The Launcher sets `.accessory` activation policy before creating any window or status item so it has no Dock tile.
- **Erase-on-quit has a hard guard in Core that does not trust the config.** `EraseOnQuitPolicy.check(dataPath:home:)` refuses: empty or relative paths, paths outside the user's home, the home itself, the top-level protected folders (`Desktop`, `Documents`, `Downloads`, `Movies`, `Music`, `Pictures`, `Public`, `Library` itself and `Library/Application Support` itself), any path with fewer than four components below `/`, a path that is not a directory, and a path that is itself a symlink. `EraseOnQuitPerformer` removes each direct child with `FileManager.removeItem(at:)` (symlinks are unlinked, never followed) and leaves the directory in place (recreating it if a removal somehow removed it). It never deletes the directory's parent and never touches anything outside `dataPath`.
- **Editor confirmation for custom erase paths.** Enabling erase-on-quit is immediate when the data path is inside `<home>/Library/Application Support/App Duplicator/`; for any other path the toggle flips only after a destructive-styled confirmation alert (spec §4.3). `HelperEditorPolicy` (App, pure) owns these decisions and is unit-tested.
- **New Window runs a profile template, stored in `MADConfig`.** `ShortcutConfig` gains `newWindowCommand: String?` (default `nil`, `decodeIfPresent`), copied from `CompatProfile.newWindowCommand` when the wizard selects a target (same place `arguments`/`environment` are copied, `WizardModel.selectTarget`) and editable in the editor's Advanced section. `NewWindowCommandBuilder.argv(template:targetPath:targetBundleIdentifier:dataPath:)` (Core, pure) splits the template on whitespace *first*, then substitutes `{target}`, `{bundleId}` and `{dataPath}` inside each token, so paths with spaces stay one argument. A relative argv0 is executed through `/usr/bin/env`. The helper runs the result with `spawnDetached` and the shortcut environment. Menu item hidden when the template is nil or blank.
- **Quit <Name>** sends `SIGTERM` to the target pid (after re-checking the start time), then `SIGKILL` 10 s later if the pid is still alive with the same start time.
- **Status item image** mirrors WebShell's convention: the shortcut's own `CFBundleIconFile` `.icns` from `<bundlePath>/Contents/Resources`, copied, 18 pt, `isTemplate = false` (spec §4.6 says template-rendered; the plan records the deviation, matching Phase 4's decision for WebShell). Menu: Show, New Window (conditional), separator, Quit <Name>. No unread badge (webApp only; WebShell owns it).
- **The helper is AppKit-free unless `menuBarIcon` is on.** With erase-on-quit alone it runs a kqueue wait loop on a plain `RunLoop`/`DispatchSource`, performs the erase and exits. `NSApplication` is created only to host the status item.
- **Helper log lines** go to the same `<Name>.log`: `helper start pid=<parent> …`, `helper exec observed`, `helper target exited status=<n>`, `helper erase <path> removed=<count>` or `helper erase skipped: <reason>`, `helper exit`. Paths and arguments pass through `SecretMasking` where values are logged.
- **Tests never create a status item.** Unit tests cover the pure Core types and the App policies. The gated integration test (`MAD_INTEGRATION=1`) runs the fixture app through a shortcut with `eraseOnQuit = true`, `menuBarIcon = false`, `dataMode = .homeOverride` and a `dataPath` inside a mktemp home, asserts the data directory is emptied and still exists after the fixture exits, and asserts no Launcher/helper process remains (poll by executable path, 10 s cap). No test forks or spawns a helper that outlives the test; no test erases anything outside mktemp dirs. `kqueue` wrapper tests use a short-lived `/bin/sleep` child they own.
- **Language override is already implemented** (`DataSeparationPlanner` §4.5 emits `-AppleLanguages (<code>) -AppleLocale <code>`; editor field exists). Phase 6 adds validation only (`LanguageCode.isValid`: `^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$`, editor message, DiagnosticsView row), an acceptance step and a known limitation for apps that ignore `AppleLanguages`.
- **`RunningShortcutMonitor` is unchanged.** The helper carries `MAD_SHORTCUT_BUNDLE` in its environment (passed explicitly to `posix_spawn`), so the sidebar's running indicator stays on until the helper exits, which happens within milliseconds of the target exiting (after an erase, within the erase's duration).
- Version bump at the end of the phase (`App/project.yml`): `MARKETING_VERSION 0.6.0`, `CURRENT_PROJECT_VERSION 5`.

## Implementer contract

Repo: `~/Developer/MacAppDuplicator` (git main). Every Bash call starts in a different cwd, so prefix commands with `cd ~/Developer/MacAppDuplicator &&`. No `timeout` binary; foreground `sleep` is blocked. Nobody else builds in this repo while you work.

Liveness: append one line `<HH:MM> step N <what>` to the PROGRESS file named in your dispatch after EVERY step (tests run, file written, commit made). A file idle for 10 minutes is treated as a stall and you are killed; write to it even when a build is slow (write before starting the build).

Tests: `swift test --filter DuplicatorCoreTests.<SuiteName>` runs one suite (dot form only; slash form runs 0 tests). Whole Core: `swift test --filter DuplicatorCoreTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`. Swift 6 strict concurrency applies to tests too: never `@unchecked Sendable`, no new `try?`, no empty `catch`, no `swiftlint:disable`. XCTest only.

Commits: `git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit ...`, message body ends with the line `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Stage only the files your task names. Never push.

Scope: touch only the files the brief lists. Tests never write outside mktemp dirs; never touch `/Applications`, `~/Applications`, `UserDefaults.standard`, `~/Library/*`, or the network. Never launch Terminal/iTerm2/Ghostty/osascript against real apps; unit-test generated strings only. Never create an NSStatusItem in a test; never start a helper process a test does not reap; never erase anything outside a mktemp dir.

Report: write the full report to the REPORT file named in your dispatch: what you changed (file list), exact commands run with their final summary lines, deviations from the brief and why, self-review notes, concerns. Your return message is at most 8 lines: STATUS (DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED), commit sha(s), one-line test summary (e.g. `Core 185/0`), concerns or `none`.


## Inputs and conventions

- Spec: `docs/superpowers/specs/2026-10-09-macos-app-duplicator-design.md` §3.4 (launch sequence, step 5 is the helper), §4.3 (erase-on-quit guard and confirmation), §4.5 (language override), §4.6 (helper: status item, Show, New Window, Quit, process watch), §4.7 (logging and exit codes), §7 (editor Launch, Data and Advanced sections), §12 item 6 (Phase 6 scope).
- Baselines at HEAD `4e0e4e5` (v0.5.0): Core 235, WebShell 56, CompatProfiles 37, Integration 4 (gated), `Tools/test-app.sh` 342.
- Running totals: Core 245 after Task 1, 257 after Task 2, 267 after Task 3, 282 after Task 4, 286 after Task 6 (Tasks 5 and 7 to 11 add no Core tests). Integration 5 after Task 5. App totals are stated in each App task's run step; Task 11 lists every final number.
- Commands (always prefix `cd ~/Developer/MacAppDuplicator &&`; the shell cwd resets per call; there is no `timeout` binary and foreground `sleep` is blocked):
  - Build every target: `swift build 2>&1 | tail -1` prints `Build complete!` (the Launcher has no unit tests; `swift build` is its compile check).
  - One Core suite: `swift test --filter DuplicatorCoreTests.<Suite> 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` (dot form only; the slash form runs 0 tests).
  - Whole Core: `swift test --filter DuplicatorCoreTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`.
  - WebShell: `swift test --filter WebShellTests 2>&1 | grep "'Selected tests' passed" -A1` prints `Executed 56 tests, with 0 failures`.
  - CompatProfiles: `swift test --filter CompatProfilesTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` prints `Executed 37 tests, with 0 failures`.
  - Gated integration: `swift build -c release --product Launcher --product WebShell --product madctl && Tools/build-fixture.sh && MAD_INTEGRATION=1 swift test --filter IntegrationTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`.
  - App: `Tools/test-app.sh 2>&1 | tail -3` ends with `** TEST SUCCEEDED **`; count with `Tools/test-app.sh 2>&1 | grep -cE "Test Case .* passed"`.
  - Forbidden constructs (run on every file a task touches, expect no output): `grep -nE 'try\?|@unchecked|swiftlint:disable|nonisolated\(unsafe\)' <files>`. The only pre-existing `try?` lines this phase touches are `ShortcutConfig.plistDictionary()` (unchanged) and the eight in `LaunchLogger.append` (Task 4 deletes them); a task's check passes when every hit is one of those unchanged lines.
- Commit identity: `git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit`, every message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Stage only the files the task names. Never push.
- The profile type is `AppProfile` (`Packages/CompatProfiles/Sources/CompatProfiles/ProfilesDocument.swift`), whose `newWindowCommand: String?` is already decoded and checked (at most 2,048 characters, no NUL). The Global Constraints call it `CompatProfile`; same field. No seed profile sets it (`SeedProfilesTests.testSeedCarriesNoLaunchValuesYet` asserts nil), and this phase keeps the seed unchanged: the builder is tested in isolation, and a template enters the seed only through `docs/acceptance/profile-promotion.md`.
- Existing patterns to mirror: `LauncherEditorPolicy` and `WebEditorPolicy` (pure `nonisolated enum` editor decisions), `DataPathGuard` (`Result`-returning path guard with canonical paths), WebShell `StatusItemController` and `StatusItemText` (status item layout, 18 pt colour image, `@objc private` actions calling `@MainActor` closures), `LaunchIntegrationTests` and `CLILaunchTests` (gated launch tests with a redirected HOME and process reaping), Core `TestSupport.makeTemporaryDirectory()`, `Spawn.swift` `spawnDetached` (posix_spawn with `POSIX_SPAWN_SETSID`).
- Names that already exist as `main.swift` top-level globals and are therefore visible to every Launcher file: `shortcutName`, `logger`, `base`, `realHome`, `shortcut`, `prepared`, `config`, `plan`, `execErrno`. New Launcher files never declare these names and always take values as parameters.

## File structure

Create:
- `Packages/DuplicatorCore/Sources/DuplicatorCore/LanguageCode.swift`: `LanguageCode.isValid(_:)`, `validationMessage(for:)`.
- `Packages/DuplicatorCore/Sources/DuplicatorCore/NewWindowCommandBuilder.swift`: template to argv, validation.
- `Packages/DuplicatorCore/Sources/DuplicatorCore/HelperMenuText.swift`: status item menu titles.
- `Packages/DuplicatorCore/Sources/DuplicatorCore/HelperPlan.swift`: does a shortcut need a helper, which folder is erased.
- `Packages/DuplicatorCore/Sources/DuplicatorCore/HelperArguments.swift`: the `--helper` argv, build and parse.
- `Packages/DuplicatorCore/Sources/DuplicatorCore/HelperEnvironment.swift`: the helper's environment (real HOME) and the target's environment for New Window.
- `Packages/DuplicatorCore/Sources/DuplicatorCore/HelperLogLine.swift`: every `helper …` log line.
- `Packages/DuplicatorCore/Sources/DuplicatorCore/EraseOnQuitPolicy.swift`: the hard erase guard.
- `Packages/DuplicatorCore/Sources/DuplicatorCore/EraseOnQuitPerformer.swift`: the symlink-safe erase.
- `Packages/DuplicatorCore/Sources/DuplicatorCore/ProcessStartTime.swift`: `proc_pidinfo` start time and comparison.
- `Packages/DuplicatorCore/Sources/DuplicatorCore/ProcessWatcher.swift`: kqueue `EVFILT_PROC` wrapper, `proc_pidpath`.
- `Packages/DuplicatorCore/Sources/DuplicatorCore/HelperWatchState.swift`: the reducer that decides erase, failure or pid reuse.
- `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/{LanguageCodeTests,NewWindowCommandBuilderTests,HelperMenuTextTests,HelperPlanTests,HelperArgumentsTests,HelperEnvironmentTests,HelperLogLineTests,EraseOnQuitPolicyTests,EraseOnQuitPerformerTests,ProcessStartTimeTests,ProcessWatcherTests,HelperWatchStateTests}.swift`
- `Launcher/Sources/Launcher/HelperLaunch.swift`: the parent side, spawns the helper just before exec.
- `Launcher/Sources/Launcher/HelperRole.swift`: the `--helper` entry point.
- `Launcher/Sources/Launcher/HelperRunner.swift`: the watch loop (blocking or AppKit), erase, Show, New Window, Quit.
- `Launcher/Sources/Launcher/HelperStatusItem.swift`: the `NSStatusItem` and its menu.
- `Tests/Integration/HelperEraseTests.swift`: gated end-to-end erase-on-quit test.
- `App/Sources/Services/HelperEditorPolicy.swift`, `App/Tests/Services/HelperEditorPolicyTests.swift`
- `docs/acceptance/phase6-helper.md`

Modify:
- `Packages/DuplicatorCore/Sources/DuplicatorCore/ShortcutConfig.swift` (`newWindowCommand`), `.../LaunchLogger.swift` (`O_APPEND` writes)
- `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/ShortcutConfigTests.swift`, `.../LaunchLoggerTests.swift`
- `Tools/madctl/Sources/madctl/Options.swift`, `Tools/madctl/Sources/madctl/ConfigFactory.swift`
- `Launcher/Sources/Launcher/main.swift`, `Launcher/Sources/Launcher/Spawn.swift`, `Launcher/Sources/Launcher/SystemLaunch.swift`
- `App/Sources/Views/Wizard/{WizardModel,WizardSteps}.swift`, `App/Sources/Services/{ProfileSummary,LaunchPlanPreview}.swift`, `App/Sources/Views/{DiagnosticsView,EditorSections,ShortcutEditorView}.swift`, `App/Sources/App/KnownLimitations.swift`, `App/project.yml`
- `App/Tests/App/{DiagnosticsModelTests,KnownLimitationsTests}.swift`, `App/Tests/Services/{LaunchPlanPreviewTests,ProfileSummaryTests}.swift`, `App/Tests/Wizard/WizardModelTests.swift`
- `Packages/CompatProfiles/Sources/CompatProfiles/ProfilesDocument.swift` (doc comment of `AppProfile.newWindowCommand` only)
- `README.md`, `docs/superpowers/specs/2026-10-09-macos-app-duplicator-design.md`

---

### Task 1: Core: `ShortcutConfig.newWindowCommand`, `LanguageCode`, `NewWindowCommandBuilder`, `HelperMenuText`, madctl flags

**Files:**
- Create: `Packages/DuplicatorCore/Sources/DuplicatorCore/LanguageCode.swift`, `.../NewWindowCommandBuilder.swift`, `.../HelperMenuText.swift`
- Modify: `Packages/DuplicatorCore/Sources/DuplicatorCore/ShortcutConfig.swift` (property after line 28, init parameter after line 58, assignment after line 81, `CodingKeys` line 93, doc comment lines 97-98, decoder after line 115), `Tools/madctl/Sources/madctl/Options.swift` (after line 48), `Tools/madctl/Sources/madctl/ConfigFactory.swift` (validation after line 19, init call lines 43-44)
- Test: create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/LanguageCodeTests.swift`, `.../NewWindowCommandBuilderTests.swift`, `.../HelperMenuTextTests.swift`; extend `.../ShortcutConfigTests.swift` (before the closing brace on line 269)

**Interfaces:**
- Consumes: `ShortcutConfig` (`makeConfig()` in `ShortcutConfigTests` is an `.app` config with a data path), `ShortcutConfig(plistDictionary:)`, `plistDictionary()`, madctl `ShortcutOptions`, `makeConfig(app:options:)`, `ValidationError`.
- Produces:
  ```swift
  // ShortcutConfig (after menuBarIcon; init parameter `newWindowCommand: String? = nil` between `menuBarIcon:` and `iconMode:`)
  public var newWindowCommand: String?

  public enum LanguageCode {
      public static let pattern: String          // ^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$
      public static let invalidMessage: String   // "Use a language code like en, fr or pt-BR."
      public static func isValid(_ code: String) -> Bool
      public static func validationMessage(for code: String?) -> String?   // nil for nil, blank or valid
  }
  public enum NewWindowCommandBuilder {
      public static let maximumLength: Int       // 2_048
      public static let envPath: String          // "/usr/bin/env"
      public static func argv(template: String?, targetPath: String, targetBundleIdentifier: String, dataPath: String?) -> [String]?
      public static func validationMessage(for template: String?) -> String?
  }
  public enum HelperMenuText {
      public static let newWindow: String        // "New Window"
      public static func show(name: String) -> String   // "Show <name>"
      public static func quit(name: String) -> String   // "Quit <name>"
  }
  // madctl ShortcutOptions: --menu-bar-icon, --erase-on-quit (flags), --new-window-command <template>
  ```

- [ ] **Step 1: Write the failing `ShortcutConfig` tests.** Insert these two tests in `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/ShortcutConfigTests.swift` directly before the class's closing brace (line 269):

```swift

    func testNewWindowCommandRoundTripsThroughMADConfig() throws {
        var config = makeConfig()
        config.newWindowCommand = "open -na {target} --args --user-data-dir={dataPath}"
        let dictionary = config.plistDictionary()
        XCTAssertEqual(dictionary["newWindowCommand"] as? String, "open -na {target} --args --user-data-dir={dataPath}")
        XCTAssertEqual(try ShortcutConfig(plistDictionary: dictionary), config)
    }

    func testNewWindowCommandDefaultsToNilAndPhase5DictionariesStillDecode() throws {
        XCTAssertNil(makeConfig().newWindowCommand)
        let phase5Dictionary = makeConfig().plistDictionary()
        XCTAssertNil(phase5Dictionary["newWindowCommand"])
        XCTAssertNil(try ShortcutConfig(plistDictionary: phase5Dictionary).newWindowCommand)
    }
```

- [ ] **Step 2: Write the failing tests for the three new types.**

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/LanguageCodeTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore

final class LanguageCodeTests: XCTestCase {
    func testAcceptsLanguageScriptAndRegionCodes() {
        for code in ["en", "fr", "deu", "pt-BR", "zh-Hant", "zh-Hant-TW", "es-419", "EN-us"] {
            XCTAssertTrue(LanguageCode.isValid(code), code)
            XCTAssertNil(LanguageCode.validationMessage(for: code), code)
        }
        XCTAssertNil(LanguageCode.validationMessage(for: nil))
        XCTAssertNil(LanguageCode.validationMessage(for: "   "))
        XCTAssertNil(LanguageCode.validationMessage(for: " fr "))
    }

    func testRefusesMalformedCodes() {
        let malformed = ["", "e", "english", "en_US", "en-", "-en", "en--US", "en-U", "en-abcdefghi", "en US", "en\n", "fr)", "1en", "en;rm"]
        for code in malformed {
            XCTAssertFalse(LanguageCode.isValid(code), code.debugDescription)
        }
        XCTAssertEqual(LanguageCode.validationMessage(for: "en_US"), "Use a language code like en, fr or pt-BR.")
        XCTAssertEqual(LanguageCode.validationMessage(for: "english"), LanguageCode.invalidMessage)
    }
}
```

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/NewWindowCommandBuilderTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore

final class NewWindowCommandBuilderTests: XCTestCase {
    private let dataPath = "/Users/me/Library/Application Support/App Duplicator/chrome-work"

    func testSplitsFirstThenSubstitutesSoPathsWithSpacesStayOneArgument() {
        let argv = NewWindowCommandBuilder.argv(
            template: "/usr/bin/open -na {target} --args --user-data-dir={dataPath}",
            targetPath: "/Applications/Google Chrome.app",
            targetBundleIdentifier: "com.google.Chrome",
            dataPath: dataPath
        )
        XCTAssertEqual(argv, [
            "/usr/bin/open", "-na", "/Applications/Google Chrome.app", "--args",
            "--user-data-dir=/Users/me/Library/Application Support/App Duplicator/chrome-work",
        ])
    }

    func testARelativeProgramRunsThroughUsrBinEnv() {
        let argv = NewWindowCommandBuilder.argv(
            template: "  open\t-n -b {bundleId}  ",
            targetPath: "/Applications/Example.app",
            targetBundleIdentifier: "com.example.app",
            dataPath: nil
        )
        XCTAssertEqual(argv, ["/usr/bin/env", "open", "-n", "-b", "com.example.app"])
    }

    func testNilOrBlankTemplatesAndAMissingDataPathProduceNoCommand() {
        for template in [nil, "", "  \t "] as [String?] {
            XCTAssertNil(NewWindowCommandBuilder.argv(
                template: template, targetPath: "/A.app", targetBundleIdentifier: "com.example.a", dataPath: dataPath))
        }
        XCTAssertNil(NewWindowCommandBuilder.argv(
            template: "/usr/bin/open -na {target} --args --user-data-dir={dataPath}",
            targetPath: "/A.app", targetBundleIdentifier: "com.example.a", dataPath: nil))
    }

    func testUnknownPlaceholdersStayLiteralAndSubstitutedValuesAreNotRescanned() {
        let argv = NewWindowCommandBuilder.argv(
            template: "/bin/echo {name} {target} {{bundleId}} {bundleId",
            targetPath: "/Apps/{bundleId}.app",
            targetBundleIdentifier: "com.example.a",
            dataPath: nil
        )
        XCTAssertEqual(argv, ["/bin/echo", "{name}", "/Apps/{bundleId}.app", "{com.example.a}", "{bundleId"])
    }

    func testValidationRefusesOverlongTemplatesAndControlCharacters() {
        XCTAssertNil(NewWindowCommandBuilder.validationMessage(for: nil))
        XCTAssertNil(NewWindowCommandBuilder.validationMessage(for: ""))
        XCTAssertNil(NewWindowCommandBuilder.validationMessage(for: "open -na {target}\t--args"))
        XCTAssertNil(NewWindowCommandBuilder.validationMessage(for: String(repeating: "a", count: 2_048)))
        XCTAssertEqual(NewWindowCommandBuilder.validationMessage(for: String(repeating: "a", count: 2_049)),
                       "The New Window command is longer than 2048 characters.")
        for template in ["open\u{0}-na", "open\n-na", "open\u{1B}[0m", "open\u{7F}"] {
            XCTAssertEqual(NewWindowCommandBuilder.validationMessage(for: template),
                           "The New Window command may not contain control characters.", template.debugDescription)
        }
    }
}
```

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/HelperMenuTextTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore

final class HelperMenuTextTests: XCTestCase {
    func testMenuTitlesNameTheShortcut() {
        XCTAssertEqual(HelperMenuText.show(name: "Claude Work"), "Show Claude Work")
        XCTAssertEqual(HelperMenuText.newWindow, "New Window")
        XCTAssertEqual(HelperMenuText.quit(name: "Claude Work"), "Quit Claude Work")
    }
}
```

- [ ] **Step 3: Run them and watch them fail.**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.LanguageCodeTests 2>&1 | grep -E "error:" | head -5`
Expected: compile errors, among them `cannot find 'LanguageCode' in scope`, `cannot find 'NewWindowCommandBuilder' in scope`, `cannot find 'HelperMenuText' in scope` and `value of type 'ShortcutConfig' has no member 'newWindowCommand'`.

- [ ] **Step 4: Add `newWindowCommand` to `ShortcutConfig`.** Six edits in `Packages/DuplicatorCore/Sources/DuplicatorCore/ShortcutConfig.swift`.

Replace lines 27-28:

```swift
    public var eraseOnQuit: Bool
    public var menuBarIcon: Bool
```

with:

```swift
    public var eraseOnQuit: Bool
    public var menuBarIcon: Bool
    /// Template for the helper's New Window menu item (spec §4.6), copied from the compatibility profile when the wizard
    /// selects a target; nil or blank hides the item. `NewWindowCommandBuilder` renders it; it never reaches a shell.
    public var newWindowCommand: String?
```

Replace the two init parameter lines:

```swift
        menuBarIcon: Bool = false,
        iconMode: IconMode = .copied,
```

with:

```swift
        menuBarIcon: Bool = false,
        newWindowCommand: String? = nil,
        iconMode: IconMode = .copied,
```

Replace the two assignment lines:

```swift
        self.menuBarIcon = menuBarIcon
        self.iconMode = iconMode
```

with:

```swift
        self.menuBarIcon = menuBarIcon
        self.newWindowCommand = newWindowCommand
        self.iconMode = iconMode
```

Replace the second `CodingKeys` line:

```swift
        case environment, arguments, appearance, languageCode, eraseOnQuit, menuBarIcon
```

with:

```swift
        case environment, arguments, appearance, languageCode, eraseOnQuit, menuBarIcon, newWindowCommand
```

Replace the decoder doc comment:

```swift
    /// Decodes Phase 1 to 4 dictionaries too: `iconMode`, `customIconPath`, `homeSymlinkEntries`, `webApp`, `file` and `cli`
    /// are optional on input.
```

with:

```swift
    /// Decodes Phase 1 to 5 dictionaries too: `newWindowCommand`, `iconMode`, `customIconPath`, `homeSymlinkEntries`,
    /// `webApp`, `file` and `cli` are optional on input.
```

Replace the decoder line:

```swift
        menuBarIcon = try container.decode(Bool.self, forKey: .menuBarIcon)
```

with:

```swift
        menuBarIcon = try container.decode(Bool.self, forKey: .menuBarIcon)
        newWindowCommand = try container.decodeIfPresent(String.self, forKey: .newWindowCommand)
```

The synthesized `encode(to:)` uses `encodeIfPresent` for the optional, so a nil template is omitted from `MADConfig` exactly like `customIconPath`; `engineVersion` stays 1.

- [ ] **Step 5: Create `Packages/DuplicatorCore/Sources/DuplicatorCore/LanguageCode.swift`.**

```swift
import Foundation

/// The accepted shape of the §4.5 language override. `DataSeparationPlanner` passes the code as
/// `-AppleLanguages (<code>) -AppleLocale <code>`; this type only validates what the editor and madctl store.
public enum LanguageCode {
    /// A 2 or 3 letter language, then optional `-` subtags of 2 to 8 letters or digits: `en`, `fr`, `pt-BR`,
    /// `zh-Hant-TW`, `es-419`.
    public static let pattern = #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"#
    /// Shown by the editor under the Language field.
    public static let invalidMessage = "Use a language code like en, fr or pt-BR."

    /// True when the whole of `code` matches `pattern`. The match must cover the entire string, because `$` also matches
    /// in front of a trailing newline.
    public static func isValid(_ code: String) -> Bool {
        guard let match = code.range(of: pattern, options: .regularExpression) else { return false }
        return match == code.startIndex..<code.endIndex
    }

    /// `invalidMessage` when `code`, trimmed, is non-empty and invalid; nil for nil, blank or valid codes (a blank field
    /// means "no override").
    public static func validationMessage(for code: String?) -> String? {
        guard let trimmed = code?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return isValid(trimmed) ? nil : invalidMessage
    }
}
```

- [ ] **Step 6: Create `Packages/DuplicatorCore/Sources/DuplicatorCore/NewWindowCommandBuilder.swift`.**

```swift
import Foundation

/// Renders a profile's `newWindowCommand` template into the argv the helper's New Window item runs (spec §4.6).
/// The template is split on whitespace first and each token's placeholders are substituted afterwards, so a target or
/// data path with spaces stays one argument. The result goes to `posix_spawn`; nothing is ever passed to a shell.
public enum NewWindowCommandBuilder {
    /// Longest template accepted, in Unicode scalars (the profiles schema caps every string at 2,048 characters).
    public static let maximumLength = 2_048
    /// Runs a template whose program is not an absolute path: `open` becomes `/usr/bin/env open`.
    public static let envPath = "/usr/bin/env"

    /// The argv to execute, or nil when the template is nil or blank, or uses `{dataPath}` while `dataPath` is nil.
    /// Placeholders: `{target}` (the target app's path), `{bundleId}` (its bundle identifier) and `{dataPath}`. Any other
    /// brace text stays literal, and substituted values are never scanned again. `argv[0]` is always an absolute path.
    public static func argv(template: String?, targetPath: String, targetBundleIdentifier: String, dataPath: String?) -> [String]? {
        guard let template else { return nil }
        let tokens = template.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }
        if dataPath == nil, tokens.contains(where: { $0.contains("{dataPath}") }) { return nil }
        let values: [(name: String, value: String)] = [
            ("target", targetPath), ("bundleId", targetBundleIdentifier), ("dataPath", dataPath ?? ""),
        ]
        let rendered = tokens.map { substitute($0, values: values) }
        guard let program = rendered.first, !program.isEmpty else { return nil }
        return program.hasPrefix("/") ? rendered : [envPath] + rendered
    }

    /// Why a template may not be stored, or nil when it may. nil and blank templates are fine: they hide the menu item.
    public static func validationMessage(for template: String?) -> String? {
        guard let template else { return nil }
        if template.unicodeScalars.count > maximumLength {
            return "The New Window command is longer than \(maximumLength) characters."
        }
        let hasControlCharacter = template.unicodeScalars.contains { scalar in
            (scalar.value < 0x20 && scalar != "\t") || scalar.value == 0x7F
        }
        return hasControlCharacter ? "The New Window command may not contain control characters." : nil
    }

    /// One left-to-right pass: each `{name}` with a known name is replaced by its value; everything else is copied.
    private static func substitute(_ token: String, values: [(name: String, value: String)]) -> String {
        var result = ""
        var rest = Substring(token)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let candidate = rest[open...]
            if let match = values.first(where: { candidate.hasPrefix("{\($0.name)}") }) {
                result += match.value
                rest = candidate.dropFirst(match.name.count + 2)
            } else {
                result += "{"
                rest = candidate.dropFirst()
            }
        }
        return result + rest
    }
}
```

- [ ] **Step 7: Create `Packages/DuplicatorCore/Sources/DuplicatorCore/HelperMenuText.swift`.**

```swift
/// Titles of the helper's status item menu (spec §4.6), worded like WebShell's `StatusItemText`.
public enum HelperMenuText {
    public static let newWindow = "New Window"

    public static func show(name: String) -> String {
        "Show \(name)"
    }

    public static func quit(name: String) -> String {
        "Quit \(name)"
    }
}
```

- [ ] **Step 8: Run the suites and watch them pass.**

Run: `cd ~/Developer/MacAppDuplicator && for suite in ShortcutConfigTests LanguageCodeTests NewWindowCommandBuilderTests HelperMenuTextTests; do swift test --filter DuplicatorCoreTests.$suite 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1; done`
Expected, in order:
```
Executed 20 tests, with 0 failures (0 unexpected) in …
Executed 2 tests, with 0 failures (0 unexpected) in …
Executed 5 tests, with 0 failures (0 unexpected) in …
Executed 1 test, with 0 failures (0 unexpected) in …
```

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: `Executed 245 tests, with 0 failures (0 unexpected) in …`

- [ ] **Step 9: Add the madctl flags and validation.**

In `Tools/madctl/Sources/madctl/Options.swift` replace the last two lines of `ShortcutOptions`:

```swift
    @Option var language: String?
}
```

with:

```swift
    @Option var language: String?
    @Flag(name: .customLong("menu-bar-icon"), help: "Show the helper's menu bar icon (app shortcuts only).") var menuBarIcon = false
    @Flag(name: .customLong("erase-on-quit"), help: "Empty the data folder after the app quits (app shortcuts only).") var eraseOnQuit = false
    @Option(name: .customLong("new-window-command"), help: "New Window template; {target}, {bundleId} and {dataPath} are substituted.")
    var newWindowCommand: String?
}
```

In `Tools/madctl/Sources/madctl/ConfigFactory.swift` replace:

```swift
    let dataMode = options.dataMode.dataMode
```

with:

```swift
    if let language = options.language, !LanguageCode.isValid(language) {
        throw ValidationError("--language expects a code like en, fr or pt-BR: \(language)")
    }
    if let message = NewWindowCommandBuilder.validationMessage(for: options.newWindowCommand) {
        throw ValidationError("--new-window-command: \(message)")
    }

    let dataMode = options.dataMode.dataMode
    if options.eraseOnQuit, dataMode == .disabled {
        throw ValidationError("--erase-on-quit needs --data-mode auto or home")
    }
```

and replace the end of the `ShortcutConfig` call:

```swift
        appearance: options.appearance.appearance,
        languageCode: options.language
    )
```

with:

```swift
        appearance: options.appearance.appearance,
        languageCode: options.language,
        eraseOnQuit: options.eraseOnQuit,
        menuBarIcon: options.menuBarIcon,
        newWindowCommand: options.newWindowCommand
    )
```

Run: `cd ~/Developer/MacAppDuplicator && swift build 2>&1 | tail -1`
Expected: `Build complete!`

Run: `cd ~/Developer/MacAppDuplicator && swift run madctl plan /System/Applications/TextEdit.app --language en_US 2>&1 | grep -m1 'Error:'`
Expected: `Error: --language expects a code like en, fr or pt-BR: en_US`

Run: `cd ~/Developer/MacAppDuplicator && swift run madctl plan /System/Applications/TextEdit.app --data-mode disabled --erase-on-quit 2>&1 | grep -m1 'Error:'`
Expected: `Error: --erase-on-quit needs --data-mode auto or home`

Run: `cd ~/Developer/MacAppDuplicator && swift run madctl plan /System/Applications/TextEdit.app --language pt-BR --menu-bar-icon --erase-on-quit --new-window-command 'open -na {target}' 2>&1 | grep -m1 '^mode:'`
Expected: `mode: systemLaunch` (TextEdit is a platform binary; `plan` writes nothing).

- [ ] **Step 10: Forbidden constructs.**

Run: `cd ~/Developer/MacAppDuplicator && grep -nE 'try\?|@unchecked|swiftlint:disable|nonisolated\(unsafe\)' Packages/DuplicatorCore/Sources/DuplicatorCore/{LanguageCode,NewWindowCommandBuilder,HelperMenuText,ShortcutConfig}.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/{LanguageCodeTests,NewWindowCommandBuilderTests,HelperMenuTextTests,ShortcutConfigTests}.swift Tools/madctl/Sources/madctl/{Options,ConfigFactory}.swift`
Expected: exactly the two pre-existing `plistDictionary()` lines of `ShortcutConfig.swift` (`guard let data = try? PropertyListEncoder()…` and `let object = try? PropertyListSerialization…`), nothing else.

- [ ] **Step 11: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add Packages/DuplicatorCore/Sources/DuplicatorCore/ShortcutConfig.swift Packages/DuplicatorCore/Sources/DuplicatorCore/LanguageCode.swift Packages/DuplicatorCore/Sources/DuplicatorCore/NewWindowCommandBuilder.swift Packages/DuplicatorCore/Sources/DuplicatorCore/HelperMenuText.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/ShortcutConfigTests.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/LanguageCodeTests.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/NewWindowCommandBuilderTests.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/HelperMenuTextTests.swift Tools/madctl/Sources/madctl/Options.swift Tools/madctl/Sources/madctl/ConfigFactory.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Core: New Window template, language code validation, helper menu text" -m "ShortcutConfig gains newWindowCommand (decodeIfPresent, omitted when nil). NewWindowCommandBuilder splits a template on whitespace before substituting {target}, {bundleId} and {dataPath}, runs a relative program through /usr/bin/env and validates length and control characters. LanguageCode validates the language override. madctl gains --menu-bar-icon, --erase-on-quit and --new-window-command and refuses bad language codes." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Deviations

- `HelperMenuText.show(name:)` returns `Show <Name>`, not the spec's bare `Show`, to match WebShell's `StatusItemText.showItemTitle` so both kinds of shortcut word their menus the same way.
- madctl takes `--menu-bar-icon` and `--erase-on-quit` as flags (off by default, like the config defaults) and refuses `--erase-on-quit` with `--data-mode disabled`, because there is no folder to erase. A custom `--data-path` outside the App Duplicator data root is accepted without a prompt: the flag is the consent, and the Core guard of Task 3 still applies at run time.
- No seed profile gets a `newWindowCommand`; the builder is unit-tested on its own (see Inputs and conventions).

---

### Task 2: Core: `HelperPlan`, `HelperArguments`, `ProcessStartTime` (value), `HelperEnvironment`, `HelperLogLine`

**Files:**
- Create: `Packages/DuplicatorCore/Sources/DuplicatorCore/HelperPlan.swift`, `.../HelperArguments.swift`, `.../ProcessStartTime.swift` (the value type only; Task 4 appends the `proc_pidinfo` reader), `.../HelperEnvironment.swift`, `.../HelperLogLine.swift`
- Test: create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/HelperPlanTests.swift`, `.../HelperArgumentsTests.swift`, `.../HelperEnvironmentTests.swift`, `.../HelperLogLineTests.swift`

**Interfaces:**
- Consumes: `ShortcutConfig` (`kind`, `dataMode`, `dataPath`, `eraseOnQuit`, `menuBarIcon`; init defaults from `ShortcutConfig.swift` lines 43-66), `ShortcutKind` and `DataMode` (`Enums.swift` lines 5 and 11), `SecretMasking.maskArguments(_:)`.
- Produces:
  ```swift
  public enum HelperPlan {
      public static func isNeeded(for config: ShortcutConfig) -> Bool
      public static func eraseDataPath(for config: ShortcutConfig) -> String?
  }
  public struct ProcessStartTime: Hashable, Sendable {
      public var seconds: UInt64
      public var microseconds: UInt64
      public init(seconds: UInt64, microseconds: UInt64)
  }
  public struct HelperArguments: Equatable, Sendable {
      public static let flag: String             // "--helper"
      public static let noDataPath: String       // "-"
      public var parentPID: pid_t
      public var startTime: ProcessStartTime
      public var bundlePath: String
      public var dataPath: String?
      public init(parentPID: pid_t, startTime: ProcessStartTime, bundlePath: String, dataPath: String?)
      public var arguments: [String]             // argv after argv[0]
      public static func isHelperInvocation(_ argv: [String]) -> Bool
      public static func parse(_ argv: [String]) -> HelperArguments?
  }
  public enum HelperEnvironment {
      public static let targetHomeKey: String          // "MAD_HELPER_TARGET_HOME"
      public static let targetFixedHomeKey: String     // "MAD_HELPER_TARGET_CFFIXED_USER_HOME"
      public static func helperEnvironment(shortcut: [String: String], base: [String: String]) -> [String: String]
      public static func targetEnvironment(helper: [String: String]) -> [String: String]
  }
  public enum HelperLogLine {
      public static let execObserved, watchedProcessGone, pidReused, dataPathMismatch, ownPathUnreadable, exiting: String
      public static func spawned(pid: pid_t) -> String               // written by the launcher (Task 5)
      public static func spawnFailed(_ reason: String) -> String     // written by the launcher (Task 5)
      public static func start(helperPID: pid_t, watchedPID: pid_t, bundlePath: String, dataPath: String?) -> String
      public static func malformed(argumentCount: Int) -> String
      public static func watchFailed(_ reason: String) -> String
      public static func targetExited(waitStatus: Int32?) -> String
      public static func launcherFailed(waitStatus: Int32?) -> String
      public static func erased(path: String, removed: Int, failed: Int) -> String
      public static func eraseSkipped(_ reason: String) -> String
      public static func newWindow(argv: [String]) -> String
      public static func newWindowFailed(_ reason: String) -> String
      public static func quit(signal: Int32) -> String
      public static func showFailed(_ reason: String) -> String
      public static func otherCopiesRunning(pids: [pid_t]) -> String // an eraseSkipped line (Task 5)
  }
  ```

- [ ] **Step 1: Write the failing tests.**

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/HelperPlanTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore

final class HelperPlanTests: XCTestCase {
    private static let dataPath = "/Users/test/Library/Application Support/App Duplicator/claude-work"

    private func makeConfig(
        kind: ShortcutKind = .app,
        dataMode: DataMode = .auto,
        dataPath: String? = HelperPlanTests.dataPath,
        eraseOnQuit: Bool = false,
        menuBarIcon: Bool = false
    ) -> ShortcutConfig {
        ShortcutConfig(
            kind: kind,
            name: "Claude Work",
            slug: "claude-work",
            bundleIdentifier: "com.mikekuta.appduplicator.claude-work",
            targetPath: "/Applications/Claude.app",
            targetBundleIdentifier: "com.anthropic.claudefordesktop",
            dataMode: dataMode,
            dataPath: dataPath,
            eraseOnQuit: eraseOnQuit,
            menuBarIcon: menuBarIcon
        )
    }

    func testOnlyApplicationShortcutsWithAMenuBarIconOrAnErasableFolderNeedAHelper() {
        XCTAssertTrue(HelperPlan.isNeeded(for: makeConfig(menuBarIcon: true)))
        XCTAssertTrue(HelperPlan.isNeeded(for: makeConfig(eraseOnQuit: true)))
        XCTAssertFalse(HelperPlan.isNeeded(for: makeConfig()))
        for kind in [ShortcutKind.webApp, .file, .folder, .cli] {
            let config = makeConfig(kind: kind, eraseOnQuit: true, menuBarIcon: true)
            XCTAssertFalse(HelperPlan.isNeeded(for: config), kind.rawValue)
            XCTAssertNil(HelperPlan.eraseDataPath(for: config), kind.rawValue)
        }
    }

    func testEraseDataPathNeedsEraseOnQuitASeparatedModeAndAPath() {
        XCTAssertEqual(HelperPlan.eraseDataPath(for: makeConfig(eraseOnQuit: true)), Self.dataPath)
        XCTAssertEqual(HelperPlan.eraseDataPath(for: makeConfig(dataMode: .homeOverride, eraseOnQuit: true)), Self.dataPath)
        XCTAssertNil(HelperPlan.eraseDataPath(for: makeConfig(eraseOnQuit: false)))
        XCTAssertNil(HelperPlan.eraseDataPath(for: makeConfig(dataMode: .disabled, eraseOnQuit: true)))
        XCTAssertNil(HelperPlan.eraseDataPath(for: makeConfig(dataPath: nil, eraseOnQuit: true)))
        XCTAssertNil(HelperPlan.eraseDataPath(for: makeConfig(dataPath: "", eraseOnQuit: true)))
        // The stored text passes through unchanged; EraseOnQuitPolicy refuses a relative path at run time.
        XCTAssertEqual(HelperPlan.eraseDataPath(for: makeConfig(dataPath: "relative/data", eraseOnQuit: true)), "relative/data")
    }

    func testDisabledDataSeparationLeavesOnlyTheMenuBarIcon() {
        XCTAssertFalse(HelperPlan.isNeeded(for: makeConfig(dataMode: .disabled, eraseOnQuit: true)))
        let withIcon = makeConfig(dataMode: .disabled, eraseOnQuit: true, menuBarIcon: true)
        XCTAssertTrue(HelperPlan.isNeeded(for: withIcon))
        XCTAssertNil(HelperPlan.eraseDataPath(for: withIcon))
    }
}
```

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/HelperArgumentsTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore

final class HelperArgumentsTests: XCTestCase {
    private let launcher = "/Users/test/Applications/App Duplicator/Claude Work.app/Contents/MacOS/Claude Work"
    private let bundle = "/Users/test/Applications/App Duplicator/Claude Work.app"
    private let dataPath = "/Users/test/Library/Application Support/App Duplicator/claude-work"

    func testArgumentsRoundTripThroughParse() {
        let withData = HelperArguments(
            parentPID: 4242,
            startTime: ProcessStartTime(seconds: 1_760_000_000, microseconds: 999_999),
            bundlePath: bundle,
            dataPath: dataPath
        )
        XCTAssertEqual(withData.arguments, ["--helper", "4242", "1760000000", "999999", bundle, dataPath])
        XCTAssertEqual(HelperArguments.parse([launcher] + withData.arguments), withData)

        let withoutData = HelperArguments(
            parentPID: 2, startTime: ProcessStartTime(seconds: 0, microseconds: 0), bundlePath: bundle, dataPath: nil
        )
        XCTAssertEqual(withoutData.arguments.last, "-")
        XCTAssertEqual(HelperArguments.parse([launcher] + withoutData.arguments), withoutData)
    }

    func testOnlyTheFlagInSecondPlaceSelectsTheHelperRole() {
        XCTAssertTrue(HelperArguments.isHelperInvocation([launcher, "--helper"]))
        XCTAssertTrue(HelperArguments.isHelperInvocation([launcher, "--helper", "1"]))
        XCTAssertFalse(HelperArguments.isHelperInvocation([]))
        XCTAssertFalse(HelperArguments.isHelperInvocation([launcher]))
        XCTAssertFalse(HelperArguments.isHelperInvocation([launcher, "-psn_0_12345", "--helper"]))
        XCTAssertFalse(HelperArguments.isHelperInvocation([launcher, "--helper=1"]))
    }

    func testParseRefusesWrongCountsAndBadNumbers() {
        let good = ["--helper", "4242", "1760000000", "5", bundle, dataPath]
        XCTAssertNotNil(HelperArguments.parse([launcher] + good))
        XCTAssertNil(HelperArguments.parse([launcher] + good.dropLast()))
        XCTAssertNil(HelperArguments.parse([launcher] + good + ["extra"]))
        XCTAssertNil(HelperArguments.parse(good))
        let badValues: [(index: Int, value: String)] = [
            (1, "1"), (1, "0"), (1, "-7"), (1, "abc"), (1, "99999999999"),
            (2, "-1"), (2, "1.5"), (3, "1000000"), (3, "x"),
        ]
        for bad in badValues {
            var argv = good
            argv[bad.index] = bad.value
            XCTAssertNil(HelperArguments.parse([launcher] + argv), "\(bad.index) \(bad.value)")
        }
    }

    func testParseRefusesARelativeBundleAndAnEmptyDataPath() {
        XCTAssertNil(HelperArguments.parse([launcher, "--helper", "4242", "1", "2", "Claude Work.app", dataPath]))
        XCTAssertNil(HelperArguments.parse([launcher, "--helper", "4242", "1", "2", "", dataPath]))
        XCTAssertNil(HelperArguments.parse([launcher, "--helper", "4242", "1", "2", bundle, ""]))
        // A relative data path parses; EraseOnQuitPolicy refuses it and the helper logs why.
        XCTAssertEqual(
            HelperArguments.parse([launcher, "--helper", "4242", "1", "2", bundle, "relative/data"])?.dataPath,
            "relative/data"
        )
    }
}
```

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/HelperEnvironmentTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore

final class HelperEnvironmentTests: XCTestCase {
    private let realHome = "/Users/mike"
    private let dataHome = "/Users/mike/Library/Application Support/App Duplicator/claude-work/mike"
    private let bundle = "/Users/mike/Applications/App Duplicator/Claude Work.app"

    func testTheHelperKeepsTheRealHomeAndCarriesTheShortcutMarker() {
        let base = ["HOME": realHome, "PATH": "/usr/bin:/bin", "USER": "mike"]
        let shortcut = [
            "HOME": dataHome, "CFFIXED_USER_HOME": dataHome, "PATH": "/opt/bin:/usr/bin:/bin", "USER": "mike",
            "MAD_SHORTCUT_BUNDLE": bundle, "MAD_SHORTCUT_NAME": "Claude Work", "API_TOKEN": "not-a-real-token",
        ]
        XCTAssertEqual(HelperEnvironment.helperEnvironment(shortcut: shortcut, base: base), [
            "HOME": realHome, "PATH": "/opt/bin:/usr/bin:/bin", "USER": "mike",
            "MAD_SHORTCUT_BUNDLE": bundle, "MAD_SHORTCUT_NAME": "Claude Work", "API_TOKEN": "not-a-real-token",
            "MAD_HELPER_TARGET_HOME": dataHome, "MAD_HELPER_TARGET_CFFIXED_USER_HOME": dataHome,
        ])
    }

    func testTheTargetEnvironmentIsTheShortcutEnvironmentAgain() {
        let cases: [(base: [String: String], shortcut: [String: String])] = [
            (["HOME": realHome], ["HOME": dataHome, "CFFIXED_USER_HOME": dataHome, "MAD_SHORTCUT_BUNDLE": bundle]),
            (["HOME": realHome], ["HOME": realHome, "MAD_SHORTCUT_BUNDLE": bundle]),
            (["HOME": "/tmp/home", "CFFIXED_USER_HOME": "/tmp/home"], ["HOME": dataHome, "CFFIXED_USER_HOME": dataHome]),
            ([:], ["PATH": "/usr/bin"]),
        ]
        for (base, shortcut) in cases {
            let helper = HelperEnvironment.helperEnvironment(shortcut: shortcut, base: base)
            XCTAssertEqual(helper["HOME"], base["HOME"])
            XCTAssertEqual(helper["CFFIXED_USER_HOME"], base["CFFIXED_USER_HOME"])
            XCTAssertEqual(HelperEnvironment.targetEnvironment(helper: helper), shortcut)
        }
    }

    func testStashKeysThatDidNotComeFromTheHelperAreDropped() {
        let shortcut = ["MAD_HELPER_TARGET_HOME": "/stray", "PATH": "/usr/bin"]
        let helper = HelperEnvironment.helperEnvironment(shortcut: shortcut, base: ["HOME": realHome])
        XCTAssertEqual(helper, ["HOME": realHome, "PATH": "/usr/bin"])
        XCTAssertEqual(HelperEnvironment.targetEnvironment(helper: helper), ["PATH": "/usr/bin"])
    }
}
```

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/HelperLogLineTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore

final class HelperLogLineTests: XCTestCase {
    func testLifecycleAndMenuLines() {
        XCTAssertEqual(
            HelperLogLine.start(helperPID: 501, watchedPID: 500, bundlePath: "/Apps/Claude Work.app", dataPath: "/Users/t/data"),
            "helper start pid=501 watch=500 bundle=/Apps/Claude Work.app data=/Users/t/data"
        )
        XCTAssertEqual(
            HelperLogLine.start(helperPID: 501, watchedPID: 500, bundlePath: "/Apps/Claude Work.app", dataPath: nil),
            "helper start pid=501 watch=500 bundle=/Apps/Claude Work.app data=-"
        )
        XCTAssertEqual(HelperLogLine.malformed(argumentCount: 3), "helper malformed argv argc=3")
        XCTAssertEqual(HelperLogLine.execObserved, "helper exec observed")
        XCTAssertEqual(HelperLogLine.watchedProcessGone, "helper watched process already gone")
        XCTAssertEqual(HelperLogLine.watchFailed("kevent errno=9"), "helper watch failed: kevent errno=9")
        XCTAssertEqual(
            HelperLogLine.newWindow(argv: ["/usr/bin/env", "open", "--args", "--api-key=abc", "--token", "t"]),
            "helper new window argv /usr/bin/env open --args --api-key=•••••• --token ••••••"
        )
        XCTAssertEqual(HelperLogLine.newWindowFailed("posix_spawn errno=2"), "helper new window failed: posix_spawn errno=2")
        XCTAssertEqual(HelperLogLine.quit(signal: SIGTERM), "helper quit signal=15")
        XCTAssertEqual(HelperLogLine.showFailed("pid 500 is not an application"), "helper show failed: pid 500 is not an application")
        XCTAssertEqual(HelperLogLine.spawned(pid: 502), "helper spawned pid=502")
        XCTAssertEqual(
            HelperLogLine.spawnFailed("Could not start /x: No such file or directory"),
            "helper spawn failed: Could not start /x: No such file or directory"
        )
        XCTAssertEqual(HelperLogLine.exiting, "helper exit")
    }

    func testExitStatusAndEraseLines() {
        XCTAssertEqual(HelperLogLine.targetExited(waitStatus: 7 << 8), "helper target exited status=7")
        XCTAssertEqual(HelperLogLine.targetExited(waitStatus: 0), "helper target exited status=0")
        XCTAssertEqual(HelperLogLine.targetExited(waitStatus: SIGKILL), "helper target exited status=137")
        XCTAssertEqual(HelperLogLine.targetExited(waitStatus: nil), "helper target exited status=unavailable")
        XCTAssertEqual(HelperLogLine.launcherFailed(waitStatus: 3 << 8), "helper launcher exited before exec status=3")
        XCTAssertEqual(HelperLogLine.pidReused, "helper watched pid was reused")
        XCTAssertEqual(HelperLogLine.erased(path: "/Users/t/data", removed: 4, failed: 0), "helper erase /Users/t/data removed=4")
        XCTAssertEqual(
            HelperLogLine.erased(path: "/Users/t/data", removed: 4, failed: 2),
            "helper erase /Users/t/data removed=4 failed=2"
        )
        XCTAssertEqual(HelperLogLine.eraseSkipped("the path is a symbolic link"), "helper erase skipped: the path is a symbolic link")
        XCTAssertEqual(HelperLogLine.dataPathMismatch, "helper erase skipped: the data path does not match MADConfig")
        XCTAssertEqual(
            HelperLogLine.otherCopiesRunning(pids: [41, 42]),
            "helper erase skipped: another copy of this shortcut is still running (pid 41,42)"
        )
        XCTAssertEqual(HelperLogLine.ownPathUnreadable, "helper erase skipped: the helper cannot read its own executable path")
    }
}
```

- [ ] **Step 2: Run them and watch them fail.**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.HelperPlanTests 2>&1 | grep -E "error:" | head -5`
Expected: compile errors, among them `cannot find 'HelperPlan' in scope`, `cannot find 'HelperArguments' in scope`, `cannot find 'ProcessStartTime' in scope`, `cannot find 'HelperEnvironment' in scope` and `cannot find 'HelperLogLine' in scope`.

- [ ] **Step 3: Create `Packages/DuplicatorCore/Sources/DuplicatorCore/ProcessStartTime.swift`** (the value type; Task 4 appends the reader to this file).

```swift
import Foundation

/// When a process started, as `proc_pidinfo(PROC_PIDTBSDINFO)` reports it (`pbi_start_tvsec`, `pbi_start_tvusec`).
/// `execve` keeps it, so the helper can tell the launcher that became the target apart from a later process that reused
/// its pid (spec §4.6).
public struct ProcessStartTime: Hashable, Sendable {
    public var seconds: UInt64
    public var microseconds: UInt64

    public init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }
}
```

- [ ] **Step 4: Create `Packages/DuplicatorCore/Sources/DuplicatorCore/HelperPlan.swift`.**

```swift
import Foundation

/// Whether an application shortcut needs the spec §4.6 helper, and which folder erase-on-quit may empty. Only `.app`
/// shortcuts have one: WebShell owns the status item of web apps, and file, folder and command shortcuts exit at once.
public enum HelperPlan {
    /// True for an application shortcut with the menu bar icon on or an erasable data folder.
    public static func isNeeded(for config: ShortcutConfig) -> Bool {
        config.kind == .app && (config.menuBarIcon || eraseDataPath(for: config) != nil)
    }

    /// The stored data folder when erase-on-quit applies: an application shortcut with `eraseOnQuit` on, data separation
    /// not disabled and a non-empty `dataPath`. Never touches the file system; `EraseOnQuitPolicy` checks the path again
    /// at run time.
    public static func eraseDataPath(for config: ShortcutConfig) -> String? {
        guard config.kind == .app, config.eraseOnQuit, config.dataMode != .disabled,
              let dataPath = config.dataPath, !dataPath.isEmpty else { return nil }
        return dataPath
    }
}
```

- [ ] **Step 5: Create `Packages/DuplicatorCore/Sources/DuplicatorCore/HelperArguments.swift`.**

```swift
import Foundation

/// The helper role's argv (spec §3.4 step 5, §4.6):
/// `<launcher> --helper <parentPid> <startSeconds> <startMicroseconds> <bundlePath> <dataPath|->`.
/// The launcher builds it just before `execve`; `main.swift` parses it before it reads `MADConfig` or logs anything.
public struct HelperArguments: Equatable, Sendable {
    public static let flag = "--helper"
    /// Stands for "no data folder to erase".
    public static let noDataPath = "-"

    /// The process to watch: the launcher, which becomes the target when it execs.
    public var parentPID: pid_t
    /// `parentPID`'s start time, read by the launcher itself; a different value later means the pid was reused.
    public var startTime: ProcessStartTime
    /// The shortcut bundle, for the status item icon and the log.
    public var bundlePath: String
    /// The folder erase-on-quit empties, or nil.
    public var dataPath: String?

    public init(parentPID: pid_t, startTime: ProcessStartTime, bundlePath: String, dataPath: String?) {
        self.parentPID = parentPID
        self.startTime = startTime
        self.bundlePath = bundlePath
        self.dataPath = dataPath
    }

    /// argv after argv[0].
    public var arguments: [String] {
        [
            Self.flag, String(parentPID), String(startTime.seconds), String(startTime.microseconds),
            bundlePath, dataPath ?? Self.noDataPath,
        ]
    }

    /// True when `argv[1]` is exactly `--helper`. LaunchServices never passes that, so a normal launch never matches.
    public static func isHelperInvocation(_ argv: [String]) -> Bool {
        argv.count >= 2 && argv[1] == flag
    }

    /// The invocation `argv` (argv[0] included) describes, or nil unless it has exactly the shape `arguments` produces:
    /// a pid above 1, decimal start seconds, start microseconds below 1,000,000, an absolute bundle path and a
    /// non-empty data path (`-` for none).
    public static func parse(_ argv: [String]) -> HelperArguments? {
        guard argv.count == 7, argv[1] == flag,
              let pid = pid_t(argv[2]), pid > 1,
              let seconds = UInt64(argv[3]),
              let microseconds = UInt64(argv[4]), microseconds < 1_000_000,
              argv[5].hasPrefix("/"),
              !argv[6].isEmpty
        else { return nil }
        return HelperArguments(
            parentPID: pid,
            startTime: ProcessStartTime(seconds: seconds, microseconds: microseconds),
            bundlePath: argv[5],
            dataPath: argv[6] == noDataPath ? nil : argv[6]
        )
    }
}
```

- [ ] **Step 6: Create `Packages/DuplicatorCore/Sources/DuplicatorCore/HelperEnvironment.swift`.**

```swift
import Foundation

/// The helper runs with the shortcut's environment, so `MAD_SHORTCUT_BUNDLE` keeps the app's running indicator on and
/// New Window sees the shortcut's variables, except `HOME` and `CFFIXED_USER_HOME`: those keep the launcher's own values,
/// because the helper's log and `EraseOnQuitPolicy` must resolve the real home, never the data folder (spec §4.3, §4.6).
/// The shortcut's two values travel under the `MAD_HELPER_TARGET_*` keys and come back for New Window.
public enum HelperEnvironment {
    public static let targetHomeKey = "MAD_HELPER_TARGET_HOME"
    public static let targetFixedHomeKey = "MAD_HELPER_TARGET_CFFIXED_USER_HOME"

    /// Each home variable and the key that carries the shortcut's value inside the helper.
    static let stashedKeys: [(key: String, stash: String)] = [("HOME", targetHomeKey), ("CFFIXED_USER_HOME", targetFixedHomeKey)]

    /// `shortcut` with `HOME` and `CFFIXED_USER_HOME` taken from `base` (removed where `base` has none) and the
    /// shortcut's own values stored under the stash keys (removed where the shortcut has none).
    public static func helperEnvironment(shortcut: [String: String], base: [String: String]) -> [String: String] {
        var environment = shortcut
        for (key, stash) in stashedKeys {
            environment[stash] = shortcut[key]
            environment[key] = base[key]
        }
        return environment
    }

    /// The shortcut environment again: both home variables restored from the stash keys, the stash keys removed.
    public static func targetEnvironment(helper: [String: String]) -> [String: String] {
        var environment = helper
        for (key, stash) in stashedKeys {
            environment[key] = helper[stash]
            environment[stash] = nil
        }
        return environment
    }
}
```

- [ ] **Step 7: Create `Packages/DuplicatorCore/Sources/DuplicatorCore/HelperLogLine.swift`.**

```swift
import Foundation

/// Every helper line in the shortcut's launcher log (spec §4.6, §4.7), including the two the launcher writes when it starts
/// the helper (`spawned`, `spawnFailed`). Paths are logged as they are, like the
/// launcher's own `start` and `target` lines; the New Window argv goes through `SecretMasking.maskArguments`, like the
/// launcher's `argv` line.
public enum HelperLogLine {
    public static let execObserved = "helper exec observed"
    public static let watchedProcessGone = "helper watched process already gone"
    public static let pidReused = "helper watched pid was reused"
    public static let dataPathMismatch = "helper erase skipped: the data path does not match MADConfig"
    public static let ownPathUnreadable = "helper erase skipped: the helper cannot read its own executable path"
    public static let exiting = "helper exit"

    public static func spawned(pid: pid_t) -> String {
        "helper spawned pid=\(pid)"
    }

    /// The launch goes on without a helper.
    public static func spawnFailed(_ reason: String) -> String {
        "helper spawn failed: \(reason)"
    }

    public static func start(helperPID: pid_t, watchedPID: pid_t, bundlePath: String, dataPath: String?) -> String {
        "helper start pid=\(helperPID) watch=\(watchedPID) bundle=\(bundlePath) data=\(dataPath ?? HelperArguments.noDataPath)"
    }

    public static func malformed(argumentCount: Int) -> String {
        "helper malformed argv argc=\(argumentCount)"
    }

    public static func watchFailed(_ reason: String) -> String {
        "helper watch failed: \(reason)"
    }

    /// `status=` is what a shell reports (the exit code, or 128 + the signal number), or `unavailable` when the kernel
    /// gave no status.
    public static func targetExited(waitStatus: Int32?) -> String {
        "helper target exited status=\(statusText(waitStatus))"
    }

    public static func launcherFailed(waitStatus: Int32?) -> String {
        "helper launcher exited before exec status=\(statusText(waitStatus))"
    }

    public static func erased(path: String, removed: Int, failed: Int) -> String {
        failed == 0 ? "helper erase \(path) removed=\(removed)" : "helper erase \(path) removed=\(removed) failed=\(failed)"
    }

    public static func eraseSkipped(_ reason: String) -> String {
        "helper erase skipped: \(reason)"
    }

    public static func newWindow(argv: [String]) -> String {
        "helper new window argv \(SecretMasking.maskArguments(argv).joined(separator: " "))"
    }

    public static func newWindowFailed(_ reason: String) -> String {
        "helper new window failed: \(reason)"
    }

    public static func quit(signal: Int32) -> String {
        "helper quit signal=\(signal)"
    }

    public static func showFailed(_ reason: String) -> String {
        "helper show failed: \(reason)"
    }

    /// Another process runs the shortcut's launcher binary: another copy's helper, a launch in progress or a System Launch
    /// launcher. That copy may still be using the data folder, so nothing is erased.
    public static func otherCopiesRunning(pids: [pid_t]) -> String {
        eraseSkipped("another copy of this shortcut is still running (pid \(pids.map { String($0) }.joined(separator: ",")))")
    }

    /// A `waitpid` status in shell form. (`WIFEXITED` and friends are C macros that Swift does not import.)
    static func statusText(_ waitStatus: Int32?) -> String {
        guard let waitStatus else { return "unavailable" }
        let signal = waitStatus & 0x7f
        return String(signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal)
    }
}
```

- [ ] **Step 8: Run the suites and watch them pass.**

Run: `cd ~/Developer/MacAppDuplicator && for suite in HelperPlanTests HelperArgumentsTests HelperEnvironmentTests HelperLogLineTests; do swift test --filter DuplicatorCoreTests.$suite 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1; done`
Expected, in order:
```
Executed 3 tests, with 0 failures (0 unexpected) in …
Executed 4 tests, with 0 failures (0 unexpected) in …
Executed 3 tests, with 0 failures (0 unexpected) in …
Executed 2 tests, with 0 failures (0 unexpected) in …
```

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: `Executed 257 tests, with 0 failures (0 unexpected) in …`

- [ ] **Step 9: Forbidden constructs.**

Run: `cd ~/Developer/MacAppDuplicator && grep -nE 'try\?|@unchecked|swiftlint:disable|nonisolated\(unsafe\)' Packages/DuplicatorCore/Sources/DuplicatorCore/{HelperPlan,HelperArguments,ProcessStartTime,HelperEnvironment,HelperLogLine}.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/{HelperPlanTests,HelperArgumentsTests,HelperEnvironmentTests,HelperLogLineTests}.swift`
Expected: no output.

- [ ] **Step 10: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add Packages/DuplicatorCore/Sources/DuplicatorCore/HelperPlan.swift Packages/DuplicatorCore/Sources/DuplicatorCore/HelperArguments.swift Packages/DuplicatorCore/Sources/DuplicatorCore/ProcessStartTime.swift Packages/DuplicatorCore/Sources/DuplicatorCore/HelperEnvironment.swift Packages/DuplicatorCore/Sources/DuplicatorCore/HelperLogLine.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/HelperPlanTests.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/HelperArgumentsTests.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/HelperEnvironmentTests.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/HelperLogLineTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Core: helper plan, argv, environment and log lines" -m "HelperPlan decides when an application shortcut needs the spec 4.6 helper and which folder erase-on-quit may empty. HelperArguments builds and strictly parses --helper <pid> <startSec> <startUsec> <bundle> <data|->. HelperEnvironment keeps the real HOME in the helper and carries the shortcut's home values for New Window. HelperLogLine pins every helper log line." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Deviations

- The helper argv adds the parent's start time and the data path to the spec's `--helper <parentPid> <bundlePath>`: the start time must come from the parent (spec §4.6 "captured at fork"), and the data path pins the folder the target actually used at launch. Task 10 updates spec §4.6.
- `HelperEnvironment` is new: without it the helper would inherit the target's `HOME`/`CFFIXED_USER_HOME`, so in HOME override mode its log and the erase guard's home would point into the folder being erased.
- `helper start` names both its own pid and the watched pid (`pid=<own> watch=<watched>`) where the Global Constraints sketch `pid=<parent>`; a missing kernel exit status logs `status=unavailable`.
- `HelperLogLine` also holds the launcher's two lines about starting the helper (`helper spawned pid=`, `helper spawn failed:`) and three lines Tasks 5 and 6 need (`helper show failed:`, the other-copies and own-path erase skips), so every helper string is unit-tested in one place; the only later Core tests are Task 6's four `HelperPlan` menu bar decisions.

---

### Task 3: Core: `EraseOnQuitPolicy` and `EraseOnQuitPerformer`

**Files:**
- Create: `Packages/DuplicatorCore/Sources/DuplicatorCore/EraseOnQuitPolicy.swift`, `.../EraseOnQuitPerformer.swift`
- Test: create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/EraseOnQuitPolicyTests.swift`, `.../EraseOnQuitPerformerTests.swift`

**Interfaces:**
- Consumes: Darwin `lstat`, `realpath`, `S_IFMT`/`S_IFDIR`/`S_IFLNK` (all `mode_t` in the SDK's `Darwin.swiftinterface`), `ShortcutConfig.defaultDataPath(forSlug:home:)` (`ShortcutConfig.swift` lines 182-187, tests only), `HelperLogLine.eraseSkipped(_:)` (Task 2, one test), test support `makeTemporaryDirectory()` and `FixtureError` (`TestSupport.swift`).
- Produces:
  ```swift
  public enum EraseOnQuitRefusal: Error, Equatable {
      case malformedPath, missing, unreadable(errno: Int32), symbolicLink, notDirectory, homeUnresolvable
      case outsideHome, home, homeChild, protectedFolder(String), libraryChild, dataRoot, tooShallow
      public var logReason: String { get }
  }
  public enum EraseOnQuitPolicy {
      public static let protectedFolders: [String]
      public static func check(dataPath: String, home: URL) -> Result<URL, EraseOnQuitRefusal>
      static func checkShape(_ path: [String], home: [String]) -> EraseOnQuitRefusal?   // internal, pure
  }
  public struct EraseOnQuitOutcome: Equatable, Sendable {
      public var removed: Int
      public var failures: [String]
      public init(removed: Int = 0, failures: [String] = [])
  }
  public enum EraseOnQuitPerformer {
      public static func erase(at directory: URL, fileManager: FileManager = .default) -> EraseOnQuitOutcome
  }
  ```
- Callers (Task 5 and Task 6) always erase the URL that `check` returns, never the configured string, and log `HelperLogLine.erased(path: url.path, removed: outcome.removed, failed: outcome.failures.count)` or `HelperLogLine.eraseSkipped(refusal.logReason)`.

The App's `CanonicalPath` and `ShortcutConfig.dataRoot(home:)` are App-target types, so Core canonicalises on its own: `realpath(3)` on the parent of the data folder and on the home folder (the data folder itself must not be a symlink, so `lstat` checks it first), then compares components after NFC normalisation and lowercasing (APFS is case-insensitive). Test homes live under `/var/folders`, a symlink to `/private/var`; both sides go through the same `realpath`, so they compare equal.

- [ ] **Step 1: Write the failing tests.**

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/EraseOnQuitPolicyTests.swift`:

```swift
import Darwin
import XCTest
@testable import DuplicatorCore

final class EraseOnQuitPolicyTests: XCTestCase {
    /// `realpath(3)` of an existing path, the form `check` returns (`/var/folders/…` becomes `/private/var/folders/…`).
    private func resolved(_ url: URL) throws -> String {
        guard let pointer = realpath(url.path, nil) else {
            throw FixtureError(description: "realpath failed for \(url.path): errno \(errno)")
        }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    @discardableResult
    private func makeFolder(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func defaultFolder(slug: String, home: URL) -> URL {
        URL(fileURLWithPath: ShortcutConfig.defaultDataPath(forSlug: slug, home: home), isDirectory: true)
    }

    func testAcceptsDefaultAndCustomFoldersAndReturnsTheResolvedURL() throws {
        let home = try makeTemporaryDirectory()
        let notes = try makeFolder(defaultFolder(slug: "notes-work", home: home))
        let custom = try makeFolder(home.appending(path: "Work/Notes Data", directoryHint: .isDirectory))

        XCTAssertEqual(EraseOnQuitPolicy.check(dataPath: notes.path, home: home).map(\.path), .success(try resolved(notes)))
        XCTAssertEqual(EraseOnQuitPolicy.check(dataPath: custom.path + "/", home: home).map(\.path), .success(try resolved(custom)))
    }

    func testRefusesMalformedMissingAndUnresolvablePaths() throws {
        let home = try makeTemporaryDirectory()
        let notes = try makeFolder(home.appending(path: "Work/Notes", directoryHint: .isDirectory))

        XCTAssertEqual(EraseOnQuitPolicy.check(dataPath: "", home: home), .failure(.malformedPath))
        XCTAssertEqual(EraseOnQuitPolicy.check(dataPath: "/", home: home), .failure(.malformedPath))
        XCTAssertEqual(EraseOnQuitPolicy.check(dataPath: "Work/Notes", home: home), .failure(.malformedPath))
        XCTAssertEqual(EraseOnQuitPolicy.check(dataPath: home.path + "/Work/Notes/../Notes", home: home), .failure(.malformedPath))
        XCTAssertEqual(EraseOnQuitPolicy.check(dataPath: home.path + "/Work/./Notes", home: home), .failure(.malformedPath))
        XCTAssertEqual(EraseOnQuitPolicy.check(dataPath: home.path + "/Work/Missing", home: home), .failure(.missing))
        XCTAssertEqual(
            EraseOnQuitPolicy.check(dataPath: notes.path, home: home.appending(path: "No Such Home", directoryHint: .isDirectory)),
            .failure(.homeUnresolvable)
        )
    }

    func testRefusesADataFolderThatIsASymbolicLinkOrAFile() throws {
        let home = try makeTemporaryDirectory()
        let real = try makeFolder(home.appending(path: "Work/Real", directoryHint: .isDirectory))
        let root = try makeFolder(defaultFolder(slug: "linked", home: home).deletingLastPathComponent())
        let link = root.appending(path: "linked", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let file = home.appending(path: "Work/notes.txt", directoryHint: .notDirectory)
        try Data("x".utf8).write(to: file)

        XCTAssertEqual(EraseOnQuitPolicy.check(dataPath: link.path, home: home), .failure(.symbolicLink))
        XCTAssertEqual(EraseOnQuitPolicy.check(dataPath: link.path + "/", home: home), .failure(.symbolicLink))
        XCTAssertEqual(EraseOnQuitPolicy.check(dataPath: file.path, home: home), .failure(.notDirectory))
    }

    func testResolvesSymbolicLinksAboveTheFolderBeforeCheckingWhereItIs() throws {
        let home = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        try makeFolder(outside.appending(path: "a/b", directoryHint: .isDirectory))
        let work = try makeFolder(home.appending(path: "Work", directoryHint: .isDirectory))
        try FileManager.default.createSymbolicLink(at: work.appending(path: "Escape", directoryHint: .notDirectory), withDestinationURL: outside)
        let notes = try makeFolder(defaultFolder(slug: "notes", home: home))
        try FileManager.default.createSymbolicLink(
            at: work.appending(path: "RootLink", directoryHint: .notDirectory),
            withDestinationURL: notes.deletingLastPathComponent()
        )

        XCTAssertEqual(EraseOnQuitPolicy.check(dataPath: work.path + "/Escape/a/b", home: home), .failure(.outsideHome))
        XCTAssertEqual(EraseOnQuitPolicy.check(dataPath: outside.path + "/a/b", home: home), .failure(.outsideHome))
        XCTAssertEqual(
            EraseOnQuitPolicy.check(dataPath: work.path + "/RootLink/notes", home: home).map(\.path),
            .success(try resolved(notes))
        )
    }

    func testRefusesTheHomeItsDirectChildrenLibraryChildrenAndTheDataRootOnDisk() throws {
        let home = try makeTemporaryDirectory()
        let root = try makeFolder(defaultFolder(slug: "notes", home: home).deletingLastPathComponent())
        let expectations: [(relativePath: String, refusal: EraseOnQuitRefusal)] = [
            ("", .home),
            ("Documents", .protectedFolder("Documents")),
            ("DOWNLOADS", .protectedFolder("Downloads")),
            ("Library", .protectedFolder("Library")),
            ("Work", .homeChild),
            ("Library/Application Support", .libraryChild),
            ("Library/Preferences", .libraryChild),
        ]
        for expectation in expectations {
            let folder = try expectation.relativePath.isEmpty
                ? home
                : makeFolder(home.appending(path: expectation.relativePath, directoryHint: .isDirectory))
            XCTAssertEqual(
                EraseOnQuitPolicy.check(dataPath: folder.path, home: home),
                .failure(expectation.refusal),
                expectation.relativePath
            )
        }
        XCTAssertEqual(EraseOnQuitPolicy.check(dataPath: root.path, home: home), .failure(.dataRoot))
    }

    func testShapeRulesOnResolvedComponents() {
        let home = ["Users", "test"]
        XCTAssertNil(EraseOnQuitPolicy.checkShape(["Users", "test", "Work", "Notes"], home: home))
        XCTAssertNil(EraseOnQuitPolicy.checkShape(["Users", "test", "Library", "Application Support", "App Duplicator", "notes"], home: home))
        XCTAssertNil(EraseOnQuitPolicy.checkShape(["Users", "Jose\u{301}", "Work", "Notes"], home: ["Users", "Jos\u{E9}"]))
        XCTAssertEqual(EraseOnQuitPolicy.checkShape(["Users", "other", "Work", "Notes"], home: home), .outsideHome)
        XCTAssertEqual(EraseOnQuitPolicy.checkShape(["Users"], home: home), .outsideHome)
        XCTAssertEqual(EraseOnQuitPolicy.checkShape(["Users", "TEST"], home: home), .home)
        XCTAssertEqual(EraseOnQuitPolicy.checkShape(["Users", "test", "applications"], home: home), .protectedFolder("Applications"))
        XCTAssertEqual(EraseOnQuitPolicy.checkShape(["Users", "test", "library", "caches"], home: home), .libraryChild)
        XCTAssertEqual(EraseOnQuitPolicy.checkShape(["Users", "test", "Library", "Application Support", "app duplicator"], home: home), .dataRoot)
        XCTAssertEqual(EraseOnQuitPolicy.checkShape(["u", "x", "y"], home: ["u"]), .tooShallow)
        XCTAssertNil(EraseOnQuitPolicy.checkShape(["u", "x", "y", "z"], home: ["u"]))
    }

    func testEveryRefusalHasADistinctLogReason() {
        let refusals: [EraseOnQuitRefusal] = [
            .malformedPath, .missing, .unreadable(errno: EACCES), .symbolicLink, .notDirectory, .homeUnresolvable,
            .outsideHome, .home, .homeChild, .protectedFolder("Documents"), .libraryChild, .dataRoot, .tooShallow,
        ]
        XCTAssertEqual(Set(refusals.map(\.logReason)).count, refusals.count)
        XCTAssertEqual(EraseOnQuitRefusal.symbolicLink.logReason, "the path is a symbolic link")
        XCTAssertEqual(EraseOnQuitRefusal.protectedFolder("Documents").logReason, "the folder is ~/Documents")
        XCTAssertEqual(EraseOnQuitRefusal.unreadable(errno: EACCES).logReason, "the path cannot be inspected (errno 13)")
        XCTAssertEqual(
            HelperLogLine.eraseSkipped(EraseOnQuitRefusal.dataRoot.logReason),
            "helper erase skipped: the folder is the App Duplicator data root"
        )
    }
}
```

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/EraseOnQuitPerformerTests.swift`:

```swift
import Darwin
import XCTest
@testable import DuplicatorCore

final class EraseOnQuitPerformerTests: XCTestCase {
    func testRemovesEveryChildIncludingHiddenOnesAndKeepsTheFolder() throws {
        let data = try makeTemporaryDirectory().appending(path: "Data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data.appending(path: "Sub/Deeper", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: data.appending(path: "a.txt", directoryHint: .notDirectory))
        try Data("h".utf8).write(to: data.appending(path: ".hidden", directoryHint: .notDirectory))
        try Data("d".utf8).write(to: data.appending(path: "Sub/Deeper/d.txt", directoryHint: .notDirectory))

        let outcome = EraseOnQuitPerformer.erase(at: data)

        XCTAssertEqual(outcome, EraseOnQuitOutcome(removed: 3, failures: []))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: data.path), [])
    }

    func testSymbolicLinksAtAnyDepthAreRemovedWithoutTouchingTheirTargets() throws {
        let sandbox = try makeTemporaryDirectory()
        let outside = sandbox.appending(path: "Outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let kept = outside.appending(path: "keep.txt", directoryHint: .notDirectory)
        try Data("keep".utf8).write(to: kept)
        let data = sandbox.appending(path: "Data", directoryHint: .isDirectory)
        let nested = data.appending(path: "Library/Preferences", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: data.appending(path: "Documents", directoryHint: .notDirectory), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: nested.appending(path: "Shared", directoryHint: .notDirectory), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: data.appending(path: "keep-link.txt", directoryHint: .notDirectory), withDestinationURL: kept)

        let outcome = EraseOnQuitPerformer.erase(at: data)

        XCTAssertEqual(outcome, EraseOnQuitOutcome(removed: 3, failures: []))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: data.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["keep.txt"])
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), "keep")
    }

    func testAChildThatCannotBeRemovedIsReportedAndTheRestAreStillRemoved() throws {
        let data = try makeTemporaryDirectory().appending(path: "Data", directoryHint: .isDirectory)
        let locked = data.appending(path: "Locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appending(path: "inside.txt", directoryHint: .notDirectory))
        try Data("a".utf8).write(to: data.appending(path: "a.txt", directoryHint: .notDirectory))
        XCTAssertEqual(chmod(locked.path, 0o500), 0)
        defer { XCTAssertEqual(chmod(locked.path, 0o700), 0) }

        let outcome = EraseOnQuitPerformer.erase(at: data)

        XCTAssertEqual(outcome, EraseOnQuitOutcome(removed: 1, failures: ["Locked"]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: data.path), ["Locked"])
    }
}
```

(The `defer` restores write permission before the `makeTemporaryDirectory()` teardown block deletes the sandbox.)

- [ ] **Step 2: Run the tests and watch them fail to compile.**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.EraseOnQuitPolicyTests 2>&1 | grep -E "error:" | head -3`
Expected (first lines):
```
…/EraseOnQuitPerformerTests.swift:…: error: cannot find 'EraseOnQuitPerformer' in scope
…/EraseOnQuitPolicyTests.swift:…: error: cannot find 'EraseOnQuitPolicy' in scope
```
(The order of the two files may differ; both names must be reported missing.)

- [ ] **Step 3: Write `EraseOnQuitPolicy.swift`.**

Create `Packages/DuplicatorCore/Sources/DuplicatorCore/EraseOnQuitPolicy.swift`:

```swift
import Darwin
import Foundation

/// Why `EraseOnQuitPolicy` refused a data folder. The helper logs `logReason` and erases nothing (spec §4.3).
public enum EraseOnQuitRefusal: Error, Equatable {
    case malformedPath
    case missing
    case unreadable(errno: Int32)
    case symbolicLink
    case notDirectory
    case homeUnresolvable
    case outsideHome
    case home
    case homeChild
    case protectedFolder(String)
    case libraryChild
    case dataRoot
    case tooShallow

    public var logReason: String {
        switch self {
        case .malformedPath: "the path is not a normalised absolute path"
        case .missing: "the folder does not exist"
        case .unreadable(let code): "the path cannot be inspected (errno \(code))"
        case .symbolicLink: "the path is a symbolic link"
        case .notDirectory: "the path is not a folder"
        case .homeUnresolvable: "the home folder cannot be resolved"
        case .outsideHome: "the folder is outside the home folder"
        case .home: "the folder is the home folder"
        case .homeChild: "the folder is directly inside the home folder"
        case .protectedFolder(let name): "the folder is ~/\(name)"
        case .libraryChild: "the folder is directly inside ~/Library"
        case .dataRoot: "the folder is the App Duplicator data root"
        case .tooShallow: "the folder is fewer than four levels below /"
        }
    }
}

/// The hard guard in front of erase-on-quit (spec §4.3). It trusts neither the config nor the caller: the folder must
/// exist, must be a real folder rather than a symbolic link, and, after every symbolic link above it is resolved, must
/// sit at least two levels inside the home folder, away from `~/Library`'s direct children and the App Duplicator data
/// root. Callers erase the URL this returns, never the configured string.
public enum EraseOnQuitPolicy {
    /// Folders directly inside the home folder, named in the refusal. Every other direct child is refused as well.
    public static let protectedFolders = ["Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public"]
    /// `<home>/Library/Application Support/App Duplicator`, the parent of every default data folder
    /// (`ShortcutConfig.defaultDataPath(forSlug:home:)`).
    static let dataRootComponents = ["Library", "Application Support", "App Duplicator"]
    /// The shortest path accepted, counted in components below `/`.
    static let minimumComponentCount = 4

    public static func check(dataPath: String, home: URL) -> Result<URL, EraseOnQuitRefusal> {
        let components = dataPath.split(separator: "/").map(String.init)
        guard dataPath.hasPrefix("/"), let name = components.last, !components.contains(where: { $0 == "." || $0 == ".." }) else {
            return .failure(.malformedPath)
        }
        // No trailing slash: `lstat("<link>/")` would follow the link.
        let path = "/" + components.joined(separator: "/")
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let code = errno
            return .failure(code == ENOENT ? .missing : .unreadable(errno: code))
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            break
        case S_IFLNK:
            return .failure(.symbolicLink)
        default:
            return .failure(.notDirectory)
        }
        guard let parent = resolvedComponents("/" + components.dropLast().joined(separator: "/")) else {
            return .failure(.unreadable(errno: errno))
        }
        guard let homeComponents = resolvedComponents(home.path) else {
            return .failure(.homeUnresolvable)
        }
        let resolved = parent + [name]
        if let refusal = checkShape(resolved, home: homeComponents) {
            return .failure(refusal)
        }
        return .success(URL(fileURLWithPath: "/" + resolved.joined(separator: "/"), isDirectory: true))
    }

    /// The location rules on already resolved components; no file-system access. `nil` means the folder may be emptied.
    static func checkShape(_ path: [String], home: [String]) -> EraseOnQuitRefusal? {
        let folded = path.map(fold)
        let foldedHome = home.map(fold)
        guard folded.starts(with: foldedHome) else {
            return .outsideHome
        }
        let relative = Array(folded.dropFirst(foldedHome.count))
        if relative.isEmpty {
            return .home
        }
        if relative.count == 1 {
            if let named = protectedFolders.first(where: { fold($0) == relative[0] }) {
                return .protectedFolder(named)
            }
            return .homeChild
        }
        if relative.count == 2, relative[0] == fold("Library") {
            return .libraryChild
        }
        if relative == dataRootComponents.map(fold) {
            return .dataRoot
        }
        if path.count < minimumComponentCount {
            return .tooShallow
        }
        return nil
    }

    /// APFS compares names case-insensitively after Unicode normalisation, so the guard does too.
    static func fold(_ component: String) -> String {
        component.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// `realpath(3)` split into components, or `nil` with `errno` set.
    private static func resolvedComponents(_ path: String) -> [String]? {
        guard let pointer = realpath(path, nil) else {
            return nil
        }
        defer { free(pointer) }
        return String(cString: pointer).split(separator: "/").map(String.init)
    }
}
```

- [ ] **Step 4: Write `EraseOnQuitPerformer.swift`.**

Create `Packages/DuplicatorCore/Sources/DuplicatorCore/EraseOnQuitPerformer.swift`:

```swift
import Foundation

/// What one erase-on-quit pass did.
public struct EraseOnQuitOutcome: Equatable, Sendable {
    /// Direct children removed.
    public var removed: Int
    /// Names of the direct children that could not be removed; `.` when the folder itself could not be listed or recreated.
    public var failures: [String]

    public init(removed: Int = 0, failures: [String] = []) {
        self.removed = removed
        self.failures = failures
    }
}

/// Empties a folder that `EraseOnQuitPolicy.check` accepted (spec §4.3, §4.6). Every direct child, hidden ones included,
/// goes through `FileManager.removeItem(at:)`, which unlinks symbolic links at any depth instead of following them, so the
/// HOME override tree's links into the real home lose only the links. The folder itself stays (it is recreated if it
/// vanished) and nothing above it is touched.
public enum EraseOnQuitPerformer {
    public static func erase(at directory: URL, fileManager: FileManager = .default) -> EraseOnQuitOutcome {
        var outcome = EraseOnQuitOutcome()
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
        } catch {
            outcome.failures.append(".")
            return outcome
        }
        for child in children {
            do {
                try fileManager.removeItem(at: child)
                outcome.removed += 1
            } catch {
                outcome.failures.append(child.lastPathComponent)
            }
        }
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            } catch {
                outcome.failures.append(".")
            }
        }
        return outcome
    }
}
```

- [ ] **Step 5: Run the suites and watch them pass.**

Run: `cd ~/Developer/MacAppDuplicator && for suite in EraseOnQuitPolicyTests EraseOnQuitPerformerTests; do swift test --filter DuplicatorCoreTests.$suite 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1; done`
Expected, in order:
```
Executed 7 tests, with 0 failures (0 unexpected) in …
Executed 3 tests, with 0 failures (0 unexpected) in …
```

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: `Executed 267 tests, with 0 failures (0 unexpected) in …`

If `testAChildThatCannotBeRemovedIsReportedAndTheRestAreStillRemoved` reports `removed: 2`, `FileManager` removed the read-only folder anyway: stop and report it (do not weaken the test); the policy and the other tests do not depend on it.

- [ ] **Step 6: Forbidden constructs.**

Run: `cd ~/Developer/MacAppDuplicator && grep -nE 'try\?|@unchecked|swiftlint:disable|nonisolated\(unsafe\)' Packages/DuplicatorCore/Sources/DuplicatorCore/{EraseOnQuitPolicy,EraseOnQuitPerformer}.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/{EraseOnQuitPolicyTests,EraseOnQuitPerformerTests}.swift`
Expected: no output.

- [ ] **Step 7: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add Packages/DuplicatorCore/Sources/DuplicatorCore/EraseOnQuitPolicy.swift Packages/DuplicatorCore/Sources/DuplicatorCore/EraseOnQuitPerformer.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/EraseOnQuitPolicyTests.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/EraseOnQuitPerformerTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Core: erase-on-quit guard and symlink-safe erase" -m "EraseOnQuitPolicy refuses malformed, missing, symlinked and non-folder paths, then resolves every symlink above the folder and refuses anything outside the home, the home and its direct children, the direct children of ~/Library and the App Duplicator data root. EraseOnQuitPerformer removes each direct child of the accepted folder without following symlinks and keeps the folder." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Deviations

- `check(dataPath:home:)` has no `fileManager:` parameter (the Global Constraints sketch had one): it uses `lstat`/`realpath` directly, so no `try`/`catch` is needed to tell a missing folder from an unreadable one. It returns the resolved URL, like `DataPathGuard`, and callers erase that URL.
- Refusals beyond the Global Constraints list: `.`/`..` components, every direct child of the home (parity with `DataPathGuard`'s shallow-path rule; the named protected list adds `Applications`, where shortcuts usually live), every direct child of `~/Library` (covers `Library/Application Support`), and the App Duplicator data root itself (erasing it would wipe every shortcut's data). Symlinks above the folder are resolved before the location rules run, so a link that escapes the home is refused.
- `EraseOnQuitOutcome` (removed count plus failed child names) is new, so the log line can report a partial erase.
- Core canonicalises paths with its own `realpath` and NFC/lowercase folding because the App's `CanonicalPath` is not visible to Core.

---

### Task 4: Core: `ProcessStartTime` reader, `ProcessWatcher`, `HelperWatchState`, `LaunchLogger` `O_APPEND` writes

**Files:**
- Create: `Packages/DuplicatorCore/Sources/DuplicatorCore/ProcessWatcher.swift`, `.../HelperWatchState.swift`
- Modify: `Packages/DuplicatorCore/Sources/DuplicatorCore/ProcessStartTime.swift` (append an extension after the struct from Task 2), `Packages/DuplicatorCore/Sources/DuplicatorCore/LaunchLogger.swift` (line 1 imports, lines 3-4 doc comment, lines 46-61 `append(_:)`)
- Test: create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/ProcessStartTimeTests.swift`, `.../ProcessWatcherTests.swift`, `.../HelperWatchStateTests.swift`; extend `.../LaunchLoggerTests.swift` (before the class's closing brace on line 68)

**Interfaces:**
- Consumes: `ProcessStartTime` (Task 2); Darwin `proc_pidinfo`, `proc_bsdinfo` (`pbi_start_tvsec`/`pbi_start_tvusec` are `uint64_t`, `sys/proc_info.h` lines 80-81), `PROC_PIDTBSDINFO` (3), `proc_pidpath`, `MAXPATHLEN` (the `4 * MAXPATHLEN` buffer `CLILaunchTests.processPath` uses), `proc_listpids` with `PROC_ALL_PIDS` (1, `sys/proc_info.h` line 51; `libproc.h` line 92; the two-call pattern of `CLILaunchTests.pids(runningFrom:)`), `kqueue`, `kevent`, `EVFILT_PROC` (-5), `EV_ADD` (0x0001), `EV_CLEAR` (0x0020), `EV_ERROR` (0x4000), `NOTE_EXIT` (0x80000000), `NOTE_EXEC` (0x20000000), `NOTE_EXITSTATUS` (0x04000000, "valid for child process or when allowed to signal target pid"; `sys/event.h` lines 72, 137, 144, 168, 261, 263, 266); libproc is part of the Darwin module, so `import Darwin` is enough (`CLILaunchTests` calls `proc_pidpath` with `import Foundation` only). `LaunchLogger` (`fileURL`, `rotatedFileURL`, `maxBytes`, private `append(_:)`), test support `makeTemporaryDirectory()`.
- Produces:
  ```swift
  extension ProcessStartTime {
      public static func of(_ pid: pid_t) -> ProcessStartTime?          // nil when no such process
      public enum Comparison: Equatable, Sendable { case same, different, gone }
      public func compare(toLiveProcess pid: pid_t) -> Comparison
  }
  public enum ProcessWatchEvent: Equatable, Sendable {
      case exec
      case exit(waitStatus: Int32?)
  }
  public enum ProcessWatcherError: Error, Equatable {
      case processGone
      case kqueueFailed(errno: Int32)
      case registrationFailed(errno: Int32)
      case waitFailed(errno: Int32)
  }
  public final class ProcessWatcher {                                    // not Sendable: one owner calls wait
      public let pid: pid_t
      public let fileDescriptor: Int32                                   // the kqueue; readable while an event is pending
      public let reportsExitStatus: Bool
      public init(pid: pid_t) throws                                     // ESRCH and pid <= 0 throw .processGone
      public func wait(timeout: TimeInterval?) throws -> [ProcessWatchEvent]   // nil blocks, 0 polls, [] on timeout
      public static func executablePath(of pid: pid_t) -> String?
      public static func pids(runningFrom path: String) -> [pid_t]       // live processes whose kernel path is `path`, sorted
  }
  public struct HelperWatchState: Equatable, Sendable {
      public enum Decision: Equatable, Sendable {
          case keepWatching, targetExited(waitStatus: Int32?), launcherFailed(waitStatus: Int32?), pidReused, watchedProcessGone
      }
      public private(set) var execObserved: Bool
      public init(requiresExec: Bool, parentExecutablePath: String?, ownExecutablePath: String?)
      public static func startupDecision(for comparison: ProcessStartTime.Comparison) -> Decision
      public mutating func apply(_ event: ProcessWatchEvent, startTime: ProcessStartTime.Comparison) -> Decision
  }
  // LaunchLogger: public API unchanged; append(_:) writes with one write(2) on an O_APPEND descriptor.
  ```
- How Tasks 5 and 6 drive these (the order matters): create the `ProcessWatcher` first (`processGone` means the parent is already gone: log `HelperLogLine.watchedProcessGone`, never erase); then `HelperWatchState.startupDecision(for: startTime.compare(toLiveProcess: pid))`; then build the state with `parentExecutablePath: ProcessWatcher.executablePath(of: pid)` and `ownExecutablePath: ProcessWatcher.executablePath(of: getpid())`, both read after the registration, so an exec before the registration shows up as a path change and an exec after it arrives as `.exec`; then feed every event to `apply(_:startTime:)` with a fresh `compare(toLiveProcess:)`. Only `.targetExited` may erase.

Why `LaunchLogger` changes here: from Task 5 on, the helper and the target-to-be write the same `<Name>.log` at the same moment. The current `append(_:)` opens a `FileHandle` without `O_APPEND`, seeks to the end and writes, so two writers that seek together overwrite each other, and `FileManager.createFile` can replace a file another writer just created. One `write(2)` on an `O_APPEND` descriptor puts each line at the end atomically, and rotation becomes one `rename(2)`, which replaces `<Name>.log.1` in a single step. This also deletes the eight `try?` in `append(_:)`.

- [ ] **Step 1: Write the failing `LaunchLogger` test.** Insert this test in `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/LaunchLoggerTests.swift` directly before the class's closing brace (line 68):

```swift

    func testConcurrentWritersNeverLoseLines() throws {
        let logger = LaunchLogger(name: "Concurrent", directory: try makeTemporaryDirectory(), maxBytes: LaunchLogger.rotationThreshold)
        DispatchQueue.concurrentPerform(iterations: 400) { index in
            logger.log("line \(index)")
        }
        let indices = try lines(of: logger.fileURL).compactMap { line in
            line.split(separator: " ").last.flatMap { Int($0) }
        }
        XCTAssertEqual(indices.sorted(), Array(0..<400))
    }
```

- [ ] **Step 2: Run it against the old `append(_:)` and watch it fail.**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.LaunchLoggerTests 2>&1 | grep -E "error: -\[|Executed [0-9]+ tests" | tail -2`
Expected:
```
…/LaunchLoggerTests.swift:…: error: -[DuplicatorCoreTests.LaunchLoggerTests testConcurrentWritersNeverLoseLines] : XCTAssertEqual failed: …
Executed 7 tests, with 1 failure (0 unexpected) in …
```
The race is timing-dependent. If the run reports `with 0 failures`, run it once more; if it passes twice, write that in the report and continue (the rewrite is still required: the helper and the target write from two processes).

- [ ] **Step 3: Write the failing tests for the reader, the watcher and the reducer.**

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/ProcessStartTimeTests.swift`:

```swift
import Darwin
import XCTest
@testable import DuplicatorCore

final class ProcessStartTimeTests: XCTestCase {
    func testTheCurrentProcessHasAStableStartTimeInThePast() throws {
        let first = try XCTUnwrap(ProcessStartTime.of(getpid()))
        let second = try XCTUnwrap(ProcessStartTime.of(getpid()))
        XCTAssertEqual(first, second)
        XCTAssertGreaterThan(first.seconds, 1_600_000_000)
        XCTAssertLessThanOrEqual(first.seconds, UInt64(Date().timeIntervalSince1970))
        XCTAssertLessThan(first.microseconds, 1_000_000)
    }

    func testAMissingProcessHasNoStartTime() {
        XCTAssertNil(ProcessStartTime.of(Int32.max))
        XCTAssertEqual(ProcessStartTime(seconds: 1, microseconds: 2).compare(toLiveProcess: Int32.max), .gone)
    }

    func testCompareTellsTheSameProcessFromAReusedPid() throws {
        let own = try XCTUnwrap(ProcessStartTime.of(getpid()))
        XCTAssertEqual(own.compare(toLiveProcess: getpid()), .same)
        let otherMicroseconds = ProcessStartTime(seconds: own.seconds, microseconds: (own.microseconds + 1) % 1_000_000)
        XCTAssertEqual(otherMicroseconds.compare(toLiveProcess: getpid()), .different)
        let otherSeconds = ProcessStartTime(seconds: own.seconds + 1, microseconds: own.microseconds)
        XCTAssertEqual(otherSeconds.compare(toLiveProcess: getpid()), .different)
    }
}
```

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/ProcessWatcherTests.swift`:

```swift
import Darwin
import XCTest
@testable import DuplicatorCore

/// Every test watches a short-lived child it starts and reaps itself. `/bin/sh` is a trampoline that execs the selected
/// shell (one extra exec event), so the scripts run under `/bin/bash` directly.
final class ProcessWatcherTests: XCTestCase {
    private func start(_ executable: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        return process
    }

    private func stop(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
    }

    /// Every event until the first `.exit`, waiting at most 10 s in all.
    private func eventsUntilExit(_ watcher: ProcessWatcher) throws -> [ProcessWatchEvent] {
        var events: [ProcessWatchEvent] = []
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            events += try watcher.wait(timeout: 1)
            if case .exit? = events.last {
                break
            }
        }
        return events
    }

    func testReportsTheExitStatusOfAChild() throws {
        let process = try start("/bin/bash", ["-c", "sleep 0.3; exit 3"])
        defer { stop(process) }
        let watcher = try ProcessWatcher(pid: process.processIdentifier)
        XCTAssertEqual(watcher.pid, process.processIdentifier)
        XCTAssertTrue(watcher.reportsExitStatus)
        XCTAssertEqual(try eventsUntilExit(watcher), [.exit(waitStatus: 3 << 8)])
    }

    func testReportsAnExecBeforeTheExit() throws {
        let process = try start("/bin/bash", ["-c", "/bin/sleep 0.3; exec /bin/sleep 0.3"])
        defer { stop(process) }
        let watcher = try ProcessWatcher(pid: process.processIdentifier)
        XCTAssertEqual(try eventsUntilExit(watcher), [.exec, .exit(waitStatus: 0)])
    }

    func testAMissingProcessIsReportedAsGone() {
        XCTAssertThrowsError(try ProcessWatcher(pid: Int32.max)) { error in
            XCTAssertEqual(error as? ProcessWatcherError, .processGone)
        }
        XCTAssertThrowsError(try ProcessWatcher(pid: 0)) { error in
            XCTAssertEqual(error as? ProcessWatcherError, .processGone)
        }
    }

    func testATimeoutReturnsNoEventsAndASignalExitIsReported() throws {
        let process = try start("/bin/sleep", ["30"])
        defer { stop(process) }
        let watcher = try ProcessWatcher(pid: process.processIdentifier)
        XCTAssertEqual(try watcher.wait(timeout: 0.2), [])
        XCTAssertEqual(try watcher.wait(timeout: 0), [])
        process.terminate()
        XCTAssertEqual(try eventsUntilExit(watcher), [.exit(waitStatus: SIGTERM)])
    }

    func testExecutablePathsAndProcessListsComeFromTheKernel() throws {
        let process = try start("/bin/sleep", ["5"])
        defer { stop(process) }
        XCTAssertEqual(ProcessWatcher.executablePath(of: process.processIdentifier), "/bin/sleep")
        XCTAssertNil(ProcessWatcher.executablePath(of: Int32.max))
        XCTAssertTrue(ProcessWatcher.pids(runningFrom: "/bin/sleep").contains(process.processIdentifier))
        XCTAssertEqual(ProcessWatcher.pids(runningFrom: "/nonexistent/\(UUID().uuidString)"), [])
    }
}
```

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/HelperWatchStateTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore

final class HelperWatchStateTests: XCTestCase {
    private let launcher = "/Users/test/Applications/App Duplicator/Notes Work.app/Contents/MacOS/Notes Work"
    private let target = "/System/Applications/Notes.app/Contents/MacOS/Notes"

    func testAnExecThenAnExitIsATargetExit() {
        var state = HelperWatchState(requiresExec: true, parentExecutablePath: launcher, ownExecutablePath: launcher)
        XCTAssertFalse(state.execObserved)
        XCTAssertEqual(state.apply(.exec, startTime: .same), .keepWatching)
        XCTAssertTrue(state.execObserved)
        XCTAssertEqual(state.apply(.exit(waitStatus: 0), startTime: .gone), .targetExited(waitStatus: 0))
    }

    func testAnExitWithoutAnExecIsALauncherFailure() {
        var state = HelperWatchState(requiresExec: true, parentExecutablePath: launcher, ownExecutablePath: launcher)
        XCTAssertEqual(state.apply(.exit(waitStatus: 3 << 8), startTime: .gone), .launcherFailed(waitStatus: 3 << 8))
        var withoutStatus = HelperWatchState(requiresExec: true, parentExecutablePath: launcher, ownExecutablePath: launcher)
        XCTAssertEqual(withoutStatus.apply(.exit(waitStatus: nil), startTime: .different), .launcherFailed(waitStatus: nil))
    }

    func testAnExecBeforeTheWatchStartedIsReadFromTheExecutablePaths() {
        XCTAssertTrue(HelperWatchState(requiresExec: true, parentExecutablePath: target, ownExecutablePath: launcher).execObserved)
        XCTAssertFalse(HelperWatchState(requiresExec: true, parentExecutablePath: nil, ownExecutablePath: launcher).execObserved)
        XCTAssertFalse(HelperWatchState(requiresExec: true, parentExecutablePath: target, ownExecutablePath: nil).execObserved)
        var state = HelperWatchState(requiresExec: true, parentExecutablePath: target, ownExecutablePath: launcher)
        XCTAssertEqual(state.apply(.exit(waitStatus: 0), startTime: .gone), .targetExited(waitStatus: 0))
    }

    func testSystemLaunchWatchesTheTargetWithoutAnExec() {
        var state = HelperWatchState(requiresExec: false, parentExecutablePath: nil, ownExecutablePath: nil)
        XCTAssertTrue(state.execObserved)
        XCTAssertEqual(state.apply(.exit(waitStatus: SIGKILL), startTime: .gone), .targetExited(waitStatus: SIGKILL))
    }

    func testTheStartupDecisionFollowsTheStartTime() {
        XCTAssertEqual(HelperWatchState.startupDecision(for: .same), .keepWatching)
        XCTAssertEqual(HelperWatchState.startupDecision(for: .different), .pidReused)
        XCTAssertEqual(HelperWatchState.startupDecision(for: .gone), .watchedProcessGone)
    }

    func testAnExecFromAReusedPidIsRefusedButAnExecThatRacesTheExitCounts() {
        var reused = HelperWatchState(requiresExec: true, parentExecutablePath: launcher, ownExecutablePath: launcher)
        XCTAssertEqual(reused.apply(.exec, startTime: .different), .pidReused)
        XCTAssertFalse(reused.execObserved)
        var raced = HelperWatchState(requiresExec: true, parentExecutablePath: launcher, ownExecutablePath: launcher)
        XCTAssertEqual(raced.apply(.exec, startTime: .gone), .keepWatching)
        XCTAssertEqual(raced.apply(.exit(waitStatus: nil), startTime: .gone), .targetExited(waitStatus: nil))
    }
}
```

- [ ] **Step 4: Run them and watch them fail to compile.**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.ProcessWatcherTests 2>&1 | grep -E "error:" | head -6`
Expected: compile errors, among them `type 'ProcessStartTime' has no member 'of'`, `cannot find 'ProcessWatcher' in scope` and `cannot find 'HelperWatchState' in scope` (the order may differ).

- [ ] **Step 5: Append the start-time reader to `Packages/DuplicatorCore/Sources/DuplicatorCore/ProcessStartTime.swift`** (after the struct's closing brace; `import Foundation` already brings in Darwin and libproc).

```swift

extension ProcessStartTime {
    /// `pid`'s start time from `proc_pidinfo(PROC_PIDTBSDINFO)`, or nil when no process has that pid.
    public static func of(_ pid: pid_t) -> ProcessStartTime? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return ProcessStartTime(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    /// How a recorded start time relates to the process that has the pid now.
    public enum Comparison: Equatable, Sendable {
        /// The same process (`execve` keeps the start time).
        case same
        /// Another process reused the pid.
        case different
        /// No process has the pid.
        case gone
    }

    public func compare(toLiveProcess pid: pid_t) -> Comparison {
        guard let live = ProcessStartTime.of(pid) else {
            return .gone
        }
        return live == self ? .same : .different
    }
}
```

- [ ] **Step 6: Create `Packages/DuplicatorCore/Sources/DuplicatorCore/ProcessWatcher.swift`.**

```swift
import Darwin
import Foundation

/// What `ProcessWatcher` saw happen to the watched process.
public enum ProcessWatchEvent: Equatable, Sendable {
    /// The process called `execve`: the launcher became the target.
    case exec
    /// The process exited. `waitStatus` is the `waitpid`-style status when the kernel reported one (`NOTE_EXITSTATUS`).
    case exit(waitStatus: Int32?)
}

public enum ProcessWatcherError: Error, Equatable {
    /// No process has the pid (`ESRCH`), or the pid is 0 or below.
    case processGone
    case kqueueFailed(errno: Int32)
    case registrationFailed(errno: Int32)
    case waitFailed(errno: Int32)
}

/// A kqueue `EVFILT_PROC` watch on one process for `NOTE_EXEC` and `NOTE_EXIT` (spec §4.6). The watcher owns its kqueue;
/// `fileDescriptor` is readable while an event is pending, so a `DispatchSource` read source can call `wait(timeout: 0)`.
/// Not `Sendable`: exactly one owner calls `wait`.
public final class ProcessWatcher {
    public let pid: pid_t
    public let fileDescriptor: Int32
    /// True when the kernel accepted `NOTE_EXITSTATUS` (allowed for a child or a process this user may signal), so
    /// `.exit` carries the status.
    public let reportsExitStatus: Bool

    public init(pid: pid_t) throws {
        guard pid > 0 else {
            throw ProcessWatcherError.processGone
        }
        let queue = kqueue()
        guard queue >= 0 else {
            throw ProcessWatcherError.kqueueFailed(errno: errno)
        }
        let flags = UInt32(truncatingIfNeeded: NOTE_EXIT) | UInt32(truncatingIfNeeded: NOTE_EXEC)
        var reportsExitStatus = true
        var result = ProcessWatcher.register(pid: pid, fflags: flags | UInt32(truncatingIfNeeded: NOTE_EXITSTATUS), on: queue)
        if result == EACCES {
            reportsExitStatus = false
            result = ProcessWatcher.register(pid: pid, fflags: flags, on: queue)
        }
        guard result == 0 else {
            close(queue)
            throw result == ESRCH ? ProcessWatcherError.processGone : ProcessWatcherError.registrationFailed(errno: result)
        }
        self.pid = pid
        fileDescriptor = queue
        self.reportsExitStatus = reportsExitStatus
    }

    deinit {
        close(fileDescriptor)
    }

    /// Waits up to `timeout` seconds (`nil` blocks, `0` polls; finite values only) and returns what happened, `.exec`
    /// before `.exit` when one wake-up carries both. An empty array means the timeout passed.
    public func wait(timeout: TimeInterval?) throws -> [ProcessWatchEvent] {
        var events = [kevent](repeating: kevent(), count: 4)
        let capacity = Int32(events.count)
        var count: Int32
        repeat {
            if let timeout {
                let seconds = max(0, timeout)
                let whole = seconds.rounded(.down)
                var limit = timespec(tv_sec: Int(whole), tv_nsec: Int((seconds - whole) * 1_000_000_000))
                count = kevent(fileDescriptor, nil, 0, &events, capacity, &limit)
            } else {
                count = kevent(fileDescriptor, nil, 0, &events, capacity, nil)
            }
        } while count < 0 && errno == EINTR
        guard count >= 0 else {
            throw ProcessWatcherError.waitFailed(errno: errno)
        }
        var result: [ProcessWatchEvent] = []
        for event in events.prefix(Int(count)) {
            if event.flags & UInt16(truncatingIfNeeded: EV_ERROR) != 0 {
                throw ProcessWatcherError.waitFailed(errno: Int32(truncatingIfNeeded: event.data))
            }
            if event.fflags & UInt32(truncatingIfNeeded: NOTE_EXEC) != 0 {
                result.append(.exec)
            }
            if event.fflags & UInt32(truncatingIfNeeded: NOTE_EXIT) != 0 {
                result.append(.exit(waitStatus: reportsExitStatus ? Int32(truncatingIfNeeded: event.data) : nil))
            }
        }
        return result
    }

    /// The kernel's path of `pid`'s executable (`proc_pidpath`), or nil when no process has that pid.
    public static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Every live process whose kernel executable path is exactly `path`, in ascending pid order. Zombies have no path and
    /// never match. The helper uses it to find other copies of its own shortcut before it erases (Task 5).
    public static func pids(runningFrom path: String) -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else {
            return []
        }
        var all = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size + 64)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &all, Int32(all.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else {
            return []
        }
        return all.prefix(Int(filled) / MemoryLayout<pid_t>.size)
            .filter { $0 > 0 && executablePath(of: $0) == path }
            .sorted()
    }

    /// Adds the `EVFILT_PROC` filter for `pid` to `queue`: 0 on success, otherwise the errno.
    private static func register(pid: pid_t, fflags: UInt32, on queue: Int32) -> Int32 {
        var change = kevent(
            ident: UInt(pid),
            filter: Int16(truncatingIfNeeded: EVFILT_PROC),
            flags: UInt16(truncatingIfNeeded: EV_ADD | EV_CLEAR),
            fflags: fflags,
            data: 0,
            udata: nil
        )
        while kevent(queue, &change, 1, nil, 0, nil) < 0 {
            guard errno == EINTR else {
                return errno
            }
        }
        return 0
    }
}
```

(`NOTE_EXIT` does not fit in a C `int`, so Swift imports it with a different integer type than `NOTE_EXEC`; the `truncatingIfNeeded` conversions accept whichever type each macro has. With `NOTE_EXITSTATUS` the exit event's `data` is the `waitpid` status: `exit(3)` gives `768`, `SIGTERM` gives `15`.)

- [ ] **Step 7: Create `Packages/DuplicatorCore/Sources/DuplicatorCore/HelperWatchState.swift`.**

```swift
import Foundation

/// The helper's decisions (spec §4.6) without system calls, so every path is unit-tested. Erase-on-quit may run only
/// after `.targetExited`: the watched launcher exec'd into the target (or the pid was the target from the start, in System
/// Launch mode) and that process then exited.
public struct HelperWatchState: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Nothing to do yet.
        case keepWatching
        /// The target quit; erase-on-quit may run.
        case targetExited(waitStatus: Int32?)
        /// The launcher exited without exec'ing, so the target never ran; never erase.
        case launcherFailed(waitStatus: Int32?)
        /// Another process has the pid now; never erase or signal.
        case pidReused
        /// The process was gone before the watch started; never erase.
        case watchedProcessGone
    }

    /// True once the watched process is known to be the target.
    public private(set) var execObserved: Bool

    /// `requiresExec` is false when the watched pid already is the target (System Launch). Otherwise an exec that happened
    /// before the kqueue registration shows as a parent executable path that differs from the helper's own: the helper
    /// runs the launcher binary its parent started from. Read both paths with `ProcessWatcher.executablePath(of:)` after
    /// the registration.
    public init(requiresExec: Bool, parentExecutablePath: String?, ownExecutablePath: String?) {
        if !requiresExec {
            execObserved = true
        } else if let parentExecutablePath, let ownExecutablePath {
            execObserved = parentExecutablePath != ownExecutablePath
        } else {
            execObserved = false
        }
    }

    /// The decision right after the registration, from the start time the launcher passed.
    public static func startupDecision(for comparison: ProcessStartTime.Comparison) -> Decision {
        switch comparison {
        case .same: .keepWatching
        case .different: .pidReused
        case .gone: .watchedProcessGone
        }
    }

    /// Folds one event in. `startTime` is a comparison read right after the event. It decides only for `.exec`: `.different`
    /// means the pid was reused, while `.gone` means the target exec'd and already exited, so the exec still counts. Exit
    /// events ignore it because the pid is free by then.
    public mutating func apply(_ event: ProcessWatchEvent, startTime: ProcessStartTime.Comparison) -> Decision {
        switch event {
        case .exec:
            if startTime == .different {
                return .pidReused
            }
            execObserved = true
            return .keepWatching
        case .exit(let waitStatus):
            return execObserved ? .targetExited(waitStatus: waitStatus) : .launcherFailed(waitStatus: waitStatus)
        }
    }
}
```

- [ ] **Step 8: Replace `Packages/DuplicatorCore/Sources/DuplicatorCore/LaunchLogger.swift` with the `O_APPEND` version.** Everything above `append(_:)` keeps its code; the imports, the type's doc comment and `append(_:)` change. The whole file:

```swift
import Darwin
import Foundation

/// Appends launcher and helper events to `~/Library/Logs/App Duplicator/<Name>.log`, rotating at 1 MB (spec §4.7).
/// Logging never fails the launch: every file-system error is ignored. Each line is one `write(2)` on an `O_APPEND`
/// descriptor, so the launcher, its helper and concurrent threads never overwrite each other's lines.
public struct LaunchLogger: Sendable {
    /// Rotation threshold: 1 MB.
    public static let rotationThreshold = 1_048_576

    public let fileURL: URL
    let maxBytes: Int

    public init(name: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/App Duplicator", directoryHint: .isDirectory)
        self.init(name: name, directory: directory, maxBytes: LaunchLogger.rotationThreshold)
    }

    init(name: String, directory: URL, maxBytes: Int) {
        fileURL = directory.appending(path: ShortcutConfig.fileSystemName(for: name) + ".log", directoryHint: .notDirectory)
        self.maxBytes = maxBytes
    }

    /// The rotated file: `<Name>.log.1`.
    public var rotatedFileURL: URL {
        fileURL.deletingLastPathComponent().appending(path: fileURL.lastPathComponent + ".1", directoryHint: .notDirectory)
    }

    /// Appends `<ISO 8601 timestamp> <line>`.
    public func log(_ line: String) {
        append(Data("\(Date.now.ISO8601Format()) \(line)\n".utf8))
    }

    /// Logs one `env KEY=VALUE` line per variable, sorted by key, values masked per spec §2.
    public func log(environment: [String: String]) {
        let masked = SecretMasking.mask(environment)
        for key in masked.keys.sorted() {
            log("env \(key)=\(masked[key] ?? "")")
        }
    }

    /// Logs `argv <arguments>` on one line, secret values masked per `SecretMasking.maskArguments`.
    public func log(arguments: [String]) {
        log("argv \(SecretMasking.maskArguments(arguments).joined(separator: " "))")
    }

    private func append(_ data: Data) {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return // Logging never fails the launch.
            }
        }
        var info = stat()
        if stat(fileURL.path, &info) == 0, info.st_size > 0, Int(info.st_size) + data.count > maxBytes {
            // One step that replaces any previous `.log.1`; if it fails the file keeps growing.
            _ = rename(fileURL.path, rotatedFileURL.path)
        }
        let descriptor = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            return
        }
        defer { close(descriptor) }
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}
```

- [ ] **Step 9: Run the suites and watch them pass.**

Run: `cd ~/Developer/MacAppDuplicator && for suite in ProcessStartTimeTests ProcessWatcherTests HelperWatchStateTests LaunchLoggerTests; do swift test --filter DuplicatorCoreTests.$suite 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1; done`
Expected, in order:
```
Executed 3 tests, with 0 failures (0 unexpected) in …
Executed 5 tests, with 0 failures (0 unexpected) in …
Executed 6 tests, with 0 failures (0 unexpected) in …
Executed 7 tests, with 0 failures (0 unexpected) in …
```

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: `Executed 282 tests, with 0 failures (0 unexpected) in …`

Run: `cd ~/Developer/MacAppDuplicator && swift build 2>&1 | tail -1`
Expected: `Build complete!` (the Launcher, WebShell and madctl use `LaunchLogger`; its public API is unchanged).

If `testReportsTheExitStatusOfAChild` reports `reportsExitStatus` false or a status other than `768`, stop and report the actual `data` value; do not loosen the test. The helper's erase decision does not depend on the status, only the log line does.

- [ ] **Step 10: Forbidden constructs.**

Run: `cd ~/Developer/MacAppDuplicator && grep -nE 'try\?|@unchecked|swiftlint:disable|nonisolated\(unsafe\)' Packages/DuplicatorCore/Sources/DuplicatorCore/{ProcessStartTime,ProcessWatcher,HelperWatchState,LaunchLogger}.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/{ProcessStartTimeTests,ProcessWatcherTests,HelperWatchStateTests,LaunchLoggerTests}.swift`
Expected: no output (the eight `try?` of the old `append(_:)` are gone).

- [ ] **Step 11: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add Packages/DuplicatorCore/Sources/DuplicatorCore/ProcessStartTime.swift Packages/DuplicatorCore/Sources/DuplicatorCore/ProcessWatcher.swift Packages/DuplicatorCore/Sources/DuplicatorCore/HelperWatchState.swift Packages/DuplicatorCore/Sources/DuplicatorCore/LaunchLogger.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/ProcessStartTimeTests.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/ProcessWatcherTests.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/HelperWatchStateTests.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/LaunchLoggerTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Core: process watcher, start-time reader, helper watch state, O_APPEND log" -m "ProcessStartTime reads pbi_start_tvsec and pbi_start_tvusec with proc_pidinfo and compares a recorded start time with the live pid. ProcessWatcher wraps a kqueue EVFILT_PROC watch for NOTE_EXEC and NOTE_EXIT, asks for NOTE_EXITSTATUS and falls back without it on EACCES, reads executable paths with proc_pidpath and lists the processes running from one path. HelperWatchState decides between keep watching, target exit, launcher failure, pid reuse and a process already gone. LaunchLogger appends each line with one write(2) on an O_APPEND descriptor and rotates with rename(2), so the launcher, its helper and concurrent threads never overwrite each other's lines." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Deviations

- `ProcessWatcher` also asks for `NOTE_EXITSTATUS` (the Global Constraints name `NOTE_EXIT | NOTE_EXEC` only) and retries without it on `EACCES`, so the `helper target exited status=` line carries a number whenever the kernel allows it; without it the line says `status=unavailable`.
- `HelperWatchState` adds `watchedProcessGone` (the start time reads `.gone` right after the registration) and detects an exec that raced the registration from the two `proc_pidpath` values; an `.exec` whose start-time re-read is `.gone` still counts, and exit events ignore the start time because the pid is free by then.
- `LaunchLogger` is in scope here although the brief lists only the helper types: two processes now write one log, and the old seek-then-write `append(_:)` loses lines (Step 2 shows it in-process). Rotation is one `rename(2)` instead of remove plus move; the existing rotation test pins the same behaviour.
- The watcher tests start `/bin/bash` children as well as `/bin/sleep` (the Global Constraints mention `/bin/sleep` only): an exit code and an exec need a two-command script, and `/bin/sh` is a trampoline that adds an exec of its own.
- `ProcessWatcher.pids(runningFrom:)` is not in the brief. Task 5's helper calls it before erasing: a second launch of the same shortcut (for example a Chromium target that hands its arguments to the running copy and exits 0) produces an exec followed by a clean exit, and without this check its helper would empty the folder the first copy is still using. The assertions sit in the existing executable-path test, so the counts above are unchanged.

---

### Task 5: Launcher: helper spawn, `--helper` role, erase on quit, gated integration test

**Files:**
- Create: `Launcher/Sources/Launcher/HelperLaunch.swift` (the parent side), `Launcher/Sources/Launcher/HelperRole.swift` (the `--helper` entry point), `Launcher/Sources/Launcher/HelperRunner.swift` (the watch, the erase and the blocking runner; Task 6 adds the menu bar runner to this file)
- Modify: `Launcher/Sources/Launcher/Spawn.swift` (lines 4-56: the doc comment and `spawnDetached`), `Launcher/Sources/Launcher/main.swift` (insert after line 2; replace lines 88-105)
- Test: create `Tests/Integration/HelperEraseTests.swift`

**Interfaces:**
- Consumes: `HelperPlan.isNeeded(for:)`, `HelperPlan.eraseDataPath(for:)`, `HelperArguments` (`init(parentPID:startTime:bundlePath:dataPath:)`, `arguments`, `isHelperInvocation(_:)`, `parse(_:)`), `HelperEnvironment.helperEnvironment(shortcut:base:)`, `HelperLogLine` (all from Task 2); `EraseOnQuitPolicy.check(dataPath:home:)`, `EraseOnQuitRefusal.logReason`, `EraseOnQuitPerformer.erase(at:fileManager:)` (Task 3); `ProcessStartTime.of(_:)`, `compare(toLiveProcess:)`, `ProcessWatcher` (`init(pid:)`, `wait(timeout:)`, `executablePath(of:)`, `pids(runningFrom:)`), `ProcessWatcherError.processGone`, `HelperWatchState` (Task 4); `LaunchLogger(name:)`; `ShortcutConfig.infoPlistKey` (`ShortcutConfig.swift` line 8), `ShortcutConfig(plistDictionary:)` (line 138); `LauncherError.configMissing`, `.configCorrupt(_:)`, `.spawnFailed(errno:path:)` (`LauncherError.swift` lines 5, 6, 16; `localizedDescription` gives the `errorDescription` text); `LaunchPlan.environment`; `spawnDetached` (`Spawn.swift` lines 10-56); Darwin `POSIX_SPAWN_CLOEXEC_DEFAULT` (0x4000, `sys/spawn.h` line 62; `POSIX_SPAWN_SETSID` is 0x0400 on line 61, so both fit the `Int16` flags) and `posix_spawn_file_actions_addopen(_:_:_:_:_:)` (`spawn.h` line 83). Test side: `BundleWriter().write(config:executable:iconFile:to:)`, `Signer().sign(bundle:identity:)`, `ShortcutConfig.slug(for:)`, `bundleIdentifier(forSlug:)`, `defaultDataPath(forSlug:home:)` (returns `String`, line 183), `fileSystemName(for:)`; the fixture's `MAD_FIXTURE_DUMP` and `MAD_FIXTURE_LIFETIME` (`Tests/Fixtures/FixtureApp/main.swift` lines 21 and 36) and its bundle id `com.mikekuta.appduplicator.fixture` (`Tools/build-fixture.sh` line 23).
- Produces (Launcher module, internal):
  ```swift
  func spawnDetached(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL?,
                     isolatedStandardStreams: Bool = false) -> Result<pid_t, LauncherError>
  enum HelperLaunch {
      static func spawnIfNeeded(config: ShortcutConfig, plan: LaunchPlan, bundlePath: String, executableURL: URL?,
                                baseEnvironment: [String: String], log: LaunchLogger)
  }
  @MainActor func runHelperRole(arguments argv: [String]) -> Never
  struct HelperSession: Sendable {
      var watchedPID: pid_t, startTime: ProcessStartTime, requiresExec: Bool, erasePath: String?, home: URL, log: LaunchLogger
  }
  enum HelperWatchEnd: Equatable, Sendable {
      case targetExited(waitStatus: Int32?), launcherFailed(waitStatus: Int32?), pidReused, watchedProcessGone, watchFailed(String)
      var logLine: String { get }
  }
  final class HelperWatch {                       // not Sendable: one owner drives it
      let session: HelperSession
      private(set) var watcher: ProcessWatcher?
      init(session: HelperSession)
      func start() -> HelperWatchEnd?             // nil: wait for events
      func handle(_ events: [ProcessWatchEvent]) -> HelperWatchEnd?
      func run() -> HelperWatchEnd                // blocking loop
      static func end(for decision: HelperWatchState.Decision) -> HelperWatchEnd?
  }
  enum HelperRunner {
      static func runBlocking(_ session: HelperSession) -> Never
      static func finish(_ end: HelperWatchEnd, session: HelperSession) -> Never
      static func eraseIfArmed(_ session: HelperSession)
  }
  ```

How the pieces fit: the Launcher reaches `HelperLaunch.spawnIfNeeded` only in Dock Shortcut mode (the System Launch branch above it never returns) and only after `LaunchPreparer` succeeded, so a helper never exists for a launch that failed before exec. The helper's argv carries the launcher's pid and start time; the helper keeps the launcher's own `HOME`/`CFFIXED_USER_HOME` (`HelperEnvironment`), so `LaunchLogger` writes the same `<Name>.log` and `EraseOnQuitPolicy` sees the real home. The erase-only helper never creates `NSApplication`, so it never checks in with LaunchServices: it is a plain background process that blocks in `kevent`. It is a child of the launcher's pid, so it stays a child of the target after `execve`; when the target exits it is re-parented to launchd.

- [ ] **Step 1: Write the failing integration test.**

Create `Tests/Integration/HelperEraseTests.swift`:

```swift
// Gated integration test: erase-on-quit (spec §4.3, §4.6) through a real shortcut bundle.
//
// Prerequisites (run from the repo root):
//   swift build -c release --product Launcher
//   Tools/build-fixture.sh
//   MAD_INTEGRATION=1 swift test --filter IntegrationTests.HelperEraseTests
//
// Without MAD_INTEGRATION=1 the test is skipped. Like CLILaunchTests it runs the shortcut's executable directly
// (`Bundle.main` still resolves to the shortcut bundle) with HOME and CFFIXED_USER_HOME pointing at a temp home, so the
// Launcher's log, the helper and the fixture's HOME tree stay out of ~/Library. The Launcher starts the helper and execs
// the fixture, which quits after one second; the helper must then empty the data folder, keep the folder itself and
// leave the temp home's Desktop (linked into the HOME tree) untouched. The fixture window shows for about a second.

import DuplicatorCore
import Foundation
import XCTest

@MainActor
final class HelperEraseTests: XCTestCase {
    struct Dump: Decodable {
        let homeDirectory: String
    }

    /// Repo root: three directories above `Tests/Integration/<this file>`.
    private let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var launcher: URL { root.appendingPathComponent(".build/release/Launcher") }
    private var fixture: URL { root.appendingPathComponent(".build/fixtures/FixtureApp.app") }
    private var fixtureBinary: URL { fixture.appendingPathComponent("Contents/MacOS/FixtureApp") }

    private let shortcutName = "MAD Helper Erase"
    private let fixtureBundleIdentifier = "com.mikekuta.appduplicator.fixture"

    // MARK: - Helpers (same shape as CLILaunchTests, whose helpers are private)

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mad-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Could not remove \(directory.path): \(error)")
            }
        }
        return directory
    }

    private func resolved(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    private func resolved(_ path: String) -> String {
        resolved(URL(fileURLWithPath: path))
    }

    private func processPath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
    }

    /// PIDs of every running process whose executable resolves to `executable`.
    private func pids(runningFrom executable: URL) -> Set<pid_t> {
        let target = resolved(executable)
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        var all = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size + 64)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &all, Int32(all.count * MemoryLayout<pid_t>.size))
        let count = Int(filled) / MemoryLayout<pid_t>.size
        return Set(all.prefix(count).filter { $0 > 0 && resolved(processPath($0)) == target })
    }

    /// Kills anything still running from `executable` and waits until the process table is clear.
    private func reapLeftovers(runningFrom executable: URL) async throws {
        for pid in pids(runningFrom: executable) where kill(pid, SIGKILL) != 0 {
            XCTFail("kill(\(pid), SIGKILL) failed with errno \(errno)")
        }
        let deadline = Date().addingTimeInterval(5)
        while !pids(runningFrom: executable).isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Returns nil until the dump file exists. The fixture writes it atomically, so a present file is complete and a
    /// decode failure is a real error.
    private func loadDump(from url: URL) throws -> Dump? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Dump.self, from: Data(contentsOf: url))
    }

    /// Stops the Launcher-turned-fixture if it is somehow still running. `process` is this test's own child and is not
    /// reaped while it runs, so its pid cannot belong to anything else.
    private func stop(_ process: Process) async throws {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(process.isRunning, "The fixture did not stop after SIGTERM")
    }

    // MARK: - Tests

    func testEraseOnQuitEmptiesTheDataFolderAfterTheTargetQuits() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAD_INTEGRATION"] == "1", "Set MAD_INTEGRATION=1")
        guard FileManager.default.isExecutableFile(atPath: launcher.path),
              FileManager.default.isExecutableFile(atPath: fixtureBinary.path) else {
            XCTFail("Run: swift build -c release --product Launcher && Tools/build-fixture.sh")
            return
        }

        let tmp = try makeTempDirectory()
        let home = tmp.appendingPathComponent("home", isDirectory: true)
        let output = tmp.appendingPathComponent("out", isDirectory: true)
        let dumpURL = tmp.appendingPathComponent("dump.json")
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let keep = desktop.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: keep)

        let slug = ShortcutConfig.slug(for: shortcutName)
        let dataPath = ShortcutConfig.defaultDataPath(forSlug: slug, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataPath), "The data folder must not exist before the launch")
        let config = ShortcutConfig(
            kind: .app,
            name: shortcutName,
            slug: slug,
            bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: slug),
            targetPath: fixture.path,
            targetBundleIdentifier: fixtureBundleIdentifier,
            launchMode: .dockShortcut,
            dataMode: .homeOverride,
            dataPath: dataPath,
            environment: ["MAD_FIXTURE_DUMP": dumpURL.path, "MAD_FIXTURE_LIFETIME": "1"],
            eraseOnQuit: true,
            menuBarIcon: false
        )
        let bundle = try BundleWriter().write(config: config, executable: launcher, iconFile: nil, to: output)
        try Signer().sign(bundle: bundle, identity: nil)
        let executable = try XCTUnwrap(Bundle(url: bundle)?.executableURL, "Shortcut bundle has no executable")
        let logURL = home.appendingPathComponent(
            "Library/Logs/App Duplicator/\(ShortcutConfig.fileSystemName(for: shortcutName)).log"
        )

        // Teardown blocks run last-in-first-out: any helper or Launcher copy is reaped before the temp directory is
        // removed, including when the wait loop below throws. The fixture quits on its own after one second.
        addTeardownBlock { @MainActor [self] in
            try await reapLeftovers(runningFrom: executable)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        let process = Process()
        process.executableURL = executable
        process.environment = environment
        try process.run()

        // Collect everything first; assert only after every process is gone, so a failed assertion can never leave one
        // running. The Launcher execs into the fixture, so `process` runs until the fixture quits; the helper then
        // erases, logs `helper exit` and exits.
        var logText = ""
        let deadline = Date().addingTimeInterval(30)
        while (process.isRunning || !logText.contains(HelperLogLine.exiting) || !pids(runningFrom: executable).isEmpty)
            && Date() < deadline {
            if FileManager.default.fileExists(atPath: logURL.path) {
                logText = try String(contentsOf: logURL, encoding: .utf8)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let fixtureFinished = !process.isRunning
        let helperFinished = pids(runningFrom: executable).isEmpty
        try await stop(process)
        try await reapLeftovers(runningFrom: executable)

        if FileManager.default.fileExists(atPath: logURL.path) {
            logText = try String(contentsOf: logURL, encoding: .utf8)
        }
        let dump = try loadDump(from: dumpURL)
        // The helper logs the folder `EraseOnQuitPolicy` resolved, so the test resolves it the same way.
        let folder = try EraseOnQuitPolicy.check(dataPath: dataPath, home: home).get()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()

        XCTAssertTrue(fixtureFinished, "The fixture was still running after 30 s. Log: \(logText)")
        if fixtureFinished {
            XCTAssertEqual(process.terminationStatus, 0, "Log: \(logText)")
        }
        XCTAssertTrue(helperFinished, "A Launcher or helper process was still running after 30 s. Log: \(logText)")
        XCTAssertEqual(dump.map { resolved($0.homeDirectory) }, resolved(dataPath), "The fixture did not run with the data folder as HOME")
        let expectedLines = [
            "helper spawned pid=",
            "helper start pid=",
            HelperLogLine.execObserved,
            HelperLogLine.targetExited(waitStatus: 0),
            "helper erase \(folder.path) removed=",
            HelperLogLine.exiting,
        ]
        for expected in expectedLines {
            XCTAssertTrue(logText.contains(expected), "Missing \"\(expected)\" in the log: \(logText)")
        }
        XCTAssertFalse(logText.contains("failed="), "Log: \(logText)")
        XCTAssertFalse(logText.contains("helper erase skipped"), "Log: \(logText)")
        XCTAssertEqual(remaining, [], "The data folder still holds: \(remaining)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path), "The erase followed the Desktop link into the temp home")
    }
}
```

- [ ] **Step 2: Run it and watch it fail.** The Launcher still has the Phase 5 no-op `spawnHelperIfNeeded`, so no helper line is written and the folder keeps the HOME tree. The loop waits the full 30 s for `helper exit`.

Run: `cd ~/Developer/MacAppDuplicator && swift build -c release --product Launcher --product WebShell --product madctl 2>&1 | tail -1 && Tools/build-fixture.sh && MAD_INTEGRATION=1 swift test --filter IntegrationTests.HelperEraseTests 2>&1 | grep -E "Executed [0-9]+ tests?" | tail -1`
Expected: `Build complete!`, then `Executed 1 test, with 7 failures (0 unexpected) in …`. The seven are the six `Missing "helper …"` messages and `The data folder still holds: [".mad-home-tree", "Desktop", "Library"]`. Any other failure (a missing dump, a non-zero status, a `helperFinished` failure) means the setup is wrong: stop and report the failure text.

- [ ] **Step 3: Give `spawnDetached` isolated standard streams.** In `Launcher/Sources/Launcher/Spawn.swift`, replace lines 5-56 (the doc comment and the whole `spawnDetached` function; `spawnAndWait` from line 58 on stays as it is) with:

```swift
/// Starts a command shortcut's process and returns without waiting for it (spec §6). `POSIX_SPAWN_SETSID` puts the
/// child in its own session, so it outlives the Launcher (which exits right after) and is re-parented to launchd.
/// `environment` is the complete environment, passed as sorted `KEY=VALUE` strings like `execTarget`; a non-nil
/// `workingDirectory` becomes the child's current directory. `isolatedStandardStreams` (the helper, spec §4.6) adds
/// `POSIX_SPAWN_CLOEXEC_DEFAULT` and opens `/dev/null` on descriptors 0 to 2, so the child inherits no other descriptor
/// of this process and never holds a caller's pipe open for the target's lifetime. Every `strdup` copy is freed before
/// returning.
/// - Returns: the child's pid, or `LauncherError.spawnFailed` with the `posix_spawn*` error code.
func spawnDetached(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    workingDirectory: URL?,
    isolatedStandardStreams: Bool = false
) -> Result<pid_t, LauncherError> {
    let path = executable.path
    let argv = [path] + arguments
    let envp = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    var cEnvp: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) } + [nil]
    defer {
        cArgv.forEach { free($0) }
        cEnvp.forEach { free($0) }
    }

    var attributes: posix_spawnattr_t?
    var code = posix_spawnattr_init(&attributes)
    guard code == 0 else {
        return .failure(.spawnFailed(errno: code, path: path))
    }
    defer { posix_spawnattr_destroy(&attributes) }
    var flags = Int32(POSIX_SPAWN_SETSID)
    if isolatedStandardStreams {
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
    }
    code = posix_spawnattr_setflags(&attributes, Int16(flags))
    guard code == 0 else {
        return .failure(.spawnFailed(errno: code, path: path))
    }

    var fileActions: posix_spawn_file_actions_t?
    code = posix_spawn_file_actions_init(&fileActions)
    guard code == 0 else {
        return .failure(.spawnFailed(errno: code, path: path))
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    if let workingDirectory {
        code = posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory.path)
        guard code == 0 else {
            return .failure(.spawnFailed(errno: code, path: path))
        }
    }
    if isolatedStandardStreams {
        let streams: [(descriptor: Int32, openFlags: Int32)] = [
            (STDIN_FILENO, O_RDONLY), (STDOUT_FILENO, O_WRONLY), (STDERR_FILENO, O_WRONLY),
        ]
        for stream in streams {
            code = posix_spawn_file_actions_addopen(&fileActions, stream.descriptor, "/dev/null", stream.openFlags, 0)
            guard code == 0 else {
                return .failure(.spawnFailed(errno: code, path: path))
            }
        }
    }

    var pid: pid_t = 0
    code = posix_spawn(&pid, path, &fileActions, &attributes, &cArgv, &cEnvp)
    guard code == 0 else {
        return .failure(.spawnFailed(errno: code, path: path))
    }
    return .success(pid)
}
```

The only existing caller (command shortcuts, `main.swift` line 66) passes no `isolatedStandardStreams` and keeps today's behaviour. `POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT` is `0x4400`, inside `Int16`.

- [ ] **Step 4: Create `Launcher/Sources/Launcher/HelperRunner.swift`.**

```swift
import Darwin
import DuplicatorCore
import Foundation

/// What one helper watches and, when armed, erases (spec §4.3, §4.6).
struct HelperSession: Sendable {
    /// Dock Shortcut mode: the launcher's pid, which then execs into the target. System Launch: the target's pid.
    var watchedPID: pid_t
    /// The start time recorded for `watchedPID` before the watch; any other start time means the pid was reused.
    var startTime: ProcessStartTime
    /// True when the watched process must exec before its exit counts as the target's exit (Dock Shortcut mode).
    var requiresExec: Bool
    /// The data folder to empty after the target quits, already matched against `MADConfig`; nil means no erase.
    var erasePath: String?
    /// The real home folder, for `EraseOnQuitPolicy`.
    var home: URL
    var log: LaunchLogger
}

/// How a watch ended. Only `targetExited` may lead to an erase.
enum HelperWatchEnd: Equatable, Sendable {
    case targetExited(waitStatus: Int32?)
    case launcherFailed(waitStatus: Int32?)
    case pidReused
    case watchedProcessGone
    case watchFailed(String)

    /// The `HelperLogLine` for this end.
    var logLine: String {
        switch self {
        case .targetExited(let waitStatus): HelperLogLine.targetExited(waitStatus: waitStatus)
        case .launcherFailed(let waitStatus): HelperLogLine.launcherFailed(waitStatus: waitStatus)
        case .pidReused: HelperLogLine.pidReused
        case .watchedProcessGone: HelperLogLine.watchedProcessGone
        case .watchFailed(let reason): HelperLogLine.watchFailed(reason)
        }
    }
}

/// Drives one `ProcessWatcher` through `HelperWatchState` in the order the watch needs: register the kqueue first, then
/// compare the start time, then read both executable paths (an exec that raced the registration shows there), then fold
/// each batch of events with a fresh start-time comparison. `run()` blocks (the erase-only helper); the menu bar helper
/// calls `start()` once and then `handle(_:)` from a read source on `watcher.fileDescriptor`. Not Sendable: one owner
/// drives it.
final class HelperWatch {
    let session: HelperSession
    private(set) var watcher: ProcessWatcher?
    private var state: HelperWatchState?

    init(session: HelperSession) {
        self.session = session
    }

    /// Registers the watch. Returns how the watch already ended, or nil when events should be awaited.
    func start() -> HelperWatchEnd? {
        let pid = session.watchedPID
        let newWatcher: ProcessWatcher
        do {
            newWatcher = try ProcessWatcher(pid: pid)
        } catch ProcessWatcherError.processGone {
            return .watchedProcessGone
        } catch {
            return .watchFailed(String(describing: error))
        }
        watcher = newWatcher
        if let end = Self.end(for: HelperWatchState.startupDecision(for: session.startTime.compare(toLiveProcess: pid))) {
            return end
        }
        let newState = HelperWatchState(
            requiresExec: session.requiresExec,
            parentExecutablePath: ProcessWatcher.executablePath(of: pid),
            ownExecutablePath: ProcessWatcher.executablePath(of: getpid())
        )
        state = newState
        if session.requiresExec && newState.execObserved {
            session.log.log(HelperLogLine.execObserved)
        }
        return nil
    }

    /// Folds one batch of events in. Returns how the watch ended, or nil to keep watching.
    func handle(_ events: [ProcessWatchEvent]) -> HelperWatchEnd? {
        guard var current = state else {
            return .watchFailed("an event arrived before the watch started")
        }
        var end: HelperWatchEnd?
        for event in events where end == nil {
            let wasObserved = current.execObserved
            let decision = current.apply(event, startTime: session.startTime.compare(toLiveProcess: session.watchedPID))
            if !wasObserved && current.execObserved {
                session.log.log(HelperLogLine.execObserved)
            }
            end = Self.end(for: decision)
        }
        state = current
        return end
    }

    /// Blocks in `kevent` until the watch ends.
    func run() -> HelperWatchEnd {
        if let end = start() {
            return end
        }
        guard let watcher else {
            return .watchFailed("the watch did not start")
        }
        while true {
            let events: [ProcessWatchEvent]
            do {
                events = try watcher.wait(timeout: nil)
            } catch {
                return .watchFailed(String(describing: error))
            }
            if let end = handle(events) {
                return end
            }
        }
    }

    /// The end a decision means, or nil for `keepWatching`.
    static func end(for decision: HelperWatchState.Decision) -> HelperWatchEnd? {
        switch decision {
        case .keepWatching:
            return nil
        case .targetExited(let waitStatus):
            return .targetExited(waitStatus: waitStatus)
        case .launcherFailed(let waitStatus):
            return .launcherFailed(waitStatus: waitStatus)
        case .pidReused:
            return .pidReused
        case .watchedProcessGone:
            return .watchedProcessGone
        }
    }
}

/// The helper's ending, shared by the erase-only helper (here) and the menu bar helper.
enum HelperRunner {
    /// The erase-only helper: blocks until the watch ends, then finishes. Never creates `NSApplication`, so the helper
    /// never checks in with LaunchServices and shows nowhere.
    static func runBlocking(_ session: HelperSession) -> Never {
        finish(HelperWatch(session: session).run(), session: session)
    }

    /// Logs how the watch ended, erases only when it ended with the target's exit, logs `helper exit` and exits 0. Once
    /// the watch has started the helper always exits 0: nothing waits for its status, and every outcome is in the log.
    static func finish(_ end: HelperWatchEnd, session: HelperSession) -> Never {
        session.log.log(end.logLine)
        if case .targetExited = end {
            eraseIfArmed(session)
        }
        session.log.log(HelperLogLine.exiting)
        exit(0)
    }

    /// Empties the data folder when erase-on-quit is armed, no other copy of this shortcut's binary is running (a second
    /// launch may still be using the folder) and `EraseOnQuitPolicy` accepts the folder. Every outcome is logged.
    static func eraseIfArmed(_ session: HelperSession) {
        guard let erasePath = session.erasePath else {
            return
        }
        guard let ownPath = ProcessWatcher.executablePath(of: getpid()) else {
            session.log.log(HelperLogLine.ownPathUnreadable)
            return
        }
        let others = ProcessWatcher.pids(runningFrom: ownPath).filter { $0 != getpid() }
        guard others.isEmpty else {
            session.log.log(HelperLogLine.otherCopiesRunning(pids: others))
            return
        }
        switch EraseOnQuitPolicy.check(dataPath: erasePath, home: session.home) {
        case .success(let folder):
            let outcome = EraseOnQuitPerformer.erase(at: folder)
            session.log.log(HelperLogLine.erased(path: folder.path, removed: outcome.removed, failed: outcome.failures.count))
        case .failure(let refusal):
            session.log.log(HelperLogLine.eraseSkipped(refusal.logReason))
        }
    }
}
```

- [ ] **Step 5: Create `Launcher/Sources/Launcher/HelperRole.swift`.**

```swift
import DuplicatorCore
import Foundation

/// The `--helper` role (spec §3.4 step 5, §4.6). `main.swift` calls it before anything else, so it never touches the
/// launcher's globals. It logs through its own `LaunchLogger` (the helper keeps the launcher's HOME, so this is the same
/// `<Name>.log`), re-reads `MADConfig` and arms erase-on-quit only when the data path in argv is the one `MADConfig` names:
/// argv alone can never point the erase at another folder. A malformed argv or an unreadable `MADConfig` exits 1 after
/// one log line; every other path ends in `HelperRunner.finish`. Never returns.
@MainActor
func runHelperRole(arguments argv: [String]) -> Never {
    let helperLog = LaunchLogger(name: Bundle.main.bundleURL.deletingPathExtension().lastPathComponent)
    guard let helperArguments = HelperArguments.parse(argv) else {
        helperLog.log(HelperLogLine.malformed(argumentCount: argv.count))
        exit(1)
    }
    helperLog.log(HelperLogLine.start(
        helperPID: getpid(),
        watchedPID: helperArguments.parentPID,
        bundlePath: helperArguments.bundlePath,
        dataPath: helperArguments.dataPath
    ))
    let helperConfig: ShortcutConfig
    do {
        helperConfig = try readHelperConfig()
    } catch {
        helperLog.log(HelperLogLine.watchFailed(error.localizedDescription))
        helperLog.log(HelperLogLine.exiting)
        exit(1)
    }
    var erasePath: String?
    if let requested = helperArguments.dataPath {
        if requested == HelperPlan.eraseDataPath(for: helperConfig) {
            erasePath = requested
        } else {
            helperLog.log(HelperLogLine.dataPathMismatch)
        }
    }
    let session = HelperSession(
        watchedPID: helperArguments.parentPID,
        startTime: helperArguments.startTime,
        requiresExec: true,
        erasePath: erasePath,
        home: FileManager.default.homeDirectoryForCurrentUser,
        log: helperLog
    )
    HelperRunner.runBlocking(session)
}

/// `MADConfig` from this bundle's Info.plist, read the way `LaunchPreparer` reads it.
private func readHelperConfig() throws -> ShortcutConfig {
    guard let rawConfig = Bundle.main.infoDictionary?[ShortcutConfig.infoPlistKey] else {
        throw LauncherError.configMissing
    }
    guard let configDictionary = rawConfig as? [String: Any] else {
        throw LauncherError.configCorrupt("MADConfig is not a dictionary")
    }
    return try ShortcutConfig(plistDictionary: configDictionary)
}
```

`FileManager.default.homeDirectoryForCurrentUser` honours `CFFIXED_USER_HOME`, and `HelperEnvironment.helperEnvironment` gave the helper the launcher's own `HOME`/`CFFIXED_USER_HOME`, so `home` is the real home (the temp home in the gated test), never the data folder.

- [ ] **Step 6: Create `Launcher/Sources/Launcher/HelperLaunch.swift`.**

```swift
import Darwin
import DuplicatorCore
import Foundation

/// The parent side of the helper (spec §3.4 step 5, §4.6). In Dock Shortcut mode `main.swift` calls it just before
/// `execve`, so the helper watches this pid turn into the target. A failed spawn is logged and the launch goes on without
/// a helper: the target still starts; only the menu bar icon and erase-on-quit are missing for this run.
enum HelperLaunch {
    static func spawnIfNeeded(
        config shortcutConfig: ShortcutConfig,
        plan launchPlan: LaunchPlan,
        bundlePath: String,
        executableURL: URL?,
        baseEnvironment: [String: String],
        log launchLog: LaunchLogger
    ) {
        guard HelperPlan.isNeeded(for: shortcutConfig) else {
            return
        }
        guard let executableURL else {
            launchLog.log(HelperLogLine.spawnFailed("the shortcut bundle has no executable"))
            return
        }
        guard let startTime = ProcessStartTime.of(getpid()) else {
            launchLog.log(HelperLogLine.spawnFailed("the Launcher cannot read its own start time"))
            return
        }
        let helperArguments = HelperArguments(
            parentPID: getpid(),
            startTime: startTime,
            bundlePath: bundlePath,
            dataPath: HelperPlan.eraseDataPath(for: shortcutConfig)
        )
        let result = spawnDetached(
            executable: executableURL,
            arguments: helperArguments.arguments,
            environment: HelperEnvironment.helperEnvironment(shortcut: launchPlan.environment, base: baseEnvironment),
            workingDirectory: nil,
            isolatedStandardStreams: true
        )
        switch result {
        case .success(let pid):
            launchLog.log(HelperLogLine.spawned(pid: pid))
        case .failure(let error):
            launchLog.log(HelperLogLine.spawnFailed(error.localizedDescription))
        }
    }
}
```

The internal parameter names (`shortcutConfig`, `launchPlan`, `launchLog`) keep clear of `main.swift`'s globals `config`, `plan` and `logger`.

- [ ] **Step 7: Wire `main.swift`.** Edit bottom first, so the second edit's line numbers still hold.

First, in `Launcher/Sources/Launcher/main.swift` replace lines 89-100:

```swift
spawnHelperIfNeeded(config: config)

/// Fork point for the helper role (spec §4.6: status item, process watch, erase-on-quit). Phase 6 implements it;
/// until then it intentionally does nothing, and the call site exists so the launch order in spec §3.4 step 5 is fixed.
func spawnHelperIfNeeded(config: ShortcutConfig) {
    _ = config
}

if plan.launchMode == .systemLaunch {
    logger.log("system launch")
    launchViaSystem(prepared: prepared, logger: logger)
}
```

with:

```swift
if plan.launchMode == .systemLaunch {
    logger.log("system launch")
    launchViaSystem(prepared: prepared, logger: logger)
}

// Spec §3.4 step 5: in Dock Shortcut mode the helper starts just before exec, so it watches this pid become the target.
// System Launch never reaches this line (`launchViaSystem` never returns). A failed spawn is logged and the launch goes on.
HelperLaunch.spawnIfNeeded(
    config: config,
    plan: plan,
    bundlePath: Bundle.main.bundlePath,
    executableURL: Bundle.main.executableURL,
    baseEnvironment: base,
    log: logger
)
```

Lines 101-105 (the blank line, the Dock Shortcut comment, `logger.log("exec")`, `execTarget` and `fail`) stay as they are.

Then insert after line 2 (`import DuplicatorCore`):

```swift

// Spec §3.4 step 5, §4.6: the helper role runs before anything below. A helper never logs a launcher `start` line, never
// prepares a launch and never touches the globals below, which stay uninitialised in a helper process.
if HelperArguments.isHelperInvocation(CommandLine.arguments) {
    runHelperRole(arguments: CommandLine.arguments)
}
```

The Launcher read none of its own arguments before this phase (no `CommandLine` use under `Launcher/` or `DuplicatorCore`), so reserving `argv[1] == "--helper"` changes no existing behaviour. The file now starts:

```swift
import AppKit
import DuplicatorCore

// Spec §3.4 step 5, §4.6: the helper role runs before anything below. A helper never logs a launcher `start` line, never
// prepares a launch and never touches the globals below, which stay uninitialised in a helper process.
if HelperArguments.isHelperInvocation(CommandLine.arguments) {
    runHelperRole(arguments: CommandLine.arguments)
}

let shortcutName = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
let logger = LaunchLogger(name: shortcutName)
```

- [ ] **Step 8: Build.**

Run: `cd ~/Developer/MacAppDuplicator && swift build 2>&1 | tail -1`
Expected: `Build complete!`

- [ ] **Step 9: Run the whole gated integration suite.** The new test passes and the four existing ones (`CLILaunchTests` uses `spawnDetached` without isolation) still pass. The fixture window shows for about a second per launch test.

Run: `cd ~/Developer/MacAppDuplicator && swift build -c release --product Launcher --product WebShell --product madctl 2>&1 | tail -1 && Tools/build-fixture.sh && MAD_INTEGRATION=1 swift test --filter IntegrationTests 2>&1 | grep -E "Executed [0-9]+ tests?" | tail -1`
Expected: `Build complete!`, then `Executed 5 tests, with 0 failures (0 unexpected) in …`.

If `HelperEraseTests` fails only on `helper target exited status=0` and the log shows `helper target exited status=unavailable`, the kernel refused `NOTE_EXITSTATUS` for the helper's parent; the erase itself must still have run. If the log shows `helper erase skipped: another copy of this shortcut is still running`, a leftover process from an earlier run holds the shortcut binary (list it with `pgrep -fl "MAD Helper Erase"`). If entries remain in the folder after a `helper erase … removed=` line, something recreated them after the target quit. In all three cases stop and report the full failure text; do not loosen the test.

- [ ] **Step 10: Forbidden constructs.**

Run: `cd ~/Developer/MacAppDuplicator && grep -nE 'try\?|@unchecked|swiftlint:disable|nonisolated\(unsafe\)' Launcher/Sources/Launcher/{HelperLaunch,HelperRole,HelperRunner,Spawn,main}.swift Tests/Integration/HelperEraseTests.swift`
Expected: no output.

- [ ] **Step 11: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add Launcher/Sources/Launcher/HelperLaunch.swift Launcher/Sources/Launcher/HelperRole.swift Launcher/Sources/Launcher/HelperRunner.swift Launcher/Sources/Launcher/Spawn.swift Launcher/Sources/Launcher/main.swift Tests/Integration/HelperEraseTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Launcher: helper role with erase on quit" -m "In Dock Shortcut mode the Launcher starts its own binary as --helper with posix_spawn just before execve: a new session, /dev/null on the standard streams and no other inherited descriptor. main.swift dispatches the helper role before anything else. The helper re-reads MADConfig, arms the erase only for the data path MADConfig names, watches the launcher pid with kqueue and empties the data folder through EraseOnQuitPolicy and EraseOnQuitPerformer only after that pid exec'd into the target and exited, and only when no other copy of the shortcut binary is running. A gated integration test launches a real shortcut with a temp home and checks the folder is emptied while the linked Desktop survives." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Deviations

- `spawnDetached` gains `isolatedStandardStreams` (`POSIX_SPAWN_CLOEXEC_DEFAULT` plus `/dev/null` on descriptors 0 to 2). The Global Constraints name `posix_spawn` with `POSIX_SPAWN_SETSID` only; without the isolation the helper would inherit every descriptor of the launcher, including a caller's pipe (a test runner's, a terminal's), and hold it open for the target's whole lifetime.
- The spawn moved below the System Launch branch; the Phase 5 stub sat above it. System Launch has no exec to watch, and Task 6 turns the Launcher process itself into the helper there, so until Task 6 lands a System Launch shortcut runs without a helper.
- The helper re-reads `MADConfig` and arms the erase only when the argv data path equals `HelperPlan.eraseDataPath(for:)`; on a mismatch it logs `dataPathMismatch` and keeps watching without erasing. The brief has the helper trust its argv.
- The erase is skipped while another process runs the shortcut's binary (`ProcessWatcher.pids(runningFrom:)`, see Task 4's deviations): a second launch of the same shortcut has its own helper, and the folder is still in use.
- The gated test runs the shortcut's executable directly (the `CLILaunchTests` pattern) instead of opening it with `NSWorkspace`, so HOME and the log stay inside the mktemp home; the fixture therefore starts outside LaunchServices. The test copies `CLILaunchTests`' private helpers rather than sharing them, to leave that file untouched.
- `posix_spawn` keeps the parent link through `execve`, so the helper is a child of the target. A helper that ends first (pid reused, watch failure) stays a zombie until the target exits; launchd then reaps it. The erase-only helper otherwise always outlives the target.
- Exit codes: a malformed argv or an unreadable `MADConfig` exits 1 (the Global Constraints); once the watch has started the helper exits 0 whatever happened, because nothing reads its status and every outcome is logged.

---

### Task 6: Core menu bar decisions; Launcher menu bar helper (status item, Show, New Window, Quit) and System Launch helper

**Files:**
- Modify: `Packages/DuplicatorCore/Sources/DuplicatorCore/HelperPlan.swift` (two functions before the enum's closing brace)
- Test: `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/HelperPlanTests.swift` (four tests before the class's closing brace, line 56)
- Create: `Launcher/Sources/Launcher/HelperStatusItem.swift`
- Modify: `Launcher/Sources/Launcher/HelperRunner.swift` (imports; append `HelperMenuBarSettings` and `HelperMenuBarRunner`)
- Modify: `Launcher/Sources/Launcher/HelperRole.swift` (the last statement of `runHelperRole`; one new private function)
- Modify: `Launcher/Sources/Launcher/SystemLaunch.swift` (whole file)

**Interfaces:**
- Consumes: `ShortcutConfig.kind`, `.name`, `.menuBarIcon`, `.dataMode`, `.dataPath`, `.targetBundleIdentifier`, `.newWindowCommand` (Task 1); `NewWindowCommandBuilder.argv(template:targetPath:targetBundleIdentifier:dataPath:)` and `HelperMenuText.show(name:)`, `.newWindow`, `.quit(name:)` (Task 1); `HelperPlan.isNeeded(for:)`, `HelperPlan.eraseDataPath(for:)`, `HelperEnvironment.targetEnvironment(helper:)`, `HelperLogLine.start(helperPID:watchedPID:bundlePath:dataPath:)`, `.watchFailed(_:)`, `.watchedProcessGone`, `.exiting`, `.showFailed(_:)`, `.newWindow(argv:)`, `.newWindowFailed(_:)`, `.quit(signal:)` (Task 2); `ProcessStartTime.of(_:)`, `ProcessStartTime.compare(toLiveProcess:) -> Comparison` (`.same`, `.different`, `.gone`), `ProcessWatcher.fileDescriptor`, `ProcessWatcher.wait(timeout:)` (`0` polls) (Task 4); `HelperSession`, `HelperWatchEnd.watchFailed(_:)`, `HelperWatch` (`init(session:)`, `session`, `watcher`, `start()`, `handle(_:)`), `HelperRunner.runBlocking(_:)`, `HelperRunner.finish(_:session:)`, `spawnDetached(executable:arguments:environment:workingDirectory:isolatedStandardStreams:) -> Result<pid_t, LauncherError>` (argv[0] is `executable.path`) (Task 5); `TargetResolver().resolve(config:) throws -> URL`; `PreparedLaunch.config`, `.app.bundleURL`, `.plan.environment`, `.plan.arguments`, `.plan.environmentAdditions(relativeTo:)`; `fail(_:logger:)`; AppKit `NSStatusBar.system.statusItem(withLength:)`, `NSStatusItem.variableLength`, `NSApplication.setActivationPolicy(_:)`, `NSApplication.yieldActivation(to:)` (macOS 14, `NSApplication.h` line 244), `NSRunningApplication(processIdentifier:)`, `.unhide()`, `.activate(from:options:)` (macOS 14, `NSRunningApplication.h` line 144), `.activate(options:)`, `NSRunningApplication.current`, `NSApplication.ActivationOptions.activateAllWindows`, `NSWorkspace.shared.icon(forFile:)`; Dispatch `DispatchSource.makeReadSource(fileDescriptor:queue:)`, `DispatchQueue.main.asyncAfter(deadline:execute:)` (the closure is `@Sendable`); `Thread.detachNewThread(_:)` (`NS_SWIFT_SENDABLE` block, `NSThread.h` line 31); Darwin `kill`, `waitpid`, `SIGTERM`, `SIGKILL`.
- Produces:
  ```swift
  public enum HelperPlan {                                    // two functions added
      public static func showsMenuBarIcon(for config: ShortcutConfig) -> Bool
      public static func newWindowArguments(for config: ShortcutConfig, targetPath: String) -> [String]?
  }
  @MainActor final class HelperStatusItem: NSObject {
      static let iconPointSize: CGFloat                       // 18
      init(name: String, icon: NSImage, onShow: @escaping @MainActor () -> Void,
           onNewWindow: (@MainActor () -> Void)?, onQuit: @escaping @MainActor () -> Void)
      static func menuBarImage(from icon: NSImage) -> NSImage
      static func shortcutIcon(bundleURL: URL) -> NSImage
  }
  struct HelperMenuBarSettings: Sendable {
      var name: String
      var bundleURL: URL
      var showsStatusItem: Bool
      var newWindowArguments: [String]?
      var targetEnvironment: [String: String]
      init(config: ShortcutConfig, bundleURL: URL, targetPath: String, targetEnvironment: [String: String])
  }
  @MainActor final class HelperMenuBarRunner: NSObject, NSApplicationDelegate {
      static let killDelay: TimeInterval                      // 10
      static func run(_ session: HelperSession, settings: HelperMenuBarSettings) -> Never
  }
  ```

- [ ] **Step 1: Write the failing tests.** Insert these four tests in `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/HelperPlanTests.swift` directly before the class's closing brace (line 56):

```swift

    func testMenuBarIconShowsOnlyForApplicationShortcuts() {
        XCTAssertTrue(HelperPlan.showsMenuBarIcon(for: makeConfig(menuBarIcon: true)))
        XCTAssertTrue(HelperPlan.showsMenuBarIcon(for: makeConfig(dataMode: .disabled, menuBarIcon: true)))
        XCTAssertFalse(HelperPlan.showsMenuBarIcon(for: makeConfig(eraseOnQuit: true)))
        for kind in [ShortcutKind.webApp, .file, .folder, .cli] {
            XCTAssertFalse(HelperPlan.showsMenuBarIcon(for: makeConfig(kind: kind, menuBarIcon: true)), kind.rawValue)
        }
    }

    func testNewWindowArgumentsUseTheResolvedTargetAndTheDataFolder() {
        var config = makeConfig()
        config.newWindowCommand = "open -na {target} --args --user-data-dir={dataPath} --bundle={bundleId}"
        XCTAssertEqual(
            HelperPlan.newWindowArguments(for: config, targetPath: "/Applications/Moved/Claude.app"),
            [
                "/usr/bin/env", "open", "-na", "/Applications/Moved/Claude.app", "--args",
                "--user-data-dir=\(Self.dataPath)", "--bundle=com.anthropic.claudefordesktop",
            ]
        )
    }

    func testNewWindowArgumentsAreNilWithoutATemplateOrWithoutTheDataFolderTheTemplateNames() {
        XCTAssertNil(HelperPlan.newWindowArguments(for: makeConfig(), targetPath: "/Applications/Claude.app"))
        var disabled = makeConfig(dataMode: .disabled)
        disabled.newWindowCommand = "open -na {target} --args --user-data-dir={dataPath}"
        XCTAssertNil(HelperPlan.newWindowArguments(for: disabled, targetPath: "/Applications/Claude.app"))
        var emptyPath = makeConfig(dataPath: "")
        emptyPath.newWindowCommand = "open -na {target} --args --user-data-dir={dataPath}"
        XCTAssertNil(HelperPlan.newWindowArguments(for: emptyPath, targetPath: "/Applications/Claude.app"))
        // A template without {dataPath} still works when data separation is disabled.
        disabled.newWindowCommand = "open -na {target}"
        XCTAssertEqual(
            HelperPlan.newWindowArguments(for: disabled, targetPath: "/Applications/Claude.app"),
            ["/usr/bin/env", "open", "-na", "/Applications/Claude.app"]
        )
    }

    func testNewWindowArgumentsAreNilForOtherKinds() {
        for kind in [ShortcutKind.webApp, .file, .folder, .cli] {
            var config = makeConfig(kind: kind)
            config.newWindowCommand = "open -na {target}"
            XCTAssertNil(HelperPlan.newWindowArguments(for: config, targetPath: "/Applications/Claude.app"), kind.rawValue)
        }
    }
```

The data path contains spaces (`Application Support`, `App Duplicator`); `NewWindowCommandBuilder` splits the template before substituting, so `--user-data-dir=…` stays one argument.

- [ ] **Step 2: Run them and watch them fail to compile.**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.HelperPlanTests 2>&1 | grep -E "error:" | head -3`
Expected (first lines):
```
…/HelperPlanTests.swift:…: error: type 'HelperPlan' has no member 'showsMenuBarIcon'
…/HelperPlanTests.swift:…: error: type 'HelperPlan' has no member 'newWindowArguments'
```

- [ ] **Step 3: Add the two decisions to `Packages/DuplicatorCore/Sources/DuplicatorCore/HelperPlan.swift`.** Replace the end of the file:

```swift
              let dataPath = config.dataPath, !dataPath.isEmpty else { return nil }
        return dataPath
    }
}
```

with:

```swift
              let dataPath = config.dataPath, !dataPath.isEmpty else { return nil }
        return dataPath
    }

    /// True when the helper shows its status item: an application shortcut with the menu bar icon on. Data separation
    /// does not matter here; only erase-on-quit needs a separated folder.
    public static func showsMenuBarIcon(for config: ShortcutConfig) -> Bool {
        config.kind == .app && config.menuBarIcon
    }

    /// The New Window argv of an application shortcut: `newWindowCommand` rendered by `NewWindowCommandBuilder`, with
    /// `targetPath` (the app the launch resolved, which may differ from the stored `targetPath`) for `{target}` and the
    /// stored data folder for `{dataPath}` while data separation is on. Nil for other kinds, for a nil or blank template,
    /// and for a template that names `{dataPath}` when separation is disabled or no folder is stored; the menu item is
    /// then hidden.
    public static func newWindowArguments(for config: ShortcutConfig, targetPath: String) -> [String]? {
        guard config.kind == .app else { return nil }
        var dataPath: String?
        if config.dataMode != .disabled, let stored = config.dataPath, !stored.isEmpty {
            dataPath = stored
        }
        return NewWindowCommandBuilder.argv(
            template: config.newWindowCommand,
            targetPath: targetPath,
            targetBundleIdentifier: config.targetBundleIdentifier,
            dataPath: dataPath
        )
    }
}
```

- [ ] **Step 4: Run the suites and watch them pass.**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.HelperPlanTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: `Executed 7 tests, with 0 failures (0 unexpected) in …`

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: `Executed 286 tests, with 0 failures (0 unexpected) in …`

- [ ] **Step 5: Create `Launcher/Sources/Launcher/HelperStatusItem.swift`.**

```swift
import AppKit
import DuplicatorCore

/// The helper's menu bar item (spec §4.6): the shortcut's own icon in colour at 18 pt with the shortcut's name as the
/// tooltip, and a menu with Show <name>, New Window (only when the shortcut has a New Window command) and Quit <name>.
/// Laid out like WebShell's `StatusItemController`; the helper owns no window, so every item calls back into
/// `HelperMenuBarRunner` through a `@MainActor` closure.
@MainActor
final class HelperStatusItem: NSObject {
    static let iconPointSize: CGFloat = 18

    private let statusItem: NSStatusItem
    private let onShow: @MainActor () -> Void
    private let onNewWindow: (@MainActor () -> Void)?
    private let onQuit: @MainActor () -> Void

    init(
        name: String,
        icon: NSImage,
        onShow: @escaping @MainActor () -> Void,
        onNewWindow: (@MainActor () -> Void)?,
        onQuit: @escaping @MainActor () -> Void
    ) {
        self.onShow = onShow
        self.onNewWindow = onNewWindow
        self.onQuit = onQuit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.image = HelperStatusItem.menuBarImage(from: icon)
            button.imagePosition = .imageOnly
            button.toolTip = name
        }
        let menu = NSMenu()
        menu.addItem(menuItem(title: HelperMenuText.show(name: name), action: #selector(showFromMenu(_:))))
        if onNewWindow != nil {
            menu.addItem(menuItem(title: HelperMenuText.newWindow, action: #selector(newWindowFromMenu(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem(title: HelperMenuText.quit(name: name), action: #selector(quitFromMenu(_:))))
        statusItem.menu = menu
    }

    /// A resized copy of `icon` in colour; the original image is left untouched.
    static func menuBarImage(from icon: NSImage) -> NSImage {
        let side = NSSize(width: iconPointSize, height: iconPointSize)
        let image = icon.copy() as? NSImage ?? NSImage(size: side)
        image.size = side
        image.isTemplate = false
        return image
    }

    /// The shortcut's own icon: the `CFBundleIconFile` image in `Contents/Resources` (`BundleWriter` writes
    /// `AppIcon.icns` when the shortcut has an icon), else the icon Finder shows for the bundle.
    static func shortcutIcon(bundleURL: URL) -> NSImage {
        if let iconName = Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           !iconName.isEmpty {
            let fileName = (iconName as NSString).pathExtension.isEmpty ? iconName + ".icns" : iconName
            let iconURL = bundleURL
                .appending(path: "Contents/Resources", directoryHint: .isDirectory)
                .appending(path: fileName, directoryHint: .notDirectory)
            if let image = NSImage(contentsOf: iconURL) {
                return image
            }
        }
        return NSWorkspace.shared.icon(forFile: bundleURL.path)
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showFromMenu(_ sender: NSMenuItem) {
        onShow()
    }

    @objc private func newWindowFromMenu(_ sender: NSMenuItem) {
        onNewWindow?()
    }

    @objc private func quitFromMenu(_ sender: NSMenuItem) {
        onQuit()
    }
}
```

- [ ] **Step 6: Add the AppKit helper to `Launcher/Sources/Launcher/HelperRunner.swift`.** Replace the three import lines at the top:

```swift
import Darwin
import DuplicatorCore
import Foundation
```

with:

```swift
import AppKit
import Darwin
import DuplicatorCore
import Foundation
```

Then append at the end of the file, after `HelperRunner`'s closing brace:

```swift

/// What the AppKit helper shows and runs, fixed when the helper starts (spec §4.6): an edit to the shortcut reaches the
/// helper at the shortcut's next launch.
struct HelperMenuBarSettings: Sendable {
    /// The shortcut's name, for Show <name>, Quit <name> and the tooltip.
    var name: String
    /// The shortcut bundle, for its icon.
    var bundleURL: URL
    /// False for a System Launch helper that runs only for erase-on-quit.
    var showsStatusItem: Bool
    /// The New Window argv (`argv[0]` absolute), or nil when the item is hidden.
    var newWindowArguments: [String]?
    /// The environment New Window runs with: the target's own, home variables included.
    var targetEnvironment: [String: String]

    init(config: ShortcutConfig, bundleURL: URL, targetPath: String, targetEnvironment: [String: String]) {
        name = config.name
        self.bundleURL = bundleURL
        showsStatusItem = HelperPlan.showsMenuBarIcon(for: config)
        newWindowArguments = HelperPlan.newWindowArguments(for: config, targetPath: targetPath)
        self.targetEnvironment = targetEnvironment
    }
}

/// The AppKit helper (spec §4.6): an `.accessory` `NSApplication` (no Dock tile, no menu bar of its own) that drives the
/// same `HelperWatch` as the erase-only helper from a read source on the watcher's kqueue, so the run loop keeps serving
/// the status item while the watch waits. Every end of the watch goes through `HelperRunner.finish`, erase included.
/// Show and a reopen of the shortcut bring the target forward, New Window runs the shortcut's New Window command, and
/// Quit sends the target `SIGTERM`, then `SIGKILL` after `killDelay` seconds if the same process still runs.
@MainActor
final class HelperMenuBarRunner: NSObject, NSApplicationDelegate {
    /// Seconds between Quit's `SIGTERM` and the `SIGKILL` for a target that is still running (spec §4.6).
    static let killDelay: TimeInterval = 10

    private let watch: HelperWatch
    private let watcher: ProcessWatcher
    private let settings: HelperMenuBarSettings
    private var statusItem: HelperStatusItem?
    private var eventSource: DispatchSourceRead?

    private init(watch: HelperWatch, watcher: ProcessWatcher, settings: HelperMenuBarSettings) {
        self.watch = watch
        self.watcher = watcher
        self.settings = settings
        super.init()
    }

    /// Starts the watch, becomes an `.accessory` application and runs AppKit until the watch ends. A watch that ends
    /// before AppKit starts finishes at once. Never returns.
    static func run(_ session: HelperSession, settings: HelperMenuBarSettings) -> Never {
        let watch = HelperWatch(session: session)
        if let end = watch.start() {
            HelperRunner.finish(end, session: session)
        }
        guard let watcher = watch.watcher else {
            HelperRunner.finish(.watchFailed("the watch did not start"), session: session)
        }
        let runner = HelperMenuBarRunner(watch: watch, watcher: watcher, settings: settings)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        // `NSApplication.delegate` is weak; `withExtendedLifetime` keeps the runner alive while AppKit runs.
        application.delegate = runner
        runner.startEventSource()
        withExtendedLifetime(runner) {
            application.run()
        }
        HelperRunner.finish(.watchFailed("the application run loop stopped"), session: session)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard settings.showsStatusItem else {
            return
        }
        var onNewWindow: (@MainActor () -> Void)?
        if settings.newWindowArguments != nil {
            onNewWindow = { [weak self] in self?.newWindow() }
        }
        statusItem = HelperStatusItem(
            name: settings.name,
            icon: HelperStatusItem.shortcutIcon(bundleURL: settings.bundleURL),
            onShow: { [weak self] in self?.show() },
            onNewWindow: onNewWindow,
            onQuit: { [weak self] in self?.quit() }
        )
    }

    /// Opening the shortcut again while this helper is its running instance shows the target instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return false
    }

    /// The kqueue descriptor is readable while an event is pending; each wake-up polls and folds the events in.
    private func startEventSource() {
        let source = DispatchSource.makeReadSource(fileDescriptor: watcher.fileDescriptor, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.drainEvents() }
        }
        eventSource = source
        source.resume()
    }

    private func drainEvents() {
        let events: [ProcessWatchEvent]
        do {
            events = try watcher.wait(timeout: 0)
        } catch {
            HelperRunner.finish(.watchFailed(String(describing: error)), session: watch.session)
        }
        if let end = watch.handle(events) {
            HelperRunner.finish(end, session: watch.session)
        }
    }

    /// Unhides the target and asks macOS to activate it with all its windows: cooperatively first (this helper yields
    /// its activation), then directly. A target that is gone, a reused pid and a refused activation are logged.
    private func show() {
        let pid = watch.session.watchedPID
        guard watch.session.startTime.compare(toLiveProcess: pid) == .same,
              let target = NSRunningApplication(processIdentifier: pid) else {
            watch.session.log.log(HelperLogLine.showFailed("pid \(pid) is not a running application"))
            return
        }
        _ = target.unhide()
        NSApplication.shared.yieldActivation(to: target)
        if !target.activate(from: NSRunningApplication.current, options: [.activateAllWindows]),
           !target.activate(options: [.activateAllWindows]) {
            watch.session.log.log(HelperLogLine.showFailed("macOS refused to activate pid \(pid)"))
        }
    }

    /// Spec §4.6: `SIGTERM` now, `SIGKILL` after `killDelay` seconds if the same process still runs. The watch sees the
    /// exit and finishes the helper as for any other quit, erase included.
    private func quit() {
        signalTarget(SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.killDelay) { [weak self] in
            MainActor.assumeIsolated { self?.signalTarget(SIGKILL) }
        }
    }

    /// Signals the watched pid only while its start time still matches, so a reused pid is never signalled.
    private func signalTarget(_ signalNumber: Int32) {
        let pid = watch.session.watchedPID
        guard watch.session.startTime.compare(toLiveProcess: pid) == .same else {
            return
        }
        if kill(pid, signalNumber) == 0 {
            watch.session.log.log(HelperLogLine.quit(signal: signalNumber))
        }
    }

    /// Runs the New Window argv detached, with the target's environment and `/dev/null` on its standard streams.
    private func newWindow() {
        guard let argv = settings.newWindowArguments, let program = argv.first else {
            return
        }
        let result = spawnDetached(
            executable: URL(filePath: program),
            arguments: Array(argv.dropFirst()),
            environment: settings.targetEnvironment,
            workingDirectory: nil,
            isolatedStandardStreams: true
        )
        switch result {
        case .success(let pid):
            watch.session.log.log(HelperLogLine.newWindow(argv: argv))
            Self.reap(pid)
        case .failure(let error):
            watch.session.log.log(HelperLogLine.newWindowFailed(error.localizedDescription))
        }
    }

    /// Collects a New Window child's exit status on a background thread, so a short-lived `open` never stays a zombie
    /// of the helper.
    nonisolated private static func reap(_ pid: pid_t) {
        Thread.detachNewThread {
            var status: Int32 = 0
            var result = waitpid(pid, &status, 0)
            while result < 0 && errno == EINTR {
                result = waitpid(pid, &status, 0)
            }
        }
    }
}
```

The read-source handler is the `FolderWatcher.start()` pattern (`setEventHandler { [weak self] in MainActor.assumeIsolated { … } }` on `.main`), which compiles under the package's Swift 6 language mode. Events that arrive between `watch.start()` and `source.resume()` stay queued in the kqueue, so the descriptor is already readable when the source starts.

- [ ] **Step 7: Route the menu bar case in `Launcher/Sources/Launcher/HelperRole.swift`.** Replace the last two lines of `runHelperRole` (they occur once in the file):

```swift
    HelperRunner.runBlocking(session)
}
```

with:

```swift
    // Spec §4.6: AppKit only for the status item. The erase-only helper stays a plain kqueue wait.
    guard HelperPlan.showsMenuBarIcon(for: helperConfig) else {
        HelperRunner.runBlocking(session)
    }
    HelperMenuBarRunner.run(session, settings: HelperMenuBarSettings(
        config: helperConfig,
        bundleURL: URL(filePath: helperArguments.bundlePath, directoryHint: .isDirectory),
        targetPath: resolvedTargetPath(for: helperConfig),
        targetEnvironment: HelperEnvironment.targetEnvironment(helper: ProcessInfo.processInfo.environment)
    ))
}
```

Then append at the end of the file, after `readHelperConfig()`:

```swift

/// The path New Window's `{target}` names: the app `TargetResolver` finds now (the launch resolved it the same way a
/// moment ago), or the stored path when it finds none.
private func resolvedTargetPath(for shortcutConfig: ShortcutConfig) -> String {
    do {
        return try TargetResolver().resolve(config: shortcutConfig).path
    } catch {
        return shortcutConfig.targetPath
    }
}
```

`ProcessInfo.processInfo.environment` is the helper's own environment, which `HelperEnvironment.helperEnvironment` built from the shortcut's; `targetEnvironment(helper:)` puts the shortcut's `HOME` and `CFFIXED_USER_HOME` back for New Window.

- [ ] **Step 8: Replace `Launcher/Sources/Launcher/SystemLaunch.swift`.** The launch itself is unchanged; the handler also records the pid, and the end hands over to the helper when one is needed. The whole file:

```swift
import AppKit
import DuplicatorCore
import os

/// System Launch mode: asks LaunchServices to start the target as its own application instance. Without a helper the
/// Launcher then exits 0; with one (spec §4.6: menu bar icon or erase-on-quit) this process stays as the target's helper.
/// Any launch failure goes through `fail`, which exits 3.
@MainActor
func launchViaSystem(prepared: PreparedLaunch, logger: LaunchLogger) -> Never {
    let plan = prepared.plan
    let bundlePath = prepared.app.bundleURL.path

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = plan.arguments
    // LaunchServices merges these over its own environment, so only the differences are sent.
    configuration.environment = plan.environmentAdditions(relativeTo: ProcessInfo.processInfo.environment)
    configuration.createsNewApplicationInstance = true
    configuration.activates = true

    let done = DispatchSemaphore(value: 0)
    let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
    let targetPID = OSAllocatedUnfairLock<pid_t?>(initialState: nil)
    // `@Sendable`: the handler's queue is not documented, and it touches only the two locks and the semaphore.
    NSWorkspace.shared.openApplication(at: prepared.app.bundleURL, configuration: configuration) { @Sendable application, error in
        failure.withLock { $0 = error?.localizedDescription }
        targetPID.withLock { $0 = application?.processIdentifier }
        done.signal()
    }

    // The completion handler's queue is not documented, so the main thread must not block on the semaphore.
    // Pump the run loop while polling it, with a 30 s deadline.
    let deadline = Date(timeIntervalSinceNow: 30)
    var completed = false
    while !completed, Date() < deadline {
        completed = done.wait(timeout: .now()) == .success
        if !completed {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    guard completed else {
        logger.log("system launch failed: timed out after 30 s")
        fail(LauncherError.execFailed(errno: ETIMEDOUT, path: bundlePath), logger: logger)
    }
    if let message = failure.withLock({ $0 }) {
        logger.log("system launch failed: \(message)")
        fail(LauncherError.execFailed(errno: EIO, path: bundlePath), logger: logger)
    }
    logger.log("system launch ok")
    guard HelperPlan.isNeeded(for: prepared.config) else {
        exit(0)
    }
    let launchedPID = targetPID.withLock { $0 }
    runSystemLaunchHelper(prepared: prepared, targetPID: launchedPID, logger: logger)
}

/// Spec §4.6 in System Launch mode: this process becomes the helper of the pid LaunchServices returned. The target was
/// never this process, so no exec is awaited (`requiresExec` false), and its start time is read now. LaunchServices
/// started this process as the shortcut, so it always becomes an `.accessory` application through
/// `HelperMenuBarRunner`, with a status item only when the menu bar icon is on. A missing pid or a target already gone
/// ends the helper after one line. Never returns.
@MainActor
private func runSystemLaunchHelper(prepared: PreparedLaunch, targetPID: pid_t?, logger: LaunchLogger) -> Never {
    guard let pid = targetPID, pid > 0 else {
        logger.log(HelperLogLine.watchFailed("LaunchServices returned no process id for the target"))
        logger.log(HelperLogLine.exiting)
        exit(0)
    }
    guard let startTime = ProcessStartTime.of(pid) else {
        logger.log(HelperLogLine.watchedProcessGone)
        logger.log(HelperLogLine.exiting)
        exit(0)
    }
    let erasePath = HelperPlan.eraseDataPath(for: prepared.config)
    logger.log(HelperLogLine.start(helperPID: getpid(), watchedPID: pid, bundlePath: Bundle.main.bundlePath, dataPath: erasePath))
    let session = HelperSession(
        watchedPID: pid,
        startTime: startTime,
        requiresExec: false,
        erasePath: erasePath,
        home: FileManager.default.homeDirectoryForCurrentUser,
        log: logger
    )
    HelperMenuBarRunner.run(session, settings: HelperMenuBarSettings(
        config: prepared.config,
        bundleURL: Bundle.main.bundleURL,
        targetPath: prepared.app.bundleURL.path,
        targetEnvironment: prepared.plan.environment
    ))
}
```

The System Launch Launcher never changes its own environment, so `homeDirectoryForCurrentUser` is the real home here too. `NSRunningApplication` is `NS_SWIFT_SENDABLE`, so reading `processIdentifier` inside the `@Sendable` handler is allowed; a pid of `-1` (an application without one) takes the first guard.

- [ ] **Step 9: Build.**

Run: `cd ~/Developer/MacAppDuplicator && swift build 2>&1 | tail -1`
Expected: `Build complete!`

- [ ] **Step 10: Run the gated integration suite.** `HelperEraseTests` (menu bar icon off, Dock Shortcut mode) goes through the changed `runHelperRole` and must still take the `runBlocking` path; no gated test uses System Launch or the menu bar icon.

Run: `cd ~/Developer/MacAppDuplicator && swift build -c release --product Launcher --product WebShell --product madctl 2>&1 | tail -1 && Tools/build-fixture.sh && MAD_INTEGRATION=1 swift test --filter IntegrationTests 2>&1 | grep -E "Executed [0-9]+ tests?" | tail -1`
Expected: `Build complete!`, then `Executed 5 tests, with 0 failures (0 unexpected) in …`.

- [ ] **Step 11: Forbidden constructs, and no status item in any test.**

Run: `cd ~/Developer/MacAppDuplicator && grep -nE 'try\?|@unchecked|swiftlint:disable|nonisolated\(unsafe\)' Packages/DuplicatorCore/Sources/DuplicatorCore/HelperPlan.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/HelperPlanTests.swift Launcher/Sources/Launcher/{HelperStatusItem,HelperRunner,HelperRole,SystemLaunch}.swift`
Expected: no output.

Run: `cd ~/Developer/MacAppDuplicator && grep -rnE 'NSStatusItem|NSStatusBar|HelperStatusItem|HelperMenuBarRunner' Packages/DuplicatorCore/Tests Tests App/Tests WebShell/Tests --include='*.swift'`
Expected: no output.

- [ ] **Step 12: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add Packages/DuplicatorCore/Sources/DuplicatorCore/HelperPlan.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/HelperPlanTests.swift Launcher/Sources/Launcher/HelperStatusItem.swift Launcher/Sources/Launcher/HelperRunner.swift Launcher/Sources/Launcher/HelperRole.swift Launcher/Sources/Launcher/SystemLaunch.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Launcher: menu bar helper and System Launch helper" -m "HelperPlan decides whether the status item shows and renders the New Window argv with the target path the launch resolved and, while data separation is on, the shortcut's data folder. With the menu bar icon on, the helper becomes an accessory NSApplication with a colour status item (Show <name>, New Window when the shortcut has a New Window command, Quit <name>) and drives the same HelperWatch from a read source on the watcher's kqueue. Show unhides and activates the target, New Window runs the command with posix_spawn in the target's environment, Quit sends SIGTERM and SIGKILL ten seconds later while the start time still matches, and reopening the shortcut shows the target. In System Launch mode the Launcher stays as the helper of the pid LaunchServices returned, for the menu bar icon and erase-on-quit." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Deviations

- `HelperPlan.showsMenuBarIcon(for:)` and `HelperPlan.newWindowArguments(for:targetPath:)` are not in the brief. They move the menu bar decisions into Core so they get failing tests first. The AppKit code has no automated test because tests never create an `NSStatusItem` (Global Constraints); Task 10's `docs/acceptance/phase6-helper.md` checks the status item, Show, New Window, Quit and reopen by hand.
- The status item image is the shortcut's own icon in colour (`isTemplate = false`, as WebShell's `StatusItemController`), not template-rendered as spec §4.6 says: a full-colour app icon rendered as a template becomes a solid silhouette. Task 10 updates the spec line.
- `{target}` is the app `TargetResolver` finds when the helper starts (System Launch: the app the launch opened), so a moved target still gets its current path. `{dataPath}` is filled only while data separation is on; a template that names it is hidden otherwise rather than run with an empty value.
- System Launch with erase-on-quit alone still creates `NSApplication` (`.accessory`, no status item), against the Global Constraints' "AppKit-free unless `menuBarIcon`": LaunchServices started this process as the shortcut, and a process that stays alive for the target's whole lifetime without checking in would leave the shortcut's tile in the Dock as an app that never finishes launching. The Dock Shortcut erase-only helper (started with `posix_spawn`, not by LaunchServices) stays AppKit-free.
- Reopen: when LaunchServices routes a second open of the shortcut to an AppKit helper, `applicationShouldHandleReopen` shows the target instead of starting another copy. Which process receives that reopen in Dock Shortcut mode (the exec'd target, which LaunchServices launched as the shortcut, or the helper, which checks in under the same bundle) is not documented; Task 10's acceptance doc records it.
- Show tries cooperative activation first (`yieldActivation(to:)`, then `activate(from:options:)`), then `activate(options:)`. macOS 14 and later may still refuse; that is logged as `helper show failed: macOS refused to activate pid N` and not retried.
- New Window children run through `spawnDetached` (own session, `/dev/null` streams, no inherited descriptors) and are reaped on a detached thread, so `open` never stays a zombie of the helper. Their environment is the target's (Dock Shortcut: `HelperEnvironment.targetEnvironment` of the helper's own; System Launch: `plan.environment`).
- The helper snapshots `MADConfig` and the target path when it starts; an edit to the shortcut changes the menu at the next launch.
- A failed `kill` is not logged: the only expected failure is a target that already exited, and the watch logs that exit.
- The System Launch helper reads the target's start time when the callback returns, not "at fork" as spec §4.6 says (there is no fork on this path); `HelperWatch.start()` compares it again after registering the kqueue. A target that exits before that read ends the helper with `helper watched process already gone`, without an erase.
- The System Launch completion handler is now explicitly `@Sendable`. It records the pid as well as the error, and an explicit `@Sendable` keeps it nonisolated on whatever queue AppKit calls it instead of relying on how the SDK imports the block (a `@MainActor`-inferred closure called off the main thread fails Swift 6's runtime isolation check). Its captures are two `OSAllocatedUnfairLock`s and a `DispatchSemaphore`, all `Sendable`.

---

### Task 7: App: HelperEditorPolicy, wizard New Window copy, profile row, preview helper line, Diagnostics helper rows

**Files:**
- Create: `App/Sources/Services/HelperEditorPolicy.swift`, `App/Tests/Services/HelperEditorPolicyTests.swift` (the Xcode project is generated by `Tools/test-app.sh` with xcodegen and is gitignored, so new files need no project edit and there is no project file to stage).
- Modify: `App/Sources/Views/Wizard/WizardModel.swift` (properties at lines 47-51; the two reset branches and the success branch of `selectTarget`; `makeConfig()`), `App/Sources/Services/ProfileSummary.swift` (doc comment lines 34-35; the rows after `Environment`), `App/Sources/Services/LaunchPlanPreview.swift` (field after `family`, line 18; the application return inside `make`), `App/Sources/Views/DiagnosticsView.swift` (`DiagnosticsModel` field after `launcher`, line 30; `make` success path; `failed` at line 167; `reportText` native branch), `Packages/CompatProfiles/Sources/CompatProfiles/ProfilesDocument.swift` (doc comment at line 19 only).
- Test: `App/Tests/Wizard/WizardModelTests.swift` (class closes at line 211), `App/Tests/Services/ProfileSummaryTests.swift`, `App/Tests/Services/LaunchPlanPreviewTests.swift`, `App/Tests/App/DiagnosticsModelTests.swift` (each gains tests directly before the class's closing brace, the file's last line).

**Interfaces:**
- Consumes: `ShortcutConfig.newWindowCommand`, `LanguageCode.validationMessage(for:)`, `LanguageCode.isValid(_:)`, `LanguageCode.invalidMessage`, `NewWindowCommandBuilder.validationMessage(for:)`, `HelperMenuText.newWindow` (Task 1); `HelperPlan.isNeeded(for:)`, `HelperPlan.eraseDataPath(for:)` (Task 2); `EraseOnQuitPolicy.check(dataPath:home:) -> Result<URL, EraseOnQuitRefusal>`, `EraseOnQuitRefusal.missing`, `EraseOnQuitRefusal.logReason` (Task 3); `HelperPlan.showsMenuBarIcon(for:)`, `HelperPlan.newWindowArguments(for:targetPath:)` (Task 6); App `CanonicalPath(_:)`, `CanonicalPath.isInside(_:)` (`App/Sources/Services/CanonicalPath.swift` lines 13 and 27), `ShortcutConfig.resolvingDefaultDataPath(home:)`, `.effectiveDataPath(home:)`, `ShortcutConfig.dataRoot(home:)` (`App/Sources/Services/ShortcutConfig+DefaultDataPath.swift`), `ProfileSummary.Row(label:value:)`, `ProfileSummary.rows(for:detectedFamily:)`; Core `SecretMasking.maskArguments(_:) -> [String]` (`SecretMasking.swift` line 28), `SecretMasking.maskedValue`, `ShortcutConfig.defaultDataPath(forSlug:home:)`, `ShortcutConfig.slug`, `ShortcutConfig.languageCode` (line 26); CompatProfiles `AppProfile(name:status:family:args:env:newWindowCommand:notes:)`; test support `makeAppTemporaryDirectory() throws -> URL`, `makeConfig(name:targetPath:targetBundleIdentifier:kind:)`, `makeWebConfig(name:url:dataStoreID:)`, `writeFakeTarget(named:bundleIdentifier:version:in:) throws -> URL`, `writeShortcutBundle(named:in:config:engineVersion:withIcon:extraInfo:) throws -> URL` (`App/Tests/TestSupport/AppTestSupport.swift` lines 9, 56, 65, 43, 18); `LibraryScanner.record(forBundleAt:fileManager:)`, `DiagnosticsModel.make(record:logReader:profileCatalog:)` (line 63), `LogReader(folder:)`, `WizardModel(prefillTarget:profileLookup:)`, `WizardModel.selectTarget(_:)`, `WizardModel.makeConfig()`, `LaunchPlanPreview.make(config:bundleURL:terminalLocator:home:) throws` (line 28).
- Produces:
  ```swift
  nonisolated enum HelperEditorPolicy {
      enum EraseCheck: Equatable { case allowed; case needsConfirmation(dataPath: String); case refused(String) }
      static let unavailableCaption: String
      static let disabledDataMessage: String
      static let eraseConfirmationTitle: String
      static let eraseConfirmButton: String
      static let newWindowPrompt: String
      static let newWindowHelp: String
      static func helperControlsVisible(kind: ShortcutKind) -> Bool
      static func canEnableEraseWithoutConfirm(dataPath: String, home: URL) -> Bool
      static func eraseRefusalReason(dataPath: String, home: URL) -> String?
      static func eraseCheck(dataPath: String?, dataMode: DataMode, home: URL) -> EraseCheck
      static func eraseCheck(for config: ShortcutConfig, home: URL) -> EraseCheck
      static func eraseConfirmationMessage(name: String, dataPath: String) -> String
      static func newWindowValidation(_ template: String?) -> String?
      static func languageValidation(_ code: String?) -> String?
      static func validationMessage(for draft: ShortcutConfig) -> String?
      static func saveConfig(draft: ShortcutConfig) -> ShortcutConfig
      static func newWindowNote(for config: ShortcutConfig, home: URL) -> String?
      static func helperLine(for config: ShortcutConfig, home: URL) -> String?
      static func newWindowText(for config: ShortcutConfig, home: URL) -> String
      static func eraseText(for config: ShortcutConfig, home: URL) -> String
      static func languageText(_ code: String?) -> String
      static func diagnosticsRows(for config: ShortcutConfig, home: URL) -> [ProfileSummary.Row]
  }
  // WizardModel
  private(set) var newWindowCommand: String?
  // LaunchPlanPreview (memberwise init parameter defaults to nil)
  var helper: String?
  // DiagnosticsModel (memberwise init parameter defaults to [])
  var helperRows: [ProfileSummary.Row]
  // ProfileSummary.rows(for:detectedFamily:) gains a "New Window" row between "Environment" and "Notes"
  ```

- [ ] **Step 1: Write the failing policy tests.**

Create `App/Tests/Services/HelperEditorPolicyTests.swift`:

```swift
import DuplicatorCore
import XCTest
@testable import MacAppDuplicator

final class HelperEditorPolicyTests: XCTestCase {
    private var dir: URL!
    private var home: URL!

    override func setUpWithError() throws {
        dir = try makeAppTemporaryDirectory()
        home = dir.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    /// Creates `relativePath` and its parents under the test home and returns its path.
    private func makeFolder(_ relativePath: String) throws -> String {
        let url = home.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// `<test home>/Library/Application Support/App Duplicator`.
    private var dataRoot: String {
        ShortcutConfig.dataRoot(home: home).path
    }

    /// The application shortcut "Target Work" with the given data settings and every helper option off.
    private func appConfig(dataMode: DataMode = .auto, dataPath: String? = nil) -> ShortcutConfig {
        var config = makeConfig(targetPath: "/Applications/Target.app")
        config.dataMode = dataMode
        config.dataPath = dataPath
        config.menuBarIcon = false
        config.eraseOnQuit = false
        config.newWindowCommand = nil
        config.languageCode = nil
        return config
    }

    func testHelperControlsShowForApplicationShortcutsOnly() {
        XCTAssertTrue(HelperEditorPolicy.helperControlsVisible(kind: .app))
        for kind in [ShortcutKind.webApp, .file, .folder, .cli] {
            XCTAssertFalse(HelperEditorPolicy.helperControlsVisible(kind: kind), kind.rawValue)
        }
    }

    func testOnlyFoldersInsideTheDataRootSkipTheConfirmation() throws {
        let work = dataRoot + "/target-work"
        XCTAssertTrue(HelperEditorPolicy.canEnableEraseWithoutConfirm(dataPath: work, home: home), "a default folder before the first launch")
        let created = try makeFolder("Library/Application Support/App Duplicator/target-work")
        XCTAssertTrue(HelperEditorPolicy.canEnableEraseWithoutConfirm(dataPath: created, home: home))
        XCTAssertFalse(HelperEditorPolicy.canEnableEraseWithoutConfirm(dataPath: dataRoot, home: home), "the data root itself")
        let custom = try makeFolder("Projects/data")
        XCTAssertFalse(HelperEditorPolicy.canEnableEraseWithoutConfirm(dataPath: custom, home: home))
        XCTAssertFalse(HelperEditorPolicy.canEnableEraseWithoutConfirm(dataPath: "Library/Application Support/App Duplicator/target-work", home: home))
    }

    func testEraseCheckAllowsAsksOrRefuses() throws {
        let work = try makeFolder("Library/Application Support/App Duplicator/target-work")
        let custom = try makeFolder("Projects/data")
        let documents = try makeFolder("Documents")
        let stuff = try makeFolder("Stuff")
        let caches = try makeFolder("Library/Caches")
        let outside = dir.appending(path: "outside/data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = home.appending(path: "Projects/link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: work)

        func check(_ path: String?, _ mode: DataMode = .homeOverride) -> HelperEditorPolicy.EraseCheck {
            HelperEditorPolicy.eraseCheck(dataPath: path, dataMode: mode, home: home)
        }
        func refused(_ reason: String) -> HelperEditorPolicy.EraseCheck {
            .refused("Erase on quit never empties this folder: \(reason).")
        }

        XCTAssertEqual(check(work, .auto), .allowed)
        XCTAssertEqual(check(dataRoot + "/not-created-yet", .auto), .allowed, "a missing folder is checked again at quit")
        XCTAssertEqual(check(custom), .needsConfirmation(dataPath: custom))
        XCTAssertEqual(check(home.path), refused("the folder is the home folder"))
        XCTAssertEqual(check(documents), refused("the folder is ~/Documents"))
        XCTAssertEqual(check(stuff), refused("the folder is directly inside the home folder"))
        XCTAssertEqual(check(caches), refused("the folder is directly inside ~/Library"))
        XCTAssertEqual(check(dataRoot), refused("the folder is the App Duplicator data root"))
        XCTAssertEqual(check(outside.path), refused("the folder is outside the home folder"))
        XCTAssertEqual(check(link), refused("the path is a symbolic link"))
        XCTAssertEqual(check("Projects/data"), refused("the path is not a normalised absolute path"))
        XCTAssertEqual(check(custom, .disabled), .refused(HelperEditorPolicy.disabledDataMessage))
        XCTAssertEqual(check(nil), .refused(HelperEditorPolicy.disabledDataMessage))
        XCTAssertEqual(check(""), .refused(HelperEditorPolicy.disabledDataMessage))
    }

    func testEraseCheckForAConfigUsesItsEffectiveDataFolder() throws {
        XCTAssertEqual(HelperEditorPolicy.eraseCheck(for: appConfig(), home: home), .allowed, "Auto without a stored folder uses the default folder")
        let custom = try makeFolder("Projects/data")
        XCTAssertEqual(
            HelperEditorPolicy.eraseCheck(for: appConfig(dataMode: .homeOverride, dataPath: custom), home: home),
            .needsConfirmation(dataPath: custom)
        )
        XCTAssertEqual(HelperEditorPolicy.eraseCheck(for: appConfig(dataMode: .disabled), home: home), .refused(HelperEditorPolicy.disabledDataMessage))
        XCTAssertEqual(
            HelperEditorPolicy.eraseCheck(for: appConfig(dataMode: .disabled, dataPath: custom), home: home),
            .refused(HelperEditorPolicy.disabledDataMessage),
            "a folder kept from before Data was disabled"
        )
        XCTAssertEqual(
            HelperEditorPolicy.eraseConfirmationMessage(name: "Target Work", dataPath: custom),
            "Every time Target Work quits, everything inside \(custom) is deleted permanently. It is not moved to the Trash. This folder is outside App Duplicator's data folder."
        )
    }

    func testValidationMessagesForLanguageAndNewWindow() {
        XCTAssertEqual(HelperEditorPolicy.languageValidation("french"), LanguageCode.invalidMessage)
        XCTAssertEqual(HelperEditorPolicy.languageValidation("en_US"), LanguageCode.invalidMessage)
        XCTAssertNil(HelperEditorPolicy.languageValidation("pt-BR"))
        XCTAssertNil(HelperEditorPolicy.languageValidation(" fr "))
        XCTAssertNil(HelperEditorPolicy.languageValidation(nil))
        XCTAssertNil(HelperEditorPolicy.languageValidation("  "))

        let control = "The New Window command may not contain control characters."
        XCTAssertEqual(HelperEditorPolicy.newWindowValidation("open\n-na {target}"), control)
        XCTAssertEqual(HelperEditorPolicy.newWindowValidation("open\u{7F} -na {target}"), control)
        XCTAssertNil(HelperEditorPolicy.newWindowValidation("open\t-na {target}"))
        XCTAssertNil(HelperEditorPolicy.newWindowValidation(nil))
        XCTAssertEqual(
            HelperEditorPolicy.newWindowValidation(String(repeating: "a", count: 2_049)),
            "The New Window command is longer than 2048 characters."
        )

        var draft = appConfig()
        draft.languageCode = "french"
        draft.newWindowCommand = "open\n-na {target}"
        XCTAssertEqual(HelperEditorPolicy.validationMessage(for: draft), LanguageCode.invalidMessage, "the language message comes first")
        draft.languageCode = "fr"
        XCTAssertEqual(HelperEditorPolicy.validationMessage(for: draft), control)
        draft.newWindowCommand = "open -na {target}"
        XCTAssertNil(HelperEditorPolicy.validationMessage(for: draft))

        var web = makeWebConfig()
        web.languageCode = "french"
        web.newWindowCommand = "open\n"
        XCTAssertNil(HelperEditorPolicy.validationMessage(for: web), "hidden fields never block Save")
    }

    func testSaveConfigTrimsTheTextFieldsAndDropsAnInertErase() {
        var draft = appConfig(dataMode: .disabled)
        draft.languageCode = " fr "
        draft.newWindowCommand = "  open -na {target}  "
        draft.eraseOnQuit = true
        let saved = HelperEditorPolicy.saveConfig(draft: draft)
        XCTAssertEqual(saved.languageCode, "fr")
        XCTAssertEqual(saved.newWindowCommand, "open -na {target}")
        XCTAssertFalse(saved.eraseOnQuit, "erase never runs while data separation is disabled")

        var blank = appConfig()
        blank.languageCode = "   "
        blank.newWindowCommand = "   "
        blank.eraseOnQuit = true
        let savedBlank = HelperEditorPolicy.saveConfig(draft: blank)
        XCTAssertNil(savedBlank.languageCode)
        XCTAssertNil(savedBlank.newWindowCommand)
        XCTAssertTrue(savedBlank.eraseOnQuit)

        var web = makeWebConfig()
        web.languageCode = " fr "
        web.eraseOnQuit = true
        XCTAssertEqual(HelperEditorPolicy.saveConfig(draft: web), web)
    }

    func testNewWindowNoteSaysWhyTheItemIsHidden() {
        var config = appConfig()
        XCTAssertNil(HelperEditorPolicy.newWindowNote(for: config, home: home))
        config.menuBarIcon = true
        XCTAssertEqual(HelperEditorPolicy.newWindowNote(for: config, home: home), "New Window is hidden until you enter a command.")
        config.newWindowCommand = "  "
        XCTAssertEqual(HelperEditorPolicy.newWindowNote(for: config, home: home), "New Window is hidden until you enter a command.")
        config.newWindowCommand = "open -na {target}"
        XCTAssertNil(HelperEditorPolicy.newWindowNote(for: config, home: home))
        config.menuBarIcon = false
        XCTAssertEqual(HelperEditorPolicy.newWindowNote(for: config, home: home), "New Window appears only while Menu bar icon is on.")

        var dataTemplate = appConfig(dataMode: .disabled)
        dataTemplate.menuBarIcon = true
        dataTemplate.newWindowCommand = "/usr/bin/touch {dataPath}/marker"
        XCTAssertEqual(
            HelperEditorPolicy.newWindowNote(for: dataTemplate, home: home),
            "New Window stays hidden: the command uses {dataPath} and the shortcut has no data folder."
        )
        dataTemplate.dataMode = .auto
        XCTAssertNil(HelperEditorPolicy.newWindowNote(for: dataTemplate, home: home), "Auto fills in the default folder")

        var web = makeWebConfig()
        web.menuBarIcon = true
        XCTAssertNil(HelperEditorPolicy.newWindowNote(for: web, home: home))
    }

    func testHelperLineListsWhatTheHelperDoes() {
        var config = appConfig()
        XCTAssertNil(HelperEditorPolicy.helperLine(for: config, home: home))
        config.newWindowCommand = "open -na {target}"
        XCTAssertNil(HelperEditorPolicy.helperLine(for: config, home: home), "a New Window command alone starts no helper")
        config.menuBarIcon = true
        XCTAssertEqual(HelperEditorPolicy.helperLine(for: config, home: home), "Menu bar icon · New Window")
        config.eraseOnQuit = true
        XCTAssertEqual(HelperEditorPolicy.helperLine(for: config, home: home), "Menu bar icon · New Window · Erase on quit")
        config.menuBarIcon = false
        XCTAssertEqual(HelperEditorPolicy.helperLine(for: config, home: home), "Erase on quit")
        config.dataMode = .disabled
        XCTAssertNil(HelperEditorPolicy.helperLine(for: config, home: home))

        var iconOnly = appConfig()
        iconOnly.menuBarIcon = true
        XCTAssertEqual(HelperEditorPolicy.helperLine(for: iconOnly, home: home), "Menu bar icon")

        var web = makeWebConfig()
        web.menuBarIcon = true
        web.eraseOnQuit = true
        XCTAssertNil(HelperEditorPolicy.helperLine(for: web, home: home))
    }

    func testNewWindowTextShowsTheMaskedCommandOrWhyItIsHidden() {
        var config = appConfig()
        XCTAssertEqual(HelperEditorPolicy.newWindowText(for: config, home: home), "None")
        config.newWindowCommand = "   "
        XCTAssertEqual(HelperEditorPolicy.newWindowText(for: config, home: home), "None")
        config.newWindowCommand = "open -na {target} --args --api-key hunter2"
        config.menuBarIcon = true
        let command = "/usr/bin/env open -na /Applications/Target.app --args --api-key \(SecretMasking.maskedValue)"
        XCTAssertEqual(HelperEditorPolicy.newWindowText(for: config, home: home), command)
        config.menuBarIcon = false
        XCTAssertEqual(HelperEditorPolicy.newWindowText(for: config, home: home), command + " (hidden: the menu bar icon is off)")

        var dataTemplate = appConfig()
        dataTemplate.menuBarIcon = true
        dataTemplate.newWindowCommand = "/usr/bin/touch {dataPath}/marker"
        let defaultPath = ShortcutConfig.defaultDataPath(forSlug: dataTemplate.slug, home: home)
        XCTAssertEqual(HelperEditorPolicy.newWindowText(for: dataTemplate, home: home), "/usr/bin/touch \(defaultPath)/marker")
        dataTemplate.dataMode = .disabled
        XCTAssertEqual(
            HelperEditorPolicy.newWindowText(for: dataTemplate, home: home),
            "Hidden (the command uses {dataPath} and the shortcut has no data folder)"
        )

        var web = makeWebConfig()
        web.newWindowCommand = "open -na {target}"
        XCTAssertEqual(HelperEditorPolicy.newWindowText(for: web, home: home), "None")
    }

    func testEraseTextSaysWhatHappensAtQuit() throws {
        var config = appConfig()
        XCTAssertEqual(HelperEditorPolicy.eraseText(for: config, home: home), "Off")
        config.eraseOnQuit = true
        let defaultPath = ShortcutConfig.defaultDataPath(forSlug: config.slug, home: home)
        XCTAssertEqual(HelperEditorPolicy.eraseText(for: config, home: home), "On: \(defaultPath)", "the first launch creates the default folder")
        let custom = try makeFolder("Projects/data")
        config.dataMode = .homeOverride
        config.dataPath = custom
        XCTAssertEqual(HelperEditorPolicy.eraseText(for: config, home: home), "On: \(custom)")
        config.dataPath = home.path
        XCTAssertEqual(HelperEditorPolicy.eraseText(for: config, home: home), "On, but the folder is never erased: the folder is the home folder")
        config.dataMode = .disabled
        XCTAssertEqual(HelperEditorPolicy.eraseText(for: config, home: home), "Off (no data folder to erase)")
    }

    func testLanguageTextAndDiagnosticsRows() {
        XCTAssertEqual(HelperEditorPolicy.languageText(nil), "System")
        XCTAssertEqual(HelperEditorPolicy.languageText("  "), "System")
        XCTAssertEqual(HelperEditorPolicy.languageText(" fr "), "fr")
        XCTAssertEqual(HelperEditorPolicy.languageText("french"), "french (not a valid language code)")

        XCTAssertEqual(HelperEditorPolicy.diagnosticsRows(for: appConfig(), home: home), [
            ProfileSummary.Row(label: "Menu bar icon", value: "Off"),
            ProfileSummary.Row(label: "Erase on quit", value: "Off"),
            ProfileSummary.Row(label: "New Window command", value: "None"),
            ProfileSummary.Row(label: "Language", value: "System"),
        ])
        XCTAssertEqual(HelperEditorPolicy.diagnosticsRows(for: makeWebConfig(), home: home), [])
        XCTAssertEqual(HelperEditorPolicy.diagnosticsRows(for: makeConfig(kind: .cli), home: home), [])
    }
}
```

- [ ] **Step 2: Run the policy tests and watch them fail to compile.**

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/HelperEditorPolicyTests 2>&1 | grep -E "error: cannot find 'HelperEditorPolicy' in scope|\*\* TEST" | sort -u | head -3`
Expected: a line ending `error: cannot find 'HelperEditorPolicy' in scope`, then `** TEST FAILED **`.

- [ ] **Step 3: Write `App/Sources/Services/HelperEditorPolicy.swift`.**

```swift
import DuplicatorCore
import Foundation

/// The editor's, the launch plan preview's and Diagnostics' decisions about the spec §4.6 helper of an application
/// shortcut: whether the menu bar icon, New Window and Erase on quit controls apply, when turning Erase on quit on needs
/// the spec §4.3 destructive confirmation, which text fields block Save, and how the helper settings read. No SwiftUI
/// and no writes; the erase checks read the file system the way the helper does at quit (`EraseOnQuitPolicy`: `lstat`
/// and `realpath`; `CanonicalPath`: `realpath`).
nonisolated enum HelperEditorPolicy {
    /// What turning Erase on quit on needs for a data folder.
    enum EraseCheck: Equatable {
        /// The folder is inside App Duplicator's data folder: the toggle turns on at once.
        case allowed
        /// A custom folder the helper would empty: the toggle turns on only after the destructive confirmation.
        case needsConfirmation(dataPath: String)
        /// The toggle stays off; the message says why.
        case refused(String)
    }

    /// Shown instead of the helper controls for web app, file, folder and command shortcuts.
    static let unavailableCaption = "The menu bar icon, New Window and Erase on quit apply to application shortcuts only."
    /// Why Erase on quit stays off while data separation is disabled or no folder is set.
    static let disabledDataMessage = "Erase on quit needs a data folder: set Data to Auto or HOME override."
    /// Title of the destructive confirmation for a custom folder.
    static let eraseConfirmationTitle = "Erase this folder on quit?"
    /// The confirmation's destructive button (`ButtonRole.destructive`).
    static let eraseConfirmButton = "Erase on Quit"
    /// Placeholder of the New Window command field.
    static let newWindowPrompt = "open -na {target}"
    /// Help text under the New Window command field.
    static let newWindowHelp = "Runs when you choose New Window in the menu bar icon's menu. {target} is the app's path, {bundleId} its bundle identifier and {dataPath} the shortcut's data folder. Split on spaces; never run by a shell."

    /// The menu bar icon, New Window and Erase on quit exist for application shortcuts only: WebShell owns the status
    /// item of web apps, and file, folder and command shortcuts leave no process behind.
    static func helperControlsVisible(kind: ShortcutKind) -> Bool {
        kind == .app
    }

    /// True when `dataPath` is an absolute path strictly inside `<home>/Library/Application Support/App Duplicator`
    /// once symbolic links are resolved: the only place where spec §4.3 lets Erase on quit turn on without the
    /// confirmation. The data root itself is not inside it.
    static func canEnableEraseWithoutConfirm(dataPath: String, home: URL) -> Bool {
        dataPath.hasPrefix("/") && CanonicalPath(dataPath).isInside(CanonicalPath(ShortcutConfig.dataRoot(home: home).path))
    }

    /// The helper's own reason for never emptying `dataPath` (`EraseOnQuitPolicy.check`), or nil when it would. A folder
    /// that does not exist yet is not refused here: the shortcut's first launch creates it and the helper checks it
    /// again at every quit.
    static func eraseRefusalReason(dataPath: String, home: URL) -> String? {
        switch EraseOnQuitPolicy.check(dataPath: dataPath, home: home) {
        case .success, .failure(.missing):
            return nil
        case .failure(let refusal):
            return refusal.logReason
        }
    }

    /// What turning Erase on quit on needs for the data folder `dataPath` under `dataMode`.
    static func eraseCheck(dataPath: String?, dataMode: DataMode, home: URL) -> EraseCheck {
        guard dataMode != .disabled, let dataPath, !dataPath.isEmpty else {
            return .refused(disabledDataMessage)
        }
        if let reason = eraseRefusalReason(dataPath: dataPath, home: home) {
            return .refused("Erase on quit never empties this folder: \(reason).")
        }
        return canEnableEraseWithoutConfirm(dataPath: dataPath, home: home) ? .allowed : .needsConfirmation(dataPath: dataPath)
    }

    /// `eraseCheck(dataPath:dataMode:home:)` for the folder `config` uses: its `dataPath`, else its default folder.
    static func eraseCheck(for config: ShortcutConfig, home: URL) -> EraseCheck {
        eraseCheck(dataPath: config.effectiveDataPath(home: home), dataMode: config.dataMode, home: home)
    }

    /// Message of the destructive confirmation for a custom folder.
    static func eraseConfirmationMessage(name: String, dataPath: String) -> String {
        "Every time \(name) quits, everything inside \(dataPath) is deleted permanently. It is not moved to the Trash. This folder is outside App Duplicator's data folder."
    }

    /// Why the New Window command cannot be saved, or nil.
    static func newWindowValidation(_ template: String?) -> String? {
        NewWindowCommandBuilder.validationMessage(for: template)
    }

    /// Why the language code cannot be saved, or nil (a blank field means no override).
    static func languageValidation(_ code: String?) -> String? {
        LanguageCode.validationMessage(for: code)
    }

    /// The first helper-related reason Save stays disabled for an application shortcut draft, or nil. Other kinds hide
    /// these fields, so they never block Save.
    static func validationMessage(for draft: ShortcutConfig) -> String? {
        guard draft.kind == .app else { return nil }
        return languageValidation(draft.languageCode) ?? newWindowValidation(draft.newWindowCommand)
    }

    /// The draft as saved: the language code and the New Window command trimmed (blank becomes nil), and Erase on quit
    /// turned off while data separation is disabled, where it could never run. Other kinds are returned unchanged.
    static func saveConfig(draft: ShortcutConfig) -> ShortcutConfig {
        guard draft.kind == .app else { return draft }
        var config = draft
        config.languageCode = trimmedOrNil(draft.languageCode)
        config.newWindowCommand = trimmedOrNil(draft.newWindowCommand)
        if config.dataMode == .disabled {
            config.eraseOnQuit = false
        }
        return config
    }

    /// Why the New Window item will not appear in the menu, or nil when it will or when neither setting is used.
    static func newWindowNote(for config: ShortcutConfig, home: URL) -> String? {
        guard config.kind == .app else { return nil }
        let hasTemplate = trimmedOrNil(config.newWindowCommand) != nil
        switch (config.menuBarIcon, hasTemplate) {
        case (true, false):
            return "New Window is hidden until you enter a command."
        case (false, true):
            return "New Window appears only while Menu bar icon is on."
        case (false, false):
            return nil
        case (true, true):
            let resolved = config.resolvingDefaultDataPath(home: home)
            guard HelperPlan.newWindowArguments(for: resolved, targetPath: resolved.targetPath) == nil else { return nil }
            return "New Window stays hidden: the command uses {dataPath} and the shortcut has no data folder."
        }
    }

    /// The launch plan preview's helper line, `Menu bar icon · New Window · Erase on quit` or the part that applies;
    /// nil when the shortcut starts no helper.
    static func helperLine(for config: ShortcutConfig, home: URL) -> String? {
        let resolved = config.resolvingDefaultDataPath(home: home)
        guard HelperPlan.isNeeded(for: resolved) else { return nil }
        var items: [String] = []
        if HelperPlan.showsMenuBarIcon(for: resolved) {
            items.append("Menu bar icon")
            if HelperPlan.newWindowArguments(for: resolved, targetPath: resolved.targetPath) != nil {
                items.append(HelperMenuText.newWindow)
            }
        }
        if HelperPlan.eraseDataPath(for: resolved) != nil {
            items.append("Erase on quit")
        }
        return items.joined(separator: " · ")
    }

    /// Diagnostics value of the New Window command: the argv the helper runs, masked, or why there is none.
    static func newWindowText(for config: ShortcutConfig, home: URL) -> String {
        guard config.kind == .app, trimmedOrNil(config.newWindowCommand) != nil else { return "None" }
        let resolved = config.resolvingDefaultDataPath(home: home)
        guard let argv = HelperPlan.newWindowArguments(for: resolved, targetPath: resolved.targetPath) else {
            return "Hidden (the command uses {dataPath} and the shortcut has no data folder)"
        }
        let command = SecretMasking.maskArguments(argv).joined(separator: " ")
        return config.menuBarIcon ? command : command + " (hidden: the menu bar icon is off)"
    }

    /// Diagnostics value of Erase on quit: off, on with its folder, or on but refused by the helper's guard.
    static func eraseText(for config: ShortcutConfig, home: URL) -> String {
        guard config.eraseOnQuit else { return "Off" }
        guard let dataPath = HelperPlan.eraseDataPath(for: config.resolvingDefaultDataPath(home: home)) else {
            return "Off (no data folder to erase)"
        }
        if let reason = eraseRefusalReason(dataPath: dataPath, home: home) {
            return "On, but the folder is never erased: \(reason)"
        }
        return "On: \(dataPath)"
    }

    /// Diagnostics value of the spec §4.5 language override.
    static func languageText(_ code: String?) -> String {
        guard let trimmed = trimmedOrNil(code) else { return "System" }
        return LanguageCode.isValid(trimmed) ? trimmed : "\(trimmed) (not a valid language code)"
    }

    /// Diagnostics rows of an application shortcut, in this order: Menu bar icon, Erase on quit, New Window command,
    /// Language. Empty for every other kind.
    static func diagnosticsRows(for config: ShortcutConfig, home: URL) -> [ProfileSummary.Row] {
        guard config.kind == .app else { return [] }
        return [
            ProfileSummary.Row(label: "Menu bar icon", value: config.menuBarIcon ? "On" : "Off"),
            ProfileSummary.Row(label: "Erase on quit", value: eraseText(for: config, home: home)),
            ProfileSummary.Row(label: "New Window command", value: newWindowText(for: config, home: home)),
            ProfileSummary.Row(label: "Language", value: languageText(config.languageCode)),
        ]
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
```

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/HelperEditorPolicyTests 2>&1 | tail -3`
Expected: the last line is `** TEST SUCCEEDED **`.

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/HelperEditorPolicyTests 2>&1 | grep -cE "Test Case .* passed"`
Expected: `11`.

- [ ] **Step 4: Write the failing wizard, profile summary, preview and Diagnostics tests.**

In `App/Tests/Wizard/WizardModelTests.swift`, insert directly before the class's closing brace (line 211):

```swift

    func testProfileNewWindowCommandIsCopiedIntoTheShortcut() throws {
        let profile = AppProfile(name: "Target", status: .verified, family: .native, args: [], env: [:], newWindowCommand: "open -na {target}", notes: nil)
        let model = WizardModel(prefillTarget: target, profileLookup: { $0 == "com.example.target" ? profile : nil })
        XCTAssertEqual(model.newWindowCommand, "open -na {target}")
        XCTAssertEqual(model.makeConfig().newWindowCommand, "open -na {target}")

        let plain = try writeFakeTarget(named: "Plain", bundleIdentifier: "com.example.plain", version: "1.0", in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plain.appending(path: "Contents/MacOS/Plain").path)
        model.selectTarget(plain)
        XCTAssertNil(model.newWindowCommand, "a target without a profile has no New Window command")
        model.selectTarget(target)
        XCTAssertEqual(model.newWindowCommand, "open -na {target}")
        model.selectTarget(dir.appending(path: "Missing.app"))
        XCTAssertNil(model.newWindowCommand)
        XCTAssertNil(model.makeConfig().newWindowCommand)
    }

    func testInvalidProfileNewWindowCommandIsNotCopied() {
        let profile = AppProfile(name: "Target", status: .verified, family: .native, args: [], env: [:], newWindowCommand: "open\n-na {target}", notes: nil)
        let model = WizardModel(prefillTarget: target, profileLookup: { $0 == "com.example.target" ? profile : nil })
        XCTAssertNil(model.newWindowCommand, "the editor would refuse to save a command with a line break")
        XCTAssertNil(model.makeConfig().newWindowCommand)
    }
```

In `App/Tests/Services/ProfileSummaryTests.swift`, insert directly before the class's closing brace (the file's last line):

```swift

    func testNewWindowRowIsMaskedAndOnlyShownWhenPresent() throws {
        let profile = AppProfile(
            name: "Target", status: .verified, family: .native, args: [], env: [:],
            newWindowCommand: "open -na {target} --args --api-key hunter2", notes: "Sign in once."
        )
        let rows = ProfileSummary.rows(for: profile, detectedFamily: .native)
        let newWindow = try XCTUnwrap(rows.first { $0.label == "New Window" })
        XCTAssertEqual(newWindow.value, "open -na {target} --args --api-key \(SecretMasking.maskedValue)")
        let labels = rows.map(\.label)
        let environmentIndex = try XCTUnwrap(labels.firstIndex(of: "Environment"))
        let newWindowIndex = try XCTUnwrap(labels.firstIndex(of: "New Window"))
        let notesIndex = try XCTUnwrap(labels.firstIndex(of: "Notes"))
        XCTAssertEqual(newWindowIndex, environmentIndex + 1)
        XCTAssertEqual(notesIndex, newWindowIndex + 1)

        for template in [nil, "", "   "] as [String?] {
            let plain = AppProfile(name: "Target", status: .verified, family: .native, args: [], env: [:], newWindowCommand: template, notes: nil)
            XCTAssertFalse(
                ProfileSummary.rows(for: plain, detectedFamily: .native).contains { $0.label == "New Window" },
                String(describing: template)
            )
        }
    }
```

In `App/Tests/Services/LaunchPlanPreviewTests.swift`, insert directly before the class's closing brace (the file's last line):

```swift

    func testPreviewHelperLineListsTheHelperFeatures() throws {
        let home = dir.appending(path: "home", directoryHint: .isDirectory)
        var config = makeConfig(targetPath: dir.appending(path: "Target.app").path)
        config.menuBarIcon = true
        config.newWindowCommand = "open -na {target}"
        XCTAssertEqual(try LaunchPlanPreview.make(config: config, bundleURL: nil, home: home).helper, "Menu bar icon · New Window")
        config.eraseOnQuit = true
        config.dataMode = .homeOverride
        let data = dir.appending(path: "Data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        config.dataPath = data.path
        XCTAssertEqual(
            try LaunchPlanPreview.make(config: config, bundleURL: nil, home: home).helper,
            "Menu bar icon · New Window · Erase on quit"
        )
    }

    func testPreviewHasNoHelperLineByDefault() throws {
        var config = makeConfig(targetPath: dir.appending(path: "Target.app").path)
        config.menuBarIcon = false
        config.eraseOnQuit = false
        XCTAssertNil(try LaunchPlanPreview.make(config: config, bundleURL: nil).helper)
    }
```

In `App/Tests/App/DiagnosticsModelTests.swift`, insert directly before the class's closing brace (the file's last line):

```swift

    func testNativeShortcutShowsHelperRows() throws {
        let target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "1.0", in: dir)
        try FileManager.default.removeItem(at: target.appending(path: "Contents/MacOS/Target"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: target.appending(path: "Contents/MacOS/Target"))
        let data = dir.appending(path: "Data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertFalse(CanonicalPath(data.path).isInside(CanonicalPath(realHome.path)), "the test folder must lie outside the home folder")
        var config = makeConfig(name: "Target Work", targetPath: target.path)
        config.dataMode = .homeOverride
        config.dataPath = data.path
        config.menuBarIcon = true
        config.eraseOnQuit = true
        config.newWindowCommand = "open -na {target} --args --api-key hunter2"
        config.languageCode = "fr"
        let bundle = try writeShortcutBundle(named: "Target Work", in: dir, config: config)
        let record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))

        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: dir))

        XCTAssertNil(model.planError)
        let targetPath = try XCTUnwrap(model.resolvedTargetPath)
        XCTAssertEqual(model.helperRows, [
            ProfileSummary.Row(label: "Menu bar icon", value: "On"),
            ProfileSummary.Row(label: "Erase on quit", value: "On, but the folder is never erased: the folder is outside the home folder"),
            ProfileSummary.Row(label: "New Window command", value: "/usr/bin/env open -na \(targetPath) --args --api-key \(SecretMasking.maskedValue)"),
            ProfileSummary.Row(label: "Language", value: "fr"),
        ])
        for row in model.helperRows {
            XCTAssertTrue(model.reportText.contains("\(row.label): \(row.value)"), row.label)
        }
        XCTAssertFalse(model.reportText.contains("hunter2"))
    }

    func testHelperRowsSurviveAPlanError() throws {
        let missing = dir.appending(path: "Missing.app").path
        var config = makeConfig(name: "Target Work", targetPath: missing, targetBundleIdentifier: "com.example.unregistered-\(UUID().uuidString)")
        config.menuBarIcon = true
        config.eraseOnQuit = false
        config.languageCode = nil
        config.newWindowCommand = "open -na {target}"
        let bundle = try writeShortcutBundle(named: "Target Work", in: dir, config: config)
        let record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))

        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: dir))

        XCTAssertNotNil(model.planError)
        XCTAssertEqual(model.helperRows, [
            ProfileSummary.Row(label: "Menu bar icon", value: "On"),
            ProfileSummary.Row(label: "Erase on quit", value: "Off"),
            ProfileSummary.Row(label: "New Window command", value: "/usr/bin/env open -na \(missing)"),
            ProfileSummary.Row(label: "Language", value: "System"),
        ])
        XCTAssertTrue(model.reportText.contains("Menu bar icon: On"))
    }
```

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/WizardModelTests -only-testing:MacAppDuplicatorTests/ProfileSummaryTests -only-testing:MacAppDuplicatorTests/LaunchPlanPreviewTests -only-testing:MacAppDuplicatorTests/DiagnosticsModelTests 2>&1 | grep -E "has no member '(newWindowCommand|helper|helperRows)'|\*\* TEST" | sed -E 's/^.*error: //' | sort -u`
Expected (compile failure; the profile summary test compiles and would fail at run time):
```
** TEST FAILED **
value of type 'DiagnosticsModel' has no member 'helperRows'
value of type 'LaunchPlanPreview' has no member 'helper'
value of type 'WizardModel' has no member 'newWindowCommand'
```

- [ ] **Step 5: Copy the profile template in the wizard.**

In `App/Sources/Views/Wizard/WizardModel.swift`, replace:

```swift
    /// The profile's `args` and `env`, copied into the new shortcut by `makeConfig()` as editable defaults; replaced
    /// whenever the target changes.
    private(set) var arguments: [String] = []
    private(set) var environment: [String: String] = [:]
```

with:

```swift
    /// The profile's `args`, `env` and `newWindowCommand`, copied into the new shortcut by `makeConfig()` as editable
    /// defaults; replaced whenever the target changes. A template `NewWindowCommandBuilder.validationMessage(for:)`
    /// rejects is not copied, so a new shortcut never starts with a command its editor would refuse to save.
    private(set) var arguments: [String] = []
    private(set) var environment: [String: String] = [:]
    private(set) var newWindowCommand: String?
```

Replace both occurrences (the refusal branch and the `catch` branch of `selectTarget`) of:

```swift
            profile = nil
            arguments = []
            environment = [:]
```

with:

```swift
            profile = nil
            arguments = []
            environment = [:]
            newWindowCommand = nil
```

Replace:

```swift
            profile = profileLookup(app.bundleIdentifier)
            arguments = profile?.args ?? []
            environment = profile?.env ?? [:]
```

with:

```swift
            profile = profileLookup(app.bundleIdentifier)
            arguments = profile?.args ?? []
            environment = profile?.env ?? [:]
            if let template = profile?.newWindowCommand, NewWindowCommandBuilder.validationMessage(for: template) == nil {
                newWindowCommand = template
            } else {
                newWindowCommand = nil
            }
```

In `makeConfig()`, replace:

```swift
            environment: environment,
            arguments: arguments,
            iconMode: iconMode,
```

with:

```swift
            environment: environment,
            arguments: arguments,
            newWindowCommand: newWindowCommand,
            iconMode: iconMode,
```

(`ShortcutConfig.init` takes `newWindowCommand:` after `menuBarIcon:` and before `iconMode:` since Task 1; `makeConfig()` leaves `menuBarIcon` at its default, so the wizard never starts a helper: the menu bar icon and Erase on quit are editor settings.)

- [ ] **Step 6: Add the New Window row to the profile summary.**

In `App/Sources/Services/ProfileSummary.swift`, replace:

```swift
    /// `Name`, `Status`, `Family` (when the profile names one), `Arguments` and `Environment` (masked, `None` when
    /// empty), `Notes` (when the profile has any) and `Family note` (see `familyNote`). Empty without a profile.
```

with:

```swift
    /// `Name`, `Status`, `Family` (when the profile names one), `Arguments` and `Environment` (masked, `None` when
    /// empty), `New Window` (the masked template, when the profile has one), `Notes` (when the profile has any) and
    /// `Family note` (see `familyNote`). Empty without a profile.
```

Replace:

```swift
                        value: environment.isEmpty ? "None" : environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }.joined(separator: " ")))
        if let notes = profile.notes, !notes.isEmpty {
```

with:

```swift
                        value: environment.isEmpty ? "None" : environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }.joined(separator: " ")))
        if let template = profile.newWindowCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !template.isEmpty {
            let tokens = template.split(whereSeparator: \.isWhitespace).map(String.init)
            rows.append(Row(label: "New Window", value: SecretMasking.maskArguments(tokens).joined(separator: " ")))
        }
        if let notes = profile.notes, !notes.isEmpty {
```

- [ ] **Step 7: Add the helper line to the launch plan preview.**

In `App/Sources/Services/LaunchPlanPreview.swift`, replace:

```swift
    /// The family AppInspector detected for the target, the one the planner used (`.native` for launcher kinds).
    var family: AppFamily
```

with:

```swift
    /// The family AppInspector detected for the target, the one the planner used (`.native` for launcher kinds).
    var family: AppFamily
    /// What the spec §4.6 helper does for an application shortcut, `Menu bar icon · New Window · Erase on quit` or the
    /// part that applies (`HelperEditorPolicy.helperLine(for:home:)`); nil when no helper starts and for other kinds.
    var helper: String?
```

Replace:

```swift
            launchMode: plan.launchMode,
            family: app.family
        )
```

with:

```swift
            launchMode: plan.launchMode,
            family: app.family,
            helper: HelperEditorPolicy.helperLine(for: config, home: home)
        )
```

(`makeItem` and `makeCommand` keep their memberwise calls; the synthesized initializer defaults the optional `helper` to nil.)

- [ ] **Step 8: Add the helper rows to `DiagnosticsModel`.**

In `App/Sources/Views/DiagnosticsView.swift`, replace:

```swift
    /// Set for a file, folder or command shortcut (Phase 5); nil for every other kind. Defaulted like `web`.
    var launcher: LauncherDetails?
```

with:

```swift
    /// Set for a file, folder or command shortcut (Phase 5); nil for every other kind. Defaulted like `web`.
    var launcher: LauncherDetails?
    /// The helper settings of an application shortcut (`HelperEditorPolicy.diagnosticsRows(for:home:)`): Menu bar icon,
    /// Erase on quit, New Window command and Language. Empty for every other kind. Defaulted like `web`.
    var helperRows: [ProfileSummary.Row] = []
```

In `make(record:logReader:profileCatalog:)`, replace:

```swift
                logLines: logLines,
                planError: nil
            )
        } catch {
```

with:

```swift
                logLines: logLines,
                planError: nil,
                helperRows: HelperEditorPolicy.diagnosticsRows(for: config, home: FileManager.default.homeDirectoryForCurrentUser)
            )
        } catch {
```

(`config` there is the `var config` of line 75, `record.config.resolvingDefaultDataPath(home:)`, whose `targetPath` the success path has set to the resolved target; `helperRows` follows `planError`, `web` and `launcher` in declaration order, so skipping the two defaulted fields keeps the memberwise call valid.)

Replace the whole `failed` function:

```swift
    private static func failed(
        record: ShortcutRecord, resolvedTargetPath: String?, logLines: [String], profileMatch: String, profile: AppProfile?, error: Error
    ) -> DiagnosticsModel {
        DiagnosticsModel(
            shortcutName: record.name,
            bundlePath: record.bundleURL.path,
            engineVersion: record.engineVersion,
            profileMatch: profileMatch,
            profileRows: ProfileSummary.rows(for: profile, detectedFamily: nil),
            storedTargetPath: record.config.targetPath,
            resolvedTargetPath: resolvedTargetPath,
            executablePath: "",
            launchMode: record.config.launchMode == .systemLaunch ? "System Launch" : "Dock Shortcut",
            arguments: [],
            environment: [],
            warnings: [],
            logLines: logLines,
            planError: error.localizedDescription
        )
    }
```

with:

```swift
    private static func failed(
        record: ShortcutRecord, resolvedTargetPath: String?, logLines: [String], profileMatch: String, profile: AppProfile?, error: Error
    ) -> DiagnosticsModel {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var config = record.config.resolvingDefaultDataPath(home: home)
        config.targetPath = resolvedTargetPath ?? record.config.targetPath
        return DiagnosticsModel(
            shortcutName: record.name,
            bundlePath: record.bundleURL.path,
            engineVersion: record.engineVersion,
            profileMatch: profileMatch,
            profileRows: ProfileSummary.rows(for: profile, detectedFamily: nil),
            storedTargetPath: record.config.targetPath,
            resolvedTargetPath: resolvedTargetPath,
            executablePath: "",
            launchMode: record.config.launchMode == .systemLaunch ? "System Launch" : "Dock Shortcut",
            arguments: [],
            environment: [],
            warnings: [],
            logLines: logLines,
            planError: error.localizedDescription,
            helperRows: HelperEditorPolicy.diagnosticsRows(for: config, home: home)
        )
    }
```

In `reportText`, replace:

```swift
            lines.append("Target: \(resolvedTargetPath ?? "not found")")
            if storedPathDiffers {
                lines.append("Stored target path: \(storedTargetPath)")
            }
        }
        if let planError {
```

with:

```swift
            lines.append("Target: \(resolvedTargetPath ?? "not found")")
            if storedPathDiffers {
                lines.append("Stored target path: \(storedTargetPath)")
            }
            lines.append(contentsOf: helperRows.map { "\($0.label): \($0.value)" })
        }
        if let planError {
```

- [ ] **Step 9: Update the profile field's doc comment.**

In `Packages/CompatProfiles/Sources/CompatProfiles/ProfilesDocument.swift`, replace:

```swift
    /// Stored but inert until Phase 6.
    public var newWindowCommand: String?
```

with:

```swift
    /// Copied into `ShortcutConfig.newWindowCommand` when the wizard creates a shortcut; the helper's New Window menu
    /// item runs it through `NewWindowCommandBuilder`.
    public var newWindowCommand: String?
```

- [ ] **Step 10: Run everything this task touches.**

Run: `cd ~/Developer/MacAppDuplicator && swift build 2>&1 | tail -1`
Expected: `Build complete!`

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter CompatProfilesTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: `Executed 37 tests, with 0 failures (0 unexpected) in …`

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh 2>&1 | tail -3`
Expected: the last line is `** TEST SUCCEEDED **`.

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh 2>&1 | grep -cE "Test Case .* passed"`
Expected: `360` (342 + 11 policy + 2 wizard + 1 profile summary + 2 preview + 2 Diagnostics).

- [ ] **Step 11: Forbidden constructs.**

Run: `cd ~/Developer/MacAppDuplicator && grep -nE 'try\?|@unchecked|swiftlint:disable|nonisolated\(unsafe\)' App/Sources/Services/{HelperEditorPolicy,ProfileSummary,LaunchPlanPreview}.swift App/Sources/Views/Wizard/WizardModel.swift App/Sources/Views/DiagnosticsView.swift App/Tests/Services/{HelperEditorPolicyTests,ProfileSummaryTests,LaunchPlanPreviewTests}.swift App/Tests/Wizard/WizardModelTests.swift App/Tests/App/DiagnosticsModelTests.swift Packages/CompatProfiles/Sources/CompatProfiles/ProfilesDocument.swift`
Expected: no output (none of these files had a hit before this task).

- [ ] **Step 12: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add App/Sources/Services/HelperEditorPolicy.swift App/Tests/Services/HelperEditorPolicyTests.swift App/Sources/Views/Wizard/WizardModel.swift App/Sources/Services/ProfileSummary.swift App/Sources/Services/LaunchPlanPreview.swift App/Sources/Views/DiagnosticsView.swift Packages/CompatProfiles/Sources/CompatProfiles/ProfilesDocument.swift App/Tests/Wizard/WizardModelTests.swift App/Tests/Services/ProfileSummaryTests.swift App/Tests/Services/LaunchPlanPreviewTests.swift App/Tests/App/DiagnosticsModelTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "App: helper editor policy, New Window copy, helper rows" -m "HelperEditorPolicy holds the helper decisions the editor, the launch plan preview and Diagnostics share: the helper controls apply to application shortcuts only; Erase on quit turns on at once inside App Duplicator's data folder, needs a destructive confirmation for any other folder and stays off for a folder the helper's EraseOnQuitPolicy would refuse or while data separation is disabled; an invalid language code or New Window command blocks Save. The wizard copies the profile's New Window command with its arguments and environment. The profile summary shows the masked template, the launch plan preview names what the helper does, and Diagnostics shows Menu bar icon, Erase on quit, New Window command and Language rows, also after a launch plan error." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Deviations

- The brief calls `HelperEditorPolicy` pure. It has no SwiftUI, no state and no writes, but its erase checks read the file system (`lstat` and `realpath` through `EraseOnQuitPolicy.check` and `CanonicalPath`), because the editor must refuse exactly what the helper will refuse at quit. Its tests build every folder and symbolic link inside the per-test temp folder and pass that folder as `home`.
- Beyond the brief's three named functions, the policy also owns `eraseCheck`, `eraseRefusalReason`, `validationMessage(for:)`, `saveConfig(draft:)`, `newWindowNote`, `helperLine`, `newWindowText`, `eraseText`, `languageText` and `diagnosticsRows`, so the editor, the preview and Diagnostics word the helper the same way from one tested place. `newWindowValidation` takes the template (`(_ template: String?) -> String?`), as the brief names it without a signature.
- A data folder that does not exist yet is not refused by the editor: `EraseOnQuitPolicy.check` returns `.missing` before its location rules, and `checkShape` is internal to Core. A missing default folder (the usual case before the first launch) turns on without confirmation; a missing custom folder asks for the confirmation, and if it then appears somewhere the guard refuses (for example directly inside the home folder), the helper logs `helper erase skipped: …` at quit and Diagnostics shows `On, but the folder is never erased: …`.
- The wizard copies a profile's template only when `NewWindowCommandBuilder.validationMessage(for:)` accepts it (the profiles schema allows line breaks, the editor does not), and it never turns on the menu bar icon or Erase on quit, so a wizard-made shortcut starts no helper and its preview shows no helper line until the editor turns one on.
- Diagnostics shows the helper rows on the native path and after a plan error (`failed`), not for web apps or launcher kinds (`diagnosticsRows` is empty there).

---

### Task 8: App views: Erase on quit with the destructive confirmation, menu bar icon and New Window command, language validation, Save gating, wizard and Diagnostics rows

**Files:**
- Modify: `App/Sources/Views/EditorSections.swift` (`ProfileSection` footer, line 120; `LaunchSection`, lines 126-211; `AdvancedSection`, lines 213-228), `App/Sources/Views/ShortcutEditorView.swift` (`revertCount` doc comment, line 22; `LaunchSection` call, line 55; Save `.disabled(`, lines 94-97; `save()`, line 148), `App/Sources/Views/Wizard/WizardSteps.swift` (profile defaults caption, line 286; launch plan rows, line 297), `App/Sources/Views/DiagnosticsView.swift` (the view's native rows, lines 323-328).
- Test: none new. These are SwiftUI views without a view test harness in this repo; every decision they show comes from `HelperEditorPolicy` (Task 7 tests), and Mike checks the views by hand in `docs/acceptance/phase6-helper.md` (Task 10). The whole App suite must stay green at 360.

**Interfaces:**
- Consumes: everything `HelperEditorPolicy` produces (Task 7): `helperControlsVisible(kind:)`, `eraseCheck(for:home:)`, `eraseCheck(dataPath:dataMode:home:)`, `EraseCheck`, `eraseConfirmationTitle`, `eraseConfirmButton`, `eraseConfirmationMessage(name:dataPath:)`, `disabledDataMessage`, `unavailableCaption`, `newWindowPrompt`, `newWindowHelp`, `newWindowValidation(_:)`, `newWindowNote(for:home:)`, `languageValidation(_:)`, `validationMessage(for:)`, `saveConfig(draft:)`; `LaunchPlanPreview.helper`, `DiagnosticsModel.helperRows` (Task 7); `ProfileSummary.Row: Identifiable` (`id` is `label`); existing `AppState.validateDataPath(_:targetPath:excluding:targetBundleIdentifier:)`, `ShortcutConfig.defaultDataPath(forSlug:home:)`.
- Produces: no new types outside the views. `LaunchSection` gains the private `PendingErase` struct and the private functions `useDataPath(_:home:)`, `setEraseOnQuit(_:home:)` and `confirmErase(_:)`.

Placement follows spec §7: Erase on quit moves from `AdvancedSection` to `LaunchSection` ("Launch (… data mode, path, existing-profile picker, erase on quit)"), beside the data folder it empties, so the folder controls and the erase confirmation share one view's state; the menu bar icon and the New Window command stay in `AdvancedSection` ("Advanced (… menu bar icon + new-window command)").

- [ ] **Step 1: Give `LaunchSection` the Erase on quit state.**

In `App/Sources/Views/EditorSections.swift`, replace:

```swift
    let inspected: InspectedApp?
    @State private var dataFolderError: String?

    var body: some View {
        let defaultPath = ShortcutConfig.defaultDataPath(forSlug: draft.slug, home: FileManager.default.homeDirectoryForCurrentUser)
```

with:

```swift
    let inspected: InspectedApp?
    @State private var dataFolderError: String?
    /// A data folder waiting for the spec §4.3 destructive confirmation.
    @State private var pendingErase: PendingErase?
    /// Why Erase on quit stayed off or was turned off; cleared when the folder, the data mode or the toggle changes.
    @State private var eraseMessage: String?

    /// Erase on quit for a folder outside App Duplicator's data folder, waiting for the confirmation.
    private struct PendingErase {
        /// The folder the helper would empty after every quit.
        let dataPath: String
        /// True when the folder was chosen with Browse… while Erase on quit was on: confirming stores it and Cancel keeps
        /// the current folder. False when the toggle is being turned on for the current folder.
        let isNewFolder: Bool
    }

    var body: some View {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultPath = ShortcutConfig.defaultDataPath(forSlug: draft.slug, home: home)
```

- [ ] **Step 2: Turn Erase on quit off when data separation is disabled.**

Replace:

```swift
            Picker("Data", selection: $draft.dataMode) {
```

with:

```swift
            Picker("Data", selection: Binding(
                get: { draft.dataMode },
                set: { mode in
                    draft.dataMode = mode
                    // Erase on quit never runs without a data folder. Turning it off keeps the toggle truthful, and
                    // turning it on again later goes through `setEraseOnQuit`, confirmation included.
                    if mode == .disabled {
                        draft.eraseOnQuit = false
                    }
                    eraseMessage = nil
                }
            )) {
```

- [ ] **Step 3: Send the Default button through the erase recheck.**

Replace:

```swift
                        Button("Default") {
                            draft.dataPath = nil
                            dataFolderError = nil
                        }
```

with:

```swift
                        Button("Default") { useDataPath(nil, home: home) }
```

- [ ] **Step 4: Add the Erase on quit toggle and its confirmation below the data folder.**

Replace:

```swift
            .disabled(draft.dataMode == .disabled)
            if let dataFolderError {
                Label(dataFolderError, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            }
```

with:

```swift
            .disabled(draft.dataMode == .disabled)
            if let dataFolderError {
                Label(dataFolderError, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            }
            if HelperEditorPolicy.helperControlsVisible(kind: draft.kind) {
                Toggle("Erase on quit", isOn: Binding(
                    get: { draft.eraseOnQuit },
                    set: { setEraseOnQuit($0, home: home) }
                ))
                .disabled(draft.dataMode == .disabled)
                .help("Empties the data folder every time the app quits, so every launch starts clean and signed out.")
                .alert(
                    HelperEditorPolicy.eraseConfirmationTitle,
                    isPresented: Binding(get: { pendingErase != nil }, set: { if !$0 { pendingErase = nil } }),
                    presenting: pendingErase
                ) { pending in
                    Button(HelperEditorPolicy.eraseConfirmButton, role: .destructive) { confirmErase(pending) }
                    Button("Cancel", role: .cancel) {}
                } message: { pending in
                    Text(verbatim: HelperEditorPolicy.eraseConfirmationMessage(name: draft.name, dataPath: pending.dataPath))
                }
                if draft.dataMode == .disabled {
                    Label(HelperEditorPolicy.disabledDataMessage, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                } else if let eraseMessage {
                    Label(eraseMessage, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
                }
            }
```

- [ ] **Step 5: Show the language code's validation message.**

Replace:

```swift
            ), prompt: Text("en"))
            .help("Two-letter language code, blank for system")
        }
    }
```

with:

```swift
            ), prompt: Text("en"))
            .help("A language code like en, fr or pt-BR; blank follows the system language.")
            if let message = HelperEditorPolicy.languageValidation(draft.languageCode) {
                Label(message, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            }
        }
    }
```

- [ ] **Step 6: Recheck Erase on quit when a folder is chosen, and add the toggle's actions.**

Replace:

```swift
        case .success:
            draft.dataPath = url.path
            dataFolderError = nil
        case .failure(let error):
            dataFolderError = error.localizedDescription
        }
    }
}
```

with:

```swift
        case .success:
            useDataPath(url.path, home: FileManager.default.homeDirectoryForCurrentUser)
        case .failure(let error):
            dataFolderError = error.localizedDescription
        }
    }

    /// Stores a new data folder (nil: the default folder). While Erase on quit is on, the folder goes through the check
    /// that turning the toggle on uses: a folder inside App Duplicator's data folder is stored at once, any other folder
    /// waits for the confirmation (Cancel keeps the current folder), and a folder the helper would never empty is stored
    /// with Erase on quit turned off and the reason shown.
    private func useDataPath(_ path: String?, home: URL) {
        dataFolderError = nil
        eraseMessage = nil
        guard draft.eraseOnQuit else {
            draft.dataPath = path
            return
        }
        let candidate = path ?? ShortcutConfig.defaultDataPath(forSlug: draft.slug, home: home)
        switch HelperEditorPolicy.eraseCheck(dataPath: candidate, dataMode: draft.dataMode, home: home) {
        case .allowed:
            draft.dataPath = path
        case .needsConfirmation(let dataPath):
            pendingErase = PendingErase(dataPath: dataPath, isNewFolder: true)
        case .refused(let message):
            draft.dataPath = path
            draft.eraseOnQuit = false
            eraseMessage = message
        }
    }

    /// Turning the toggle off always works; turning it on follows `HelperEditorPolicy.eraseCheck(for:home:)`.
    private func setEraseOnQuit(_ isOn: Bool, home: URL) {
        eraseMessage = nil
        guard isOn else {
            draft.eraseOnQuit = false
            return
        }
        switch HelperEditorPolicy.eraseCheck(for: draft, home: home) {
        case .allowed:
            draft.eraseOnQuit = true
        case .needsConfirmation(let dataPath):
            pendingErase = PendingErase(dataPath: dataPath, isNewFolder: false)
        case .refused(let message):
            eraseMessage = message
        }
    }

    /// The confirmation's destructive button: turns Erase on quit on and, for a folder chosen with Browse…, stores it.
    private func confirmErase(_ pending: PendingErase) {
        if pending.isNewFolder {
            draft.dataPath = pending.dataPath
        }
        draft.eraseOnQuit = true
        eraseMessage = nil
    }
}
```

- [ ] **Step 7: Enable the menu bar icon and add the New Window command in `AdvancedSection`.**

Replace:

```swift
struct AdvancedSection: View {
```

with:

```swift
/// Arguments, environment, and the spec §4.6 helper's menu bar icon and New Window command (spec §7). Erase on quit
/// lives in `LaunchSection`, beside the data folder it empties.
struct AdvancedSection: View {
```

Replace:

```swift
            EnvironmentTableView(environment: $draft.environment)
            Toggle("Erase data on quit", isOn: $draft.eraseOnQuit).disabled(true).help("Coming in Phase 6")
            Toggle("Menu bar icon", isOn: $draft.menuBarIcon).disabled(true).help("Coming in Phase 6")
            // GC-22: the editor says inline that these settings are stored but inert until Phase 6.
            Text("Stored now; takes effect in Phase 6").font(.caption).foregroundStyle(.secondary)
        }
    }
}
```

with:

```swift
            EnvironmentTableView(environment: $draft.environment)
            if HelperEditorPolicy.helperControlsVisible(kind: draft.kind) {
                Toggle("Menu bar icon", isOn: $draft.menuBarIcon)
                    .help("Shows the app's icon in the menu bar while it runs, with Show, New Window and Quit.")
                TextField("New Window command", text: Binding(
                    get: { draft.newWindowCommand ?? "" },
                    set: { draft.newWindowCommand = $0.isEmpty ? nil : $0 }
                ), prompt: Text(verbatim: HelperEditorPolicy.newWindowPrompt))
                Text(verbatim: HelperEditorPolicy.newWindowHelp).font(.caption).foregroundStyle(.secondary)
                if let message = HelperEditorPolicy.newWindowValidation(draft.newWindowCommand) {
                    Label(message, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
                } else if let note = HelperEditorPolicy.newWindowNote(for: draft, home: FileManager.default.homeDirectoryForCurrentUser) {
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(verbatim: HelperEditorPolicy.unavailableCaption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 8: Name the New Window command in the profile footer.**

Replace:

```swift
            Text("A profile's arguments and environment are copied into a shortcut only when it is created; Check Profile Updates never changes an existing shortcut.")
```

with:

```swift
            Text("A profile's arguments, environment and New Window command are copied into a shortcut only when it is created; Check Profile Updates never changes an existing shortcut.")
```

- [ ] **Step 9: Gate Save on the helper fields and save the cleaned config.**

In `App/Sources/Views/ShortcutEditorView.swift`, replace:

```swift
    /// Bumped by Revert so the web section rebuilds its local text fields from the restored draft.
```

with:

```swift
    /// Bumped by Revert so the web, command and launch sections rebuild their local state (text fields, the folder and
    /// Erase on quit messages, a pending erase confirmation) from the restored draft.
```

Replace:

```swift
                LaunchSection(draft: $draft, record: record, inspected: inspected)
```

with:

```swift
                LaunchSection(draft: $draft, record: record, inspected: inspected).id(revertCount)
```

Replace:

```swift
                            || (isLauncher && LauncherEditorPolicy.validationMessage(for: draft) != nil)
                    )
```

with:

```swift
                            || (isLauncher && LauncherEditorPolicy.validationMessage(for: draft) != nil)
                            || HelperEditorPolicy.validationMessage(for: draft) != nil
                    )
```

Replace:

```swift
                config.bundleIdentifier = ShortcutConfig.bundleIdentifier(forSlug: config.slug)
            }
        }
        Task {
```

with:

```swift
                config.bundleIdentifier = ShortcutConfig.bundleIdentifier(forSlug: config.slug)
            }
            // Trims the language code and the New Window command, and drops an Erase on quit that could never run.
            config = HelperEditorPolicy.saveConfig(draft: config)
        }
        Task {
```

(`save()` already adopts the written config afterwards, `draft = saved.config`, so the trimmed values leave Save and Revert disabled. `HelperEditorPolicy.validationMessage(for:)` is nil for every kind but `.app`, so web app and launcher saves are unaffected.)

- [ ] **Step 10: Wizard caption and launch plan helper row.**

In `App/Sources/Views/Wizard/WizardSteps.swift`, replace:

```swift
                            Text("The profile's arguments and environment are copied into the new shortcut; change them in its Advanced section after it is created.")
```

with:

```swift
                            Text("The profile's arguments, environment and New Window command are copied into the new shortcut; change them in its Advanced section after it is created.")
```

Replace:

```swift
                            planRow("Environment additions", preview.environmentAdditions.keys.sorted().map { "\($0)=\(preview.environmentAdditions[$0] ?? "")" }.joined(separator: "\n"))
```

with:

```swift
                            planRow("Environment additions", preview.environmentAdditions.keys.sorted().map { "\($0)=\(preview.environmentAdditions[$0] ?? "")" }.joined(separator: "\n"))
                            if let helper = preview.helper {
                                planRow("Helper", helper)
                            }
```

- [ ] **Step 11: Diagnostics helper rows in the view.**

In `App/Sources/Views/DiagnosticsView.swift`, replace:

```swift
                                if model.storedPathDiffers {
                                    row("Stored path", model.storedTargetPath)
                                }
                            }
                            if let error = model.planError {
```

with:

```swift
                                if model.storedPathDiffers {
                                    row("Stored path", model.storedTargetPath)
                                }
                                ForEach(model.helperRows) { row($0.label, $0.value) }
                            }
                            if let error = model.planError {
```

- [ ] **Step 12: Build, test and check.**

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh 2>&1 | tail -3`
Expected: the last line is `** TEST SUCCEEDED **`.

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh 2>&1 | grep -cE "Test Case .* passed"`
Expected: `360` (no new tests in this task).

Run: `cd ~/Developer/MacAppDuplicator && grep -n "Phase 6\|Erase data on quit" App/Sources/Views/EditorSections.swift`
Expected: no output (the four "Phase 6" lines and the old toggle label are gone).

Run: `cd ~/Developer/MacAppDuplicator && grep -c "HelperEditorPolicy\." App/Sources/Views/EditorSections.swift App/Sources/Views/ShortcutEditorView.swift`
Expected: `App/Sources/Views/EditorSections.swift:15` and `App/Sources/Views/ShortcutEditorView.swift:2` (lines that mention the policy; a different count means a step was skipped or applied twice).

Run: `cd ~/Developer/MacAppDuplicator && grep -nE 'try\?|@unchecked|swiftlint:disable|nonisolated\(unsafe\)' App/Sources/Views/EditorSections.swift App/Sources/Views/ShortcutEditorView.swift App/Sources/Views/Wizard/WizardSteps.swift App/Sources/Views/DiagnosticsView.swift`
Expected: no output.

- [ ] **Step 13: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add App/Sources/Views/EditorSections.swift App/Sources/Views/ShortcutEditorView.swift App/Sources/Views/Wizard/WizardSteps.swift App/Sources/Views/DiagnosticsView.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "App: helper settings in the editor, wizard and Diagnostics" -m "Erase on quit moves to the Launch section beside the data folder (spec section 7) and turns on at once for a folder inside App Duplicator's data folder, after a destructive confirmation for any other folder, and never for a folder the helper would refuse or while data separation is disabled; choosing another folder while it is on goes through the same check. The Advanced section enables the menu bar icon and adds the New Window command field with its help, validation and a note when the item will stay hidden. An invalid language code or New Window command disables Save, and Save trims both. The wizard names the New Window command among the profile defaults and shows the helper line in the launch plan; Diagnostics shows the helper rows." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Deviations

- Erase on quit moves from `AdvancedSection` to `LaunchSection`. The brief says to touch `LaunchSection` "per spec §7 if the editor currently groups erase there (check)": the editor grouped it under Advanced, but spec §7 lists erase on quit under Launch, and the data folder recheck (Step 6) needs the folder controls and the confirmation in one view. Appearance and Language stay in `LaunchSection`, although spec §7 lists them under Advanced: moving them is unrelated to Phase 6 (flagged in the report).
- The caption for other kinds (`HelperEditorPolicy.unavailableCaption`) sits in `AdvancedSection`'s `else` branch. `ShortcutEditorView` shows `LaunchSection` and `AdvancedSection` only for application shortcuts (web apps get `WebAppSection`, which keeps WebShell's own Menu bar icon toggle; files, folders and commands get `FileSection` or `CommandSection`), so today the branch is a guard for any future kind routed there, and no other section changes.
- Switching Data to Disabled turns Erase on quit off in the draft instead of leaving an inert `true` for `saveConfig(draft:)` to drop. Switching back does not turn it on again: the user turns it on, through the confirmation when the folder is custom. This closes the path "erase on with the default folder, Disabled, back to HOME override with another stored folder" that would skip the confirmation.
- Cancel in the folder-change confirmation keeps the current folder with Erase on quit still on, so nothing destructive ever applies to a folder the user did not confirm; to use a custom folder without erasing it, the user turns Erase on quit off first. The confirmation text (Task 7) is the same for both cases.
- `LaunchSection` gets `.id(revertCount)` so Revert also clears its folder and erase messages and any pending confirmation (the existing `dataFolderError` used to survive a Revert).
- No new automated tests: no SwiftUI test harness exists in the app target, and the decisions are `HelperEditorPolicy`'s (Task 7). The wizard's launch plan never shows the Helper row today, because the wizard does not turn on the menu bar icon or Erase on quit (Task 7 Deviation 4); the row is wired for when it does.

### Task 9: Known limitations for the helper

**Files:**
- Modify: `App/Sources/App/KnownLimitations.swift` (doc comment, lines 9-13; six entries appended after `cli-ghostty-path`)
- Modify: `App/Tests/App/KnownLimitationsTests.swift` (doc comment at lines 92-93, the count at line 97, one new test before the class's closing brace)

**Interfaces:**
- Consumes: `KnownLimitation(id:title:detail:)` and `KnownLimitations.all` (unchanged types).
- Produces: six entries with the ids `helper-running-until-exit`, `erase-custom-folder-confirm`, `language-applelanguages`, `helper-colour-icon`, `new-window-template` and `system-launch-helper`, appended in that order; `KnownLimitations.all.count == 35`. The Known Limitations window lists `KnownLimitations.all`, so no view changes.

The texts use the codebase's British spelling ("honour", "colour"), as the existing entries do, and state behaviour fixed by Tasks 1-8: the helper carries `MAD_SHORTCUT_BUNDLE` until it exits (Global Constraints); the editor's confirmation and refusals (Task 7 `HelperEditorPolicy.eraseCheck`, Core `EraseOnQuitPolicy`); the `-AppleLanguages (<code>) -AppleLocale <code>` arguments (`DataSeparationPlanner`); the colour 18 pt icon (Task 6 Deviation 2); the New Window placeholders and the hidden `{dataPath}` command (Tasks 1 and 6); the System Launch helper in the Launcher process with `applicationShouldHandleReopen` (Task 6, `HelperMenuBarRunner`, used on that path even for erase-only).

- [ ] **Step 1: Write the failing tests.**

In `App/Tests/App/KnownLimitationsTests.swift`, replace:

```swift
    /// Phase 4 (web apps): the four web limits are present with their prescribed ids and titles, the earlier 20 are
    /// kept (29 in all with Phase 5's five), ids stay unique, and each entry states its point.
    func testPhase4WebEntriesStateTheirPoint() throws {
        let ids = KnownLimitations.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate known-limitation ids")
        XCTAssertEqual(ids.count, 29, "20 earlier entries plus the four web entries plus the five launcher entries")
```

with:

```swift
    /// Phase 4 (web apps): the four web limits are present with their prescribed ids and titles, the earlier 20 are
    /// kept (35 in all with Phase 5's five and Phase 6's six), ids stay unique, and each entry states its point.
    func testPhase4WebEntriesStateTheirPoint() throws {
        let ids = KnownLimitations.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate known-limitation ids")
        XCTAssertEqual(ids.count, 35, "20 earlier, four web, five launcher and six helper entries")
```

In the same file, insert directly before the class's closing brace (the file's last line):

```swift

    /// Phase 6 (helper): the six helper limits are present with their prescribed ids and titles, and each states its
    /// point: the running indicator waits for the helper, erase on quit confirms custom folders and refuses protected
    /// ones and can be skipped, the language needs AppleLanguages, the menu bar icon is in colour, New Window needs a
    /// command, and System Launch keeps the shortcut's own process open as the helper.
    func testPhase6HelperEntriesStateTheirPoint() throws {
        let topics: [(id: String, title: String, mentions: [String])] = [
            ("helper-running-until-exit", "A shortcut with a helper stays running until the helper exits",
             ["helper", "running indicator", "Erase on quit"]),
            ("erase-custom-folder-confirm", "Erase on quit asks before emptying a folder outside App Duplicator's data folder",
             ["~/Library/Application Support/App Duplicator/", "confirm", "Trash", "always refused", "logout"]),
            ("language-applelanguages", "The language setting works only in apps that honour AppleLanguages",
             ["-AppleLanguages", "-AppleLocale", "own language setting", "system language"]),
            ("helper-colour-icon", "The menu bar icon is the shortcut's icon in full colour",
             ["template", "light or dark menu bar"]),
            ("new-window-template", "New Window needs a command",
             ["{target}", "{bundleId}", "compatibility profile", "Advanced", "{dataPath}"]),
            ("system-launch-helper", "With System Launch, the shortcut itself stays open as the helper",
             ["no Dock icon", "Activity Monitor", "forward", "skips the erase"]),
        ]
        let byID = Dictionary(KnownLimitations.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for topic in topics {
            let entry = try XCTUnwrap(byID[topic.id], "no entry \(topic.id)")
            XCTAssertEqual(entry.title, topic.title)
            for phrase in topic.mentions {
                XCTAssertTrue("\(entry.title) \(entry.detail)".contains(phrase), "\(topic.id) does not mention \"\(phrase)\"")
            }
        }
    }
```

- [ ] **Step 2: Run the known-limitation tests and watch them fail.**

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/KnownLimitationsTests 2>&1 | grep -oE 'XCTAssertEqual failed: \("29"\) is not equal to \("35"\)|no entry helper-running-until-exit|\*\* TEST FAILED \*\*' | LC_ALL=C sort -u`
Expected: exactly these three lines:

```
** TEST FAILED **
XCTAssertEqual failed: ("29") is not equal to ("35")
no entry helper-running-until-exit
```

- [ ] **Step 3: Add the six entries.**

In `App/Sources/App/KnownLimitations.swift`, replace the doc comment's last three lines:

```swift
/// the four web app limits (passkeys, zoom storage, notification permission, pop-up and off-site links). Phase 5 adds
/// the five launcher limits (terminal AppleScript, terminal shell history, no running state for files or commands,
/// Ghostty path). Shown in the Known Limitations window and linked from the wizard's compatibility line.
```

with:

```swift
/// the four web app limits (passkeys, zoom storage, notification permission, pop-up and off-site links). Phase 5 adds
/// the five launcher limits (terminal AppleScript, terminal shell history, no running state for files or commands,
/// Ghostty path). Phase 6 adds the six helper limits (running until the helper exits, erase confirmation and refusals,
/// AppleLanguages, colour menu bar icon, New Window command, System Launch helper). Shown in the Known Limitations
/// window and linked from the wizard's compatibility line.
```

In the same file, replace the end of the list:

```swift
        KnownLimitation(
            id: "cli-ghostty-path",
            title: "Ghostty commands start in Ghostty's own environment",
            detail: "A command sent to Ghostty runs with the PATH and shell setup of the Ghostty window it opens, not the shortcut's environment, so a program that is not on that PATH needs its full path."
        ),
    ]
}
```

with:

```swift
        KnownLimitation(
            id: "cli-ghostty-path",
            title: "Ghostty commands start in Ghostty's own environment",
            detail: "A command sent to Ghostty runs with the PATH and shell setup of the Ghostty window it opens, not the shortcut's environment, so a program that is not on that PATH needs its full path."
        ),
        KnownLimitation(
            id: "helper-running-until-exit",
            title: "A shortcut with a helper stays running until the helper exits",
            detail: "With the menu bar icon or Erase on quit turned on, a small helper process watches the app for the shortcut. The sidebar's running indicator stays on until that helper exits: a moment after the app quits, or once the erase has finished when Erase on quit is on."
        ),
        KnownLimitation(
            id: "erase-custom-folder-confirm",
            title: "Erase on quit asks before emptying a folder outside App Duplicator's data folder",
            detail: "Erase on quit permanently deletes everything inside the shortcut's data folder each time the app quits; nothing goes to the Trash. A folder inside ~/Library/Application Support/App Duplicator/ needs no confirmation, any other folder needs you to confirm a warning first, and your home folder, folders outside it and top-level folders such as Desktop, Documents and Downloads are always refused. The erase runs only when the helper sees the app quit while no other copy of the shortcut is running, so a second copy, a logout, a restart or a helper quit from Activity Monitor can leave the data in place until the next time the app quits."
        ),
        KnownLimitation(
            id: "language-applelanguages",
            title: "The language setting works only in apps that honour AppleLanguages",
            detail: "A shortcut's language reaches the app as the -AppleLanguages and -AppleLocale launch arguments. An app that chooses its language another way, such as its own language setting, keeps its usual language, and an app without a translation for the chosen language falls back to one it has. A blank language follows the system language."
        ),
        KnownLimitation(
            id: "helper-colour-icon",
            title: "The menu bar icon is the shortcut's icon in full colour",
            detail: "The menu bar icon shows the shortcut's own icon in colour, as web app shortcuts do, instead of a monochrome template image, so it does not adapt to a light or dark menu bar the way system icons do."
        ),
        KnownLimitation(
            id: "new-window-template",
            title: "New Window needs a command",
            detail: "The menu bar icon's New Window item appears only when the shortcut has a New Window command: a command line run each time you choose the item, in which {target}, {bundleId} and {dataPath} stand for the app's path, its bundle identifier and the shortcut's data folder. The wizard copies the command from the app's compatibility profile when the profile includes one; otherwise, and for shortcuts made before this version, enter it in the editor's Advanced section. A command that uses {dataPath} is hidden while data separation is off."
        ),
        KnownLimitation(
            id: "system-launch-helper",
            title: "With System Launch, the shortcut itself stays open as the helper",
            detail: "In System Launch mode the menu bar icon and Erase on quit are run by the shortcut's own process, which stays open in the background with no Dock icon for as long as the app runs, and Activity Monitor lists it beside the app. Opening the shortcut again while the app runs brings the app forward instead of starting another copy. Quitting the shortcut's process from Activity Monitor removes the menu bar icon and skips the erase, but leaves the app running."
        ),
    ]
}
```

- [ ] **Step 4: Run the known-limitation tests.**

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/KnownLimitationsTests 2>&1 | tail -3`
Expected: the last line is `** TEST SUCCEEDED **`.

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/KnownLimitationsTests 2>&1 | grep -cE "Test Case .* passed"`
Expected: `9` (the eight existing tests plus `testPhase6HelperEntriesStateTheirPoint`).

- [ ] **Step 5: Run the whole app suite.**

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh 2>&1 | tail -3`
Expected: the last line is `** TEST SUCCEEDED **`.

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh 2>&1 | grep -cE "Test Case .* passed"`
Expected: `361` (360 after Task 8, plus one).

- [ ] **Step 6: Forbidden constructs.**

Run: `cd ~/Developer/MacAppDuplicator && grep -nE 'try\?|@unchecked|swiftlint:disable|nonisolated\(unsafe\)' App/Sources/App/KnownLimitations.swift App/Tests/App/KnownLimitationsTests.swift`
Expected: no output.

Run: `cd ~/Developer/MacAppDuplicator && grep -c 'KnownLimitation($' App/Sources/App/KnownLimitations.swift`
Expected: `35` (one `KnownLimitation(` opener per entry; any other number means an entry was lost or doubled in the edit).

- [ ] **Step 7: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add App/Sources/App/KnownLimitations.swift App/Tests/App/KnownLimitationsTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "App: known limitations for the helper" -m "Six Known Limitations entries for Phase 6: a shortcut with a helper shows as running until the helper exits; erase on quit confirms folders outside App Duplicator's data folder, refuses protected ones and is skipped when the helper does not see the app quit; the language setting works only in apps that honour AppleLanguages; the menu bar icon is the shortcut's icon in colour; New Window needs a command; System Launch keeps the shortcut's own process open as the helper. The Phase 4 count test now expects 35 entries." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Deviations

- The erase entry also says that a second running copy (Task 5's `helper erase skipped: another copy of this shortcut is still running`), a logout, a restart or a helper quit from Activity Monitor can skip the erase (the data stays until the next quit). The brief lists the entry only as "refuses paths outside App Duplicator support dir without confirm"; the skip is the one user-visible way erase on quit does not happen, and a seventh entry would change the brief's count of six, so it rides in the same entry.
- The erase entry says custom folders need a confirmation and protected folders are always refused, rather than "refuses paths outside App Duplicator support dir without confirm": Task 7's editor asks for any folder outside App Duplicator's data folder and refuses only what `EraseOnQuitPolicy` refuses (home, outside home, top-level folders), and the helper re-checks at quit.
- The New Window entry describes the placeholders and the Advanced field instead of "needs a profile template": none of the 18 bundled profiles in `Packages/CompatProfiles/Resources/profiles.json` has a `newWindowCommand` today (all are `null`), so in practice every New Window command is typed in the editor until profiles gain templates. The entry does not say so, because the text would go stale when a profile update adds one.
- The language entry makes no claim about specific app frameworks (Electron, Java, web views); which of them honour `-AppleLanguages` was not verified.

### Task 10: Docs: Phase 6 acceptance checklist, README section, spec touch-ups

**Files:**
- Create: `docs/acceptance/phase6-helper.md`
- Modify: `README.md` (line 22 `madctl plan` usage; Defaults bullets at lines 30-31; line 74, end of the `Editor:` bullet; line 78; line 123; new `## Phase 6 helper` section between line 139 `Acceptance checklist: docs/acceptance/phase5-launchers.md` and line 141 `## Core API used by the app`; Core API bullet after line 149 ``- `SecretMasking.mask`.``)
- Modify: `docs/superpowers/specs/2026-10-09-macos-app-duplicator-design.md` (line 62 `Launcher` row; §3.4 line 99 step 5; line 102 System Launch sentence; §4.6 body lines 181-185; new sub-bullet after line 235 in §7)

**Interfaces:**
- Consumes: the behaviour and texts fixed by Tasks 1-9: madctl flags `--menu-bar-icon`, `--erase-on-quit`, `--new-window-command <template>` and the error `Error: --erase-on-quit needs --data-mode auto or home` (Task 1); `HelperLogLine` texts `helper spawned pid=`, `helper start pid=… watch=… bundle=… data=…`, `helper exec observed`, `helper new window argv …`, `helper quit signal=15`, `helper target exited status=<n>|unavailable`, `helper erase <path> removed=<n>`, `helper erase skipped: another copy of this shortcut is still running (pid <n>)`, `helper show failed: macOS refused to activate pid <n>`, `helper exit` (Tasks 2, 5, 6); `HelperEditorPolicy` texts (Task 7): the confirmation title "Erase this folder on quit?", its message, the buttons `Erase on Quit` and `Cancel`, `disabledDataMessage`, the three New Window notes, "Use a language code like en, fr or pt-BR.", the refusal prefix "Erase on quit never empties this folder: "; Diagnostics rows `Menu bar icon`, `Erase on quit`, `New Window command`, `Language` (Task 7); the editor controls in `LaunchSection` and `AdvancedSection` (Task 8); the six known-limitation titles (Task 9).
- Produces: documentation only. No Swift file changes.

All 13 anchors below were checked against the files at `4e0e4e5`: each `Replace:` text occurs exactly once.

- [ ] **Step 1: Create the acceptance checklist.**

````bash
cd ~/Developer/MacAppDuplicator && mkdir -p docs/acceptance && cat > docs/acceptance/phase6-helper.md <<'ACCEPTANCE_EOF'
# Phase 6 acceptance: helper

Manual checks for the helper on a real Mac, with Mike present: the menu bar icon (Show, New Window, Quit) on a Dock Shortcut and on a System Launch shortcut, erase on quit, and the language override. Run them in order on a build of this commit. Every shortcut made here lives in a fresh temporary output folder, every folder that gets erased is a test folder, and everything is moved to the Trash at the end; nothing is deleted outright.

## Preconditions

- macOS 26 on Apple silicon, signed in to a normal user account.
- A current backup (Time Machine or similar). Step 4 empties real folders under your home folder; the guards limit it to the test folders, and Step 4 is what proves that.
- TextEdit installed (it is part of macOS) and not running: `pgrep -x TextEdit` prints nothing.
- Write down the current output folder (Settings → General → Output folder) so Teardown can restore it.
- In Terminal, from the repository (keep this window open; later steps use `$OUT`, `$LOGS` and `$DATA`):
  `cd ~/Developer/MacAppDuplicator`
  `OUT=$(mktemp -d "$HOME/Desktop/ad-phase6.XXXXXX") && echo "$OUT"`
  `LOGS="$HOME/Library/Logs/App Duplicator"`
  `DATA="$HOME/Library/Application Support/App Duplicator/ad-p6-erase"`

## Step 1: Build

- [ ] **1.1** `swift build -c release --product Launcher --product WebShell --product madctl 2>&1 | tail -1` prints `Build complete!`.
- [ ] **1.2** `Tools/build-app.sh --configuration Release` succeeds.
- [ ] **1.3** About App Duplicator shows `Version 0.6.0 (5)`.
- [ ] **1.4** `Tools/build-fixture.sh` succeeds and `ls .build/fixtures/FixtureApp.app/Contents/Resources` lists `AppIcon.icns`.
- [ ] **1.5** `MAD_INTEGRATION=1 swift test --filter IntegrationTests 2>&1 | grep -E "Executed [0-9]+ tests?" | tail -1` prints `Executed 5 tests, with 0 failures (0 unexpected) in …`. Do not start Step 4 if it fails: this run includes the erase-on-quit test on a throwaway folder.
- [ ] **1.6** Create the two fixture shortcuts: `.build/release/madctl new .build/fixtures/FixtureApp.app --name "AD P6 Fixture" --env MAD_FIXTURE_LIFETIME=600 --out "$OUT"` and `.build/release/madctl new .build/fixtures/FixtureApp.app --name "AD P6 Erase" --data-mode home --env MAD_FIXTURE_LIFETIME=5 --out "$OUT"`. Both succeed and `ls "$OUT"` lists `AD P6 Erase.app` and `AD P6 Fixture.app`.
- [ ] **1.7** Settings → General → Output folder → `Choose…`, press ⇧⌘G, paste the folder `echo "$OUT"` printed and choose it. The sidebar lists exactly `AD P6 Erase` and `AD P6 Fixture` under Apps (press ⌘R to refresh if they are missing).

## Step 2: Menu bar icon on a Dock Shortcut

- [ ] **2.1** Select `AD P6 Fixture` and press `Launch`. The `MAD Fixture` window opens, no menu bar icon appears, and `pgrep -lf 'AD P6 Fixture.*--helper'` prints nothing (no helper while the menu bar icon and erase on quit are off). Quit it: Control-click its Dock tile → Quit (the fixture has no menus, so ⌘Q does nothing).
- [ ] **2.2** In the editor's Advanced section turn `Menu bar icon` on: the note under `New Window command` reads "New Window is hidden until you enter a command." Type `open -na {target}` into `New Window command`: the note goes away. Turn `Menu bar icon` off: the note reads "New Window appears only while Menu bar icon is on." Turn it on again and press `Save`.
- [ ] **2.3** Press `Launch`. Within a few seconds the fixture's icon appears in the menu bar in full colour (not a grey silhouette); its menu reads `Show AD P6 Fixture`, `New Window`, a separator, `Quit AD P6 Fixture`. The sidebar row shows it running. `pgrep -lf 'AD P6 Fixture.*--helper'` prints exactly one line, and that line ends with `AD P6 Fixture.app -` (the `-` means no folder to erase).
- [ ] **2.4** Click another app's window, then choose `Show AD P6 Fixture`: the `MAD Fixture` window comes to the front. If it does not, the step fails; record what `tail -n 5 "$LOGS/AD P6 Fixture.log"` shows (`helper show failed: macOS refused to activate pid …` means macOS declined the activation).
- [ ] **2.5** Choose `New Window`: a second `MAD Fixture` window opens (a second fixture process) and closes by itself after about 3 seconds, because `open` starts it through LaunchServices without the shortcut's `MAD_FIXTURE_LIFETIME`. `grep 'helper new window' "$LOGS/AD P6 Fixture.log" | tail -n 1` shows `helper new window argv /usr/bin/env open -na ` followed by the fixture's absolute path, ending in `.build/fixtures/FixtureApp.app`.
- [ ] **2.6** Run `open "$OUT/AD P6 Fixture.app"; sleep 5; pgrep -x FixtureApp | wc -l` and record which of these happened; either passes: (a) it prints `1` and the existing `MAD Fixture` window came to the front; (b) it prints `2` and a second copy with its own menu bar icon started (quit that copy with its own `Quit AD P6 Fixture` before going on).
- [ ] **2.7** Choose `Quit AD P6 Fixture`. Within 10 seconds the window closes, the menu bar icon goes away, the sidebar row stops showing it running, and `pgrep -lf 'AD P6 Fixture'` prints nothing. `grep helper "$LOGS/AD P6 Fixture.log" | tail -n 20` contains, in this order: `helper spawned pid=…`, `helper start pid=… watch=… bundle=… data=-`, `helper exec observed`, `helper new window argv …`, `helper quit signal=15`, `helper target exited status=143` (or `status=unavailable`), `helper exit`; there is no `helper erase` line.
- [ ] **2.8** Turn `Menu bar icon` off and press `Save`. `Diagnostics…` shows `Menu bar icon: Off` and `New Window command: /usr/bin/env open -na <fixture path> (hidden: the menu bar icon is off)`. Press `Launch`: no menu bar icon appears and `pgrep -lf 'AD P6 Fixture.*--helper'` prints nothing. Quit it from its Dock tile, then turn `Menu bar icon` back on and press `Save`.

## Step 3: Menu bar icon with System Launch (TextEdit)

- [ ] **3.1** ⌘N → `Application` → `Browse…` → `/System/Applications/TextEdit.app` → `Next`; name it `AD P6 TextEdit` and press `Create`. In its editor, `Launch mode` is `System Launch` (TextEdit is a platform binary, so Dock Shortcut is not available).
- [ ] **3.2** In Advanced turn `Menu bar icon` on, enter `open -na {target}` as the `New Window command` and press `Save`.
- [ ] **3.3** Press `Launch`. TextEdit starts with its own Dock tile and no `AD P6 TextEdit` Dock tile stays; the TextEdit icon appears in the menu bar in full colour, with `Show AD P6 TextEdit`, `New Window`, a separator and `Quit AD P6 TextEdit`. `pgrep -lf 'AD P6 TextEdit.app/Contents/MacOS'` prints exactly one line, and that line has no `--helper` (with System Launch the shortcut itself stays open as the helper).
- [ ] **3.4** Click another app's window, then choose `Show AD P6 TextEdit`: TextEdit comes to the front.
- [ ] **3.5** Run `open "$OUT/AD P6 TextEdit.app"; sleep 3; pgrep -x TextEdit | wc -l`: TextEdit comes to the front, the command prints `1`, and `pgrep -lf 'AD P6 TextEdit.app/Contents/MacOS'` still prints one line.
- [ ] **3.6** Choose `New Window`: a second TextEdit starts (`pgrep -x TextEdit | wc -l` prints `2`), and `grep 'helper new window' "$LOGS/AD P6 TextEdit.log" | tail -n 1` shows `helper new window argv /usr/bin/env open -na /System/Applications/TextEdit.app`.
- [ ] **3.7** Choose `Quit AD P6 TextEdit`. Within 10 seconds `pgrep -x TextEdit | wc -l` prints `1` (the copy the shortcut started is gone; the New Window copy stays), no save prompt appears, the menu bar icon goes away and `pgrep -lf 'AD P6 TextEdit.app/Contents/MacOS'` prints nothing. Quit works like `kill`: an unsaved document in the quit copy would be lost without a prompt. `grep helper "$LOGS/AD P6 TextEdit.log"` contains, in this order: `helper start pid=… watch=… bundle=… data=-`, `helper new window argv …`, `helper quit signal=15`, `helper target exited status=…` (a number or `unavailable`), `helper exit`; it has no `helper spawned` and no `helper exec observed` line. Quit the remaining TextEdit with ⌘Q.

## Step 4: Erase on quit

- [ ] **4.1** Select `AD P6 Erase`, press `Launch` and let the fixture quit by itself (about 5 seconds). `ls -la "$DATA"` lists symbolic links into your home folder, among them `Desktop -> /Users/<you>/Desktop` and `Documents -> /Users/<you>/Documents`.
- [ ] **4.2** Record these baselines: `ls -A "$HOME/Desktop" | wc -l`, `ls -A "$HOME/Documents" | wc -l`, `ls -A "$HOME/.ssh" 2>/dev/null | wc -l` and `ls "$OUT"`.
- [ ] **4.3** In the editor's Launch section turn `Erase on quit` on: it turns on at once, with no question (the folder is inside App Duplicator's data folder). Press `Save`. `Diagnostics…` shows `Erase on quit: On: /Users/<you>/Library/Application Support/App Duplicator/ad-p6-erase`.
- [ ] **4.4** Run `touch "$DATA/marker.txt"`, press `Launch` and wait for the fixture to quit. Then `ls -A "$DATA"` prints nothing, `test -d "$DATA" && echo kept` prints `kept`, `pgrep -lf 'AD P6 Erase'` prints nothing, and `grep helper "$LOGS/AD P6 Erase.log" | tail -n 4` shows `helper exec observed`, `helper target exited status=0` (or `status=unavailable`), `helper erase /Users/<you>/Library/Application Support/App Duplicator/ad-p6-erase removed=<n>` and `helper exit`.
- [ ] **4.5** Run the four baseline commands from 4.2 again: every count and the `ls "$OUT"` listing are unchanged. The erase removed the links into your home folder without following them.
- [ ] **4.6** Run `open -n "$OUT/AD P6 Erase.app"; sleep 2; open -n "$OUT/AD P6 Erase.app"` and wait about 10 seconds for both copies to quit. `grep 'helper erase' "$LOGS/AD P6 Erase.log" | tail -n 2` shows `helper erase skipped: another copy of this shortcut is still running (pid <n>)` followed by `helper erase … removed=<n>`, and `ls -A "$DATA"` prints nothing.
- [ ] **4.7** Run `mkdir "$OUT/custom-data"`. With `Erase on quit` still on, press the data folder's `Browse…`, press ⇧⌘G, paste the `custom-data` path and choose it. A confirmation appears: the title "Erase this folder on quit?", a message that starts "Every time AD P6 Erase quits, everything inside", names the `custom-data` folder, says everything inside it is deleted permanently and not moved to the Trash, and ends "This folder is outside App Duplicator's data folder.", and the buttons `Erase on Quit` and `Cancel`. Press `Cancel`: `Data folder` still shows the default folder and `Erase on quit` stays on.
- [ ] **4.8** Choose the `custom-data` folder again and press `Erase on Quit`: `Data folder` shows the `custom-data` path. Press `Save`. Run `touch "$OUT/custom-data/marker.txt"`, press `Launch` and wait for the fixture to quit: `ls -A "$OUT/custom-data"` prints nothing, `test -d "$OUT/custom-data" && echo kept` prints `kept`, and `ls "$OUT"` still lists `AD P6 Erase.app`, `AD P6 Fixture.app`, `AD P6 TextEdit.app` and `custom-data` (the data folder's `Desktop` link pointed at the folder that holds `$OUT`; it was removed, not followed).
- [ ] **4.9** Turn `Erase on quit` off, then on again: the confirmation appears. Press `Cancel`: the toggle stays off.
- [ ] **4.10** Press `Revert` (the saved state: `custom-data`, Erase on quit on). Run `mkdir -p /Users/Shared/ad-p6-outside/data`, then choose that folder with the data folder's `Browse…` (⇧⌘G): no confirmation appears, `Data folder` shows `/Users/Shared/ad-p6-outside/data`, `Erase on quit` turns off, and a red message reads "Erase on quit never empties this folder: the folder is outside the home folder." Turn `Erase on quit` on: it stays off and the same message shows. Press `Revert`.
- [ ] **4.11** Set `Data` to `Disabled`: `Erase on quit` turns off and is dimmed, and the caption reads "Erase on quit needs a data folder: set Data to Auto or HOME override." Press `Revert`.
- [ ] **4.12** `.build/release/madctl plan .build/fixtures/FixtureApp.app --data-mode disabled --erase-on-quit 2>&1 | grep -m1 'Error:'` prints `Error: --erase-on-quit needs --data-mode auto or home`.

## Step 5: Language override (TextEdit fr)

- [ ] **5.1** Select `AD P6 TextEdit`. In the Launch section type `en_US` into `Language`: a red message reads "Use a language code like en, fr or pt-BR." and `Save` is disabled.
- [ ] **5.2** Change it to `fr` and press `Save`. `Diagnostics…` shows `Language: fr`.
- [ ] **5.3** With no TextEdit running (`pgrep -x TextEdit` prints nothing), press `Launch`: TextEdit's menus are in French (`Fichier`, `Édition`, `Format`).
- [ ] **5.4** Choose `Quit AD P6 TextEdit` from its menu bar icon. Run `open -a TextEdit`: its menus use your system language. Quit it with ⌘Q.
- [ ] **5.5** Clear `Language` and press `Save`: `Diagnostics…` shows `Language: System`. Press `Launch`: the menus use your system language. Quit it from its menu bar icon.

## Step 6: Diagnostics

- [ ] **6.1** Select `AD P6 Fixture` and open `Diagnostics…`: the rows read `Menu bar icon: On`, `Erase on quit: Off`, `New Window command: /usr/bin/env open -na <fixture path>` and `Language: System`.
- [ ] **6.2** Press `Copy Report`, then run `pbpaste | grep -E '^(Menu bar icon|Erase on quit|New Window command|Language): '`: it prints those four lines.
- [ ] **6.3** Select `AD P6 Erase` and open `Diagnostics…`: `Erase on quit: On: ` followed by the `custom-data` path.

## Teardown

- Quit every shortcut from this checklist; `pgrep -lf 'AD P6'` prints nothing.
- Settings → General → Output folder → `Choose…`: restore the folder written down in Preconditions; your own shortcuts reappear in the sidebar.
- In Finder, move to the Trash: the `$OUT` folder, `/Users/Shared/ad-p6-outside`, the folders `ad-p6-erase`, `ad-p6-fixture` and `ad-p6-textedit` in `~/Library/Application Support/App Duplicator/` (those that exist), and `AD P6 Erase.log`, `AD P6 Fixture.log` and `AD P6 TextEdit.log` in `~/Library/Logs/App Duplicator/`. Do not empty the Trash as part of this checklist.

## Record

| Step | Date | Result | Notes |
|------|------|--------|-------|
| 1 | | | |
| 2 | | | |
| 3 | | | |
| 4 | | | |
| 5 | | | |
| 6 | | | |
ACCEPTANCE_EOF
````

- [ ] **Step 2: Check the checklist's shape.**

Run: `cd ~/Developer/MacAppDuplicator && grep -c '^- \[ \] \*\*' docs/acceptance/phase6-helper.md && grep -c '^## Step ' docs/acceptance/phase6-helper.md && grep -cE '^\| [1-6] \| \| \| \|$' docs/acceptance/phase6-helper.md`
Expected:

```
42
6
6
```

(7 + 8 + 7 + 12 + 5 + 3 checklist items in Steps 1-6, six step headings, six Record rows.)

- [ ] **Step 3: README: madctl usage line.**

In `README.md` replace (line 22):

```text
madctl plan <app-path> [--data-mode auto|home|disabled] [--data-path P] [--mode dock|system] [--env K=V ...] [--arg A ...] [--appearance system|light|dark] [--language CODE] [--name N]
```

with:

```text
madctl plan <app-path> [--data-mode auto|home|disabled] [--data-path P] [--mode dock|system] [--env K=V ...] [--arg A ...] [--appearance system|light|dark] [--language CODE] [--menu-bar-icon] [--erase-on-quit] [--new-window-command T] [--name N]
```

Line 23 (`madctl new <app-path> --name N [same flags] …`) stays as it is; "same flags" now covers the three new ones.

- [ ] **Step 4: README: Defaults bullets.**

Replace (lines 30-31):

```text
- `--appearance`: `system`
- `--name`: the target app's name (`plan` only; `new` requires `--name`)
```

with:

```text
- `--appearance`: `system`
- `--language`: none (the system language); a code such as `en`, `fr` or `pt-BR`
- `--menu-bar-icon`, `--erase-on-quit`: off; `--erase-on-quit` needs `--data-mode auto` or `home`
- `--new-window-command`: none; a template such as `open -na {target}` (`{target}`, `{bundleId}` and `{dataPath}` are replaced; the result is split on spaces and never run by a shell)
- `--name`: the target app's name (`plan` only; `new` requires `--name`)
```

- [ ] **Step 5: README: the Phase 2 editor bullet, the limitation count and the Phase 4 menu bar bullet.**

Replace (the end of line 74; the text before it on that line stays):

```text
`Erase data on quit` and `Menu bar icon` show their stored values but stay disabled for application shortcuts until Phase 6; a web app's `Menu bar icon` is live (see Phase 4 web apps).
```

with:

```text
`Erase on quit` (Launch section), `Menu bar icon` and `New Window command` (Advanced) work for application shortcuts since Phase 6 (see Phase 6 helper); a web app's `Menu bar icon` belongs to its web shell (see Phase 4 web apps).
```

Replace (line 78):

```text
- Help → Known Limitations (29 entries since Phase 5; the six profile entries are listed under Phase 3 profiles, the four web entries under Phase 4 web apps and the five launcher entries under Phase 5 files, folders and commands).
```

with:

```text
- Help → Known Limitations (35 entries since Phase 6; the six profile entries are listed under Phase 3 profiles, the four web entries under Phase 4 web apps, the five launcher entries under Phase 5 files, folders and commands and the six helper entries under Phase 6 helper).
```

Replace (the second sentence of line 123):

```text
For a web app the Menu bar icon is live in this phase; for application shortcuts it stays inert until Phase 6.
```

with:

```text
A web app's menu bar icon belongs to its web shell; application shortcuts get theirs from the Phase 6 helper.
```

- [ ] **Step 6: README: the Phase 6 helper section.**

Replace (lines 139-141):

```text
Acceptance checklist: docs/acceptance/phase5-launchers.md

## Core API used by the app
```

with:

```text
Acceptance checklist: docs/acceptance/phase5-launchers.md

## Phase 6 helper

Application shortcuts gain three options, all off until you turn them on, and a checked language field:

- **Menu bar icon** (Advanced) shows the shortcut's own icon, in full colour, in the menu bar while the app runs. Its menu has `Show <Name>` (brings the app to the front), `New Window` (only when a New Window command is set) and `Quit <Name>`. Quit sends SIGTERM and, if the app is still running 10 seconds later, SIGKILL: the app does not get to ask about unsaved work.
- **New Window command** (Advanced) is a template such as `open -na {target}`; `{target}`, `{bundleId}` and `{dataPath}` are replaced, and the result is split on spaces and run through `/usr/bin/env`, never a shell, with the shortcut's environment. An app started with `open` gets LaunchServices' environment rather than the shortcut's (no HOME override, no extra variables), so pass the data folder yourself, for example `open -na {target} --args --user-data-dir={dataPath}` for a Chromium browser. The wizard copies a profile's `newWindowCommand`; no bundled profile sets one yet.
- **Erase on quit** (Launch section, under the data folder) empties the data folder every time the app quits, so each launch starts clean and signed out. It needs Data set to Auto or HOME override. A folder inside App Duplicator's data folder is accepted at once; any other folder needs a confirmation. Some folders are never emptied, whatever a shortcut says: your home folder and the folders directly inside it, the folders directly inside `~/Library`, App Duplicator's data folder itself, anything outside your home folder or fewer than four levels below `/`, and symbolic links. Links inside the folder (the HOME override's links to Desktop, Documents and the rest) are removed, never followed, and the folder itself stays. The erase is skipped while another copy of the same shortcut is still running.
- **Language** (Launch section) takes a code such as `en`, `fr` or `pt-BR`; anything else shows a message and Save stays disabled. Apps that ignore `AppleLanguages` keep the system language.

The helper runs only while the menu bar icon or erase on quit is on, and only for application shortcuts; with both off a shortcut leaves no process behind, as before. In Dock Shortcut mode the shortcut starts a second copy of its launcher (`posix_spawn`, in its own session) just before it becomes the app, and that copy erases only after it has seen the app start and then exit. In System Launch mode the shortcut itself stays open as the helper, so opening the shortcut again brings the app forward. Helper events go to the shortcut's log in `~/Library/Logs/App Duplicator/` as `helper …` lines: start, exec observed, new window, quit, target exited, erase (or why it was skipped) and exit.

Diagnostics adds `Menu bar icon`, `Erase on quit` (with the reason when the folder would never be emptied), `New Window command` (the masked command line, or why it is hidden) and `Language`, and Copy Report includes them. madctl gains `--menu-bar-icon`, `--erase-on-quit` (needs `--data-mode auto` or `home`) and `--new-window-command <template>`. Help → Known Limitations has six helper entries: the app counts as running until its helper exits, erase confirmation and refusals, apps that ignore `AppleLanguages`, the full-colour icon, New Window needs a command, and System Launch keeps the shortcut open.

Acceptance checklist: `docs/acceptance/phase6-helper.md`.

## Core API used by the app
```

- [ ] **Step 7: README: Core API bullets.**

Replace (line 149):

```text
- `SecretMasking.mask`.
```

with:

```text
- `SecretMasking.mask`.
- `HelperPlan.isNeeded(for:)`, `HelperPlan.eraseDataPath(for:)`, `HelperPlan.showsMenuBarIcon(for:)` and `HelperPlan.newWindowArguments(for:targetPath:)` for the editor notes, the preview's helper line and Diagnostics.
- `EraseOnQuitPolicy.check(dataPath:home:)` and `EraseOnQuitRefusal` for the erase checks.
- `NewWindowCommandBuilder.validationMessage(for:)` and `LanguageCode.validationMessage(for:)` for the field messages.
```

- [ ] **Step 8: Check the README.**

Run: `cd ~/Developer/MacAppDuplicator && grep -c 'until Phase 6' README.md; grep -c 'Erase data on quit' README.md; grep -c -- '--new-window-command' README.md; grep -c '35 entries since Phase 6' README.md; grep -c 'docs/acceptance/phase6-helper.md' README.md; grep '^## ' README.md`
Expected:

```
0
0
3
1
1
## Phase 1 engine
## Phase 2 library app
## Phase 3 profiles
## Phase 4 web apps
## Phase 5 launchers
## Phase 6 helper
## Core API used by the app
```

(`--new-window-command` appears on the usage line, its Defaults bullet and the Phase 6 section's madctl sentence.)

- [ ] **Step 9: Spec: the Launcher row, §3.4 step 5 and the System Launch sentence.**

In `docs/superpowers/specs/2026-10-09-macos-app-duplicator-design.md` replace (inside line 62, the `Launcher` row of the §3 component table):

```text
forks helper if needed
```

with:

```text
starts the helper with `posix_spawn` if needed (§4.6)
```

Replace (line 99):

```text
5. If menu bar icon or erase-on-quit is enabled: `fork()`; child `setsid()`s and re-executes the same Launcher binary with `--helper <parentPid> <bundlePath>`.
```

with:

```text
5. If menu bar icon or erase-on-quit is enabled (application shortcuts only): `posix_spawn` the same Launcher binary with `POSIX_SPAWN_SETSID` (its own session) and `--helper <parentPid> <startSeconds> <startMicroseconds> <bundlePath> <dataPath|->`, where the start time is the Launcher's own `proc_pidinfo` start time (`execve` keeps it). Phase 6 deviation: the design said `fork()`, then `setsid()` and a re-exec in the child; Swift marks `fork()` unavailable, and `posix_spawn` gives the same detached child without copying the parent.
```

Replace (the end of line 102):

```text
Launcher waits for the callback then exits (or stays as helper).
```

with:

```text
Launcher waits for the callback then exits or, when the menu bar icon or erase-on-quit is enabled, stays running as the helper itself (no second process; §4.6).
```

- [ ] **Step 10: Spec: rewrite the §4.6 body.**

Replace (lines 181-185, everything between the `### 4.6 Helper role` heading's blank line and the blank line before `### 4.7 Error handling`):

```text
`Launcher --helper <parentPid> <bundlePath>`:
- `NSApplication` with `.accessory` activation policy; no Dock tile.
- `NSStatusItem` with the shortcut icon (template-rendered 18 pt). Menu: **Show** (activate pid via `NSRunningApplication(processIdentifier:)`), **New Window** (runs profile's `newWindowCommand` if any, e.g. `open -na <bundle> --args --user-data-dir=<path>`; hidden otherwise), optional unread badge (webApp only), **Quit <Name>** (SIGTERM to pid, then SIGKILL after 10 s if still alive).
- Watches parent with `kqueue` `EVFILT_PROC NOTE_EXIT`; on exit performs erase-on-quit if enabled, then exits. Also exits if the parent pid is reused by another process (checks `proc_pidinfo` start time captured at fork).
- Forked only when menu bar icon or erase-on-quit is enabled. Otherwise the shortcut is a pure exec with zero residual process.
```

with:

```text
`Launcher --helper <parentPid> <startSeconds> <startMicroseconds> <bundlePath> <dataPath|->` (application shortcuts only):
- Dock Shortcut mode: the Launcher starts the helper with `posix_spawn` (`POSIX_SPAWN_SETSID`, isolated standard streams) just before it `execve`s the target (§3.4 step 5). `<startSeconds> <startMicroseconds>` is the Launcher's own `proc_pidinfo` start time, which `execve` keeps, and `<dataPath|->` is the folder to erase or `-`. System Launch mode: no second process; after the `openApplication` callback the Launcher itself becomes the helper and watches the app it started.
- `NSApplication` with `.accessory` activation policy (no Dock tile) only when the menu bar icon is on or the mode is System Launch, where opening the shortcut again reaches the helper and `applicationShouldHandleReopen` brings the target forward. A Dock-mode helper that only erases never loads AppKit.
- `NSStatusItem` with the shortcut's own icon (`CFBundleIconFile`) in full colour at 18 pt, `isTemplate = false`. Phase 6 decision: a full-colour app icon rendered as a template becomes a solid silhouette, so the helper draws it in colour, as the Phase 4 web shell's status item does. Menu: **Show <Name>** (activates the target via `NSRunningApplication(processIdentifier:)`; a refusal is logged), **New Window** (runs the shortcut's `newWindowCommand` through `/usr/bin/env`, never a shell, e.g. `open -na {target} --args --user-data-dir={dataPath}`; hidden when there is none), a separator, **Quit <Name>** (SIGTERM to the target, then SIGKILL after 10 s only if the same process, by start time, is still alive). No unread badge: web apps keep theirs in the web shell.
- Watches the target with `kqueue` `EVFILT_PROC` `NOTE_EXIT | NOTE_EXEC` (plus `NOTE_EXITSTATUS` when the kernel allows it). In Dock mode the erase runs only after the helper has seen the `execve` and then the exit; in System Launch mode, after the exit. `EraseOnQuitPolicy` refuses the home folder and its direct children, the direct children of `~/Library`, the App Duplicator data root, paths outside home, symbolic links and paths fewer than four levels below `/`; `EraseOnQuitPerformer` removes the folder's contents without following links and keeps the folder. The erase is skipped while another process runs from the same shortcut's Launcher binary (another copy's helper). The helper exits without erasing when the watched pid's start time no longer matches (pid reuse).
- Started only when the menu bar icon or erase-on-quit is enabled (`HelperPlan.isNeeded(for:)`). Otherwise the shortcut is a pure exec with zero residual process.
```

- [ ] **Step 11: Spec: record the editor layout in §7.**

Insert this line directly after line 235, the single line that starts `  - Phase 5 scope reduction: command shortcuts have no environment table` (line 236 starts `- **New wizard**`):

```text
  - Phase 6 layout: `Erase on quit` sits in the Launch section under the data folder it empties (it needs Data set to Auto or HOME override, and a folder outside App Duplicator's data folder needs a confirmation); `Menu bar icon` and the `New Window command` field sit in Advanced; all three apply to application shortcuts only, and `Language` stays in the Launch section with its code check.
```

- [ ] **Step 12: Check the spec.**

Run: `cd ~/Developer/MacAppDuplicator && S=docs/superpowers/specs/2026-10-09-macos-app-duplicator-design.md; grep -c 'fork()' $S; grep -cE 'forks helper|Forked only|captured at fork|template-rendered' $S; grep -c 'Phase 6 deviation: the design said' $S; grep -c 'rendered as a template becomes a solid silhouette' $S; grep -c 'stays running as the helper itself' $S; grep -c '^  - Phase 6 layout:' $S; sed -n '/^### 4.6 Helper role$/,/^### 4.7 Error handling$/p' $S | wc -l | tr -d ' '`
Expected:

```
1
0
1
1
1
1
10
```

(`fork()` survives only in step 5's deviation note; the §4.6 range is the heading, a blank line, the argv line, five bullets, a blank line and the §4.7 heading.)

- [ ] **Step 13: Confirm only the three docs changed.**

Run: `cd ~/Developer/MacAppDuplicator && git status --short --untracked-files=no && git status --short -- docs/acceptance`
Expected:

```
 M README.md
 M docs/superpowers/specs/2026-10-09-macos-app-duplicator-design.md
?? docs/acceptance/phase6-helper.md
```

- [ ] **Step 14: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add docs/acceptance/phase6-helper.md README.md docs/superpowers/specs/2026-10-09-macos-app-duplicator-design.md && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Docs: Phase 6 helper acceptance checklist, README and spec" -m "The checklist covers the menu bar icon on a Dock Shortcut and a System Launch shortcut, erase on quit with its confirmation and refusals, and the TextEdit fr language check. README gains the Phase 6 helper section and the madctl flags; the spec records posix_spawn instead of fork and the full-colour status item." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Deviations

- The checklist makes the two fixture shortcuts with `madctl new` (exact `MAD_FIXTURE_LIFETIME` and data mode in one line) and the TextEdit shortcut in the app's wizard, so both creation paths reach the helper. TextEdit is the System Launch case because it is a platform binary.
- The erase-refusal check (4.10) uses `/Users/Shared/ad-p6-outside/data`, not a folder such as `~/Documents`: `DataPathGuard` refuses every direct child of the home folder as a data folder before the erase check runs, so the outside-home refusal is the one the editor can reach.
- 2.6 records which reopen outcome happens in Dock Shortcut mode instead of asserting one; Task 6's Deviations explain why the routing is unknown. A follow-up is listed under Deferred.
- Quit is SIGTERM then SIGKILL, as spec §4.6 says; 3.7 tells the tester an unsaved document would be lost. No known-limitation entry covers this (Task 9 has the six the brief names); see the report's concerns.
- README line 78 keeps the existing "Phase 5 files, folders and commands" wording although that section's heading is `Phase 5 launchers`; only the count and the helper clause change.
- Step 11 adds a §7 sub-bullet for the editor layout (Erase on quit in the Launch section, Task 8). The brief names two spec touch-ups; this third one records Task 8's layout deviation where the editor is specified. §4.7 gets no helper rows: helper failures are log lines, not user-facing errors.
- The README and spec use "colour", following the codebase's British spelling.

### Task 11: Release: 0.6.0 (5) and the full verification run

**Files:**
- Modify: `App/project.yml` (lines 56-57)

**Interfaces:**
- Consumes: Tasks 1-10 committed on `main`.
- Produces: `CURRENT_PROJECT_VERSION` `5` and `MARKETING_VERSION` `0.6.0`, shown by About App Duplicator as `Version 0.6.0 (5)` (acceptance 1.3).

- [ ] **Step 1: Bump the version.**

In `App/project.yml` replace (lines 56-57, eight-space indent):

```text
        CURRENT_PROJECT_VERSION: "4"
        MARKETING_VERSION: "0.5.0"
```

with:

```text
        CURRENT_PROJECT_VERSION: "5"
        MARKETING_VERSION: "0.6.0"
```

Run: `cd ~/Developer/MacAppDuplicator && grep -nE 'CURRENT_PROJECT_VERSION|MARKETING_VERSION' App/project.yml`
Expected:

```
56:        CURRENT_PROJECT_VERSION: "5"
57:        MARKETING_VERSION: "0.6.0"
```

- [ ] **Step 2: Build and run the package tests.**

Run: `cd ~/Developer/MacAppDuplicator && swift build 2>&1 | tail -1`
Expected: `Build complete!`

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: `Executed 286 tests, with 0 failures (0 unexpected) in …` (235 at `4e0e4e5` plus 51 new).

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter WebShellTests 2>&1 | grep "'Selected tests' passed" -A1`
Expected: the second line reads `Executed 56 tests, with 0 failures (0 unexpected) in …` (unchanged).

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter CompatProfilesTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: `Executed 37 tests, with 0 failures (0 unexpected) in …` (unchanged).

- [ ] **Step 3: Run the gated integration tests.**

Run: `cd ~/Developer/MacAppDuplicator && swift build -c release --product Launcher --product WebShell --product madctl 2>&1 | tail -1 && Tools/build-fixture.sh && MAD_INTEGRATION=1 swift test --filter IntegrationTests 2>&1 | grep -E "Executed [0-9]+ tests?" | tail -1`
Expected: the first line is `Build complete!` and the last line is `Executed 5 tests, with 0 failures (0 unexpected) in …` (4 at `4e0e4e5` plus Task 5's helper test).

- [ ] **Step 4: Run the app tests.**

`Tools/test-app.sh` regenerates `App/MacAppDuplicator.xcodeproj` from `App/project.yml` with xcodegen, so the new version is in this build.

Run: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh 2>&1 | tee "${TMPDIR:-/tmp}/p6-app-tests.log" | tail -3`
Expected: the last line is `** TEST SUCCEEDED **`.

Run: `cd ~/Developer/MacAppDuplicator && grep -cE "Test Case .* passed" "${TMPDIR:-/tmp}/p6-app-tests.log"`
Expected: `361` (342 at `4e0e4e5` plus 19 new).

- [ ] **Step 5: Check the forbidden patterns across the whole phase.**

Run: `cd ~/Developer/MacAppDuplicator && git diff 4e0e4e5 -- '*.swift' | grep -E '^\+' | grep -nE 'try\?|@unchecked|swiftlint:disable|nonisolated\(unsafe\)'`
Expected: no output.

- [ ] **Step 6: Confirm only the version changed.**

Run: `cd ~/Developer/MacAppDuplicator && git status --short --untracked-files=no && git ls-files --others --exclude-standard -- App Launcher Packages Tests Tools WebShell docs/acceptance`
Expected:

```
 M App/project.yml
```

(The only output line; no untracked source, test or checklist file is left behind.)

- [ ] **Step 7: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add App/project.yml && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Release: 0.6.0 (5)" -m "Phase 6 helper: menu bar icon, New Window, erase on quit and the language check." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Run: `cd ~/Developer/MacAppDuplicator && git log -1 --format=%s`
Expected: `Release: 0.6.0 (5)`

### Deviations

- The brief's item 7 pairs the docs with the version bump; the bump is its own last task so the full suite runs once on the finished tree. Phase 5 did both in one commit (`a8eda17`).
- Only `App/project.yml` changes: `App/MacAppDuplicator.xcodeproj/` is gitignored (`.gitignore:15`) and `Tools/test-app.sh` and `Tools/build-app.sh` regenerate it.
- The engine version is not bumped, so the app does not offer Rebuild All; see Deferred.

## Self-review

### Spec coverage

| Spec section | What it asks for | Tasks |
|---|---|---|
| §3.4 step 5 (Dock Shortcut launch) | Start a detached helper from the same Launcher binary with `--helper`, only when the menu bar icon or erase-on-quit is on | 2 (`HelperPlan.isNeeded(for:)`, `HelperArguments`), 5 (`HelperLaunch` spawns with `posix_spawn` before `execve`), 10 (spec S1, S2 record `posix_spawn`) |
| §3.4 step 6 (System Launch) | The Launcher waits for the callback, then exits or stays as the helper | 5 (`HelperWatch`, erase path), 6 (System Launch helper in `HelperMenuBarRunner`), 10 (spec S3) |
| §4.3 erase-on-quit | Empty the data folder on quit; never a dangerous folder | 3 (`EraseOnQuitPolicy`, `EraseOnQuitPerformer`), 5 (erase after exec and exit, other-copy skip, gated integration test), 7 (`HelperEditorPolicy` erase check and Diagnostics row), 8 (toggle, confirmation, refusal message) |
| §4.5 language | `AppleLanguages` override with a valid code | 1 (`LanguageCode`, madctl `--language` check), 7 (Diagnostics `Language` row), 8 (field message, Save gating) |
| §4.6 helper role | argv with the start time, accessory app, status item with Show / New Window / Quit, `kqueue` watch, pid-reuse check, erase, started only when needed | 2 (argv, plan, environment, log lines), 4 (start-time reader, `ProcessWatcher`, `HelperWatchState`), 5 (`--helper` role, erase), 6 (`HelperStatusItem`, Show, New Window, Quit with SIGTERM then SIGKILL by start time, reopen), 10 (spec S4 rewrite: `posix_spawn`, full-colour icon) |
| §4.7 error handling | Failures are reported, not fatal | 5 (`helper spawn failed:`, erase refusals and skips logged), 6 (`helper show failed:`), 8 (refusal message in the editor) |
| §7 main app | Editor, wizard, Diagnostics, Known Limitations | 7 (`HelperEditorPolicy`, wizard New Window copy, profile row, preview helper line, Diagnostics rows), 8 (Launch and Advanced controls, confirmation, language check, Save gating), 9 (Known Limitations), 10 (spec S5 layout note) |
| §11 known limitations | New helper entries | 9 (six entries, 35 in total), 10 (README count) |
| §12 phases | Phase 6 scope, docs, version | 10 (acceptance checklist, README, spec), 11 (0.6.0 (5), full run) |

### Brief coverage

- Item 1, Core pure types: Tasks 1-4 (and Task 6's two `HelperPlan` functions).
- Item 2, `newWindowCommand` and madctl: Task 1.
- Item 3, Launcher helper role, process watcher, status item and runner: `ProcessWatcher` in Task 4 (in Core, not the Launcher, so XCTest reaches it); `HelperRole.swift` (the `--helper` entry point; argv parsed by Core's `HelperArguments` from Task 2) and `HelperRunner.swift` (watch loop, erase, Show, New Window, Quit) in Task 5; `HelperStatusItem` and `HelperMenuBarRunner` in Task 6.
- Item 4, gated integration test and watcher unit test: Task 5 (integration) and Task 4 (watcher).
- Item 5, App `HelperEditorPolicy`, Advanced controls and the confirmation: Tasks 7 and 8.
- Item 6, Known Limitations: Task 9.
- Item 7, docs and version bump last: Tasks 10 and 11.

### Placeholder scan

`grep -nE 'TBD|TODO|FIXME|similar to Task|add validation|implement later|fill in|appropriate error'` over this plan returned no lines before this section was added (this paragraph names the patterns, so a re-run matches it). Every code step holds complete Swift; every check has an exact command and expected output.

### Type consistency

A script matched every `Type.member` use of `HelperPlan`, `HelperLogLine`, `EraseOnQuitPolicy`, `EraseOnQuitPerformer`, `EraseOnQuitRefusal`, `EraseOnQuitOutcome`, `NewWindowCommandBuilder`, `LanguageCode`, `HelperMenuText`, `HelperEnvironment`, `HelperEditorPolicy`, `ProcessStartTime`, `HelperArguments`, `HelperWatchState` and `ProcessWatcher` in this plan (74 distinct members) against a `func`, `let`, `var` or `case` declaration in the plan: none is missing. Declarations by task: Task 1 `LanguageCode`, `NewWindowCommandBuilder`, `HelperMenuText`, `ShortcutConfig.newWindowCommand`; Task 2 `HelperPlan.isNeeded(for:)` and `eraseDataPath(for:)`, `ProcessStartTime`, `HelperArguments`, `HelperEnvironment`, `HelperLogLine`; Task 3 `EraseOnQuitRefusal`, `EraseOnQuitPolicy`, `EraseOnQuitOutcome`, `EraseOnQuitPerformer`; Task 4 the `ProcessStartTime` reader and `Comparison`, `ProcessWatchEvent`, `ProcessWatcherError`, `ProcessWatcher`, `HelperWatchState`, `LaunchLogger` `O_APPEND` writes; Task 5 (Launcher) `HelperLaunch`, `HelperSession`, `HelperWatchEnd`, `HelperWatch`, `HelperRunner`; Task 6 `HelperPlan.showsMenuBarIcon(for:)` and `newWindowArguments(for:targetPath:)`, `HelperStatusItem`, `HelperMenuBarSettings`, `HelperMenuBarRunner`; Task 7 `HelperEditorPolicy` and `EraseCheck`; Task 8 the view-private `PendingErase`. `ProcessWatcher` and `HelperWatch` are not `Sendable` (one owner each), and no task adds `@unchecked Sendable`, `try?` or an empty `catch`.

### Test count

| Suite | At `4e0e4e5` | After Phase 6 | New |
|---|---|---|---|
| DuplicatorCoreTests | 235 | 286 | 51 |
| WebShellTests | 56 | 56 | 0 |
| CompatProfilesTests | 37 | 37 | 0 |
| IntegrationTests (gated) | 4 | 5 | 1 |
| App (`Tools/test-app.sh`) | 342 | 361 | 19 |

## Acceptance gate

Phase 6 is done when all of these hold:

1. Tasks 1-11 are committed on `main` in order, each with its own checks passing.
2. Task 11 Steps 2-5 pass on the final tree: Core 286, WebShell 56, Compat 37, gated integration 5, app 361 passed test cases with `** TEST SUCCEEDED **`, and no forbidden pattern in the Swift lines added since `4e0e4e5`.
3. Mike runs `docs/acceptance/phase6-helper.md` on a Release build of the final commit and fills in its Record table with every step passing; item 2.6 records which reopen outcome happened instead of passing or failing.

No step in this plan pushes or tags; that stays with Mike.

## Deferred

- Copying a profile's `newWindowCommand` into a shortcut that already exists (a "copy from profile" action); Phase 6 copies it only when the wizard creates the shortcut.
- Bundled profiles with a `newWindowCommand`, for example `open -na {target} --args --user-data-dir={dataPath}` for Chromium browsers, after each is checked on a real install.
- Menu bar icon and Erase on quit in the New wizard; Phase 6 sets them in the editor only.
- Moving Appearance and Language from the Launch section to Advanced.
- An automated test of the status item and its menu (needs a UI test target); acceptance Steps 2 and 3 cover it by hand.
- An engine version bump with Rebuild All, so shortcuts made before 0.6.0 get the helper-capable Launcher without being saved again.
- A gentler Quit: `NSRunningApplication.terminate()` first (the app may ask about unsaved work), then SIGTERM and SIGKILL.
- A known-limitation entry for Quit discarding unsaved work, if the gentler Quit does not come first.
- Reopen routing for Dock Shortcut helpers, depending on the outcome acceptance 2.6 records.
