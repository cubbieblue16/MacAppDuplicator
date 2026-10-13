# macOS App Duplicator Phase 3 (Profiles) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship compatibility profiles: the `CompatProfiles` library (schema, validation, bundled seed, cached remote copy), user-triggered Check Profile Updates, profile-driven compat badges and creation defaults, profile and engine details in Diagnostics, argv secret masking, a Rebuild All that runs off the main actor and reports per-shortcut results, and the Phase 2 hardening carry-over (spec §8, §7, §12 phase 3).

**Architecture:** Compatibility profiles live in a new SwiftPM library `CompatProfiles` (`Packages/CompatProfiles`, depends on `DuplicatorCore`) that only the app and its tests link: the Launcher never reads profiles, so `URLSession` stays out of `DuplicatorCore` and out of every shortcut bundle, and spec §3 and §10 already treat Profiles as its own unit tested next to Core. A profile's `args` and `env` are copied into the new shortcut's `ShortcutConfig.arguments` and `ShortcutConfig.environment` when the shortcut is created (editable afterwards), so `DataSeparationPlanner`, the bundle layout and `ShortcutConfig.currentEngineVersion` (`1`) stay unchanged and the spec §4.4 merge order still holds. The app owns one `ProfilesModel` (bundled seed plus a cached remote copy that wins only when strictly newer) that drives badges, wizard defaults, the editor's read-only Profile section and Diagnostics; Rebuild All moves the builder off the main actor and reports per-shortcut results; the Phase 2 hardening carry-over (data-path guard, export, delete, icon preview, slug de-duplication, scan generations, test-host hygiene) lands in the same phase.

**Tech Stack:** Swift 6 language mode (Xcode 27.0, Swift 6.4), macOS 26+ arm64, SwiftUI + AppKit (app), Foundation + Darwin (Core), Foundation + DuplicatorCore (`CompatProfiles`: `JSONDecoder`, `NSRegularExpression`, ephemeral `URLSession`), Synchronization (`Mutex`, app tests and package tests), xcodegen 2.45.3 (`/usr/local/bin/xcodegen`), XCTest.

> **Scope note:** This file holds Tasks 1–7 (profiles library, fetch/update, app wiring, argv masking, badges and defaults, Rebuild All, data-path/export/delete hardening). Tasks 8–10 (icon preview, shortcut-as-target refusal, slug de-duplication, scan/monitor generations, `FolderWatcher` deinit, test-host hygiene, known limitations, acceptance docs, README, version 0.3.0) live in `docs/superpowers/plans/2026-10-10-phase3-part2-hardening.md`. The File map below lists all ten for orientation.

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

## File map

| Path | Responsibility | Task |
|---|---|---|
| `Package.swift`, `Packages/CompatProfiles/Sources/CompatProfiles/{ProfilesError,ProfilesDocument,ProfileCatalog}.swift`, `Packages/CompatProfiles/Tests/CompatProfilesTests/{TestSupport,ProfilesDocumentTests,ProfileCatalogTests}.swift` | `profiles.json` schema, validation of untrusted input, catalog with bundled/cached precedence | 1 |
| `Packages/CompatProfiles/Sources/CompatProfiles/{ProfilesFetching,ProfilesUpdater,ProfilesConstants}.swift`, `Packages/CompatProfiles/Tests/CompatProfilesTests/{ProfilesFetchPolicyTests,ProfilesUpdaterTests,URLSessionProfilesFetcherTests}.swift` | Fetch policy, `URLSession` fetcher, validated cache write | 2 |
| `Packages/CompatProfiles/Resources/profiles.json`, `Packages/CompatProfiles/Tests/CompatProfilesTests/SeedProfilesTests.swift`, `App/project.yml`, `App/Sources/Model/ProfilesModel.swift`, `App/Sources/Model/AppSettings.swift`, `App/Sources/App/{LaunchEnvironment,AppState,MacAppDuplicatorApp}.swift`, `App/Sources/Views/{ContentView,SettingsView}.swift`, `App/Tests/TestSupport/AppTestSupport.swift`, `App/Tests/SmokeTests.swift`, `App/Tests/Model/{ProfilesModelTests,AppSettingsTests}.swift`, `App/Tests/App/{LaunchEnvironmentTests,AppStateTests}.swift` | Bundled seed, app wiring, Check Profile Updates, profiles URL setting | 3 |
| `Packages/DuplicatorCore/Sources/DuplicatorCore/{SecretMasking,LaunchLogger}.swift`, `Launcher/Sources/Launcher/main.swift`, `App/Sources/Services/{LaunchPlanPreview,ExportInstructions}.swift`, `App/Sources/Views/{DiagnosticsView,ExportSheet,ShortcutEditorView}.swift` + their tests | argv secret masking in the Launcher log, Diagnostics, previews and the export notice; Diagnostics engine version | 4 |
| `App/Sources/Services/{CompatBadge,ProfileSummary,LaunchPlanPreview}.swift`, `App/Sources/Views/{ProfileSummaryView,EditorSections,ShortcutEditorView,DiagnosticsView}.swift`, `App/Sources/Views/Wizard/{WizardModel,NewShortcutWizard,WizardSteps}.swift`, `Packages/DuplicatorCore/Sources/DuplicatorCore/DataSeparationPlanner.swift` (doc comment) + tests | Profile-driven badges, creation defaults, read-only Profile section, Diagnostics profile match | 5 |
| `App/Sources/Services/ShortcutBuilder.swift`, `App/Sources/Model/RebuildResult.swift`, `App/Sources/App/AppState.swift`, `App/Sources/Views/{RebuildAllSheet,ContentView}.swift`, `App/Tests/Model/RebuildSummaryTests.swift`, `App/Tests/App/AppStateTests.swift` | Rebuild All off the main actor with per-shortcut results (M16) | 6 |
| `App/Sources/Services/{CanonicalPath,DataPathGuard,ShortcutBuilder,TargetResolver+ResolvedPath,DeleteConfirmation}.swift`, `App/Sources/App/AppState.swift`, `App/Sources/Views/{DeleteShortcutSheet,ExportSheet,ShortcutEditorView,EditorSections}.swift`, `App/Sources/Views/Wizard/WizardSteps.swift` + tests | Data-path guard widening, export trash-and-sweep, delete confirmation (re-review Minors 1, 2, 4, 5, 6; M24) | 7 |
| `App/Sources/Services/IconPreviewSource.swift`, `App/Sources/Views/IconPreview.swift`, `App/Sources/Model/LibraryScanner.swift`, `App/Sources/Services/ShortcutBuilder.swift`, `App/Sources/App/AppState.swift`, wizard and editor views, `App/Sources/Views/ContentView.swift` + tests | Draft icon preview (M4), shortcut-as-target refusal (M5), slug de-duplication (M6) | 8 |
| `App/Sources/Model/{ShortcutLibrary,RunningShortcutMonitor,FolderWatcher}.swift`, `App/Sources/App/{LaunchEnvironment,MacAppDuplicatorApp}.swift`, `Tools/test-app.sh`, `App/Tests/TestSupport/AppTestSupport.swift`, `App/Tests/Model/{ShortcutLibraryTests,RunningShortcutMonitorTests,FolderWatcherTests}.swift`, `App/Tests/App/LaunchEnvironmentTests.swift` | Scan and monitor generations (M7), `FolderWatcher` deinit (M8), test-host window suppression and preference residue (re-review Minor 7) | 9 |
| `App/Sources/App/KnownLimitations.swift`, `App/Tests/App/KnownLimitationsTests.swift`, `docs/acceptance/phase3-profiles.md`, `docs/acceptance/profile-promotion.md`, `README.md`, `App/project.yml` | Known limitations, acceptance checklist, promotion procedure, README, version 0.3.0 | 10 |

---

### Task 1: CompatProfiles library — schema, validation and catalog

**Files:**
- Modify: `Package.swift:7-24` (new `CompatProfiles` product, target and test target; whole file shown)
- Create: `Packages/CompatProfiles/Sources/CompatProfiles/ProfilesError.swift`
- Create: `Packages/CompatProfiles/Sources/CompatProfiles/ProfilesDocument.swift`
- Create: `Packages/CompatProfiles/Sources/CompatProfiles/ProfileCatalog.swift`
- Test: `Packages/CompatProfiles/Tests/CompatProfilesTests/TestSupport.swift`
- Test: `Packages/CompatProfiles/Tests/CompatProfilesTests/ProfilesDocumentTests.swift`
- Test: `Packages/CompatProfiles/Tests/CompatProfilesTests/ProfileCatalogTests.swift`

**Interfaces:**
- Consumes: `DuplicatorCore.AppFamily` (`public enum AppFamily: String, Codable, Sendable { case todesktop, electron, chromium, firefox, eclipse, native }`).
- Produces (used by Tasks 2, 3, 5, 10):
  - `public enum ProfilesError: Error, Equatable, LocalizedError` with cases `tooLarge(Int)`, `malformed(String)`, `unsupportedSchemaVersion(Int)`, `invalidUpdatedDate(String)`, `invalidField(String)`, `tooMany(String)`, `insecureURL(String)`, `httpStatus(Int)`, `fetchFailed(String)`.
  - `public enum ProfileStatus: String, Codable, Sendable, CaseIterable { case verified, partial, unsupported }`.
  - `public struct AppProfile: Decodable, Equatable, Sendable` — `name: String`, `status: ProfileStatus`, `family: AppFamily?`, `args: [String]`, `env: [String: String]`, `newWindowCommand: String?`, `notes: String?`; `init(name:status:family: = nil, args: = [], env: = [:], newWindowCommand: = nil, notes: = nil)`.
  - `public struct WebAppPreset: Decodable, Equatable, Sendable` — `name: String`, `url: String`, `userAgent: String?`, `badgeRegex: String?`, `extraHosts: [String]`, `iconURL: String?`; `init(name:url:userAgent: = nil, badgeRegex: = nil, extraHosts: = [], iconURL: = nil)`.
  - `public struct ProfilesDocument: Decodable, Equatable, Sendable` — `schemaVersion: Int`, `updated: String`, `apps: [String: AppProfile]`, `webApps: [String: WebAppPreset]`; statics `supportedSchemaVersion = 1`, `maxBytes = 1_048_576`, `maxStringLength = 2_048`, `maxApps = 500`, `maxWebApps = 200`, `maxListEntries = 64`; `init(schemaVersion: = 1, updated:, apps: = [:], webApps: = [:])`; `static func decodeValidated(from data: Data) throws -> ProfilesDocument`.
  - `public enum ProfileSource: String, Sendable { case bundled, cached }`.
  - `public struct ProfileCatalog: Equatable, Sendable` — `document: ProfilesDocument`, `source: ProfileSource`, `updated: String`, `appCount: Int`, `static let empty`, `init(document:source:)`, `func profile(forBundleIdentifier: String) -> AppProfile?`, `static func load(bundledURL: URL?, cacheURL: URL) -> ProfileCatalog`, `static func isNewer(_ candidate: String, than current: String) -> Bool`.
  - Test helpers (target `CompatProfilesTests` only): `makeTemporaryDirectory() throws -> URL`, `makeProfilesData(schemaVersion:updated:apps:webApps:extra:) throws -> Data`, `jsonData(_:) throws -> Data`, `appEntry(name:status:extra:) -> [String: Any]`, `webAppEntry(extra:) -> [String: Any]`, `assertRejects(_:with:file:line:)`, `writeFile(_:named:in:) throws -> URL`.

- [ ] **Step 1: Add the package target and its error type**

The library target needs at least one source file, so the error type that every later file uses comes first. Replace `Package.swift` with:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacAppDuplicator",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DuplicatorCore", targets: ["DuplicatorCore"]),
        .library(name: "CompatProfiles", targets: ["CompatProfiles"]),
        .executable(name: "Launcher", targets: ["Launcher"]),
        .executable(name: "madctl", targets: ["madctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "DuplicatorCore", path: "Packages/DuplicatorCore/Sources/DuplicatorCore"),
        .testTarget(name: "DuplicatorCoreTests", dependencies: ["DuplicatorCore"],
                    path: "Packages/DuplicatorCore/Tests/DuplicatorCoreTests"),
        // Compatibility profiles (spec §8). Linked by the app and its tests only; the Launcher never reads profiles.
        .target(name: "CompatProfiles", dependencies: ["DuplicatorCore"],
                path: "Packages/CompatProfiles/Sources/CompatProfiles"),
        .testTarget(name: "CompatProfilesTests", dependencies: ["CompatProfiles", "DuplicatorCore"],
                    path: "Packages/CompatProfiles/Tests/CompatProfilesTests"),
        .executableTarget(name: "Launcher", dependencies: ["DuplicatorCore"], path: "Launcher/Sources/Launcher"),
        .executableTarget(name: "madctl",
                          dependencies: ["DuplicatorCore", .product(name: "ArgumentParser", package: "swift-argument-parser")],
                          path: "Tools/madctl/Sources/madctl"),
        .testTarget(name: "IntegrationTests", path: "Tests/Integration"),
    ],
    swiftLanguageModes: [.v6]
)
```

Create `Packages/CompatProfiles/Sources/CompatProfiles/ProfilesError.swift`:

```swift
import Foundation

/// Why a `profiles.json` document or a profile update was refused. Every description is a full sentence for the UI.
public enum ProfilesError: Error, Equatable, LocalizedError {
    /// The document is larger than `ProfilesDocument.maxBytes`; carries its byte count.
    case tooLarge(Int)
    /// The bytes are not JSON of the schema-1 shape; carries a short reason that never echoes document values.
    case malformed(String)
    /// `schemaVersion` is not `ProfilesDocument.supportedSchemaVersion`.
    case unsupportedSchemaVersion(Int)
    /// `updated` is not a real `YYYY-MM-DD` date.
    case invalidUpdatedDate(String)
    /// A key or value broke a validation rule; carries its JSON path.
    case invalidField(String)
    /// A collection is over its cap; carries its JSON path.
    case tooMany(String)
    /// A URL is not an allowed `https://raw.githubusercontent.com` address.
    case insecureURL(String)
    /// The server answered with a status other than 200.
    case httpStatus(Int)
    /// The transfer failed; carries the system's description.
    case fetchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let bytes):
            "The profiles file is \(bytes) bytes; the limit is 1,048,576."
        case .malformed(let detail):
            "The profiles file is not valid JSON for schema 1: \(detail)"
        case .unsupportedSchemaVersion(let version):
            "The profiles file uses schema version \(version); this build reads version 1."
        case .invalidUpdatedDate(let value):
            "The profiles file has an invalid updated date “\(value)”; expected YYYY-MM-DD."
        case .invalidField(let path):
            "The profiles file has an invalid value: \(path)."
        case .tooMany(let path):
            "The profiles file has too many entries in \(path)."
        case .insecureURL(let url):
            "\(url) is not an https://raw.githubusercontent.com address."
        case .httpStatus(let code):
            "The profiles server answered HTTP \(code)."
        case .fetchFailed(let message):
            message
        }
    }
}
```

SwiftPM refuses a target whose `path` does not exist, so create the test directory now (it stays empty until Step 3):

```bash
cd "$REPO" && mkdir -p Packages/CompatProfiles/Tests/CompatProfilesTests
```

- [ ] **Step 2: Confirm the new target builds**

Run: `cd "$REPO" && swift build --target CompatProfiles 2>&1 | grep -vE '^\[' | tail -3`
Expected: `Build complete!` and no `error:` lines. SwiftPM also prints `warning: … Source files for target CompatProfilesTests should be located under …` until Step 3 adds the first test file; that warning is expected here.

- [ ] **Step 3: Write the test support and the failing document tests**

Create `Packages/CompatProfiles/Tests/CompatProfilesTests/TestSupport.swift`:

```swift
import Foundation
import XCTest
@testable import CompatProfiles

extension XCTestCase {
    /// A new empty directory under the system temporary directory, deleted when the test ends.
    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "CompatProfilesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

/// JSON bytes for a hand-built object (sorted keys, so failures are reproducible).
func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

/// `profiles.json` bytes built from plain values, so each test varies only the fields it is about.
func makeProfilesData(schemaVersion: Any = 1, updated: Any = "2026-10-09", apps: [String: Any] = [:],
                      webApps: [String: Any]? = nil, extra: [String: Any] = [:]) throws -> Data {
    var object: [String: Any] = ["schemaVersion": schemaVersion, "updated": updated, "apps": apps]
    if let webApps { object["webApps"] = webApps }
    object.merge(extra) { _, new in new }
    return try jsonData(object)
}

/// The smallest valid `apps` entry, plus `extra` fields.
func appEntry(name: String = "Example", status: String = "partial", extra: [String: Any] = [:]) -> [String: Any] {
    var entry: [String: Any] = ["name": name, "status": status]
    entry.merge(extra) { _, new in new }
    return entry
}

/// The smallest valid `webApps` entry, plus `extra` fields.
func webAppEntry(extra: [String: Any] = [:]) -> [String: Any] {
    var entry: [String: Any] = ["name": "WhatsApp", "url": "https://web.whatsapp.com"]
    entry.merge(extra) { _, new in new }
    return entry
}

/// Asserts that `ProfilesDocument.decodeValidated(from:)` refuses `data` with exactly `expected`.
func assertRejects(_ data: Data, with expected: ProfilesError, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try ProfilesDocument.decodeValidated(from: data), file: file, line: line) { error in
        XCTAssertEqual(error as? ProfilesError, expected, file: file, line: line)
    }
}

/// Writes `data` to `name` inside `directory` and returns the file URL.
func writeFile(_ data: Data, named name: String, in directory: URL) throws -> URL {
    let url = directory.appending(path: name, directoryHint: .notDirectory)
    try data.write(to: url)
    return url
}
```

Create `Packages/CompatProfiles/Tests/CompatProfilesTests/ProfilesDocumentTests.swift`:

```swift
import DuplicatorCore
import XCTest
@testable import CompatProfiles

final class ProfilesDocumentTests: XCTestCase {
    func testDecodesTheSpecExample() throws {
        let json = #"""
        {
          "schemaVersion": 1,
          "updated": "2026-10-09",
          "apps": {
            "com.anthropic.claudefordesktop": {
              "name": "Claude",
              "status": "verified",
              "family": "electron",
              "args": [],
              "env": {},
              "newWindowCommand": null,
              "notes": "Each instance has its own claude_desktop_config.json inside the data folder."
            }
          },
          "webApps": { "whatsapp": { "name": "WhatsApp", "url": "https://web.whatsapp.com", "userAgent": "chrome", "badgeRegex": "\\((\\d+)\\)", "extraHosts": ["whatsapp.com"], "iconURL": "..." } }
        }
        """#

        let document = try ProfilesDocument.decodeValidated(from: Data(json.utf8))

        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.updated, "2026-10-09")
        XCTAssertEqual(document.apps, ["com.anthropic.claudefordesktop": AppProfile(
            name: "Claude", status: .verified, family: .electron,
            notes: "Each instance has its own claude_desktop_config.json inside the data folder.")])
        XCTAssertEqual(document.webApps, ["whatsapp": WebAppPreset(
            name: "WhatsApp", url: "https://web.whatsapp.com", userAgent: "chrome", badgeRegex: #"\((\d+)\)"#,
            extraHosts: ["whatsapp.com"], iconURL: "...")])
    }

    func testUnknownKeysAreTolerated() throws {
        let data = try makeProfilesData(
            apps: ["com.example.app": appEntry(extra: ["minimumVersion": "2.0", "tags": ["a", "b"]])],
            webApps: ["whatsapp": webAppEntry(extra: ["sandbox": true])],
            extra: ["generator": "hand-written", "mirrors": ["https://example.com"]])

        let document = try ProfilesDocument.decodeValidated(from: data)

        XCTAssertEqual(document.apps["com.example.app"]?.name, "Example")
        XCTAssertEqual(document.webApps["whatsapp"]?.url, "https://web.whatsapp.com")
    }

    func testMissingOptionalFieldsTakeDefaults() throws {
        let document = try ProfilesDocument.decodeValidated(from: makeProfilesData(apps: ["com.example.app": appEntry()]))

        XCTAssertEqual(document.apps["com.example.app"], AppProfile(name: "Example", status: .partial))
        XCTAssertEqual(document.webApps, [:])

        let web = try ProfilesDocument.decodeValidated(from: makeProfilesData(webApps: ["whatsapp": webAppEntry()]))
        XCTAssertEqual(web.webApps["whatsapp"], WebAppPreset(name: "WhatsApp", url: "https://web.whatsapp.com"))
    }

    func testUnknownFamilyDecodesAsNil() throws {
        let data = try makeProfilesData(apps: [
            "com.example.qt": appEntry(extra: ["family": "qt"]),
            "com.example.null": appEntry(extra: ["family": NSNull()]),
            "com.example.chromium": appEntry(extra: ["family": "chromium"]),
        ])

        let apps = try ProfilesDocument.decodeValidated(from: data).apps

        XCTAssertEqual(apps.count, 3, "an unknown family never drops the entry")
        XCTAssertNil(apps["com.example.qt"]?.family)
        XCTAssertNil(apps["com.example.null"]?.family)
        XCTAssertEqual(apps["com.example.chromium"]?.family, .chromium)
    }

    func testRejectsUnsupportedSchemaVersion() throws {
        assertRejects(try makeProfilesData(schemaVersion: 2), with: .unsupportedSchemaVersion(2))
        assertRejects(try makeProfilesData(schemaVersion: 0), with: .unsupportedSchemaVersion(0))
        // The version gate runs before the full decode, so a future layout is reported as a version problem.
        assertRejects(try makeProfilesData(schemaVersion: 2, extra: ["apps": ["not", "a", "dictionary"]]),
                      with: .unsupportedSchemaVersion(2))
    }

    func testRejectsMalformedJSON() throws {
        assertRejects(Data("not json".utf8), with: .malformed("the data is not valid JSON"))
        assertRejects(try jsonData(["updated": "2026-10-09", "apps": [String: Any]()]),
                      with: .malformed("missing key schemaVersion"))
        assertRejects(try jsonData(["schemaVersion": 1, "updated": "2026-10-09"]),
                      with: .malformed("missing key apps"))
        assertRejects(try makeProfilesData(apps: ["com.example.app": ["status": "partial"]]),
                      with: .malformed("missing key apps.com.example.app.name"))
        let wrongType = try makeProfilesData(apps: ["com.example.app": appEntry(extra: ["args": "--single-string"])])
        XCTAssertThrowsError(try ProfilesDocument.decodeValidated(from: wrongType)) { error in
            guard case .malformed = error as? ProfilesError else { return XCTFail("expected malformed, got \(error)") }
        }
    }

    func testRejectsUnknownStatus() throws {
        assertRejects(try makeProfilesData(apps: ["com.example.app": appEntry(status: "beta")]),
                      with: .invalidField("apps.com.example.app.status"))
        assertRejects(try makeProfilesData(apps: ["com.example.app": appEntry(status: "Verified")]),
                      with: .invalidField("apps.com.example.app.status"))
    }

    func testRejectsBadUpdatedDates() throws {
        let bad = ["2026-13-01", "2026-02-30", "2026-00-10", "26-10-09", "2026-1-09", "2026-10-09T00:00:00Z", "",
                   " 2026-10-09", "2026-10-09\n"]
        for updated in bad {
            assertRejects(try makeProfilesData(updated: updated), with: .invalidUpdatedDate(updated))
        }
        XCTAssertNoThrow(try ProfilesDocument.decodeValidated(from: makeProfilesData(updated: "2028-02-29")), "leap day")
    }

    func testRejectsOversizedInput() throws {
        assertRejects(Data(repeating: UInt8(ascii: " "), count: ProfilesDocument.maxBytes + 1), with: .tooLarge(1_048_577))

        var atLimit = try makeProfilesData(apps: ["com.example.app": appEntry()])
        atLimit.append(Data(repeating: UInt8(ascii: " "), count: ProfilesDocument.maxBytes - atLimit.count))
        XCTAssertEqual(atLimit.count, ProfilesDocument.maxBytes)
        XCTAssertNoThrow(try ProfilesDocument.decodeValidated(from: atLimit), "trailing whitespace up to the cap is valid")
    }

    func testRejectsLongStringsAndNUL() throws {
        let limit = String(repeating: "a", count: ProfilesDocument.maxStringLength)
        XCTAssertNoThrow(try ProfilesDocument.decodeValidated(from: makeProfilesData(apps: ["com.example.app": appEntry(name: limit)])))

        let cases: [(entry: [String: Any], path: String)] = [
            (appEntry(name: limit + "a"), "apps.com.example.app.name"),
            (appEntry(name: ""), "apps.com.example.app.name"),
            (appEntry(extra: ["notes": "line\u{0}break"]), "apps.com.example.app.notes"),
            (appEntry(extra: ["args": ["--ok", "bad\u{0}"]]), "apps.com.example.app.args[1]"),
            (appEntry(extra: ["env": ["API_URL": limit + "a"]]), "apps.com.example.app.env.API_URL"),
            (appEntry(extra: ["newWindowCommand": limit + "a"]), "apps.com.example.app.newWindowCommand"),
        ]
        for (entry, path) in cases {
            assertRejects(try makeProfilesData(apps: ["com.example.app": entry]), with: .invalidField(path))
        }
    }

    func testRejectsTooManyEntries() throws {
        func apps(_ count: Int) -> [String: Any] {
            Dictionary(uniqueKeysWithValues: (0..<count).map { ("com.example.app\($0)", appEntry() as Any) })
        }
        XCTAssertEqual(try ProfilesDocument.decodeValidated(from: makeProfilesData(apps: apps(500))).apps.count, 500)
        assertRejects(try makeProfilesData(apps: apps(501)), with: .tooMany("apps"))

        let webApps = Dictionary(uniqueKeysWithValues: (0...200).map { ("web\($0)", webAppEntry() as Any) })
        assertRejects(try makeProfilesData(webApps: webApps), with: .tooMany("webApps"))

        let arguments = (0...64).map { "--flag\($0)" }
        assertRejects(try makeProfilesData(apps: ["com.example.app": appEntry(extra: ["args": arguments])]),
                      with: .tooMany("apps.com.example.app.args"))
        let environment = Dictionary(uniqueKeysWithValues: (0...64).map { ("VAR_\($0)", "1") })
        assertRejects(try makeProfilesData(apps: ["com.example.app": appEntry(extra: ["env": environment])]),
                      with: .tooMany("apps.com.example.app.env"))
        let hosts = (0...64).map { "host\($0).example.com" }
        assertRejects(try makeProfilesData(webApps: ["whatsapp": webAppEntry(extra: ["extraHosts": hosts])]),
                      with: .tooMany("webApps.whatsapp.extraHosts"))
    }

    func testRejectsBadKeys() throws {
        let badIdentifiers = ["", "-leading.dash", "has space", "com.example/app", "com.example.app\n",
                              String(repeating: "a", count: 256)]
        for identifier in badIdentifiers {
            assertRejects(try makeProfilesData(apps: [identifier: appEntry()]),
                          with: .invalidField("apps." + String(identifier.prefix(100))))
        }
        assertRejects(try makeProfilesData(apps: ["com.Example.App": appEntry(), "com.example.app": appEntry()]),
                      with: .invalidField("apps.com.example.app duplicates another bundle identifier"))
        for key in ["1BAD", "HAS-DASH", "", "SPACE KEY"] {
            assertRejects(try makeProfilesData(apps: ["com.example.app": appEntry(extra: ["env": [key: "1"]])]),
                          with: .invalidField("apps.com.example.app.env.\(key)"))
        }
        for key in ["WhatsApp", "-web", "web_app", ""] {
            assertRejects(try makeProfilesData(webApps: [key: webAppEntry()]), with: .invalidField("webApps.\(key)"))
        }
    }

    func testRejectsInsecureOrInvalidWebAppFields() throws {
        let cases: [(extra: [String: Any], path: String)] = [
            (["url": "http://web.whatsapp.com"], "webApps.whatsapp.url"),
            (["url": "https://"], "webApps.whatsapp.url"),
            (["url": "javascript:alert(1)"], "webApps.whatsapp.url"),
            (["url": "file:///etc/passwd"], "webApps.whatsapp.url"),
            (["name": ""], "webApps.whatsapp.name"),
            (["userAgent": "x\u{0}"], "webApps.whatsapp.userAgent"),
            (["badgeRegex": "(unclosed"], "webApps.whatsapp.badgeRegex"),
            (["extraHosts": ["whatsapp.com", "bad host"]], "webApps.whatsapp.extraHosts[1]"),
            (["extraHosts": ["-bad.example.com"]], "webApps.whatsapp.extraHosts[0]"),
        ]
        for (extra, path) in cases {
            assertRejects(try makeProfilesData(webApps: ["whatsapp": webAppEntry(extra: extra)]), with: .invalidField(path))
        }
    }

    func testRejectsLaunchControlEnvironmentAndArguments() throws {
        // Fetched profiles are untrusted: they may not inject code into the target or take over data separation.
        for key in ["DYLD_INSERT_LIBRARIES", "LD_PRELOAD", "MAD_SHORTCUT_NAME", "XRE_PROFILE_PATH", "NODE_OPTIONS",
                    "ELECTRON_RUN_AS_NODE", "JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "HOME", "CFFIXED_USER_HOME"] {
            assertRejects(try makeProfilesData(apps: ["com.example.app": appEntry(extra: ["env": [key: "x"]])]),
                          with: .invalidField("apps.com.example.app.env.\(key)"))
        }
        for argument in ["--inspect", "--inspect-brk=9229", "--INSPECT", "--remote-debugging-port=9222",
                         "-remote-debugging-pipe", "--load-extension=/tmp/x", "--disable-web-security", "--no-sandbox",
                         "--renderer-cmd-prefix=/bin/sh", "--user-data-dir=/tmp/y", "--profile-directory=Work",
                         "-profile", "-P", "-data", "-vmargs", "-javaagent:/tmp/agent.jar"] {
            assertRejects(try makeProfilesData(apps: ["com.example.app": appEntry(extra: ["args": [argument]])]),
                          with: .invalidField("apps.com.example.app.args[0]"))
        }
        let allowed = try makeProfilesData(apps: ["com.example.app": appEntry(extra: [
            "args": ["--enable-features=Foo", "--force-dark-mode", "-new-instance", "--homepage-flag"],
            "env": ["ELECTRON_ENABLE_LOGGING": "1", "HOMEBREW_NO_ANALYTICS": "1", "DYLDX": "1"],
        ])])
        XCTAssertNoThrow(try ProfilesDocument.decodeValidated(from: allowed))
    }
}
```

- [ ] **Step 4: Run the document tests to verify they fail**

Run: `cd "$REPO" && swift test --filter CompatProfilesTests 2>&1 | grep -oE "cannot find '[A-Za-z]+' in scope" | sort -u`
Expected: `cannot find 'ProfilesDocument' in scope` (compile error; nothing runs).

- [ ] **Step 5: Implement the document model and its validation**

Create `Packages/CompatProfiles/Sources/CompatProfiles/ProfilesDocument.swift`:

```swift
import DuplicatorCore
import Foundation

/// How far a profile has been tested (spec §8). Only `verified` profiles passed a real launch test on Mike's Mac.
public enum ProfileStatus: String, Codable, Sendable, CaseIterable {
    case verified, partial, unsupported
}

/// One `apps` entry; `ProfilesDocument.apps` keys it by bundle identifier (spec §8).
public struct AppProfile: Decodable, Equatable, Sendable {
    public var name: String
    public var status: ProfileStatus
    /// The family the profile was written for. Nil when the key is absent, null or names a family this build does not know.
    public var family: AppFamily?
    /// Copied into `ShortcutConfig.arguments` when a shortcut is created.
    public var args: [String]
    /// Copied into `ShortcutConfig.environment` when a shortcut is created.
    public var env: [String: String]
    /// Stored but inert until Phase 6.
    public var newWindowCommand: String?
    public var notes: String?

    public init(name: String, status: ProfileStatus, family: AppFamily? = nil, args: [String] = [],
                env: [String: String] = [:], newWindowCommand: String? = nil, notes: String? = nil) {
        self.name = name
        self.status = status
        self.family = family
        self.args = args
        self.env = env
        self.newWindowCommand = newWindowCommand
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case name, status, family, args, env, newWindowCommand, notes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        let rawStatus = try container.decode(String.self, forKey: .status)
        guard let status = ProfileStatus(rawValue: rawStatus) else {
            throw ProfilesError.invalidField(profilesPath(decoder.codingPath, leaf: "status"))
        }
        self.status = status
        family = try container.decodeIfPresent(String.self, forKey: .family).flatMap(AppFamily.init(rawValue:))
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        newWindowCommand = try container.decodeIfPresent(String.self, forKey: .newWindowCommand)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}

/// One `webApps` entry (spec §8). Decoded and validated in Phase 3; the web shell that uses it is Phase 4.
public struct WebAppPreset: Decodable, Equatable, Sendable {
    public var name: String
    /// An `https` URL with a host.
    public var url: String
    public var userAgent: String?
    /// Compiled by the Phase 4 web shell to read unread counts from the page title.
    public var badgeRegex: String?
    public var extraHosts: [String]
    public var iconURL: String?

    public init(name: String, url: String, userAgent: String? = nil, badgeRegex: String? = nil,
                extraHosts: [String] = [], iconURL: String? = nil) {
        self.name = name
        self.url = url
        self.userAgent = userAgent
        self.badgeRegex = badgeRegex
        self.extraHosts = extraHosts
        self.iconURL = iconURL
    }

    private enum CodingKeys: String, CodingKey {
        case name, url, userAgent, badgeRegex, extraHosts, iconURL
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        userAgent = try container.decodeIfPresent(String.self, forKey: .userAgent)
        badgeRegex = try container.decodeIfPresent(String.self, forKey: .badgeRegex)
        extraHosts = try container.decodeIfPresent([String].self, forKey: .extraHosts) ?? []
        iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL)
    }
}

/// A decoded and validated `profiles.json` (spec §8). Build one from bytes with `decodeValidated(from:)`; unknown
/// keys are ignored so a newer file with extra fields still loads.
public struct ProfilesDocument: Decodable, Equatable, Sendable {
    /// The only `schemaVersion` this build reads.
    public static let supportedSchemaVersion = 1
    /// Largest accepted file, in bytes.
    public static let maxBytes = 1_048_576
    /// Longest accepted string, in Unicode scalars.
    public static let maxStringLength = 2_048
    public static let maxApps = 500
    public static let maxWebApps = 200
    /// Cap for the `args`, `env` and `extraHosts` of one entry.
    public static let maxListEntries = 64

    public var schemaVersion: Int
    /// `YYYY-MM-DD`; a later date wins (`ProfileCatalog.isNewer`).
    public var updated: String
    public var apps: [String: AppProfile]
    public var webApps: [String: WebAppPreset]

    public init(schemaVersion: Int = ProfilesDocument.supportedSchemaVersion, updated: String,
                apps: [String: AppProfile] = [:], webApps: [String: WebAppPreset] = [:]) {
        self.schemaVersion = schemaVersion
        self.updated = updated
        self.apps = apps
        self.webApps = webApps
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, updated, apps, webApps
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        updated = try container.decode(String.self, forKey: .updated)
        apps = try container.decode([String: AppProfile].self, forKey: .apps)
        webApps = try container.decodeIfPresent([String: WebAppPreset].self, forKey: .webApps) ?? [:]
    }

    /// Decodes untrusted bytes and applies every validation rule. The app builds documents only through this.
    public static func decodeValidated(from data: Data) throws -> ProfilesDocument {
        guard data.count <= maxBytes else { throw ProfilesError.tooLarge(data.count) }
        let decoder = JSONDecoder()
        let probe: VersionProbe
        do {
            probe = try decoder.decode(VersionProbe.self, from: data)
        } catch {
            throw ProfilesError.malformed(describe(error))
        }
        guard probe.schemaVersion == supportedSchemaVersion else {
            throw ProfilesError.unsupportedSchemaVersion(probe.schemaVersion)
        }
        let document: ProfilesDocument
        do {
            document = try decoder.decode(ProfilesDocument.self, from: data)
        } catch let error as ProfilesError {
            throw error
        } catch {
            throw ProfilesError.malformed(describe(error))
        }
        try document.validate()
        return document
    }
}

/// Decodes only `schemaVersion`, so a newer schema is reported as such instead of as malformed JSON.
private struct VersionProbe: Decodable {
    var schemaVersion: Int
}

/// A dotted JSON path for error messages. Each component is cut to 100 characters so a hostile key cannot flood the UI.
func profilesPath(_ codingPath: [any CodingKey], leaf: String? = nil) -> String {
    let components = codingPath.map { $0.stringValue } + (leaf.map { [$0] } ?? [])
    guard !components.isEmpty else { return "the top level" }
    return components.map { String($0.prefix(100)) }.joined(separator: ".")
}

extension ProfilesDocument {
    static let bundleIdentifierPattern = #"\A[A-Za-z0-9][A-Za-z0-9._-]{0,254}\z"#
    static let environmentKeyPattern = #"\A[A-Za-z_][A-Za-z0-9_]{0,127}\z"#
    static let webAppKeyPattern = #"\A[a-z0-9][a-z0-9-]{0,63}\z"#
    static let hostnamePattern =
        #"\A(?=.{1,253}\z)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\z"#
    static let datePattern = #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z"#
    /// Environment keys a profile may not set: dynamic-loader, Node, Electron and JVM hooks that load code into the
    /// target, the launcher's own `MAD_` variables, and the variables data separation owns (`HOME`,
    /// `CFFIXED_USER_HOME`, Firefox's `XRE_` overrides).
    static let refusedEnvironmentKeyPattern =
        #"\A(?:DYLD_|LD_|MAD_|XRE_)|\A(?:NODE_OPTIONS|ELECTRON_RUN_AS_NODE|JAVA_TOOL_OPTIONS|_JAVA_OPTIONS|JDK_JAVA_OPTIONS|HOME|CFFIXED_USER_HOME)\z"#
    /// Argument prefixes a profile may not use, with one or two leading dashes in any case (Chromium accepts both):
    /// debugger and remote-control switches, code loaders (`--load-extension`, `--renderer-cmd-prefix`, `-vmargs`,
    /// `-javaagent`), sandbox and web-security switches, and the profile and data-folder switches the planner owns
    /// (`--user-data-dir`, `--profile-directory`, Firefox `-profile` and `-P`, Eclipse `-data` and `-configuration`).
    static let refusedArgumentPattern =
        #"(?i)\A--?(?:inspect|remote-debugging|remote-allow-origins|load-extension|disable-extensions-except|disable-web-security|no-sandbox|renderer-cmd-prefix|utility-cmd-prefix|gpu-launcher|browser-subprocess-path|user-data-dir|profile|configuration|data\z|p\z|vm|javaagent)"#

    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    /// `YYYY-MM-DD` with ASCII digits that names a real Gregorian date.
    static func isValidDate(_ value: String) -> Bool {
        guard matches(value, datePattern) else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    /// Refuses strings over `maxStringLength` Unicode scalars, strings containing NUL and, unless allowed, empty strings.
    static func checkString(_ value: String, at path: String, allowEmpty: Bool = true) throws {
        guard value.unicodeScalars.count <= maxStringLength, !value.unicodeScalars.contains("\u{0}"),
              allowEmpty || !value.isEmpty else {
            throw ProfilesError.invalidField(path)
        }
    }

    /// Applies every rule from the Global Constraints. Keys are visited in sorted order so errors are reproducible.
    func validate() throws {
        guard Self.isValidDate(updated) else { throw ProfilesError.invalidUpdatedDate(String(updated.prefix(100))) }
        guard apps.count <= Self.maxApps else { throw ProfilesError.tooMany("apps") }
        guard webApps.count <= Self.maxWebApps else { throw ProfilesError.tooMany("webApps") }
        var seenIdentifiers = Set<String>()
        for (identifier, profile) in apps.sorted(by: { $0.key < $1.key }) {
            let path = "apps." + String(identifier.prefix(100))
            guard Self.matches(identifier, Self.bundleIdentifierPattern) else { throw ProfilesError.invalidField(path) }
            guard seenIdentifiers.insert(identifier.lowercased()).inserted else {
                throw ProfilesError.invalidField("\(path) duplicates another bundle identifier")
            }
            try profile.validate(at: path)
        }
        for (key, preset) in webApps.sorted(by: { $0.key < $1.key }) {
            let path = "webApps." + String(key.prefix(100))
            guard Self.matches(key, Self.webAppKeyPattern) else { throw ProfilesError.invalidField(path) }
            try preset.validate(at: path)
        }
    }

    /// A one-line reason for a decoding failure that names the JSON path but never echoes document values.
    static func describe(_ error: any Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let context) where context.codingPath.isEmpty:
            return "the data is not valid JSON"
        case DecodingError.dataCorrupted(let context):
            return "invalid value at \(profilesPath(context.codingPath))"
        case DecodingError.keyNotFound(let key, let context):
            return "missing key \(profilesPath(context.codingPath, leaf: key.stringValue))"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "wrong or missing value at \(profilesPath(context.codingPath))"
        default:
            return error.localizedDescription
        }
    }
}

extension AppProfile {
    func validate(at path: String) throws {
        try ProfilesDocument.checkString(name, at: "\(path).name", allowEmpty: false)
        guard args.count <= ProfilesDocument.maxListEntries else { throw ProfilesError.tooMany("\(path).args") }
        for (index, argument) in args.enumerated() {
            let argumentPath = "\(path).args[\(index)]"
            try ProfilesDocument.checkString(argument, at: argumentPath)
            guard !ProfilesDocument.matches(argument, ProfilesDocument.refusedArgumentPattern) else {
                throw ProfilesError.invalidField(argumentPath)
            }
        }
        guard env.count <= ProfilesDocument.maxListEntries else { throw ProfilesError.tooMany("\(path).env") }
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
            let entryPath = "\(path).env.\(key.prefix(100))"
            guard ProfilesDocument.matches(key, ProfilesDocument.environmentKeyPattern),
                  !ProfilesDocument.matches(key, ProfilesDocument.refusedEnvironmentKeyPattern) else {
                throw ProfilesError.invalidField(entryPath)
            }
            try ProfilesDocument.checkString(value, at: entryPath)
        }
        if let newWindowCommand { try ProfilesDocument.checkString(newWindowCommand, at: "\(path).newWindowCommand") }
        if let notes { try ProfilesDocument.checkString(notes, at: "\(path).notes") }
    }
}

extension WebAppPreset {
    func validate(at path: String) throws {
        try ProfilesDocument.checkString(name, at: "\(path).name", allowEmpty: false)
        try ProfilesDocument.checkString(url, at: "\(path).url")
        guard let components = URLComponents(string: url), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty else {
            throw ProfilesError.invalidField("\(path).url")
        }
        if let userAgent { try ProfilesDocument.checkString(userAgent, at: "\(path).userAgent") }
        if let badgeRegex {
            try ProfilesDocument.checkString(badgeRegex, at: "\(path).badgeRegex")
            do {
                _ = try NSRegularExpression(pattern: badgeRegex)
            } catch {
                throw ProfilesError.invalidField("\(path).badgeRegex")
            }
        }
        guard extraHosts.count <= ProfilesDocument.maxListEntries else { throw ProfilesError.tooMany("\(path).extraHosts") }
        for (index, extraHost) in extraHosts.enumerated()
        where !ProfilesDocument.matches(extraHost, ProfilesDocument.hostnamePattern) {
            throw ProfilesError.invalidField("\(path).extraHosts[\(index)]")
        }
        if let iconURL { try ProfilesDocument.checkString(iconURL, at: "\(path).iconURL") }
    }
}
```

- [ ] **Step 6: Run the document tests to verify they pass**

Run: `cd "$REPO" && swift test --filter CompatProfilesTests 2>&1 | grep -E 'Executed|error:' | tail -3`
Expected: `Executed 14 tests, with 0 failures`.

- [ ] **Step 7: Write the failing catalog tests**

Create `Packages/CompatProfiles/Tests/CompatProfilesTests/ProfileCatalogTests.swift`:

```swift
import XCTest
@testable import CompatProfiles

final class ProfileCatalogTests: XCTestCase {
    private func data(updated: String, name: String) throws -> Data {
        try makeProfilesData(updated: updated, apps: ["com.example.app": appEntry(name: name)])
    }

    func testEmptyCatalog() {
        XCTAssertEqual(ProfileCatalog.empty.updated, "")
        XCTAssertEqual(ProfileCatalog.empty.appCount, 0)
        XCTAssertEqual(ProfileCatalog.empty.source, .bundled)
        XCTAssertNil(ProfileCatalog.empty.profile(forBundleIdentifier: "com.example.app"))
    }

    func testLookupIsCaseInsensitive() {
        let document = ProfilesDocument(updated: "2026-10-09",
                                        apps: ["com.Example.App": AppProfile(name: "Example", status: .verified)])
        let catalog = ProfileCatalog(document: document, source: .bundled)

        XCTAssertEqual(catalog.profile(forBundleIdentifier: "com.Example.App")?.status, .verified)
        XCTAssertEqual(catalog.profile(forBundleIdentifier: "com.example.app")?.status, .verified)
        XCTAssertEqual(catalog.profile(forBundleIdentifier: "COM.EXAMPLE.APP")?.status, .verified)
        XCTAssertNil(catalog.profile(forBundleIdentifier: "com.example.other"))
    }

    func testLoadUsesBundledWhenNoCache() throws {
        let directory = try makeTemporaryDirectory()
        let bundled = try writeFile(data(updated: "2026-10-09", name: "Bundled"), named: "profiles.json", in: directory)

        let catalog = ProfileCatalog.load(bundledURL: bundled, cacheURL: directory.appending(path: "missing/profiles.json"))

        XCTAssertEqual(catalog.source, .bundled)
        XCTAssertEqual(catalog.updated, "2026-10-09")
        XCTAssertEqual(catalog.profile(forBundleIdentifier: "com.example.app")?.name, "Bundled")
    }

    func testLoadPrefersAStrictlyNewerCache() throws {
        let directory = try makeTemporaryDirectory()
        let bundled = try writeFile(data(updated: "2026-10-09", name: "Bundled"), named: "bundled.json", in: directory)
        let cache = try writeFile(data(updated: "2026-10-10", name: "Cached"), named: "cache.json", in: directory)

        let catalog = ProfileCatalog.load(bundledURL: bundled, cacheURL: cache)

        XCTAssertEqual(catalog.source, .cached)
        XCTAssertEqual(catalog.updated, "2026-10-10")
        XCTAssertEqual(catalog.profile(forBundleIdentifier: "com.example.app")?.name, "Cached")
    }

    func testLoadIgnoresAnOlderOrSameDayCache() throws {
        let directory = try makeTemporaryDirectory()
        let bundled = try writeFile(data(updated: "2026-10-09", name: "Bundled"), named: "bundled.json", in: directory)
        for updated in ["2026-10-09", "2026-10-08"] {
            let cache = try writeFile(data(updated: updated, name: "Cached"), named: "cache-\(updated).json", in: directory)

            let catalog = ProfileCatalog.load(bundledURL: bundled, cacheURL: cache)

            XCTAssertEqual(catalog.source, .bundled, updated)
            XCTAssertEqual(catalog.profile(forBundleIdentifier: "com.example.app")?.name, "Bundled", updated)
        }
    }

    func testLoadSkipsInvalidSources() throws {
        let directory = try makeTemporaryDirectory()
        let bundled = try writeFile(data(updated: "2026-10-09", name: "Bundled"), named: "bundled.json", in: directory)
        let broken = try writeFile(Data("{".utf8), named: "broken.json", in: directory)
        let futureSchema = try writeFile(makeProfilesData(schemaVersion: 2, updated: "2027-01-01"), named: "future.json", in: directory)
        let oversized = try writeFile(Data(repeating: UInt8(ascii: " "), count: ProfilesDocument.maxBytes + 1),
                                      named: "big.json", in: directory)
        let cache = try writeFile(data(updated: "2026-10-10", name: "Cached"), named: "cache.json", in: directory)

        XCTAssertEqual(ProfileCatalog.load(bundledURL: bundled, cacheURL: futureSchema).source, .bundled)
        XCTAssertEqual(ProfileCatalog.load(bundledURL: bundled, cacheURL: oversized).source, .bundled)
        XCTAssertEqual(ProfileCatalog.load(bundledURL: broken, cacheURL: cache).source, .cached)
        XCTAssertEqual(ProfileCatalog.load(bundledURL: nil, cacheURL: cache).source, .cached)
        XCTAssertEqual(ProfileCatalog.load(bundledURL: broken, cacheURL: broken), .empty)
        XCTAssertEqual(ProfileCatalog.load(bundledURL: nil, cacheURL: directory.appending(path: "missing.json")), .empty)
    }

    func testIsNewerComparesDates() {
        XCTAssertTrue(ProfileCatalog.isNewer("2026-10-10", than: "2026-10-09"))
        XCTAssertTrue(ProfileCatalog.isNewer("2027-01-01", than: "2026-12-31"))
        XCTAssertTrue(ProfileCatalog.isNewer("2026-10-09", than: ""), "any date beats the empty catalog")
        XCTAssertFalse(ProfileCatalog.isNewer("2026-10-09", than: "2026-10-09"), "the same day is not newer")
        XCTAssertFalse(ProfileCatalog.isNewer("2026-10-08", than: "2026-10-09"))
    }
}
```

- [ ] **Step 8: Run the catalog tests to verify they fail**

Run: `cd "$REPO" && swift test --filter CompatProfilesTests 2>&1 | grep -oE "cannot find '[A-Za-z]+' in scope" | sort -u`
Expected: `cannot find 'ProfileCatalog' in scope` (compile error; nothing runs).

- [ ] **Step 9: Implement the catalog**

Create `Packages/CompatProfiles/Sources/CompatProfiles/ProfileCatalog.swift`:

```swift
import Foundation

/// Where the active profiles came from; shown in Settings and Diagnostics.
public enum ProfileSource: String, Sendable {
    case bundled, cached
}

/// The profiles the app uses: the bundled seed, or the cached remote copy when it is strictly newer (spec §8).
public struct ProfileCatalog: Equatable, Sendable {
    public var document: ProfilesDocument
    public var source: ProfileSource

    public init(document: ProfilesDocument, source: ProfileSource) {
        self.document = document
        self.source = source
    }

    /// No profiles at all; used until `load` finishes and when even the bundled seed is missing or invalid.
    public static let empty = ProfileCatalog(document: ProfilesDocument(updated: ""), source: .bundled)

    /// The document's `updated` date (`YYYY-MM-DD`; empty for `empty`).
    public var updated: String { document.updated }

    /// Number of app profiles.
    public var appCount: Int { document.apps.count }

    /// The profile for `bundleIdentifier`. Bundle identifiers are case-insensitive, so the lookup is too.
    public func profile(forBundleIdentifier bundleIdentifier: String) -> AppProfile? {
        if let exact = document.apps[bundleIdentifier] { return exact }
        let folded = bundleIdentifier.lowercased()
        return document.apps.first { $0.key.lowercased() == folded }?.value
    }

    /// Reads the bundled seed and the cached copy and returns the one to use; never throws. A missing, oversized or
    /// invalid source is skipped, and the cache wins only when its `updated` date is strictly later than the seed's.
    public static func load(bundledURL: URL?, cacheURL: URL) -> ProfileCatalog {
        let bundled = bundledURL.flatMap(readDocument(at:)).map { ProfileCatalog(document: $0, source: .bundled) }
        let cached = readDocument(at: cacheURL).map { ProfileCatalog(document: $0, source: .cached) }
        switch (bundled, cached) {
        case let (bundled?, cached?):
            return isNewer(cached.updated, than: bundled.updated) ? cached : bundled
        case let (bundled?, nil):
            return bundled
        case let (nil, cached?):
            return cached
        case (nil, nil):
            return .empty
        }
    }

    /// Whether `candidate` is a strictly later date than `current`. Both are validated `YYYY-MM-DD` strings (or empty
    /// for the empty catalog), so string order is date order.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate > current
    }

    /// The validated document at `url`, or nil when the file is missing, larger than `ProfilesDocument.maxBytes`,
    /// unreadable or invalid. A bad cache must never stop the app from using the bundled seed.
    static func readDocument(at url: URL) -> ProfilesDocument? {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= ProfilesDocument.maxBytes else { return nil }
            return try ProfilesDocument.decodeValidated(from: Data(contentsOf: url))
        } catch {
            return nil
        }
    }
}
```

- [ ] **Step 10: Run the package tests to verify they pass**

Run: `cd "$REPO" && swift test --filter CompatProfilesTests 2>&1 | grep -E 'Executed|error:' | tail -3`
Expected: `Executed 21 tests, with 0 failures` (14 document + 7 catalog).

- [ ] **Step 11: Confirm Core is untouched**

Run: `cd "$REPO" && swift test --filter DuplicatorCoreTests 2>&1 | grep -E 'Executed|error:' | tail -3`
Expected: `Executed 111 tests, with 0 failures`.

- [ ] **Step 12: Commit**

```bash
cd "$REPO" && git add Package.swift Packages/CompatProfiles && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -q -F - <<'MSG'
feat(profiles): add CompatProfiles schema, validation and catalog

New SwiftPM library CompatProfiles (Foundation + DuplicatorCore only, linked by
the app and its tests, never by the Launcher) decodes profiles.json per spec §8:
schemaVersion gate, status verified|partial|unsupported, apps keyed by bundle
identifier, webApps decoded and validated for Phase 4, unknown keys ignored.

Fetched JSON is untrusted: 1 MiB cap, strings of at most 2,048 scalars without
NUL, capped counts, anchored key patterns, real YYYY-MM-DD dates, and a
deny-list of code-loading environment hooks and of debugger, code-loading,
sandbox and data-folder switches in profile env and args.
ProfileCatalog uses the cached copy only when it is strictly newer than the seed.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 2: Profile refresh client — fetch policy, URLSession fetcher and cache updater

**Files:**
- Create: `Packages/CompatProfiles/Sources/CompatProfiles/ProfilesConstants.swift`
- Create: `Packages/CompatProfiles/Sources/CompatProfiles/ProfilesFetching.swift`
- Create: `Packages/CompatProfiles/Sources/CompatProfiles/ProfilesUpdater.swift`
- Test: `Packages/CompatProfiles/Tests/CompatProfilesTests/ProfilesFetchPolicyTests.swift`
- Test: `Packages/CompatProfiles/Tests/CompatProfilesTests/URLSessionProfilesFetcherTests.swift`
- Test: `Packages/CompatProfiles/Tests/CompatProfilesTests/ProfilesUpdaterTests.swift`

**Interfaces:**
- Consumes (Task 1): `ProfilesError` (`insecureURL(String)`, `httpStatus(Int)`, `tooLarge(Int)`, `fetchFailed(String)`, `unsupportedSchemaVersion(Int)`, `invalidField(String)`), `ProfilesDocument.maxBytes`, `ProfilesDocument.init(updated:)`, `ProfilesDocument.decodeValidated(from:)`, `ProfileCatalog.init(document:source:)`, `ProfileCatalog.updated`, `ProfileCatalog.profile(forBundleIdentifier:)`, `ProfileCatalog.isNewer(_:than:)`, `ProfileCatalog.load(bundledURL:cacheURL:)`, `ProfileSource.cached`; test helpers `makeTemporaryDirectory()`, `makeProfilesData(schemaVersion:updated:apps:webApps:extra:)`, `appEntry(name:status:extra:)`.
- Produces (used by Tasks 3 and 10):
  - `public enum ProfilesConstants` — `static let defaultURLString: String` (the Global Constraints URL), `static func defaultCacheURL(home: URL) -> URL` (`<home>/Library/Application Support/App Duplicator/profiles.json`).
  - `public protocol ProfilesFetching: Sendable { func fetch(from url: URL) async throws -> Data }`.
  - `public enum ProfilesFetchPolicy` — `static let allowedHost = "raw.githubusercontent.com"`, `static func isAllowedSource(_ url: URL) -> Bool`, `static func allowsRedirect(to url: URL?) -> Bool`, `static func checkResponse(statusCode: Int, finalURL: URL?, expectedContentLength: Int64) throws`.
  - `public final class URLSessionProfilesFetcher: NSObject, ProfilesFetching, URLSessionTaskDelegate, Sendable` — `public override init()`, `static func sessionConfiguration() -> URLSessionConfiguration`, `static func request(for url: URL) -> URLRequest`, `func fetch(from url: URL) async throws -> Data`.
  - `public enum ProfilesUpdateResult: Equatable, Sendable { case updated(ProfileCatalog); case upToDate(current: String, fetched: String) }`.
  - `public struct ProfilesUpdater: Sendable` — `init(fetcher: any ProfilesFetching, cacheURL: URL)`, `func update(from url: URL, current: ProfileCatalog) async throws -> ProfilesUpdateResult` (throws `ProfilesError`, or the file system error when the cache cannot be written).

- [ ] **Step 1: Write the failing fetch-policy and fetcher tests**

No test in this task resumes a `URLSession` task, so nothing touches the network: the policy is pure, the fetcher refuses a disallowed URL before it creates a session, and the redirect delegate method is called directly.

Create `Packages/CompatProfiles/Tests/CompatProfilesTests/ProfilesFetchPolicyTests.swift`:

```swift
import XCTest
@testable import CompatProfiles

final class ProfilesFetchPolicyTests: XCTestCase {
    private func assertThrows(_ expected: ProfilesError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? ProfilesError, expected, file: file, line: line)
        }
    }

    func testDefaultURLAndCacheLocation() {
        XCTAssertEqual(ProfilesConstants.defaultURLString,
                       "https://raw.githubusercontent.com/cubbieblue16/MacAppDuplicator/main/Packages/CompatProfiles/Resources/profiles.json")
        XCTAssertEqual(ProfilesConstants.defaultCacheURL(home: URL(filePath: "/Users/test", directoryHint: .isDirectory)).path,
                       "/Users/test/Library/Application Support/App Duplicator/profiles.json")
    }

    func testAllowsOnlyHTTPSToRawGitHubUserContent() throws {
        let allowed = [
            ProfilesConstants.defaultURLString,
            "https://raw.githubusercontent.com:443/cubbieblue16/MacAppDuplicator/main/profiles.json",
            "HTTPS://RAW.GITHUBUSERCONTENT.COM/cubbieblue16/MacAppDuplicator/main/profiles.json",
        ]
        let refused = [
            "http://raw.githubusercontent.com/cubbieblue16/MacAppDuplicator/main/profiles.json",
            "https://raw.githubusercontent.com:8443/cubbieblue16/MacAppDuplicator/main/profiles.json",
            "https://someone:hunter2@raw.githubusercontent.com/cubbieblue16/MacAppDuplicator/main/profiles.json",
            "https://raw.githubusercontent.com.example.com/profiles.json",
            "https://github.com/cubbieblue16/MacAppDuplicator/raw/main/profiles.json",
            "https://example.com/raw.githubusercontent.com/profiles.json",
            "file:///Users/test/profiles.json",
            "ftp://raw.githubusercontent.com/profiles.json",
        ]

        for raw in allowed {
            XCTAssertTrue(ProfilesFetchPolicy.isAllowedSource(try XCTUnwrap(URL(string: raw))), raw)
        }
        for raw in refused {
            XCTAssertFalse(ProfilesFetchPolicy.isAllowedSource(try XCTUnwrap(URL(string: raw))), raw)
        }
    }

    func testRedirectTargetsFollowTheSameRule() {
        XCTAssertTrue(ProfilesFetchPolicy.allowsRedirect(
            to: URL(string: "https://raw.githubusercontent.com/cubbieblue16/Renamed/main/profiles.json")))
        XCTAssertFalse(ProfilesFetchPolicy.allowsRedirect(to: URL(string: "https://objects.githubusercontent.com/profiles.json")))
        XCTAssertFalse(ProfilesFetchPolicy.allowsRedirect(to: URL(string: "http://raw.githubusercontent.com/profiles.json")))
        XCTAssertFalse(ProfilesFetchPolicy.allowsRedirect(to: nil))
    }

    func testCheckResponseAcceptsOnlyA200FromTheAllowedHostWithinTheCap() throws {
        let source = try XCTUnwrap(URL(string: ProfilesConstants.defaultURLString))

        XCTAssertNoThrow(try ProfilesFetchPolicy.checkResponse(statusCode: 200, finalURL: source, expectedContentLength: -1))
        XCTAssertNoThrow(try ProfilesFetchPolicy.checkResponse(statusCode: 200, finalURL: source,
                                                               expectedContentLength: Int64(ProfilesDocument.maxBytes)))
        assertThrows(.httpStatus(404)) {
            try ProfilesFetchPolicy.checkResponse(statusCode: 404, finalURL: source, expectedContentLength: 14)
        }
        assertThrows(.httpStatus(302)) {
            try ProfilesFetchPolicy.checkResponse(statusCode: 302, finalURL: source, expectedContentLength: 0)
        }
        assertThrows(.insecureURL("https://example.com/profiles.json")) {
            try ProfilesFetchPolicy.checkResponse(statusCode: 200, finalURL: URL(string: "https://example.com/profiles.json"),
                                                  expectedContentLength: -1)
        }
        assertThrows(.insecureURL("")) {
            try ProfilesFetchPolicy.checkResponse(statusCode: 200, finalURL: nil, expectedContentLength: -1)
        }
        assertThrows(.tooLarge(ProfilesDocument.maxBytes + 1)) {
            try ProfilesFetchPolicy.checkResponse(statusCode: 200, finalURL: source,
                                                  expectedContentLength: Int64(ProfilesDocument.maxBytes + 1))
        }
    }
}
```

Create `Packages/CompatProfiles/Tests/CompatProfilesTests/URLSessionProfilesFetcherTests.swift`:

```swift
import XCTest
@testable import CompatProfiles

/// Shape-only tests: no test here resumes a `URLSession` task, so nothing touches the network.
final class URLSessionProfilesFetcherTests: XCTestCase {
    func testSessionAndRequestKeepNoCookiesCacheOrCredentials() throws {
        let configuration = URLSessionProfilesFetcher.sessionConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 20)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 60)

        let url = try XCTUnwrap(URL(string: ProfilesConstants.defaultURLString))
        let request = URLSessionProfilesFetcher.request(for: url)
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.timeoutInterval, 20)
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testRefusesAnInsecureURLBeforeAnyRequest() async throws {
        let fetcher = URLSessionProfilesFetcher()
        for raw in ["http://raw.githubusercontent.com/cubbieblue16/MacAppDuplicator/main/profiles.json",
                    "https://gist.githubusercontent.com/cubbieblue16/profiles.json",
                    "file:///etc/hosts"] {
            let url = try XCTUnwrap(URL(string: raw))
            do {
                _ = try await fetcher.fetch(from: url)
                XCTFail("expected insecureURL for \(raw)")
            } catch {
                XCTAssertEqual(error as? ProfilesError, .insecureURL(raw))
            }
        }
    }

    func testRedirectsAreFollowedOnlyToTheAllowedHost() async throws {
        let fetcher = URLSessionProfilesFetcher()
        let session = URLSession(configuration: URLSessionProfilesFetcher.sessionConfiguration())
        defer { session.invalidateAndCancel() }
        let original = try XCTUnwrap(URL(string: ProfilesConstants.defaultURLString))
        let task = session.dataTask(with: original) // never resumed, so no request is sent
        let response = try XCTUnwrap(HTTPURLResponse(url: original, statusCode: 301, httpVersion: "HTTP/1.1", headerFields: nil))
        let sameHost = URLRequest(url: try XCTUnwrap(URL(string: "https://raw.githubusercontent.com/cubbieblue16/Renamed/main/profiles.json")))
        let otherHost = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/profiles.json")))
        let plainHTTP = URLRequest(url: try XCTUnwrap(URL(string: "http://raw.githubusercontent.com/cubbieblue16/Renamed/main/profiles.json")))

        let followedSameHost = await fetcher.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: sameHost)
        let followedOtherHost = await fetcher.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: otherHost)
        let followedPlainHTTP = await fetcher.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: plainHTTP)

        XCTAssertEqual(followedSameHost, sameHost)
        XCTAssertNil(followedOtherHost)
        XCTAssertNil(followedPlainHTTP)
    }
}
```

- [ ] **Step 2: Run the fetch tests to verify they fail**

Run: `cd "$REPO" && swift test --filter CompatProfilesTests 2>&1 | grep -oE "cannot find (type )?'[A-Za-z]+' in scope" | sort -u`
Expected: compile errors; the list includes `cannot find 'ProfilesConstants' in scope` and `cannot find 'URLSessionProfilesFetcher' in scope` (it may also name `ProfilesFetchPolicy`); nothing runs.

- [ ] **Step 3: Implement the constants, the fetch policy and the fetcher**

Create `Packages/CompatProfiles/Sources/CompatProfiles/ProfilesConstants.swift`:

```swift
import Foundation

/// Fixed locations for compatibility profiles.
public enum ProfilesConstants {
    /// The default profiles URL (Settings → Profiles). It answers HTTP 404 until the repository is public; Check
    /// Profile Updates then reports the status and changes nothing.
    public static let defaultURLString =
        "https://raw.githubusercontent.com/cubbieblue16/MacAppDuplicator/main/Packages/CompatProfiles/Resources/profiles.json"

    /// `<home>/Library/Application Support/App Duplicator/profiles.json`, the cached remote copy. Only Check Profile
    /// Updates writes it.
    public static func defaultCacheURL(home: URL) -> URL {
        home.appending(path: "Library/Application Support/App Duplicator/profiles.json", directoryHint: .notDirectory)
    }
}
```

Create `Packages/CompatProfiles/Sources/CompatProfiles/ProfilesFetching.swift`:

```swift
import Foundation

/// Downloads the raw bytes of a `profiles.json`. Injected everywhere, so tests never touch the network.
public protocol ProfilesFetching: Sendable {
    func fetch(from url: URL) async throws -> Data
}

/// The rules every profile download follows (spec §2, §8, §9): HTTPS to `raw.githubusercontent.com` only, for the
/// request and for every redirect; HTTP 200 only; at most `ProfilesDocument.maxBytes`.
public enum ProfilesFetchPolicy {
    public static let allowedHost = "raw.githubusercontent.com"

    /// Whether `url` may be fetched: scheme `https`, host `raw.githubusercontent.com` (both case-insensitive), port 443
    /// or none, and no user name or password.
    public static func isAllowedSource(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == allowedHost,
              components.user == nil,
              components.password == nil
        else { return false }
        return components.port == nil || components.port == 443
    }

    /// Whether a redirect to `url` may be followed; the same rule as the original request.
    public static func allowsRedirect(to url: URL?) -> Bool {
        guard let url else { return false }
        return isAllowedSource(url)
    }

    /// Checks a response before its body is read. `expectedContentLength` is -1 when the server did not say. A refused
    /// redirect leaves the 3xx response as the final one, which fails here as `httpStatus`.
    public static func checkResponse(statusCode: Int, finalURL: URL?, expectedContentLength: Int64) throws {
        guard statusCode == 200 else { throw ProfilesError.httpStatus(statusCode) }
        guard let finalURL, isAllowedSource(finalURL) else {
            throw ProfilesError.insecureURL(finalURL?.absoluteString ?? "")
        }
        if expectedContentLength > Int64(ProfilesDocument.maxBytes) {
            throw ProfilesError.tooLarge(Int(expectedContentLength))
        }
    }
}

/// The production fetcher: one ephemeral `URLSession` per fetch with no cookie, cache or credential storage, redirects
/// checked against `ProfilesFetchPolicy`, and the body read with a running size cap. It holds no state.
public final class URLSessionProfilesFetcher: NSObject, ProfilesFetching, URLSessionTaskDelegate, Sendable {
    override public init() {
        super.init()
    }

    /// The configuration of every fetch session.
    public static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return configuration
    }

    /// The request for `url`: a GET that never comes from a cache and sends no cookies.
    public static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        return request
    }

    public func fetch(from url: URL) async throws -> Data {
        guard ProfilesFetchPolicy.isAllowedSource(url) else { throw ProfilesError.insecureURL(url.absoluteString) }
        let session = URLSession(configuration: Self.sessionConfiguration())
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, response) = try await session.bytes(for: Self.request(for: url), delegate: self)
            guard let http = response as? HTTPURLResponse else {
                throw ProfilesError.fetchFailed("The profiles server did not send an HTTP response.")
            }
            try ProfilesFetchPolicy.checkResponse(statusCode: http.statusCode, finalURL: http.url,
                                                  expectedContentLength: http.expectedContentLength)
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > ProfilesDocument.maxBytes { throw ProfilesError.tooLarge(data.count) }
            }
            return data
        } catch let error as ProfilesError {
            throw error
        } catch {
            throw ProfilesError.fetchFailed(error.localizedDescription)
        }
    }

    /// Follows a redirect only when its target passes `ProfilesFetchPolicy`; otherwise the 3xx response becomes the
    /// final response and `checkResponse` reports it.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        ProfilesFetchPolicy.allowsRedirect(to: request.url) ? request : nil
    }
}
```

- [ ] **Step 4: Run the fetch tests to verify they pass**

Run: `cd "$REPO" && swift test --filter CompatProfilesTests 2>&1 | grep -E 'Executed|error:' | tail -3`
Expected: `Executed 28 tests, with 0 failures` (21 from Task 1 + 4 policy + 3 fetcher).

- [ ] **Step 5: Write the failing updater tests**

Create `Packages/CompatProfiles/Tests/CompatProfilesTests/ProfilesUpdaterTests.swift`:

```swift
import Synchronization
import XCTest
@testable import CompatProfiles

/// A `ProfilesFetching` that returns a canned result and records every URL it was asked for; never touches the network.
final class MockFetcher: ProfilesFetching, Sendable {
    let result: Result<Data, ProfilesError>
    private let calls = Mutex<[URL]>([])

    init(_ result: Result<Data, ProfilesError>) {
        self.result = result
    }

    var requestedURLs: [URL] { calls.withLock { $0 } }

    func fetch(from url: URL) async throws -> Data {
        calls.withLock { $0.append(url) }
        return try result.get()
    }
}

final class ProfilesUpdaterTests: XCTestCase {
    private let source = URL(string: ProfilesConstants.defaultURLString)!

    private func catalog(updated: String) -> ProfileCatalog {
        ProfileCatalog(document: ProfilesDocument(updated: updated), source: .bundled)
    }

    private func assertUpdateThrows(_ updater: ProfilesUpdater, from url: URL, expected: ProfilesError,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let result = try await updater.update(from: url, current: catalog(updated: "2026-10-09"))
            XCTFail("expected \(expected), got \(result)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ProfilesError, expected, file: file, line: line)
        }
    }

    func testRefusesAnInsecureURLWithoutFetching() async throws {
        let fetcher = MockFetcher(.success(try makeProfilesData(updated: "2026-10-10")))
        let cacheURL = try makeTemporaryDirectory().appending(path: "profiles.json")
        let updater = ProfilesUpdater(fetcher: fetcher, cacheURL: cacheURL)

        for raw in ["http://raw.githubusercontent.com/cubbieblue16/MacAppDuplicator/main/profiles.json",
                    "https://example.com/profiles.json"] {
            await assertUpdateThrows(updater, from: try XCTUnwrap(URL(string: raw)), expected: .insecureURL(raw))
        }

        XCTAssertEqual(fetcher.requestedURLs, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testWritesANewerDocumentAndReturnsTheCachedCatalog() async throws {
        let data = try makeProfilesData(updated: "2026-10-10", apps: ["com.example.app": appEntry(name: "Fetched")])
        let fetcher = MockFetcher(.success(data))
        let cacheURL = try makeTemporaryDirectory().appending(path: "Application Support/App Duplicator/profiles.json")

        let result = try await ProfilesUpdater(fetcher: fetcher, cacheURL: cacheURL)
            .update(from: source, current: catalog(updated: "2026-10-09"))

        guard case .updated(let updated) = result else { return XCTFail("expected .updated, got \(result)") }
        XCTAssertEqual(updated.source, .cached)
        XCTAssertEqual(updated.updated, "2026-10-10")
        XCTAssertEqual(updated.profile(forBundleIdentifier: "com.example.app")?.name, "Fetched")
        XCTAssertEqual(fetcher.requestedURLs, [source])
        XCTAssertEqual(try Data(contentsOf: cacheURL), data, "the validated bytes are cached unchanged")
        XCTAssertEqual(ProfileCatalog.load(bundledURL: nil, cacheURL: cacheURL), updated)
    }

    func testSameDayOrOlderIsUpToDateAndWritesNothing() async throws {
        let cacheURL = try makeTemporaryDirectory().appending(path: "profiles.json")
        for fetched in ["2026-10-09", "2026-10-08"] {
            let updater = ProfilesUpdater(fetcher: MockFetcher(.success(try makeProfilesData(updated: fetched))),
                                          cacheURL: cacheURL)

            let result = try await updater.update(from: source, current: catalog(updated: "2026-10-09"))

            XCTAssertEqual(result, .upToDate(current: "2026-10-09", fetched: fetched))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testInvalidDownloadThrowsAndLeavesTheCacheAlone() async throws {
        let cacheURL = try makeTemporaryDirectory().appending(path: "profiles.json")
        let previous = try makeProfilesData(updated: "2026-10-01")
        try previous.write(to: cacheURL)
        let refusedEnvironment = appEntry(extra: ["env": ["DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib"]])
        let downloads: [(Data, ProfilesError)] = [
            (try makeProfilesData(schemaVersion: 2, updated: "2026-10-10"), .unsupportedSchemaVersion(2)),
            (try makeProfilesData(updated: "2026-10-10", apps: ["com.example.app": refusedEnvironment]),
             .invalidField("apps.com.example.app.env.DYLD_INSERT_LIBRARIES")),
            (Data(repeating: UInt8(ascii: " "), count: ProfilesDocument.maxBytes + 1), .tooLarge(ProfilesDocument.maxBytes + 1)),
        ]

        for (data, expected) in downloads {
            await assertUpdateThrows(ProfilesUpdater(fetcher: MockFetcher(.success(data)), cacheURL: cacheURL),
                                     from: source, expected: expected)
        }

        XCTAssertEqual(try Data(contentsOf: cacheURL), previous)
    }

    func testFetchErrorsPropagateAndWriteNothing() async throws {
        let cacheURL = try makeTemporaryDirectory().appending(path: "profiles.json")
        for error in [ProfilesError.httpStatus(404), .fetchFailed("The Internet connection appears to be offline.")] {
            await assertUpdateThrows(ProfilesUpdater(fetcher: MockFetcher(.failure(error)), cacheURL: cacheURL),
                                     from: source, expected: error)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }
}
```

- [ ] **Step 6: Run the updater tests to verify they fail**

Run: `cd "$REPO" && swift test --filter CompatProfilesTests 2>&1 | grep -oE "cannot find (type )?'[A-Za-z]+' in scope" | sort -u`
Expected: `cannot find type 'ProfilesUpdater' in scope` (compile error; nothing runs).

- [ ] **Step 7: Implement the updater**

Create `Packages/CompatProfiles/Sources/CompatProfiles/ProfilesUpdater.swift`:

```swift
import Foundation

/// What Check Profile Updates found.
public enum ProfilesUpdateResult: Equatable, Sendable {
    /// A strictly newer document was downloaded, validated and cached; use this catalog from now on.
    case updated(ProfileCatalog)
    /// The download was valid but not newer than the profiles in use; nothing was written.
    case upToDate(current: String, fetched: String)
}

/// Downloads `profiles.json`, validates it as untrusted input and caches it only when it is strictly newer than the
/// profiles in use (spec §8). Nothing is written unless the download is valid and newer, and the bytes written are
/// exactly the bytes that were validated.
public struct ProfilesUpdater: Sendable {
    public let fetcher: any ProfilesFetching
    public let cacheURL: URL

    public init(fetcher: any ProfilesFetching, cacheURL: URL) {
        self.fetcher = fetcher
        self.cacheURL = cacheURL
    }

    public func update(from url: URL, current: ProfileCatalog) async throws -> ProfilesUpdateResult {
        guard ProfilesFetchPolicy.isAllowedSource(url) else { throw ProfilesError.insecureURL(url.absoluteString) }
        let data = try await fetcher.fetch(from: url)
        let document = try ProfilesDocument.decodeValidated(from: data)
        guard ProfileCatalog.isNewer(document.updated, than: current.updated) else {
            return .upToDate(current: current.updated, fetched: document.updated)
        }
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
        return .updated(ProfileCatalog(document: document, source: .cached))
    }
}
```

- [ ] **Step 8: Run the package tests to verify they pass**

Run: `cd "$REPO" && swift test --filter CompatProfilesTests 2>&1 | grep -E 'Executed|error:' | tail -3`
Expected: `Executed 33 tests, with 0 failures` (28 + 5 updater).

- [ ] **Step 9: Commit**

```bash
cd "$REPO" && git add Packages/CompatProfiles && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -q -F - <<'MSG'
feat(profiles): add the fetch policy, URLSession fetcher and cache updater

ProfilesFetchPolicy allows https://raw.githubusercontent.com only (port 443 or
none, no user info) for the request and for every redirect, accepts HTTP 200
only and refuses a declared length over 1 MiB. URLSessionProfilesFetcher uses
one ephemeral session per fetch with no cookie, cache or credential storage,
20 s request and 60 s resource timeouts, and a running 1 MiB cap on the body.
ProfilesUpdater validates the download as untrusted input and writes the cache
atomically only when it is strictly newer than the profiles in use. Tests
inject a mock fetcher and never resume a URLSession task, so nothing touches
the network.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 3: Bundled seed and app wiring — ProfilesModel, Check Profile Updates and the profiles URL setting

**Files:**
- Create: `Packages/CompatProfiles/Resources/profiles.json`
- Create: `App/Sources/Model/ProfilesModel.swift`
- Modify: `App/project.yml:32-37,94-97` (seed resource; `CompatProfiles` product for the app and the tests)
- Modify: `App/Sources/Model/AppSettings.swift:1-3,18,45,50,63` (profiles URL setting)
- Modify: `App/Sources/App/LaunchEnvironment.swift:1,24` (profiles cache location)
- Modify: `App/Sources/App/AppState.swift:1-3,48,54,56-60,64` (profiles model, Check Profile Updates)
- Modify: `App/Sources/App/MacAppDuplicatorApp.swift:1,12-15,27,46` (builds the model, app menu item)
- Modify: `App/Sources/Views/ContentView.swift:30,42,49` (toolbar button, result alert)
- Modify: `App/Sources/Views/SettingsView.swift:1-2,14,126` (Profiles tab)
- Modify: `App/Tests/TestSupport/AppTestSupport.swift:1-4,78` (stub fetcher, JSON helper)
- Test: `Packages/CompatProfiles/Tests/CompatProfilesTests/SeedProfilesTests.swift`
- Test: `App/Tests/Model/ProfilesModelTests.swift`
- Test: `App/Tests/SmokeTests.swift:1-2,21` (modify)
- Test: `App/Tests/Model/AppSettingsTests.swift:1-3,117` (modify)
- Test: `App/Tests/App/LaunchEnvironmentTests.swift:38` (modify)
- Test: `App/Tests/App/AppStateTests.swift:1-3,173` (modify)

**Interfaces:**
- Consumes (Tasks 1–2): `ProfilesDocument.decodeValidated(from:)` (`schemaVersion`, `updated`, `apps`, `webApps`), `AppProfile` (`name`, `status`, `family`, `args`, `env`, `newWindowCommand`, `notes`), `ProfileStatus` (`verified`, `partial`, `unsupported`), `ProfileCatalog` (`empty`, `source`, `updated`, `appCount`, `profile(forBundleIdentifier:)`, `load(bundledURL:cacheURL:)`, `isNewer(_:than:)`), `ProfileSource` (`bundled`, `cached`; `rawValue` is the display word), `ProfilesError` (`httpStatus(Int)`, `fetchFailed(String)`; `LocalizedError` descriptions), `ProfilesFetching`, `ProfilesFetchPolicy.isAllowedSource(_:)`, `URLSessionProfilesFetcher()`, `ProfilesUpdater(fetcher:cacheURL:)` with `update(from:current:) async throws -> ProfilesUpdateResult` (`.updated(ProfileCatalog)`, `.upToDate(current:fetched:)`), `ProfilesConstants.defaultURLString`, `ProfilesConstants.defaultCacheURL(home:)`. App (Phase 2): `AppSettings.init(defaults:defaultSigningIdentity:)`, `AppState.init(settings:library:launcherBinary:)`, `LaunchEnvironment.isTestHost(_:)`, test helpers `makeAppTemporaryDirectory()` and `makeTestDefaults()`.
- Produces (used by Tasks 5, 9 and 10):
  - `@MainActor @Observable final class ProfilesModel` (`App/Sources/Model/ProfilesModel.swift`) — `private(set) var catalog: ProfileCatalog`, `private(set) var isChecking: Bool`, `private(set) var statusMessage: String?`, `let bundledURL: URL?`, `let cacheURL: URL`, `init(catalog: ProfileCatalog = .empty, bundledURL: URL?, cacheURL: URL, fetcher: any ProfilesFetching)`, `static func inert() -> ProfilesModel`, `func load() async`, `func profile(forBundleIdentifier bundleIdentifier: String) -> AppProfile?`, `var catalogSummary: String`, `@discardableResult func checkForUpdates(from url: URL?) async -> String`.
  - `struct DisabledProfilesFetcher: ProfilesFetching` — always throws `ProfilesError.fetchFailed("Profile updates are disabled while the app hosts the unit tests.")`.
  - `AppSettings.profilesURLString: String` (UserDefaults key `profilesURLString`, stored only when it differs from `ProfilesConstants.defaultURLString`) and `AppSettings.profilesURL: URL?` (trimmed, nil unless `ProfilesFetchPolicy.isAllowedSource`).
  - `LaunchEnvironment.profilesCacheURL(isTestHost: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL`.
  - `AppState` — `let profiles: ProfilesModel`, `init(settings: AppSettings, library: ShortcutLibrary, launcherBinary: URL, profiles: ProfilesModel? = nil)` (nil means `ProfilesModel.inert()`), `func profile(forBundleIdentifier bundleIdentifier: String) -> AppProfile?`, `var profileUpdateMessage: String?`, `@discardableResult func checkProfileUpdates() async -> String`.
  - Test helpers in `App/Tests/TestSupport/AppTestSupport.swift`: `final class StubProfilesFetcher: ProfilesFetching, Sendable` (`init(_ result: Result<Data, ProfilesError>)`, `var requestedURLs: [URL]`) and `func makeProfilesJSON(updated: String, apps: [String: String]) throws -> Data`. From this task on the file imports `CompatProfiles` and `Synchronization`; later tasks do not add those imports again.

- [ ] **Step 1: Write the failing seed tests**

The seed is a plain file outside every SwiftPM target path, so the package does not bundle it; the test reads it next to its own source file. The app bundles the same file through `App/project.yml` (Step 6), and `SmokeTests` checks the bundled copy (Step 9).

Create `Packages/CompatProfiles/Tests/CompatProfilesTests/SeedProfilesTests.swift`:

```swift
import DuplicatorCore
import XCTest
@testable import CompatProfiles

/// Checks the bundled seed (`Packages/CompatProfiles/Resources/profiles.json`) against spec §8 and the Global
/// Constraints. The app bundles the same file through `App/project.yml`; `SmokeTests` checks the bundled copy.
final class SeedProfilesTests: XCTestCase {
    private let seedURL = URL(filePath: #filePath)
        .deletingLastPathComponent()   // CompatProfilesTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // CompatProfiles
        .appending(path: "Resources/profiles.json", directoryHint: .notDirectory)

    private func seed() throws -> ProfilesDocument {
        try ProfilesDocument.decodeValidated(from: Data(contentsOf: seedURL))
    }

    func testSeedListsExactlyTheEighteenSpecApps() throws {
        let expected: [String: (name: String, family: AppFamily?)] = [
            "com.anthropic.claudefordesktop": ("Claude", .electron),
            "com.google.Chrome": ("Google Chrome", .chromium),
            "com.brave.Browser": ("Brave Browser", .chromium),
            "com.microsoft.edgemac": ("Microsoft Edge", .chromium),
            "org.mozilla.firefox": ("Firefox", .firefox),
            "com.microsoft.VSCode": ("Visual Studio Code", .electron),
            "com.todesktop.230313mzl4w4u92": ("Cursor", .todesktop),
            "com.tinyspeck.slackmacgap": ("Slack", .electron),
            "com.hnc.Discord": ("Discord", .electron),
            "md.obsidian": ("Obsidian", .electron),
            "tv.plex.desktop": ("Plex", nil),
            "com.spotify.client": ("Spotify", nil),
            "org.whispersystems.signal-desktop": ("Signal", .electron),
            "ru.keepcoder.Telegram": ("Telegram", .native),
            "com.mitchellh.ghostty": ("Ghostty", .native),
            "com.googlecode.iterm2": ("iTerm2", .native),
            "com.apple.Terminal": ("Terminal", .native),
            "com.apple.dt.Xcode": ("Xcode", .native),
        ]
        let apps = try seed().apps
        XCTAssertEqual(Set(apps.keys), Set(expected.keys))
        for (identifier, entry) in expected {
            XCTAssertEqual(apps[identifier]?.name, entry.name, identifier)
            XCTAssertEqual(apps[identifier]?.family, entry.family, identifier)
        }
    }

    func testOnlyClaudeIsVerifiedAndTerminalIsSystemLaunchOnly() throws {
        let apps = try seed().apps
        XCTAssertEqual(apps.filter { $0.value.status == .verified }.map(\.key), ["com.anthropic.claudefordesktop"])
        XCTAssertFalse(apps.values.contains { $0.status == .unsupported })
        XCTAssertEqual(apps["com.apple.Terminal"]?.status, .partial)
        XCTAssertEqual(apps["com.apple.Terminal"]?.notes, "Apple platform binary, System Launch only.")
        XCTAssertEqual(apps["com.anthropic.claudefordesktop"]?.notes,
                       "Each instance has its own claude_desktop_config.json inside the data folder.")
        for (identifier, profile) in apps {
            XCTAssertFalse(profile.notes?.isEmpty ?? true, "\(identifier) explains its status")
        }
    }

    func testSeedCarriesNoLaunchValuesYet() throws {
        let document = try seed()
        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.updated, "2026-10-09")
        XCTAssertTrue(document.webApps.isEmpty, "web app presets arrive with the Phase 4 web shell")
        for (identifier, profile) in document.apps {
            XCTAssertEqual(profile.args, [], identifier)
            XCTAssertEqual(profile.env, [:], identifier)
            XCTAssertNil(profile.newWindowCommand, identifier)
        }
    }
}
```

- [ ] **Step 2: Run the seed tests to verify they fail**

Run: `cd "$REPO" && swift test --filter CompatProfilesTests 2>&1 | grep -E 'Executed|error:' | tail -3`
Expected: `Executed 36 tests, with 3 failures (3 unexpected)`; the three seed tests fail because `Packages/CompatProfiles/Resources/profiles.json` does not exist yet.

- [ ] **Step 3: Create the bundled seed**

The 18 apps of spec §8, keyed by the bundle identifiers listed in Inputs and conventions. Statuses follow the Global Constraints: Claude is `verified`, every other entry is `partial` (Terminal with the spec's System Launch note). No entry sets `args`, `env` or `newWindowCommand` yet: Auto data mode already separates every family the planner knows, and a value enters the seed only through `docs/acceptance/profile-promotion.md` (Task 10). Each note says what Auto data mode does for that family, because the badge alone cannot. This file is also what the default profiles URL serves once the repository is public, so editing it here and pushing is how a profile update ships.

Create `Packages/CompatProfiles/Resources/profiles.json`:

```json
{
  "schemaVersion": 1,
  "updated": "2026-10-09",
  "apps": {
    "com.anthropic.claudefordesktop": {
      "name": "Claude",
      "status": "verified",
      "family": "electron",
      "args": [],
      "env": {},
      "newWindowCommand": null,
      "notes": "Each instance has its own claude_desktop_config.json inside the data folder."
    },
    "com.google.Chrome": {
      "name": "Google Chrome",
      "status": "partial",
      "family": "chromium",
      "args": [],
      "env": {},
      "newWindowCommand": null,
      "notes": "Chromium: Auto data mode adds --user-data-dir, so each instance has its own profile and single-instance lock. Not launch-tested yet."
    },
    "com.brave.Browser": {
      "name": "Brave Browser",
      "status": "partial",
      "family": "chromium",
      "args": [],
      "env": {},
      "newWindowCommand": null,
      "notes": "Chromium: Auto data mode adds --user-data-dir, so each instance has its own profile and single-instance lock. Not launch-tested yet."
    },
    "com.microsoft.edgemac": {
      "name": "Microsoft Edge",
      "status": "partial",
      "family": "chromium",
      "args": [],
      "env": {},
      "newWindowCommand": null,
      "notes": "Chromium: Auto data mode adds --user-data-dir, so each instance has its own profile and single-instance lock. Not launch-tested yet."
    },
    "org.mozilla.firefox": {
      "name": "Firefox",
      "status": "partial",
      "family": "firefox",
      "args": [],
      "env": {},
      "newWindowCommand": null,
      "notes": "Firefox: Auto data mode adds --profile and --no-remote, so each instance runs its own profile. Not launch-tested yet."
    },
    "com.microsoft.VSCode": {
      "name": "Visual Studio Code",
      "status": "partial",
      "family": "electron",
      "args": [],
      "env": {},
      "newWindowCommand": null,
      "notes": "Electron: Auto data mode adds --user-data-dir; files the app keeps under HOME (logs, updater cache) stay shared. Not launch-tested yet."
    },
    "com.todesktop.230313mzl4w4u92": {
      "name": "Cursor",
      "status": "partial",
      "family": "todesktop",
      "args": [],
      "env": {},
      "newWindowCommand": null,
      "notes": "ToDesktop (Electron): Auto data mode adds --user-data-dir; files the app keeps under HOME stay shared. Not launch-tested yet."
    },
    "com.tinyspeck.slackmacgap": {
      "name": "Slack",
      "status": "partial",
      "family": "electron",
      "args": [],
      "env": {},
      "newWindowCommand": null,
      "notes": "Electron: Auto data mode adds --user-data-dir; files the app keeps under HOME (logs, updater cache) stay shared. Not launch-tested yet."
    },
    "com.hnc.Discord": {
      "name": "Discord",
      "status": "partial",
      "family": "electron",
      "args": [],
      "env": {},
      "newWindowCommand": null,
      "notes": "Electron: Auto data mode adds --user-data-dir; files the app keeps under HOME (logs, updater cache) stay shared. Not launch-tested yet."
    },
    "md.obsidian": {
      "name": "Obsidian",
      "status": "partial",
      "family": "electron",
      "args": [],
      "env": {},
      "newWindowCommand": null,
      "notes": "Electron: Auto data mode adds --user-data-dir; files the app keeps under HOME (logs, updater cache) stay shared. Not launch-tested yet."
    },
    "tv.plex.desktop": {
      "name": "Plex",
      "status": "partial",
      "family": null,
      "args": [],
      "env": {},
      "newWindowCommand": null,
      "notes": "Family not set; App Duplicator uses the family it detects. Not launch-tested yet."
    },
    "com.spotify.client": {
      "name": "Spotify",
      "status": "partial",
      "family": null,
      "args": [],
      "env": {},
      "newWindowCommand": null,
      "notes": "Family not set; App Duplicator uses the family it detects. Not launch-tested yet."
    },
    "org.whispersystems.signal-desktop": {
      "name": "Signal",
      "status": "partial",
      "family": "electron",
      "args": [],
      "env": {},
      "newWindowCommand": null,
      "notes": "Electron: Auto data mode adds --user-data-dir; files the app keeps under HOME (logs, updater cache) stay shared. Not launch-tested yet."
    },
    "ru.keepcoder.Telegram": {
      "name": "Telegram",
      "status": "partial",
      "family": "native",
      "args": [],
      "env": {},
      "newWindowCommand": null,
      "notes": "Native app. The Mac App Store build is sandboxed: its container cannot be moved, so Auto data mode separates nothing and instances share data. Not launch-tested yet."
    },
    "com.mitchellh.ghostty": {
      "name": "Ghostty",
      "status": "partial",
      "family": "native",
      "args": [],
      "env": {},
      "newWindowCommand": null,
      "notes": "Native app: Auto data mode falls back to a HOME override; preferences (CFPreferences) stay shared. Not launch-tested yet."
    },
    "com.googlecode.iterm2": {
      "name": "iTerm2",
      "status": "partial",
      "family": "native",
      "args": [],
      "env": {},
      "newWindowCommand": null,
      "notes": "Native app: Auto data mode falls back to a HOME override; preferences (CFPreferences) stay shared. Not launch-tested yet."
    },
    "com.apple.Terminal": {
      "name": "Terminal",
      "status": "partial",
      "family": "native",
      "args": [],
      "env": {},
      "newWindowCommand": null,
      "notes": "Apple platform binary, System Launch only."
    },
    "com.apple.dt.Xcode": {
      "name": "Xcode",
      "status": "partial",
      "family": "native",
      "args": [],
      "env": {},
      "newWindowCommand": null,
      "notes": "Native app: Auto data mode falls back to a HOME override; preferences (CFPreferences) stay shared. Not launch-tested yet."
    }
  },
  "webApps": {}
}
```

- [ ] **Step 4: Run the package tests to verify they pass**

Run: `cd "$REPO" && swift test --filter CompatProfilesTests 2>&1 | grep -E 'Executed|error:' | tail -3`
Expected: `Executed 36 tests, with 0 failures` (33 from Task 2 + 3 seed).

- [ ] **Step 5: Re-check the seed bundle identifiers (read-only)**

This only reads Spotlight metadata; nothing is written under `/Applications` or `/System/Applications`. The loop variable is `app`, not `path`, because zsh ties `path` to `PATH`.

Run: `cd "$REPO" && python3 -c 'import json; print("\n".join(sorted(json.load(open("Packages/CompatProfiles/Resources/profiles.json"))["apps"])))' | while read -r id; do app=$(mdfind -onlyin /Applications -onlyin /System/Applications "kMDItemCFBundleIdentifier == '$id'" | head -1); echo "$id ${app:-not installed}"; done`
Expected: 18 lines in this order: `com.anthropic.claudefordesktop`, `com.apple.Terminal`, `com.apple.dt.Xcode`, `com.brave.Browser`, `com.google.Chrome`, `com.googlecode.iterm2`, `com.hnc.Discord`, `com.microsoft.VSCode`, `com.microsoft.edgemac`, `com.mitchellh.ghostty`, `com.spotify.client`, `com.tinyspeck.slackmacgap`, `com.todesktop.230313mzl4w4u92`, `md.obsidian`, `org.mozilla.firefox`, `org.whispersystems.signal-desktop`, `ru.keepcoder.Telegram`, `tv.plex.desktop`, each followed by the installed app's path or `not installed`. On the planning Mac the eight confirmed identifiers print a path (`/Applications/Claude.app`, `/System/Applications/Utilities/Terminal.app`, `/Applications/Xcode.app`, `/Applications/Brave Browser.app`, `/Applications/Google Chrome.app`, `/Applications/Discord.app`, `/Applications/Obsidian.app`, `/Applications/Telegram.app`) and the other ten print `not installed`. If one of the eight prints `not installed`, read the installed app's identifier with `mdls -name kMDItemCFBundleIdentifier "/Applications/<App>.app"` and correct the seed key (and the Step 1 test) before committing.

- [ ] **Step 6: Bundle the seed and link `CompatProfiles` in the app**

`Tools/test-app.sh` regenerates the Xcode project from `App/project.yml`, so these two edits are all the build needs. The test target declares `CompatProfiles` so its sources can import the module. Xcode builds the package once, as a framework embedded in the app (`Contents/Frameworks`), and the app and the test bundle both link that copy (Step 17 checks this).

In `App/project.yml` lines 32-37 (the `MacAppDuplicator` target) replace

```yaml
    sources:
      - path: Sources
      - path: Resources
    dependencies:
      - package: DuplicatorCore
        product: DuplicatorCore
```

with

```yaml
    sources:
      - path: Sources
      - path: Resources
      # The bundled compatibility profiles seed (spec §8), copied into Contents/Resources.
      - path: ../Packages/CompatProfiles/Resources/profiles.json
        buildPhase: resources
    dependencies:
      - package: DuplicatorCore
        product: DuplicatorCore
      - package: DuplicatorCore
        product: CompatProfiles
```

In `App/project.yml` lines 94-97 (the `MacAppDuplicatorTests` target) replace

```yaml
    dependencies:
      - target: MacAppDuplicator
      - package: DuplicatorCore
        product: DuplicatorCore
```

with

```yaml
    dependencies:
      - target: MacAppDuplicator
      - package: DuplicatorCore
        product: DuplicatorCore
      - package: DuplicatorCore
        product: CompatProfiles
```

(`DuplicatorCore` is the `packages:` key for the root package at `..`, which now vends both library products.)

- [ ] **Step 7: Confirm the app still builds and bundles the seed**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/SmokeTests 2>&1 | tail -4`
Expected: `Test Suite 'SmokeTests' passed` and `** TEST SUCCEEDED **`. Expected: PASS, pins existing behaviour.

Run: `cd "$REPO" && ls ".build/DerivedData/Build/Products/Debug/macOS App Duplicator.app/Contents/Resources/profiles.json"`
Expected: the path is printed (no `No such file or directory`).

- [ ] **Step 8: Add the app test helpers**

In `App/Tests/TestSupport/AppTestSupport.swift`:

1. Replace the imports (lines 1-4) with:

```swift
import CompatProfiles
import Foundation
import Synchronization
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator
```

2. After the `XCTestCase` extension (the end of the file, line 78) add:

```swift

/// A `ProfilesFetching` that returns a canned result and records every URL it was asked for; never touches the network.
final class StubProfilesFetcher: ProfilesFetching, Sendable {
    let result: Result<Data, ProfilesError>
    private let calls = Mutex<[URL]>([])

    init(_ result: Result<Data, ProfilesError>) {
        self.result = result
    }

    var requestedURLs: [URL] { calls.withLock { $0 } }

    func fetch(from url: URL) async throws -> Data {
        calls.withLock { $0.append(url) }
        return try result.get()
    }
}

/// `profiles.json` bytes (schema 1) dated `updated`, with one minimal entry per `apps` key (bundle identifier → status).
func makeProfilesJSON(updated: String, apps: [String: String]) throws -> Data {
    var entries: [String: Any] = [:]
    for (identifier, status) in apps { entries[identifier] = ["name": identifier, "status": status] as [String: Any] }
    let object: [String: Any] = ["schemaVersion": 1, "updated": updated, "apps": entries]
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
```

- [ ] **Step 9: Write the failing app tests**

In `App/Tests/SmokeTests.swift`:

1. Replace the imports (lines 1-2) with:

```swift
import CompatProfiles
import XCTest
@testable import MacAppDuplicator
```

2. After `testBundleIdentity` (line 21) add:

```swift

    func testBundledProfilesSeedIsPresentAndValid() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "profiles", withExtension: "json"),
                                "App/project.yml copies Packages/CompatProfiles/Resources/profiles.json into the app")
        let document = try ProfilesDocument.decodeValidated(from: Data(contentsOf: url))
        XCTAssertEqual(document.apps.count, 18)
        XCTAssertEqual(document.apps["com.anthropic.claudefordesktop"]?.status, .verified)
    }
```

Create `App/Tests/Model/ProfilesModelTests.swift`:

```swift
import CompatProfiles
import XCTest
@testable import MacAppDuplicator

@MainActor
final class ProfilesModelTests: XCTestCase {
    private var dir: URL!
    private var bundledURL: URL!
    private var cacheURL: URL!
    private let source = URL(string: "https://raw.githubusercontent.com/example/fork/main/profiles.json")!

    override func setUp() async throws {
        dir = try makeAppTemporaryDirectory()
        bundledURL = dir.appending(path: "bundled.json", directoryHint: .notDirectory)
        try makeProfilesJSON(updated: "2026-10-09", apps: ["com.example.target": "partial"]).write(to: bundledURL)
        cacheURL = dir.appending(path: "cache/profiles.json", directoryHint: .notDirectory)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: dir)
    }

    private func makeModel(_ result: Result<Data, ProfilesError> = .failure(.httpStatus(500))) -> (ProfilesModel, StubProfilesFetcher) {
        let fetcher = StubProfilesFetcher(result)
        return (ProfilesModel(bundledURL: bundledURL, cacheURL: cacheURL, fetcher: fetcher), fetcher)
    }

    func testLoadUsesTheSeedUntilACacheIsStrictlyNewer() async throws {
        let (model, _) = makeModel()
        XCTAssertEqual(model.catalogSummary, "No profiles loaded.")

        await model.load()
        XCTAssertEqual(model.catalog.source, .bundled)
        XCTAssertEqual(model.profile(forBundleIdentifier: "com.example.target")?.status, .partial)
        XCTAssertEqual(model.catalogSummary, "1 app, updated 2026-10-09 (bundled)")

        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeProfilesJSON(updated: "2026-10-10", apps: ["com.example.target": "partial", "com.example.cached": "verified"])
            .write(to: cacheURL)
        await model.load()
        XCTAssertEqual(model.catalog.source, .cached)
        XCTAssertEqual(model.profile(forBundleIdentifier: "COM.EXAMPLE.CACHED")?.status, .verified)
        XCTAssertEqual(model.catalogSummary, "2 apps, updated 2026-10-10 (cached)")
    }

    func testCheckForUpdatesCachesANewerDocumentAndSwitchesToIt() async throws {
        let data = try makeProfilesJSON(updated: "2026-10-11", apps: ["com.example.target": "verified"])
        let (model, fetcher) = makeModel(.success(data))
        await model.load()

        let message = await model.checkForUpdates(from: source)

        XCTAssertEqual(message, "Downloaded profiles from 2026-10-11.")
        XCTAssertEqual(model.statusMessage, message)
        XCTAssertFalse(model.isChecking)
        XCTAssertEqual(fetcher.requestedURLs, [source])
        XCTAssertEqual(model.catalog.source, .cached)
        XCTAssertEqual(model.profile(forBundleIdentifier: "com.example.target")?.status, .verified)
        XCTAssertEqual(try Data(contentsOf: cacheURL), data)
    }

    func testCheckForUpdatesReportsUpToDateAndWritesNothing() async throws {
        let data = try makeProfilesJSON(updated: "2026-10-09", apps: [:])
        let (model, _) = makeModel(.success(data))
        await model.load()

        let message = await model.checkForUpdates(from: source)

        XCTAssertEqual(message, "Profiles are up to date (2026-10-09).")
        XCTAssertEqual(model.catalog.source, .bundled)
        XCTAssertEqual(model.catalog.appCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testCheckForUpdatesReportsErrorsAndKeepsTheCatalog() async throws {
        let (model, fetcher) = makeModel(.failure(.httpStatus(404)))
        await model.load()
        let loaded = model.catalog

        let notFound = await model.checkForUpdates(from: source)
        XCTAssertEqual(notFound, "Could not check profile updates: The profiles server answered HTTP 404.")
        XCTAssertEqual(model.catalog, loaded)

        let refused = await model.checkForUpdates(from: nil)
        XCTAssertEqual(refused, "Could not check profile updates: the profiles URL must be an https://raw.githubusercontent.com address.")
        XCTAssertEqual(model.statusMessage, refused)
        XCTAssertEqual(fetcher.requestedURLs, [source], "a refused URL is never fetched")
        XCTAssertEqual(model.catalog, loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testInertModelNeverFetchesOrTouchesTheRealCache() async {
        let model = ProfilesModel.inert()

        let message = await model.checkForUpdates(from: source)

        XCTAssertEqual(message, "Could not check profile updates: Profile updates are disabled while the app hosts the unit tests.")
        XCTAssertEqual(model.catalog, .empty)
        XCTAssertNil(model.bundledURL)
        XCTAssertTrue(model.cacheURL.path.hasPrefix(FileManager.default.temporaryDirectory.path), model.cacheURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.cacheURL.path))
    }
}
```

In `App/Tests/Model/AppSettingsTests.swift`:

1. Replace the imports (lines 1-3) with:

```swift
import CompatProfiles
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator
```

2. After `testLoadDefaultSigningIdentityFallsBackToAdHoc` (line 117, the last test) add:

```swift

    func testProfilesURLDefaultsToTheConstantAndPersistsAChoice() {
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        XCTAssertEqual(settings.profilesURLString, ProfilesConstants.defaultURLString)
        XCTAssertEqual(settings.profilesURL?.absoluteString, ProfilesConstants.defaultURLString)
        let fork = "https://raw.githubusercontent.com/example/fork/main/profiles.json"
        settings.profilesURLString = fork
        XCTAssertEqual(AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName).profilesURLString, fork)
        settings.profilesURLString = ProfilesConstants.defaultURLString
        XCTAssertNil(defaults.object(forKey: "profilesURLString"), "the default is not stored, so a later default still applies")
    }

    func testProfilesURLIsNilUnlessItIsAnAllowedAddress() {
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        settings.profilesURLString = "  \(ProfilesConstants.defaultURLString)\n"
        XCTAssertEqual(settings.profilesURL?.absoluteString, ProfilesConstants.defaultURLString, "surrounding whitespace is ignored")
        for refused in ["http://raw.githubusercontent.com/example/fork/main/profiles.json",
                        "https://example.com/profiles.json", "", "not a url"] {
            settings.profilesURLString = refused
            XCTAssertNil(settings.profilesURL, refused)
        }
    }
```

In `App/Tests/App/LaunchEnvironmentTests.swift`, after `testTestHostSuiteIsNotTheAppDomain` (line 38, the last test) add (the file's imports already cover it):

```swift

    func testProfilesCacheIsTheRealPathOnlyOutsideTheTestHost() {
        let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
        XCTAssertEqual(LaunchEnvironment.profilesCacheURL(isTestHost: false, home: home).path,
                       "/Users/test/Library/Application Support/App Duplicator/profiles.json")
        let hosted = LaunchEnvironment.profilesCacheURL(isTestHost: true, home: home)
        XCTAssertTrue(hosted.path.hasPrefix(FileManager.default.temporaryDirectory.path), hosted.path)
        XCTAssertNotEqual(hosted, LaunchEnvironment.profilesCacheURL(isTestHost: true, home: home), "unique per call")
        XCTAssertFalse(FileManager.default.fileExists(atPath: hosted.path))
    }
```

In `App/Tests/App/AppStateTests.swift`:

1. Add `import CompatProfiles` above `import XCTest` (line 1).
2. After `testRebuildAllRewritesOnlyStaleRecords` (line 173, the last test) add:

```swift

    func testCheckProfileUpdatesUsesTheSettingsURLAndReportsTheResult() async throws {
        let fork = "https://raw.githubusercontent.com/example/fork/main/profiles.json"
        settings.profilesURLString = fork
        let fetcher = StubProfilesFetcher(.success(try makeProfilesJSON(updated: "2026-10-11", apps: ["com.example.target": "verified"])))
        let profiles = ProfilesModel(bundledURL: nil, cacheURL: dir.appending(path: "profiles.json", directoryHint: .notDirectory), fetcher: fetcher)
        let checking = AppState(settings: settings, library: library, launcherBinary: dir.appending(path: "Launcher"), profiles: profiles)
        XCTAssertNil(state.profile(forBundleIdentifier: "com.example.target"), "the default model is inert and empty")

        let message = await checking.checkProfileUpdates()

        XCTAssertEqual(message, "Downloaded profiles from 2026-10-11.")
        XCTAssertEqual(checking.profileUpdateMessage, message)
        XCTAssertEqual(fetcher.requestedURLs.map(\.absoluteString), [fork])
        XCTAssertEqual(checking.profile(forBundleIdentifier: "com.example.target")?.status, .verified)
    }
```

- [ ] **Step 10: Run the app tests to verify they fail**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/SmokeTests -only-testing:MacAppDuplicatorTests/ProfilesModelTests -only-testing:MacAppDuplicatorTests/AppSettingsTests -only-testing:MacAppDuplicatorTests/LaunchEnvironmentTests -only-testing:MacAppDuplicatorTests/AppStateTests 2>&1 | grep -oE "cannot find (type )?'[A-Za-z]+' in scope" | sort -u`
Expected: `cannot find 'ProfilesModel' in scope` and `cannot find type 'ProfilesModel' in scope` (compile errors; nothing runs). The filter leaves out the other errors, such as `value of type 'AppSettings' has no member 'profilesURLString'` and `type 'LaunchEnvironment' has no member 'profilesCacheURL'`.

- [ ] **Step 11: Implement `ProfilesModel`**

Create `App/Sources/Model/ProfilesModel.swift`:

```swift
import CompatProfiles
import Foundation
import Observation

/// The compatibility profiles the app uses (spec §8): the bundled seed, or the cached remote copy when it is strictly
/// newer. Check Profile Updates is the only thing that fetches, and only when the user chooses it (spec §2).
@MainActor
@Observable
final class ProfilesModel {
    private(set) var catalog: ProfileCatalog
    private(set) var isChecking = false
    /// The result of the last Check Profile Updates, shown in Settings → Profiles.
    private(set) var statusMessage: String?
    let bundledURL: URL?
    let cacheURL: URL
    private let fetcher: any ProfilesFetching

    init(catalog: ProfileCatalog = .empty, bundledURL: URL?, cacheURL: URL, fetcher: any ProfilesFetching) {
        self.catalog = catalog
        self.bundledURL = bundledURL
        self.cacheURL = cacheURL
        self.fetcher = fetcher
    }

    /// No profiles, no seed, a cache path under the temporary directory that nothing writes, and a fetcher that always
    /// refuses: the `AppState` default, so tests and previews never read the real cache or the network.
    static func inert() -> ProfilesModel {
        ProfilesModel(bundledURL: nil,
                      cacheURL: FileManager.default.temporaryDirectory
                          .appending(path: "mad-inert-profiles-\(UUID().uuidString).json", directoryHint: .notDirectory),
                      fetcher: DisabledProfilesFetcher())
    }

    /// Reads the seed and the cache off the main actor; keeps a newer catalog that a check installed meanwhile.
    func load() async {
        let bundledURL = bundledURL
        let cacheURL = cacheURL
        let loaded = await Task.detached { ProfileCatalog.load(bundledURL: bundledURL, cacheURL: cacheURL) }.value
        if !ProfileCatalog.isNewer(catalog.updated, than: loaded.updated) { catalog = loaded }
    }

    func profile(forBundleIdentifier bundleIdentifier: String) -> AppProfile? {
        catalog.profile(forBundleIdentifier: bundleIdentifier)
    }

    /// "18 apps, updated 2026-10-09 (bundled)", or "No profiles loaded."
    var catalogSummary: String {
        guard !catalog.updated.isEmpty else { return "No profiles loaded." }
        let apps = catalog.appCount == 1 ? "1 app" : "\(catalog.appCount) apps"
        return "\(apps), updated \(catalog.updated) (\(catalog.source.rawValue))"
    }

    /// Fetches `url` (nil when the Settings URL is not an allowed address), caches a strictly newer document and
    /// switches to it. Returns the message shown to the user, which is also kept in `statusMessage`.
    @discardableResult
    func checkForUpdates(from url: URL?) async -> String {
        isChecking = true
        defer { isChecking = false }
        let message: String
        if let url {
            do {
                switch try await ProfilesUpdater(fetcher: fetcher, cacheURL: cacheURL).update(from: url, current: catalog) {
                case .updated(let newer):
                    catalog = newer
                    message = "Downloaded profiles from \(newer.updated)."
                case .upToDate(let current, _):
                    message = "Profiles are up to date (\(current))."
                }
            } catch {
                message = "Could not check profile updates: \(error.localizedDescription)"
            }
        } else {
            message = "Could not check profile updates: the profiles URL must be an https://raw.githubusercontent.com address."
        }
        statusMessage = message
        return message
    }
}

/// The fetcher of the unit-test host and of `ProfilesModel.inert()`: it never touches the network.
struct DisabledProfilesFetcher: ProfilesFetching {
    func fetch(from url: URL) async throws -> Data {
        throw ProfilesError.fetchFailed("Profile updates are disabled while the app hosts the unit tests.")
    }
}
```

- [ ] **Step 12: Add the profiles URL setting**

In `App/Sources/Model/AppSettings.swift`:

1. Add `import CompatProfiles` above `import DuplicatorCore` (line 1).
2. In `private enum Key`, after the `homeSymlinkEntries` key (line 18) add:

```swift
        static let profilesURL = "profilesURLString"
```

3. After the `homeSymlinkEntries` property (lines 43-45) add:

```swift
    /// Settings → Profiles. Stored only when it differs from `ProfilesConstants.defaultURLString`, so a later default
    /// reaches users who never changed it.
    var profilesURLString: String {
        didSet {
            if profilesURLString == ProfilesConstants.defaultURLString {
                defaults.removeObject(forKey: Key.profilesURL)
            } else {
                defaults.set(profilesURLString, forKey: Key.profilesURL)
            }
        }
    }
```

4. After the `signerIdentity` property (lines 47-50) add:

```swift

    /// `profilesURLString` without surrounding whitespace, when it is an allowed profiles address; nil otherwise.
    var profilesURL: URL? {
        let trimmed = profilesURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ProfilesFetchPolicy.isAllowedSource(url) else { return nil }
        return url
    }
```

5. In `init(defaults:defaultSigningIdentity:)`, after the `homeSymlinkEntries` assignment (line 63) add:

```swift
        profilesURLString = defaults.string(forKey: Key.profilesURL) ?? ProfilesConstants.defaultURLString
```

- [ ] **Step 13: Add the profiles cache location**

In `App/Sources/App/LaunchEnvironment.swift`:

1. Add `import CompatProfiles` above `import Foundation` (line 1).
2. After `settingsDefaults(isTestHost:suiteName:)` (line 24, before the enum's closing brace) add:

```swift

    /// The profiles cache Check Profile Updates writes (`~/Library/Application Support/App Duplicator/profiles.json`).
    /// Under the test host, a file under the temporary directory, unique to this call, so the host never reads or
    /// writes the real cache.
    static func profilesCacheURL(isTestHost: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        guard isTestHost else { return ProfilesConstants.defaultCacheURL(home: home) }
        return FileManager.default.temporaryDirectory
            .appending(path: "mad-testhost-profiles-\(UUID().uuidString).json", directoryHint: .notDirectory)
    }
```

- [ ] **Step 14: Give `AppState` the profiles model**

In `App/Sources/App/AppState.swift`:

1. Add `import CompatProfiles` above `import DuplicatorCore` (line 2).
2. After `let library: ShortcutLibrary` (line 48) add:

```swift
    let profiles: ProfilesModel
```

3. After `var pendingError: AppError?` (line 54) add:

```swift
    /// The last Check Profile Updates result, shown in an alert until it is dismissed.
    var profileUpdateMessage: String?
```

4. Replace the initializer (lines 56-60)

```swift
    init(settings: AppSettings, library: ShortcutLibrary, launcherBinary: URL) {
        self.settings = settings
        self.library = library
        self.launcherBinary = launcherBinary
    }
```

with

```swift
    init(settings: AppSettings, library: ShortcutLibrary, launcherBinary: URL, profiles: ProfilesModel? = nil) {
        self.settings = settings
        self.library = library
        self.launcherBinary = launcherBinary
        // Main-actor types are never default argument values; nil means the inert model (no profiles, no network).
        self.profiles = profiles ?? .inert()
    }
```

5. After the `builder` property (lines 62-64) add:

```swift

    /// The compatibility profile for a target bundle identifier, if the profiles in use have one.
    func profile(forBundleIdentifier bundleIdentifier: String) -> AppProfile? {
        profiles.profile(forBundleIdentifier: bundleIdentifier)
    }

    /// Check Profile Updates from the toolbar or the app menu: fetches from the Settings URL and keeps the result in
    /// `profileUpdateMessage` for the alert.
    @discardableResult
    func checkProfileUpdates() async -> String {
        let message = await profiles.checkForUpdates(from: settings.profilesURL)
        profileUpdateMessage = message
        return message
    }
```

- [ ] **Step 15: Run the app tests to verify they pass**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/SmokeTests -only-testing:MacAppDuplicatorTests/ProfilesModelTests -only-testing:MacAppDuplicatorTests/AppSettingsTests -only-testing:MacAppDuplicatorTests/LaunchEnvironmentTests -only-testing:MacAppDuplicatorTests/AppStateTests 2>&1 | grep -cE "Test Case '.*' passed"`
Expected: `33` (Smoke 3 + ProfilesModel 5 + AppSettings 11 + LaunchEnvironment 4 + AppState 10).

- [ ] **Step 16: Wire Check Profile Updates and the Profiles settings tab**

In `App/Sources/App/MacAppDuplicatorApp.swift`:

1. Add `import CompatProfiles` above `import SwiftUI` (line 1).
2. In `init()` replace lines 12-15

```swift
        if !isTestHost {
            // `security find-identity` runs off the main thread; until it returns, new shortcuts default to ad hoc.
            Task { await settings.loadDefaultSigningIdentity() }
        }
```

with

```swift
        // As the test host the app never fetches profiles, and its cache path is a temporary file nothing writes.
        let fetcher: any ProfilesFetching = isTestHost ? DisabledProfilesFetcher() : URLSessionProfilesFetcher()
        let profiles = ProfilesModel(bundledURL: Bundle.main.url(forResource: "profiles", withExtension: "json"),
                                     cacheURL: LaunchEnvironment.profilesCacheURL(isTestHost: isTestHost),
                                     fetcher: fetcher)
        if !isTestHost {
            // `security find-identity` runs off the main thread; until it returns, new shortcuts default to ad hoc.
            Task { await settings.loadDefaultSigningIdentity() }
            // The profiles are read off the main thread too; until they load, no target has a profile.
            Task { await profiles.load() }
        }
```

3. Replace the `AppState` line (line 27) with:

```swift
        let state = AppState(settings: settings, library: library, launcherBinary: launcherBinary, profiles: profiles)
```

4. After `.commands {` (line 46) add:

```swift
            CommandGroup(after: .appInfo) {
                Button("Check Profile Updates") { Task { await appState.checkProfileUpdates() } }
                    .disabled(appState.profiles.isChecking)
            }
```

In `App/Sources/Views/ContentView.swift`:

1. After the `Rebuild All` toolbar item (line 30) add:

```swift
            ToolbarItem {
                Button("Check Profile Updates") { Task { await appState.checkProfileUpdates() } }
                    .disabled(appState.profiles.isChecking)
                    .help("Download the latest compatibility profiles from the profiles URL in Settings")
            }
```

2. After the `.alert(item: $appState.pendingError)` modifier (line 42) add:

```swift
        .alert("Check Profile Updates", isPresented: isProfileUpdateAlertPresented) {
            Button("OK") { appState.profileUpdateMessage = nil }
        } message: {
            Text(appState.profileUpdateMessage ?? "")
        }
```

3. After `body` (line 49, before the struct's closing brace) add:

```swift

    /// Shows the Check Profile Updates result until it is dismissed.
    private var isProfileUpdateAlertPresented: Binding<Bool> {
        Binding(get: { appState.profileUpdateMessage != nil }, set: { if !$0 { appState.profileUpdateMessage = nil } })
    }
```

In `App/Sources/Views/SettingsView.swift`:

1. Add `import CompatProfiles` above `import DuplicatorCore` (line 1).
2. After the `Data` tab (lines 13-14) add:

```swift
            ProfilesSettingsTab(settings: appState.settings, profiles: appState.profiles)
                .tabItem { Label("Profiles", systemImage: "checkmark.shield") }
```

3. After `DataSettingsTab` (line 126, the end of the file) add:

```swift

private struct ProfilesSettingsTab: View {
    @Bindable var settings: AppSettings
    let profiles: ProfilesModel

    var body: some View {
        Form {
            TextField("Profiles URL", text: $settings.profilesURLString)
            if settings.profilesURL == nil {
                // Verbatim: a string literal would be read as Markdown and the address shown as a link.
                Label {
                    Text(verbatim: "Use an https://raw.githubusercontent.com address.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(.orange)
            }
            HStack {
                Button("Reset to Default") { settings.profilesURLString = ProfilesConstants.defaultURLString }
                Spacer()
                if profiles.isChecking { ProgressView().controlSize(.small) }
                Button("Check Now") { Task { await profiles.checkForUpdates(from: settings.profilesURL) } }
                    .disabled(profiles.isChecking || settings.profilesURL == nil)
            }
            if let status = profiles.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("In use", value: profiles.catalogSummary)
            Text("Profiles are downloaded only when you choose Check Profile Updates. A downloaded copy is used only when it is newer than the bundled one, and it never changes existing shortcuts: profile values are copied into a shortcut when it is created.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 17: Run the full app suite from a clean build**

The clean build makes every file compile in this run, so every warning the new code causes is printed once.

Run: `cd "$REPO" && rm -rf .build/DerivedData && Tools/test-app.sh 2>&1 | grep -E "Test Case '.*' passed|: warning:|\*\* TEST" | sed -E "s/^Test Case .* passed .*/passed/" | sort | uniq -c`
Expected: exactly two lines, `1 ** TEST SUCCEEDED **` and `118 passed` (108 + 10; the counts are left-padded). Any `: warning:` line names a file to fix before committing.

Run: `cd "$REPO" && nm ".build/DerivedData/Build/Products/Debug/macOS App Duplicator.app/Contents/PlugIns/MacAppDuplicatorTests.xctest/Contents/MacOS/MacAppDuplicatorTests" | grep ' T ' | grep -c 14CompatProfiles`
Expected: `0`. The test bundle defines no global `CompatProfiles` symbol: the module's code exists once, in the framework under the app's `Contents/Frameworks`. A second, static copy in the test bundle would register `URLSessionProfilesFetcher`'s Objective-C class twice.

- [ ] **Step 18: Commit**

```bash
cd "$REPO" && git add Packages/CompatProfiles/Resources/profiles.json Packages/CompatProfiles/Tests/CompatProfilesTests/SeedProfilesTests.swift App/project.yml App/Sources/Model/ProfilesModel.swift App/Sources/Model/AppSettings.swift App/Sources/App/LaunchEnvironment.swift App/Sources/App/AppState.swift App/Sources/App/MacAppDuplicatorApp.swift App/Sources/Views/ContentView.swift App/Sources/Views/SettingsView.swift App/Tests/TestSupport/AppTestSupport.swift App/Tests/SmokeTests.swift App/Tests/Model/ProfilesModelTests.swift App/Tests/Model/AppSettingsTests.swift App/Tests/App/LaunchEnvironmentTests.swift App/Tests/App/AppStateTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -q -F - <<'MSG'
feat(app): bundle the profiles seed and add Check Profile Updates

The seed lists the 18 apps of spec §8: Claude is verified, every other entry
is partial (Terminal is System Launch only), and no entry sets launch values
yet. The app copies it into Contents/Resources. The app and test targets
declare CompatProfiles; Xcode builds it once, as a framework inside the app,
and both link it.

ProfilesModel holds the seed, or the cached download when it is strictly
newer, and reads both off the main thread at launch. Check Profile Updates is
in the toolbar, the app menu and Settings → Profiles. The URL setting accepts
only https://raw.githubusercontent.com addresses and is stored only when it
differs from the default. As the test host the app gets a fetcher that never
touches the network and a throwaway cache path.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

`App/MacAppDuplicator.xcodeproj` is generated and ignored, so `git status --short` is empty after the commit.

---

### Task 4: Argument secret masking — Launcher log, Diagnostics, previews and the export notice

**Files:**
- Modify: `Packages/DuplicatorCore/Sources/DuplicatorCore/SecretMasking.swift:21` (`maskArguments`, `maskLogLine`)
- Modify: `Packages/DuplicatorCore/Sources/DuplicatorCore/LaunchLogger.swift:39` (`log(arguments:)`)
- Modify: `Launcher/Sources/Launcher/main.swift:29` (argv logged through the masking API)
- Modify: `App/Sources/Services/LaunchPlanPreview.swift:7,21` (masked arguments)
- Modify: `App/Sources/Services/ExportInstructions.swift:4-5,29-35` (secret argument names in the notice)
- Modify: `App/Sources/Views/ExportSheet.swift:8,25` (`arguments` property)
- Modify: `App/Sources/Views/ShortcutEditorView.swift:83` (passes the saved arguments)
- Modify: `App/Sources/Views/DiagnosticsView.swift:6,21,36,55,74,115` (engine version, masked log lines)
- Test: `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/SecretMaskingTests.swift:32` (modify)
- Test: `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/LaunchLoggerTests.swift:57` (modify)
- Test: `App/Tests/Services/LaunchPlanPreviewTests.swift:36` (modify)
- Test: `App/Tests/Services/ExportInstructionsTests.swift:57` (modify)
- Test: `App/Tests/App/DiagnosticsModelTests.swift:103` (modify)

**Interfaces:**
- Consumes (Phase 1 and 2 only; nothing from Tasks 1–3): `SecretMasking.maskedValue`, `SecretMasking.isSecretKey(_:)`, `LaunchLogger.log(_:)`, `LaunchPlan.arguments` (argv after argv[0]: planner arguments, then `ShortcutConfig.arguments`), `LaunchPlanPreview.make(config:bundleURL:)`, `ShortcutRecord.engineVersion` (read from `MADEngineVersion`, 0 when missing), `ShortcutConfig.currentEngineVersion`, `LogReader(folder:)` and `tail(name:)`, `ExportInstructions.secretNotice(for:)`, `LibraryScanner.record(forBundleAt:fileManager:)`; test helpers `makeTemporaryDirectory()` (Core), `makeAppTemporaryDirectory()`, `writeFakeTarget(named:bundleIdentifier:version:in:)`, `writeShortcutBundle(named:in:config:engineVersion:)`, `makeConfig(name:targetPath:)`.
- Produces (used by Tasks 5, 7 and 10):
  - `SecretMasking.maskArguments(_ arguments: [String]) -> [String]` and `SecretMasking.maskLogLine(_ line: String) -> String` (public, DuplicatorCore). Task 5 shows profile arguments through `maskArguments`.
  - `LaunchLogger.log(arguments: [String])` (public): one `argv …` line with secret values masked.
  - `LaunchPlanPreview.arguments` holds masked values from this task on; the preview keeps no unmasked copy.
  - `ExportInstructions.secretNotice(for environment: [String: String], arguments: [String] = []) -> String?` and `ExportInstructions.secretArgumentNames(in arguments: [String]) -> [String]`.
  - `ExportSheet(exportedURL: URL, environment: [String: String] = [:], arguments: [String] = [])`; Task 7 edits the sheet and its call in `ShortcutEditorView`.
  - `DiagnosticsModel.engineVersion: Int`, declared right after `bundlePath`; the report line `Engine version: N (current M)` follows the `Bundle:` line and the view row `Engine` follows the `Bundle` row. Task 5 adds the profile fields after them.

- [ ] **Step 1: Write the failing Core tests**

In `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/SecretMaskingTests.swift`, after `testEmptyEnvironment` (line 32, the last test) add:

```swift

    func testMaskArgumentsHidesSecretValues() {
        let arguments = [
            "--api-key", "hunter2", "--token=not-a-real-token", "-password", "pw", "--plain", "visible", "positional",
            "API_TOKEN=leaked",
        ]
        XCTAssertEqual(SecretMasking.maskArguments(arguments), [
            "--api-key", "••••••", "--token=••••••", "-password", "••••••", "--plain", "visible", "positional",
            "API_TOKEN=••••••",
        ])
    }

    func testMaskArgumentsLeavesFlagsAndPlannerArgumentsAlone() {
        // A secret flag followed by another flag has no value to hide.
        XCTAssertEqual(SecretMasking.maskArguments(["--token", "--verbose", "x"]), ["--token", "--verbose", "x"])
        // Every argument DataSeparationPlanner adds stays readable.
        let planner = [
            "--user-data-dir=/tmp/data", "--profile", "/tmp/profile", "--no-remote", "-data", "/tmp/workspace",
            "-configuration", "/tmp/configuration", "-NSRequiresAquaSystemAppearance", "YES", "--force-dark-mode",
            "-AppleLanguages", "(de)", "-AppleLocale", "de",
        ]
        XCTAssertEqual(SecretMasking.maskArguments(planner), planner)
        XCTAssertEqual(SecretMasking.maskArguments([]), [])
        // Over-masking is accepted: a flag that merely contains "key" hides its value too.
        XCTAssertEqual(SecretMasking.maskArguments(["--use-mock-keychain", "value"]), ["--use-mock-keychain", "••••••"])
    }

    func testMaskLogLineMasksArgvAndEnvironmentWords() {
        XCTAssertEqual(
            SecretMasking.maskLogLine("2026-10-01T09:00:00Z argv --api-key hunter2 --token=abc --plain v"),
            "2026-10-01T09:00:00Z argv --api-key •••••• --token=•••••• --plain v"
        )
        XCTAssertEqual(
            SecretMasking.maskLogLine("2026-10-01T09:00:00Z env GITHUB_TOKEN=leaked"),
            "2026-10-01T09:00:00Z env GITHUB_TOKEN=••••••"
        )
        let plain = "2026-10-01T09:00:00Z config name=Claude Work mode=dockShortcut data=auto"
        XCTAssertEqual(SecretMasking.maskLogLine(plain), plain)
        XCTAssertEqual(SecretMasking.maskLogLine(""), "")
    }
```

In `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/LaunchLoggerTests.swift`, after `testEnvironmentIsLoggedSortedAndMasked` (line 57, the last test) add:

```swift

    func testArgumentsAreLoggedOnOneLineWithSecretValuesMasked() throws {
        let logger = LaunchLogger(name: "Argv", directory: try makeTemporaryDirectory(), maxBytes: 10_000)
        logger.log(arguments: ["--user-data-dir=/tmp/data", "--api-key", "hunter2", "--token=not-a-real-token", "--plain", "visible"])
        let written = try lines(of: logger.fileURL).map { $0.split(separator: " ", maxSplits: 1).last.map(String.init) ?? "" }
        XCTAssertEqual(written, ["argv --user-data-dir=/tmp/data --api-key •••••• --token=•••••• --plain visible"])
        let raw = try String(contentsOf: logger.fileURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("hunter2"))
        XCTAssertFalse(raw.contains("not-a-real-token"))
    }
```

- [ ] **Step 2: Run the Core tests to verify they fail**

Run: `cd "$REPO" && swift test --filter DuplicatorCoreTests 2>&1 | grep -oE "has no member '[A-Za-z]+'|no exact matches in call to instance method 'log'" | sort -u`
Expected: compile errors; nothing runs. In practice the list is `has no member 'maskArguments'` and `has no member 'maskLogLine'`. The build stops at the first test file that fails, so `no exact matches in call to instance method 'log'` (the `log(arguments:)` call in `LaunchLoggerTests.swift`) can appear next to them, or alone when the compiler reaches that file first.

- [ ] **Step 3: Implement `maskArguments` and `maskLogLine`**

In `Packages/DuplicatorCore/Sources/DuplicatorCore/SecretMasking.swift`, after `mask(_:)` (line 21, before the enum's closing brace) add:

```swift

    /// Argument list with secret values replaced by `maskedValue`, for the launcher log, Diagnostics and previews.
    /// An argument's name is its text after any leading dashes and before the first `=`. `--api-key=v` and
    /// `API_TOKEN=v` keep their name and lose their value when the name matches `secretKeyPattern`; a secret flag
    /// without `=` (`--token v`) hides the argument after it unless that one starts with `-`. Everything else passes
    /// through. Over-masking is accepted: `--use-mock-keychain value` hides `value`.
    public static func maskArguments(_ arguments: [String]) -> [String] {
        var masked: [String] = []
        masked.reserveCapacity(arguments.count)
        var nextIsSecret = false
        for argument in arguments {
            let isFlag = argument.hasPrefix("-")
            if nextIsSecret, !isFlag {
                masked.append(maskedValue)
                nextIsSecret = false
                continue
            }
            let name = argument.drop { $0 == "-" }
            if let equals = name.firstIndex(of: "=") {
                nextIsSecret = false
                masked.append(isSecretKey(String(name[..<equals])) ? String(argument[...equals]) + maskedValue : argument)
            } else {
                nextIsSecret = isFlag && isSecretKey(String(name))
                masked.append(argument)
            }
        }
        return masked
    }

    /// `maskArguments` applied to the space-separated words of one launcher log line. Diagnostics uses it for log
    /// files written before the launcher masked argv. Best effort: a secret value that contains a space is hidden only
    /// up to its first space.
    public static func maskLogLine(_ line: String) -> String {
        maskArguments(line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)).joined(separator: " ")
    }
```

- [ ] **Step 4: Add `LaunchLogger.log(arguments:)`**

In `Packages/DuplicatorCore/Sources/DuplicatorCore/LaunchLogger.swift`, after `log(environment:)` (line 39) add:

```swift

    /// Logs `argv <arguments>` on one line, secret values masked per `SecretMasking.maskArguments`.
    public func log(arguments: [String]) {
        log("argv \(SecretMasking.maskArguments(arguments).joined(separator: " "))")
    }
```

- [ ] **Step 5: Run the Core tests to verify they pass**

Run: `cd "$REPO" && swift test --filter DuplicatorCoreTests 2>&1 | grep -E 'Executed|error:' | tail -3`
Expected: `Executed 115 tests, with 0 failures` (111 + 4).

- [ ] **Step 6: Log argv through the masking API in the Launcher**

In `Launcher/Sources/Launcher/main.swift` line 29 replace

```swift
logger.log("argv \(plan.arguments.joined(separator: " "))")
```

with

```swift
logger.log(arguments: plan.arguments)
```

The line keeps its `argv ` prefix and word order; only secret values change. Each shortcut bundle carries its own copy of the Launcher, so shortcuts built before this commit keep logging argv unmasked until they are Regenerated (Known Limitation `argument-logging`, Task 10); Diagnostics masks those log lines for display (Step 11).

Run: `cd "$REPO" && swift build 2>&1 | grep -E 'error:|warning:|Build complete'`
Expected: `Build complete!` and no `error:` or `warning:` lines.

- [ ] **Step 7: Write the failing app tests**

In `App/Tests/Services/LaunchPlanPreviewTests.swift`, after `testPreviewMissingTargetThrows` (line 36, the last test) add:

```swift

    func testPreviewMasksSecretArgumentValues() throws {
        var config = makeConfig(targetPath: dir.appending(path: "Target.app").path)
        config.arguments = ["--api-key", "hunter2", "--token=not-a-real-token", "--plain", "visible"]

        let preview = try LaunchPlanPreview.make(config: config, bundleURL: nil)

        // The /bin/ls stand-in is a native app, so the planner adds no arguments of its own.
        XCTAssertEqual(preview.arguments, ["--api-key", "••••••", "--token=••••••", "--plain", "visible"])
    }
```

In `App/Tests/Services/ExportInstructionsTests.swift`, after `testSecretNoticeOnlyWhenAKeyLooksSecret` (line 57, the last test) add:

```swift

    func testSecretNoticeNamesSecretArgumentsButNeverTheirValues() throws {
        // Arguments with nothing secret leave the environment-only behaviour unchanged.
        XCTAssertNil(ExportInstructions.secretNotice(for: [:], arguments: ["--plain", "visible"]))
        XCTAssertEqual(
            ExportInstructions.secretNotice(for: ["GITHUB_TOKEN": "x"], arguments: ["--plain", "visible"]),
            "Environment values travel in plain text inside the exported shortcut, including GITHUB_TOKEN."
        )

        let notice = try XCTUnwrap(ExportInstructions.secretNotice(
            for: ["PLAIN": "ok", "GITHUB_TOKEN": "leaked"],
            arguments: ["--api-key", "hunter2", "--token=not-a-real-token", "--plain", "visible", "--api-key", "again"]
        ))
        XCTAssertEqual(
            notice,
            "Environment values and arguments travel in plain text inside the exported shortcut, including GITHUB_TOKEN, --api-key, --token."
        )
        for value in ["leaked", "hunter2", "not-a-real-token", "visible", "again"] {
            XCTAssertFalse(notice.contains(value), value)
        }
        XCTAssertEqual(
            ExportInstructions.secretNotice(for: [:], arguments: ["--token=abc"]),
            "Environment values and arguments travel in plain text inside the exported shortcut, including --token."
        )
    }
```

In `App/Tests/App/DiagnosticsModelTests.swift`, after `testStaleStoredPathResolvesThroughLaunchServices` (line 103, the last test) add:

```swift

    func testMasksSecretArgumentsAndOldLogLinesAndShowsTheEngineVersion() throws {
        let target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "1.0", in: dir)
        try FileManager.default.removeItem(at: target.appending(path: "Contents/MacOS/Target"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: target.appending(path: "Contents/MacOS/Target"))
        var config = makeConfig(name: "Target Work", targetPath: target.path)
        config.arguments = ["--api-key", "hunter2", "--token=not-a-real-token", "--plain", "visible"]
        let bundle = try writeShortcutBundle(named: "Target Work", in: dir, config: config, engineVersion: 0)
        let record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))

        // Lines a launcher built before argv masking wrote.
        let logs = dir.appending(path: "logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "2026-10-01T09:00:00Z argv --api-key hunter2 --token=not-a-real-token\n2026-10-01T09:00:00Z env GITHUB_TOKEN=leaked\n"
            .write(to: logs.appending(path: "Target Work.log"), atomically: true, encoding: .utf8)

        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: logs))
        XCTAssertNil(model.planError)
        XCTAssertEqual(model.arguments, ["--api-key", "••••••", "--token=••••••", "--plain", "visible"])
        XCTAssertEqual(model.engineVersion, 0)
        XCTAssertEqual(model.logLines, [
            "2026-10-01T09:00:00Z argv --api-key •••••• --token=••••••",
            "2026-10-01T09:00:00Z env GITHUB_TOKEN=••••••",
        ])
        let report = model.reportText
        XCTAssertTrue(report.contains("Engine version: 0 (current \(ShortcutConfig.currentEngineVersion))"), report)
        for secret in ["hunter2", "not-a-real-token", "leaked"] {
            XCTAssertFalse(report.contains(secret), secret)
        }
    }
```

- [ ] **Step 8: Run the app tests to verify they fail**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/LaunchPlanPreviewTests -only-testing:MacAppDuplicatorTests/ExportInstructionsTests -only-testing:MacAppDuplicatorTests/DiagnosticsModelTests 2>&1 | grep -E 'error:' | sed -E 's/.*error: //' | sort -u`
Expected: exactly `extra argument 'arguments' in call` and `value of type 'DiagnosticsModel' has no member 'engineVersion'` (compile errors; nothing runs). The new `LaunchPlanPreviewTests` test compiles against today's API and would fail on its assertion; the compile errors stop the run first.

- [ ] **Step 9: Mask the preview's arguments**

In `App/Sources/Services/LaunchPlanPreview.swift`:

1. Add above `var arguments: [String]` (line 7):

```swift
    /// argv after argv[0] (planner arguments, then the shortcut's), secret values masked per `SecretMasking.maskArguments`.
```

2. In `make(config:bundleURL:)` (line 21) replace `arguments: plan.arguments,` with `arguments: SecretMasking.maskArguments(plan.arguments),`.

Diagnostics (`DiagnosticsModel.arguments`) and the wizard Review step (`App/Sources/Views/Wizard/WizardSteps.swift:236`) read `preview.arguments`, so both show masked values without a change of their own.

- [ ] **Step 10: Name secret arguments in the export notice**

In `App/Sources/Services/ExportInstructions.swift` lines 4-5 replace

```swift
/// Copy for the export sheet (spec §7): how the exported copy is signed, the quarantine-removal command for the other
/// Mac, and a warning when environment values that look secret travel with it.
```

with

```swift
/// Copy for the export sheet (spec §7): how the exported copy is signed, the quarantine-removal command for the other
/// Mac, and a warning when environment values or arguments that look secret travel with it.
```

In `App/Sources/Services/ExportInstructions.swift` lines 29-35 replace

```swift
    /// One line naming the keys that match `SecretMasking.isSecretKey` (never their values), or nil when none do:
    /// the exported Info.plist carries every environment value in plain text.
    static func secretNotice(for environment: [String: String]) -> String? {
        let keys = environment.keys.filter { SecretMasking.isSecretKey($0) }.sorted()
        guard !keys.isEmpty else { return nil }
        return "Environment values travel in plain text inside the exported shortcut, including \(keys.joined(separator: ", "))."
    }
```

with

```swift
    /// One line naming the environment keys that match `SecretMasking.isSecretKey` and the arguments that
    /// `SecretMasking.maskArguments` hides (never their values), or nil when there are none: the exported Info.plist
    /// carries every environment value and argument in plain text. Without secret arguments the wording is the
    /// environment-only sentence.
    static func secretNotice(for environment: [String: String], arguments: [String] = []) -> String? {
        let keys = environment.keys.filter { SecretMasking.isSecretKey($0) }.sorted()
        let argumentNames = secretArgumentNames(in: arguments)
        guard !argumentNames.isEmpty else {
            guard !keys.isEmpty else { return nil }
            return "Environment values travel in plain text inside the exported shortcut, including \(keys.joined(separator: ", "))."
        }
        let names = (keys + argumentNames).joined(separator: ", ")
        return "Environment values and arguments travel in plain text inside the exported shortcut, including \(names)."
    }

    /// Names of the arguments `SecretMasking.maskArguments` hides, in order and without repeats: the text before `=`
    /// for `--name=value` and `NAME=value`, the flag before it for a value passed as its own argument.
    static func secretArgumentNames(in arguments: [String]) -> [String] {
        var names: [String] = []
        var previous: String?
        for (argument, shown) in zip(arguments, SecretMasking.maskArguments(arguments)) {
            defer { previous = argument }
            guard shown != argument else { continue }
            let name = shown == SecretMasking.maskedValue ? (previous ?? "") : String(argument.prefix { $0 != "=" })
            if !name.isEmpty, !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }
```

In `App/Sources/Views/ExportSheet.swift`:

1. After `var environment: [String: String] = [:]` (line 8) add:

```swift
    /// The exported shortcut's saved arguments; the notice names the secret-looking ones, never their values.
    var arguments: [String] = []
```

2. In line 25 replace `ExportInstructions.secretNotice(for: environment)` with `ExportInstructions.secretNotice(for: environment, arguments: arguments)`.

In `App/Sources/Views/ShortcutEditorView.swift` line 83 replace

```swift
            ExportSheet(exportedURL: url, environment: record.config.environment)
```

with

```swift
            ExportSheet(exportedURL: url, environment: record.config.environment, arguments: record.config.arguments)
```

- [ ] **Step 11: Show the engine version and mask old log lines in Diagnostics**

In `App/Sources/Views/DiagnosticsView.swift`:

1. After `let bundlePath: String` (line 6) add:

```swift
    /// The bundle's `MADEngineVersion` (0 when missing); below `ShortcutConfig.currentEngineVersion` means Regenerate is due.
    let engineVersion: Int
```

2. In `make(record:logReader:)` replace `let logLines = logReader.tail(name: record.name)` (line 21) with:

```swift
        // Lines a launcher built before argv masking wrote can hold secret argument values; mask them for display and
        // for the copied report.
        let logLines = logReader.tail(name: record.name).map(SecretMasking.maskLogLine)
```

3. After `bundlePath: record.bundleURL.path,` in `make` (line 36) and in `failed` (line 55) add `engineVersion: record.engineVersion,` at the same indentation.
4. In `reportText`, after `lines.append("Bundle: \(bundlePath)")` (line 74) add:

```swift
        lines.append("Engine version: \(engineVersion) (current \(ShortcutConfig.currentEngineVersion))")
```

5. In the `Shortcut` section of `DiagnosticsView.body`, after `row("Bundle", model.bundlePath)` (line 115) add:

```swift
                            row("Engine", "\(model.engineVersion) (current \(ShortcutConfig.currentEngineVersion))")
```

- [ ] **Step 12: Run the app tests to verify they pass**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/LaunchPlanPreviewTests -only-testing:MacAppDuplicatorTests/ExportInstructionsTests -only-testing:MacAppDuplicatorTests/DiagnosticsModelTests 2>&1 | grep -cE "Test Case '.*' passed"`
Expected: `15` (LaunchPlanPreview 3 + ExportInstructions 6 + DiagnosticsModel 6).

- [ ] **Step 13: Run the full app suite**

Run: `cd "$REPO" && Tools/test-app.sh 2>&1 | grep -E "Test Case '.*' passed|: warning:|\*\* TEST" | sed -E "s/^Test Case .* passed .*/passed/" | sort | uniq -c`
Expected: exactly two lines, `1 ** TEST SUCCEEDED **` and `121 passed` (118 + 3; the counts are left-padded). Any `: warning:` line names a file to fix before committing.

- [ ] **Step 14: Commit**

```bash
cd "$REPO" && git add Packages/DuplicatorCore/Sources/DuplicatorCore/SecretMasking.swift Packages/DuplicatorCore/Sources/DuplicatorCore/LaunchLogger.swift Launcher/Sources/Launcher/main.swift App/Sources/Services/LaunchPlanPreview.swift App/Sources/Services/ExportInstructions.swift App/Sources/Views/ExportSheet.swift App/Sources/Views/ShortcutEditorView.swift App/Sources/Views/DiagnosticsView.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/SecretMaskingTests.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/LaunchLoggerTests.swift App/Tests/Services/LaunchPlanPreviewTests.swift App/Tests/Services/ExportInstructionsTests.swift App/Tests/App/DiagnosticsModelTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -q -F - <<'MSG'
feat: mask secret argument values in the launcher log, Diagnostics and previews

SecretMasking.maskArguments hides the value of every argument whose name
(leading dashes dropped, text before "=") matches the spec §2 secret pattern:
--api-key=v and API_TOKEN=v keep their names, and a bare secret flag hides the
argument after it. The launcher logs argv through it, LaunchPlanPreview masks
its arguments for Diagnostics and the wizard Review step, and Diagnostics
masks log lines an older launcher wrote. The export notice names secret
arguments next to the environment keys, never their values.

Diagnostics also shows the bundle's engine version next to the current one.
The engine version stays 1, so existing shortcuts keep logging argv unmasked
until they are Regenerated.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 5: Profile-driven badges, creation defaults, the Profile section and Diagnostics profile match

**Files:**
- Create: `App/Sources/Services/ProfileSummary.swift`
- Create: `App/Sources/Views/ProfileSummaryView.swift`
- Modify: `App/Sources/Services/CompatBadge.swift:1-18` (whole file replaced; profile status, sandboxed native)
- Modify: `App/Sources/Services/LaunchPlanPreview.swift:14,26` (`family`)
- Modify: `App/Sources/Views/Wizard/WizardModel.swift:1,23,35,37-42,67,81,108` (profile and its defaults)
- Modify: `App/Sources/Views/Wizard/NewShortcutWizard.swift:6,55-60` (profile lookup; the model is built once per presentation)
- Modify: `App/Sources/Views/Wizard/WizardSteps.swift:1,64,216,218-247` (badge, Review profile row and defaults)
- Modify: `App/Sources/Views/EditorSections.swift:1,45,57,79` (TargetSection badge, new `ProfileSection`)
- Modify: `App/Sources/Views/ShortcutEditorView.swift:1,23,28,86` (profile lookup, Profile section, Diagnostics catalog)
- Modify: `App/Sources/Views/DiagnosticsView.swift:1,8,22,25,31,41,53,57,61,81,111,123,134,165-168` (profile match and rows)
- Modify: `Packages/DuplicatorCore/Sources/DuplicatorCore/DataSeparationPlanner.swift:19-22` (doc comment only)
- Test: `App/Tests/Services/CompatBadgeTests.swift:1,6,8,25` (modify)
- Test: `App/Tests/Services/ProfileSummaryTests.swift`
- Test: `App/Tests/Services/LaunchPlanPreviewTests.swift:31` (modify)
- Test: `App/Tests/Wizard/WizardModelTests.swift:1,106` (modify)
- Test: `App/Tests/App/DiagnosticsModelTests.swift:1,133` (modify)

**Interfaces:**
- Consumes (Tasks 1, 3 and 4; Phase 1 and 2): `AppProfile` (`name`, `status`, `family: AppFamily?`, `args: [String]`, `env: [String: String]`, `notes: String?`; `init(name:status:family:args:env:newWindowCommand:notes:)` with every parameter after `status` defaulted), `ProfileStatus` (`verified`, `partial`, `unsupported`, `CaseIterable` in that order), `ProfileCatalog` (`init(document:source:)`, `empty`, `updated` (empty for `empty`), `source`, `profile(forBundleIdentifier:)`: exact key first, then case-insensitive), `ProfileSource` (`bundled`, `cached`; the `rawValue` is the word shown) and `ProfilesDocument(updated:apps:)` (Task 1); `AppState.profile(forBundleIdentifier:) -> AppProfile?` and `AppState.profiles.catalog` (Task 3); `SecretMasking.maskArguments(_:)`, `DiagnosticsModel.engineVersion` with its `Engine version:` report line and `Engine` view row, and the masked `LaunchPlanPreview.arguments` (Task 4); `InspectedApp` (`family`, `isSandboxed`, `bundleIdentifier`), `AppFamily`, `SecretMasking.mask(_:)`, `SecretMasking.maskedValue`, `LaunchPlanPreview.make(config:bundleURL:)`, the `ShortcutConfig` init labels `dataPath:`, `environment:`, `arguments:` in that order, `AppState.wizardPrefillTarget`, `LibraryScanner.record(forBundleAt:fileManager:)`, `LogReader(folder:)`; test helpers `makeAppTemporaryDirectory()`, `writeFakeTarget(named:bundleIdentifier:version:in:)`, `writeShortcutBundle(named:in:config:)`, `makeConfig(name:targetPath:targetBundleIdentifier:)`.
- Produces (used by Tasks 7, 8 and 10):
  - `CompatBadge.badge(for app: InspectedApp?, profile: AppProfile? = nil) -> CompatBadge`, decided in this order: no inspected app → `unknown`; profile `unsupported` → `unsupported`; profile `verified` → `verified`; sandboxed native → `unknown` (final review M9); other native → `homeOnly`; every other family → `auto`. A `partial` profile changes nothing.
  - `enum ProfileSummary` (`App/Sources/Services/ProfileSummary.swift`): `struct Row: Equatable, Identifiable, Sendable` (`label`, `value`, `id` = `label`), `statusLabel(_ status: ProfileStatus) -> String`, `familyName(_ family: AppFamily) -> String`, `rows(for profile: AppProfile?, detectedFamily: AppFamily?) -> [Row]`, `matchLine(bundleIdentifier: String, catalog: ProfileCatalog) -> String`, `familyNote(profile: AppProfile?, detected: AppFamily?) -> String?`.
  - `ProfileSummaryView(rows: [ProfileSummary.Row])` (`App/Sources/Views/ProfileSummaryView.swift`).
  - `LaunchPlanPreview.family: AppFamily`, the family the planner used.
  - `WizardModel.init(prefillTarget: URL? = nil, profileLookup: @escaping @MainActor (String) -> AppProfile? = { _ in nil })`; `private(set) var profile: AppProfile?`, `arguments: [String]` and `environment: [String: String]`, all replaced in `selectTarget(_:)`; `makeConfig()` passes `environment:` and `arguments:`. Task 8 builds test models as `WizardModel(prefillTarget:profileLookup:)`.
  - `NewShortcutWizard` builds its model once per presentation in `onAppear`, guarded by `@State private var isSetUp`.
  - `TargetSection(draft:inspected:profile:)` and `ProfileSection(bundleIdentifier: String, profile: AppProfile?, detectedFamily: AppFamily?)`; `ProfileSection` comes right after `TargetSection` in `ShortcutEditorView`.
  - `DiagnosticsModel.make(record:logReader: = LogReader(), profileCatalog: ProfileCatalog = .empty)`; `profileMatch: String` and `profileRows: [ProfileSummary.Row]`, declared after `engineVersion`; the report lines `Profile: <match>` and `  <label>: <value>` follow `Engine version:`, the view row `Profile` follows `Engine`, and the `Profile` section follows `Shortcut` when there are rows.
  - `DiagnosticsView(record: ShortcutRecord, profileCatalog: ProfileCatalog)`.

- [ ] **Step 1: Write the failing app tests**

In `App/Tests/Services/CompatBadgeTests.swift`:

1. Add `import CompatProfiles` above `import XCTest` (line 1).
2. In line 6 replace `private func app(family: AppFamily) -> InspectedApp {` with `private func app(family: AppFamily, sandboxed: Bool = false) -> InspectedApp {`.
3. In line 8 replace `isSandboxed: false,` with `isSandboxed: sandboxed,`.
4. After `testLabels` (line 25, the last test) add:

```swift

    func testProfileStatusComesBeforeTheFamily() {
        let verified = AppProfile(name: "X", status: .verified)
        let partial = AppProfile(name: "X", status: .partial, family: .electron)
        let unsupported = AppProfile(name: "X", status: .unsupported)
        // A profile that marks the app single-instance wins over every family, native included.
        XCTAssertEqual(CompatBadge.badge(for: app(family: .native), profile: unsupported), .unsupported)
        XCTAssertEqual(CompatBadge.badge(for: app(family: .electron), profile: unsupported), .unsupported)
        XCTAssertEqual(CompatBadge.badge(for: app(family: .native), profile: verified), .verified)
        XCTAssertEqual(CompatBadge.badge(for: app(family: .chromium), profile: verified), .verified)
        // A partial profile says nothing about the badge; the detected family decides.
        XCTAssertEqual(CompatBadge.badge(for: app(family: .native), profile: partial), .homeOnly)
        XCTAssertEqual(CompatBadge.badge(for: app(family: .firefox), profile: partial), .auto)
        // Without an inspected app there is nothing to badge, whatever the profile says.
        XCTAssertEqual(CompatBadge.badge(for: nil, profile: verified), .unknown)
        XCTAssertEqual(CompatBadge.badge(for: nil, profile: unsupported), .unknown)
    }

    func testSandboxedNativeAppIsUnknown() {
        // Final review M9: a sandboxed app's container ignores a HOME override, so `HOME only` would promise too much.
        XCTAssertEqual(CompatBadge.badge(for: app(family: .native, sandboxed: true)), .unknown)
        XCTAssertEqual(CompatBadge.badge(for: app(family: .native, sandboxed: false)), .homeOnly)
        XCTAssertEqual(CompatBadge.badge(for: app(family: .electron, sandboxed: true)), .auto)
        // A profile still decides first.
        XCTAssertEqual(CompatBadge.badge(for: app(family: .native, sandboxed: true), profile: AppProfile(name: "X", status: .verified)), .verified)
    }
```

Create `App/Tests/Services/ProfileSummaryTests.swift`:

```swift
import CompatProfiles
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class ProfileSummaryTests: XCTestCase {
    func testRowsShowEveryFieldWithSecretsMasked() {
        let profile = AppProfile(name: "Target", status: .partial, family: .electron,
                                 args: ["--api-key", "hunter2", "--plain"], env: ["PLAIN": "ok", "API_TOKEN": "leaked"],
                                 notes: "Opens one window per data folder.")
        let rows = ProfileSummary.rows(for: profile, detectedFamily: .native)
        XCTAssertEqual(rows.map(\.label), ["Name", "Status", "Family", "Arguments", "Environment", "Notes", "Family note"])
        XCTAssertEqual(rows.map(\.value), [
            "Target",
            "Partial",
            "Electron",
            "--api-key •••••• --plain",
            "API_TOKEN=•••••• PLAIN=ok",
            "Opens one window per data folder.",
            "The profile lists family Electron but App Duplicator detected Native; launch settings follow the detected family.",
        ])
        for row in rows {
            XCTAssertFalse(row.value.contains("hunter2"), row.label)
            XCTAssertFalse(row.value.contains("leaked"), row.label)
        }
    }

    func testRowsWithoutAProfileOrWithOnlyTheRequiredFields() {
        XCTAssertEqual(ProfileSummary.rows(for: nil, detectedFamily: .native), [])
        XCTAssertEqual(ProfileSummary.rows(for: AppProfile(name: "Bare", status: .verified), detectedFamily: .electron), [
            ProfileSummary.Row(label: "Name", value: "Bare"),
            ProfileSummary.Row(label: "Status", value: "Verified"),
            ProfileSummary.Row(label: "Arguments", value: "None"),
            ProfileSummary.Row(label: "Environment", value: "None"),
        ])
        // Empty notes add no row.
        XCTAssertFalse(ProfileSummary.rows(for: AppProfile(name: "Bare", status: .partial, notes: ""), detectedFamily: nil)
            .contains { $0.label == "Notes" })
    }

    func testMatchLine() {
        let catalog = ProfileCatalog(
            document: ProfilesDocument(updated: "2026-10-09", apps: ["com.example.target": AppProfile(name: "Target", status: .verified)]),
            source: .cached
        )
        XCTAssertEqual(ProfileSummary.matchLine(bundleIdentifier: "com.example.target", catalog: catalog),
                       "com.example.target · Verified · updated 2026-10-09 · cached")
        // The catalog falls back to a case-insensitive match; the line shows the target's own identifier.
        XCTAssertEqual(ProfileSummary.matchLine(bundleIdentifier: "COM.EXAMPLE.TARGET", catalog: catalog),
                       "COM.EXAMPLE.TARGET · Verified · updated 2026-10-09 · cached")
        XCTAssertEqual(ProfileSummary.matchLine(bundleIdentifier: "com.example.other", catalog: catalog),
                       "No profile for com.example.other (profiles updated 2026-10-09, cached)")
        XCTAssertEqual(ProfileSummary.matchLine(bundleIdentifier: "com.example.target", catalog: .empty), "No profiles loaded.")
    }

    func testFamilyNoteStatusAndFamilyNames() {
        let electron = AppProfile(name: "X", status: .partial, family: .electron)
        XCTAssertNil(ProfileSummary.familyNote(profile: electron, detected: .electron))
        XCTAssertNil(ProfileSummary.familyNote(profile: electron, detected: nil))
        XCTAssertNil(ProfileSummary.familyNote(profile: AppProfile(name: "X", status: .partial), detected: .native))
        XCTAssertNil(ProfileSummary.familyNote(profile: nil, detected: .native))
        XCTAssertEqual(ProfileSummary.familyNote(profile: electron, detected: .chromium),
                       "The profile lists family Electron but App Duplicator detected Chromium; launch settings follow the detected family.")
        XCTAssertEqual(ProfileStatus.allCases.map(ProfileSummary.statusLabel), ["Verified", "Partial", "Unsupported"])
        XCTAssertEqual([AppFamily.todesktop, .electron, .chromium, .firefox, .eclipse, .native].map(ProfileSummary.familyName),
                       ["ToDesktop", "Electron", "Chromium", "Firefox", "Eclipse", "Native"])
    }
}
```

In `App/Tests/Services/LaunchPlanPreviewTests.swift`, in `testPreviewMasksSecretsAndCarriesArgsWarningsAndMode` (line 17), after `XCTAssertFalse(preview.warnings.isEmpty)` (line 31) add:

```swift
        XCTAssertEqual(preview.family, .native, "/bin/ls has no Electron, Chromium, Firefox or Eclipse markers")
```

In `App/Tests/Wizard/WizardModelTests.swift`:

1. Add `import CompatProfiles` above `import XCTest` (line 1).
2. After `testBackStopsAtFirstStep` (line 106, the last test) add:

```swift

    func testProfileDefaultsArePrefilledAndShownMaskedInThePreview() throws {
        let profile = AppProfile(name: "Target", status: .verified, family: .native,
                                 args: ["--api-key", "hunter2", "--plain"], env: ["API_TOKEN": "leaked", "TARGET_MODE": "work"],
                                 notes: "Profile notes.")
        let model = WizardModel(prefillTarget: target, profileLookup: { $0 == "com.example.target" ? profile : nil })
        XCTAssertEqual(model.profile, profile)
        XCTAssertEqual(model.arguments, ["--api-key", "hunter2", "--plain"])
        XCTAssertEqual(model.environment, ["API_TOKEN": "leaked", "TARGET_MODE": "work"])
        let config = model.makeConfig()
        XCTAssertEqual(config.arguments, ["--api-key", "hunter2", "--plain"])
        XCTAssertEqual(config.environment, ["API_TOKEN": "leaked", "TARGET_MODE": "work"])

        model.next() // data
        model.next() // review
        let preview = try XCTUnwrap(model.preview)
        XCTAssertEqual(preview.arguments, ["--api-key", "••••••", "--plain"])
        XCTAssertEqual(preview.environmentAdditions["API_TOKEN"], SecretMasking.maskedValue)
        XCTAssertEqual(preview.environmentAdditions["TARGET_MODE"], "work")
    }

    func testAnotherTargetReplacesTheProfileDefaults() throws {
        let plain = try writeFakeTarget(named: "Plain", bundleIdentifier: "com.example.plain", version: "1.0", in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plain.appending(path: "Contents/MacOS/Plain").path)
        let profiles = ["com.example.target": AppProfile(name: "Target", status: .partial, args: ["--one"], env: ["ONE": "1"])]
        let model = WizardModel(prefillTarget: target, profileLookup: { profiles[$0] })
        XCTAssertEqual(model.arguments, ["--one"])

        model.selectTarget(plain)
        XCTAssertNil(model.profile)
        XCTAssertEqual(model.arguments, [])
        XCTAssertEqual(model.environment, [:])
        XCTAssertEqual(model.makeConfig().arguments, [])
        XCTAssertEqual(model.makeConfig().environment, [:])

        model.selectTarget(target)
        XCTAssertEqual(model.profile?.name, "Target")
        XCTAssertEqual(model.environment, ["ONE": "1"])

        model.selectTarget(dir.appending(path: "Missing.app"))
        XCTAssertNil(model.inspected)
        XCTAssertNil(model.profile)
        XCTAssertEqual(model.arguments, [])
        XCTAssertEqual(model.environment, [:])
    }
```

In `App/Tests/App/DiagnosticsModelTests.swift`:

1. Add `import CompatProfiles` above `import XCTest` (line 1).
2. After `testMasksSecretArgumentsAndOldLogLinesAndShowsTheEngineVersion` (line 133, the last test) add:

```swift

    func testShowsTheProfileMatchNotesAndFamilyWithoutSecrets() throws {
        let target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "1.0", in: dir)
        try FileManager.default.removeItem(at: target.appending(path: "Contents/MacOS/Target"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: target.appending(path: "Contents/MacOS/Target"))
        let config = makeConfig(name: "Target Work", targetPath: target.path)
        let bundle = try writeShortcutBundle(named: "Target Work", in: dir, config: config)
        let record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))
        let catalog = ProfileCatalog(document: ProfilesDocument(updated: "2026-10-09", apps: [
            "com.example.target": AppProfile(name: "Target", status: .partial, family: .electron,
                                             args: ["--api-key", "hunter2", "--plain"], env: ["API_TOKEN": "leaked", "PLAIN": "ok"],
                                             notes: "Opens one window per data folder."),
        ]), source: .cached)

        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: dir), profileCatalog: catalog)
        XCTAssertNil(model.planError)
        XCTAssertEqual(model.profileMatch, "com.example.target · Partial · updated 2026-10-09 · cached")
        XCTAssertEqual(model.profileRows, ProfileSummary.rows(for: catalog.profile(forBundleIdentifier: "com.example.target"), detectedFamily: .native))
        let report = model.reportText
        XCTAssertTrue(report.contains("Profile: com.example.target · Partial · updated 2026-10-09 · cached"), report)
        XCTAssertTrue(report.contains("  Notes: Opens one window per data folder."), report)
        XCTAssertTrue(report.contains("  Family note: The profile lists family Electron but App Duplicator detected Native; launch settings follow the detected family."), report)
        for secret in ["hunter2", "leaked"] {
            XCTAssertFalse(report.contains(secret), secret)
        }

        // No catalog loaded, and a catalog without this app.
        let unloaded = DiagnosticsModel.make(record: record, logReader: LogReader(folder: dir))
        XCTAssertEqual(unloaded.profileMatch, "No profiles loaded.")
        XCTAssertEqual(unloaded.profileRows, [])
        let other = DiagnosticsModel.make(record: record, logReader: LogReader(folder: dir),
                                          profileCatalog: ProfileCatalog(document: ProfilesDocument(updated: "2026-10-09"), source: .bundled))
        XCTAssertEqual(other.profileMatch, "No profile for com.example.target (profiles updated 2026-10-09, bundled)")

        // The failed path still reports the match; no family is detected, so there is no family note.
        let goneID = "com.example.unregistered-\(UUID().uuidString)"
        let gone = makeConfig(name: "Gone", targetPath: dir.appending(path: "Missing.app").path, targetBundleIdentifier: goneID)
        let goneRecord = try XCTUnwrap(LibraryScanner.record(forBundleAt: try writeShortcutBundle(named: "Gone", in: dir, config: gone), fileManager: .default))
        let goneCatalog = ProfileCatalog(document: ProfilesDocument(updated: "2026-10-09", apps: [goneID: AppProfile(name: "Gone", status: .verified, family: .electron)]), source: .bundled)
        let failed = DiagnosticsModel.make(record: goneRecord, logReader: LogReader(folder: dir), profileCatalog: goneCatalog)
        XCTAssertNotNil(failed.planError)
        XCTAssertEqual(failed.profileMatch, "\(goneID) · Verified · updated 2026-10-09 · bundled")
        XCTAssertFalse(failed.profileRows.contains { $0.label == "Family note" })
        XCTAssertTrue(failed.reportText.contains("Profile: \(goneID) · Verified"), failed.reportText)
    }
```

- [ ] **Step 2: Run the app tests to verify they fail**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/CompatBadgeTests -only-testing:MacAppDuplicatorTests/ProfileSummaryTests -only-testing:MacAppDuplicatorTests/LaunchPlanPreviewTests -only-testing:MacAppDuplicatorTests/WizardModelTests -only-testing:MacAppDuplicatorTests/DiagnosticsModelTests 2>&1 | grep -E 'error:' | sed -E 's/.*error: //' | sort -u`
Expected: compile errors; nothing runs. In practice the list is `cannot find 'ProfileSummary' in scope`, `extra argument 'profile' in call` and `value of type 'LaunchPlanPreview' has no member 'family'`, with the follow-on errors `cannot infer key path type from context; consider explicitly specifying a root type`, `type 'Any' cannot conform to 'Equatable' [#ProtocolTypeNonConformance]` and `type 'Equatable' has no member 'native'`. The build stops at the first test files that fail, so `extra argument 'profileLookup' in call` and `generic parameter 'T' could not be inferred` (from `WizardModelTests.swift`) can appear next to them, and so can `extra argument 'profileCatalog' in call`, `value of type 'DiagnosticsModel' has no member 'profileMatch'`, `value of type 'DiagnosticsModel' has no member 'profileRows'` and `use [:] to get an empty dictionary literal` (from `DiagnosticsModelTests.swift`) when the compiler reaches that file.

- [ ] **Step 3: Add `ProfileSummary`, the profile-aware badge and `LaunchPlanPreview.family`**

Create `App/Sources/Services/ProfileSummary.swift`:

```swift
import CompatProfiles
import DuplicatorCore

/// Read-only text for a compatibility profile (spec §8), shared by the wizard Review step, the editor's Profile
/// section and Diagnostics. Argument and environment values pass through `SecretMasking`, so a profile's secrets are
/// never shown.
enum ProfileSummary {
    /// One label/value line of a profile summary.
    struct Row: Equatable, Identifiable, Sendable {
        var label: String
        var value: String
        var id: String { label }
    }

    static func statusLabel(_ status: ProfileStatus) -> String {
        switch status {
        case .verified: "Verified"
        case .partial: "Partial"
        case .unsupported: "Unsupported"
        }
    }

    static func familyName(_ family: AppFamily) -> String {
        switch family {
        case .todesktop: "ToDesktop"
        case .electron: "Electron"
        case .chromium: "Chromium"
        case .firefox: "Firefox"
        case .eclipse: "Eclipse"
        case .native: "Native"
        }
    }

    /// `Name`, `Status`, `Family` (when the profile names one), `Arguments` and `Environment` (masked, `None` when
    /// empty), `Notes` (when the profile has any) and `Family note` (see `familyNote`). Empty without a profile.
    static func rows(for profile: AppProfile?, detectedFamily: AppFamily?) -> [Row] {
        guard let profile else { return [] }
        var rows = [Row(label: "Name", value: profile.name), Row(label: "Status", value: statusLabel(profile.status))]
        if let family = profile.family {
            rows.append(Row(label: "Family", value: familyName(family)))
        }
        let arguments = SecretMasking.maskArguments(profile.args)
        rows.append(Row(label: "Arguments", value: arguments.isEmpty ? "None" : arguments.joined(separator: " ")))
        let environment = SecretMasking.mask(profile.env)
        rows.append(Row(label: "Environment",
                        value: environment.isEmpty ? "None" : environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }.joined(separator: " ")))
        if let notes = profile.notes, !notes.isEmpty {
            rows.append(Row(label: "Notes", value: notes))
        }
        if let note = familyNote(profile: profile, detected: detectedFamily) {
            rows.append(Row(label: "Family note", value: note))
        }
        return rows
    }

    /// The Diagnostics profile match: `<bundle id> · <status> · updated <date> · <bundled|cached>` when the catalog has
    /// a profile for the bundle id, `No profile for <bundle id> (profiles updated <date>, <source>)` when it does not,
    /// and `No profiles loaded.` when no catalog is loaded.
    static func matchLine(bundleIdentifier: String, catalog: ProfileCatalog) -> String {
        guard !catalog.updated.isEmpty else { return "No profiles loaded." }
        guard let profile = catalog.profile(forBundleIdentifier: bundleIdentifier) else {
            return "No profile for \(bundleIdentifier) (profiles updated \(catalog.updated), \(catalog.source.rawValue))"
        }
        return "\(bundleIdentifier) · \(statusLabel(profile.status)) · updated \(catalog.updated) · \(catalog.source.rawValue)"
    }

    /// Launch settings always follow the family AppInspector detects; a profile's `family` is informational. Returns a
    /// note when both are known and differ, nil otherwise.
    static func familyNote(profile: AppProfile?, detected: AppFamily?) -> String? {
        guard let listed = profile?.family, let detected, listed != detected else { return nil }
        return "The profile lists family \(familyName(listed)) but App Duplicator detected \(familyName(detected)); launch settings follow the detected family."
    }
}
```

Replace `App/Sources/Services/CompatBadge.swift` with:

```swift
import CompatProfiles
import DuplicatorCore

/// Compatibility badge (spec §7): `Verified` (profile tested), `Auto` (family detected, untested), `HOME only`,
/// `Unsupported` (the profile marks the app single-instance) and `Unknown`.
enum CompatBadge: String, Sendable {
    case verified = "Verified"
    case auto = "Auto"
    case homeOnly = "HOME only"
    case unsupported = "Unsupported"
    case unknown = "Unknown"

    var label: String { rawValue }

    /// Evaluated in this order: no inspected app → `unknown`; a profile marked `unsupported` → `unsupported`; a
    /// `verified` profile → `verified`; a sandboxed native app → `unknown` (its container ignores a HOME override,
    /// final review M9); another native app → `homeOnly`; every other family → `auto`. A `partial` profile changes nothing.
    static func badge(for app: InspectedApp?, profile: AppProfile? = nil) -> CompatBadge {
        guard let app else { return .unknown }
        switch profile?.status {
        case .unsupported: return .unsupported
        case .verified: return .verified
        case .partial, nil: break
        }
        if app.family == .native {
            return app.isSandboxed ? .unknown : .homeOnly
        }
        return .auto
    }
}
```

The only callers are `TargetSection` (`EditorSections.swift:57`) and the wizard's Target and Review steps (`WizardSteps.swift:64` and `:224`); the sidebar shows no badge. They pass the profile in Steps 7 and 8; until then the defaulted `profile` keeps them compiling.

In `App/Sources/Services/LaunchPlanPreview.swift`:

1. After `var launchMode: LaunchMode` (line 14) add:

```swift
    /// The family AppInspector detected for the target, the one the planner used.
    var family: AppFamily
```

2. In `make(config:bundleURL:)` line 26 replace

```swift
            launchMode: plan.launchMode
```

with

```swift
            launchMode: plan.launchMode,
            family: app.family
```

- [ ] **Step 4: Carry the profile and its defaults in `WizardModel`**

In `App/Sources/Views/Wizard/WizardModel.swift`:

1. Add `import CompatProfiles` above `import DuplicatorCore` (line 1).
2. After `var launchMode: LaunchMode = .dockShortcut` (line 23) add:

```swift
    /// The compatibility profile for the selected target, if the profiles in use have one (spec §8).
    private(set) var profile: AppProfile?
    /// The profile's `args` and `env`, copied into the new shortcut by `makeConfig()` as editable defaults; replaced
    /// whenever the target changes.
    private(set) var arguments: [String] = []
    private(set) var environment: [String: String] = [:]
```

3. After `private var launchModeWasForced = false` (line 35) add:

```swift

    /// Looks up the profile for a target bundle identifier; the sheet passes `AppState.profile(forBundleIdentifier:)`.
    private let profileLookup: @MainActor (String) -> AppProfile?
```

4. In lines 37-42 replace

```swift
    init(prefillTarget: URL? = nil) {
        if let prefillTarget {
            selectTarget(prefillTarget)
            if inspected != nil { step = .identity }
        }
    }
```

with

```swift
    init(prefillTarget: URL? = nil, profileLookup: @escaping @MainActor (String) -> AppProfile? = { _ in nil }) {
        self.profileLookup = profileLookup
        if let prefillTarget {
            selectTarget(prefillTarget)
            if inspected != nil { step = .identity }
        }
    }
```

5. In `selectTarget(_:)`, after `inspectError = nil` (line 67) add:

```swift
            profile = profileLookup(app.bundleIdentifier)
            arguments = profile?.args ?? []
            environment = profile?.env ?? [:]
```

6. After `inspectError = error.localizedDescription` (line 81) add:

```swift
            profile = nil
            arguments = []
            environment = [:]
```

7. In `makeConfig()`, after `dataPath: dataPath,` (line 108) add:

```swift
            environment: environment,
            arguments: arguments,
```

The profile's `args` and `env` are copied once, when the target is picked. The user edits them afterwards in the shortcut's Advanced section (`ArgumentsEditor`, `EnvironmentTableView`), and Check Profile Updates never touches an existing shortcut. `DataSeparationPlanner` is unchanged: the copied values sit in the user's slot of the spec §4.4 order (`config.arguments` after the planner arguments, `config.environment` after the planner environment).

- [ ] **Step 5: Add the profile match to `DiagnosticsModel`**

In `App/Sources/Views/DiagnosticsView.swift` (the `DiagnosticsModel` struct):

1. Add `import CompatProfiles` above `import DuplicatorCore` (line 1).
2. After `let engineVersion: Int` (line 8) add:

```swift
    /// The profile match for the target bundle id (`ProfileSummary.matchLine`).
    let profileMatch: String
    /// The matched profile's rows (`ProfileSummary.rows`); empty without a match.
    let profileRows: [ProfileSummary.Row]
```

3. In line 22 replace `static func make(record: ShortcutRecord, logReader: LogReader = LogReader()) -> DiagnosticsModel {` with `static func make(record: ShortcutRecord, logReader: LogReader = LogReader(), profileCatalog: ProfileCatalog = .empty) -> DiagnosticsModel {`.
4. After `let logLines = logReader.tail(name: record.name).map(SecretMasking.maskLogLine)` (line 25) add:

```swift
        let profile = profileCatalog.profile(forBundleIdentifier: record.config.targetBundleIdentifier)
        let profileMatch = ProfileSummary.matchLine(bundleIdentifier: record.config.targetBundleIdentifier, catalog: profileCatalog)
```

5. In lines 31 and 53 replace `logLines: logLines, error: error)` with `logLines: logLines, profileMatch: profileMatch, profile: profile, error: error)`.
6. In `make`, after `engineVersion: record.engineVersion,` (line 41) add:

```swift
                profileMatch: profileMatch,
                profileRows: ProfileSummary.rows(for: profile, detectedFamily: preview.family),
```

7. In line 57 replace

```swift
    private static func failed(record: ShortcutRecord, resolvedTargetPath: String?, logLines: [String], error: Error) -> DiagnosticsModel {
```

with

```swift
    private static func failed(
        record: ShortcutRecord, resolvedTargetPath: String?, logLines: [String], profileMatch: String, profile: AppProfile?, error: Error
    ) -> DiagnosticsModel {
```

8. In `failed`, after `engineVersion: record.engineVersion,` (line 61) add:

```swift
            profileMatch: profileMatch,
            profileRows: ProfileSummary.rows(for: profile, detectedFamily: nil),
```

9. In `reportText`, after `lines.append("Engine version: \(engineVersion) (current \(ShortcutConfig.currentEngineVersion))")` (line 81) add:

```swift
        lines.append("Profile: \(profileMatch)")
        lines.append(contentsOf: profileRows.map { "  \($0.label): \($0.value)" })
```

- [ ] **Step 6: Run the app tests to verify they pass**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/CompatBadgeTests -only-testing:MacAppDuplicatorTests/ProfileSummaryTests -only-testing:MacAppDuplicatorTests/LaunchPlanPreviewTests -only-testing:MacAppDuplicatorTests/WizardModelTests -only-testing:MacAppDuplicatorTests/DiagnosticsModelTests 2>&1 | grep -cE "Test Case '.*' passed"`
Expected: `29` (CompatBadge 4 + ProfileSummary 4 + LaunchPlanPreview 3 + WizardModel 11 + DiagnosticsModel 7). The views still compile because every new parameter has a default; Steps 7 and 8 pass the profile to them.

- [ ] **Step 7: Show the profile in the wizard**

Create `App/Sources/Views/ProfileSummaryView.swift`:

```swift
import SwiftUI

/// Read-only label/value rows for a compatibility profile (`ProfileSummary.rows`), shared by the wizard Review step,
/// the editor's Profile section and Diagnostics.
struct ProfileSummaryView: View {
    let rows: [ProfileSummary.Row]

    var body: some View {
        ForEach(rows) { row in
            LabeledContent(row.label) {
                Text(row.value).textSelection(.enabled)
            }
        }
    }
}
```

In `App/Sources/Views/Wizard/NewShortcutWizard.swift`:

1. After `@State private var model: WizardModel` (line 6) add:

```swift
    /// Set once `onAppear` has built the model, so a second `onAppear` in the same presentation keeps the user's progress.
    @State private var isSetUp = false
```

2. In lines 55-60 replace

```swift
        .onAppear {
            if let prefill = appState.wizardPrefillTarget {
                model = WizardModel(prefillTarget: prefill)
                appState.wizardPrefillTarget = nil
            }
        }
```

with

```swift
        .onAppear {
            // The environment is available from here on: build the model once per presentation with the profile
            // lookup and the dropped app, if any.
            guard !isSetUp else { return }
            isSetUp = true
            model = WizardModel(prefillTarget: appState.wizardPrefillTarget,
                                profileLookup: { [appState] in appState.profile(forBundleIdentifier: $0) })
            appState.wizardPrefillTarget = nil
        }
```

`init()` cannot read the environment, so the model it builds has no profile lookup; `onAppear` replaces it before the first frame, with or without a dropped app. `onAppear` can run more than once while the sheet is up, and the `isSetUp` guard keeps a later call from resetting the user's progress.

In `App/Sources/Views/Wizard/WizardSteps.swift`:

1. Add `import CompatProfiles` above `import DuplicatorCore` (line 1).
2. In line 64 replace `CompatBadge.badge(for: app).label` with `CompatBadge.badge(for: app, profile: model.profile).label`.
3. After `@State private var showPlan = false` (line 216) add:

```swift
    @State private var showProfile = false
```

4. In `ReviewStep.body` lines 218-247 replace

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review").font(.title3)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Name", model.name)
                row("Target", model.targetURL?.path ?? "")
                row("Compatibility", CompatBadge.badge(for: model.inspected).label)
                row("Launch mode", model.requiresSystemLaunch || model.launchMode == .systemLaunch ? "System Launch" : "Dock Shortcut")
                row("Data", dataDescription)
                row("Icon", iconDescription)
            }
            if let error = model.previewError {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption)
            }
            if let preview = model.preview {
                DisclosureGroup("Launch plan", isExpanded: $showPlan) {
                    VStack(alignment: .leading, spacing: 6) {
                        planRow("Executable", preview.executablePath)
                        planRow("Arguments", preview.arguments.joined(separator: "\n"))
                        planRow("Environment additions", preview.environmentAdditions.keys.sorted().map { "\($0)=\(preview.environmentAdditions[$0] ?? "")" }.joined(separator: "\n"))
                        if !preview.warnings.isEmpty {
                            Text("Warnings").font(.caption).foregroundStyle(.secondary)
                            ForEach(preview.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption) }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }
```

with

```swift
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review").font(.title3)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("Name", model.name)
                    row("Target", model.targetURL?.path ?? "")
                    row("Compatibility", CompatBadge.badge(for: model.inspected, profile: model.profile).label)
                    row("Profile", model.profile.map { "\($0.name) · \(ProfileSummary.statusLabel($0.status))" } ?? "None")
                    row("Launch mode", model.requiresSystemLaunch || model.launchMode == .systemLaunch ? "System Launch" : "Dock Shortcut")
                    row("Data", dataDescription)
                    row("Icon", iconDescription)
                }
                if let error = model.previewError {
                    Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption)
                }
                if let profile = model.profile {
                    DisclosureGroup("Profile defaults", isExpanded: $showProfile) {
                        VStack(alignment: .leading, spacing: 6) {
                            ProfileSummaryView(rows: ProfileSummary.rows(for: profile, detectedFamily: model.inspected?.family))
                            Text("The profile's arguments and environment are copied into the new shortcut; change them in its Advanced section after it is created.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }
                if let preview = model.preview {
                    DisclosureGroup("Launch plan", isExpanded: $showPlan) {
                        VStack(alignment: .leading, spacing: 6) {
                            planRow("Executable", preview.executablePath)
                            planRow("Arguments", preview.arguments.joined(separator: "\n"))
                            planRow("Environment additions", preview.environmentAdditions.keys.sorted().map { "\($0)=\(preview.environmentAdditions[$0] ?? "")" }.joined(separator: "\n"))
                            if !preview.warnings.isEmpty {
                                Text("Warnings").font(.caption).foregroundStyle(.secondary)
                                ForEach(preview.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption) }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
```

The Review step now scrolls: with both disclosures open it no longer fits the 560 × 520 sheet.

- [ ] **Step 8: Add the editor's Profile section and the Diagnostics profile rows**

In `App/Sources/Views/EditorSections.swift`:

1. Add `import CompatProfiles` above `import DuplicatorCore` (line 1).
2. In `TargetSection`, after `let inspected: InspectedApp?` (line 45) add:

```swift
    /// The compatibility profile for `draft.targetBundleIdentifier`, if any; it can turn the badge `Verified` or `Unsupported`.
    let profile: AppProfile?
```

3. In line 57 replace `CompatBadge.badge(for: inspected).label` with `CompatBadge.badge(for: inspected, profile: profile).label`.
4. After the end of `TargetSection` (line 79), before `struct LaunchSection: View {` (line 81), add:

```swift

/// Read-only view of the compatibility profile for the draft's target (spec §8); it never edits the shortcut.
struct ProfileSection: View {
    let bundleIdentifier: String
    let profile: AppProfile?
    let detectedFamily: AppFamily?

    var body: some View {
        Section {
            if let profile {
                ProfileSummaryView(rows: ProfileSummary.rows(for: profile, detectedFamily: detectedFamily))
            } else {
                Text(verbatim: "No compatibility profile for \(bundleIdentifier).").foregroundStyle(.secondary)
            }
        } header: {
            Text("Profile")
        } footer: {
            Text("A profile's arguments and environment are copied into a shortcut only when it is created; Check Profile Updates never changes an existing shortcut.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
```

In `App/Sources/Views/ShortcutEditorView.swift`:

1. Add `import CompatProfiles` above `import DuplicatorCore` (line 1).
2. After `private var hasChanges: Bool { draft != record.config }` (line 23) add:

```swift

    /// The profile for the draft's target, read from the profiles in use (never copied into the draft here).
    private var profile: AppProfile? { appState.profile(forBundleIdentifier: draft.targetBundleIdentifier) }
```

3. In line 28 replace

```swift
            TargetSection(draft: $draft, inspected: inspected)
```

with

```swift
            TargetSection(draft: $draft, inspected: inspected, profile: profile)
            ProfileSection(bundleIdentifier: draft.targetBundleIdentifier, profile: profile, detectedFamily: inspected?.family)
```

4. In line 86 replace `DiagnosticsView(record: record)` with `DiagnosticsView(record: record, profileCatalog: appState.profiles.catalog)`.

In `App/Sources/Views/DiagnosticsView.swift` (the `DiagnosticsView` struct; line numbers are the file's before Step 5, which added 15 lines above it):

1. After `let record: ShortcutRecord` (line 111) add:

```swift
    /// The profiles in use when the sheet opened (`AppState.profiles.catalog`).
    let profileCatalog: ProfileCatalog
```

2. After `row("Engine", "\(model.engineVersion) (current \(ShortcutConfig.currentEngineVersion))")` (line 123) add:

```swift
                            row("Profile", model.profileMatch)
```

3. After the end of `section("Shortcut")` (line 134), before `if model.planError == nil {` (line 135), add:

```swift
                        if !model.profileRows.isEmpty {
                            section("Profile") { ProfileSummaryView(rows: model.profileRows) }
                        }
```

4. In lines 165-168 replace

```swift
        .task {
            let record = record
            model = await Task.detached { DiagnosticsModel.make(record: record) }.value
        }
```

with

```swift
        .task {
            let record = record
            let profileCatalog = profileCatalog
            model = await Task.detached { DiagnosticsModel.make(record: record, profileCatalog: profileCatalog) }.value
        }
```

The `row` helper truncates at two lines, so the notes and the family note get their own section; Copy Report carries the same lines.

- [ ] **Step 9: Update the planner's doc comment**

In `Packages/DuplicatorCore/Sources/DuplicatorCore/DataSeparationPlanner.swift` lines 19-22 replace

```swift
    /// Phase 3 (Compatibility profiles) inserts a `profile` parameter here, matching spec §3.1
    /// `(InspectedApp, Profile?, ShortcutConfig) -> LaunchPlan`: profile args go between the planner args and
    /// `config.arguments`, profile env between the planner env and `config.environment`, and a profile's
    /// data-mode override replaces the family default in `.auto`.
```

with

```swift
    /// Compatibility profiles (Phase 3) do not reach the planner: a profile's `args` and `env` are copied into
    /// `config.arguments` and `config.environment` when the shortcut is created (editable defaults), so they already sit
    /// in the user's slot of the order above. Spec §3.1's `(InspectedApp, Profile?, ShortcutConfig) -> LaunchPlan` is
    /// realised at creation time; a profile's family is shown but never replaces the detected one, and the spec §8
    /// schema has no data-mode override.
```

Run: `cd "$REPO" && swift build 2>&1 | grep -E 'error:|warning:|Build complete'`
Expected: `Build complete!` and no `error:` or `warning:` lines. README line 93 still names this comment as the Phase 3 insertion point; Task 10 rewrites that line.

- [ ] **Step 10: Run the full app suite**

Run: `cd "$REPO" && Tools/test-app.sh 2>&1 | grep -E "Test Case '.*' passed|: warning:|\*\* TEST" | sed -E "s/^Test Case .* passed .*/passed/" | sort | uniq -c`
Expected: exactly two lines, `1 ** TEST SUCCEEDED **` and `130 passed` (121 + 9; the counts are left-padded). Any `: warning:` line names a file to fix before committing.

- [ ] **Step 11: Commit**

```bash
cd "$REPO" && git add App/Sources/Services/CompatBadge.swift App/Sources/Services/ProfileSummary.swift App/Sources/Services/LaunchPlanPreview.swift App/Sources/Views/ProfileSummaryView.swift App/Sources/Views/EditorSections.swift App/Sources/Views/ShortcutEditorView.swift App/Sources/Views/DiagnosticsView.swift App/Sources/Views/Wizard/WizardModel.swift App/Sources/Views/Wizard/NewShortcutWizard.swift App/Sources/Views/Wizard/WizardSteps.swift Packages/DuplicatorCore/Sources/DuplicatorCore/DataSeparationPlanner.swift App/Tests/Services/CompatBadgeTests.swift App/Tests/Services/ProfileSummaryTests.swift App/Tests/Services/LaunchPlanPreviewTests.swift App/Tests/Wizard/WizardModelTests.swift App/Tests/App/DiagnosticsModelTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -q -F - <<'MSG'
feat: profile-driven compat badges, creation defaults and Diagnostics match

CompatBadge.badge(for:profile:) checks the profile first: a profile marked
unsupported shows Unsupported and a verified one Verified; otherwise the
detected family decides, and a sandboxed native app now shows Unknown
instead of HOME only, since its container ignores a HOME override (final
review M9).

The wizard looks up the profile for the chosen target and copies its args
and env into the new shortcut as editable defaults; the Review step shows
the profile, masked, next to the launch plan. The editor gets a read-only
Profile section, and Diagnostics reports the profile match (bundle id,
status, updated date, bundled or cached) with the profile's notes. A
profile's family is informational: launch settings follow the detected
family, and DataSeparationPlanner is unchanged apart from its doc comment.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 6: Rebuild All off the main actor with per-shortcut results

**Files:**
- Create: `App/Sources/Model/RebuildResult.swift`
- Modify: `App/Sources/Services/ShortcutBuilder.swift:7,29` (`Sendable`; `fileManager` becomes computed)
- Modify: `App/Sources/App/AppState.swift:58,136-150` (`rebuildProgress`, the new `rebuildAll()`)
- Modify: `App/Sources/Views/RebuildAllSheet.swift:1-31` (whole file replaced; progress and results)
- Modify: `App/Sources/Views/ContentView.swift:42` (the sheet's closure returns the results)
- Test: `App/Tests/App/AppStateTests.swift:171-172,190` (modify)
- Test: `App/Tests/Model/RebuildSummaryTests.swift`

**Interfaces:**
- Consumes (Phase 2): `ShortcutLibrary.recordsNeedingRebuild` (`records.filter(\.needsRebuild)`, in the name order `LibraryScanner` sorts by) and `ShortcutLibrary.rescan() async`, `ShortcutRecord` (`bundleURL`, `name`, `config`; `Sendable`), `ShortcutBuilder.regenerate(record:config:) throws -> URL` and its `BuilderError.targetMissing` text "The target app was not found at <path>.", `AppState.builder` and `AppState.pendingError`, the `@Environment(AppState.self)` that sheets inherit from `ContentView`; test helpers `makeAppTemporaryDirectory()`, `writeFakeTarget(named:bundleIdentifier:version:in:)`, `writeShortcutBundle(named:in:config:engineVersion:)`, `makeConfig(name:targetPath:)`, `makeTestDefaults()`.
- Produces (used by Tasks 7, 8 and 10):
  - `ShortcutBuilder: Sendable`; `fileManager` is a computed property that returns `FileManager.default` and can no longer be set.
  - `struct RebuildResult: Identifiable, Equatable, Sendable` (`App/Sources/Model/RebuildResult.swift`): `id: URL` (the shortcut's bundle URL), `name: String`, `outcome: Outcome`; `enum Outcome: Equatable, Sendable { case rebuilt; case failed(String) }`.
  - `struct RebuildProgress: Equatable, Sendable` (`done: Int`, `total: Int`) and `enum RebuildSummary` with `static func text(for results: [RebuildResult]) -> String`.
  - `AppState.rebuildProgress: RebuildProgress?` (non-nil only while Rebuild All runs) and `AppState.rebuildAll() async -> [RebuildResult]`: one result per stale record in `recordsNeedingRebuild` order; it never sets `pendingError`.
  - `RebuildAllSheet(count: Int, onRebuild: @escaping () async -> [RebuildResult])`, which reads `AppState` from the environment for the progress.

- [ ] **Step 1: Write the failing app tests**

In `App/Tests/App/AppStateTests.swift`:

1. In lines 171-172 replace

```swift
        let count = await state.rebuildAll()
        XCTAssertEqual(count, 1)
```

with

```swift
        let results = await state.rebuildAll()
        XCTAssertEqual(results.map(\.name), ["Old One"])
        XCTAssertEqual(results.map(\.outcome), [.rebuilt])
```

2. After `testCheckProfileUpdatesUsesTheSettingsURLAndReportsTheResult` (line 190, the last test) add:

```swift

    func testRebuildAllContinuesPastAFailureAndReportsEveryShortcut() async throws {
        // "A Broken" sorts first and its target is gone; Phase 2's loop stopped there and never reached "B Stale".
        var broken = config(name: "A Broken")
        broken.targetPath = dir.appending(path: "Missing.app").path
        broken.engineVersion = 0
        try writeShortcutBundle(named: "A Broken", in: out, config: broken, engineVersion: 0)
        var stale = config(name: "B Stale")
        stale.engineVersion = 0
        try writeShortcutBundle(named: "B Stale", in: out, config: stale, engineVersion: 0)
        await library.rescan()
        XCTAssertEqual(library.recordsNeedingRebuild.map(\.name), ["A Broken", "B Stale"])

        let results = await state.rebuildAll()

        XCTAssertEqual(results.map(\.name), ["A Broken", "B Stale"])
        XCTAssertEqual(results.map(\.id.lastPathComponent), ["A Broken.app", "B Stale.app"])
        XCTAssertEqual(results.last?.outcome, .rebuilt)
        guard case .failed(let message) = results.first?.outcome else { return XCTFail("the missing target fails") }
        XCTAssertTrue(message.contains("Missing.app"), message)
        XCTAssertNil(state.pendingError, "Rebuild All reports failures in its results, not in the error alert")
        XCTAssertNil(state.rebuildProgress, "progress is cleared when Rebuild All ends")
        XCTAssertEqual(library.recordsNeedingRebuild.map(\.name), ["A Broken"])
    }
```

Create `App/Tests/Model/RebuildSummaryTests.swift`:

```swift
import XCTest
@testable import MacAppDuplicator

final class RebuildSummaryTests: XCTestCase {
    private func result(_ name: String, _ outcome: RebuildResult.Outcome) -> RebuildResult {
        RebuildResult(id: URL(fileURLWithPath: "/Shortcuts/\(name).app"), name: name, outcome: outcome)
    }

    func testCountsRebuiltShortcutsWithTheRightNoun() {
        XCTAssertEqual(RebuildSummary.text(for: [result("One", .rebuilt)]), "Rebuilt 1 of 1 shortcut.")
        XCTAssertEqual(RebuildSummary.text(for: [result("One", .rebuilt), result("Two", .rebuilt)]), "Rebuilt 2 of 2 shortcuts.")
        XCTAssertEqual(RebuildSummary.text(for: []), "No shortcuts needed a rebuild.")
    }

    func testReportsFailuresNextToTheRebuiltCount() {
        let results = [
            result("One", .rebuilt),
            result("Two", .failed("The target app was not found at /Applications/Two.app.")),
            result("Three", .failed("codesign failed")),
        ]
        XCTAssertEqual(RebuildSummary.text(for: results), "Rebuilt 1 of 3 shortcuts; 2 failed.")
        XCTAssertEqual(RebuildSummary.text(for: [result("One", .failed("codesign failed"))]), "Rebuilt 0 of 1 shortcut; 1 failed.")
    }
}
```

- [ ] **Step 2: Run the app tests to verify they fail**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/AppStateTests -only-testing:MacAppDuplicatorTests/RebuildSummaryTests 2>&1 | grep -E 'error:' | sed -E 's/.*error: //' | sort -u`
Expected: compile errors; nothing runs. In practice the list is `cannot find 'RebuildResult' in scope`, `cannot find type 'RebuildResult' in scope` and `cannot find 'RebuildSummary' in scope` (from `RebuildSummaryTests.swift`). The build stops at the first test files that fail, so `value of type 'Int' has no member 'map'`, `value of type 'Int' has no member 'last'` and `value of type 'AppState' has no member 'rebuildProgress'` (from `AppStateTests.swift`) can appear next to them when the compiler reaches that file, with follow-on errors such as `cannot infer key path type from context; consider explicitly specifying a root type`, `type 'Equatable' has no member 'rebuilt'` and `failed to produce diagnostic for expression; please submit a bug report (https://swift.org/contributing/#reporting-bugs)`.

- [ ] **Step 3: Add the result types and make `ShortcutBuilder` Sendable**

Create `App/Sources/Model/RebuildResult.swift`:

```swift
import Foundation

/// One shortcut's line in the Rebuild All results (final review M16).
struct RebuildResult: Identifiable, Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case rebuilt
        /// The error's description, shown under the shortcut's name.
        case failed(String)
    }

    /// The shortcut's bundle URL when Rebuild All started.
    let id: URL
    let name: String
    let outcome: Outcome
}

/// How far Rebuild All has got: `done` of `total` shortcuts finished, failed ones included.
struct RebuildProgress: Equatable, Sendable {
    var done: Int
    var total: Int
}

/// The headline of the Rebuild All results.
enum RebuildSummary {
    /// "Rebuilt 2 of 3 shortcuts; 1 failed.", "Rebuilt 1 of 1 shortcut." or "No shortcuts needed a rebuild."
    static func text(for results: [RebuildResult]) -> String {
        guard !results.isEmpty else { return "No shortcuts needed a rebuild." }
        let failed = results.filter { $0.outcome != .rebuilt }.count
        let noun = results.count == 1 ? "shortcut" : "shortcuts"
        let rebuilt = "Rebuilt \(results.count - failed) of \(results.count) \(noun)"
        return failed == 0 ? "\(rebuilt)." : "\(rebuilt); \(failed) failed."
    }
}
```

In `App/Sources/Services/ShortcutBuilder.swift`:

1. In line 7 replace `struct ShortcutBuilder {` with `struct ShortcutBuilder: Sendable {`.
2. In line 29 replace

```swift
    var fileManager: FileManager = .default
```

with

```swift
    // FileManager is not Sendable, so it is not a stored property of this Sendable struct (Rebuild All runs the
    // builder in a detached task). Nothing ever set it; every use reads the shared instance.
    var fileManager: FileManager { .default }
```

Every `ShortcutBuilder` call site already builds it with `init(launcherBinary:signingIdentity:)` and never assigns `fileManager`, so nothing else changes. The stored properties (`URL`, `String?`) are Sendable, and `regenerate` only reaches nonisolated code (`AppInspector`, `IconResolver`, `BundleWriter`, `Signer`), so it can run in a detached task.

- [ ] **Step 4: Run Rebuild All off the main actor in `AppState`**

In `App/Sources/App/AppState.swift`:

1. After `var profileUpdateMessage: String?` (line 58) add:

```swift
    /// Rebuild All progress while it runs; nil otherwise.
    var rebuildProgress: RebuildProgress?
```

2. In lines 136-150 replace

```swift
    /// Rewrites every record whose engine version is stale. Returns how many were rebuilt; stops at the first error.
    func rebuildAll() async -> Int {
        var count = 0
        for record in library.recordsNeedingRebuild {
            do {
                _ = try builder.regenerate(record: record, config: record.config)
                count += 1
            } catch {
                present(error, context: "Could not rebuild \(record.name)")
                break
            }
        }
        await library.rescan()
        return count
    }
```

with

```swift
    /// Rebuild All (final review M16): rewrites every record whose engine version is stale, one at a time in a
    /// detached task so the main actor stays free, and carries on past a failure. `rebuildProgress` counts the
    /// finished records while it runs. Returns one result per record, in `recordsNeedingRebuild` order; failures are
    /// reported there, never through `pendingError`.
    func rebuildAll() async -> [RebuildResult] {
        let records = library.recordsNeedingRebuild
        let builder = self.builder
        var results: [RebuildResult] = []
        rebuildProgress = RebuildProgress(done: 0, total: records.count)
        for record in records {
            let outcome = await Task.detached(priority: .userInitiated) { () -> RebuildResult.Outcome in
                do {
                    _ = try builder.regenerate(record: record, config: record.config)
                    return .rebuilt
                } catch {
                    return .failed(error.localizedDescription)
                }
            }.value
            results.append(RebuildResult(id: record.bundleURL, name: record.name, outcome: outcome))
            rebuildProgress = RebuildProgress(done: results.count, total: records.count)
        }
        await library.rescan()
        rebuildProgress = nil
        return results
    }
```

The records are rebuilt one after another, not in parallel: each rebuild runs `codesign`, and a stale shortcut's rebuild can rename its bundle, so ordering keeps the results and the rescan predictable. `rebuildProgress` is cleared after the rescan, so the sheet never shows an empty progress bar between the last rebuild and the results. `ContentView` still compiles: its closure (`_ = await appState.rebuildAll()`) discards the new return value until Step 6.

- [ ] **Step 5: Run the app tests to verify they pass**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/AppStateTests -only-testing:MacAppDuplicatorTests/RebuildSummaryTests 2>&1 | grep -cE "Test Case '.*' passed"`
Expected: `13` (AppState 11 + RebuildSummary 2).

- [ ] **Step 6: Show progress and the results in the sheet**

Replace `App/Sources/Views/RebuildAllSheet.swift` with:

```swift
import SwiftUI

/// Rebuild All (spec §7 toolbar): asks first, rebuilds every stale shortcut with progress, then lists each result
/// (final review M16). The sheet stays open after the rebuild so failures can be read.
struct RebuildAllSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let count: Int
    let onRebuild: () async -> [RebuildResult]
    @State private var isWorking = false
    @State private var results: [RebuildResult]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let results {
                Text(RebuildSummary.text(for: results)).font(.headline)
                if results.contains(where: { $0.outcome != .rebuilt }) {
                    Text("Shortcuts that failed keep their Needs rebuild badge. Fix the cause, then run Rebuild All again.")
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(results) { result in
                            RebuildResultRow(result: result)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text(count == 1 ? "Rebuild 1 shortcut?" : "Rebuild \(count) shortcuts?").font(.headline)
                Text("Each shortcut is rewritten with the current launcher and signed again. Settings are kept.")
                if let progress = appState.rebuildProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                        Text("\(progress.done) of \(progress.total) done")
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(isWorking)
                    Button("Rebuild") {
                        isWorking = true
                        Task {
                            results = await onRebuild()
                            isWorking = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(isWorking)
    }
}

/// One shortcut's line in the results: a check mark, or a warning with the error underneath.
private struct RebuildResultRow: View {
    let result: RebuildResult

    var body: some View {
        switch result.outcome {
        case .rebuilt:
            Label(result.name, systemImage: "checkmark.circle")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                Label(result.name, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}
```

In `App/Sources/Views/ContentView.swift` line 42 replace `_ = await appState.rebuildAll()` with `await appState.rebuildAll()`.

The confirmation copy and the Cancel and Rebuild buttons are unchanged. While the rebuild runs the sheet cannot be dismissed (Cancel is disabled and `interactiveDismissDisabled` blocks Escape); afterwards it shows `RebuildSummary.text(for:)`, a hint when anything failed, one row per shortcut with the error text selectable, and `Done`. The Phase 2 acceptance step (`docs/acceptance/phase2-library-app.md` line 67) still holds: the badge clears behind the sheet; Task 10's Phase 3 checklist covers the results list.

- [ ] **Step 7: Run the full app suite**

Run: `cd "$REPO" && Tools/test-app.sh 2>&1 | grep -E "Test Case '.*' passed|: warning:|\*\* TEST" | sed -E "s/^Test Case .* passed .*/passed/" | sort | uniq -c`
Expected: exactly two lines, `1 ** TEST SUCCEEDED **` and `133 passed` (130 + 3; the counts are left-padded). Any `: warning:` line names a file to fix before committing.

- [ ] **Step 8: Commit**

```bash
cd "$REPO" && git add App/Sources/Model/RebuildResult.swift App/Sources/Services/ShortcutBuilder.swift App/Sources/App/AppState.swift App/Sources/Views/RebuildAllSheet.swift App/Sources/Views/ContentView.swift App/Tests/App/AppStateTests.swift App/Tests/Model/RebuildSummaryTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -q -F - <<'MSG'
feat(app): run Rebuild All off the main actor and report every shortcut

Rebuild All rewrote each stale shortcut on the main actor and stopped at
the first error, which it showed in the generic error alert. It now runs
each regenerate in a detached task, one shortcut at a time, so the window
stays responsive; it carries on past failures and returns one
RebuildResult per shortcut. The sheet shows progress while it runs, then
a summary line and each shortcut's result with the error text, and stays
open until Done (final review M16).

ShortcutBuilder is Sendable for this. Its fileManager is now a computed
property that returns FileManager.default, since FileManager is not
Sendable and nothing ever replaced it.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 7: Data-path guard widening, export trash-and-sweep and delete confirmation

**Files:**
- Create: `App/Sources/Services/TargetResolver+ResolvedPath.swift`
- Create: `App/Sources/Services/DeleteConfirmation.swift`
- Modify: `App/Sources/Services/CanonicalPath.swift:16,34` (one shared fold; `foldedComponent(at:)`)
- Modify: `App/Sources/Services/DataPathGuard.swift:12,18,22,34-39,53,66-67` (two new errors; the Phase 3 checks)
- Modify: `App/Sources/Services/ShortcutBuilder.swift:22,70-96,98-111,120,128` (`ExportOutcome`, `exportCopy`, sweep and restore; `delete` gains `shortcutBundles`)
- Modify: `App/Sources/App/AppState.swift:174-182,190-193,203-210,222` (`exportCopy`, `exportWarning`; every scanned bundle and the target's bundle id reach the guard)
- Modify: `App/Sources/Views/DeleteShortcutSheet.swift:1-46` (whole file replaced; the second confirmation)
- Modify: `App/Sources/Views/ExportSheet.swift:10,32` (where the replaced item went)
- Modify: `App/Sources/Views/ShortcutEditorView.swift:15,87-89,125-129` (library-folder warning; the export outcome sheet)
- Modify: `App/Sources/Views/EditorSections.swift:183` (the target's bundle id reaches the guard)
- Modify: `App/Sources/Views/Wizard/WizardSteps.swift:205` (the target's bundle id reaches the guard)
- Test: `App/Tests/Services/DataPathGuardTests.swift:33-38,138,150` (modify)
- Test: `App/Tests/Services/ShortcutBuilderTests.swift:167-173,241` (modify)
- Test: `App/Tests/App/AppStateTests.swift:215` (modify)
- Test: `App/Tests/Services/DeleteConfirmationTests.swift`

**Interfaces:**
- Consumes (Phase 2; Task 6's `ShortcutBuilder: Sendable` with its computed `fileManager`): `CanonicalPath` (`init(_:)` resolves symlinks with `realpath(3)` along the longest existing prefix; `path`, `url`, `depth`, `isSame(as:)`, `isInside(_:)` (strictly inside), `overlaps(_:)`, `appending(_:)`), `DataPathGuard.validate(dataPath:targetPath:outputFolder:libraryFolders:otherRecordDataPaths:home:) -> Result<URL, DataPathGuardError>` and `DataPathGuardError` (`empty`, `relative`, `protectedLocation`, `dataRoot`, `overlapsTarget`, `overlapsLibraryFolder`, `usedByAnotherShortcut`; `LocalizedError`), `ShortcutConfig.dataRoot(home:) -> URL` and `effectiveDataPath(home:) -> String?` (`App/Sources/Services/ShortcutConfig+DefaultDataPath.swift`), the `ShortcutConfig` init (labels in order `name:slug:bundleIdentifier:targetPath:targetBundleIdentifier:`, every later label defaulted), `TargetResolver().resolve(config:) throws -> URL` (DuplicatorCore: the stored path while it holds an app whose `CFBundleIdentifier` is `targetBundleIdentifier`, else the first LaunchServices hit for that bundle id; throws `LauncherError.targetNotFound` otherwise), `ShortcutBuilder.export(record:to:) throws -> URL`, `delete(record:removeData:libraryFolders:otherRecordDataPaths:) throws -> [URL]`, `BuilderError.exportOverlapsShortcut(URL)` and `exportOverlapsTarget(URL)`, the private `trash(_:) throws -> URL` and `removeStagingCopy(_:)`, `AppState.export(_:to:) async -> Bool`, `delete(_:removeData:) async -> [URL]`, `validateDataPath(_:targetPath:excluding:)`, `dataFolderDeletionOption(for:)`, `present(_:context:)`, `settings.allLibraryFolders` (the output folder first) and `library.records`, `DataFolderDeletionOption` (`unavailable(note:)`, `available(folder:outsideDataRoot:)`), `ExportSheet(exportedURL:environment:arguments:)` (Task 4), `WizardModel.inspected: InspectedApp?`; test helpers `makeAppTemporaryDirectory()`, `writeFakeTarget(named:bundleIdentifier:version:in:)`, `makeConfig(name:targetPath:)` (target bundle id `com.example.target`), `makeTestDefaults()`, `LibraryScanner.record(forBundleAt:)`.
- Produces (used by Tasks 8 and 10):
  - `DataPathGuardError.overlapsShortcut(String)` ("<path> is, contains or is inside a shortcut bundle.") and `DataPathGuardError.targetAppData(String)`; `protectedLocation` now reads "<path> is a system, volume or home folder, not a shortcut data folder."
  - `DataPathGuard.validate(dataPath:targetPath:outputFolder:libraryFolders:otherRecordDataPaths:home:resolvedTargetPath: String? = nil, targetBundleIdentifier: String? = nil, shortcutBundles: [URL] = [])`. The Phase 2 checks run first and keep their messages; the Phase 3 checks follow in the order resolved target, shortcut bundles, the target's own data in `~/Library`, shallow folders.
  - `CanonicalPath.fold(_ component: String) -> String` (static) and `CanonicalPath.foldedComponent(at index: Int) -> String?`.
  - `TargetResolver.resolvedPath(targetPath: String, targetBundleIdentifier: String) -> String?` and `TargetResolver.resolvedPath(for config: ShortcutConfig) -> String?` (`App/Sources/Services/TargetResolver+ResolvedPath.swift`).
  - `ShortcutBuilder.ExportOutcome: Equatable, Sendable, Identifiable` (`exportedURL: URL`, `trashedExisting: URL?`, `id` is `exportedURL`), `ShortcutBuilder.exportCopy(record:to:resolvedTargetPath: String? = nil) throws -> ExportOutcome` and `static ShortcutBuilder.isStagingName(_ name: String) -> Bool`. `export(record:to:)` keeps its signature and checks the resolved target too. `delete(record:removeData:libraryFolders:otherRecordDataPaths:shortcutBundles: [URL] = [])`.
  - `AppState.exportCopy(_:to:) async -> ShortcutBuilder.ExportOutcome?` (rescans the library), `AppState.exportWarning(for destination: URL) -> String?`, `AppState.validateDataPath(_:targetPath:excluding:targetBundleIdentifier: String? = nil)`; `AppState.delete(_:removeData:)` passes every scanned bundle.
  - `struct DeleteConfirmation: Equatable` (`App/Sources/Services/DeleteConfirmation.swift`): `init?(shortcutName: String, option: DataFolderDeletionOption, removeData: Bool)`, `title: String`, `message: String`.
  - `ExportSheet(exportedURL:environment:arguments:trashedExisting: URL? = nil)`.
  - Copy for Task 10's checklist: the delete sheet's second step "Also move “<folder name>” to the Trash?" with `Move to Trash` and `Cancel`; the export dialog "Export into a library folder?" with `Export Anyway` and `Cancel`; the export sheet line "The item that was at <destination> is in the Trash: <Trash location>".

- [ ] **Step 1: Write the failing app tests**

In `App/Tests/Services/DataPathGuardTests.swift`:

1. In lines 33-38 replace

```swift
    private func validate(_ path: String) -> Result<URL, DataPathGuardError> {
        DataPathGuard.validate(
            dataPath: path, targetPath: target.path, outputFolder: output, libraryFolders: [shortcuts],
            otherRecordDataPaths: [otherData.path, sharedData.path], home: home
        )
    }
```

with

```swift
    /// Where `TargetResolver` finds the target now, after it moved and was renamed (the stored path is `target`).
    private var movedTarget: URL { dir.appending(path: "Moved/Renamed.app", directoryHint: .isDirectory) }

    private func validate(_ path: String) -> Result<URL, DataPathGuardError> {
        DataPathGuard.validate(
            dataPath: path, targetPath: target.path, outputFolder: output, libraryFolders: [shortcuts],
            otherRecordDataPaths: [otherData.path, sharedData.path], home: home,
            resolvedTargetPath: movedTarget.path, targetBundleIdentifier: "com.example.target",
            shortcutBundles: [shortcuts.appending(path: "Other.app"), dir.appending(path: "Loose/Other.app")]
        )
    }
```

2. After `testAcceptsOwnFoldersAndReturnsTheResolvedLocation` (line 138, the last test) add:

```swift

    func testRefusesEveryDirectChildOfHomeButNotFoldersBelowThem() throws {
        for name in ["Developer", ".ssh", "Projects", "Sites"] {
            assertRefused(home.appending(path: name).path, as: "protectedLocation")
        }
        assertAccepted(home.appending(path: "Developer/Work Data").path, resolvingTo: try realPath(home) + "/Developer/Work Data")
    }

    func testRefusesShallowFoldersOutsideHomeButNotFoldersBelowThem() {
        // Read-only: these paths are only resolved with realpath(3); nothing is created outside the temp folder.
        let volume = "/Volumes/NoSuchDisk-\(UUID().uuidString)"
        for path in ["/Users/Shared", "/opt/homebrew", "/usr/local", "/Library/Caches", "/tmp", volume] {
            assertRefused(path, as: "protectedLocation")
        }
        assertAccepted(volume + "/Shortcut Data", resolvingTo: volume + "/Shortcut Data")
    }

    func testAcceptsAFolderInsideALibraryFolderThatIsNotAShortcut() throws {
        // The library scans only the `.app` bundles directly inside a library folder, so this folder is never a shortcut.
        assertAccepted(shortcuts.appending(path: "Work Data").path, resolvingTo: try realPath(shortcuts) + "/Work Data")
    }

    func testRefusesShortcutBundlesPathsInsideThemAndFoldersContainingThem() {
        assertRefused(shortcuts.appending(path: "Other.app").path, as: "overlapsShortcut")
        assertRefused(shortcuts.appending(path: "Other.app/Contents/Data").path, as: "overlapsShortcut")
        assertRefused(dir.appending(path: "Loose").path, as: "overlapsShortcut")
    }

    func testRefusesTheResolvedTargetPathsInsideItAndFoldersContainingIt() {
        assertRefused(movedTarget.path, as: "overlapsTarget")
        assertRefused(movedTarget.appending(path: "Contents/Data").path, as: "overlapsTarget")
        assertRefused(movedTarget.deletingLastPathComponent().path, as: "overlapsTarget")
    }

    func testRefusesTheTargetAppsOwnDataFolders() throws {
        for folder in [
            "Library/Application Support/Target", "Library/Containers/com.example.target/Data",
            "Library/Caches/COM.EXAMPLE.TARGET", "Library/Application Support/Renamed",
        ] {
            assertRefused(home.appending(path: folder).path, as: "targetAppData")
        }
        let support = try realPath(dataRoot.deletingLastPathComponent())
        assertAccepted(home.appending(path: "Library/Application Support/Target Work Data").path, resolvingTo: support + "/Target Work Data")
        // A shortcut of App Duplicator itself: its data folders inside the data root stay its own.
        let selfShortcut = DataPathGuard.validate(
            dataPath: dataRoot.appending(path: "work").path, targetPath: dir.appending(path: "Apps/App Duplicator.app").path,
            outputFolder: output, libraryFolders: [], otherRecordDataPaths: [], home: home
        )
        XCTAssertEqual(try selfShortcut.get().path, try realPath(dataRoot) + "/work")
    }
```

3. After `case .usedByAnotherShortcut: "usedByAnotherShortcut"` (line 150) add:

```swift
        case .overlapsShortcut: "overlapsShortcut"
        case .targetAppData: "targetAppData"
```

In `App/Tests/Services/ShortcutBuilderTests.swift`:

1. In lines 167-173 replace

```swift
        let exported = try builder.export(record: record, to: destination)

        XCTAssertEqual(exported.standardizedFileURL.path, destination.standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appending(path: "old-marker").path))
        XCTAssertEqual(try Data(contentsOf: destination.appending(path: "Contents/Info.plist")), try Data(contentsOf: bundle.appending(path: "Contents/Info.plist")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Info.plist").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exportDir.path), ["Exported.app"], "no staging copy left behind")
```

with

```swift
        let outcome = try builder.exportCopy(record: record, to: destination)
        let exported = outcome.exportedURL
        let trashed = try XCTUnwrap(outcome.trashedExisting, "the existing destination goes to the Trash")
        addTeardownBlock { try FileManager.default.removeItem(at: trashed) }

        XCTAssertEqual(exported.standardizedFileURL.path, destination.standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appending(path: "old-marker").path))
        XCTAssertEqual(try Data(contentsOf: trashed.appending(path: "old-marker")), Data("old".utf8), "replaced, never deleted")
        XCTAssertEqual(try Data(contentsOf: destination.appending(path: "Contents/Info.plist")), try Data(contentsOf: bundle.appending(path: "Contents/Info.plist")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Info.plist").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exportDir.path), ["Exported.app"], "no staging copy left behind")
```

2. After `testDeleteRemovesBundleAndOptionallyDataFolder` (line 241, the last test) add:

```swift

    func testExportRefusesACaseVariantOfTheShortcutsPath() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        for destination in [out.appending(path: "target work.app"), out.appending(path: "TARGET WORK.app/Contents/Copy.app")] {
            XCTAssertThrowsError(try builder.exportCopy(record: record, to: destination)) { error in
                guard case ShortcutBuilder.BuilderError.exportOverlapsShortcut = error else { return XCTFail("\(destination.path): \(error)") }
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["Target Work.app"], "nothing staged, trashed or replaced")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Info.plist").path))
    }

    func testExportRefusesASymlinkToTheShortcut() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        let link = dir.appending(path: "Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)
        let folderLink = dir.appending(path: "link-to-out")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: out)
        for destination in [link, folderLink.appending(path: "Target Work.app")] {
            XCTAssertThrowsError(try builder.exportCopy(record: record, to: destination)) { error in
                guard case ShortcutBuilder.BuilderError.exportOverlapsShortcut = error else { return XCTFail("\(destination.path): \(error)") }
            }
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), bundle.path, "the link is never replaced")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Info.plist").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["Target Work.app"])
    }

    func testExportRefusesTheResolvedTargetWhenTheStoredPathIsStale() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        // The target moved after the shortcut was made; the stored path no longer holds it.
        let moved = dir.appending(path: "Moved/Renamed.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: target, to: moved)
        let executable = try Data(contentsOf: moved.appending(path: "Contents/MacOS/Target"))
        for destination in [moved, moved.appending(path: "Contents/Inner.app"), moved.deletingLastPathComponent()] {
            XCTAssertThrowsError(try builder.exportCopy(record: record, to: destination, resolvedTargetPath: moved.path)) { error in
                guard case ShortcutBuilder.BuilderError.exportOverlapsTarget = error else { return XCTFail("\(destination.path): \(error)") }
            }
        }
        XCTAssertEqual(try Data(contentsOf: moved.appending(path: "Contents/MacOS/Target")), executable, "the target is never touched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.deletingLastPathComponent().path), ["Renamed.app"])
    }

    func testExportSweepsStaleStagingCopiesAndNothingElse() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        let exportDir = dir.appending(path: "export", directoryHint: .isDirectory)
        // Left behind by crashed exports: the staging names `exportCopy` makes, for this destination and another one.
        let stale = [".Exported.app.mad-export-\(UUID().uuidString)", ".Other.app.mad-export-\(UUID().uuidString)"]
        // Look-alikes the sweep must keep.
        let kept = [".Exported.app.mad-export-not-a-uuid", "Exported.app.mad-export-\(UUID().uuidString)", "Notes"]
        for name in stale + kept {
            try FileManager.default.createDirectory(at: exportDir.appending(path: name), withIntermediateDirectories: true)
        }

        let outcome = try builder.exportCopy(record: record, to: exportDir.appending(path: "Exported.app", directoryHint: .isDirectory))

        XCTAssertNil(outcome.trashedExisting, "nothing was at the destination")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: exportDir.path)), Set(kept + ["Exported.app"]))
        XCTAssertTrue(ShortcutBuilder.isStagingName(stale[0]))
        XCTAssertFalse(ShortcutBuilder.isStagingName(kept[0]))
    }
```

In `App/Tests/App/AppStateTests.swift`, after `testRebuildAllContinuesPastAFailureAndReportsEveryShortcut` (line 215, the last test) add:

```swift

    func testExportWarnsInsideALibraryFolderAndMovesAnExistingDestinationToTheTrash() async throws {
        let created = await state.create(config: config())
        let record = try XCTUnwrap(library.record(for: try XCTUnwrap(created)))
        let exports = dir.appending(path: "Exports", directoryHint: .isDirectory)

        let warning = try XCTUnwrap(state.exportWarning(for: out.appending(path: "Work Copy.app")))
        XCTAssertTrue(warning.contains("Work Copy.app") && warning.contains("second shortcut"), warning)
        XCTAssertNotNil(state.exportWarning(for: dir.appending(path: "OUT/Work Copy.app")), "library folders compare case-insensitively")
        XCTAssertNil(state.exportWarning(for: exports.appending(path: "Work Copy.app")))
        XCTAssertNil(state.exportWarning(for: out.appending(path: "Nested/Work Copy.app")), "the library scans only a folder's direct children")

        let destination = exports.appending(path: "Work.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appending(path: "old-marker"))
        let exported = await state.exportCopy(record, to: destination)

        let outcome = try XCTUnwrap(exported)
        let trashed = try XCTUnwrap(outcome.trashedExisting)
        addTeardownBlock { try FileManager.default.removeItem(at: trashed) }
        XCTAssertEqual(try Data(contentsOf: trashed.appending(path: "old-marker")), Data("old".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appending(path: "Contents/Info.plist").path))
        XCTAssertNil(state.pendingError)
    }

    func testValidateDataPathRefusesScannedShortcutsAndTheTargetAppsOwnData() async throws {
        let created = await state.create(config: config())
        let bundle = try XCTUnwrap(created)
        guard case .failure(.overlapsShortcut) = state.validateDataPath(bundle.appending(path: "Contents/Data").path, targetPath: target.path, excluding: nil) else {
            return XCTFail("a folder inside a scanned shortcut is refused")
        }
        // Read-only: the app is not sandboxed, so this is the real home; these folders are only resolved, never created.
        let home = FileManager.default.homeDirectoryForCurrentUser
        for folder in ["Library/Application Support/Target", "Library/Caches/com.example.target"] {
            let result = state.validateDataPath(home.appending(path: folder).path, targetPath: target.path, excluding: nil, targetBundleIdentifier: "com.example.target")
            guard case .failure(.targetAppData) = result else { return XCTFail("\(folder): \(result)") }
        }
        XCTAssertEqual(TargetResolver().resolvedPath(targetPath: target.path, targetBundleIdentifier: "com.example.target"), target.path)
        XCTAssertNil(TargetResolver().resolvedPath(targetPath: target.path, targetBundleIdentifier: ""))
    }
```

Create `App/Tests/Services/DeleteConfirmationTests.swift`:

```swift
import XCTest
@testable import MacAppDuplicator

final class DeleteConfirmationTests: XCTestCase {
    func testAsksOnlyBeforeTrashingADataFolderOutsideTheDataRoot() throws {
        let outside = DataFolderDeletionOption.available(folder: URL(fileURLWithPath: "/Volumes/Work/Shared Data", isDirectory: true), outsideDataRoot: true)
        let inside = DataFolderDeletionOption.available(
            folder: URL(fileURLWithPath: "/Users/someone/Library/Application Support/App Duplicator/work", isDirectory: true), outsideDataRoot: false
        )

        XCTAssertNil(DeleteConfirmation(shortcutName: "Work", option: outside, removeData: false), "nothing to confirm when the folder stays")
        XCTAssertNil(DeleteConfirmation(shortcutName: "Work", option: inside, removeData: true), "a folder inside the data root needs no second step")
        XCTAssertNil(DeleteConfirmation(shortcutName: "Work", option: .unavailable(note: "No data folder exists."), removeData: true))

        let confirmation = try XCTUnwrap(DeleteConfirmation(shortcutName: "Work", option: outside, removeData: true))
        XCTAssertEqual(confirmation.title, "Also move “Shared Data” to the Trash?")
        XCTAssertEqual(
            confirmation.message,
            "The data folder of “Work” is /Volumes/Work/Shared Data, outside ~/Library/Application Support/App Duplicator. Everything in it is moved to the Trash with the shortcut."
        )
    }
}
```

The case-variant and symlink export tests and `testAcceptsAFolderInsideALibraryFolderThatIsNotAShortcut` pin Phase 2 behaviour (re-review Minor 6): they would pass on the Phase 2 code once `exportCopy` exists, and they keep it from regressing. The AppState test checks `~/Library/Caches/com.example.target` rather than a folder under `~/Library/Containers`, because looking inside another app's container can raise a macOS privacy prompt; the fake-home guard test covers `Containers`.

- [ ] **Step 2: Run the app tests to verify they fail**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/DataPathGuardTests -only-testing:MacAppDuplicatorTests/ShortcutBuilderTests -only-testing:MacAppDuplicatorTests/AppStateTests -only-testing:MacAppDuplicatorTests/DeleteConfirmationTests 2>&1 | grep -E 'error:' | sed -E 's/.*error: //' | sort -u`
Expected: compile errors; nothing runs. In practice the list is `cannot find 'DeleteConfirmation' in scope` (from `DeleteConfirmationTests.swift`). The build stops at the first test files that fail, so `extra arguments at positions #7, #8, #9 in call` and `type '_ErrorCodeProtocol' has no member 'overlapsShortcut'` (from `DataPathGuardTests.swift`) can appear next to them, and so can `value of type 'ShortcutBuilder' has no member 'exportCopy'` and `type 'ShortcutBuilder' has no member 'isStagingName'` (from `ShortcutBuilderTests.swift`) and `value of type 'AppState' has no member 'exportCopy'`, `value of type 'AppState' has no member 'exportWarning'` and `extra argument 'targetBundleIdentifier' in call` (from `AppStateTests.swift`), with follow-on errors such as `generic parameter 'T' could not be inferred` and `failed to produce diagnostic for expression; please submit a bug report (https://swift.org/contributing/#reporting-bugs)`.

- [ ] **Step 3: Widen the data-path guard**

In `App/Sources/Services/CanonicalPath.swift`:

1. In line 16 replace `folded = resolved.split(separator: "/").map { $0.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil) }` with `folded = resolved.split(separator: "/").map { Self.fold(String($0)) }`.
2. After `func appending(_ relativePath: String) -> CanonicalPath { CanonicalPath(path + "/" + relativePath) }` (line 34) add:

```swift

    /// The comparison form of one path component: precomposed (NFC) and case-folded, as every comparison here uses.
    static func fold(_ component: String) -> String {
        component.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
    }

    /// The comparison form of the component at `index` (0 is the first component below `/`), or nil past the end.
    func foldedComponent(at index: Int) -> String? { folded.indices.contains(index) ? folded[index] : nil }
```

In `App/Sources/Services/DataPathGuard.swift`:

1. After `case usedByAnotherShortcut(String)` (line 12) add:

```swift
    case overlapsShortcut(String)
    case targetAppData(String)
```

2. In line 18 replace `"\(path) is a system or home folder, not a shortcut data folder."` with `"\(path) is a system, volume or home folder, not a shortcut data folder."`.
3. After the `usedByAnotherShortcut` description (line 22) add:

```swift
        case .overlapsShortcut(let path): "\(path) is, contains or is inside a shortcut bundle."
        case .targetAppData(let path): "\(path) is or is inside the target app's own data in ~/Library (a folder named after the app or its bundle identifier); App Duplicator never uses or trashes it."
```

4. In lines 34-39 replace

```swift
    /// - Parameters:
    ///   - targetPath: the shortcut's target app; empty skips the target check.
    ///   - outputFolder, libraryFolders: every folder the library scans.
    ///   - otherRecordDataPaths: the data folders of every other shortcut.
    /// - Returns: the resolved folder (symlinks followed) on success; act on this URL, not on `dataPath`.
    static func validate(dataPath: String, targetPath: String, outputFolder: URL, libraryFolders: [URL], otherRecordDataPaths: [String], home: URL) -> Result<URL, DataPathGuardError> {
```

with

```swift
    /// - Parameters:
    ///   - targetPath: the shortcut's target app; empty skips the target check.
    ///   - outputFolder, libraryFolders: every folder the library scans.
    ///   - otherRecordDataPaths: the data folders of every other shortcut.
    ///   - resolvedTargetPath: where `TargetResolver` finds the target now; checked like `targetPath` (re-review Minor 4).
    ///   - targetBundleIdentifier: with the target's file names, marks `~/Library/<folder>/<name or bundle id>` as the
    ///     target's own data (re-review Minor 1).
    ///   - shortcutBundles: every scanned shortcut bundle; a folder that is, contains or is inside one is refused
    ///     (re-review Minor 2).
    /// - Returns: the resolved folder (symlinks followed) on success; act on this URL, not on `dataPath`. After the
    ///   Phase 2 checks it also refuses shallow folders: every direct child of home, and anything at depth 2 or less
    ///   outside home (`/Users/Shared`, `/opt/homebrew`, `/Volumes/<volume>`).
    static func validate(
        dataPath: String, targetPath: String, outputFolder: URL, libraryFolders: [URL], otherRecordDataPaths: [String], home: URL,
        resolvedTargetPath: String? = nil, targetBundleIdentifier: String? = nil, shortcutBundles: [URL] = []
    ) -> Result<URL, DataPathGuardError> {
```

5. In line 53 replace

```swift
        if candidate.isSame(as: CanonicalPath(ShortcutConfig.dataRoot(home: home).path)) { return .failure(.dataRoot(shown)) }
```

with

```swift
        let dataRoot = CanonicalPath(ShortcutConfig.dataRoot(home: home).path)
        if candidate.isSame(as: dataRoot) { return .failure(.dataRoot(shown)) }
```

6. In lines 66-67 replace

```swift
        return .success(candidate.url)
    }
```

with

```swift
        // Phase 3 widening (re-review Minors 1, 2 and 4) runs after every Phase 2 check, so those keep their messages.
        if let resolvedTargetPath, resolvedTargetPath.hasPrefix("/"), candidate.overlaps(CanonicalPath(resolvedTargetPath)) {
            return .failure(.overlapsTarget(shown))
        }
        if shortcutBundles.contains(where: { candidate.overlaps(CanonicalPath($0.path)) }) { return .failure(.overlapsShortcut(shown)) }
        // `~/Library/<folder>/<target name or bundle id>` is the target's own data. A folder inside the data root is
        // always App Duplicator's, even for a shortcut of App Duplicator itself.
        if !candidate.isInside(dataRoot), candidate.isInside(library), let owner = candidate.foldedComponent(at: library.depth + 1),
           targetDataFolderNames(targetPath: targetPath, resolvedTargetPath: resolvedTargetPath, targetBundleIdentifier: targetBundleIdentifier).contains(owner) {
            return .failure(.targetAppData(shown))
        }
        // A folder this shallow is a shared location (`~/Developer`, `~/.ssh`, `/Users/Shared`, `/opt/homebrew`,
        // `/Volumes/<volume>`, …), never one shortcut's own folder.
        let isShallow = candidate.isInside(homePath) ? candidate.depth == homePath.depth + 1 : candidate.depth <= 2
        if isShallow { return .failure(.protectedLocation(shown)) }

        return .success(candidate.url)
    }

    /// The folded names the target's own data folders go by in `~/Library/<folder>/`: its file name without `.app`
    /// (stored and resolved) and its bundle identifier.
    private static func targetDataFolderNames(targetPath: String, resolvedTargetPath: String?, targetBundleIdentifier: String?) -> Set<String> {
        let fileNames = [targetPath, resolvedTargetPath ?? ""].filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        return Set((fileNames + [targetBundleIdentifier ?? ""]).filter { !$0.isEmpty }.map(CanonicalPath.fold))
    }
```

Create `App/Sources/Services/TargetResolver+ResolvedPath.swift`:

```swift
import DuplicatorCore
import Foundation

extension TargetResolver {
    /// The target's current location as `resolve(config:)` finds it (the stored path while it still holds the app,
    /// else the first LaunchServices hit for the bundle id), or nil when the bundle id is empty or nothing is found.
    /// The data-path guard and export check this location as well as the stored path (re-review Minor 4).
    func resolvedPath(targetPath: String, targetBundleIdentifier: String) -> String? {
        guard !targetBundleIdentifier.isEmpty else { return nil }
        let probe = ShortcutConfig(name: "", slug: "", bundleIdentifier: "", targetPath: targetPath, targetBundleIdentifier: targetBundleIdentifier)
        do {
            return try resolve(config: probe).path
        } catch {
            // `resolve` throws only `targetNotFound`; the stored path is checked on its own, so there is nothing to add.
            return nil
        }
    }

    func resolvedPath(for config: ShortcutConfig) -> String? {
        resolvedPath(targetPath: config.targetPath, targetBundleIdentifier: config.targetBundleIdentifier)
    }
}
```

The Phase 2 checks run first and keep their messages, so every Phase 2 test still sees the refusal it expects. The new checks follow in order. The resolved target is refused like the stored one (re-review Minor 4). A folder that is, contains or is inside a scanned shortcut bundle is refused (Minor 2). `~/Library/<folder>/<name>`, where `<name>` is the target's file name without `.app` (stored or resolved) or its bundle identifier, compared like every other component, is the target's own data; the data root is exempt, because everything in it belongs to App Duplicator (Minor 1). Last, every direct child of home and anything at depth 2 or less outside home is a shared location (Minor 1): a volume root such as `/Volumes/Work` is refused, a folder inside it such as `/Volumes/Work/Shortcut Data` is accepted. `TargetResolver.resolve(config:)` lives in DuplicatorCore and throws only `LauncherError.targetNotFound`; `resolvedPath` turns that into nil, since the stored path is checked either way.

- [ ] **Step 4: Trash, sweep and restore in `ShortcutBuilder` export**

In `App/Sources/Services/ShortcutBuilder.swift`:

1. After the closing brace of `BuilderError` (line 22) add:

```swift

    /// What an export did: where the copy is, and where the item that was already at the destination went.
    struct ExportOutcome: Equatable, Sendable, Identifiable {
        let exportedURL: URL
        /// The Trash location of the item that was at the destination, or nil when there was none.
        let trashedExisting: URL?

        var id: URL { exportedURL }
    }
```

2. In lines 70-96 replace

```swift
    /// Copies the bundle to `destination` (an `.app` path chosen by the user). The copy keeps its signature.
    /// A destination that is, contains or is inside the target or the shortcut itself is refused before any write.
    /// The copy is staged next to the destination and swapped in with `replaceItemAt`, so an existing item there is
    /// removed only once its replacement is in place, and a failed export leaves both the source and it untouched.
    func export(record: ShortcutRecord, to destination: URL) throws -> URL {
        let canonicalDestination = CanonicalPath(destination.path)
        if record.config.targetPath.hasPrefix("/"), canonicalDestination.overlaps(CanonicalPath(record.config.targetPath)) {
            throw BuilderError.exportOverlapsTarget(destination)
        }
        if canonicalDestination.overlaps(CanonicalPath(record.bundleURL.path)) {
            throw BuilderError.exportOverlapsShortcut(destination)
        }
        let staging = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).mad-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.copyItem(at: record.bundleURL, to: staging)
            if fileManager.fileExists(atPath: destination.path) {
                // New metadata only: the export must be byte-for-byte the signed source, not inherit the old item's.
                return try fileManager.replaceItemAt(destination, withItemAt: staging, options: .usingNewMetadataOnly) ?? destination
            }
            try fileManager.moveItem(at: staging, to: destination)
            return destination
        } catch {
            removeStagingCopy(staging)
            throw error
        }
    }
```

with

```swift
    /// Copies the bundle to `destination` (an `.app` path chosen by the user). The copy keeps its signature.
    /// A destination that is, contains or is inside the shortcut, the stored target or `resolvedTargetPath` (where
    /// `TargetResolver` finds the target now) is refused before any write (re-review Minor 4). Staging copies a
    /// crashed export left in the destination folder (`isStagingName`) are removed first. The copy is staged next to
    /// the destination; only once staging is complete does an item already at the destination go to the Trash (never
    /// deleted), and it is put back if the final move fails (re-review Minor 5).
    func exportCopy(record: ShortcutRecord, to destination: URL, resolvedTargetPath: String? = nil) throws -> ExportOutcome {
        let canonicalDestination = CanonicalPath(destination.path)
        for targetPath in [record.config.targetPath, resolvedTargetPath ?? ""] where targetPath.hasPrefix("/") {
            if canonicalDestination.overlaps(CanonicalPath(targetPath)) { throw BuilderError.exportOverlapsTarget(destination) }
        }
        if canonicalDestination.overlaps(CanonicalPath(record.bundleURL.path)) {
            throw BuilderError.exportOverlapsShortcut(destination)
        }
        let folder = destination.deletingLastPathComponent()
        sweepStagingCopies(in: folder)
        let staging = folder.appending(path: ".\(destination.lastPathComponent).mad-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.copyItem(at: record.bundleURL, to: staging)
        } catch {
            removeStagingCopy(staging)
            throw error
        }
        var trashedExisting: URL?
        if fileManager.fileExists(atPath: destination.path) {
            do {
                trashedExisting = try trash(destination)
            } catch {
                removeStagingCopy(staging)
                throw error
            }
        }
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            if let trashedExisting { restore(trashedExisting, to: destination) }
            removeStagingCopy(staging)
            throw error
        }
        return ExportOutcome(exportedURL: destination, trashedExisting: trashedExisting)
    }

    /// `exportCopy` checked against the target's current location as well as the stored one; returns where the copy is.
    func export(record: ShortcutRecord, to destination: URL) throws -> URL {
        try exportCopy(record: record, to: destination, resolvedTargetPath: TargetResolver().resolvedPath(for: record.config)).exportedURL
    }
```

3. In lines 98-111 replace

```swift
    /// Moves the bundle to the Trash; with `removeData`, also trashes the shortcut's data folder (never the target).
    /// The data folder must pass `DataPathGuard` against `libraryFolders` (the bundle's own folder is always included)
    /// and `otherRecordDataPaths`; a refusal throws before anything is trashed. Returns the Trash location of
    /// everything it trashed, in order (bundle first).
    @discardableResult
    func delete(record: ShortcutRecord, removeData: Bool, libraryFolders: [URL] = [], otherRecordDataPaths: [String] = []) throws -> [URL] {
        var dataFolder: URL?
        let home = fileManager.homeDirectoryForCurrentUser
        if removeData, record.config.dataMode != .disabled, let dataPath = record.config.effectiveDataPath(home: home) {
            dataFolder = try DataPathGuard.validate(
                dataPath: dataPath, targetPath: record.config.targetPath, outputFolder: record.bundleURL.deletingLastPathComponent(),
                libraryFolders: libraryFolders, otherRecordDataPaths: otherRecordDataPaths, home: home
            ).get()
        }
```

with

```swift
    /// Moves the bundle to the Trash; with `removeData`, also trashes the shortcut's data folder (never the target).
    /// The data folder must pass `DataPathGuard` against `libraryFolders` (the bundle's own folder is always included),
    /// `otherRecordDataPaths`, `shortcutBundles` (the bundle itself is always included), the target's current location
    /// and its own data in `~/Library`; a refusal throws before anything is trashed. Returns the Trash location of
    /// everything it trashed, in order (bundle first).
    @discardableResult
    func delete(
        record: ShortcutRecord, removeData: Bool, libraryFolders: [URL] = [], otherRecordDataPaths: [String] = [], shortcutBundles: [URL] = []
    ) throws -> [URL] {
        var dataFolder: URL?
        let home = fileManager.homeDirectoryForCurrentUser
        if removeData, record.config.dataMode != .disabled, let dataPath = record.config.effectiveDataPath(home: home) {
            dataFolder = try DataPathGuard.validate(
                dataPath: dataPath, targetPath: record.config.targetPath, outputFolder: record.bundleURL.deletingLastPathComponent(),
                libraryFolders: libraryFolders, otherRecordDataPaths: otherRecordDataPaths, home: home,
                resolvedTargetPath: TargetResolver().resolvedPath(for: record.config),
                targetBundleIdentifier: record.config.targetBundleIdentifier, shortcutBundles: [record.bundleURL] + shortcutBundles
            ).get()
        }
```

4. In line 120 replace `/// Best-effort cleanup after a failed export; the export error is what the caller sees.` with `/// Best-effort removal of a staging copy (after a failed export, or a stale one); a failure is only logged.`.
5. After the closing brace of `removeStagingCopy(_:)` (line 128) add:

```swift

    /// Removes the staging copies a crashed export left in `folder` (`isStagingName`); best effort, never anything else.
    private func sweepStagingCopies(in folder: URL) {
        guard fileManager.fileExists(atPath: folder.path) else { return }
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: folder.path)
        } catch {
            Self.logger.warning("Could not list \(folder.path, privacy: .public) for stale export copies: \(error.localizedDescription, privacy: .public)")
            return
        }
        for name in names where Self.isStagingName(name) {
            removeStagingCopy(folder.appending(path: name, directoryHint: .isDirectory))
        }
    }

    /// `.<name>.mad-export-<UUID>`: the staging copy `exportCopy` makes, a name only it uses.
    static func isStagingName(_ name: String) -> Bool {
        name.wholeMatch(of: #/\..+\.mad-export-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/#) != nil
    }

    /// Best-effort undo after a failed export: puts the item that was at `destination` back from the Trash. A failure
    /// is logged with both locations and the item stays in the Trash; the export error is what the caller sees.
    private func restore(_ trashed: URL, to destination: URL) {
        do {
            try fileManager.moveItem(at: trashed, to: destination)
        } catch {
            Self.logger.warning("Could not put back \(destination.path, privacy: .public) from the Trash (\(trashed.path, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }
```

The refusals before any write are unchanged apart from the resolved target. The Phase 2 `replaceItemAt` swap deleted the item it replaced; now that item goes to the Trash only after the staging copy is complete, and `restore` moves it back when the final move fails, so a failed export still leaves the source and the existing item in place. On a volume without a Trash, `trashItem` throws and the export fails before anything is replaced. The sweep matches only `.<name>.mad-export-<UUID>` (`UUID().uuidString` is upper-case hex), and the library never scans those hidden folders. `export(record:to:)` keeps its signature for its Phase 2 callers and resolves the target itself. `delete` always checks the bundle being deleted, so a data folder inside it is refused; the delete sheet never offers one, because `AppState` runs the same check first.

- [ ] **Step 5: Export outcome, library warning and guard inputs in `AppState`; the delete confirmation**

In `App/Sources/App/AppState.swift`:

1. In lines 174-182 replace

```swift
    func export(_ record: ShortcutRecord, to destination: URL) async -> Bool {
        do {
            _ = try builder.export(record: record, to: destination)
            return true
        } catch {
            present(error, context: "Could not export shortcut")
            return false
        }
    }
```

with

```swift
    /// Exports a copy of `record` (re-review Minors 4 and 5): checked against the target's current location as well
    /// as the stored one; an item already at `destination` goes to the Trash and comes back if the export fails. The
    /// library is rescanned afterwards. Returns nil and sets `pendingError` on failure.
    func exportCopy(_ record: ShortcutRecord, to destination: URL) async -> ShortcutBuilder.ExportOutcome? {
        do {
            let outcome = try builder.exportCopy(record: record, to: destination, resolvedTargetPath: TargetResolver().resolvedPath(for: record.config))
            await library.rescan()
            return outcome
        } catch {
            present(error, context: "Could not export shortcut")
            return nil
        }
    }

    func export(_ record: ShortcutRecord, to destination: URL) async -> Bool {
        await exportCopy(record, to: destination) != nil
    }

    /// Why exporting to `destination` deserves a second look, or nil: a copy directly inside a library folder is
    /// scanned as a second shortcut with the same bundle identifier and data folder (re-review Minor 5).
    func exportWarning(for destination: URL) -> String? {
        let parent = CanonicalPath(destination.deletingLastPathComponent().path)
        guard let folder = settings.allLibraryFolders.first(where: { CanonicalPath($0.path).isSame(as: parent) }) else { return nil }
        return "\(destination.lastPathComponent) would be inside the library folder \(folder.path), so it would appear in the library as a second shortcut with the same bundle identifier and data folder."
    }
```

2. In lines 190-193 replace

```swift
            let trashed = try builder.delete(
                record: record, removeData: removeData,
                libraryFolders: settings.allLibraryFolders, otherRecordDataPaths: dataPathsInUse(excluding: record.bundleURL)
            )
```

with

```swift
            let trashed = try builder.delete(
                record: record, removeData: removeData,
                libraryFolders: settings.allLibraryFolders, otherRecordDataPaths: dataPathsInUse(excluding: record.bundleURL),
                shortcutBundles: library.records.map(\.bundleURL)
            )
```

3. In lines 203-210 replace

```swift
    /// Checks a data folder the user picked (wizard or editor) with the same guard delete uses. `excluding` is the
    /// bundle being edited, so its own current folder does not count as another shortcut's.
    func validateDataPath(_ path: String, targetPath: String, excluding bundleURL: URL?) -> Result<URL, DataPathGuardError> {
        DataPathGuard.validate(
            dataPath: path, targetPath: targetPath, outputFolder: settings.outputFolder, libraryFolders: settings.allLibraryFolders,
            otherRecordDataPaths: dataPathsInUse(excluding: bundleURL), home: FileManager.default.homeDirectoryForCurrentUser
        )
    }
```

with

```swift
    /// Checks a data folder the user picked (wizard or editor) with the same guard delete uses. `excluding` is the
    /// bundle being edited, so its own current folder does not count as another shortcut's. Every scanned bundle is
    /// checked, the edited one included; with `targetBundleIdentifier`, so are the target's current location and its
    /// own data folders in `~/Library`.
    func validateDataPath(_ path: String, targetPath: String, excluding bundleURL: URL?, targetBundleIdentifier: String? = nil) -> Result<URL, DataPathGuardError> {
        DataPathGuard.validate(
            dataPath: path, targetPath: targetPath, outputFolder: settings.outputFolder, libraryFolders: settings.allLibraryFolders,
            otherRecordDataPaths: dataPathsInUse(excluding: bundleURL), home: FileManager.default.homeDirectoryForCurrentUser,
            resolvedTargetPath: targetBundleIdentifier.flatMap { TargetResolver().resolvedPath(targetPath: targetPath, targetBundleIdentifier: $0) },
            targetBundleIdentifier: targetBundleIdentifier, shortcutBundles: library.records.map(\.bundleURL)
        )
    }
```

4. In line 222 replace `switch validateDataPath(path, targetPath: record.config.targetPath, excluding: record.bundleURL) {` with `switch validateDataPath(path, targetPath: record.config.targetPath, excluding: record.bundleURL, targetBundleIdentifier: record.config.targetBundleIdentifier) {`.

Create `App/Sources/Services/DeleteConfirmation.swift`:

```swift
import Foundation

/// The second step before a data folder outside the data root goes to the Trash with its shortcut (re-review
/// Minor 1, final review M24): the delete sheet asks again, naming the folder.
struct DeleteConfirmation: Equatable {
    let title: String
    let message: String

    /// Nil unless `removeData` is on and `option` offers a folder outside the data root.
    init?(shortcutName: String, option: DataFolderDeletionOption, removeData: Bool) {
        guard removeData, case .available(folder: let folder, outsideDataRoot: true) = option else { return nil }
        title = "Also move “\(folder.lastPathComponent)” to the Trash?"
        message = "The data folder of “\(shortcutName)” is \(folder.path), outside ~/Library/Application Support/App Duplicator. Everything in it is moved to the Trash with the shortcut."
    }
}
```

`exportCopy` rescans because a copy exported into a library folder is a new shortcut there; `export(_:to:)` stays for its Phase 2 test and rescans too. `exportWarning(for:)` compares the destination's parent folder with every library folder as `CanonicalPath`s, so a different case or a symlinked path still warns; the library scans only the direct children of a folder, so a deeper destination gets no warning. `delete` and `validateDataPath` pass every scanned bundle, and `dataFolderDeletionOption(for:)` now passes the record's target bundle id, so the delete sheet offers a data folder only when `ShortcutBuilder.delete` would accept it. `DeleteConfirmation` keeps the second step's decision and copy out of the view, where a unit test can reach them.

- [ ] **Step 6: Run the app tests to verify they pass**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/DataPathGuardTests -only-testing:MacAppDuplicatorTests/ShortcutBuilderTests -only-testing:MacAppDuplicatorTests/AppStateTests -only-testing:MacAppDuplicatorTests/DeleteConfirmationTests 2>&1 | grep -cE "Test Case '.*' passed"`
Expected: `47` (DataPathGuard 15 + ShortcutBuilder 18 + AppState 13 + DeleteConfirmation 1). The views still build unchanged: every new parameter has a default and `export(_:to:)` is still there.

- [ ] **Step 7: The second delete confirmation, the library-folder warning and the export notice**

Replace `App/Sources/Views/DeleteShortcutSheet.swift` with:

```swift
import DuplicatorCore
import SwiftUI

/// Confirms a delete. The data-folder toggle appears only for a folder `AppState.dataFolderDeletionOption` approved
/// (final review I1): never for Disabled mode, a missing folder, or a folder `DataPathGuard` refuses. Trashing a
/// folder outside the data root takes a second, destructive confirmation that names it (re-review Minor 1, final
/// review M24).
struct DeleteShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss
    let record: ShortcutRecord
    let dataFolder: DataFolderDeletionOption
    let onDelete: (Bool) async -> Void
    @State private var removeData = false
    @State private var pendingConfirmation: DeleteConfirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete “\(record.name)”?").font(.headline)
            Text("The shortcut is moved to the Trash. The target app is never touched.")
            switch dataFolder {
            case .unavailable(let note):
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .available(let folder, let outsideDataRoot):
                Toggle("Also move the data folder to the Trash", isOn: $removeData)
                Text(folder.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                if outsideDataRoot {
                    Label("This folder is outside ~/Library/Application Support/App Duplicator: \(folder.path)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    let removesData = removeData && isDataFolderAvailable
                    if let confirmation = DeleteConfirmation(shortcutName: record.name, option: dataFolder, removeData: removesData) {
                        pendingConfirmation = confirmation
                    } else {
                        delete(removeData: removesData)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .confirmationDialog(
            pendingConfirmation?.title ?? "",
            isPresented: Binding(get: { pendingConfirmation != nil }, set: { if !$0 { pendingConfirmation = nil } }),
            titleVisibility: .visible,
            presenting: pendingConfirmation
        ) { _ in
            Button("Move to Trash", role: .destructive) { delete(removeData: true) }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private var isDataFolderAvailable: Bool {
        if case .available = dataFolder { true } else { false }
    }

    private func delete(removeData: Bool) {
        Task {
            await onDelete(removeData)
            dismiss()
        }
    }
}
```

In `App/Sources/Views/ExportSheet.swift`:

1. After `var arguments: [String] = []` (line 10) add:

```swift
    /// Where the item that was already at `exportedURL` went in the Trash, or nil when there was none.
    var trashedExisting: URL? = nil
```

2. After the closing brace of the secret notice's `if` (line 32) add:

```swift
            if let trashedExisting {
                Label {
                    Text(verbatim: "The item that was at \(exportedURL.path) is in the Trash: \(trashedExisting.path)")
                } icon: {
                    Image(systemName: "trash")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
```

In `App/Sources/Views/ShortcutEditorView.swift`:

1. In line 15 replace

```swift
    @State private var exportedURL: URL?
```

with

```swift
    @State private var exportOutcome: ShortcutBuilder.ExportOutcome?
    /// An export destination inside a library folder, waiting for Export Anyway (re-review Minor 5).
    @State private var pendingLibraryExport: URL?
```

2. In lines 87-89 replace

```swift
        .sheet(item: $exportedURL) { url in
            ExportSheet(exportedURL: url, environment: record.config.environment, arguments: record.config.arguments)
        }
```

with

```swift
        .confirmationDialog(
            "Export into a library folder?",
            isPresented: Binding(get: { pendingLibraryExport != nil }, set: { if !$0 { pendingLibraryExport = nil } }),
            titleVisibility: .visible,
            presenting: pendingLibraryExport
        ) { url in
            Button("Export Anyway") { startExport(to: url) }
            Button("Cancel", role: .cancel) {}
        } message: { url in
            Text(appState.exportWarning(for: url) ?? "")
        }
        .sheet(item: $exportOutcome) { outcome in
            ExportSheet(
                exportedURL: outcome.exportedURL, environment: record.config.environment, arguments: record.config.arguments,
                trashedExisting: outcome.trashedExisting
            )
        }
```

3. In lines 125-129 replace

```swift
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if await appState.export(record, to: url) { exportedURL = url }
        }
    }
```

with

```swift
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // A copy directly inside a library folder would be scanned as a second shortcut; ask first (re-review Minor 5).
        if appState.exportWarning(for: url) != nil {
            pendingLibraryExport = url
        } else {
            startExport(to: url)
        }
    }

    private func startExport(to url: URL) {
        Task { exportOutcome = await appState.exportCopy(record, to: url) }
    }
```

In `App/Sources/Views/EditorSections.swift` line 183 replace `switch appState.validateDataPath(url.path, targetPath: draft.targetPath, excluding: record.bundleURL) {` with `switch appState.validateDataPath(url.path, targetPath: draft.targetPath, excluding: record.bundleURL, targetBundleIdentifier: draft.targetBundleIdentifier) {`.

In `App/Sources/Views/Wizard/WizardSteps.swift` line 205 replace `switch appState.validateDataPath(url.path, targetPath: model.targetURL?.path ?? "", excluding: nil) {` with `switch appState.validateDataPath(url.path, targetPath: model.targetURL?.path ?? "", excluding: nil, targetBundleIdentifier: model.inspected?.bundleIdentifier) {`.

Delete now asks `DeleteConfirmation` first: with the toggle on and a folder outside the data root, the sheet shows the destructive dialog titled "Also move “<folder name>” to the Trash?" (`Move to Trash`, `Cancel`), and `Cancel` trashes nothing; every other delete runs as before. Export asks before writing directly into a library folder: "Export into a library folder?" with the warning text, `Export Anyway` and `Cancel`. When the export replaced an item, the export sheet names the item's Trash location. The two data-folder pickers pass the target's bundle id, so they refuse the target's own data and its current location, as delete does. `ShortcutEditorView.swift`'s `extension URL: @retroactive Identifiable` loses its only use (the old `.sheet(item: $exportedURL)`); it stays, because removing a public conformance is out of scope here.

- [ ] **Step 8: Run the full app suite**

Run: `cd "$REPO" && Tools/test-app.sh 2>&1 | grep -E "Test Case '.*' passed|: warning:|\*\* TEST" | sed -E "s/^Test Case .* passed .*/passed/" | sort | uniq -c`
Expected: exactly two lines, `1 ** TEST SUCCEEDED **` and `146 passed` (133 + 13; the counts are left-padded). Any `: warning:` line names a file to fix before committing.

- [ ] **Step 9: Commit**

```bash
cd "$REPO" && git add App/Sources/Services/TargetResolver+ResolvedPath.swift App/Sources/Services/DeleteConfirmation.swift App/Sources/Services/CanonicalPath.swift App/Sources/Services/DataPathGuard.swift App/Sources/Services/ShortcutBuilder.swift App/Sources/App/AppState.swift App/Sources/Views/DeleteShortcutSheet.swift App/Sources/Views/ExportSheet.swift App/Sources/Views/ShortcutEditorView.swift App/Sources/Views/EditorSections.swift App/Sources/Views/Wizard/WizardSteps.swift App/Tests/Services/DataPathGuardTests.swift App/Tests/Services/ShortcutBuilderTests.swift App/Tests/App/AppStateTests.swift App/Tests/Services/DeleteConfirmationTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16.noreply.github.com" commit -q -F - <<'MSG'
feat(app): widen the data-path guard and harden export and delete

The data-path guard now also refuses every direct child of home, anything
at depth 2 or less outside home (/Users/Shared, /opt/homebrew, a volume
root under /Volumes), a folder that is, contains or is inside a scanned
shortcut bundle, the target's current location as TargetResolver finds
it, and the target's own data in ~/Library (a folder named after the app
or its bundle id). The Phase 2 checks run first and keep their messages
(re-review Minors 1, 2 and 4).

Export checks the resolved target as well as the stored path, sweeps
stale .mad-export staging copies, and moves an item already at the
destination to the Trash only once the copy is staged, putting it back
if the final move fails. The editor asks before exporting directly into
a library folder, and the export sheet names where a replaced item went
(re-review Minor 5). New tests pin case-variant and symlinked export
destinations (re-review Minor 6).

Deleting a data folder outside the data root now takes a second,
destructive confirmation that names the folder (re-review Minor 1, final
review M24).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

