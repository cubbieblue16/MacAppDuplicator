# macOS App Duplicator Phase 3 Part 2 (Hardening) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish Phase 3 with the hardening carry-over from the Phase 2 reviews: a draft-driven icon preview, refusal of shortcuts as targets, slug de-duplication, generation-guarded scans and monitor refreshes, a self-cancelling `FolderWatcher`, a test host that leaves no preference residue, Phase 3 Known Limitations, the Phase 3 acceptance checklist, the profile-promotion procedure, README updates and version 0.3.0.

**Architecture:** Tasks 8–10 build on Phase 3 part 1 (`docs/superpowers/plans/2026-10-09-phase3-profiles.md`, Tasks 1–7, complete at `30ea974`). Task 8 adds three small pure services (`IconPreviewSource`, `TargetGuard`, `SlugAllocator`) under `App/Sources/Services` and wires them into the wizard, editor, sidebar and `ShortcutBuilder`, plus four UI nits. Task 9 is concurrency and hygiene: generation counters in `ShortcutLibrary` and `RunningShortcutMonitor`, an isolated `deinit` in `FolderWatcher`, window suppression under the test host and plist residue cleanup in `Tools/test-app.sh`, and the Settings signing-identity loading state. Task 10 is docs and metadata only. `ShortcutConfig.currentEngineVersion` stays `1`; `DuplicatorCore` and `CompatProfiles` are not modified.

**Tech Stack:** Swift 6 language mode (Xcode 27.0, Swift 6.4), macOS 26+ arm64, SwiftUI + AppKit (app), Foundation + Darwin (Core), Synchronization (`Mutex`), xcodegen 2.45.3, XCTest.

> **Scope note:** This file holds Tasks 8–10. Tasks 1–7 and the full File map live in `docs/superpowers/plans/2026-10-09-phase3-profiles.md`. The Global Constraints below are copied verbatim from that plan and bind every task here.

## Global Constraints

- Target macOS 26+, Apple Silicon only. Root package stays `swift-tools-version: 6.2`, `swiftLanguageModes: [.v6]`, `platforms: [.macOS(.v26)]`. The Xcode targets build `ARCHS = arm64`, `MACOSX_DEPLOYMENT_TARGET = 26.0`, `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`.
- DuplicatorCore imports Foundation, Security and Darwin only (no AppKit). The app may import AppKit and SwiftUI. XCTest only (no swift-testing). No new `try?` in app code except where the plan shows it; no empty `catch`, no `@unchecked Sendable`, no `swiftlint:disable`.
- Never copy, repackage, patch, inject into or re-sign the target app (spec §2). The only files the app writes are: shortcut bundles under the output folder (or a user-chosen export location), data folders under `~/Library/Application Support/App Duplicator/`, the launcher log folder `~/Library/Logs/App Duplicator/` (Open Logs Folder creates it when missing; the launcher writes the log files), the profiles cache `~/Library/Application Support/App Duplicator/profiles.json` (written only by Check Profile Updates), `UserDefaults` of `com.mikekuta.MacAppDuplicator`, and temporary files under `FileManager.default.temporaryDirectory`.
- Secrets never shown or logged unmasked by default: env values whose key matches `SecretMasking.secretKeyPattern` (`(?i)secret|token|key|password|passwd|credential`) are shown as `SecretMasking.maskedValue` (`••••••`) in the editor env table (until the per-row reveal toggle is on), in Diagnostics and in previews (spec §2, §7). The signing identity is referred to by display name only (spec §9); the app never prints certificate hashes.
- Shortcut `Info.plist` keeps the Phase 1 key set; `BundleWriter` still never writes `CFBundleURLTypes`, `CFBundleDocumentTypes`, `UTExportedTypeDeclarations` or `UTImportedTypeDeclarations`. Icons are copied, never symlinked.
- `ShortcutConfig.currentEngineVersion` stays `1` in Phase 2. New `ShortcutConfig` fields decode with defaults so the two existing shortcuts (`~/Applications/App Duplicator/Claude Work.app`, `Claude Personal.app`) still load: `iconMode` → `.copied`, `customIconPath` → nil, `homeSymlinkEntries` → nil.
- Bundle identifier `com.mikekuta.appduplicator.<slug>`; default data path `~/Library/Application Support/App Duplicator/<slug>`; default output `~/Applications/App Duplicator`; logs `~/Library/Logs/App Duplicator/<shortcut name>.log` (Phase 1 `LaunchLogger`).
- App bundle id `com.mikekuta.MacAppDuplicator`, product name and display name `macOS App Duplicator`, `PRODUCT_MODULE_NAME = MacAppDuplicator`, `LSApplicationCategoryType = public.app-category.utilities`, hardened runtime on, App Sandbox off, no entitlements file, no TCC-gated APIs (spec §9).
- UI copy is verbatim from spec §7 where the spec gives it: sidebar sections `Apps`, `Web Apps`, `Files & Folders`, `Commands`; icon modes `Copied from target`, `Custom file`, `Generated tile`; appearance options `Follow System`, `Light`, `Force dark (Chromium/Electron only, best effort)`; actions `Launch`, `Reveal in Finder`, `Regenerate`, `Duplicate`, `Export…`, `Delete`; toolbar `New`, `Rebuild All`; compat badges `Verified`, `Auto`, `HOME only`, `Unsupported`, `Unknown`; signing option `Ad-hoc`.
- Phase 2 implements shortcut kind `.app` only. The wizard shows the other kinds disabled with the hint `Coming in a later phase`. `Check Profile Updates`, the profiles URL setting and `Verified`/`Unsupported` badges are Phase 3; the menu bar icon and new-window command fields are stored but inert until Phase 6 (the editor says so inline).
- Tests never touch `/Applications`, `~/Applications`, the real output folder, the real `UserDefaults` suite or the two Claude shortcuts; every test writes under `makeTemporaryDirectory()` / `FileManager.default.temporaryDirectory` and uses `UserDefaults(suiteName:)` with a unique suite that it removes in `tearDown`. No test launches a shortcut or a target app.
- Every commit message ends with the line `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Repository `/Users/cubbieblue16/Developer/MacAppDuplicator`, branch `main`. Commit identity `git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com"`.
- Additive-only toward Phase 1: no existing public symbol, test or behaviour is removed or weakened. New Core API goes next to the existing files.
- Build-system conventions: `App/MacAppDuplicator.xcodeproj` is generated and git-ignored; `Tools/build-app.sh` and `Tools/test-app.sh` are the only documented ways to build and test the app. All `xcodebuild` runs use `-derivedDataPath .build/DerivedData` and `-destination 'platform=macOS,arch=arm64'`.
- `ShortcutConfig.currentEngineVersion` stays `1` in Phase 3: no Phase 3 change alters the written bundle layout, the shortcut `Info.plist` key set or the `MADConfig` keys, so Phase 3 marks no shortcut as needing a rebuild. The Launcher's masked argv logging reaches an existing shortcut only when that shortcut is Regenerated (Known Limitation `argument-logging`).
- Phase 3 ships `Check Profile Updates` (toolbar button, app menu item and the Settings `Check Now` button), the profiles URL setting and the `Verified`/`Unsupported` badges; this supersedes the Phase 2 deferral line above. Shortcut kinds other than `.app`, the menu bar icon and the new-window command stay exactly as Phase 2 left them.
- `CompatProfiles` imports Foundation and DuplicatorCore only. Only the app target, the app test target and `CompatProfilesTests` link it; the Launcher and `madctl` never do, so no shortcut bundle contains networking code.
- Fetched `profiles.json` is untrusted data: it is decoded with `JSONDecoder` only, never executed, never passed to a shell and never used to build a command line; every string is at most 2,048 characters and contains no NUL; counts are capped (500 apps, 200 web apps, 64 arguments and 64 environment entries per app, 64 extra hosts per web app); the file is at most 1,048,576 bytes; `schemaVersion` must be `1`; `newWindowCommand` is stored but inert until Phase 6; `webApps` is decoded and validated but has no UI until Phase 4. Profile `env` may not set `DYLD_*`, `LD_*`, `MAD_*`, `XRE_*`, `NODE_OPTIONS`, `ELECTRON_RUN_AS_NODE`, `JAVA_TOOL_OPTIONS`, `_JAVA_OPTIONS`, `JDK_JAVA_OPTIONS`, `HOME` or `CFFIXED_USER_HOME`, and profile `args` may not start (one or two dashes, any case) with the debugger, code-loading, sandbox or data-folder switches in `ProfilesDocument.refusedArgumentPattern` (Task 1). That deny-list is defence in depth; the main control is that profile values are copied only when a shortcut is created, shown (masked) on the wizard Review step and stay editable.
- Profile `env` and `args` are shown masked wherever they appear: env values whose key matches `SecretMasking.isSecretKey` show `SecretMasking.maskedValue`, and argument lists pass through `SecretMasking.maskArguments`. Diagnostics, the export notice, the wizard Review step and the Launcher log mask argv the same way.
- No network in tests and no test touches the real profiles cache: the app test host builds its `ProfilesModel` with `DisabledProfilesFetcher` and a cache path under `FileManager.default.temporaryDirectory`; package tests inject a mock `ProfilesFetching`. Tests never touch `/Applications` (writes), `~/Applications`, `UserDefaults.standard`, the real profiles cache or the network.
- Seed statuses: Claude (`com.anthropic.claudefordesktop`) is `verified`, the only entry with a real launch test on Mike's Mac; Terminal (`com.apple.Terminal`) is `partial` with notes `Apple platform binary, System Launch only.`; every other seed entry is `partial`. An entry becomes `verified` only through `docs/acceptance/profile-promotion.md` (spec §8).
- Compat badge copy is exact: `Verified`, `Auto`, `HOME only`, `Unsupported`, `Unknown` (spec §7).
- Profiles URL constant (`ProfilesConstants.defaultURLString`, the default of the Settings profiles URL): `https://raw.githubusercontent.com/cubbieblue16/MacAppDuplicator/main/Packages/CompatProfiles/Resources/profiles.json`. It answers HTTP 404 until the repository is public; that is expected and handled as an error message.
- Profile fetches: HTTPS only; host `raw.githubusercontent.com` only (port 443 or none, no user info) for the request and for every redirect; response capped at 1,048,576 bytes; ephemeral `URLSession` with no cookie storage and no URL cache; request timeout 20 s, resource timeout 60 s. A fetch happens only when the user chooses Check Profile Updates (spec §2).
- Export moves an item already at the chosen destination to the Trash (never deletes it) and puts it back if the export fails; the export sweep removes only `.<name>.mad-export-<UUID>` staging folders that a crashed export left in the destination folder.

---

## Inputs and conventions

- `$REPO` = `/Users/cubbieblue16/Developer/MacAppDuplicator`. All commands run from `$REPO`. The shell's cwd does not persist between tool calls; prefix every command with `cd "$REPO" &&`.
- Starting point: branch `main` at `42327e0` ("fix(app): re-review nits — product name, pluralization, build filter, delete guard"), clean tree, no remote. Baselines: `DuplicatorCoreTests` 111 tests, `IntegrationTests` 2 tests, `MacAppDuplicatorTests` 108 tests. `CompatProfilesTests` does not exist yet.
- Spec: `docs/superpowers/specs/2026-10-09-macos-app-duplicator-design.md` (§2 offline-by-default and secret regex, §3.1 component table, §4.3 data modes, §4.4 argv/env merge order, §7 main app, §8 `profiles.json`, §9 security, §10 tests, §11 known limitations, §12 item 3).
- Test commands used by every task (expected counts are given per step):
  - Profiles package: `cd "$REPO" && swift test --filter CompatProfilesTests 2>&1 | grep -E 'Executed|error:' | tail -3` prints `Executed N tests, with 0 failures`.
  - Core: `cd "$REPO" && swift test --filter DuplicatorCoreTests 2>&1 | grep -E 'Executed|error:' | tail -3` prints `Executed N tests, with 0 failures`.
  - App, one class: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/<ClassName> 2>&1 | tail -4` prints `Test Suite '<ClassName>' passed` and `** TEST SUCCEEDED **`.
  - App, everything: `cd "$REPO" && Tools/test-app.sh 2>&1 | tail -4` prints `** TEST SUCCEEDED **`; count passing tests with `cd "$REPO" && Tools/test-app.sh 2>&1 | grep -cE "Test Case '.*' passed"`.
  - `Tools/test-app.sh` regenerates `App/MacAppDuplicator.xcodeproj` with xcodegen on every run, so new files under `App/Sources` and `App/Tests` are picked up without editing `App/project.yml`; only new package products and resources need `project.yml` edits (Task 3).
- DuplicatorCore API consumed (Phase 1 and 2, unchanged unless a task says otherwise): `ShortcutConfig` (init labels in order `kind: = .app, name:, slug:, bundleIdentifier:, targetPath:, targetBundleIdentifier:, launchMode: = .dockShortcut, dataMode: = .auto, dataPath: = nil, environment: = [:], arguments: = [], appearance: = .system, languageCode: = nil, eraseOnQuit: = false, menuBarIcon: = false, iconMode: = .copied, customIconPath: = nil, homeSymlinkEntries: = nil, engineVersion: = currentEngineVersion`; statics `currentEngineVersion`, `slug(for:)`, `bundleIdentifier(forSlug:)`, `fileSystemName(for:)`), `InspectedApp(bundleURL:bundleIdentifier:name:version:executableURL:family:isSandboxed:iconFileURL:isPlatformBinary:hasLaunchConstraints:lsEnvironment:warnings:)`, `AppFamily` (`todesktop`, `electron`, `chromium`, `firefox`, `eclipse`, `native`), `AppInspector().inspect(appAt:)`, `TargetResolver().resolve(config:) throws -> URL`, `DataSeparationPlanner().plan(app:config:baseEnvironment:shortcutBundleURL:) -> LaunchPlan`, `SecretMasking` (`maskedValue`, `secretKeyPattern`, `isSecretKey(_:)`, `mask(_ env: [String: String]) -> [String: String]`), `LaunchLogger(name:directory:maxBytes:)` with `log(_ message: String)`.
- App code consumed (module `MacAppDuplicator`): `AppState` (`App/Sources/App/AppState.swift`), `AppSettings` (`App/Sources/Model/AppSettings.swift`), `ShortcutLibrary`, `ShortcutRecord`, `LibraryScanner`, `RunningShortcutMonitor`, `FolderWatcher` (`App/Sources/Model/`), `ShortcutBuilder`, `CompatBadge`, `LaunchPlanPreview`, `ExportInstructions`, `DataPathGuard`, `CanonicalPath`, `IconRenderer`, `IconResolver`, `ShortcutConfig+DefaultDataPath` (`App/Sources/Services/`), `DiagnosticsModel` (inside `App/Sources/Views/DiagnosticsView.swift`), `LaunchEnvironment`, `KnownLimitations` (`App/Sources/App/`). Each task's **Interfaces** block repeats the exact signatures it uses.
- App test helpers in `App/Tests/TestSupport/AppTestSupport.swift`: `makeAppTemporaryDirectory()`, `writeShortcutBundle(named:in:config:engineVersion:withIcon:extraInfo:)`, `writeFakeTarget(named:bundleIdentifier:version:in:)`, `makeConfig(name:targetPath:targetBundleIdentifier:kind:)`, `makeTestDefaults()`, `XCTestCase.waitUntil(timeout:_:)`. Core tests use `makeTemporaryDirectory()` from `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/TestSupport.swift`. `CompatProfilesTests` gets its own `TestSupport.swift` (Task 1).
- Concurrency rules that bite in this phase: `FileManager` is not `Sendable` (a `Sendable` type uses `FileManager.default` at the point of use instead of storing one); `Mutex` (Synchronization) is `~Copyable`, so it is wrapped in a `final class …: Sendable`; a `Sendable` final class may subclass `NSObject` when its stored properties are `let` and `Sendable`; `DispatchSemaphore` is `Sendable`; anything captured by `Task.detached` must be `Sendable`; main-actor types are never default argument values (use an optional parameter and `?? .inert()` in the body).
- Seed bundle identifiers: read-only `mdls -name kMDItemCFBundleIdentifier` on the copies installed under `/Applications` confirmed Claude (`com.anthropic.claudefordesktop`), Google Chrome (`com.google.Chrome`), Brave Browser (`com.brave.Browser`), Discord (`com.hnc.Discord`), Obsidian (`md.obsidian`), Telegram (`ru.keepcoder.Telegram`, App Store build, sandboxed), Terminal (`com.apple.Terminal`) and Xcode (`com.apple.dt.Xcode`). Not installed, so the well-known public identifiers are used and `docs/acceptance/profile-promotion.md` makes re-checking the identifier the first promotion step: Microsoft Edge (`com.microsoft.edgemac`), Firefox (`org.mozilla.firefox`), Visual Studio Code (`com.microsoft.VSCode`), Cursor (`com.todesktop.230313mzl4w4u92`), Slack (`com.tinyspeck.slackmacgap`), Plex (`tv.plex.desktop`), Spotify (`com.spotify.client`), Signal (`org.whispersystems.signal-desktop`), Ghostty (`com.mitchellh.ghostty`), iTerm2 (`com.googlecode.iterm2`).


---


### Task 8: Icon preview from the draft, shortcut-as-target refusal, slug de-duplication and wizard/editor nits

**Files:**
- Create: `App/Sources/Services/IconPreviewSource.swift`
- Create: `App/Sources/Views/IconPreview.swift`
- Create: `App/Sources/Services/TargetGuard.swift`
- Create: `App/Sources/Services/SlugAllocator.swift`
- Modify: `App/Sources/Services/ShortcutBuilder.swift`
- Modify: `App/Sources/Views/EditorSections.swift`
- Modify: `App/Sources/Views/ShortcutEditorView.swift`
- Modify: `App/Sources/Views/Wizard/WizardModel.swift`
- Modify: `App/Sources/Views/ContentView.swift`
- Modify: `App/Sources/Views/SettingsView.swift`
- Modify: `App/Sources/Views/Wizard/NewShortcutWizard.swift`
- Modify: `App/Sources/Views/Wizard/WizardSteps.swift`
- Modify: `App/Sources/Views/Wizard/InstalledAppsGrid.swift`
- Modify: `App/Sources/App/AppState.swift`
- Modify: `App/Sources/App/MacAppDuplicatorApp.swift`
- Test: `App/Tests/Services/IconPreviewSourceTests.swift`
- Test: `App/Tests/Services/TargetGuardTests.swift`
- Test: `App/Tests/Services/SlugAllocatorTests.swift`
- Test: `App/Tests/Services/ShortcutBuilderTests.swift`
- Test: `App/Tests/Wizard/WizardModelTests.swift`

**Interfaces:**
- Consumes (all existing, unchanged):
  - Core: `ShortcutConfig.slug(for:) -> String`, `ShortcutConfig.bundleIdentifier(forSlug:) -> String`, `ShortcutConfig.infoPlistKey` (the `MADConfig` key `LibraryScanner.record(forBundleAt:fileManager:)` reads), `ShortcutConfig.defaultDataPath(forSlug:home:) -> String`, `InspectedApp.iconFileURL: URL?`, `IconMode` (`.copied`, `.custom`, `.generated`).
  - App: `InstalledApps.infoDictionary(ofAppAt: URL) -> [String: Any]?`, `IconRenderer.initials(for: String) -> String`, `IconRenderer.generatedTile(initials: String, size: Int) -> CGImage`, `ShortcutRecord` (`bundleURL: URL`, `config: ShortcutConfig`, `iconURL: URL?`), `LibraryScanner.record(forBundleAt:fileManager:) throws -> ShortcutRecord`.
  - Tests: `makeAppTemporaryDirectory()`, `writeShortcutBundle(named:in:config:engineVersion:withIcon:extraInfo:)`, `writeFakeTarget(named:bundleIdentifier:version:in:)`, `makeConfig(name:targetPath:targetBundleIdentifier:kind:)`.
- Produces:
  - `enum SlugAllocator` (`App/Sources/Services/SlugAllocator.swift`): `static func uniqueSlug(proposed: String, taken: Set<String>) -> String`; `static func takenSlugs(in records: [ShortcutRecord], excluding bundleURL: URL? = nil) -> Set<String>`.
  - `enum TargetGuard` (`App/Sources/Services/TargetGuard.swift`): `static func isShortcutBundle(at url: URL) -> Bool`; `static func refusalMessage(forAppAt url: URL) -> String` returning `"<name> is an App Duplicator shortcut, not an app. Choose the original app instead."` where `<name>` is the bundle file name without `.app`.
  - `enum IconPreviewSource: Equatable, Sendable` (`App/Sources/Services/IconPreviewSource.swift`): cases `file(URL)`, `generated(initials: String)`, `placeholder`; `static func resolve(draft: ShortcutConfig, saved: ShortcutConfig, savedIconURL: URL?, targetIconURL: URL?) -> IconPreviewSource`.
  - `struct IconPreview: View` (`App/Sources/Views/IconPreview.swift`): `let source: IconPreviewSource`; `static func image(for source: IconPreviewSource) -> NSImage?`.
  - `ShortcutBuilder.BuilderError.targetIsShortcut(String)` (new case; payload = the refused target path; `errorDescription` = `TargetGuard.refusalMessage(forAppAt:)`). `ShortcutBuilder.write(config:in:)` (private; behind `create`, `regenerate` and `duplicate`) throws it.
  - `ShortcutBuilder.duplicate(record:newName:in:takenSlugs:)` — new required `takenSlugs: Set<String>` parameter; the copy's slug is `SlugAllocator.uniqueSlug(proposed: ShortcutConfig.slug(for: newName), taken: takenSlugs)`.
  - `WizardModel` (`App/Sources/Views/Wizard/WizardModel.swift`): `init(prefillTarget: URL? = nil, takenSlugs: Set<String> = [], profileLookup: @escaping @MainActor (String) -> AppProfile? = { _ in nil })`; `var slug: String` (the de-duplicated slug `makeConfig()` uses); `static func filteredApps(_ apps: [InstalledApp], query: String) -> [InstalledApp]`; `static func showsNoMatches(apps: [InstalledApp], query: String) -> Bool`; `selectTarget(_:)` refuses a shortcut (clears `targetURL`/`inspected`, sets `inspectError` to the refusal message).

- [ ] **Step 1: Write the failing slug allocator tests (M6)**

Create `App/Tests/Services/SlugAllocatorTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class SlugAllocatorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try makeAppTemporaryDirectory() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    func testFreeSlugIsReturnedUnchanged() {
        XCTAssertEqual(SlugAllocator.uniqueSlug(proposed: "claude-work", taken: []), "claude-work")
        XCTAssertEqual(SlugAllocator.uniqueSlug(proposed: "claude-work", taken: ["claude-home"]), "claude-work")
    }

    func testTakenSlugGetsTheSuffixTwo() {
        XCTAssertEqual(SlugAllocator.uniqueSlug(proposed: "claude-work", taken: ["claude-work"]), "claude-work-2")
    }

    func testSkipsToThreeWhenTwoIsTaken() {
        XCTAssertEqual(SlugAllocator.uniqueSlug(proposed: "claude-work", taken: ["claude-work", "claude-work-2"]), "claude-work-3")
    }

    func testTheFirstFreeSuffixWins() {
        XCTAssertEqual(SlugAllocator.uniqueSlug(proposed: "claude-work", taken: ["claude-work", "claude-work-3"]), "claude-work-2")
    }

    /// Launch Services compares bundle ids case-insensitively and the default data folder sits on a case-insensitive
    /// volume, so a hand-edited `Claude-Work` already occupies `claude-work`.
    func testMatchingIgnoresCase() {
        XCTAssertEqual(SlugAllocator.uniqueSlug(proposed: "claude-work", taken: ["Claude-Work"]), "claude-work-2")
    }

    func testTakenSlugsExcludesTheRecordBeingEdited() throws {
        var work = makeConfig(name: "Claude Work")
        work.slug = "claude-work"
        var home = makeConfig(name: "Claude Home")
        home.slug = "claude-home"
        let workURL = try writeShortcutBundle(named: "Claude Work", in: dir, config: work)
        let homeURL = try writeShortcutBundle(named: "Claude Home", in: dir, config: home)
        let records = [try LibraryScanner.record(forBundleAt: workURL), try LibraryScanner.record(forBundleAt: homeURL)]

        XCTAssertEqual(SlugAllocator.takenSlugs(in: records), ["claude-work", "claude-home"])
        let taken = SlugAllocator.takenSlugs(in: records, excluding: workURL)
        XCTAssertEqual(taken, ["claude-home"])
        // Renaming "Claude Work" to "Claude-Work" folds back to its own slug: it must not collide with itself.
        XCTAssertEqual(SlugAllocator.uniqueSlug(proposed: "claude-work", taken: taken), "claude-work")
    }
}
```

- [ ] **Step 2: Run the slug allocator tests to verify they fail**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/SlugAllocatorTests 2>&1 | tail -4`
Expected: `** TEST FAILED **`; the build log above it reports `cannot find 'SlugAllocator' in scope`.

- [ ] **Step 3: Implement the slug allocator**

Create `App/Sources/Services/SlugAllocator.swift`:

```swift
import DuplicatorCore
import Foundation

/// Gives every shortcut in the library its own slug (final review M6). `ShortcutConfig.slug(for:)` folds
/// "Claude Work", "Claude-Work" and "claude  work" to the same `claude-work`; two shortcuts on one slug would share a
/// bundle id and a default data folder, which silently defeats separation. Core's `slug(for:)` stays unchanged: only
/// the app knows the library.
enum SlugAllocator {
    /// `proposed` when no slug in `taken` matches it, else `proposed-2`, `proposed-3`, … (the first free one).
    /// Matching ignores case: Launch Services compares bundle ids case-insensitively and the default data folder sits
    /// on a case-insensitive volume, so `Claude-Work` already occupies `claude-work`.
    static func uniqueSlug(proposed: String, taken: Set<String>) -> String {
        let occupied = Set(taken.map { $0.lowercased() })
        guard occupied.contains(proposed.lowercased()) else { return proposed }
        var suffix = 2
        while occupied.contains("\(proposed)-\(suffix)".lowercased()) { suffix += 1 }
        return "\(proposed)-\(suffix)"
    }

    /// The slugs `records` already use. `excluding` names the bundle being edited, so a rename may keep its own slug.
    static func takenSlugs(in records: [ShortcutRecord], excluding bundleURL: URL? = nil) -> Set<String> {
        let excluded = bundleURL?.standardizedFileURL
        return Set(records.filter { $0.bundleURL.standardizedFileURL != excluded }.map(\.config.slug))
    }
}
```

- [ ] **Step 4: Run the slug allocator tests to verify they pass**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/SlugAllocatorTests 2>&1 | tail -4`
Expected: `Test Suite 'SlugAllocatorTests' passed` and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Write the failing target guard tests (M5)**

Create `App/Tests/Services/TargetGuardTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class TargetGuardTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try makeAppTemporaryDirectory() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    func testABundleCarryingMADConfigIsRefused() throws {
        let shortcut = try writeShortcutBundle(named: "Claude Work", in: dir, config: makeConfig(name: "Claude Work"))
        XCTAssertTrue(TargetGuard.isShortcutBundle(at: shortcut))
    }

    func testAPlainAppIsAccepted() throws {
        let app = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "1.0", in: dir)
        XCTAssertFalse(TargetGuard.isShortcutBundle(at: app))
    }

    func testABundleWithoutInfoPlistIsNotAShortcut() throws {
        let bare = dir.appending(path: "Bare.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        XCTAssertFalse(TargetGuard.isShortcutBundle(at: dir.appending(path: "Bare.app", directoryHint: .isDirectory)))
        XCTAssertFalse(TargetGuard.isShortcutBundle(at: dir.appending(path: "Missing.app", directoryHint: .isDirectory)))
    }

    func testRefusalMessageNamesTheBundle() {
        let url = URL(fileURLWithPath: "/Users/someone/Applications/Claude Work.app")
        XCTAssertEqual(
            TargetGuard.refusalMessage(forAppAt: url),
            "Claude Work is an App Duplicator shortcut, not an app. Choose the original app instead.")
    }
}
```

- [ ] **Step 6: Run the target guard tests to verify they fail**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/TargetGuardTests 2>&1 | tail -4`
Expected: `** TEST FAILED **`; the build log above it reports `cannot find 'TargetGuard' in scope`.

- [ ] **Step 7: Implement the target guard**

Create `App/Sources/Services/TargetGuard.swift`:

```swift
import DuplicatorCore
import Foundation

/// Refuses App Duplicator shortcuts as targets (final review M5). A shortcut-to-shortcut target chains launchers, and
/// a shortcut that targets itself makes its launcher exec its own binary again. The wizard, the editor's Target section
/// and the sidebar drop path check this before accepting a target; `ShortcutBuilder` checks it again before every write.
enum TargetGuard {
    /// True when the bundle's Info.plist carries `MADConfig` (`ShortcutConfig.infoPlistKey`, the key `LibraryScanner`
    /// reads to recognise a shortcut). Any value counts, even one that no longer decodes: that bundle is still a
    /// launcher. A missing or unreadable Info.plist is not a shortcut.
    static func isShortcutBundle(at url: URL) -> Bool {
        InstalledApps.infoDictionary(ofAppAt: url)?[ShortcutConfig.infoPlistKey] != nil
    }

    /// The sentence shown when a shortcut is offered as a target; the name is the bundle's file name without `.app`.
    static func refusalMessage(forAppAt url: URL) -> String {
        "\(url.deletingPathExtension().lastPathComponent) is an App Duplicator shortcut, not an app. Choose the original app instead."
    }
}
```

- [ ] **Step 8: Run the target guard tests to verify they pass**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/TargetGuardTests 2>&1 | tail -4`
Expected: `Test Suite 'TargetGuardTests' passed` and `** TEST SUCCEEDED **`.

- [ ] **Step 9: Write the failing icon preview source tests (M4)**

Create `App/Tests/Services/IconPreviewSourceTests.swift`. The resolver is pure, so the URLs below are never opened:

```swift
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class IconPreviewSourceTests: XCTestCase {
    private let savedIcon = URL(fileURLWithPath: "/nonexistent/Claude Work.app/Contents/Resources/AppIcon.icns")
    private let targetIcon = URL(fileURLWithPath: "/nonexistent/Target.app/Contents/Resources/Target.icns")

    private func config(_ mode: IconMode, custom: String? = nil, name: String = "Claude Work", target: String = "/Applications/Target.app") -> ShortcutConfig {
        var c = makeConfig(name: name, targetPath: target)
        c.iconMode = mode
        c.customIconPath = custom
        return c
    }

    /// Both icon files present; the two nil cases call `IconPreviewSource.resolve` directly.
    private func resolve(draft: ShortcutConfig, saved: ShortcutConfig) -> IconPreviewSource {
        IconPreviewSource.resolve(draft: draft, saved: saved, savedIconURL: savedIcon, targetIconURL: targetIcon)
    }

    // MARK: copied

    func testCopiedSavedUsesTheSavedIcon() {
        XCTAssertEqual(resolve(draft: config(.copied), saved: config(.copied)), .file(savedIcon))
    }

    func testCopiedSavedSurvivesARename() {
        XCTAssertEqual(resolve(draft: config(.copied, name: "Claude Home"), saved: config(.copied)), .file(savedIcon))
    }

    func testCopiedDraftUsesTheTargetsIcon() {
        XCTAssertEqual(resolve(draft: config(.copied), saved: config(.generated)), .file(targetIcon))
    }

    func testCopiedDraftWithANewTargetUsesThatTargetsIcon() {
        XCTAssertEqual(resolve(draft: config(.copied, target: "/Applications/Other.app"), saved: config(.copied)), .file(targetIcon))
    }

    func testCopiedDraftWithoutATargetIconIsAPlaceholder() {
        let source = IconPreviewSource.resolve(draft: config(.copied), saved: config(.generated), savedIconURL: savedIcon, targetIconURL: nil)
        XCTAssertEqual(source, .placeholder)
    }

    // MARK: custom

    func testCustomSavedUsesTheSavedIcon() {
        let saved = config(.custom, custom: "/Users/someone/Pictures/work.png")
        XCTAssertEqual(resolve(draft: saved, saved: saved), .file(savedIcon))
    }

    func testCustomDraftUsesTheChosenFile() {
        let source = resolve(draft: config(.custom, custom: "/Users/someone/Pictures/new.png"), saved: config(.custom, custom: "/Users/someone/Pictures/work.png"))
        XCTAssertEqual(source, .file(URL(fileURLWithPath: "/Users/someone/Pictures/new.png")))
    }

    func testCustomDraftWithoutAFileIsAPlaceholder() {
        XCTAssertEqual(resolve(draft: config(.custom), saved: config(.copied)), .placeholder)
    }

    // MARK: generated

    func testGeneratedSavedUsesTheSavedIcon() {
        XCTAssertEqual(resolve(draft: config(.generated), saved: config(.generated)), .file(savedIcon))
    }

    func testGeneratedDraftAfterAModeSwitchRendersTheInitials() {
        XCTAssertEqual(resolve(draft: config(.generated), saved: config(.copied)), .generated(initials: IconRenderer.initials(for: "Claude Work")))
    }

    func testGeneratedDraftWithNewInitialsRendersThem() {
        let source = resolve(draft: config(.generated, name: "Personal Mail"), saved: config(.generated))
        XCTAssertEqual(source, .generated(initials: IconRenderer.initials(for: "Personal Mail")))
    }

    // MARK: no saved icon file

    func testAnUnchangedDraftWithoutASavedIconPreviewsFromTheDraft() {
        let source = IconPreviewSource.resolve(draft: config(.generated), saved: config(.generated), savedIconURL: nil, targetIconURL: nil)
        XCTAssertEqual(source, .generated(initials: IconRenderer.initials(for: "Claude Work")))
    }
}
```

- [ ] **Step 10: Run the icon preview source tests to verify they fail**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/IconPreviewSourceTests 2>&1 | tail -4`
Expected: `** TEST FAILED **`; the build log above it reports `cannot find type 'IconPreviewSource' in scope`.

- [ ] **Step 11: Implement the icon preview source**

Create `App/Sources/Services/IconPreviewSource.swift`:

```swift
import DuplicatorCore
import Foundation

/// What the editor's icon preview draws (final review M4): the draft's icon, not only the one saved in the bundle.
/// The saved `AppIcon.icns` is shown while the draft's icon inputs still match the saved config, because it is exactly
/// what Save would write again; any change to those inputs previews from the draft instead.
enum IconPreviewSource: Equatable, Sendable {
    /// Draw the image file at this URL (`.icns`, `.png`, `.jpeg` or `.tiff`).
    case file(URL)
    /// Draw `IconRenderer.generatedTile(initials:size:)` for these initials.
    case generated(initials: String)
    /// Nothing to draw: custom mode without a file, or a target with no icon file (or not inspected yet).
    case placeholder

    /// - Parameters:
    ///   - draft: the editor's unsaved config.
    ///   - saved: the config the bundle was last written with (`ShortcutRecord.config`).
    ///   - savedIconURL: the bundle's `AppIcon.icns` (`ShortcutRecord.iconURL`), nil when it has none.
    ///   - targetIconURL: `InspectedApp.iconFileURL` of the draft's target, nil while it is inspected or when it has none.
    static func resolve(draft: ShortcutConfig, saved: ShortcutConfig, savedIconURL: URL?, targetIconURL: URL?) -> IconPreviewSource {
        if let savedIconURL, iconInputsMatch(draft, saved) { return .file(savedIconURL) }
        switch draft.iconMode {
        case .copied:
            guard let targetIconURL else { return .placeholder }
            return .file(targetIconURL)
        case .custom:
            guard let path = draft.customIconPath, !path.isEmpty else { return .placeholder }
            return .file(URL(fileURLWithPath: path))
        case .generated:
            return .generated(initials: IconRenderer.initials(for: draft.name))
        }
    }

    /// True when Save would render the icon the bundle already has: the same mode and the same input for that mode
    /// (the target for `.copied`, the file for `.custom`, the initials for `.generated`).
    private static func iconInputsMatch(_ draft: ShortcutConfig, _ saved: ShortcutConfig) -> Bool {
        guard draft.iconMode == saved.iconMode else { return false }
        switch draft.iconMode {
        case .copied: return draft.targetPath == saved.targetPath
        case .custom: return draft.customIconPath == saved.customIconPath
        case .generated: return IconRenderer.initials(for: draft.name) == IconRenderer.initials(for: saved.name)
        }
    }
}
```

- [ ] **Step 12: Run the icon preview source tests to verify they pass**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/IconPreviewSourceTests 2>&1 | tail -4`
Expected: `Test Suite 'IconPreviewSourceTests' passed` and `** TEST SUCCEEDED **`.

- [ ] **Step 13: Write the failing builder tests (M5 last line of defence, M6 duplicate)**

In `App/Tests/Services/ShortcutBuilderTests.swift`, `testDuplicateCreatesSecondBundleWithNewIdentity` calls `duplicate` without the new parameter. Replace its line

```swift
        let second = try builder.duplicate(record: record, newName: "Target Personal", in: out)
```

with

```swift
        let second = try builder.duplicate(record: record, newName: "Target Personal", in: out, takenSlugs: [record.config.slug])
```

Then add these three tests inside `ShortcutBuilderTests`, directly after `testDuplicateCreatesSecondBundleWithNewIdentity`:

```swift
    func testCreateRefusesAShortcutAsTheTarget() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let shortcut = try builder.create(config: config(), in: out)
        var chained = config(name: "Chained")
        chained.targetPath = shortcut.path

        XCTAssertThrowsError(try builder.create(config: chained, in: out)) { error in
            guard case ShortcutBuilder.BuilderError.targetIsShortcut(let path) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertEqual(path, shortcut.path)
            XCTAssertEqual(error.localizedDescription, "Target Work is an App Duplicator shortcut, not an app. Choose the original app instead.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appending(path: "Chained.app").path), "nothing is written for a refused target")
    }

    func testRegenerateRefusesTheShortcutItselfAsTheTarget() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        var selfTarget = record.config
        selfTarget.targetPath = bundle.path

        XCTAssertThrowsError(try builder.regenerate(record: record, config: selfTarget)) { error in
            guard case ShortcutBuilder.BuilderError.targetIsShortcut = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertEqual(try LibraryScanner.record(forBundleAt: bundle).config.targetPath, record.config.targetPath, "the refused write leaves the bundle as it was")
    }

    func testDuplicateDeDuplicatesTheSlugAgainstTheLibrary() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let first = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: first)
        // "Target-Work" gets its own file name but folds to the original's slug.
        XCTAssertEqual(ShortcutConfig.slug(for: "Target-Work"), record.config.slug, "precondition: the names collide on the slug")

        let second = try builder.duplicate(record: record, newName: "Target-Work", in: out, takenSlugs: [record.config.slug])
        let copy = try LibraryScanner.record(forBundleAt: second)
        let expected = "\(record.config.slug)-2"
        XCTAssertEqual(second.lastPathComponent, "Target-Work.app")
        XCTAssertEqual(copy.config.slug, expected)
        XCTAssertEqual(copy.config.bundleIdentifier, ShortcutConfig.bundleIdentifier(forSlug: expected))
        XCTAssertEqual(copy.config.dataPath, ShortcutConfig.defaultDataPath(forSlug: expected, home: FileManager.default.homeDirectoryForCurrentUser))
        XCTAssertNotEqual(copy.config.bundleIdentifier, record.config.bundleIdentifier)
    }
```

- [ ] **Step 14: Run the builder tests to verify they fail**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/ShortcutBuilderTests 2>&1 | tail -4`
Expected: `** TEST FAILED **`; the build log above it reports `extra argument 'takenSlugs' in call` and `type 'ShortcutBuilder.BuilderError' has no member 'targetIsShortcut'`.

- [ ] **Step 15: Refuse shortcut targets in the builder and de-duplicate the duplicate's slug**

In `App/Sources/Services/ShortcutBuilder.swift`, make three edits.

(a) Add the case to `BuilderError`. Replace

```swift
        case exportOverlapsTarget(URL)

        var errorDescription: String? {
```

with

```swift
        case exportOverlapsTarget(URL)
        /// The target is an App Duplicator shortcut (final review M5); carries the refused target path.
        case targetIsShortcut(String)

        var errorDescription: String? {
```

and replace

```swift
            case .exportOverlapsTarget(let url): "Cannot export to \(url.path): it is, contains or is inside the target app."
```

with

```swift
            case .exportOverlapsTarget(let url): "Cannot export to \(url.path): it is, contains or is inside the target app."
            case .targetIsShortcut(let path): TargetGuard.refusalMessage(forAppAt: URL(fileURLWithPath: path))
```

(b) Replace the whole `duplicate` method (doc comment included) with:

```swift
    /// A new shortcut with the same target and launch settings, its own slug, bundle id and default data folder.
    /// `takenSlugs` are the slugs the library already uses (`SlugAllocator.takenSlugs(in:)`); a name that folds onto
    /// one of them, or onto the original's own slug, gets `-2`, `-3`, … (final review M6). The nil data path resolves
    /// to the final slug's default folder at write time.
    func duplicate(record: ShortcutRecord, newName: String, in directory: URL, takenSlugs: Set<String>) throws -> URL {
        var config = record.config
        config.name = newName
        config.slug = SlugAllocator.uniqueSlug(proposed: ShortcutConfig.slug(for: newName), taken: takenSlugs.union([record.config.slug]))
        config.bundleIdentifier = ShortcutConfig.bundleIdentifier(forSlug: config.slug)
        config.dataPath = nil
        return try create(config: config, in: directory)
    }
```

(c) In `write(config:in:)`, `create`, `regenerate` and `duplicate` all pass through here, so this is the last line of defence behind the UI checks. Replace

```swift
        guard fileManager.fileExists(atPath: targetURL.path) else { throw BuilderError.targetMissing(config.targetPath) }
```

with

```swift
        guard fileManager.fileExists(atPath: targetURL.path) else { throw BuilderError.targetMissing(config.targetPath) }
        // Final review M5: a shortcut target chains launchers, and a self-target makes the launcher exec itself again.
        guard !TargetGuard.isShortcutBundle(at: targetURL) else { throw BuilderError.targetIsShortcut(config.targetPath) }
```

In `App/Sources/App/AppState.swift`, `duplicate(_:newName:)` passes the library's slugs. Replace

```swift
            let url = try builder.duplicate(record: record, newName: newName, in: record.bundleURL.deletingLastPathComponent())
```

with

```swift
            let url = try builder.duplicate(
                record: record, newName: newName, in: record.bundleURL.deletingLastPathComponent(),
                takenSlugs: SlugAllocator.takenSlugs(in: library.records))
```

- [ ] **Step 16: Run the builder tests to verify they pass**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/ShortcutBuilderTests 2>&1 | tail -4`
Expected: `Test Suite 'ShortcutBuilderTests' passed` and `** TEST SUCCEEDED **`.

- [ ] **Step 17: Write the failing wizard model tests (M5 refusal, M6 slug, search empty state)**

Add these tests inside `WizardModelTests` in `App/Tests/Wizard/WizardModelTests.swift` (the class is already `@MainActor`; `dir` and `target` come from its `setUp`), directly after `testMakeConfigDerivesSlugAndBundleIdentifier`:

```swift
    func testAShortcutIsRefusedAsTheTargetWithTheExactMessage() throws {
        let shortcut = try writeShortcutBundle(named: "Claude Work", in: dir, config: makeConfig(name: "Claude Work", targetPath: target.path))
        let model = WizardModel()
        model.selectTarget(target)
        XCTAssertNotNil(model.inspected, "precondition: a real app is accepted")

        model.selectTarget(shortcut)
        XCTAssertNil(model.targetURL)
        XCTAssertNil(model.inspected)
        XCTAssertNil(model.profile)
        XCTAssertEqual(model.inspectError, "Claude Work is an App Duplicator shortcut, not an app. Choose the original app instead.")
        model.step = .target
        XCTAssertFalse(model.canAdvance)
    }

    func testAShortcutPrefillIsRefusedAndStaysOnTheFirstStep() throws {
        let shortcut = try writeShortcutBundle(named: "Claude Work", in: dir, config: makeConfig(name: "Claude Work", targetPath: target.path))
        let model = WizardModel(prefillTarget: shortcut)
        XCTAssertEqual(model.step, .kind)
        XCTAssertNil(model.inspected)
        XCTAssertEqual(model.inspectError, "Claude Work is an App Duplicator shortcut, not an app. Choose the original app instead.")
    }

    func testMakeConfigStepsAroundTakenSlugs() {
        XCTAssertEqual(ShortcutConfig.slug(for: "Claude-Work"), "claude-work", "precondition: the name folds to a taken slug")
        let model = WizardModel(takenSlugs: ["claude-work", "claude-work-2"])
        model.selectTarget(target)
        model.name = "Claude-Work"

        let config = model.makeConfig()
        XCTAssertEqual(model.slug, "claude-work-3")
        XCTAssertEqual(config.slug, "claude-work-3")
        XCTAssertEqual(config.bundleIdentifier, ShortcutConfig.bundleIdentifier(forSlug: "claude-work-3"))
        XCTAssertNil(config.dataPath, "the default data folder stays nil until the builder resolves it from the final slug")
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        XCTAssertEqual(config.resolvingDefaultDataPath(home: home).dataPath, ShortcutConfig.defaultDataPath(forSlug: "claude-work-3", home: home))
    }

    func testAFreeSlugIsKeptAsIs() {
        let model = WizardModel(takenSlugs: ["claude-home"])
        model.name = "Claude Work"
        XCTAssertEqual(model.slug, ShortcutConfig.slug(for: "Claude Work"))
    }

    func testSearchDistinguishesAnEmptyFilterFromNoMatches() {
        let apps = [
            InstalledApp(url: URL(fileURLWithPath: "/Applications/Claude.app"), name: "Claude", bundleIdentifier: "com.anthropic.claudefordesktop", version: "1.0"),
            InstalledApp(url: URL(fileURLWithPath: "/Applications/Slack.app"), name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", version: nil),
        ]
        XCTAssertEqual(WizardModel.filteredApps(apps, query: ""), apps)
        XCTAssertFalse(WizardModel.showsNoMatches(apps: apps, query: ""), "an empty filter is not a no-match state")
        XCTAssertEqual(WizardModel.filteredApps(apps, query: "sla").map(\.name), ["Slack"])
        XCTAssertFalse(WizardModel.showsNoMatches(apps: apps, query: "sla"))
        XCTAssertEqual(WizardModel.filteredApps(apps, query: "zzz"), [])
        XCTAssertTrue(WizardModel.showsNoMatches(apps: apps, query: "zzz"))
        XCTAssertFalse(WizardModel.showsNoMatches(apps: [], query: ""), "no apps and no filter (scan still running) is not a search result")
    }
```

- [ ] **Step 18: Run the wizard model tests to verify they fail**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/WizardModelTests 2>&1 | tail -4`
Expected: `** TEST FAILED **`; the build log above it reports `extra argument 'takenSlugs' in call` and `type 'WizardModel' has no member 'filteredApps'`.

- [ ] **Step 19: Implement the refusal, the slug and the search helpers in the wizard model**

In `App/Sources/Views/Wizard/WizardModel.swift`, make four edits.

(a) Replace

```swift
    /// Looks up the profile for a target bundle identifier; the sheet passes `AppState.profile(forBundleIdentifier:)`.
    private let profileLookup: @MainActor (String) -> AppProfile?

    init(prefillTarget: URL? = nil, profileLookup: @escaping @MainActor (String) -> AppProfile? = { _ in nil }) {
        self.profileLookup = profileLookup
```

with

```swift
    /// Looks up the profile for a target bundle identifier; the sheet passes `AppState.profile(forBundleIdentifier:)`.
    private let profileLookup: @MainActor (String) -> AppProfile?

    /// Slugs the library already uses (`SlugAllocator.takenSlugs(in:)`); `slug` steps around them (final review M6).
    private let takenSlugs: Set<String>

    init(prefillTarget: URL? = nil, takenSlugs: Set<String> = [], profileLookup: @escaping @MainActor (String) -> AppProfile? = { _ in nil }) {
        self.profileLookup = profileLookup
        self.takenSlugs = takenSlugs
```

(b) Replace

```swift
    var isLastStep: Bool { step == .review }
```

with

```swift
    var isLastStep: Bool { step == .review }

    /// The slug the new shortcut gets: the name's slug, or its first free `-2`, `-3`, … variant. Its bundle id and
    /// default data folder follow it.
    var slug: String {
        SlugAllocator.uniqueSlug(proposed: ShortcutConfig.slug(for: name.trimmingCharacters(in: .whitespaces)), taken: takenSlugs)
    }

    /// The installed apps the target step shows for `query`: all of them while it is empty, else the names that
    /// contain it (case-insensitive).
    static func filteredApps(_ apps: [InstalledApp], query: String) -> [InstalledApp] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// True when a non-empty search hides every app, so the step shows "No matches" instead of an empty grid. An
    /// empty query with no apps (the scan is still running, or found nothing) is not a search result.
    static func showsNoMatches(apps: [InstalledApp], query: String) -> Bool {
        !query.isEmpty && filteredApps(apps, query: query).isEmpty
    }
```

(c) Replace

```swift
    func selectTarget(_ url: URL) {
        targetURL = url
```

with

```swift
    func selectTarget(_ url: URL) {
        // Final review M5: a shortcut is never a target; it would chain launchers, or exec itself if it is this one.
        guard !TargetGuard.isShortcutBundle(at: url) else {
            targetURL = nil
            inspected = nil
            inspectError = TargetGuard.refusalMessage(forAppAt: url)
            profile = nil
            arguments = []
            environment = [:]
            return
        }
        targetURL = url
```

(d) Replace

```swift
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let slug = ShortcutConfig.slug(for: trimmed)
        return ShortcutConfig(
            kind: kind,
            name: trimmed,
            slug: slug,
            bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: slug),
```

with

```swift
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let finalSlug = slug
        return ShortcutConfig(
            kind: kind,
            name: trimmed,
            slug: finalSlug,
            bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: finalSlug),
```

In `App/Sources/Views/Wizard/NewShortcutWizard.swift`, hand the library's slugs to the model. Replace

```swift
            model = WizardModel(prefillTarget: appState.wizardPrefillTarget,
                                profileLookup: { [appState] in appState.profile(forBundleIdentifier: $0) })
```

with

```swift
            model = WizardModel(prefillTarget: appState.wizardPrefillTarget,
                                takenSlugs: SlugAllocator.takenSlugs(in: appState.library.records),
                                profileLookup: { [appState] in appState.profile(forBundleIdentifier: $0) })
```

- [ ] **Step 20: Run the wizard model tests to verify they pass**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/WizardModelTests 2>&1 | tail -4`
Expected: `Test Suite 'WizardModelTests' passed` and `** TEST SUCCEEDED **`.

- [ ] **Step 21: Preview the editor icon from the draft (M4)**

Create `App/Sources/Views/IconPreview.swift`:

```swift
import AppKit
import SwiftUI

/// The editor's 64-point icon preview. It draws what `IconPreviewSource` resolved from the draft, so a new icon mode,
/// custom file or name shows before Save (final review M4).
struct IconPreview: View {
    let source: IconPreviewSource

    var body: some View {
        if let image = Self.image(for: source) {
            Image(nsImage: image).resizable().frame(width: 64, height: 64)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 48)).foregroundStyle(.secondary).frame(width: 64, height: 64)
        }
    }

    /// The image for `source`; nil when there is nothing to draw or the file is not a readable image.
    static func image(for source: IconPreviewSource) -> NSImage? {
        switch source {
        case .file(let url):
            return NSImage(contentsOf: url)
        case .generated(let initials):
            return NSImage(cgImage: IconRenderer.generatedTile(initials: initials, size: 128), size: NSSize(width: 64, height: 64))
        case .placeholder:
            return nil
        }
    }
}
```

In `App/Sources/Views/EditorSections.swift`, replace

```swift
struct IdentitySection: View {
    @Binding var draft: ShortcutConfig
    let record: ShortcutRecord
```

with

```swift
struct IdentitySection: View {
    @Binding var draft: ShortcutConfig
    let record: ShortcutRecord
    /// The draft target's inspection; its icon file is the `.copied` preview.
    let inspected: InspectedApp?
```

and replace

```swift
            LabeledContent("Preview") {
                if let url = record.iconURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().frame(width: 64, height: 64)
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 48)).foregroundStyle(.secondary).frame(width: 64, height: 64)
                }
            }
```

with

```swift
            LabeledContent("Preview") {
                IconPreview(source: IconPreviewSource.resolve(draft: draft, saved: record.config,
                                                              savedIconURL: record.iconURL,
                                                              targetIconURL: inspected?.iconFileURL))
            }
```

In `App/Sources/Views/ShortcutEditorView.swift` (line 33), replace `IdentitySection(draft: $draft, record: record)` with `IdentitySection(draft: $draft, record: record, inspected: inspected)`.

- [ ] **Step 22: Refuse a shortcut target in the editor and on drop (M5); de-duplicate the slug on rename (M6)**

In `App/Sources/Views/EditorSections.swift`, `TargetSection`: replace

```swift
    let profile: AppProfile?

    var body: some View {
        Section("Target") {
            LabeledContent("Application") {
                HStack {
                    Text(draft.targetPath).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button("Choose…") { chooseTarget() }
                }
            }
```

with

```swift
    let profile: AppProfile?
    /// Why the last chosen target was refused (final review M5); the next accepted choice clears it.
    @State private var targetError: String?

    var body: some View {
        Section("Target") {
            LabeledContent("Application") {
                HStack {
                    Text(draft.targetPath).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button("Choose…") { chooseTarget() }
                }
            }
            if let targetError {
                Label(targetError, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption)
            }
```

and replace

```swift
        guard panel.runModal() == .OK, let url = panel.url,
              let identifier = InstalledApps.infoDictionary(ofAppAt: url)?["CFBundleIdentifier"] as? String else { return }
        draft.targetPath = url.path
```

with

```swift
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Final review M5: a shortcut, this one included, is never a target.
        guard !TargetGuard.isShortcutBundle(at: url) else {
            targetError = TargetGuard.refusalMessage(forAppAt: url)
            return
        }
        guard let identifier = InstalledApps.infoDictionary(ofAppAt: url)?["CFBundleIdentifier"] as? String else { return }
        targetError = nil
        draft.targetPath = url.path
```

In `App/Sources/Views/ContentView.swift`, replace

```swift
            guard let app = urls.first(where: { $0.pathExtension == "app" }) else { return false }
            appState.wizardPrefillTarget = app
```

with

```swift
            guard let app = urls.first(where: { $0.pathExtension == "app" }) else { return false }
            // Final review M5: a dropped shortcut is refused before the wizard opens on it.
            guard !TargetGuard.isShortcutBundle(at: app) else {
                appState.pendingError = AppError(context: "Not an app", message: TargetGuard.refusalMessage(forAppAt: app))
                return false
            }
            appState.wizardPrefillTarget = app
```

In `App/Sources/Views/ShortcutEditorView.swift`, `save()` (lines 121-122), replace

```swift
            config.slug = ShortcutConfig.slug(for: config.name)
            config.bundleIdentifier = ShortcutConfig.bundleIdentifier(forSlug: config.slug)
```

with

```swift
            // Final review M6: a rename steps around the slugs the other shortcuts use (this one's own stays free).
            config.slug = SlugAllocator.uniqueSlug(proposed: ShortcutConfig.slug(for: config.name),
                                                   taken: SlugAllocator.takenSlugs(in: appState.library.records, excluding: record.bundleURL))
            config.bundleIdentifier = ShortcutConfig.bundleIdentifier(forSlug: config.slug)
```

An explicit `dataPath` already stored in the config is left as it is on rename, so the shortcut keeps its data; a nil `dataPath` resolves from the new slug when the builder regenerates.

- [ ] **Step 23: Wizard target step: "No matches" state, keyboard and VoiceOver tiles, final slug in the data step (nits a, b; M6)**

In `App/Sources/Views/Wizard/WizardSteps.swift`, `TargetStep`: replace

```swift
    private var filtered: [InstalledApp] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
```

with

```swift
    private var filtered: [InstalledApp] { WizardModel.filteredApps(apps, query: query) }
```

and replace

```swift
            InstalledAppsGrid(apps: filtered, selection: $selection)
                .frame(minHeight: 220)
```

with

```swift
            if WizardModel.showsNoMatches(apps: apps, query: query) {
                ContentUnavailableView("No matches", systemImage: "magnifyingglass",
                                       description: Text("No installed app matches “\(query)”. Drop the app below or browse for it."))
                    .frame(minHeight: 220)
            } else {
                InstalledAppsGrid(apps: filtered, selection: $selection)
                    .frame(minHeight: 220)
            }
```

In the same file, `DataStep` (line 158), replace

```swift
    private var slug: String { ShortcutConfig.slug(for: model.name.trimmingCharacters(in: .whitespaces)) }
```

with

```swift
    private var slug: String { model.slug }
```

so the default folder it shows and validates against is the de-duplicated one `makeConfig()` uses.

Replace the whole of `App/Sources/Views/Wizard/InstalledAppsGrid.swift` with:

```swift
import SwiftUI

struct InstalledAppsGrid: View {
    let apps: [InstalledApp]
    @Binding var selection: URL?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(apps) { app in
                    // A Button, not a tap gesture: the tile is a VoiceOver button and Space presses it from keyboard
                    // focus. Return is handled explicitly because macOS gives it to the default button.
                    Button {
                        selection = app.url
                    } label: {
                        VStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                .resizable()
                                .frame(width: 48, height: 48)
                            Text(app.name)
                                .font(.caption)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(width: 96, height: 84)
                        .padding(6)
                        .background(selection == app.url ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onKeyPress(.return) {
                        selection = app.url
                        return .handled
                    }
                    .accessibilityLabel(app.name)
                    .accessibilityAddTraits(selection == app.url ? [.isButton, .isSelected] : [.isButton])
                }
            }
            .padding(4)
        }
    }
}
```

- [ ] **Step 24: "Browse…" on every file chooser and a window tall enough for the editor's Actions (nits c, d)**

Rename the six chooser buttons (EditorSections.swift:22/55/142, SettingsView.swift:32, WizardSteps.swift:108/174; `AppDropZone.swift:13` already reads `Browse…`):

Run: `cd "$REPO" && sed -i '' 's/Button("Choose…")/Button("Browse…")/' App/Sources/Views/EditorSections.swift App/Sources/Views/SettingsView.swift App/Sources/Views/Wizard/WizardSteps.swift && grep -rn 'Choose…\|Choose\.\.\.\|Browse\.\.\.' App/Sources; grep -rn 'Button("Browse…"' App/Sources | wc -l`
Expected: the first grep prints nothing; the count is `7`.

Nit d uses `.frame(minHeight:)`, not a `ScrollView`: the editor's `.grouped` `Form` is already a scroll view on macOS and wrapping it in another `ScrollView` collapses its height, so the fix is a window that opens tall enough for the Actions section to start on screen. In `App/Sources/App/MacAppDuplicatorApp.swift` (line 44), replace

```swift
                .frame(minWidth: 820, minHeight: 520)
```

with

```swift
                .frame(minWidth: 820, minHeight: 720)
```

- [ ] **Step 25: Run the full app suite and the Core suite**

Run: `cd "$REPO" && Tools/test-app.sh 2>&1 | tail -4`
Expected: `** TEST SUCCEEDED **`.

Run: `cd "$REPO" && swift test --filter DuplicatorCoreTests 2>&1 | grep -E 'Executed|error:' | tail -3`
Expected: `Executed … tests, with 0 failures` and no `error:` line (Core is not touched by this task).

Run: `cd "$REPO" && git status --short`
Expected: exactly the files in this task's **Files:** block (new files as `??`, the rest as ` M`), nothing else.

- [ ] **Step 26: Commit**

```bash
cd "$REPO" && git add App/Sources/Services/IconPreviewSource.swift App/Sources/Views/IconPreview.swift App/Sources/Services/TargetGuard.swift App/Sources/Services/SlugAllocator.swift App/Sources/Services/ShortcutBuilder.swift App/Sources/App/AppState.swift App/Sources/App/MacAppDuplicatorApp.swift App/Sources/Views/EditorSections.swift App/Sources/Views/ShortcutEditorView.swift App/Sources/Views/ContentView.swift App/Sources/Views/SettingsView.swift App/Sources/Views/Wizard/WizardModel.swift App/Sources/Views/Wizard/NewShortcutWizard.swift App/Sources/Views/Wizard/WizardSteps.swift App/Sources/Views/Wizard/InstalledAppsGrid.swift App/Tests/Services/SlugAllocatorTests.swift App/Tests/Services/TargetGuardTests.swift App/Tests/Services/IconPreviewSourceTests.swift App/Tests/Services/ShortcutBuilderTests.swift App/Tests/Wizard/WizardModelTests.swift \
  && ! git diff --cached -U0 | grep -nE '^\+.*(try\?|@unchecked Sendable|swiftlint:disable)' \
  && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -q -F - <<'MSG'
Harden shortcuts: draft icon preview, shortcut-target refusal, unique slugs

- The editor's icon preview renders from the draft (IconPreviewSource, IconPreview), not only the saved bundle icon.
- TargetGuard refuses an App Duplicator shortcut as a target in the wizard, the editor, the window drop and the builder.
- SlugAllocator gives create, rename and duplicate the first free slug (-2, -3, ...); bundle id and default data folder follow it.
- Wizard search shows "No matches"; app tiles are keyboard and VoiceOver buttons; file choosers read "Browse…"; the window opens tall enough for the editor's Actions.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

Expected: the forbidden-construct grep finds nothing, the commit succeeds, and `git status --short` is empty.

---

### Task 9: Scan and monitor generations, FolderWatcher deinit, test-host hygiene

**Files:**
- Modify: `App/Sources/Model/ShortcutLibrary.swift:9-26,54-63` (scanner seam `ShortcutScanning`; scan generation guard in `rescan()`)
- Modify: `App/Sources/Model/RunningShortcutMonitor.swift:9-41` (probe seam; refresh generation guard in `refresh()`)
- Modify: `App/Sources/Model/FolderWatcher.swift` (whole file shown: `Mutex`-held sources, nonisolated `cancelSources()`, `deinit`)
- Modify: `App/Sources/App/MacAppDuplicatorApp.swift:54-71` (main `WindowGroup` and the `Known Limitations` `Window`: launch suppressed and restoration disabled under the test host)
- Modify: `Tools/test-app.sh:18-19` (EXIT trap deletes `com.mikekuta.MacAppDuplicatorTests.*.plist` residue)
- Test: `App/Tests/Model/ShortcutLibraryTests+ScanGeneration.swift` (new file: `GatedScanner` stub + `extension ShortcutLibraryTests`)
- Test: `App/Tests/Model/RunningShortcutMonitorTests.swift` (new file: `GatedProbe` stub + `RunningShortcutMonitorTests`)
- Test: `App/Tests/Model/FolderWatcherTests.swift` (new file: `FolderWatcherTests`)
- Test: `App/Tests/App/LaunchEnvironmentTests+TestHost.swift` (new file: `extension LaunchEnvironmentTests`)

**Interfaces:**
- Consumes:
  - `struct LibraryScanner: Sendable` with `func scan(folders: [URL]) -> ScanResult`; `struct ScanResult: Sendable` (`records`, `warnings`) — `App/Sources/Model/LibraryScanner.swift:4-23`.
  - `ProcessEnvironment.values(forEnvironmentKey:)` and `DataSeparationPlanner.shortcutBundleKey` (DuplicatorCore), exactly as `RunningShortcutMonitor.refresh()` uses them today.
  - `LaunchEnvironment.isTestHost(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool` and `MacAppDuplicatorApp.isTestHost` (private static, wraps it).
  - SwiftUI (macOS 15+): `Scene.defaultLaunchBehavior(_: SceneLaunchBehavior)`, `Scene.restorationBehavior(_: SceneRestorationBehavior)`.
  - Test helpers (`App/Tests/TestSupport/AppTestSupport.swift`): `makeAppTemporaryDirectory() throws -> URL`, `writeShortcutBundle(named:in:config:engineVersion:withIcon:extraInfo:) throws -> URL`, `makeConfig(name:targetPath:targetBundleIdentifier:kind:) -> ShortcutConfig`, `makeTestDefaults() -> (defaults: UserDefaults, suite: String)`, `XCTestCase.waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async`.
- Produces (app target):
  - `protocol ShortcutScanning: Sendable { func scan(folders: [URL]) -> ScanResult }` and `extension LibraryScanner: ShortcutScanning {}` (in `ShortcutLibrary.swift`).
  - `ShortcutLibrary.init(settings: AppSettings, scanner: any ShortcutScanning = LibraryScanner(), monitor: RunningShortcutMonitor? = nil)`; private `@ObservationIgnored var scanGeneration: UInt64`. `rescan()` signature unchanged.
  - `RunningShortcutMonitor.init(probe: @escaping @Sendable () -> Set<String> = { RunningShortcutMonitor.liveRunningBundlePaths() })`; `nonisolated static func liveRunningBundlePaths() -> Set<String>`; private `@ObservationIgnored var refreshGeneration: UInt64`. `refresh()` signature unchanged.
  - `FolderWatcher`: unchanged surface (`init(folders:debounce:onChange:)`, `start()`, `stop()`, `watchedSourceCount`) plus a nonisolated `deinit` that cancels the sources.
- Produces (test target only): `final class GatedScanner: ShortcutScanning` (`init(gatedCalls: Set<Int>)`, `hasFinishedScanning(call:) -> Bool`, `release(call:)`); `final class GatedProbe: Sendable` (`init(results: [Set<String>], gatedCalls: Set<Int>)`, `next() -> Set<String>`, `hasStarted(call:) -> Bool`, `release(call:)`); `@MainActor final class ChangeCounter` (`count`, `onRecord`, `record()`), in `FolderWatcherTests.swift`.

**Settings signing default race: dropped — the current code already handles it.** `AppSettings.init` never leaves `signingIdentity` empty (it falls back to `defaultSigningIdentity`, ad hoc at launch), `applyDefaultSigningIdentity` swaps in the Developer ID default without persisting it (M15), and `SigningSettingsTab`'s picker always has a tag for the current value (ad hoc, a loaded identity, or the `isMissing` fallback tag at `SettingsView.swift:97`), so the selection can be neither blank nor different from the effective setting, and the picker writes `AppSettings` only when the user picks. A "fall back to the first loaded identity in the displayed binding" would show an identity that is not the one shortcuts get signed with, so it is not planned. (Known cosmetic gap, out of scope here: while the tab's own `.task` load is pending, a stored Developer ID identity counts as `isMissing`, so the orange "Identity not found in keychain" label flashes until `security find-identity` returns.)

- [ ] **Step 1: Write the failing scan-generation tests for `ShortcutLibrary`**

The stub wraps the real scanner, so no `ScanResult` is built by hand: every call scans the folder for real, and a gated call then blocks after scanning, which lets a test hold an older (empty) result back while a newer scan sees a new bundle. The tests go in a new file as an extension of the existing `ShortcutLibraryTests` class, so the existing file is not touched. Create `App/Tests/Model/ShortcutLibraryTests+ScanGeneration.swift`:

```swift
import Foundation
import Synchronization
import XCTest
@testable import MacAppDuplicator

/// Wraps the real scanner. Every call scans for real; each call listed in `gatedCalls` then records that it has
/// finished scanning and blocks until `release(call:)`, so a test can make an older scan land after a newer one
/// (final review M7). The semaphore wait sits inside the synchronous `scan`, never directly in async code.
final class GatedScanner: ShortcutScanning {
    private let gates: [Int: DispatchSemaphore]
    private let callCount = Mutex(0)
    private let finishedCalls = Mutex<Set<Int>>([])

    init(gatedCalls: Set<Int>) {
        gates = Dictionary(uniqueKeysWithValues: gatedCalls.map { ($0, DispatchSemaphore(value: 0)) })
    }

    func scan(folders: [URL]) -> ScanResult {
        let call = callCount.withLock { count in
            count += 1
            return count
        }
        let result = LibraryScanner().scan(folders: folders)
        finishedCalls.withLock { _ = $0.insert(call) }
        gates[call]?.wait()
        return result
    }

    func hasFinishedScanning(call: Int) -> Bool { finishedCalls.withLock { $0.contains(call) } }
    func release(call: Int) { gates[call]?.signal() }
}

extension ShortcutLibraryTests {
    @MainActor
    func testStaleScanThatLandsLastIsDropped() async throws {
        let root = try makeAppTemporaryDirectory()
        let (defaults, suite) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        settings.outputFolder = root
        let scanner = GatedScanner(gatedCalls: [1])
        let library = ShortcutLibrary(settings: settings, scanner: scanner, monitor: RunningShortcutMonitor(probe: { [] }))

        // Scan 1 sees the empty folder, then blocks before its result can land.
        let stale = Task { await library.rescan() }
        await waitUntil { scanner.hasFinishedScanning(call: 1) }
        XCTAssertTrue(library.isScanning)

        // Scan 2 sees the new bundle and lands first.
        let bundle = try writeShortcutBundle(named: "Fresh.app", in: root, config: makeConfig(name: "Fresh"))
        await library.rescan()
        XCTAssertNotNil(library.record(for: bundle))
        XCTAssertFalse(library.isScanning)

        // Scan 1's empty result lands last and must be dropped.
        scanner.release(call: 1)
        await stale.value
        XCTAssertNotNil(library.record(for: bundle), "a stale scan result replaced a newer one")
        XCTAssertEqual(library.records.count, 1)
        XCTAssertFalse(library.isScanning)
    }

    @MainActor
    func testOnlyTheNewestScanClearsIsScanning() async throws {
        let root = try makeAppTemporaryDirectory()
        let (defaults, suite) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        settings.outputFolder = root
        let scanner = GatedScanner(gatedCalls: [1, 2])
        let library = ShortcutLibrary(settings: settings, scanner: scanner, monitor: RunningShortcutMonitor(probe: { [] }))

        let stale = Task { await library.rescan() }
        await waitUntil { scanner.hasFinishedScanning(call: 1) }
        let bundle = try writeShortcutBundle(named: "Fresh.app", in: root, config: makeConfig(name: "Fresh"))
        let newest = Task { await library.rescan() }
        await waitUntil { scanner.hasFinishedScanning(call: 2) }

        // The stale scan lands while the newest is still running: it must neither publish nor clear isScanning.
        scanner.release(call: 1)
        await stale.value
        XCTAssertTrue(library.isScanning, "a stale scan cleared isScanning while a newer scan was running")
        XCTAssertNil(library.record(for: bundle))
        XCTAssertTrue(library.records.isEmpty)

        scanner.release(call: 2)
        await newest.value
        XCTAssertFalse(library.isScanning)
        XCTAssertNotNil(library.record(for: bundle))
    }
}
```

`named: "Fresh.app"` yields a bundle whose path extension is `app` whether or not `writeShortcutBundle` appends `.app` itself; every assertion looks the record up by the URL the helper returns.

- [ ] **Step 2: Run the new tests to verify they fail to compile**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/ShortcutLibraryTests 2>&1 | grep -E 'error:|\*\* TEST' | head -5`
Expected: `error: cannot find type 'ShortcutScanning' in scope`, an `error:` line for the unknown `probe:` argument of `RunningShortcutMonitor(probe:)` (wording varies by toolchain, for example `argument passed to call that takes no arguments`), and `** TEST FAILED **`.

- [ ] **Step 3: Add the scanner and probe seams (no behavior change yet)**

In `App/Sources/Model/ShortcutLibrary.swift`, insert above the `/// The in-memory library: …` doc comment (current line 6):

```swift
/// What `ShortcutLibrary` needs from a scanner. `LibraryScanner` is the real one; tests inject a gated stub (final review M7).
protocol ShortcutScanning: Sendable {
    func scan(folders: [URL]) -> ScanResult
}

extension LibraryScanner: ShortcutScanning {}

```

In the same file replace `    private let scanner: LibraryScanner` (current line 16) with:

```swift
    private let scanner: any ShortcutScanning
```

and replace the `init` signature line (current line 22) with:

```swift
    init(settings: AppSettings, scanner: any ShortcutScanning = LibraryScanner(), monitor: RunningShortcutMonitor? = nil) {
```

In `App/Sources/Model/RunningShortcutMonitor.swift`, insert after `    private var refreshTask: Task<Void, Never>?` (current line 14):

```swift
    private let probe: @Sendable () -> Set<String>

    /// `probe` lists the standardized bundle paths of running shortcuts; it runs detached, off the main actor.
    /// Tests inject a stub. The default is a nonisolated closure, never a main-actor value.
    init(probe: @escaping @Sendable () -> Set<String> = { RunningShortcutMonitor.liveRunningBundlePaths() }) {
        self.probe = probe
    }
```

and replace the whole `refresh()` method (current lines 34-41, doc comment included) with:

```swift
    /// Rescans process environments once. Safe to call while a scheduled refresh is pending.
    func refresh() async {
        let probe = probe
        let paths = await Task.detached(priority: .utility) { probe() }.value
        runningBundlePaths = paths
    }

    /// Standardized paths from every process's `MAD_SHORTCUT_BUNDLE` entry (spec §7). Nonisolated because it runs
    /// detached; the body is the expression `refresh()` ran inline before the seam existed.
    nonisolated static func liveRunningBundlePaths() -> Set<String> {
        let key = DataSeparationPlanner.shortcutBundleKey
        return Set(ProcessEnvironment.values(forEnvironmentKey: key).values.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }
```

Every existing call site (`ShortcutLibrary(settings:)`, `RunningShortcutMonitor()`, `monitor ?? RunningShortcutMonitor()`) still compiles unchanged through the default arguments.

- [ ] **Step 4: Run the ShortcutLibrary generation tests to verify they fail for the right reason**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/ShortcutLibraryTests 2>&1 | grep -E 'error:|\*\* TEST' | head -8`
Expected: the target now compiles, and exactly the two new tests fail: `testStaleScanThatLandsLastIsDropped` with "a stale scan result replaced a newer one" and `XCTAssertEqual failed: ("0") is not equal to ("1")`, and `testOnlyTheNewestScanClearsIsScanning` with "a stale scan cleared isScanning while a newer scan was running"; then `** TEST FAILED **`. Every pre-existing `ShortcutLibraryTests` method still passes, which proves the seam refactor changed no behavior. A compile error here means Step 3 was applied incompletely; fix it before continuing.

- [ ] **Step 5: Write the failing RunningShortcutMonitor generation test**

Create `App/Tests/Model/RunningShortcutMonitorTests.swift` (no such file or class exists today):

```swift
import Foundation
import Synchronization
import XCTest
@testable import MacAppDuplicator

/// A process probe that returns canned results in call order and blocks gated calls until the test releases them.
final class GatedProbe: Sendable {
    private let results: [Set<String>]
    private let gates: [Int: DispatchSemaphore]
    private let callCount = Mutex(0)
    private let started = Mutex<Set<Int>>([])

    init(results: [Set<String>], gatedCalls: Set<Int>) {
        self.results = results
        self.gates = Dictionary(uniqueKeysWithValues: gatedCalls.map { ($0, DispatchSemaphore(value: 0)) })
    }

    /// Runs on the detached probe task, never on the main actor, so blocking on a gate is safe.
    func next() -> Set<String> {
        let call = callCount.withLock { count in
            count += 1
            return count
        }
        started.withLock { _ = $0.insert(call) }
        gates[call]?.wait()
        return results[min(call, results.count) - 1]
    }

    func hasStarted(call: Int) -> Bool { started.withLock { $0.contains(call) } }

    func release(call: Int) { gates[call]?.signal() }
}

final class RunningShortcutMonitorTests: XCTestCase {
    @MainActor
    func testStaleRefreshThatLandsLastIsDropped() async {
        let probe = GatedProbe(results: [["/stale/Old.app"], ["/fresh/New.app"]], gatedCalls: [1])
        let monitor = RunningShortcutMonitor(probe: { probe.next() })

        let stale = Task { await monitor.refresh() }
        await waitUntil { probe.hasStarted(call: 1) }
        await monitor.refresh()
        XCTAssertEqual(monitor.runningBundlePaths, ["/fresh/New.app"])

        probe.release(call: 1)
        await stale.value
        XCTAssertEqual(monitor.runningBundlePaths, ["/fresh/New.app"], "a stale refresh replaced a newer one")
        XCTAssertFalse(monitor.isRunning(bundleURL: URL(fileURLWithPath: "/stale/Old.app")))
    }
}
```

- [ ] **Step 6: Run the monitor test to verify it fails**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/RunningShortcutMonitorTests 2>&1 | grep -E 'error:|\*\* TEST' | head -5`
Expected: `testStaleRefreshThatLandsLastIsDropped` fails with "a stale refresh replaced a newer one" (the set holds `/stale/Old.app`) and the `XCTAssertFalse` on `isRunning`, then `** TEST FAILED **`.

- [ ] **Step 7: Implement the scan and refresh generations**

In `App/Sources/Model/ShortcutLibrary.swift`, add after `    private(set) var isScanning = false` (keep the property's exact existing spelling; only add the new line under it):

```swift
    /// Bumped by every `rescan()`; only the scan holding the current value may publish (final review M7).
    @ObservationIgnored private var scanGeneration: UInt64 = 0
```

and replace the method from `    func rescan() async {` through its closing brace (current lines 54-63; leave any doc comment above it untouched) with:

```swift
    func rescan() async {
        // Rescans overlap (FolderWatcher, Refresh, Settings changes) and can finish out of order. Each takes a
        // generation: a stale result is dropped, and only the newest scan clears `isScanning` (final review M7).
        scanGeneration &+= 1
        let generation = scanGeneration
        isScanning = true
        let folders = settings.allLibraryFolders
        let scanner = scanner
        let result = await Task.detached(priority: .userInitiated) { scanner.scan(folders: folders) }.value
        guard generation == scanGeneration else { return }
        records = result.records
        warnings = result.warnings
        await monitor.refresh()
        if generation == scanGeneration { isScanning = false }
    }
```

The `defer { isScanning = false }` is gone on purpose: a stale scan must leave the flag to the newer scan. A cancelled caller still reaches the guard, because `Task.detached(...).value` does not throw.

In `App/Sources/Model/RunningShortcutMonitor.swift`, add under `    private let probe: @Sendable () -> Set<String>`:

```swift
    /// Bumped by every `refresh()`; only the newest refresh may publish its paths (final review M7).
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
```

and replace the Step 3 `refresh()` (doc comment included) with:

```swift
    /// Rescans process environments once. Safe to call while a scheduled refresh is pending: overlapping refreshes
    /// can finish out of order, so only the newest one publishes its paths (final review M7).
    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let probe = probe
        let paths = await Task.detached(priority: .utility) { probe() }.value
        guard generation == refreshGeneration else { return }
        runningBundlePaths = paths
    }
```

- [ ] **Step 8: Run both generation suites and the whole app suite to verify they pass**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/ShortcutLibraryTests -only-testing:MacAppDuplicatorTests/RunningShortcutMonitorTests 2>&1 | grep -E 'error:|\*\* TEST' | tail -3`
Expected: `** TEST SUCCEEDED **`, no `error:` lines.

Run: `cd "$REPO" && Tools/test-app.sh 2>&1 | grep -E 'error:|\*\* TEST' | tail -3`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
cd "$REPO" && git add App/Sources/Model/ShortcutLibrary.swift App/Sources/Model/RunningShortcutMonitor.swift App/Tests/Model/ShortcutLibraryTests+ScanGeneration.swift App/Tests/Model/RunningShortcutMonitorTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -q -F - <<'MSG'
fix(library): drop stale scan and monitor results by generation

Overlapping rescans (FolderWatcher, Refresh, Settings changes) could finish
out of order: a stale scan overwrote newer records, and the first scan to
finish cleared isScanning while a newer one was still running. Each rescan
and each monitor refresh now takes a generation; stale results are dropped
and only the newest scan clears isScanning. ShortcutScanning and an
injectable process probe let tests gate the detached work.

Final review M7.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

Expected: `git status --short` prints nothing (the generated `App/MacAppDuplicator.xcodeproj` is gitignored).

- [ ] **Step 10: Write the failing FolderWatcher deinit test**

Create `App/Tests/Model/FolderWatcherTests.swift` (no such file or class exists today):

```swift
import Darwin
import Foundation
import XCTest
@testable import MacAppDuplicator

/// Counts debounced change callbacks on the main actor and optionally reports each one.
@MainActor
final class ChangeCounter {
    private(set) var count = 0
    var onRecord: (() -> Void)?

    func record() {
        count += 1
        onRecord?()
    }
}

final class FolderWatcherTests: XCTestCase {
    @MainActor
    func testDeallocatedWatcherWithoutStopClosesItsDescriptorAndNeverCallsBack() async throws {
        let folder = try makeAppTemporaryDirectory()
        let counter = ChangeCounter()
        var watcher: FolderWatcher? = FolderWatcher(folders: [folder], debounce: .milliseconds(50)) { counter.record() }
        watcher?.start()
        XCTAssertEqual(watcher?.watchedSourceCount, 1)
        XCTAssertEqual(Self.openDescriptorCount(for: folder), 1, "start() opens one O_EVTONLY descriptor per folder")

        try Data("one".utf8).write(to: folder.appendingPathComponent("one.txt"))
        await waitUntil { counter.count == 1 }
        XCTAssertEqual(counter.count, 1, "the watcher must report a change while alive")

        weak var released = watcher
        watcher = nil  // no stop(): deinit alone must clean up (final review M8)
        XCTAssertNil(released, "nothing may retain the watcher, or deinit never runs")

        await waitUntil { Self.openDescriptorCount(for: folder) == 0 }
        XCTAssertEqual(
            Self.openDescriptorCount(for: folder), 0,
            "deinit must cancel the sources so their cancel handlers close the descriptors"
        )

        let noCallback = expectation(description: "no change callback after the watcher is gone")
        noCallback.isInverted = true
        counter.onRecord = { noCallback.fulfill() }
        try Data("two".utf8).write(to: folder.appendingPathComponent("two.txt"))
        await fulfillment(of: [noCallback], timeout: 1)
        XCTAssertEqual(counter.count, 1)
    }

    /// Counts this process's open descriptors whose path is `folder`. `F_GETPATH` reports the resolved path, so a
    /// temporary folder under `/var/folders/…` comes back as `/private/var/folders/…`; both spellings count.
    private static func openDescriptorCount(for folder: URL) -> Int {
        let folderPath = folder.standardizedFileURL.path
        let accepted: Set<String> = [folderPath, "/private" + folderPath]
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var count = 0
        for descriptor in 0..<getdtablesize() where fcntl(descriptor, F_GETPATH, &buffer) == 0 {
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if accepted.contains(path) { count += 1 }
        }
        return count
    }
}
```

The "no callback" half cannot fail today: the event handler already holds `[weak self]`, and libdispatch unregisters a released source. The descriptor assertion is the real M8 signal: when an uncancelled source is released, libdispatch disposes its cancel handler without running it, so `close(descriptor)` never happens and the `O_EVTONLY` descriptor leaks until the process exits.

- [ ] **Step 11: Run the FolderWatcher test to verify it fails**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/FolderWatcherTests 2>&1 | grep -E 'error:|\*\* TEST' | head -5`
Expected: one failure, "deinit must cancel the sources so their cancel handlers close the descriptors" (`("1") is not equal to ("0")`), after the `waitUntil` times out; then `** TEST FAILED **`. If the first `openDescriptorCount` assertion fails instead (reports 0 while the watcher is alive), the path matching is wrong for this machine's temporary directory: print the `F_GETPATH` results and fix the accepted spellings before going on.

- [ ] **Step 12: Cancel the sources in deinit**

Approach: a nonisolated `deinit` plus a `Mutex`, not SE-0371 `isolated deinit`. A `@MainActor` class's deinit is nonisolated, so it may touch only `Sendable` stored state. Holding the sources in a `Mutex` (unconditionally `Sendable`) lets `deinit` cancel them synchronously, on whatever thread drops the last reference. This needs no Swift 6.2 language feature and no runtime-availability check, and nothing has to hop to the main actor after the object is already gone. `pending` is a `Task`, which is `Sendable`. It is read before the first method call, because once `deinit` calls a method only nonisolated properties stay accessible.

Replace the whole of `App/Sources/Model/FolderWatcher.swift` with:

```swift
import Foundation
import Synchronization

/// Watches library folders for writes/renames/deletes with `DispatchSource` and coalesces bursts (spec §7).
/// Folders that do not exist when `start()` runs are skipped; call `stop()`/`start()` again after changing the list.
@MainActor
final class FolderWatcher {
    private let folders: [URL]
    private let debounce: Duration
    private let onChange: @MainActor () -> Void
    /// In a `Mutex` so the nonisolated `deinit` can cancel the sources (final review M8).
    private let sources = Mutex<[any DispatchSourceFileSystemObject]>([])
    private var pending: Task<Void, Never>?

    init(folders: [URL], debounce: Duration = .milliseconds(300), onChange: @escaping @MainActor () -> Void) {
        self.folders = folders
        self.debounce = debounce
        self.onChange = onChange
    }

    /// Releasing a source without cancelling it skips its cancel handler, so the `O_EVTONLY` descriptor would leak
    /// (final review M8). A `@MainActor` class's deinit is nonisolated: it touches only `Sendable` state, reading
    /// `pending` before calling `cancelSources()` because only nonisolated members stay reachable after a method call.
    deinit {
        pending?.cancel()
        cancelSources()
    }

    /// Number of folders currently watched; 0 after `stop()`.
    var watchedSourceCount: Int { sources.withLock { $0.count } }

    func start() {
        stop()
        // Sources are created inside the lock so each one is in the lock's region from birth (Swift 6 region isolation).
        sources.withLock { list in
            for folder in folders {
                let descriptor = open(folder.path, O_EVTONLY)
                guard descriptor >= 0 else { continue }
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
                source.setEventHandler { [weak self] in
                    MainActor.assumeIsolated { self?.schedule() }
                }
                source.setCancelHandler { close(descriptor) }
                source.resume()
                list.append(source)
            }
        }
    }

    func stop() {
        cancelSources()
        pending?.cancel()
        pending = nil
    }

    /// Cancels and forgets every source. A cancelled source runs its cancel handler on `.main`, which closes the
    /// descriptor. Nonisolated so `deinit` can call it; it touches only the `Mutex`.
    nonisolated private func cancelSources() {
        sources.withLock { list in
            list.forEach { $0.cancel() }
            list.removeAll()
        }
    }

    private func schedule() {
        pending?.cancel()
        let delay = debounce
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.onChange()
        }
    }
}
```

Everything else (the debounce, the event mask, the `[weak self]` handlers, the skip-missing-folder rule) is unchanged. No `@unchecked Sendable`, no new `try?`. If the compiler rejects the `deinit` read of `pending` (it should not: the property is `Sendable` and the read comes before any method call), keep the order and report the diagnostic. Do not move `pending` into the `Mutex`; it is main-actor state everywhere else.

- [ ] **Step 13: Run the FolderWatcher test and the whole app suite to verify they pass**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/FolderWatcherTests 2>&1 | grep -E 'error:|warning:.*FolderWatcher|\*\* TEST' | tail -3`
Expected: `** TEST SUCCEEDED **`, no `error:` lines and no Swift 6 isolation warning for `FolderWatcher.swift`.

Run: `cd "$REPO" && Tools/test-app.sh 2>&1 | grep -E 'error:|\*\* TEST' | tail -3`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 14: Commit**

```bash
cd "$REPO" && git add App/Sources/Model/FolderWatcher.swift App/Tests/Model/FolderWatcherTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -q -F - <<'MSG'
fix(watcher): cancel dispatch sources in deinit

A FolderWatcher released without stop() dropped its DispatchSources
uncancelled; libdispatch then disposes the cancel handler without running
it, so every watched folder's O_EVTONLY descriptor leaked. The sources now
live in a Mutex, and the nonisolated deinit cancels them, so their cancel
handlers close the descriptors. The test counts open descriptors by path.

Final review M8.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

Expected: `git status --short` prints nothing.

- [ ] **Step 15: Write the test-host window tests**

Create `App/Tests/App/LaunchEnvironmentTests+TestHost.swift` (an extension of the existing `final class LaunchEnvironmentTests: XCTestCase`; method names are new):

```swift
import AppKit
import XCTest
@testable import MacAppDuplicator

extension LaunchEnvironmentTests {
    /// Guard test: the scene suppression below keys off this detection, so it must stay true inside the test host.
    func testTestHostDetectionHoldsInsideTheTestBundle() {
        XCTAssertTrue(LaunchEnvironment.isTestHost(), "the app's scenes are suppressed only when this is true under XCTest")
    }

    @MainActor
    func testTestHostOpensNoAutosavingWindow() async throws {
        // Let SwiftUI finish materializing its launch scenes before looking.
        try await Task.sleep(for: .milliseconds(500))
        let autosaving = NSApp.windows.map(\.frameAutosaveName).filter { !$0.isEmpty }
        XCTAssertEqual(
            autosaving, [],
            "the test host must open no window; a window's frame autosave writes the real com.mikekuta.MacAppDuplicator defaults (re-review Minor 7)"
        )
    }
}
```

- [ ] **Step 16: Run the test-host tests to verify the window test fails**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/LaunchEnvironmentTests 2>&1 | grep -E 'error:|\*\* TEST' | head -5`
Expected: `testTestHostOpensNoAutosavingWindow` fails, and its message lists one SwiftUI-generated autosave name for the "App Duplicator" window; then `** TEST FAILED **`. `testTestHostDetectionHoldsInsideTheTestBundle` and the existing `LaunchEnvironmentTests` methods pass. The guard test passes before and after the fix; it exists to catch a detection regression that would silently re-enable the window.

- [ ] **Step 17: Suppress launch and restoration of the app's windows under the test host**

In `App/Sources/App/MacAppDuplicatorApp.swift`, directly after the closing brace of the `WindowGroup`'s `.commands { … }` (current line 71), add:

```swift
        // Under the unit-test host no window may open or be restored: the main window's frame autosave wrote the
        // real com.mikekuta.MacAppDuplicator defaults domain on every test run (re-review Minor 7).
        .defaultLaunchBehavior(Self.isTestHost ? .suppressed : .automatic)
        .restorationBehavior(Self.isTestHost ? .disabled : .automatic)
```

Add the same two modifier lines (without the comment) after the last existing modifier of the `Window("Known Limitations", id: "known-limitations") { … }` scene, so state restoration cannot reopen that window inside the test host either. Leave the `Settings` scene alone: it never opens at launch. With `.automatic` on both scenes, a normal launch behaves exactly as before. Both modifiers are macOS 15 API; the deployment target is macOS 26.0 (`App/project.yml`).

- [ ] **Step 18: Run the test-host tests and the whole app suite to verify they pass**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/LaunchEnvironmentTests 2>&1 | grep -E 'error:|\*\* TEST' | tail -3`
Expected: `** TEST SUCCEEDED **`.

Run: `cd "$REPO" && Tools/test-app.sh 2>&1 | grep -E 'error:|\*\* TEST' | tail -3`
Expected: `** TEST SUCCEEDED **`. No other suite opened windows (the `.task` and `.onChange` test-host guards stay as they are), so nothing else changes.

- [ ] **Step 19: Delete the per-suite defaults residue after every test run**

In `Tools/test-app.sh`, insert between `swift build -c release --product Launcher` (line 18) and `xcodebuild \` (line 19):

```bash
# makeTestDefaults() suites leave one empty com.mikekuta.MacAppDuplicatorTests.<UUID>.plist each in
# ~/Library/Preferences (re-review Minor 7). Delete exactly those on every exit, pass or fail. Scope: that one
# directory, that one name pattern, regular files only, no recursion.
cleanup_test_defaults() {
  find "$HOME/Library/Preferences" -maxdepth 1 -type f -name 'com.mikekuta.MacAppDuplicatorTests.*.plist' -delete \
    || echo "warning: could not remove MacAppDuplicatorTests defaults residue from ~/Library/Preferences" >&2
}
trap cleanup_test_defaults EXIT
```

An EXIT trap, not a trailing command: with `set -euo pipefail`, a failing `xcodebuild` ends the script at the pipeline, so a line after it would never run on a red build. The trap does not call `exit`, so the script keeps `xcodebuild`'s exit status. The glob cannot match the app's own `com.mikekuta.MacAppDuplicator.plist`: it requires the `Tests.` infix.

Run: `cd "$REPO" && bash -n Tools/test-app.sh && echo syntax-ok`
Expected: `syntax-ok`.

- [ ] **Step 20: Run the whole suite, then verify the hygiene by hand**

Run: `cd "$REPO" && defaults read com.mikekuta.MacAppDuplicator 2>/dev/null | grep -c 'NSWindow Frame'`
Expected: a count, possibly `0`. Note it; it reflects real use of the app and is only read here.

Run: `cd "$REPO" && Tools/test-app.sh 2>&1 | grep -E 'error:|\*\* TEST' | tail -3`
Expected: `** TEST SUCCEEDED **`.

Run: `ls ~/Library/Preferences | grep -c MacAppDuplicatorTests`
Expected: `0`. If it is not 0, run it again after 5 seconds: `cfprefsd` can flush a removed suite's file shortly after the test process exits. A non-zero count that persists means the trap did not run; report it and do not commit.

Run: `defaults read com.mikekuta.MacAppDuplicator 2>/dev/null | grep -c 'NSWindow Frame'`
Expected: the same count as before the suite. The test host no longer autosaves a window frame into the real domain.

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/LaunchEnvironmentTests > /dev/null 2>&1; echo "exit=$?"; ls ~/Library/Preferences | grep -c MacAppDuplicatorTests`
Expected: `exit=0`, then `0`. This is a filtered run, which the trap also covers.

- [ ] **Step 21: Commit**

```bash
cd "$REPO" && git add App/Sources/App/MacAppDuplicatorApp.swift App/Tests/App/LaunchEnvironmentTests+TestHost.swift Tools/test-app.sh && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -q -F - <<'MSG'
fix(test-host): open no windows and clear defaults residue

Under the unit-test host the main window opened and autosaved its frame
into the real com.mikekuta.MacAppDuplicator defaults domain, and every
makeTestDefaults() suite left an empty
com.mikekuta.MacAppDuplicatorTests.<UUID>.plist behind. Both app scenes
now suppress launch and disable restoration when LaunchEnvironment detects
the test host (normal launches are unchanged), and Tools/test-app.sh
deletes exactly that residue pattern from ~/Library/Preferences in an EXIT
trap, on green and red runs alike.

Re-review Minor 7.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

Expected: `git status --short` prints nothing, and `git log --oneline -3` shows the three Task 9 commits: `fix(test-host): …`, `fix(watcher): …`, `fix(library): …`.

---

### Task 10: Known limitations, acceptance docs, README and version 0.3.0

**Files:**
- Modify: `App/Sources/App/KnownLimitations.swift:9-11,79-84` (doc comment; six Phase 3 entries appended to `KnownLimitations.all`)
- Modify: `App/project.yml:56-57` (`CURRENT_PROJECT_VERSION` "1" → "2", `MARKETING_VERSION` "0.2.0" → "0.3.0")
- Modify: `README.md:78` (Known Limitations count 14 → 20) and a new `## Phase 3 profiles` section inserted after line 80; no `MacAppDuplicator.app` or version string exists at HEAD to fix
- Create: `docs/acceptance/phase3-profiles.md`
- Create: `docs/acceptance/profile-promotion.md`
- Test: `App/Tests/App/KnownLimitationsTests.swift`

**Interfaces:**
- Consumes: `struct KnownLimitation: Identifiable, Hashable { let id: String; let title: String; let detail: String }` and `enum KnownLimitations { static let all: [KnownLimitation] }` (shape unchanged); `public enum ProfilesFetchPolicy { public static let allowedHost = "raw.githubusercontent.com" }` (Task 2, `ProfilesFetching.swift:10-11`); `static func badge(for app: InspectedApp?, profile: AppProfile? = nil) -> CompatBadge` (labels `Verified`, `Auto`, `HOME only`, `Unsupported`, `Unknown`); `public static func isNewer(_ candidate: String, than current: String) -> Bool` and `ProfilesDocument.updated` (Task 1); slug de-duplication `-2`, `-3` (Task 8); export replacing an existing destination via the Trash (Task 7).
- Produces: six new known-limitation entries (ids listed in Step 1) shown by the app's Known Limitations view; two acceptance documents; README Profiles section; app version `0.3.0` (build `2`). No new Swift types or signatures.

- [ ] **Step 1: Write the failing known-limitations tests**

The six Phase 3 entries get these ids and titles (asserted verbatim below, added in Step 3):

| id | title |
|---|---|
| `profiles-advisory` | Compatibility profiles are advisory |
| `profiles-partial` | Partial profiles need manual review |
| `profile-updates` | Check Profile Updates is manual and fetches from one host |
| `sandboxed-badge` | Sandboxed native apps cannot be separated |
| `slug-suffix` | Shortcuts whose names match get a numbered slug |
| `export-replaces` | Export replaces an existing shortcut by moving it to the Trash |

The existing `sandboxed-apps` entry stays untouched (it explains why the HOME override fails); `sandboxed-badge` explains what the compatibility badge shows for such an app, which is the Phase 3 point. The update-host assertion reads `ProfilesFetchPolicy.allowedHost` (Task 2, `Packages/CompatProfiles/Sources/CompatProfiles/ProfilesFetching.swift:11`) so the text cannot drift from the pinned host.

Replace `App/Tests/App/KnownLimitationsTests.swift` with:

```swift
import CompatProfiles
import XCTest
@testable import MacAppDuplicator

final class KnownLimitationsTests: XCTestCase {
    func testEntriesAreUniqueAndNonEmpty() {
        let ids = KnownLimitations.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertGreaterThanOrEqual(KnownLimitations.all.count, 6)
        for item in KnownLimitations.all {
            XCTAssertFalse(item.title.isEmpty)
            XCTAssertFalse(item.detail.isEmpty)
        }
    }

    /// The ids the Phase 2 plan prescribes. Spec §11 coverage is asserted by `testCoversEverySpecSection11Topic`.
    func testKeepsEveryEntryThePlanPrescribes() {
        let ids = Set(KnownLimitations.all.map(\.id))
        for required in ["launch-constraints", "sandboxed-apps", "single-instance", "dock-redraw", "login-items", "updates", "notifications", "file-associations"] {
            XCTAssertTrue(ids.contains(required), "missing \(required)")
        }
    }

    /// Spec §11 is "documented in-app and README": one entry per §11 bullet, each stating that bullet's point.
    /// The web-shell bullet (no passkeys) waits for the web shell phase.
    func testCoversEverySpecSection11Topic() throws {
        let topics: [(topic: String, id: String, mentions: String)] = [
            ("target Dock badges replace the shortcut's icon", "dock-redraw", "badge"),
            ("the Dock title can only be the bundle file name", "dock-title", "file name"),
            ("Apple platform binaries cannot use Dock Shortcut", "launch-constraints", "System Launch"),
            ("CFPreferences are shared in every data mode", "preferences", "~/Library/Preferences"),
            ("no dark override outside Chromium/Electron", "electron-dark-mode", "--force-dark-mode"),
            ("Disabled-mode launch-order handoff", "launch-order", "Disabled"),
            ("OAuth callbacks go to the instance that registered last", "oauth-callbacks", "registered"),
            ("push-notification clicks may front the wrong instance", "notifications", "wrong copy"),
            ("HOME override gives no separate Keychain or macOS user", "keychain", "Keychain"),
            ("sandboxed apps stay in their system container", "sandboxed-apps", "container"),
        ]
        let byID = Dictionary(KnownLimitations.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for topic in topics {
            let entry = try XCTUnwrap(byID[topic.id], "no entry for spec §11 topic: \(topic.topic)")
            XCTAssertTrue("\(entry.title) \(entry.detail)".contains(topic.mentions), "\(topic.id) does not mention \"\(topic.mentions)\"")
        }
    }

    /// Spec §11: links for the target's URL schemes reach whichever running instance registered the scheme last, so the
    /// entry must not promise that documents and links always open in the original app.
    func testFileAssociationsMatchesSpecURLRouting() throws {
        let entry = try XCTUnwrap(KnownLimitations.all.first { $0.id == "file-associations" })
        XCTAssertFalse(entry.detail.contains("keep opening in the original app"))
        XCTAssertTrue(entry.detail.contains("registered"))
    }

    /// Phase 3 (profiles): every profile-era limit is present, the Phase 2 entries are kept (14 + 6), ids stay unique and
    /// no entry is blank once whitespace is trimmed.
    func testKeepsEveryPhase3EntryThePlanPrescribes() {
        let ids = KnownLimitations.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate known-limitation ids")
        XCTAssertGreaterThanOrEqual(ids.count, 20)
        for required in ["profiles-advisory", "profiles-partial", "profile-updates", "sandboxed-badge", "slug-suffix", "export-replaces"] {
            XCTAssertTrue(ids.contains(required), "missing \(required)")
        }
        for item in KnownLimitations.all {
            XCTAssertFalse(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(item.id) has a blank title")
            XCTAssertFalse(item.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(item.id) has a blank detail")
        }
    }

    /// Each Phase 3 entry has its prescribed title and states its point: a Verified badge is one machine's check, partial
    /// profiles need review, updates are manual from the pinned host, sandboxed native apps never get a separable badge,
    /// colliding slugs get numbered, and export moves the old bundle to the Trash.
    func testPhase3EntriesStateTheirPoint() throws {
        let topics: [(id: String, title: String, mentions: [String])] = [
            ("profiles-advisory", "Compatibility profiles are advisory", ["Verified", "one Mac", "not a guarantee"]),
            ("profiles-partial", "Partial profiles need manual review", ["partial", "check"]),
            ("profile-updates", "Check Profile Updates is manual and fetches from one host",
             [ProfilesFetchPolicy.allowedHost, "never runs automatically"]),
            ("sandboxed-badge", "Sandboxed native apps cannot be separated", ["Unknown", "Unsupported", "container"]),
            ("slug-suffix", "Shortcuts whose names match get a numbered slug", ["-2", "-3"]),
            ("export-replaces", "Export replaces an existing shortcut by moving it to the Trash", ["Trash"]),
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
}
```

The first four tests are unchanged; only the `import CompatProfiles` line and the last two tests are new.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/KnownLimitationsTests 2>&1 | grep -E 'error:|failed|passed|TEST' | tail -6`
Expected: `testKeepsEveryPhase3EntryThePlanPrescribes` and `testPhase3EntriesStateTheirPoint` fail with `XCTAssertGreaterThanOrEqual failed: ("14") is less than ("20")`, `missing profiles-advisory` (one line per new id) and `no entry profiles-advisory`; the four existing tests pass; the run ends `** TEST FAILED **`.

- [ ] **Step 3: Add the six Phase 3 entries**

Every entry uses the existing `KnownLimitation(id:title:detail:)` shape; nothing else in the file changes except the doc comment. Badge wording follows `CompatBadge.badge(for:profile:)` (`App/Sources/Services/CompatBadge.swift:18-29`): a `partial` profile changes nothing, and a sandboxed native app with no `unsupported`/`verified` profile is `Unknown`. The cache rule follows `ProfileCatalog.load` (`Packages/CompatProfiles/Sources/CompatProfiles/ProfileCatalog.swift:35-41`): the cache wins only when its `updated` date is strictly later than the bundled seed's.

In `App/Sources/App/KnownLimitations.swift`, replace the doc comment (lines 9–11):

```swift
/// Spec §11 ("documented in-app and README"): one entry per §11 bullet, plus the app-specific limits that the README's
/// list also carries (single instance, login items, updates). The web-shell bullet (no passkeys) arrives with the web
/// shell phase. Shown in the Known Limitations window and linked from the wizard's compatibility line.
```

with:

```swift
/// Spec §11 ("documented in-app and README"): one entry per §11 bullet, plus the app-specific limits that the README's
/// list also carries (single instance, login items, updates). Phase 3 adds the profile limits (advisory badges, partial
/// profiles, manual updates from one host, sandboxed badges, numbered slugs, export's Trash replacement). The web-shell
/// bullet (no passkeys) arrives with the web shell phase. Shown in the Known Limitations window and linked from the
/// wizard's compatibility line.
```

Then replace the last entry and the closing bracket (lines 79–84):

```swift
        KnownLimitation(
            id: "electron-dark-mode",
            title: "Forcing dark mode only works for Chromium-based apps",
            detail: "Force dark (Chromium/Electron only, best effort) adds Chromium's --force-dark-mode flag, which Chromium, Electron and ToDesktop apps honour; an app with its own theme setting may still override it. The option is unavailable for other apps, which follow the system appearance. Light works for every app through -NSRequiresAquaSystemAppearance YES."
        ),
    ]
```

with:

```swift
        KnownLimitation(
            id: "electron-dark-mode",
            title: "Forcing dark mode only works for Chromium-based apps",
            detail: "Force dark (Chromium/Electron only, best effort) adds Chromium's --force-dark-mode flag, which Chromium, Electron and ToDesktop apps honour; an app with its own theme setting may still override it. The option is unavailable for other apps, which follow the system appearance. Light works for every app through -NSRequiresAquaSystemAppearance YES."
        ),
        KnownLimitation(
            id: "profiles-advisory",
            title: "Compatibility profiles are advisory",
            detail: "A profile suggests launch arguments, environment variables and a status for one app. A Verified badge means the profile was checked on one Mac with the app version available then; it is not a guarantee that it works with your version or setup. App Duplicator still inspects the app and builds the launch plan itself, and every value a profile fills in can be changed in the wizard or the editor."
        ),
        KnownLimitation(
            id: "profiles-partial",
            title: "Partial profiles need manual review",
            detail: "A partial profile has not been through the full check (a second account, a separate data folder and two Dock icons), so its arguments and environment may be incomplete. The badge ignores a partial profile and shows Auto, HOME only or Unknown as if there were none. Check the filled-in values and confirm that the copy keeps its own data before you rely on it."
        ),
        KnownLimitation(
            id: "profile-updates",
            title: "Check Profile Updates is manual and fetches from one host",
            detail: "Profiles change only when you choose Check Profile Updates; it never runs automatically and nothing checks in the background. It downloads only from an https address on raw.githubusercontent.com, any other host is refused, and a failed or invalid download leaves the cached profiles untouched. Between checks the app uses the cached copy only when its updated date is later than the profiles bundled with the app."
        ),
        KnownLimitation(
            id: "sandboxed-badge",
            title: "Sandboxed native apps cannot be separated",
            detail: "A sandboxed native app keeps its data in its App Sandbox container whatever the HOME override says, so App Duplicator cannot give a copy its own data. Without a profile its badge is Unknown, never HOME only, and a profile can mark it Unsupported. A shortcut can still give such an app a second Dock icon when the app allows a second instance, but both copies share one set of data."
        ),
        KnownLimitation(
            id: "slug-suffix",
            title: "Shortcuts whose names match get a numbered slug",
            detail: "Each shortcut's bundle identifier and default data folder are built from a slug of its name. When another shortcut already uses that slug, App Duplicator appends -2, -3 and so on, so shortcuts whose names match never share a bundle identifier or a default data folder."
        ),
        KnownLimitation(
            id: "export-replaces",
            title: "Export replaces an existing shortcut by moving it to the Trash",
            detail: "When the export destination already holds a bundle with the same name, App Duplicator moves that bundle to the Trash and writes the exported copy in its place; nothing is deleted outright. If you exported over the wrong bundle, put it back from the Trash."
        ),
    ]
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/KnownLimitationsTests 2>&1 | tail -4`
Expected: `Test Suite 'KnownLimitationsTests' passed` and `** TEST SUCCEEDED **` (6 tests).

- [ ] **Step 5: Commit**

```bash
cd "$REPO" && git add App/Sources/App/KnownLimitations.swift App/Tests/App/KnownLimitationsTests.swift
git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -m "Known limitations: Phase 3 profile entries

Advisory and partial profiles, manual update fetch pinned to
raw.githubusercontent.com, sandboxed-app badge, numbered slugs and
export's Trash replacement. Tests assert ids, titles and key phrases.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 6: Write the Phase 3 acceptance checklist**

Same skeleton as `docs/acceptance/phase2-library-app.md` (preconditions, build, numbered steps, teardown, record table), but every check is a top-level `- [ ]` line so `grep -c` can count them (27). Badge expectations come from `CompatBadge.badge(for:profile:)` and the bundled seed: Claude is `verified` (→ `Verified`); Chrome, Terminal and every other seeded app are `partial`, which the badge ignores, so Chrome (chromium) is `Auto` and Terminal (native, not sandboxed) is `HOME only`. The `ProfilesError.insecureURL` text is quoted from `ProfilesError.swift`.

Create `docs/acceptance/phase3-profiles.md`:

````markdown
# Phase 3 acceptance: compatibility profiles

Manual gate. Automated coverage is `Tools/test-app.sh` (MacAppDuplicatorTests) and `swift test --filter CompatProfilesTests`. The steps below need a person at the Mac; Step 10 needs Mike (it launches the real Claude Desktop shortcuts). Tick each box as it passes and fill in the Record table.

## Preconditions

- The Mac is online, and the Phase 3 commits are pushed to `main` on GitHub: the default profiles URL serves `profiles.json` from this repository's `main` branch (Step 6).
- `Claude.app` and `Google Chrome.app` are in `/Applications`; `Claude Work.app` and `Claude Personal.app` are in `~/Applications/App Duplicator` and launch today.
- Default settings: quit App Duplicator and run `defaults delete com.mikekuta.MacAppDuplicator` (an error saying the domain does not exist is fine).
- Bundled profiles only: if `~/Library/Application Support/App Duplicator/profiles.json` exists from an earlier run, move it to the Trash with `mv ~/Library/Application\ Support/App\ Duplicator/profiles.json ~/.Trash/`.
- Run every command from the repository root.

## Step 1: Build

```bash
Tools/build-app.sh --configuration Release
```

- [ ] **1.1** The command prints `<repo>/.build/DerivedData/Build/Products/Release/macOS App Duplicator.app`. Open it with `open "<path>"` (the name contains spaces). Expected: the library window opens and the app menu's About panel shows `Version 0.3.0 (2)`.

## Step 2: Compatibility badges

Press ⌘N, choose `Application`, Next, and read the line under the drop zone (`<App> <version> · <badge>`) as you select each app in turn. Create nothing in this step.

- [ ] **2.1** Select `Claude` in the grid. Expected: `Claude <version> · Verified`.
- [ ] **2.2** Select `Google Chrome`. Expected: `Google Chrome <version> · Auto`. The bundled Chrome profile is `partial` and a partial profile does not change the badge; Chrome shows `Verified` only after the profile is promoted (`docs/acceptance/profile-promotion.md`).
- [ ] **2.3** Click `Browse…`, press ⇧⌘G, go to `/System/Applications/Utilities`, select `Terminal` and click `Open`. Expected: `Terminal <version> · HOME only` (a native app that is not sandboxed; its `partial` profile does not change the badge).
- [ ] **2.4** Select an Electron or Chromium app that has no profile. Obsidian qualifies when `grep -c '"md.obsidian"' Packages/CompatProfiles/Resources/profiles.json` prints `0`; otherwise pick another such app and run the same check with its bundle identifier from `mdls -name kMDItemCFBundleIdentifier "/Applications/<App>.app"`. Expected: `<App> <version> · Auto`. Cancel the wizard.

## Step 3: Wizard prefill and the editor's Profile section

List the bundled profiles that carry arguments or environment variables:

```bash
python3 -I -c '
import json
apps = json.load(open("Packages/CompatProfiles/Resources/profiles.json"))["apps"]
for bid, a in apps.items():
    if a.get("args") or a.get("env"):
        print(bid, a.get("name"), a.get("status"), "args=%s" % json.dumps(a.get("args", [])), "env=%s" % json.dumps(a.get("env", {})), sep="  ")
'
```

Call the first listed app that is installed `<P>`. If the command prints only an empty line, no bundled profile carries arguments or environment: use `Claude` as `<P>` and expect empty Arguments and Environment below.

- [ ] **3.1** ⌘N, `Application`, select `<P>`, Next. Identity: name `Accept Profile`. Data: leave `Auto`. Expected: the note reads `Default: ~/Library/Application Support/App Duplicator/accept-profile`. Next.
- [ ] **3.2** Review. Expected: `Compatibility` shows `<P>`'s badge by the Step 2 rules, and the `Launch plan` disclosure contains the profile's arguments in argv and its environment variables among the additions, exactly as the command printed them. Create.
- [ ] **3.3** In the `Accept Profile` editor, expected: Arguments and Environment hold the profile's values (empty for Claude), and the Profile section shows the match line naming `<P>`'s profile and its status.

## Step 4: Diagnostics

- [ ] **4.1** In the `Accept Profile` editor, type `API_TOKEN` in the empty Environment row's Name field, type `mad-secret-4471` as its value, click ⊕ and Save.
- [ ] **4.2** `Diagnostics…`. Expected: the engine version row reads `1`; the profile rows name the matched profile and its status with every secret-looking value masked; Environment shows `API_TOKEN=••••••`. Click `Copy Report`, then run `pbpaste | grep -c 'mad-secret-4471'`. Expected: `0`. Done.

## Step 5: Data-path guard

In the `Accept Profile` editor, set the data folder to each path below (type it, or use the folder chooser with ⇧⌘G) and Save.

- [ ] **5.1** `~/Documents` (a direct child of your home folder). Expected: Save is refused with an explanation; the stored data folder is unchanged.
- [ ] **5.2** The shortcut's own bundle, `~/Applications/App Duplicator/Accept Profile.app`. Expected: refused the same way.
- [ ] **5.3** The target's own folder, `~/Library/Application Support/<bundle id of P>` (bundle id from the Step 3 command, or `com.anthropic.claudefordesktop` for Claude). Expected: refused the same way.
- [ ] **5.4** Run `mkdir -p ~/Desktop/MAD\ Accept\ Data`, then set the data folder to `~/Desktop/MAD Accept Data` and Save. Expected: accepted; the editor shows the new folder (Step 9 uses it).

## Step 6: Check Profile Updates

- [ ] **6.1** In Settings, copy the profiles URL value somewhere. Expected: an `https://raw.githubusercontent.com/` address on this repository's `main` branch.
- [ ] **6.2** Online, choose Check Profile Updates. Expected: it reports success, and `ls -l ~/Library/Application\ Support/App\ Duplicator/profiles.json` shows a file written just now whose first lines (`head -3` of it) include `"schemaVersion": 1` and an `"updated"` date. Run `shasum -a 256 ~/Library/Application\ Support/App\ Duplicator/profiles.json` and note the hash.
- [ ] **6.3** Turn Wi-Fi off (or unplug the network cable) and choose Check Profile Updates. Expected: an error such as `The Internet connection appears to be offline.`, and the `shasum` command prints the 6.2 hash (the cache is untouched). Turn the network back on.
- [ ] **6.4** Set the profiles URL to `https://example.com/profiles.json` and choose Check Profile Updates. Expected: refused with `https://example.com/profiles.json is not an https://raw.githubusercontent.com address.` (shown when you enter the URL or when you check), and the `shasum` command still prints the 6.2 hash. Paste the 6.1 URL back.

## Step 7: Export into the output folder

- [ ] **7.1** Select `Accept Profile`, `Export…`; in the save panel go to `~/Applications/App Duplicator` (the output folder), name it `Accept Export.app` and Save. Expected: the Export Shortcut sheet shows the library-folder warning and the line saying an existing bundle at the destination is moved to the Trash; `Accept Export` appears in the sidebar. Done.
- [ ] **7.2** Export `Accept Profile` again to the same folder and name, and confirm the save panel's Replace. Expected: the same warning and Trash line; `ls ~/.Trash | grep 'Accept Export'` lists the earlier copy, and `~/Applications/App Duplicator/Accept Export.app` exists. Done.

## Step 8: Rebuild All

- [ ] **8.1** Run `plutil -replace MADEngineVersion -integer 0 ~/Applications/App\ Duplicator/Accept\ Profile.app/Contents/Info.plist`, then choose View → Refresh (⌘R). Expected: `Accept Profile` shows `Needs rebuild` and the toolbar `Rebuild All` enables.
- [ ] **8.2** Click `Rebuild All`. Expected: the sheet opens idle, listing what it will rebuild (including `Accept Profile`), and nothing runs until you start it.
- [ ] **8.3** Start the rebuild. Expected: the sheet shows its running state with progress until every shortcut is done.
- [ ] **8.4** Expected: the sheet shows results, with `Accept Profile` rebuilt successfully. Close it. Expected: the `Needs rebuild` badge is gone and `codesign --verify --deep --strict ~/Applications/App\ Duplicator/Accept\ Profile.app` exits 0 with no output. Note in the Record whether the results listed `Claude Work` and `Claude Personal`.

## Step 9: Delete with data outside the data root

- [ ] **9.1** Select `Accept Profile`, `Delete`. Expected: the sheet offers the data-folder toggle for `~/Desktop/MAD Accept Data`. Turn it on and click Delete. Expected: a second destructive confirmation, because the folder is outside `~/Library/Application Support/App Duplicator`. Confirm. Expected: `Accept Profile.app` and `MAD Accept Data` are in the Trash and the app is still running.

## Step 10: Claude Desktop after Rebuild All (Mike)

- [ ] **10.1** (Mike) `Launch` on `Claude Work`, then on `Claude Personal`. Expected: two Dock icons titled `Claude Work` and `Claude Personal`, both rows show the running dot, and each instance is signed in to its own account (as in Phase 2 Step 6). Quit both.

## Step 11: Known Limitations

- [ ] **11.1** Help → Known Limitations. Expected: 20 entries; the last six are `Compatibility profiles are advisory`, `Partial profiles need manual review`, `Check Profile Updates is manual and fetches from one host`, `Sandboxed native apps cannot be separated`, `Shortcuts whose names match get a numbered slug` and `Export replaces an existing shortcut by moving it to the Trash`.

## Teardown

Move only the test shortcuts to the Trash:

- `~/Applications/App Duplicator/Accept Export.app` (Step 7.2; never launched, so it has no data folder or log)

`Accept Profile.app` and `MAD Accept Data` are already in the Trash (Step 9), and so is the first `Accept Export.app` (Step 7.2). Keep `~/Library/Application Support/App Duplicator/profiles.json`: it is the cache Step 6.2 downloaded. Leave `Claude Work.app` and `Claude Personal.app` in place.

## Record

| Step | Date | Result | Notes |
|---|---|---|---|
| 1 | | | |
| 2 | | | |
| 3 | | | |
| 4 | | | |
| 5 | | | |
| 6 | | | |
| 7 | | | |
| 8 | | | |
| 9 | | | |
| 10 | | | |
| 11 | | | |
````

- [ ] **Step 7: Verify the checklist's step count**

Run: `cd "$REPO" && grep -c '^- \[ \]' docs/acceptance/phase3-profiles.md`
Expected: `27` (1 + 4 + 3 + 2 + 4 + 4 + 2 + 4 + 1 + 1 + 1).

- [ ] **Step 8: Write the profile-promotion procedure**

Field names and rules come from the seed and the catalog: the top-level date is `updated` (`"updated": "2026-10-09"` in `Packages/CompatProfiles/Resources/profiles.json:3`), it must be a real `YYYY-MM-DD` date (`ProfilesError.invalidUpdatedDate`), and `ProfileCatalog.load` prefers a cache only when `ProfileCatalog.isNewer(cached.updated, than: bundled.updated)`, that is, strictly later (`ProfileCatalog.swift:35-53`).

Create `docs/acceptance/profile-promotion.md`:

````markdown
# Promoting a profile from partial to verified

A profile's `status` in `Packages/CompatProfiles/Resources/profiles.json` is `partial` until someone has checked the app end to end on a real Mac, and only then `verified`. The badge shows `Verified` for a verified profile and ignores a partial one (`CompatBadge.badge(for:profile:)`), so promote only what you have checked yourself. A promotion is advisory: it records that the profile worked on one Mac with the app version installed at the time.

## Before you start

- The app is installed at `/Applications/<App>.app` at the version you want to vouch for.
- You have a second account for the app (different from the one the original app is signed in to).
- A current App Duplicator build (`Tools/build-app.sh`) and a clean checkout of `main`.

## Steps

### 1. Re-check the bundle identifier

```bash
mdls -name kMDItemCFBundleIdentifier /Applications/<App>.app
```

Expected: `kMDItemCFBundleIdentifier = "<bundle id>"`, matching the profile's key under `apps` exactly (case included). If it differs, the profile never matches the app: fix the key instead of promoting.

### 2. Create a shortcut with the profile defaults

In App Duplicator, ⌘N, `Application`, select the app, name the shortcut `<App> Promote`, keep the prefilled arguments and environment, leave Data on `Auto` and create it. Expected: the editor's Profile section shows the match line for this profile with status `partial`.

### 3. Sign in to a second account and confirm a separate data folder

Launch `<App> Promote` and sign in to the second account. Expected: `~/Library/Application Support/App Duplicator/<slug>` (the data folder shown in the editor) now holds the app's data, and the original app, launched separately, is still signed in to the first account. Quit both and relaunch both: each comes back signed in to its own account.

### 4. Confirm two Dock icons

With the original app and `<App> Promote` both running, expected: two Dock icons, one titled `<App> Promote`, and both windows usable at the same time. Quit both.

### 5. Edit the profile

In `Packages/CompatProfiles/Resources/profiles.json`:

- set the app's `"status"` to `"verified"`;
- rewrite its `"notes"` to say what was checked, for example `"Verified 2026-10-10 on macOS 26.1 with <App> 1.2.3: second account, separate data folder, two Dock icons."` (drop wording such as `Not launch-tested yet.`);
- set the top-level `"updated"` to today's date (`date +%F`). It must be a real `YYYY-MM-DD` date and strictly later than the value it replaces: the app compares this date (`ProfileCatalog.isNewer`) to decide whether a downloaded or cached `profiles.json` replaces the bundled one, so an unchanged date can leave people on the old copy. If the file already carries today's date, use tomorrow's (`date -v+1d +%F`).

Check that the file still parses and shows the new status:

```bash
python3 -I -c '
import json
doc = json.load(open("Packages/CompatProfiles/Resources/profiles.json"))
print(doc["updated"], doc["apps"]["<bundle id>"]["status"])
'
```

Expected: the new date followed by `verified`.

### 6. Run the profile tests

```bash
swift test --filter CompatProfilesTests 2>&1 | grep -E 'Executed|error:' | tail -3
```

Expected: `Executed … tests, with 0 failures` and no `error:` lines.

### 7. Commit

```bash
git add Packages/CompatProfiles/Resources/profiles.json
git commit -m "Profiles: promote <App> to verified"
git push origin main
```

The next app build bundles the new seed. Existing installs pick it up through Check Profile Updates once the commit is on `main`, because the default profiles URL points at this repository's `main` branch. Move `<App> Promote` and its data folder to the Trash when you are done.
````

- [ ] **Step 9: Verify the promotion procedure's structure**

Run: `cd "$REPO" && grep -c '^### [1-7]\. ' docs/acceptance/profile-promotion.md && grep -c 'mdls -name kMDItemCFBundleIdentifier\|swift test --filter CompatProfilesTests' docs/acceptance/profile-promotion.md`
Expected: `7` then `2`.

- [ ] **Step 10: Commit the acceptance documents**

```bash
cd "$REPO" && git add docs/acceptance/phase3-profiles.md docs/acceptance/profile-promotion.md
git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -m "Acceptance: Phase 3 profiles checklist and promotion procedure

27-step manual gate (badges, prefill, Diagnostics, data-path guard,
Check Profile Updates, export, Rebuild All, delete, Claude two-instance)
and the partial-to-verified profile promotion steps.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 11: Add the README Profiles section and fix the Known Limitations count**

At HEAD `30ea974` the README already names the product correctly (line 58: `` `macOS App Duplicator.app` ``), contains no `MacAppDuplicator.app` and no version string, so there is nothing to rename; Step 12's grep keeps it that way. Two edits:

In `README.md`, replace line 78:

```markdown
- Help → Known Limitations (14 entries).
```

with:

```markdown
- Help → Known Limitations (20 entries since Phase 3; the six profile entries are listed under Phase 3 profiles).
```

Also replace line 65:

```
Tools/test-app.sh          # MacAppDuplicatorTests (108 tests)
```

with:

```
Tools/test-app.sh          # MacAppDuplicatorTests
```

and replace line 93:

```markdown
The Phase 3 insertion point for profiles is the doc comment on `DataSeparationPlanner.plan`.
```

with:

```markdown
Profiles feed `DataSeparationPlanner.plan` through the wizard prefill (`WizardModel(prefillTarget:profileLookup:)`); see "Phase 3 profiles" above.
```

Then insert this block after line 80 (`Acceptance checklist: \`docs/acceptance/phase2-library-app.md\`.`) and its blank line, before `## Core API used by the app`:

```markdown
## Phase 3 profiles

Compatibility profiles (`Packages/CompatProfiles`) record, per bundle identifier, a status (`verified`, `partial` or `unsupported`), suggested launch arguments and environment variables, and notes. The New Shortcut wizard fills a new shortcut's arguments and environment from the matching profile, the editor's Profile section shows which profile matched, and Diagnostics lists it.

### What a badge means

The compatibility badge in the New Shortcut wizard is evaluated in this order (`CompatBadge.badge(for:profile:)`):

- `Unsupported`: the profile marks the app unsupported (typically an app that refuses to run twice).
- `Verified`: the profile was checked end to end on one Mac (second account, separate data folder, two Dock icons). It is advisory, not a guarantee for your app version or setup.
- `Unknown`: no app inspected yet, or a sandboxed native app, whose container ignores the HOME override so its data cannot be separated.
- `HOME only`: any other native app; App Duplicator applies the HOME override, untested for this app.
- `Auto`: a Chromium, Electron, ToDesktop, Firefox or Eclipse app without a verified profile; App Duplicator applies its family's data separation, untested for this app.

A `partial` profile still fills in arguments and environment but does not change the badge, so review those values before relying on them. `docs/acceptance/profile-promotion.md` is the procedure that moves a profile from `partial` to `verified`.

### Checking for profile updates

- Profiles change only when you choose Check Profile Updates. Nothing checks automatically or in the background.
- The default profiles URL is the raw `profiles.json` on this repository's `main` branch, so a profile change reaches existing installs once it is on `main`. The URL is a setting, and only `https://raw.githubusercontent.com` addresses are accepted (`ProfilesFetchPolicy.allowedHost`).
- A successful check writes the cache `~/Library/Application Support/App Duplicator/profiles.json`. A failed or invalid download leaves the cache as it was.
- The app uses the cache only when its `updated` date is later than the bundled seed's (`Packages/CompatProfiles/Resources/profiles.json`); otherwise it uses the seed.

### Profile limitations

Also listed in Help → Known Limitations:

- Profiles are advisory: `Verified` means checked on one Mac, not a guarantee.
- `partial` profiles need manual review.
- Check Profile Updates is manual and fetches only from `raw.githubusercontent.com`.
- Sandboxed native apps cannot be separated (`Unknown`, or `Unsupported` when a profile says so).
- Shortcuts whose names give the same slug get `-2`, `-3` and so on appended, so they never share a bundle identifier or default data folder.
- Exporting over an existing bundle moves the old one to the Trash.

Acceptance checklist: `docs/acceptance/phase3-profiles.md`. Promotion procedure: `docs/acceptance/profile-promotion.md`.
```

- [ ] **Step 12: Verify the README**

Run: `cd "$REPO" && grep -n -E 'MacAppDuplicator\.app|108 tests|insertion point' README.md; grep -c '^## Phase 3 profiles$' README.md; grep -n '20 entries' README.md`
Expected: no output from the first grep, then `1`, then `78:- Help → Known Limitations (20 entries since Phase 3; the six profile entries are listed under Phase 3 profiles).`

- [ ] **Step 13: Bump the version to 0.3.0 (build 2)**

In `App/project.yml`, replace lines 56–57:

```yaml
        CURRENT_PROJECT_VERSION: "1"
        MARKETING_VERSION: "0.2.0"
```

with:

```yaml
        CURRENT_PROJECT_VERSION: "2"
        MARKETING_VERSION: "0.3.0"
```

No test asserts the version: `grep -rn '0\.2\.0' App/Tests Packages/*/Tests` printed nothing at HEAD `30ea974`, so no test file changes.

Run: `cd "$REPO" && grep -n 'MARKETING_VERSION\|CURRENT_PROJECT_VERSION' App/project.yml; grep -rn '0\.2\.0' App/Tests Packages/*/Tests App/project.yml`
Expected: `56:        CURRENT_PROJECT_VERSION: "2"` and `57:        MARKETING_VERSION: "0.3.0"`, then no output from the second grep.

Run: `cd "$REPO" && APP="$(Tools/build-app.sh 2>&1 | tail -1)" && /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"`
Expected: `0.3.0` then `2`.

- [ ] **Step 14: Run the full app suite**

Run: `cd "$REPO" && Tools/test-app.sh 2>&1 | tail -4`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 15: Commit the README and version bump**

```bash
cd "$REPO" && git add README.md App/project.yml
git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -m "README Profiles section; version 0.3.0 (2)

Badge meanings, manual Check Profile Updates, cache location and the
main-branch default URL; profile limitations; Known Limitations count
now 20. MARKETING_VERSION 0.3.0, CURRENT_PROJECT_VERSION 2.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---
