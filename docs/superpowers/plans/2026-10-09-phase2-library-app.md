# macOS App Duplicator Phase 2 (Library App) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the SwiftUI library app "macOS App Duplicator": library scan of shortcut bundles, editor, New wizard, bundle creation through `BundleWriter` + `Signer`, icon modes, Settings, Diagnostics, the in-repo app icon pipeline, and an Xcode project that embeds the Phase 1 `Launcher` binary (spec §7, §7.1, §12 phase 2).

**Architecture:** The app is an Xcode project generated from `App/project.yml` by xcodegen (no workspace; xcodegen cannot emit one, so the spec §3 "one Xcode workspace" is realised as one project that depends on the root SwiftPM package by local path). The app has three layers: `App/Sources/Model` (pure value types + `@Observable` library state), `App/Sources/Services` (thin wrappers over DuplicatorCore, AppKit and `/usr/bin` tools), `App/Sources/Views` (SwiftUI). DuplicatorCore gets three additive changes (icon mode fields on `ShortcutConfig`, an explicit-icon `BundleWriter.write` overload, `ProcessEnvironment` for running-state detection) and nothing else moves out of the Phase 1 package. The Launcher release binary is copied into the app's `Resources/` by a post-build script and loaded at run time with `Bundle.main.url(forResource: "Launcher", withExtension: nil)`.

**Tech Stack:** Swift 6 language mode (Xcode 27.0, Swift 6.4), macOS 26+ arm64, SwiftUI + AppKit (app), Foundation + Darwin (Core), xcodegen 2.45.3 (`/usr/local/bin/xcodegen`), XCTest, `/usr/bin/iconutil`, `/usr/bin/qlmanage`, `/usr/bin/sips`, `/usr/bin/security`, `/usr/bin/codesign`.

## Global Constraints

- Target macOS 26+, Apple Silicon only. Root package stays `swift-tools-version: 6.2`, `swiftLanguageModes: [.v6]`, `platforms: [.macOS(.v26)]`. The Xcode targets build `ARCHS = arm64`, `MACOSX_DEPLOYMENT_TARGET = 26.0`, `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`.
- DuplicatorCore imports Foundation, Security and Darwin only (no AppKit). The app may import AppKit and SwiftUI. XCTest only (no swift-testing). No new `try?` in app code except where the plan shows it; no empty `catch`, no `@unchecked Sendable`, no `swiftlint:disable`.
- Never copy, repackage, patch, inject into or re-sign the target app (spec §2). The only files the app writes are: shortcut bundles under the output folder (or a user-chosen export location), data folders under `~/Library/Application Support/App Duplicator/`, `UserDefaults` of `com.mikekuta.MacAppDuplicator`, and temporary files under `FileManager.default.temporaryDirectory`.
- Secrets never shown or logged unmasked by default: env values whose key matches `SecretMasking.secretKeyPattern` (`(?i)secret|token|key|password|passwd|credential`) are shown as `SecretMasking.maskedValue` (`••••••`) in the editor env table (until the per-row reveal toggle is on), in Diagnostics and in previews (spec §2, §7). The signing identity is referred to by display name only (spec §9); the app never prints certificate hashes.
- Shortcut `Info.plist` keeps the Phase 1 key set; `BundleWriter` still never writes `CFBundleURLTypes`, `CFBundleDocumentTypes`, `UTExportedTypeDeclarations` or `UTImportedTypeDeclarations`. Icons are copied, never symlinked.
- `ShortcutConfig.currentEngineVersion` stays `1` in Phase 2. New `ShortcutConfig` fields decode with defaults so the two existing shortcuts (`~/Applications/App Duplicator/Claude Work.app`, `Claude Personal.app`) still load: `iconMode` → `.copied`, `customIconPath` → nil, `homeSymlinkEntries` → nil.
- Bundle identifier `com.mikekuta.appduplicator.<slug>`; default data path `~/Library/Application Support/App Duplicator/<slug>`; default output `~/Applications/App Duplicator`; logs `~/Library/Logs/App Duplicator/<shortcut name>.log` (Phase 1 `LaunchLogger`).
- App bundle id `com.mikekuta.MacAppDuplicator`, product name and display name `macOS App Duplicator`, `PRODUCT_MODULE_NAME = MacAppDuplicator`, `LSApplicationCategoryType = public.app-category.utilities`, hardened runtime on, App Sandbox off, no entitlements file, no TCC-gated APIs (spec §9).
- UI copy is verbatim from spec §7 where the spec gives it: sidebar sections `Apps`, `Web Apps`, `Files & Folders`, `Commands`; icon modes `Copied from target`, `Custom file`, `Generated tile`; appearance options `Follow System`, `Light`, `Force dark (Chromium/Electron only, best effort)`; actions `Launch`, `Reveal in Finder`, `Regenerate`, `Duplicate`, `Export…`, `Delete`; toolbar `New`, `Rebuild All`; compat badges `Verified`, `Auto`, `HOME only`, `Unsupported`, `Unknown`; signing option `Ad-hoc`.
- Phase 2 implements shortcut kind `.app` only. The wizard shows the other kinds disabled with the hint `Coming in a later phase`. `Check Profile Updates`, the profiles URL setting and `Verified`/`Unsupported` badges are Phase 3; the menu bar icon and new-window command fields are stored but inert until Phase 6 (the editor says so inline).
- Tests never touch `/Applications`, `~/Applications`, the real output folder, the real `UserDefaults` suite or the two Claude shortcuts; every test writes under `makeTemporaryDirectory()` / `FileManager.default.temporaryDirectory` and uses `UserDefaults(suiteName:)` with a unique suite that it removes in `tearDown`. No test launches a shortcut or a target app.
- Every commit message ends with the line `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Repository `/Users/cubbieblue16/Developer/MacAppDuplicator`, branch `main`. Commit identity `git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com"`.
- Additive-only toward Phase 1: no existing public symbol, test or behaviour is removed or weakened. New Core API goes next to the existing files.
- Build-system conventions: `App/MacAppDuplicator.xcodeproj` is generated and git-ignored; `Tools/build-app.sh` and `Tools/test-app.sh` are the only documented ways to build and test the app. All `xcodebuild` runs use `-derivedDataPath .build/DerivedData` and `-destination 'platform=macOS,arch=arm64'`.

## Inputs and conventions

- `$REPO` = `/Users/cubbieblue16/Developer/MacAppDuplicator`. All commands run from `$REPO`. The shell's cwd does not persist between tool calls; prefix every command with `cd "$REPO" &&`.
- Phase 1 API consumed (all in `DuplicatorCore`, see README "Phase 2 consumes"): `ShortcutConfig` (statics `currentEngineVersion`, `infoPlistKey = "MADConfig"`, `engineVersionInfoPlistKey = "MADEngineVersion"`, `bundleIdentifierPrefix`, `slug(for:)`, `bundleIdentifier(forSlug:)`, `defaultDataPath(forSlug:home:)`, `fileSystemName(for:)`, `plistDictionary()`, `init(plistDictionary:)`), `AppInspector().inspect(appAt:) throws -> InspectedApp` (`bundleURL`, `bundleIdentifier`, `name`, `version`, `executableURL`, `family: AppFamily`, `isSandboxed`, `iconFileURL: URL?`, `isPlatformBinary`, `hasLaunchConstraints`, `lsEnvironment`, `warnings`), `BundleWriter(fileManager:).write(config:app:launcherBinary:to:) throws -> URL`, `Signer().sign(bundle:identity: String?) throws` (nil = ad hoc; non-nil adds `--options runtime --timestamp`), `DataSeparationPlanner().plan(app:config:baseEnvironment:shortcutBundleURL:) -> LaunchPlan` (`executableURL`, `arguments`, `environment`, `directoriesToCreate`, `homeOverridePath`, `warnings`, `launchMode`), `DataSeparationPlanner.shortcutBundleKey = "MAD_SHORTCUT_BUNDLE"`, `HomeTreeBuilder.defaultSymlinkEntries`, `SecretMasking.mask(_:)`, `SecretMasking.isSecretKey(_:)`, `SecretMasking.maskedValue`, `LaunchLogger(name:).fileURL`, `LauncherError` (`configMissing`, `configCorrupt(String)`, `targetNotFound(path:bundleID:)`, `dataPathNotWritable(String)`, `execFailed(errno:path:)`, `notAnAppBundle(String)`), enums `ShortcutKind {app, webApp, file, folder, cli}`, `LaunchMode {dockShortcut, systemLaunch}`, `DataMode {auto, homeOverride, disabled}`, `Appearance {system, light, dark}`, `AppFamily {todesktop, electron, chromium, firefox, eclipse, native}`.
- Test helpers in `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/TestSupport.swift`: `makeTemporaryDirectory() throws -> URL`, `runCommand(_ path: String, _ arguments: [String]) throws -> CommandResult` (`status`, `stdout`, `stderr`), `FixtureBundle(name:bundleIdentifier:info:files:directories:)` with `write(in:) throws -> URL` and `writeSigned(in:extraCodesignArguments:) throws -> URL`, `writePropertyList(_:named:in:)`.
- The fixture app: `Tools/build-fixture.sh` builds `.build/fixtures/FixtureApp.app` (ad hoc signed, bundle id `com.mikekuta.appduplicator.fixture`). The app's end-to-end test (Task 9) uses it and skips with `XCTSkip` when it is absent.
- Signing identities present on this Mac (names only): `Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)`, `Apple Development: 152761714+cubbieblue16@users.noreply.github.com (GZHS2TWCRJ)`. `security find-identity -v -p codesigning` lists one revoked duplicate marked `(CSSMERR_TP_CERT_REVOKED)`; the parser drops such lines.
- `rsvg-convert` and ImageMagick are NOT installed; `/usr/bin/qlmanage -t -s 1024 -o <dir> <file>.svg` renders `<dir>/<file>.svg.png` (1024×1024, alpha preserved, linear gradients and opacity honoured). `/usr/bin/sips -z H W in.png --out out.png` downsamples. `/usr/bin/iconutil -c icns <X>.iconset -o <X>.icns` builds the icns.

## File map

| Path | Responsibility | Task |
|---|---|---|
| `Packages/DuplicatorCore/Sources/DuplicatorCore/{Enums,ShortcutConfig,BundleWriter,LaunchPreparer,ProcessEnvironment}.swift` + tests | Icon-mode fields, explicit-icon write overload, symlink list wiring, process environment lookup | 1 |
| `App/Icon/AppIcon.svg`, `Tools/make-icons.sh`, `App/Resources/AppIcon.icns`, `App/Resources/Assets.xcassets/AppIcon.appiconset/*` | Replicator app icon and its build pipeline | 2 |
| `App/project.yml`, `App/Sources/App/MacAppDuplicatorApp.swift`, `App/Sources/App/ContentView.swift` (placeholder), `App/Tests/SmokeTests.swift`, `Tools/build-app.sh`, `Tools/test-app.sh`, `.gitignore` | Xcode project, Launcher embedding, build/test scripts | 3 |
| `App/Sources/Model/{ShortcutRecord,LibraryScanner,FolderWatcher,RunningShortcutMonitor,ShortcutLibrary,AppSettings}.swift` + `App/Tests/Model/*` | Library state | 4 |
| `App/Sources/Services/{SigningIdentities,IconRenderer,IconResolver,ShortcutBuilder,InstalledApps,LogReader,CompatBadge,LaunchPlanPreview,AppLauncher}.swift` + `App/Tests/Services/*` | Core/AppKit/tool wrappers | 5 |
| `App/Sources/Views/{ContentView,SidebarView,ShortcutRowView,ShortcutEditorView,EditorSections.swift,EnvironmentTableView,ExportSheet,DeleteShortcutSheet,RebuildAllSheet}.swift`, `App/Sources/App/AppState.swift` | Sidebar, editor, actions, Rebuild All | 6 |
| `App/Sources/Views/Wizard/{NewShortcutWizard,WizardModel,WizardSteps,InstalledAppsGrid,AppDropZone}.swift` + `App/Tests/Wizard/*` | New wizard, drag-and-drop | 7 |
| `App/Sources/Views/{SettingsView,DiagnosticsView,KnownLimitationsView,HomeSymlinkListEditor}.swift`, `App/Sources/App/KnownLimitations.swift` + `App/Tests/App/{KnownLimitations,DiagnosticsModel}Tests.swift` | Settings, Diagnostics, Help window | 8 |
| `App/Tests/EndToEnd/ShortcutBuilderEndToEndTests.swift`, `docs/acceptance/phase2-library-app.md`, `README.md` | End-to-end test, acceptance checklist, docs | 9 |

---

### Task 1: DuplicatorCore additions (icon mode, explicit icon write, symlink list, process environment)

**Files:**
- Modify: `Packages/DuplicatorCore/Sources/DuplicatorCore/Enums.swift`
- Modify: `Packages/DuplicatorCore/Sources/DuplicatorCore/ShortcutConfig.swift`
- Modify: `Packages/DuplicatorCore/Sources/DuplicatorCore/BundleWriter.swift`
- Modify: `Packages/DuplicatorCore/Sources/DuplicatorCore/LaunchPreparer.swift:57`
- Create: `Packages/DuplicatorCore/Sources/DuplicatorCore/ProcessEnvironment.swift`
- Test: `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/ShortcutConfigTests.swift` (add), `BundleWriterTests.swift` (add), `LaunchPreparerTests.swift` (add), create `ProcessEnvironmentTests.swift`

**Interfaces:**
- Consumes: Phase 1 Core as listed in "Inputs and conventions".
- Produces (used by Tasks 4, 5, 6, 9):
  - `public enum IconMode: String, Codable, Sendable { case copied, custom, generated }`
  - `ShortcutConfig.iconMode: IconMode`, `ShortcutConfig.customIconPath: String?`, `ShortcutConfig.homeSymlinkEntries: [String]?`; init gains `iconMode: IconMode = .copied, customIconPath: String? = nil, homeSymlinkEntries: [String]? = nil` (placed before `engineVersion`); `ShortcutConfig` becomes `Hashable`.
  - `BundleWriter.write(config:app:launcherBinary:iconFile: URL?, to:) throws -> URL`.
  - `public enum ProcessEnvironment` with `static func environment(ofProcess pid: pid_t) -> [String: String]?`, `static func allProcessIDs() -> [pid_t]`, `static func values(forEnvironmentKey key: String) -> [pid_t: String]`, `static func processIDs(whereEnvironment key: String, equals value: String) -> [pid_t]`.

- [ ] **Step 1: Add `IconMode` to `Enums.swift`**

Append to `Packages/DuplicatorCore/Sources/DuplicatorCore/Enums.swift`:

```swift

/// How a shortcut's icon is produced (spec §7, Identity section).
/// `copied` copies the target's icon, `custom` converts the file at `ShortcutConfig.customIconPath`,
/// `generated` renders a tile with the shortcut's initials.
public enum IconMode: String, Codable, Sendable { case copied, custom, generated }
```

- [ ] **Step 2: Write the failing `ShortcutConfig` tests**

Append inside `final class ShortcutConfigTests` in `ShortcutConfigTests.swift`:

```swift
    func testIconFieldsRoundTrip() throws {
        var config = makeConfig()
        config.iconMode = .custom
        config.customIconPath = "/Users/test/Pictures/work.png"
        config.homeSymlinkEntries = ["Desktop", ".ssh"]
        let decoded = try ShortcutConfig(plistDictionary: config.plistDictionary())
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.iconMode, .custom)
        XCTAssertEqual(decoded.customIconPath, "/Users/test/Pictures/work.png")
        XCTAssertEqual(decoded.homeSymlinkEntries, ["Desktop", ".ssh"])
    }

    func testEngineVersion1PlistWithoutIconFieldsDecodesWithDefaults() throws {
        // A Phase 1 MADConfig dictionary: no iconMode, customIconPath or homeSymlinkEntries keys.
        let legacy: [String: Any] = [
            "kind": "app", "name": "Claude Work", "slug": "claude-work",
            "bundleIdentifier": "com.mikekuta.appduplicator.claude-work",
            "targetPath": "/Applications/Claude.app", "targetBundleIdentifier": "com.anthropic.claudefordesktop",
            "launchMode": "dockShortcut", "dataMode": "auto",
            "environment": [String: String](), "arguments": [String](),
            "appearance": "system", "eraseOnQuit": false, "menuBarIcon": false, "engineVersion": 1,
        ]
        let config = try ShortcutConfig(plistDictionary: legacy)
        XCTAssertEqual(config.iconMode, .copied)
        XCTAssertNil(config.customIconPath)
        XCTAssertNil(config.homeSymlinkEntries)
        XCTAssertEqual(config.name, "Claude Work")
    }

    func testDefaultIconModeIsCopiedAndNilOptionalsAreOmitted() {
        let config = makeConfig()
        XCTAssertEqual(config.iconMode, .copied)
        let dictionary = config.plistDictionary()
        XCTAssertEqual(dictionary["iconMode"] as? String, "copied")
        XCTAssertNil(dictionary["customIconPath"])
        XCTAssertNil(dictionary["homeSymlinkEntries"])
    }

    func testConfigIsHashable() {
        let set: Set<ShortcutConfig> = [makeConfig(), makeConfig()]
        XCTAssertEqual(set.count, 1)
    }
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd "$REPO" && swift test --filter ShortcutConfigTests 2>&1 | tail -15`
Expected: compile errors `value of type 'ShortcutConfig' has no member 'iconMode'` and `type 'ShortcutConfig' does not conform to protocol 'Hashable'`.

- [ ] **Step 4: Implement the `ShortcutConfig` changes**

In `ShortcutConfig.swift`:

1. Change the declaration line to `public struct ShortcutConfig: Codable, Hashable, Sendable {`.
2. After `public var menuBarIcon: Bool` add:

```swift
    /// Icon source for the shortcut bundle (spec §7). Default `.copied`.
    public var iconMode: IconMode
    /// Image file converted to the bundle icon when `iconMode == .custom` (PNG, JPEG, TIFF or ICNS).
    public var customIconPath: String?
    /// HOME-override symlink list override; nil means `HomeTreeBuilder.defaultSymlinkEntries` (spec §4.3, §7 Settings).
    public var homeSymlinkEntries: [String]?
```

3. In `public init(...)` add the three parameters between `menuBarIcon: Bool = false,` and `engineVersion: Int = ShortcutConfig.currentEngineVersion`:

```swift
        iconMode: IconMode = .copied,
        customIconPath: String? = nil,
        homeSymlinkEntries: [String]? = nil,
```

and the assignments `self.iconMode = iconMode`, `self.customIconPath = customIconPath`, `self.homeSymlinkEntries = homeSymlinkEntries` before `self.engineVersion = engineVersion`.

4. Add explicit coding keys and a decoder that tolerates Phase 1 dictionaries (place after the memberwise init, before `plistDictionary()`):

```swift
    private enum CodingKeys: String, CodingKey {
        case kind, name, slug, bundleIdentifier, targetPath, targetBundleIdentifier, launchMode, dataMode, dataPath
        case environment, arguments, appearance, languageCode, eraseOnQuit, menuBarIcon
        case iconMode, customIconPath, homeSymlinkEntries, engineVersion
    }

    /// Decodes Phase 1 dictionaries too: `iconMode`, `customIconPath` and `homeSymlinkEntries` are optional on input.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(ShortcutKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        slug = try container.decode(String.self, forKey: .slug)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        targetPath = try container.decode(String.self, forKey: .targetPath)
        targetBundleIdentifier = try container.decode(String.self, forKey: .targetBundleIdentifier)
        launchMode = try container.decode(LaunchMode.self, forKey: .launchMode)
        dataMode = try container.decode(DataMode.self, forKey: .dataMode)
        dataPath = try container.decodeIfPresent(String.self, forKey: .dataPath)
        environment = try container.decode([String: String].self, forKey: .environment)
        arguments = try container.decode([String].self, forKey: .arguments)
        appearance = try container.decode(Appearance.self, forKey: .appearance)
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
        eraseOnQuit = try container.decode(Bool.self, forKey: .eraseOnQuit)
        menuBarIcon = try container.decode(Bool.self, forKey: .menuBarIcon)
        iconMode = try container.decodeIfPresent(IconMode.self, forKey: .iconMode) ?? .copied
        customIconPath = try container.decodeIfPresent(String.self, forKey: .customIconPath)
        homeSymlinkEntries = try container.decodeIfPresent([String].self, forKey: .homeSymlinkEntries)
        engineVersion = try container.decode(Int.self, forKey: .engineVersion)
    }
```

Encoding stays synthesized (the explicit `CodingKeys` keep the key names unchanged; `PropertyListEncoder` omits nil optionals).

- [ ] **Step 5: Run the `ShortcutConfig` tests**

Run: `cd "$REPO" && swift test --filter ShortcutConfigTests 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures` (N = previous count + 4).

- [ ] **Step 6: Write the failing `BundleWriter` tests**

Append inside `final class BundleWriterTests` in `BundleWriterTests.swift`:

```swift
    func testExplicitIconFileWinsOverTargetIcon() throws {
        let fixture = try makeFixture(withIcon: true)
        let custom = fixture.output.appending(path: "custom.icns", directoryHint: .notDirectory)
        try Data([9, 9, 9, 9]).write(to: custom)

        let bundle = try BundleWriter().write(config: config(), app: fixture.app, launcherBinary: fixture.launcher, iconFile: custom, to: fixture.output)

        let icon = bundle.appending(path: "Contents/Resources/AppIcon.icns", directoryHint: .notDirectory)
        XCTAssertEqual(try Data(contentsOf: icon), Data([9, 9, 9, 9]))
        let info = try XCTUnwrap(NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist")) as? [String: Any])
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "AppIcon")
    }

    func testNilIconFileWritesNoIconEvenWhenTargetHasOne() throws {
        let fixture = try makeFixture(withIcon: true)

        let bundle = try BundleWriter().write(config: config(), app: fixture.app, launcherBinary: fixture.launcher, iconFile: nil, to: fixture.output)

        XCTAssertFalse(fileManager.fileExists(atPath: bundle.appending(path: "Contents/Resources/AppIcon.icns").path))
        let info = try XCTUnwrap(NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist")) as? [String: Any])
        XCTAssertNil(info["CFBundleIconFile"])
    }

    func testFourArgumentWriteStillCopiesTargetIcon() throws {
        let fixture = try makeFixture(withIcon: true)
        let bundle = try BundleWriter().write(config: config(), app: fixture.app, launcherBinary: fixture.launcher, to: fixture.output)
        let icon = bundle.appending(path: "Contents/Resources/AppIcon.icns", directoryHint: .notDirectory)
        XCTAssertEqual(try Data(contentsOf: icon), Data([1, 2, 3]))
    }
```

- [ ] **Step 7: Run them to verify failure**

Run: `cd "$REPO" && swift test --filter BundleWriterTests 2>&1 | tail -8`
Expected: compile error `extra argument 'iconFile' in call`.

- [ ] **Step 8: Add the `iconFile:` overload to `BundleWriter`**

Replace the existing `write(config:app:launcherBinary:to:)` doc comment and function with:

```swift
    /// Writes `<directory>/<Name>.app`, replacing an existing bundle of that name, and returns its URL.
    /// `launcherBinary` is copied to `Contents/MacOS/<Name>`; the target's icon file is copied (never symlinked)
    /// to `Contents/Resources/AppIcon.icns`.
    public func write(config: ShortcutConfig, app: InspectedApp, launcherBinary: URL, to directory: URL) throws -> URL {
        try write(config: config, app: app, launcherBinary: launcherBinary, iconFile: app.iconFileURL, to: directory)
    }

    /// Same as `write(config:app:launcherBinary:to:)` with an explicit icon: `iconFile` (any `.icns`, or nil for no icon)
    /// is copied to `Contents/Resources/AppIcon.icns` instead of the target's icon. The library app passes the result of
    /// its icon mode (copied / custom / generated) here.
    public func write(config: ShortcutConfig, app: InspectedApp, launcherBinary: URL, iconFile: URL?, to directory: URL) throws -> URL {
```

and inside the body change the icon block to:

```swift
            var hasIcon = false
            if let icon = iconFile, fileManager.fileExists(atPath: icon.path) {
                // Data(contentsOf:) follows symlinks, so the bundle always gets a regular-file copy.
                try Data(contentsOf: icon).write(to: resources.appending(path: "AppIcon.icns", directoryHint: .notDirectory))
                hasIcon = true
            }
```

Everything else in the body is unchanged.

- [ ] **Step 9: Run the `BundleWriter` tests**

Run: `cd "$REPO" && swift test --filter BundleWriterTests 2>&1 | tail -5`
Expected: `0 failures`.

- [ ] **Step 10: Write the failing `LaunchPreparer` symlink-list test**

Append inside `final class LaunchPreparerTests` in `LaunchPreparerTests.swift`:

```swift
    func testHomeOverrideUsesConfigSymlinkEntries() throws {
        let fixture = try makeFixture()
        try fileManager.createDirectory(at: fixture.realHome.appending(path: "Desktop", directoryHint: .isDirectory), withIntermediateDirectories: true)
        let home = fixture.root.appending(path: "home", directoryHint: .isDirectory)
        var shortcut = config(for: fixture, dataMode: .homeOverride, dataPath: home.path)
        shortcut.homeSymlinkEntries = ["Desktop"]

        _ = try prepare(fixture, ["MADConfig": shortcut.plistDictionary()])

        let desktop = home.appending(path: "Desktop", directoryHint: .notDirectory)
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: desktop.path), fixture.realHome.appending(path: "Desktop").path)
        XCTAssertFalse(fileManager.fileExists(atPath: home.appending(path: "Documents").path), "Documents is not in the config's list")
    }
```

- [ ] **Step 11: Run it to verify failure**

Run: `cd "$REPO" && swift test --filter LaunchPreparerTests/testHomeOverrideUsesConfigSymlinkEntries 2>&1 | tail -8`
Expected: FAIL on the `Documents` assertion (the default list still links it).

- [ ] **Step 12: Wire the list in `LaunchPreparer`**

In `LaunchPreparer.swift` line 57 replace

```swift
                let effectiveHome = try HomeTreeBuilder(fileManager: fileManager, realHome: realHome).materialize(at: home)
```

with

```swift
                let symlinkEntries = config.homeSymlinkEntries ?? HomeTreeBuilder.defaultSymlinkEntries
                let effectiveHome = try HomeTreeBuilder(fileManager: fileManager, realHome: realHome, symlinkEntries: symlinkEntries)
                    .materialize(at: home)
```

(`config` is the decoded `ShortcutConfig` already in scope in `prepare`; if the local is named differently, use that name.)

- [ ] **Step 13: Run the preparer tests**

Run: `cd "$REPO" && swift test --filter LaunchPreparerTests 2>&1 | tail -5`
Expected: `0 failures`.

- [ ] **Step 14: Write the failing `ProcessEnvironment` tests**

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/ProcessEnvironmentTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore

final class ProcessEnvironmentTests: XCTestCase {
    private let markerKey = "MAD_TEST_MARKER"

    override func tearDown() {
        unsetenv(markerKey)
        super.tearDown()
    }

    func testReadsOwnEnvironment() throws {
        let value = "marker-\(UUID().uuidString)"
        setenv(markerKey, value, 1)

        let environment = try XCTUnwrap(ProcessEnvironment.environment(ofProcess: getpid()))

        XCTAssertEqual(environment[markerKey], value)
        XCTAssertNotNil(environment["PATH"])
    }

    func testUnknownProcessReturnsNil() {
        // pid_t.max is never a live process id.
        XCTAssertNil(ProcessEnvironment.environment(ofProcess: pid_t.max))
    }

    func testAllProcessIDsContainsSelf() {
        XCTAssertTrue(ProcessEnvironment.allProcessIDs().contains(getpid()))
    }

    func testFindsProcessesByEnvironmentValue() {
        let value = "marker-\(UUID().uuidString)"
        setenv(markerKey, value, 1)

        XCTAssertEqual(ProcessEnvironment.processIDs(whereEnvironment: markerKey, equals: value), [getpid()])
        XCTAssertEqual(ProcessEnvironment.values(forEnvironmentKey: markerKey)[getpid()], value)
        XCTAssertTrue(ProcessEnvironment.processIDs(whereEnvironment: markerKey, equals: "other").isEmpty)
    }
}
```

- [ ] **Step 15: Run them to verify failure**

Run: `cd "$REPO" && swift test --filter ProcessEnvironmentTests 2>&1 | tail -5`
Expected: compile error `cannot find 'ProcessEnvironment' in scope`.

- [ ] **Step 16: Implement `ProcessEnvironment`**

Create `Packages/DuplicatorCore/Sources/DuplicatorCore/ProcessEnvironment.swift`:

```swift
import Darwin
import Foundation

/// Reads other processes' environments through `sysctl(KERN_PROCARGS2)`. Used by the library app to show the
/// running indicator: after LaunchServices check-in a shortcut's process reports the target's bundle, so the only
/// durable marker is `MAD_SHORTCUT_BUNDLE` in its environment (spec §4.4, §7). Only same-user, unrestricted processes
/// are readable; everything else is skipped.
public enum ProcessEnvironment {
    /// The environment of `pid`, or nil when the kernel refuses (foreign user, exited, restricted) or the buffer is malformed.
    /// Entries after the environment block (the loader's `executable_path=` and similar) are included; they never
    /// collide with `MAD_*` keys.
    public static func environment(ofProcess pid: pid_t) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        buffer.removeSubrange(size...)

        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = MemoryLayout<Int32>.size

        func nextString() -> String? {
            guard index < buffer.count else { return nil }
            var end = index
            while end < buffer.count, buffer[end] != 0 { end += 1 }
            let string = String(decoding: buffer[index..<end], as: UTF8.self)
            index = end + 1
            return string
        }

        // Layout: argc, executable path, NUL padding, argv[0..<argc], then "KEY=VALUE" strings.
        guard nextString() != nil else { return nil }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        for _ in 0..<max(argc, 0) {
            guard nextString() != nil else { return nil }
        }

        var environment: [String: String] = [:]
        while let entry = nextString() {
            guard !entry.isEmpty, let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            // First occurrence wins, matching how libc resolves duplicate names.
            if environment[key] == nil {
                environment[key] = String(entry[entry.index(after: equals)...])
            }
        }
        return environment
    }

    /// Every live process id, via `proc_listpids(PROC_ALL_PIDS)`. Zero entries are dropped.
    public static func allProcessIDs() -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        // Leave headroom for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size + 64)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    /// One scan over all readable processes: pid → value of `key` for every process that has it.
    public static func values(forEnvironmentKey key: String) -> [pid_t: String] {
        var result: [pid_t: String] = [:]
        for pid in allProcessIDs() {
            if let value = environment(ofProcess: pid)?[key] {
                result[pid] = value
            }
        }
        return result
    }

    /// Processes whose environment has `key == value`, ascending by pid.
    public static func processIDs(whereEnvironment key: String, equals value: String) -> [pid_t] {
        values(forEnvironmentKey: key).filter { $0.value == value }.map(\.key).sorted()
    }
}
```

- [ ] **Step 17: Run the whole Core suite**

Run: `cd "$REPO" && swift test 2>&1 | grep -E 'Executed|error:' | tail -5`
Expected: one `Executed N tests, with 0 failures` line for DuplicatorCoreTests with N = 98 + 12 = 110 (the IntegrationTests target reports its own skipped tests), no `error:` lines.

- [ ] **Step 18: Commit**

```bash
cd "$REPO" && git add Packages/DuplicatorCore && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -q -F - <<'MSG'
feat(core): icon mode fields, explicit-icon write, symlink list wiring, ProcessEnvironment

ShortcutConfig gains iconMode/customIconPath/homeSymlinkEntries with
tolerant decoding so Phase 1 shortcuts still load. BundleWriter.write
takes an explicit iconFile. LaunchPreparer honours the config's symlink
list. ProcessEnvironment reads MAD_SHORTCUT_BUNDLE from running
processes for the library app's running indicator.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 2: App icon "Replicator" and icon pipeline

**Files:**
- Create: `App/Icon/AppIcon.svg`
- Create: `Tools/make-icons.sh`
- Create (generated, committed): `App/Resources/AppIcon.icns`, `App/Resources/Assets.xcassets/Contents.json`, `App/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` + 10 PNGs

**Interfaces:**
- Consumes: nothing from code.
- Produces: `App/Resources/Assets.xcassets` (asset catalog with `AppIcon`) consumed by Task 3's `project.yml` (`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`), `App/Resources/AppIcon.icns` (used by Task 8 Diagnostics "about" header and by the README).

- [ ] **Step 1: Write the SVG**

Create `App/Icon/AppIcon.svg` exactly (spec §7.1: squircle, `#1B1540` → `#4A2DB8` vertical gradient, back violet glass tile, front frosted white tile with 1.5 pt cyan rim `#5EF0FF`, thin cyan scan-ring arcs behind, no text; no filters or clip paths because `qlmanage` rasterises those unreliably):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#1B1540"/>
      <stop offset="1" stop-color="#4A2DB8"/>
    </linearGradient>
    <linearGradient id="backTile" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#8A6CFF" stop-opacity="0.55"/>
      <stop offset="1" stop-color="#5A3FD6" stop-opacity="0.35"/>
    </linearGradient>
    <linearGradient id="frontTile" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.92"/>
      <stop offset="1" stop-color="#E6F6FF" stop-opacity="0.78"/>
    </linearGradient>
    <linearGradient id="frontSheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.9"/>
      <stop offset="0.55" stop-color="#FFFFFF" stop-opacity="0.0"/>
    </linearGradient>
  </defs>

  <!-- macOS squircle: 824 pt body inside the 1024 canvas, 100 pt margin -->
  <rect x="100" y="100" width="824" height="824" rx="186" ry="186" fill="url(#bg)"/>

  <!-- scan ring: three cyan arcs behind the tiles -->
  <g fill="none" stroke="#5EF0FF" stroke-width="6" stroke-linecap="round" opacity="0.6">
    <circle cx="512" cy="512" r="330" stroke-dasharray="520 1553" transform="rotate(-30 512 512)"/>
    <circle cx="512" cy="512" r="330" stroke-dasharray="300 1773" transform="rotate(130 512 512)"/>
    <circle cx="512" cy="512" r="330" stroke-dasharray="140 1933" transform="rotate(230 512 512)"/>
  </g>
  <circle cx="512" cy="512" r="330" fill="none" stroke="#5EF0FF" stroke-width="2" opacity="0.18"/>

  <!-- back tile: violet glass, offset up-right -->
  <rect x="380" y="260" width="400" height="400" rx="88" ry="88" fill="url(#backTile)" stroke="#B9A8FF" stroke-opacity="0.45" stroke-width="4"/>
  <rect x="396" y="276" width="368" height="368" rx="76" ry="76" fill="none" stroke="#FFFFFF" stroke-opacity="0.18" stroke-width="3"/>

  <!-- front tile: frosted white glass with cyan rim -->
  <rect x="244" y="364" width="400" height="400" rx="88" ry="88" fill="url(#frontTile)" stroke="#5EF0FF" stroke-width="10"/>
  <rect x="262" y="382" width="364" height="364" rx="74" ry="74" fill="none" stroke="#FFFFFF" stroke-opacity="0.6" stroke-width="3"/>
  <rect x="262" y="382" width="364" height="190" rx="74" ry="74" fill="url(#frontSheen)"/>
</svg>
```

- [ ] **Step 2: Write `Tools/make-icons.sh`**

```bash
#!/bin/bash
# Renders App/Icon/AppIcon.svg to App/Resources/AppIcon.icns and the AppIcon.appiconset.
# Uses rsvg-convert when installed, otherwise /usr/bin/qlmanage + /usr/bin/sips (both ship with macOS).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$REPO/App/Icon/AppIcon.svg"
RES="$REPO/App/Resources"
APPICONSET="$RES/Assets.xcassets/AppIcon.appiconset"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mad-icons.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

MASTER="$WORK/master-1024.png"
if command -v rsvg-convert >/dev/null 2>&1; then
  rsvg-convert -w 1024 -h 1024 -o "$MASTER" "$SVG"
else
  # qlmanage writes <dir>/<basename>.png; the result keeps the SVG's alpha channel.
  /usr/bin/qlmanage -t -s 1024 -o "$WORK" "$SVG" >/dev/null 2>&1
  mv "$WORK/$(basename "$SVG").png" "$MASTER"
fi

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET" "$APPICONSET" "$RES"

# name:pixels pairs for the iconset (iconutil) and the asset catalog (same PNGs).
declare -a ENTRIES=(
  "icon_16x16:16" "icon_16x16@2x:32"
  "icon_32x32:32" "icon_32x32@2x:64"
  "icon_128x128:128" "icon_128x128@2x:256"
  "icon_256x256:256" "icon_256x256@2x:512"
  "icon_512x512:512" "icon_512x512@2x:1024"
)
for entry in "${ENTRIES[@]}"; do
  name="${entry%%:*}"; px="${entry##*:}"
  if [ "$px" = "1024" ]; then
    cp "$MASTER" "$ICONSET/$name.png"
  else
    /usr/bin/sips -z "$px" "$px" "$MASTER" --out "$ICONSET/$name.png" >/dev/null
  fi
  cp "$ICONSET/$name.png" "$APPICONSET/$name.png"
done

/usr/bin/iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"

cat > "$APPICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

cat > "$RES/Assets.xcassets/Contents.json" <<'JSON'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "wrote $RES/AppIcon.icns and $APPICONSET"
```

Then: `chmod +x Tools/make-icons.sh`.

- [ ] **Step 3: Run it and verify the outputs**

Run: `cd "$REPO" && Tools/make-icons.sh && ls App/Resources/Assets.xcassets/AppIcon.appiconset | wc -l && /usr/bin/sips -g pixelWidth -g pixelHeight -g hasAlpha App/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png && /usr/bin/iconutil -c iconset App/Resources/AppIcon.icns -o /tmp/mad-check.iconset && ls /tmp/mad-check.iconset | wc -l && rm -rf /tmp/mad-check.iconset`
Expected: `wrote …`, then `11` (10 PNGs + Contents.json), `pixelWidth: 1024`, `pixelHeight: 1024`, `hasAlpha: yes`, then `10`.

- [ ] **Step 4: Visual check**

Run: `cd "$REPO" && cp App/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png "$TMPDIR/mad-icon-preview.png" && echo "$TMPDIR/mad-icon-preview.png"`
The controller (not the implementer) views the PNG. Acceptance: dark indigo squircle, two overlapping rounded tiles, front one white with a visible cyan rim, faint cyan arcs; corners transparent (not black). If the corners are opaque black, `qlmanage` dropped alpha: re-run with `rsvg-convert` after `brew install librsvg`, or report BLOCKED.

- [ ] **Step 5: Commit**

```bash
cd "$REPO" && git add App/Icon App/Resources Tools/make-icons.sh && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -q -F - <<'MSG'
feat(app): Replicator app icon and make-icons.sh pipeline

SVG source plus a script that renders it with rsvg-convert or the
qlmanage/sips fallback, builds the .icns with iconutil and fills the
AppIcon.appiconset. Rendered assets are committed so the Xcode build
does not depend on the renderer.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 3: Xcode project scaffold, Launcher embedding, build and test scripts

**Files:**
- Create: `App/project.yml`
- Create: `App/Sources/App/MacAppDuplicatorApp.swift`
- Create: `App/Sources/App/ContentView.swift` (placeholder, replaced in Task 6)
- Create: `App/Tests/SmokeTests.swift`
- Create: `Tools/build-app.sh`, `Tools/test-app.sh`
- Modify: `.gitignore` (add `/App/MacAppDuplicator.xcodeproj/`)

**Interfaces:**
- Consumes: Task 2 asset catalog; root package product `DuplicatorCore`; `.build/release/Launcher`.
- Produces: `Tools/build-app.sh [--identity NAME] [--configuration Debug|Release]` → prints the built `.app` path; `Tools/test-app.sh` → runs the `MacAppDuplicatorTests` bundle; the app module `MacAppDuplicator` (`@testable import MacAppDuplicator` in tests); `EmbeddedLauncher.url` for Task 5.

- [ ] **Step 1: Write `App/project.yml`**

```yaml
name: MacAppDuplicator
options:
  bundleIdPrefix: com.mikekuta
  deploymentTarget:
    macOS: "26.0"
  createIntermediateGroups: true
  generateEmptyDirectories: true
  xcodeVersion: "27.0"

packages:
  DuplicatorCore:
    path: ..

settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    ARCHS: arm64
    ONLY_ACTIVE_ARCH: YES
    MACOSX_DEPLOYMENT_TARGET: "26.0"
    CODE_SIGN_STYLE: Manual
    CODE_SIGN_IDENTITY: "-"
    ENABLE_HARDENED_RUNTIME: YES
    ENABLE_APP_SANDBOX: NO
    DEAD_CODE_STRIPPING: YES
    SWIFT_TREAT_WARNINGS_AS_ERRORS: NO

targets:
  MacAppDuplicator:
    type: application
    platform: macOS
    sources:
      - path: Sources
      - path: Resources
    dependencies:
      - package: DuplicatorCore
        product: DuplicatorCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.mikekuta.MacAppDuplicator
        PRODUCT_NAME: "macOS App Duplicator"
        PRODUCT_MODULE_NAME: MacAppDuplicator
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: ""
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_CFBundleDisplayName: "macOS App Duplicator"
        INFOPLIST_KEY_LSApplicationCategoryType: public.app-category.utilities
        INFOPLIST_KEY_NSHumanReadableCopyright: "© 2026 Cubbieblue16"
        INFOPLIST_KEY_NSPrincipalClass: NSApplication
        INFOPLIST_KEY_NSMainStoryboardFile: ""
        CURRENT_PROJECT_VERSION: "1"
        MARKETING_VERSION: "0.2.0"
        SWIFT_EMIT_LOC_STRINGS: YES
    info:
      path: Resources/Info.plist
      properties:
        CFBundleName: "App Duplicator"
        CFBundleDisplayName: "macOS App Duplicator"
        LSMinimumSystemVersion: "26.0"
        LSApplicationCategoryType: public.app-category.utilities
        NSHighResolutionCapable: true
        NSSupportsAutomaticTermination: false
        NSSupportsSuddenTermination: false
    postBuildScripts:
      - name: Embed Launcher
        shell: /bin/bash
        inputFiles:
          - "$(SRCROOT)/../.build/release/Launcher"
        outputFiles:
          - "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/Launcher"
        script: |
          set -euo pipefail
          LAUNCHER_SRC="${SRCROOT}/../.build/release/Launcher"
          if [ ! -x "$LAUNCHER_SRC" ]; then
            env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin xcrun swift build -c release --product Launcher --package-path "${SRCROOT}/.."
          fi
          DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Launcher"
          mkdir -p "$(dirname "$DEST")"
          cp -f "$LAUNCHER_SRC" "$DEST"
          chmod 755 "$DEST"
          if [ "${EXPANDED_CODE_SIGN_IDENTITY:--}" = "-" ] || [ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
            codesign --force --sign - "$DEST"
          else
            codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp "$DEST"
          fi

  MacAppDuplicatorTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: Tests
    dependencies:
      - target: MacAppDuplicator
      - package: DuplicatorCore
        product: DuplicatorCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.mikekuta.MacAppDuplicatorTests
        GENERATE_INFOPLIST_FILE: YES
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/macOS App Duplicator.app/Contents/MacOS/macOS App Duplicator"
        BUNDLE_LOADER: "$(TEST_HOST)"

schemes:
  MacAppDuplicator:
    build:
      targets:
        MacAppDuplicator: all
        MacAppDuplicatorTests: [test]
    run:
      config: Debug
    test:
      config: Debug
      gatherCoverageData: false
      targets:
        - MacAppDuplicatorTests
```

Notes for the implementer: xcodegen's `info:` block writes `App/Resources/Info.plist` on generate; because `GENERATE_INFOPLIST_FILE` is also on, Xcode merges the `INFOPLIST_KEY_*` settings into it. If xcodegen 2.45.3 rejects any key above, remove that key and record the deviation in the report. `Resources/Info.plist` is generated; add `/App/Resources/Info.plist` to `.gitignore` too.

- [ ] **Step 2: Write the app entry point and placeholder content view**

`App/Sources/App/MacAppDuplicatorApp.swift`:

```swift
import SwiftUI

@main
struct MacAppDuplicatorApp: App {
    var body: some Scene {
        WindowGroup("macOS App Duplicator") {
            ContentView()
        }
    }
}
```

`App/Sources/App/ContentView.swift` (placeholder; Task 6 replaces this file):

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("macOS App Duplicator")
            .frame(minWidth: 600, minHeight: 400)
    }
}
```

`App/Sources/App/EmbeddedLauncher.swift`:

```swift
import Foundation

/// The Phase 1 `Launcher` binary copied into `Contents/Resources/Launcher` by the "Embed Launcher" build phase.
enum EmbeddedLauncher {
    enum Error: Swift.Error, LocalizedError {
        case missing
        var errorDescription: String? {
            "The embedded Launcher binary is missing from the app bundle. Rebuild with Tools/build-app.sh."
        }
    }

    /// URL of the embedded launcher; throws when the build phase did not run (for example a bare `swift build`).
    static func url() throws -> URL {
        guard let url = Bundle.main.url(forResource: "Launcher", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw Error.missing
        }
        return url
    }
}
```

- [ ] **Step 3: Write the smoke test**

`App/Tests/SmokeTests.swift`:

```swift
import XCTest
@testable import MacAppDuplicator

final class SmokeTests: XCTestCase {
    func testEmbeddedLauncherIsPresentAndSigned() throws {
        let launcher = try EmbeddedLauncher.url()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: launcher.path))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", launcher.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "embedded Launcher must carry a valid signature")
    }

    func testBundleIdentity() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.mikekuta.MacAppDuplicator")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "macOS App Duplicator")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String, "26.0")
    }
}
```

- [ ] **Step 4: Write `Tools/build-app.sh` and `Tools/test-app.sh`**

`Tools/build-app.sh`:

```bash
#!/bin/bash
# Builds macOS App Duplicator.app. Usage: Tools/build-app.sh [--identity "Developer ID Application: ..."] [--configuration Debug|Release]
# Without --identity the app and the embedded Launcher are ad hoc signed.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY=""
CONFIG="Debug"
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --configuration) CONFIG="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

cd "$REPO"
/usr/local/bin/xcodegen generate --spec App/project.yml --project App --quiet
swift build -c release --product Launcher

ARGS=(
  -project App/MacAppDuplicator.xcodeproj
  -scheme MacAppDuplicator
  -configuration "$CONFIG"
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath .build/DerivedData
)
if [ -n "$IDENTITY" ]; then
  ARGS+=("CODE_SIGN_IDENTITY=$IDENTITY" "DEVELOPMENT_TEAM=4NQ2UVJ4EZ")
fi
xcodebuild "${ARGS[@]}" build | { grep -E '^(\*\* BUILD|error:|warning: .*\.swift)' || true; }

APP="$REPO/.build/DerivedData/Build/Products/$CONFIG/macOS App Duplicator.app"
test -d "$APP"
echo "$APP"
```

`Tools/test-app.sh`:

```bash
#!/bin/bash
# Runs the MacAppDuplicatorTests bundle. Usage: Tools/test-app.sh [-only-testing:MacAppDuplicatorTests/SomeTests]
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
/usr/local/bin/xcodegen generate --spec App/project.yml --project App --quiet
swift build -c release --product Launcher
xcodebuild \
  -project App/MacAppDuplicator.xcodeproj \
  -scheme MacAppDuplicator \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  test "$@" 2>&1 | { grep -E 'Test Suite|Test Case.*(passed|failed)|error:|\*\* TEST' || true; }
```

Then `chmod +x Tools/build-app.sh Tools/test-app.sh`.

- [ ] **Step 5: Ignore generated project files**

Append to `.gitignore`:

```
/App/MacAppDuplicator.xcodeproj/
/App/Resources/Info.plist
```

- [ ] **Step 6: Build and test**

Run: `cd "$REPO" && Tools/build-app.sh 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **` and the path `…/.build/DerivedData/Build/Products/Debug/macOS App Duplicator.app`.

Run: `cd "$REPO" && ls -l ".build/DerivedData/Build/Products/Debug/macOS App Duplicator.app/Contents/Resources/Launcher" && codesign --verify --strict --deep ".build/DerivedData/Build/Products/Debug/macOS App Duplicator.app" && echo signed-ok`
Expected: an executable file and `signed-ok`.

Run: `cd "$REPO" && Tools/test-app.sh 2>&1 | tail -4`
Expected: `Test Suite 'MacAppDuplicatorTests.xctest' passed` with 2 tests, `** TEST SUCCEEDED **`.

Run: `cd "$REPO" && swift test 2>&1 | grep -E 'Executed|error:' | tail -3`
Expected: unchanged Core result (the Xcode project does not alter the SwiftPM build).

- [ ] **Step 7: Commit**

```bash
cd "$REPO" && git add App/project.yml App/Sources App/Tests Tools/build-app.sh Tools/test-app.sh .gitignore && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -q -F - <<'MSG'
feat(app): Xcode project via xcodegen, Launcher embedding, build/test scripts

project.yml defines the MacAppDuplicator app and unit-test targets on
top of the root SwiftPM package. A post-build phase copies the release
Launcher into Contents/Resources and signs it with the app's identity.
Tools/build-app.sh and Tools/test-app.sh are the documented entry points.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 4: Library model (records, scanner, folder watcher, running monitor, library, settings)

**Files:**
- Create: `App/Sources/Model/ShortcutRecord.swift`, `LibraryScanner.swift`, `FolderWatcher.swift`, `RunningShortcutMonitor.swift`, `ShortcutLibrary.swift`, `AppSettings.swift`
- Create: `App/Tests/Model/LibraryScannerTests.swift`, `AppSettingsTests.swift`, `ShortcutLibraryTests.swift`, `App/Tests/TestSupport/AppTestSupport.swift`

**Interfaces:**
- Consumes: Task 1 `ShortcutConfig` (incl. `iconMode`, `homeSymlinkEntries`), `ProcessEnvironment`, `DataSeparationPlanner.shortcutBundleKey`, `HomeTreeBuilder.defaultSymlinkEntries`.
- Produces (used by Tasks 5–9):
  - `struct ShortcutRecord: Identifiable, Hashable, Sendable` with `id: URL` (= `bundleURL`), `bundleURL`, `config: ShortcutConfig`, `engineVersion: Int`, `iconURL: URL?`, `targetVersion: String?`, `targetExists: Bool`, `modifiedDate: Date`, computed `name`, `needsRebuild`.
  - `struct LibraryScanner: Sendable { func scan(folders: [URL]) -> ScanResult }`, `struct ScanResult: Sendable { var records: [ShortcutRecord]; var warnings: [String] }`, `static func record(forBundleAt:) throws -> ShortcutRecord`.
  - `@MainActor final class FolderWatcher { init(folders: [URL], debounce: Duration = .milliseconds(300), onChange: @escaping @MainActor () -> Void); func start(); func stop() }`.
  - `@MainActor @Observable final class RunningShortcutMonitor { private(set) var runningBundlePaths: Set<String>; func start(); func stop(); func refresh() async }`.
  - `@MainActor @Observable final class ShortcutLibrary { private(set) var records: [ShortcutRecord]; private(set) var warnings: [String]; private(set) var isScanning: Bool; init(settings: AppSettings, scanner: LibraryScanner = LibraryScanner(), monitor: RunningShortcutMonitor? = nil); func start(); func stop(); func rescan() async; func isRunning(_ record: ShortcutRecord) -> Bool; func records(ofKind kind: ShortcutKind) -> [ShortcutRecord]; func record(for bundleURL: URL) -> ShortcutRecord?; var recordsNeedingRebuild: [ShortcutRecord] }`.
  - `@MainActor @Observable final class AppSettings { var outputFolder: URL; var libraryFolders: [URL]; var signingIdentity: String; var homeSymlinkEntries: [String]; static let adHocIdentityName = "Ad-hoc"; static func defaultOutputFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL; var signerIdentity: String? (nil when Ad-hoc); var allLibraryFolders: [URL]; init(defaults: UserDefaults = .standard, defaultSigningIdentity: String) }`.

- [ ] **Step 1: Test support for the app test bundle**

Create `App/Tests/TestSupport/AppTestSupport.swift`:

```swift
import Foundation
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

/// A unique temp directory per test; removed by `removeTemporaryDirectory`.
func makeAppTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "mad-app-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes a minimal shortcut bundle (Info.plist with MADConfig + MADEngineVersion, empty MacOS executable, optional icon)
/// the way BundleWriter lays it out, without needing a launcher binary or a real target.
@discardableResult
func writeShortcutBundle(named name: String, in directory: URL, config: ShortcutConfig, engineVersion: Int = ShortcutConfig.currentEngineVersion, withIcon: Bool = true, extraInfo: [String: Any] = [:]) throws -> URL {
    let bundle = directory.appending(path: "\(name).app", directoryHint: .isDirectory)
    let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
    var info: [String: Any] = [
        "CFBundleIdentifier": config.bundleIdentifier,
        "CFBundleName": config.name,
        "CFBundleExecutable": name,
        "CFBundlePackageType": "APPL",
        ShortcutConfig.infoPlistKey: config.plistDictionary(),
        ShortcutConfig.engineVersionInfoPlistKey: engineVersion,
    ]
    for (key, value) in extraInfo { info[key] = value }
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appending(path: "Info.plist"))
    try Data().write(to: contents.appending(path: "MacOS/\(name)"))
    if withIcon {
        try Data([1, 2, 3]).write(to: contents.appending(path: "Resources/AppIcon.icns"))
    }
    return bundle
}

/// A fake target app bundle with a version, so scanner tests can resolve `targetVersion` without a real app.
@discardableResult
func writeFakeTarget(named name: String, bundleIdentifier: String, version: String, in directory: URL) throws -> URL {
    let bundle = directory.appending(path: "\(name).app", directoryHint: .isDirectory)
    let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": bundleIdentifier, "CFBundleName": name, "CFBundleExecutable": name,
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
    try Data().write(to: contents.appending(path: "MacOS/\(name)"))
    return bundle
}

func makeConfig(name: String = "Target Work", targetPath: String = "/Applications/Target.app", targetBundleIdentifier: String = "com.example.target", kind: ShortcutKind = .app) -> ShortcutConfig {
    let slug = ShortcutConfig.slug(for: name)
    return ShortcutConfig(
        kind: kind, name: name, slug: slug, bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: slug),
        targetPath: targetPath, targetBundleIdentifier: targetBundleIdentifier
    )
}

/// Isolated UserDefaults for one test; call `removeSuite` in tearDown.
func makeTestDefaults() -> (defaults: UserDefaults, suite: String) {
    let suite = "com.mikekuta.MacAppDuplicatorTests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

extension XCTestCase {
    func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if await MainActor.run(body: condition) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
```

(The single `try?` in `waitUntil` is a polling sleep whose failure is irrelevant; it is the one allowed instance in app tests.)

- [ ] **Step 2: Write the failing scanner tests**

Create `App/Tests/Model/LibraryScannerTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class LibraryScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try makeAppTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testScanFindsShortcutsReadsConfigIconAndTargetVersion() throws {
        let target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "4.2.0", in: root)
        let config = makeConfig(targetPath: target.path)
        let bundle = try writeShortcutBundle(named: "Target Work", in: root, config: config)

        let result = LibraryScanner().scan(folders: [root])

        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.records.count, 1, "the fake target has no MADConfig and must not be listed")
        let record = try XCTUnwrap(result.records.first)
        XCTAssertEqual(record.bundleURL.standardizedFileURL, bundle.standardizedFileURL)
        XCTAssertEqual(record.config, config)
        XCTAssertEqual(record.engineVersion, 1)
        XCTAssertEqual(record.iconURL?.lastPathComponent, "AppIcon.icns")
        XCTAssertEqual(record.targetVersion, "4.2.0")
        XCTAssertTrue(record.targetExists)
        XCTAssertFalse(record.needsRebuild)
        XCTAssertEqual(record.name, "Target Work")
    }

    func testMissingTargetAndMissingIcon() throws {
        let config = makeConfig(targetPath: root.appending(path: "Gone.app").path)
        try writeShortcutBundle(named: "Target Work", in: root, config: config, withIcon: false)

        let record = try XCTUnwrap(LibraryScanner().scan(folders: [root]).records.first)

        XCTAssertFalse(record.targetExists)
        XCTAssertNil(record.targetVersion)
        XCTAssertNil(record.iconURL)
    }

    func testCorruptConfigBecomesWarningNotRecord() throws {
        let bundle = try writeShortcutBundle(named: "Broken", in: root, config: makeConfig(name: "Broken"))
        let info = bundle.appending(path: "Contents/Info.plist")
        let dict = try XCTUnwrap(NSDictionary(contentsOf: info)?.mutableCopy() as? NSMutableDictionary)
        dict[ShortcutConfig.infoPlistKey] = ["kind": "app"]
        try dict.write(to: info)

        let result = LibraryScanner().scan(folders: [root])

        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("Broken.app"))
    }

    func testOlderEngineVersionNeedsRebuildAndFoldersAreDeduplicated() throws {
        try writeShortcutBundle(named: "Old", in: root, config: makeConfig(name: "Old"), engineVersion: 0)
        let missing = root.appending(path: "does-not-exist", directoryHint: .isDirectory)

        let result = LibraryScanner().scan(folders: [root, root, missing])

        XCTAssertEqual(result.records.count, 1)
        XCTAssertTrue(result.records[0].needsRebuild)
        XCTAssertEqual(result.warnings, [], "a missing library folder is not an error")
    }

    func testRecordsSortedByNameCaseInsensitive() throws {
        try writeShortcutBundle(named: "beta", in: root, config: makeConfig(name: "beta"))
        try writeShortcutBundle(named: "Alpha", in: root, config: makeConfig(name: "Alpha"))
        XCTAssertEqual(LibraryScanner().scan(folders: [root]).records.map(\.name), ["Alpha", "beta"])
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/LibraryScannerTests 2>&1 | tail -5`
Expected: compile errors (`cannot find 'LibraryScanner' in scope`).

- [ ] **Step 4: Implement `ShortcutRecord` and `LibraryScanner`**

`App/Sources/Model/ShortcutRecord.swift`:

```swift
import DuplicatorCore
import Foundation

/// One shortcut bundle found in a library folder (spec §7 sidebar row + editor source of truth).
struct ShortcutRecord: Identifiable, Hashable, Sendable {
    var id: URL { bundleURL }
    var bundleURL: URL
    var config: ShortcutConfig
    /// `MADEngineVersion` from the bundle's Info.plist.
    var engineVersion: Int
    /// `Contents/Resources/AppIcon.icns` when present.
    var iconURL: URL?
    /// `CFBundleShortVersionString` of the target, when the target exists and declares one.
    var targetVersion: String?
    var targetExists: Bool
    var modifiedDate: Date

    var name: String { config.name }
    var needsRebuild: Bool { engineVersion < ShortcutConfig.currentEngineVersion }
}
```

`App/Sources/Model/LibraryScanner.swift`:

```swift
import DuplicatorCore
import Foundation

struct ScanResult: Sendable {
    var records: [ShortcutRecord] = []
    var warnings: [String] = []
}

/// Finds shortcut bundles: depth-1 `.app` directories whose Info.plist carries `MADConfig` (spec §7).
struct LibraryScanner: Sendable {
    enum ScanError: Error, LocalizedError {
        case notAShortcut(URL)
        case unreadableInfoPlist(URL)

        var errorDescription: String? {
            switch self {
            case .notAShortcut(let url): "\(url.lastPathComponent) has no \(ShortcutConfig.infoPlistKey) entry."
            case .unreadableInfoPlist(let url): "\(url.lastPathComponent) has no readable Info.plist."
            }
        }
    }

    var fileManager: FileManager = .default

    func scan(folders: [URL]) -> ScanResult {
        var result = ScanResult()
        var seen = Set<String>()
        for folder in folders {
            let folderPath = folder.standardizedFileURL.path
            guard seen.insert(folderPath).inserted else { continue }
            guard let entries = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
                continue // a missing or unreadable library folder is not a warning (spec: user-added folders may be on unmounted volumes)
            }
            for entry in entries where entry.pathExtension == "app" {
                do {
                    result.records.append(try Self.record(forBundleAt: entry, fileManager: fileManager))
                } catch ScanError.notAShortcut {
                    continue // an ordinary app in the folder
                } catch {
                    result.warnings.append("\(entry.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        result.records.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result
    }

    /// Reads one bundle. Throws `ScanError.notAShortcut` for apps without `MADConfig`, `LauncherError.configCorrupt`
    /// for shortcuts whose config no longer decodes.
    static func record(forBundleAt bundleURL: URL, fileManager: FileManager = .default) throws -> ShortcutRecord {
        let infoURL = bundleURL.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        guard let data = fileManager.contents(atPath: infoURL.path),
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ScanError.unreadableInfoPlist(bundleURL)
        }
        guard let rawConfig = info[ShortcutConfig.infoPlistKey] as? [String: Any] else {
            throw ScanError.notAShortcut(bundleURL)
        }
        let config = try ShortcutConfig(plistDictionary: rawConfig)
        let engineVersion = info[ShortcutConfig.engineVersionInfoPlistKey] as? Int ?? 0

        let iconURL = bundleURL.appending(path: "Contents/Resources/AppIcon.icns", directoryHint: .notDirectory)
        let hasIcon = fileManager.fileExists(atPath: iconURL.path)

        let targetURL = URL(fileURLWithPath: config.targetPath)
        let targetExists = fileManager.fileExists(atPath: targetURL.path)
        var targetVersion: String?
        if targetExists, let bundle = Bundle(url: targetURL) {
            targetVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        }

        let modified = (try? fileManager.attributesOfItem(atPath: infoURL.path)[.modificationDate] as? Date) ?? .distantPast

        return ShortcutRecord(
            bundleURL: bundleURL, config: config, engineVersion: engineVersion,
            iconURL: hasIcon ? iconURL : nil, targetVersion: targetVersion, targetExists: targetExists, modifiedDate: modified
        )
    }
}
```

(The two `try?` here are deliberate: an unreadable folder and a missing modification date are both non-fatal for a library listing; the test `testOlderEngineVersionNeedsRebuildAndFoldersAreDeduplicated` pins the folder behaviour.)

- [ ] **Step 5: Run the scanner tests**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/LibraryScannerTests 2>&1 | tail -3`
Expected: 5 tests passed.

- [ ] **Step 6: Write the failing `AppSettings` tests**

Create `App/Tests/Model/AppSettingsTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

@MainActor
final class AppSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        (defaults, suite) = makeTestDefaults()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testDefaults() {
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: "Developer ID Application: Test (TEAMID)")
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(settings.outputFolder.standardizedFileURL, home.appending(path: "Applications/App Duplicator", directoryHint: .isDirectory).standardizedFileURL)
        XCTAssertEqual(settings.libraryFolders, [])
        XCTAssertEqual(settings.signingIdentity, "Developer ID Application: Test (TEAMID)")
        XCTAssertEqual(settings.signerIdentity, "Developer ID Application: Test (TEAMID)")
        XCTAssertEqual(settings.homeSymlinkEntries, HomeTreeBuilder.defaultSymlinkEntries)
        XCTAssertEqual(settings.allLibraryFolders, [settings.outputFolder])
    }

    func testAdHocMapsToNilSignerIdentity() {
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        XCTAssertEqual(settings.signingIdentity, "Ad-hoc")
        XCTAssertNil(settings.signerIdentity)
    }

    func testValuesPersistAcrossInstances() throws {
        let folder = try makeAppTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = AppSettings(defaults: defaults, defaultSigningIdentity: "Ad-hoc")
        first.outputFolder = folder
        first.libraryFolders = [folder.appending(path: "extra", directoryHint: .isDirectory)]
        first.signingIdentity = "Developer ID Application: Test (TEAMID)"
        first.homeSymlinkEntries = ["Desktop"]

        let second = AppSettings(defaults: defaults, defaultSigningIdentity: "Ad-hoc")
        XCTAssertEqual(second.outputFolder.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(second.libraryFolders.map(\.lastPathComponent), ["extra"])
        XCTAssertEqual(second.signingIdentity, "Developer ID Application: Test (TEAMID)")
        XCTAssertEqual(second.homeSymlinkEntries, ["Desktop"])
        XCTAssertEqual(second.allLibraryFolders.count, 2)
    }

    func testAllLibraryFoldersDeduplicatesOutputFolder() throws {
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: "Ad-hoc")
        settings.libraryFolders = [settings.outputFolder]
        XCTAssertEqual(settings.allLibraryFolders.count, 1)
    }
}
```

- [ ] **Step 7: Implement `AppSettings`**

`App/Sources/Model/AppSettings.swift`:

```swift
import DuplicatorCore
import Foundation
import Observation

/// User preferences (spec §7 Settings). Backed by UserDefaults; every property writes through on set.
@MainActor
@Observable
final class AppSettings {
    static let adHocIdentityName = "Ad-hoc"

    private enum Key {
        static let outputFolder = "outputFolderPath"
        static let libraryFolders = "libraryFolderPaths"
        static let signingIdentity = "signingIdentity"
        static let homeSymlinkEntries = "homeSymlinkEntries"
    }

    static func defaultOutputFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Applications/App Duplicator", directoryHint: .isDirectory)
    }

    private let defaults: UserDefaults

    var outputFolder: URL {
        didSet { defaults.set(outputFolder.path, forKey: Key.outputFolder) }
    }
    /// User-added folders scanned in addition to `outputFolder`.
    var libraryFolders: [URL] {
        didSet { defaults.set(libraryFolders.map(\.path), forKey: Key.libraryFolders) }
    }
    /// Display name of the codesigning identity, or `adHocIdentityName`.
    var signingIdentity: String {
        didSet { defaults.set(signingIdentity, forKey: Key.signingIdentity) }
    }
    /// Symlink list applied to new HOME-override shortcuts (spec §4.3). Stored per shortcut at creation time.
    var homeSymlinkEntries: [String] {
        didSet { defaults.set(homeSymlinkEntries, forKey: Key.homeSymlinkEntries) }
    }

    /// `Signer` argument: nil for ad hoc.
    var signerIdentity: String? {
        signingIdentity == Self.adHocIdentityName ? nil : signingIdentity
    }

    /// Output folder first, then user folders, without duplicates.
    var allLibraryFolders: [URL] {
        var seen = Set<String>()
        return ([outputFolder] + libraryFolders).filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    init(defaults: UserDefaults = .standard, defaultSigningIdentity: String) {
        self.defaults = defaults
        outputFolder = defaults.string(forKey: Key.outputFolder).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultOutputFolder()
        libraryFolders = (defaults.stringArray(forKey: Key.libraryFolders) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        signingIdentity = defaults.string(forKey: Key.signingIdentity) ?? defaultSigningIdentity
        homeSymlinkEntries = defaults.stringArray(forKey: Key.homeSymlinkEntries) ?? HomeTreeBuilder.defaultSymlinkEntries
    }
}
```

- [ ] **Step 8: Run the settings tests**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/AppSettingsTests 2>&1 | tail -3`
Expected: 4 passed.

- [ ] **Step 9: Implement `FolderWatcher` and `RunningShortcutMonitor`**

`App/Sources/Model/FolderWatcher.swift`:

```swift
import Foundation

/// Watches library folders for writes/renames/deletes with `DispatchSource` and coalesces bursts (spec §7).
/// Folders that do not exist when `start()` runs are skipped; call `stop()`/`start()` again after changing the list.
@MainActor
final class FolderWatcher {
    private let folders: [URL]
    private let debounce: Duration
    private let onChange: @MainActor () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: Task<Void, Never>?

    init(folders: [URL], debounce: Duration = .milliseconds(300), onChange: @escaping @MainActor () -> Void) {
        self.folders = folders
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        stop()
        for folder in folders {
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.schedule() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        pending?.cancel()
        pending = nil
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

`App/Sources/Model/RunningShortcutMonitor.swift`:

```swift
import AppKit
import DuplicatorCore
import Observation

/// Which shortcut bundles currently have a live process. After `execve` the target checks in under its own bundle,
/// so NSRunningApplication cannot tell shortcuts apart; the launcher's `MAD_SHORTCUT_BUNDLE` env entry can (spec §7).
@MainActor
@Observable
final class RunningShortcutMonitor {
    /// Standardized paths of shortcut bundles with at least one running process.
    private(set) var runningBundlePaths: Set<String> = []

    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        scheduleRefresh()
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Rescans process environments once. Safe to call while a scheduled refresh is pending.
    func refresh() async {
        let key = DataSeparationPlanner.shortcutBundleKey
        let paths = await Task.detached(priority: .utility) {
            Set(ProcessEnvironment.values(forEnvironmentKey: key).values.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        }.value
        runningBundlePaths = paths
    }

    func isRunning(bundleURL: URL) -> Bool {
        runningBundlePaths.contains(bundleURL.standardizedFileURL.path)
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            // LaunchServices check-in happens up to ~1 s after exec; wait so a fresh launch is seen with its final env.
            do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
            await self?.refresh()
        }
    }
}
```

- [ ] **Step 10: Write the failing `ShortcutLibrary` test**

Create `App/Tests/Model/ShortcutLibraryTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

@MainActor
final class ShortcutLibraryTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        root = try makeAppTemporaryDirectory()
        (defaults, suite) = makeTestDefaults()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    private func makeLibrary() -> ShortcutLibrary {
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: "Ad-hoc")
        settings.outputFolder = root
        return ShortcutLibrary(settings: settings, monitor: RunningShortcutMonitor())
    }

    func testRescanPopulatesRecordsAndLookups() async throws {
        try writeShortcutBundle(named: "Target Work", in: root, config: makeConfig())
        try writeShortcutBundle(named: "Old", in: root, config: makeConfig(name: "Old"), engineVersion: 0)
        let library = makeLibrary()

        await library.rescan()

        XCTAssertEqual(library.records.map(\.name), ["Old", "Target Work"])
        XCTAssertEqual(library.records(ofKind: .app).count, 2)
        XCTAssertEqual(library.records(ofKind: .webApp).count, 0)
        XCTAssertEqual(library.recordsNeedingRebuild.map(\.name), ["Old"])
        XCTAssertNotNil(library.record(for: root.appending(path: "Old.app")))
        XCTAssertFalse(library.isRunning(library.records[0]))
        XCTAssertFalse(library.isScanning)
    }

    func testStartWatchesFolderAndPicksUpNewBundle() async throws {
        let library = makeLibrary()
        library.start()
        defer { library.stop() }
        await waitUntil { library.records.isEmpty && !library.isScanning }

        try writeShortcutBundle(named: "Late", in: root, config: makeConfig(name: "Late"))

        await waitUntil { library.records.map(\.name) == ["Late"] }
        XCTAssertEqual(library.records.map(\.name), ["Late"])
    }
}
```

- [ ] **Step 11: Implement `ShortcutLibrary`**

`App/Sources/Model/ShortcutLibrary.swift`:

```swift
import DuplicatorCore
import Foundation
import Observation

/// The in-memory library: scan results for all library folders, a folder watcher, and the running monitor (spec §7).
@MainActor
@Observable
final class ShortcutLibrary {
    private(set) var records: [ShortcutRecord] = []
    private(set) var warnings: [String] = []
    private(set) var isScanning = false

    let settings: AppSettings
    let monitor: RunningShortcutMonitor
    private let scanner: LibraryScanner
    private var watcher: FolderWatcher?
    private var watchedFolders: [URL] = []

    init(settings: AppSettings, scanner: LibraryScanner = LibraryScanner(), monitor: RunningShortcutMonitor? = nil) {
        self.settings = settings
        self.scanner = scanner
        self.monitor = monitor ?? RunningShortcutMonitor()
    }

    /// Starts watching and performs the first scan. Call again after the folder list changes.
    func start() {
        let folders = settings.allLibraryFolders
        if watcher == nil || folders != watchedFolders {
            watcher?.stop()
            watchedFolders = folders
            try? FileManager.default.createDirectory(at: settings.outputFolder, withIntermediateDirectories: true)
            watcher = FolderWatcher(folders: folders) { [weak self] in
                Task { await self?.rescan() }
            }
            watcher?.start()
        }
        monitor.start()
        Task { await rescan() }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        watchedFolders = []
        monitor.stop()
    }

    func rescan() async {
        isScanning = true
        defer { isScanning = false }
        let folders = settings.allLibraryFolders
        let scanner = scanner
        let result = await Task.detached(priority: .userInitiated) { scanner.scan(folders: folders) }.value
        records = result.records
        warnings = result.warnings
        await monitor.refresh()
    }

    func isRunning(_ record: ShortcutRecord) -> Bool { monitor.isRunning(bundleURL: record.bundleURL) }
    func records(ofKind kind: ShortcutKind) -> [ShortcutRecord] { records.filter { $0.config.kind == kind } }
    func record(for bundleURL: URL) -> ShortcutRecord? {
        let path = bundleURL.standardizedFileURL.path
        return records.first { $0.bundleURL.standardizedFileURL.path == path }
    }
    var recordsNeedingRebuild: [ShortcutRecord] { records.filter(\.needsRebuild) }
}
```

(`try? createDirectory` in `start()`: creating the default output folder is best effort; a failure surfaces later as a creation error with a real message in Task 5.)

- [ ] **Step 12: Run all model tests**

Run: `cd "$REPO" && Tools/test-app.sh 2>&1 | tail -4`
Expected: `** TEST SUCCEEDED **`, 13 tests (2 smoke + 5 scanner + 4 settings + 2 library).

- [ ] **Step 13: Commit**

```bash
cd "$REPO" && git add App/Sources/Model App/Tests && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -q -F - <<'MSG'
feat(app): library model — records, scanner, folder watcher, running monitor, settings

LibraryScanner lists depth-1 shortcut bundles with their config, icon,
target version and engine version. ShortcutLibrary owns the scan state,
a DispatchSource folder watcher and the RunningShortcutMonitor that
matches processes by MAD_SHORTCUT_BUNDLE. AppSettings persists output
folder, extra library folders, signing identity and HOME symlink list.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 5: Services (signing identities, icons, shortcut builder, installed apps, logs, badges, launch preview, launcher)

**Files:**
- Create: `App/Sources/Services/SigningIdentities.swift`, `IconRenderer.swift`, `IconResolver.swift`, `ShortcutBuilder.swift`, `InstalledApps.swift`, `LogReader.swift`, `CompatBadge.swift`, `LaunchPlanPreview.swift`, `AppLauncher.swift`
- Create: `App/Tests/Services/SigningIdentitiesTests.swift`, `IconRendererTests.swift`, `IconResolverTests.swift`, `ShortcutBuilderTests.swift`, `InstalledAppsTests.swift`, `LogReaderTests.swift`, `CompatBadgeTests.swift`, `LaunchPlanPreviewTests.swift`

**Interfaces:**
- Consumes: Task 1 `BundleWriter.write(config:app:launcherBinary:iconFile:to:)`, `ShortcutConfig.iconMode/customIconPath`, Task 4 `ShortcutRecord`, `LibraryScanner.record(forBundleAt:)`, Phase 1 `AppInspector`, `Signer`, `DataSeparationPlanner`, `SecretMasking`, `LaunchLogger`, `InspectedApp`.
- Produces (used by Tasks 6–9):
  - `enum SigningIdentities { static func parse(_ output: String) -> [String]; static func load() -> [String]; static func defaultIdentity(from identities: [String]) -> String }`
  - `enum IconRenderer { static func initials(for name: String) -> String; static func generatedTile(initials: String, size: Int) -> CGImage; static func writeICNS(generatedFor name: String, to url: URL) throws; static func writeICNS(fromImageFile source: URL, to url: URL) throws }`
  - `enum IconResolver { static func iconFile(for config: ShortcutConfig, app: InspectedApp, scratchDirectory: URL) throws -> URL? }` plus `enum IconError: Error, LocalizedError { case customFileMissing(String), renderFailed(String) }`
  - `struct ShortcutBuilder { let launcherBinary: URL; let signingIdentity: String?; init(launcherBinary:signingIdentity:); func create(config:in:) throws -> URL; func regenerate(record:config:) throws -> URL; func duplicate(record:newName:in:) throws -> URL; func export(record:to:) throws -> URL; func delete(record:removeData:) throws }` and `enum BuilderError: Error, LocalizedError { case alreadyExists(URL), targetMissing(String) }`
  - `struct InstalledApp: Identifiable, Hashable, Sendable { var id: URL { url }; var url: URL; var name: String; var bundleIdentifier: String; var version: String? }`, `enum InstalledApps { static func scan(folders: [URL] = defaultFolders) -> [InstalledApp]; static let defaultFolders: [URL] }`
  - `enum LogReader { static func tail(name: String, lines: Int = 200) -> [String]; static func logFolder() -> URL }`
  - `enum CompatBadge: String, Sendable { case verified = "Verified", auto = "Auto", homeOnly = "HOME only", unsupported = "Unsupported", unknown = "Unknown"; var label: String { rawValue }; static func badge(for app: InspectedApp?) -> CompatBadge }`
  - `struct LaunchPlanPreview: Sendable { var executablePath: String; var arguments: [String]; var maskedEnvironment: [String: String]; var environmentAdditions: [String: String]; var warnings: [String]; var launchMode: LaunchMode; static func make(config: ShortcutConfig, bundleURL: URL?) throws -> LaunchPlanPreview }`
  - `enum AppLauncher { @MainActor static func launch(_ record: ShortcutRecord) async throws; static func revealInFinder(_ url: URL) }`

- [ ] **Step 1: Write the failing `SigningIdentities` tests**

`App/Tests/Services/SigningIdentitiesTests.swift`:

```swift
import XCTest
@testable import MacAppDuplicator

final class SigningIdentitiesTests: XCTestCase {
    private let sample = """
      1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)"
      2) 89ABCDEF0123456789ABCDEF0123456789ABCDEF "Apple Development: 152761714+cubbieblue16@users.noreply.github.com (GZHS2TWCRJ)"
      3) 89ABCDEF0123456789ABCDEF0123456789ABCDE0 "Apple Development: 152761714+cubbieblue16@users.noreply.github.com (GZHS2TWCRJ)" (CSSMERR_TP_CERT_REVOKED)
      4) FEDCBA9876543210FEDCBA9876543210FEDCBA98 "Apple Development: 152761714+cubbieblue16@users.noreply.github.com (GZHS2TWCRJ)"
         3 valid identities found
    """

    func testParseKeepsValidUniqueNamesInOrder() {
        XCTAssertEqual(SigningIdentities.parse(sample), [
            "Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)",
            "Apple Development: 152761714+cubbieblue16@users.noreply.github.com (GZHS2TWCRJ)",
        ])
    }

    func testParseEmptyOutput() {
        XCTAssertEqual(SigningIdentities.parse("     0 valid identities found\n"), [])
    }

    func testDefaultIdentityPrefersDeveloperIDElseAdHoc() {
        XCTAssertEqual(SigningIdentities.defaultIdentity(from: ["Apple Development: x (T)", "Developer ID Application: Y (T2)"]), "Developer ID Application: Y (T2)")
        XCTAssertEqual(SigningIdentities.defaultIdentity(from: ["Apple Development: x (T)"]), AppSettings.adHocIdentityName)
        XCTAssertEqual(SigningIdentities.defaultIdentity(from: []), "Ad-hoc")
    }
}
```

- [ ] **Step 2: Implement `SigningIdentities`**

`App/Sources/Services/SigningIdentities.swift`:

```swift
import Foundation

/// Lists codesigning identities by display name via `security find-identity -v -p codesigning` (spec §7 Settings).
enum SigningIdentities {
    private static let line = /^\s*\d+\)\s+[0-9A-Fa-f]{40}\s+"(.+)"\s*$/

    /// Keeps unique names, in order; drops lines with a trailing status such as `(CSSMERR_TP_CERT_REVOKED)`.
    static func parse(_ output: String) -> [String] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
            guard let match = raw.wholeMatch(of: line) else { return nil }
            let name = String(match.1)
            return seen.insert(name).inserted ? name : nil
        }
    }

    static func load() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-identity", "-v", "-p", "codesigning"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// First "Developer ID Application" identity, otherwise ad hoc.
    static func defaultIdentity(from identities: [String]) -> String {
        identities.first { $0.hasPrefix("Developer ID Application") } ?? AppSettings.adHocIdentityName
    }
}
```

- [ ] **Step 3: Run**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/SigningIdentitiesTests 2>&1 | tail -3`
Expected: 3 passed.

- [ ] **Step 4: Write the failing icon tests**

`App/Tests/Services/IconRendererTests.swift`:

```swift
import XCTest
@testable import MacAppDuplicator

final class IconRendererTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try makeAppTemporaryDirectory() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    func testInitials() {
        XCTAssertEqual(IconRenderer.initials(for: "Claude Work"), "CW")
        XCTAssertEqual(IconRenderer.initials(for: "slack"), "S")
        XCTAssertEqual(IconRenderer.initials(for: "Visual Studio Code"), "VS")
        XCTAssertEqual(IconRenderer.initials(for: "   "), "?")
    }

    func testGeneratedTileHasRequestedSizeAndAlpha() {
        let image = IconRenderer.generatedTile(initials: "CW", size: 128)
        XCTAssertEqual(image.width, 128)
        XCTAssertEqual(image.height, 128)
        XCTAssertNotEqual(image.alphaInfo, .none)
    }

    func testWriteICNSGeneratedProducesValidICNS() throws {
        let out = dir.appending(path: "gen.icns")
        try IconRenderer.writeICNS(generatedFor: "Claude Work", to: out)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "icns")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    func testWriteICNSFromICNSFileCopiesBytes() throws {
        let source = dir.appending(path: "src.icns")
        try Data("icns-fake".utf8).write(to: source)
        let out = dir.appending(path: "copy.icns")
        try IconRenderer.writeICNS(fromImageFile: source, to: out)
        XCTAssertEqual(try Data(contentsOf: out), Data("icns-fake".utf8))
    }

    func testWriteICNSFromPNGFileConverts() throws {
        let png = dir.appending(path: "src.png")
        let cg = IconRenderer.generatedTile(initials: "P", size: 256)
        let rep = NSBitmapImageRep(cgImage: cg)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: png)
        let out = dir.appending(path: "conv.icns")
        try IconRenderer.writeICNS(fromImageFile: png, to: out)
        XCTAssertEqual(String(decoding: try Data(contentsOf: out).prefix(4), as: UTF8.self), "icns")
    }
}
```

`App/Tests/Services/IconResolverTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class IconResolverTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try makeAppTemporaryDirectory() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    private func app(iconFile: URL?) -> InspectedApp {
        InspectedApp(
            bundleURL: dir.appending(path: "T.app"), bundleIdentifier: "com.example.t", name: "T", version: "1",
            executableURL: dir.appending(path: "T.app/Contents/MacOS/T"), family: .native, isSandboxed: false,
            iconFileURL: iconFile, isPlatformBinary: false, hasLaunchConstraints: false, lsEnvironment: [:], warnings: []
        )
    }

    func testCopiedUsesTargetIconOrNil() throws {
        let icon = dir.appending(path: "t.icns")
        try Data([1]).write(to: icon)
        var config = makeConfig()
        config.iconMode = .copied
        XCTAssertEqual(try IconResolver.iconFile(for: config, app: app(iconFile: icon), scratchDirectory: dir), icon)
        XCTAssertNil(try IconResolver.iconFile(for: config, app: app(iconFile: nil), scratchDirectory: dir))
    }

    func testCustomConvertsIntoScratchAndFailsWhenMissing() throws {
        let custom = dir.appending(path: "custom.icns")
        try Data("icns-fake".utf8).write(to: custom)
        var config = makeConfig()
        config.iconMode = .custom
        config.customIconPath = custom.path
        let result = try XCTUnwrap(try IconResolver.iconFile(for: config, app: app(iconFile: nil), scratchDirectory: dir))
        XCTAssertEqual(result.pathExtension, "icns")
        XCTAssertTrue(result.path.hasPrefix(dir.path))
        XCTAssertNotEqual(result, custom)

        config.customIconPath = dir.appending(path: "nope.png").path
        XCTAssertThrowsError(try IconResolver.iconFile(for: config, app: app(iconFile: nil), scratchDirectory: dir)) { error in
            guard case IconResolver.IconError.customFileMissing = error else { return XCTFail("\(error)") }
        }
    }

    func testGeneratedRendersTile() throws {
        var config = makeConfig(name: "Claude Work")
        config.iconMode = .generated
        let result = try XCTUnwrap(try IconResolver.iconFile(for: config, app: app(iconFile: nil), scratchDirectory: dir))
        XCTAssertEqual(String(decoding: try Data(contentsOf: result).prefix(4), as: UTF8.self), "icns")
    }
}
```

- [ ] **Step 5: Implement `IconRenderer` and `IconResolver`**

`App/Sources/Services/IconRenderer.swift`:

```swift
import AppKit
import CoreGraphics
import Foundation

/// Generated tile icons and ICNS writing (spec §7 icon modes). ICNS files are produced with `/usr/bin/iconutil`
/// from a temporary `.iconset`, the same route Xcode uses; an `.icns` source is copied as is.
enum IconRenderer {
    enum RenderError: Error, LocalizedError {
        case unreadableImage(String)
        case iconutilFailed(String)
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .unreadableImage(let path): "Could not read an image from \(path)."
            case .iconutilFailed(let message): "iconutil failed: \(message)"
            case .encodeFailed: "Could not encode the icon as PNG."
            }
        }
    }

    /// The sizes `iconutil` requires, as (pixels, file name).
    private static let iconsetEntries: [(Int, String)] = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"), (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"), (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]

    /// Up to two initials from the first two words; "?" for an empty name.
    static func initials(for name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace).prefix(2)
        let letters = words.compactMap { $0.first.map { String($0).uppercased() } }
        return letters.isEmpty ? "?" : letters.joined()
    }

    /// A rounded indigo tile with white initials, hue derived from the initials so different shortcuts differ.
    static func generatedTile(initials: String, size: Int) -> CGImage {
        let scale = CGFloat(size) / 1024
        let hue = CGFloat(initials.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = rect.insetBy(dx: 100 * scale, dy: 100 * scale)
            let path = NSBezierPath(roundedRect: inset, xRadius: 186 * scale, yRadius: 186 * scale)
            let gradient = NSGradient(starting: NSColor(hue: hue, saturation: 0.55, brightness: 0.35, alpha: 1),
                                      ending: NSColor(hue: hue, saturation: 0.65, brightness: 0.75, alpha: 1))
            gradient?.draw(in: path, angle: -60)
            let font = NSFont.systemFont(ofSize: 420 * scale, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let text = NSAttributedString(string: initials, attributes: attributes)
            let textSize = text.size()
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            return true
        }
        var proposed = CGRect(origin: .zero, size: NSSize(width: size, height: size))
        // NSImage drawing handlers always rasterize; the block above guarantees a bitmap at exactly `size` points.
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: [.ctm: AffineTransform(scale: 1)])!
    }

    static func writeICNS(generatedFor name: String, to url: URL) throws {
        let tile = generatedTile(initials: initials(for: name), size: 1024)
        try writeICNS(from: tile, to: url)
    }

    /// `.icns` sources are copied; any other image readable by `NSImage` is resampled into an iconset.
    static func writeICNS(fromImageFile source: URL, to url: URL) throws {
        if source.pathExtension.lowercased() == "icns" {
            try replaceFile(at: url, with: try Data(contentsOf: source))
            return
        }
        guard let image = NSImage(contentsOf: source) else { throw RenderError.unreadableImage(source.path) }
        var proposed = CGRect(origin: .zero, size: NSSize(width: 1024, height: 1024))
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            throw RenderError.unreadableImage(source.path)
        }
        try writeICNS(from: cg, to: url)
    }

    static func writeICNS(from image: CGImage, to url: URL) throws {
        let iconset = FileManager.default.temporaryDirectory.appending(path: "mad-\(UUID().uuidString).iconset", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: iconset) }

        for (pixels, fileName) in iconsetEntries {
            let data = try pngData(resampling: image, to: pixels)
            try data.write(to: iconset.appending(path: fileName))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", url.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        try process.run()
        let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RenderError.iconutilFailed(String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func pngData(resampling image: CGImage, to pixels: Int) throws -> Data {
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RenderError.encodeFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let scaled = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) else {
            throw RenderError.encodeFailed
        }
        return data
    }

    private static func replaceFile(at url: URL, with data: Data) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try data.write(to: url)
    }
}
```

(The `try?` in the iconset `defer` cleans a temp folder; failure is harmless. The two force unwraps are on `CGColorSpace(name: .sRGB)` and a drawing-handler image that AppKit always rasterizes — both are documented to be non-nil.)

`App/Sources/Services/IconResolver.swift`:

```swift
import DuplicatorCore
import Foundation

/// Turns `config.iconMode` into the `.icns` file BundleWriter copies into the shortcut (spec §7).
enum IconResolver {
    enum IconError: Error, LocalizedError {
        case customFileMissing(String)
        case renderFailed(String)

        var errorDescription: String? {
            switch self {
            case .customFileMissing(let path): "The custom icon file was not found: \(path)"
            case .renderFailed(let message): "The icon could not be rendered: \(message)"
            }
        }
    }

    /// - Returns: the target's own icon (`.copied`), a converted copy of `customIconPath` in `scratchDirectory` (`.custom`),
    ///   a generated tile in `scratchDirectory` (`.generated`), or nil when the target has no icon to copy.
    static func iconFile(for config: ShortcutConfig, app: InspectedApp, scratchDirectory: URL) throws -> URL? {
        switch config.iconMode {
        case .copied:
            return app.iconFileURL
        case .custom:
            guard let path = config.customIconPath, FileManager.default.fileExists(atPath: path) else {
                throw IconError.customFileMissing(config.customIconPath ?? "")
            }
            let out = scratchDirectory.appending(path: "\(config.slug)-custom.icns")
            do { try IconRenderer.writeICNS(fromImageFile: URL(fileURLWithPath: path), to: out) } catch {
                throw IconError.renderFailed(error.localizedDescription)
            }
            return out
        case .generated:
            let out = scratchDirectory.appending(path: "\(config.slug)-generated.icns")
            do { try IconRenderer.writeICNS(generatedFor: config.name, to: out) } catch {
                throw IconError.renderFailed(error.localizedDescription)
            }
            return out
        }
    }
}
```

- [ ] **Step 6: Run icon tests**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/IconRendererTests -only-testing:MacAppDuplicatorTests/IconResolverTests 2>&1 | tail -3`
Expected: 8 passed.

- [ ] **Step 7: Write the failing `ShortcutBuilder` tests**

`App/Tests/Services/ShortcutBuilderTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class ShortcutBuilderTests: XCTestCase {
    private var dir: URL!
    private var target: URL!
    private var launcher: URL!
    private var builder: ShortcutBuilder!

    override func setUpWithError() throws {
        dir = try makeAppTemporaryDirectory()
        target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "1.0", in: dir)
        // The fake target needs a real Mach-O executable for AppInspector; /bin/ls is a universal binary. Copy, don't link.
        try FileManager.default.removeItem(at: target.appending(path: "Contents/MacOS/Target"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: target.appending(path: "Contents/MacOS/Target"))
        launcher = dir.appending(path: "Launcher")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: launcher)
        builder = ShortcutBuilder(launcherBinary: launcher, signingIdentity: nil)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    private func config(name: String = "Target Work") -> ShortcutConfig {
        var c = makeConfig(name: name, targetPath: target.path)
        c.iconMode = .generated
        return c
    }

    func testCreateWritesSignedBundleWithIconAndRefusesDuplicate() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)

        XCTAssertEqual(bundle.lastPathComponent, "Target Work.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Resources/AppIcon.icns").path))
        let record = try LibraryScanner.record(forBundleAt: bundle)
        XCTAssertEqual(record.config.iconMode, .generated)
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", bundle.path]
        verify.standardError = Pipe()
        try verify.run(); verify.waitUntilExit()
        XCTAssertEqual(verify.terminationStatus, 0)

        XCTAssertThrowsError(try builder.create(config: config(), in: out)) { error in
            guard case ShortcutBuilder.BuilderError.alreadyExists = error else { return XCTFail("\(error)") }
        }
    }

    func testCreateWithMissingTargetThrows() {
        var c = config()
        c.targetPath = dir.appending(path: "Gone.app").path
        XCTAssertThrowsError(try builder.create(config: c, in: dir)) { error in
            guard case ShortcutBuilder.BuilderError.targetMissing = error else { return XCTFail("\(error)") }
        }
    }

    func testRegenerateRewritesInPlaceAndKeepsPath() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        var record = try LibraryScanner.record(forBundleAt: bundle)
        var updated = record.config
        updated.arguments = ["--flag"]
        let rewritten = try builder.regenerate(record: record, config: updated)
        XCTAssertEqual(rewritten, bundle)
        record = try LibraryScanner.record(forBundleAt: rewritten)
        XCTAssertEqual(record.config.arguments, ["--flag"])
    }

    func testDuplicateCreatesSecondBundleWithNewIdentity() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let first = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: first)
        let second = try builder.duplicate(record: record, newName: "Target Personal", in: out)
        let copy = try LibraryScanner.record(forBundleAt: second)
        XCTAssertEqual(second.lastPathComponent, "Target Personal.app")
        XCTAssertEqual(copy.config.slug, ShortcutConfig.slug(for: "Target Personal"))
        XCTAssertEqual(copy.config.bundleIdentifier, ShortcutConfig.bundleIdentifier(forSlug: copy.config.slug))
        XCTAssertNil(copy.config.dataPath, "a duplicate gets its own default data folder, not the original's")
        XCTAssertEqual(copy.config.targetPath, record.config.targetPath)
    }

    func testExportCopiesBundle() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        let exported = try builder.export(record: record, to: dir.appending(path: "exported.app"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appending(path: "Contents/Info.plist").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
    }

    func testDeleteRemovesBundleAndOptionallyDataFolder() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        var c = config()
        let data = dir.appending(path: "data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        c.dataMode = .homeOverride
        c.dataPath = data.path
        let bundle = try builder.create(config: c, in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)

        try builder.delete(record: record, removeData: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path))

        let again = try builder.create(config: c, in: out)
        try builder.delete(record: try LibraryScanner.record(forBundleAt: again), removeData: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.path))
    }
}
```

- [ ] **Step 8: Implement `ShortcutBuilder`**

`App/Sources/Services/ShortcutBuilder.swift`:

```swift
import DuplicatorCore
import Foundation

/// Create / regenerate / duplicate / export / delete shortcut bundles (spec §7 actions). Every write goes through
/// `BundleWriter` + `Signer`; the target app is only ever read.
struct ShortcutBuilder {
    enum BuilderError: Error, LocalizedError {
        case alreadyExists(URL)
        case targetMissing(String)

        var errorDescription: String? {
            switch self {
            case .alreadyExists(let url): "\(url.lastPathComponent) already exists in \(url.deletingLastPathComponent().path)."
            case .targetMissing(let path): "The target app was not found at \(path)."
            }
        }
    }

    let launcherBinary: URL
    /// Codesign identity display name, or nil for ad hoc.
    let signingIdentity: String?
    var fileManager: FileManager = .default

    init(launcherBinary: URL, signingIdentity: String?) {
        self.launcherBinary = launcherBinary
        self.signingIdentity = signingIdentity
    }

    /// Writes `<name>.app` into `directory`. Throws `alreadyExists` rather than replacing a bundle it did not make.
    func create(config: ShortcutConfig, in directory: URL) throws -> URL {
        let destination = directory.appending(path: "\(ShortcutConfig.fileSystemName(for: config.name)).app", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: destination.path) { throw BuilderError.alreadyExists(destination) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try write(config: config, in: directory)
    }

    /// Rewrites an existing shortcut in place with `config` (same folder; the name may change the bundle file name).
    func regenerate(record: ShortcutRecord, config: ShortcutConfig) throws -> URL {
        let directory = record.bundleURL.deletingLastPathComponent()
        let newURL = directory.appending(path: "\(ShortcutConfig.fileSystemName(for: config.name)).app", directoryHint: .isDirectory)
        if newURL.standardizedFileURL != record.bundleURL.standardizedFileURL, fileManager.fileExists(atPath: newURL.path) {
            throw BuilderError.alreadyExists(newURL)
        }
        let written = try write(config: config, in: directory)
        if written.standardizedFileURL != record.bundleURL.standardizedFileURL {
            try fileManager.removeItem(at: record.bundleURL)
        }
        return written
    }

    /// A new shortcut with the same target and launch settings, its own slug, bundle id and default data folder.
    func duplicate(record: ShortcutRecord, newName: String, in directory: URL) throws -> URL {
        var config = record.config
        config.name = newName
        config.slug = ShortcutConfig.slug(for: newName)
        config.bundleIdentifier = ShortcutConfig.bundleIdentifier(forSlug: config.slug)
        config.dataPath = nil
        return try create(config: config, in: directory)
    }

    /// Copies the bundle to `destination` (an `.app` path chosen by the user). The copy keeps its signature.
    func export(record: ShortcutRecord, to destination: URL) throws -> URL {
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.copyItem(at: record.bundleURL, to: destination)
        return destination
    }

    /// Moves the bundle to the Trash; with `removeData`, also trashes the shortcut's data folder (never the target).
    func delete(record: ShortcutRecord, removeData: Bool) throws {
        try fileManager.trashItem(at: record.bundleURL, resultingItemURL: nil)
        guard removeData else { return }
        let home = fileManager.homeDirectoryForCurrentUser
        let dataPath = record.config.dataPath ?? ShortcutConfig.defaultDataPath(forSlug: record.config.slug, home: home)
        let dataURL = URL(fileURLWithPath: dataPath, isDirectory: true)
        if fileManager.fileExists(atPath: dataURL.path) {
            try fileManager.trashItem(at: dataURL, resultingItemURL: nil)
        }
    }

    private func write(config: ShortcutConfig, in directory: URL) throws -> URL {
        let targetURL = URL(fileURLWithPath: config.targetPath)
        guard fileManager.fileExists(atPath: targetURL.path) else { throw BuilderError.targetMissing(config.targetPath) }
        let app = try AppInspector().inspect(appAt: targetURL)
        let scratch = fileManager.temporaryDirectory.appending(path: "mad-build-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let icon = try IconResolver.iconFile(for: config, app: app, scratchDirectory: scratch)
        let bundle = try BundleWriter(fileManager: fileManager).write(config: config, app: app, launcherBinary: launcherBinary, iconFile: icon, to: directory)
        try Signer().sign(bundle: bundle, identity: signingIdentity)
        return bundle
    }
}
```

(`try?` on scratch cleanup only.)

- [ ] **Step 9: Run builder tests**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/ShortcutBuilderTests 2>&1 | tail -3`
Expected: 6 passed. If `AppInspector` rejects the `/bin/ls` copy (platform binary flag is fine; it just forces systemLaunch in the plan), the test still passes because the builder does not run the planner.

- [ ] **Step 10: Write the failing tests for installed apps, log reader, badge, preview**

`App/Tests/Services/InstalledAppsTests.swift`:

```swift
import XCTest
@testable import MacAppDuplicator

final class InstalledAppsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try makeAppTemporaryDirectory() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    func testScanListsAppsSkipsShortcutsLocalizedAndNonApps() throws {
        try writeFakeTarget(named: "Zed", bundleIdentifier: "com.example.zed", version: "2.0", in: dir)
        try writeFakeTarget(named: "alpha", bundleIdentifier: "com.example.alpha", version: "1.0", in: dir)
        try writeShortcutBundle(named: "Zed Work", in: dir, config: makeConfig(name: "Zed Work"))
        try FileManager.default.createDirectory(at: dir.appending(path: ".localized"), withIntermediateDirectories: true)
        try Data().write(to: dir.appending(path: "notes.txt"))

        let apps = InstalledApps.scan(folders: [dir, dir.appending(path: "missing")])

        XCTAssertEqual(apps.map(\.name), ["alpha", "Zed"])
        XCTAssertEqual(apps.map(\.bundleIdentifier), ["com.example.alpha", "com.example.zed"])
        XCTAssertEqual(apps.first?.version, "1.0")
    }

    func testDefaultFolders() {
        XCTAssertEqual(InstalledApps.defaultFolders.map(\.path), ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path])
    }
}
```

`App/Tests/Services/LogReaderTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class LogReaderTests: XCTestCase {
    func testTailReturnsLastLinesOfExistingLogAndEmptyForMissing() throws {
        let name = "mad-test-\(UUID().uuidString)"
        let logger = LaunchLogger(name: name)
        defer { try? FileManager.default.removeItem(at: logger.fileURL) }
        for i in 1...5 { logger.log("line \(i)") }

        let tail = LogReader.tail(name: name, lines: 2)
        XCTAssertEqual(tail.count, 2)
        XCTAssertTrue(tail[1].hasSuffix("line 5"))
        XCTAssertEqual(LogReader.tail(name: "mad-never-\(UUID().uuidString)"), [])
        XCTAssertEqual(LogReader.logFolder(), logger.fileURL.deletingLastPathComponent())
    }
}
```

`App/Tests/Services/CompatBadgeTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class CompatBadgeTests: XCTestCase {
    private func app(family: AppFamily) -> InspectedApp {
        InspectedApp(bundleURL: URL(fileURLWithPath: "/tmp/x.app"), bundleIdentifier: "x", name: "x", version: "1",
                     executableURL: URL(fileURLWithPath: "/tmp/x.app/Contents/MacOS/x"), family: family, isSandboxed: false,
                     iconFileURL: nil, isPlatformBinary: false, hasLaunchConstraints: false, lsEnvironment: [:], warnings: [])
    }

    func testBadges() {
        XCTAssertEqual(CompatBadge.badge(for: nil), .unknown)
        XCTAssertEqual(CompatBadge.badge(for: app(family: .native)), .homeOnly)
        XCTAssertEqual(CompatBadge.badge(for: app(family: .electron)), .auto)
        XCTAssertEqual(CompatBadge.badge(for: app(family: .chromium)), .auto)
    }

    func testLabels() {
        XCTAssertEqual(CompatBadge.verified.label, "Verified")
        XCTAssertEqual(CompatBadge.auto.label, "Auto")
        XCTAssertEqual(CompatBadge.homeOnly.label, "HOME only")
        XCTAssertEqual(CompatBadge.unsupported.label, "Unsupported")
        XCTAssertEqual(CompatBadge.unknown.label, "Unknown")
    }
}
```

`App/Tests/Services/LaunchPlanPreviewTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class LaunchPlanPreviewTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeAppTemporaryDirectory()
        let target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "1", in: dir)
        try FileManager.default.removeItem(at: target.appending(path: "Contents/MacOS/Target"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: target.appending(path: "Contents/MacOS/Target"))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    func testPreviewMasksSecretsAndCarriesArgsWarningsAndMode() throws {
        var config = makeConfig(targetPath: dir.appending(path: "Target.app").path)
        config.environment = ["API_TOKEN": "abc", "PLAIN": "1"]
        config.arguments = ["--x"]

        let preview = try LaunchPlanPreview.make(config: config, bundleURL: nil)

        XCTAssertTrue(preview.executablePath.hasSuffix("Contents/MacOS/Target"))
        XCTAssertEqual(preview.arguments.last, "--x")
        XCTAssertEqual(preview.maskedEnvironment["API_TOKEN"], SecretMasking.maskedValue)
        XCTAssertEqual(preview.maskedEnvironment["PLAIN"], "1")
        XCTAssertEqual(preview.environmentAdditions["API_TOKEN"], SecretMasking.maskedValue)
        XCTAssertNil(preview.environmentAdditions["PATH"], "inherited variables are not additions")
        XCTAssertEqual(preview.launchMode, .systemLaunch, "/bin/ls is a platform binary; the planner forces System Launch")
        XCTAssertFalse(preview.warnings.isEmpty)
    }

    func testPreviewMissingTargetThrows() {
        XCTAssertThrowsError(try LaunchPlanPreview.make(config: makeConfig(targetPath: dir.appending(path: "Nope.app").path), bundleURL: nil))
    }
}
```

- [ ] **Step 11: Implement `InstalledApps`, `LogReader`, `CompatBadge`, `LaunchPlanPreview`, `AppLauncher`**

`App/Sources/Services/InstalledApps.swift`:

```swift
import DuplicatorCore
import Foundation

struct InstalledApp: Identifiable, Hashable, Sendable {
    var id: URL { url }
    var url: URL
    var name: String
    var bundleIdentifier: String
    var version: String?
}

/// Apps offered by the New Shortcut wizard (spec §7): depth-1 `.app` bundles in `/Applications` and `~/Applications`,
/// excluding shortcuts this app made (they carry `MADConfig`).
enum InstalledApps {
    static let defaultFolders: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
    ]

    static func scan(folders: [URL] = defaultFolders) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        for folder in folders {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for entry in entries where entry.pathExtension == "app" {
                guard let bundle = Bundle(url: entry), let info = bundle.infoDictionary,
                      info[ShortcutConfig.infoPlistKey] == nil,
                      let identifier = info["CFBundleIdentifier"] as? String else { continue }
                let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? entry.deletingPathExtension().lastPathComponent
                apps.append(InstalledApp(url: entry, name: name, bundleIdentifier: identifier, version: info["CFBundleShortVersionString"] as? String))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
```

`App/Sources/Services/LogReader.swift`:

```swift
import DuplicatorCore
import Foundation

/// Reads the launcher's per-shortcut log (`~/Library/Logs/App Duplicator/<name>.log`) for Diagnostics (spec §7).
enum LogReader {
    static func logFolder() -> URL {
        LaunchLogger(name: "placeholder").fileURL.deletingLastPathComponent()
    }

    /// The last `lines` lines of the shortcut's log; empty when there is no log yet.
    static func tail(name: String, lines: Int = 200) -> [String] {
        let url = LaunchLogger(name: name).fileURL
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let all = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        return Array(all.suffix(lines))
    }
}
```

`App/Sources/Services/CompatBadge.swift`:

```swift
import DuplicatorCore

/// Sidebar/editor compatibility badge (spec §7). `verified` and `unsupported` come from profiles in Phase 3;
/// Phase 2 only produces `auto`, `homeOnly` and `unknown`.
enum CompatBadge: String, Sendable {
    case verified = "Verified"
    case auto = "Auto"
    case homeOnly = "HOME only"
    case unsupported = "Unsupported"
    case unknown = "Unknown"

    var label: String { rawValue }

    static func badge(for app: InspectedApp?) -> CompatBadge {
        guard let app else { return .unknown }
        return app.family == .native ? .homeOnly : .auto
    }
}
```

`App/Sources/Services/LaunchPlanPreview.swift`:

```swift
import DuplicatorCore
import Foundation

/// What the launcher would exec for a config, with secrets masked, for Diagnostics and the wizard review step (spec §7).
struct LaunchPlanPreview: Sendable {
    var executablePath: String
    var arguments: [String]
    /// Full target environment, masked per `SecretMasking`.
    var maskedEnvironment: [String: String]
    /// Only the variables the launcher adds or changes relative to this process's environment, masked.
    var environmentAdditions: [String: String]
    var warnings: [String]
    var launchMode: LaunchMode

    static func make(config: ShortcutConfig, bundleURL: URL?) throws -> LaunchPlanPreview {
        let app = try AppInspector().inspect(appAt: URL(fileURLWithPath: config.targetPath))
        let base = ProcessInfo.processInfo.environment
        let plan = DataSeparationPlanner().plan(app: app, config: config, baseEnvironment: base, shortcutBundleURL: bundleURL)
        return LaunchPlanPreview(
            executablePath: plan.executableURL.path,
            arguments: plan.arguments,
            maskedEnvironment: SecretMasking.mask(plan.environment),
            environmentAdditions: SecretMasking.mask(plan.environmentAdditions(relativeTo: base)),
            warnings: plan.warnings,
            launchMode: plan.launchMode
        )
    }
}
```

`App/Sources/Services/AppLauncher.swift`:

```swift
import AppKit
import Foundation

/// Launch and reveal (spec §7 actions). Launching a shortcut is exactly what Finder does: LaunchServices opens the
/// shortcut bundle, the launcher inside takes over.
enum AppLauncher {
    @MainActor
    static func launch(_ record: ShortcutRecord) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: record.bundleURL, configuration: configuration)
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
```

- [ ] **Step 12: Run all app tests**

Run: `cd "$REPO" && Tools/test-app.sh 2>&1 | tail -4`
Expected: `** TEST SUCCEEDED **`; 13 (Task 4) + 3 + 8 + 6 + 2 + 1 + 2 + 2 = 37 tests.

- [ ] **Step 13: Commit**

```bash
cd "$REPO" && git add App/Sources/Services App/Tests/Services && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -q -F - <<'MSG'
feat(app): services — identities, icons, shortcut builder, installed apps, logs, badges, preview

ShortcutBuilder wraps BundleWriter + Signer for create, regenerate,
duplicate, export and delete (trash, data folder optional). IconResolver
maps the three icon modes to an .icns via IconRenderer (iconutil).
SigningIdentities parses `security find-identity`; InstalledApps lists
candidate targets; LaunchPlanPreview renders a masked argv/env preview.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 6: Library UI (app state, sidebar, rows, editor, sheets, actions)

**Files:**
- Create: `App/Sources/App/AppState.swift`
- Create: `App/Sources/Views/ContentView.swift` (replaces the Task 3 placeholder), `SidebarView.swift`, `ShortcutRowView.swift`, `ShortcutEditorView.swift`, `EditorSections.swift`, `EnvironmentTableView.swift`, `ExportSheet.swift`, `DeleteShortcutSheet.swift`, `RebuildAllSheet.swift`, `EmptyLibraryView.swift`
- Modify: `App/Sources/App/MacAppDuplicatorApp.swift`
- Create: `App/Tests/App/AppStateTests.swift`

**Interfaces:**
- Consumes: Task 4 `ShortcutLibrary`, `ShortcutRecord`, `AppSettings`, `RunningShortcutMonitor`; Task 5 `ShortcutBuilder`, `AppLauncher`, `LaunchPlanPreview`, `CompatBadge`, `SigningIdentities`; Task 3 `EmbeddedLauncher.url`.
- Produces (used by Tasks 7–8):
  - `@MainActor @Observable final class AppState { let settings: AppSettings; let library: ShortcutLibrary; var selection: URL?; var isWizardPresented: Bool; var wizardPrefillTarget: URL?; var pendingError: AppError?; var builder: ShortcutBuilder (computed from settings + EmbeddedLauncher.url); init(settings:library:); func create(config:) async -> URL?; func save(record:config:) async -> Bool; func launch(_:) async; func reveal(_:); func regenerate(_:) async; func rebuildAll() async -> Int; func duplicate(_:newName:) async; func export(_:to:) async -> Bool; func delete(_:removeData:) async; func present(_ error: Error, context: String) }`
  - `struct AppError: Identifiable { let id = UUID(); var context: String; var message: String }`
  - `enum SidebarSection: String, CaseIterable, Identifiable { case apps = "Apps", webApps = "Web Apps", filesAndFolders = "Files & Folders", commands = "Commands"; var kinds: [ShortcutKind]; func records(in: ShortcutLibrary) -> [ShortcutRecord] }`
  - Views listed above. `ContentView` takes `AppState` from the environment (`@Environment(AppState.self)`).
  - Focused value for menu commands: `extension FocusedValues { var appState: AppState? }` — not needed; `AppState` is passed as an environment object and the `commands` block holds its own reference.

**UI copy (verbatim, spec §7 and §11):**
- Window title: `App Duplicator`.
- Sidebar section headers: `Apps`, `Web Apps`, `Files & Folders`, `Commands`. Hidden when empty, except `Apps`, which shows the empty state.
- Empty state (no shortcuts anywhere): title `No shortcuts yet`, body `Create a shortcut to run a second copy of an app with its own data, icon and Dock tile.`, button `New Shortcut…`.
- Row: name; subtitle `<target name> <version>` or `Target missing` in red; green running dot with accessibility label `Running`; badge `Needs rebuild` when `record.needsRebuild`.
- Editor sections: `Identity`, `Target`, `Launch`, `Advanced`, `Actions`.
- Identity fields: `Name`, `Icon` (picker `Copied from target` / `Custom file…` / `Generated tile`), icon preview 64 pt.
- Target fields: `Application` (path, read-only, with `Choose…`), `Bundle ID` (read-only), `Compatibility` badge label from `CompatBadge`.
- Launch fields: `Launch mode` (picker `Dock Shortcut` / `System Launch`), `Data` (picker `Auto` / `HOME override` / `Disabled`), `Data folder` (path + `Choose…`, enabled unless Disabled), `Appearance` (picker `System` / `Light` / `Dark`), `Language` (text field, placeholder `en`, help `Two-letter language code, blank for system`).
- Advanced: `Arguments` (one per line text editor, help `One argument per line`), `Environment` table (`Name`, `Value`, reveal toggle), `Erase data on quit` toggle (disabled with help `Coming in Phase 6`), `Menu bar icon` toggle (disabled, same help).
- Actions row: buttons `Launch`, `Reveal in Finder`, `Regenerate`, `Duplicate…`, `Export…`, `Delete…`.
- Editor footer: `Revert`, `Save` (default). Unsaved marker in window: `hasChanges` → Save enabled; Save rewrites + signs.
- Toolbar: `New Shortcut` (plus icon, ⌘N), `Rebuild All` (disabled when `recordsNeedingRebuild` is empty).
- ExportSheet: title `Export Shortcut`, body `The exported shortcut is signed with your identity. On another Mac, Gatekeeper may block it until you remove the quarantine flag:`, code snippet `xattr -dr com.apple.quarantine "<path>"`, buttons `Copy Command`, `Done`.
- DeleteShortcutSheet: title `Delete “<name>”?`, body `The shortcut is moved to the Trash. The target app is never touched.`, toggle `Also move the data folder to the Trash` (default off), help text showing the data folder path, buttons `Cancel`, `Delete` (destructive).
- RebuildAllSheet: title `Rebuild <n> shortcuts?`, body `Each shortcut is rewritten with the current launcher and signed again. Settings are kept.`, buttons `Cancel`, `Rebuild`.
- Duplicate prompt: alert `Duplicate Shortcut`, text field placeholder `New name`, default `<name> Copy`, buttons `Cancel`, `Duplicate`.
- Error alert: title `<context>` (e.g. `Could not save shortcut`), message `error.localizedDescription`, button `OK`.
- Help menu item: `Known Limitations` (opens the Task 8 window; Task 6 wires the menu to a `KnownLimitationsView()` placeholder defined in Task 8 — until Task 8 lands, the Task 6 implementer adds a one-line `struct KnownLimitationsView: View { var body: some View { Text("Known limitations are listed here in Task 8.").padding() } }` in `App/Sources/Views/KnownLimitationsView.swift`, which Task 8 replaces).

- [ ] **Step 1: Write the failing `AppState` tests**

`App/Tests/App/AppStateTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

@MainActor
final class AppStateTests: XCTestCase {
    private var dir: URL!
    private var out: URL!
    private var target: URL!
    private var settings: AppSettings!
    private var library: ShortcutLibrary!
    private var state: AppState!

    override func setUp() async throws {
        dir = try makeAppTemporaryDirectory()
        out = dir.appending(path: "out", directoryHint: .isDirectory)
        target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "1", in: dir)
        try FileManager.default.removeItem(at: target.appending(path: "Contents/MacOS/Target"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: target.appending(path: "Contents/MacOS/Target"))
        let (defaults, _) = makeTestDefaults()
        settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        settings.outputFolder = out
        library = ShortcutLibrary(settings: settings)
        let launcher = dir.appending(path: "Launcher")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: launcher)
        state = AppState(settings: settings, library: library, launcherBinary: launcher)
    }

    override func tearDown() async throws {
        library.stop()
        try FileManager.default.removeItem(at: dir)
    }

    private func config(name: String = "Target Work") -> ShortcutConfig {
        var c = makeConfig(name: name, targetPath: target.path)
        c.iconMode = .generated
        return c
    }

    func testCreateSelectsNewRecordAndRescans() async throws {
        let url = await state.create(config: config())
        XCTAssertNotNil(url)
        XCTAssertEqual(state.selection, url)
        XCTAssertEqual(library.records.map(\.name), ["Target Work"])
        XCTAssertNil(state.pendingError)
    }

    func testCreateDuplicateNameReportsError() async throws {
        _ = await state.create(config: config())
        let second = await state.create(config: config())
        XCTAssertNil(second)
        XCTAssertEqual(state.pendingError?.context, "Could not create shortcut")
    }

    func testSaveRewritesAndKeepsSelection() async throws {
        let url = try XCTUnwrap(await state.create(config: config()))
        let record = try XCTUnwrap(library.record(for: url))
        var updated = record.config
        updated.arguments = ["--a"]
        let ok = await state.save(record: record, config: updated)
        XCTAssertTrue(ok)
        XCTAssertEqual(library.record(for: url)?.config.arguments, ["--a"])
        XCTAssertEqual(state.selection, url)
    }

    func testSaveWithRenameMovesSelection() async throws {
        let url = try XCTUnwrap(await state.create(config: config()))
        let record = try XCTUnwrap(library.record(for: url))
        var updated = record.config
        updated.name = "Target Personal"
        updated.slug = ShortcutConfig.slug(for: updated.name)
        updated.bundleIdentifier = ShortcutConfig.bundleIdentifier(forSlug: updated.slug)
        XCTAssertTrue(await state.save(record: record, config: updated))
        XCTAssertEqual(library.records.map(\.name), ["Target Personal"])
        XCTAssertEqual(state.selection?.lastPathComponent, "Target Personal.app")
    }

    func testDuplicateExportDeleteRoundTrip() async throws {
        let url = try XCTUnwrap(await state.create(config: config()))
        let record = try XCTUnwrap(library.record(for: url))
        await state.duplicate(record, newName: "Target Two")
        XCTAssertEqual(library.records.map(\.name), ["Target Two", "Target Work"])

        let exported = dir.appending(path: "Exported.app")
        XCTAssertTrue(await state.export(record, to: exported))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))

        await state.delete(record, removeData: false)
        XCTAssertEqual(library.records.map(\.name), ["Target Two"])
        XCTAssertNil(state.selection)
    }

    func testRebuildAllRewritesOnlyStaleRecords() async throws {
        _ = await state.create(config: config())
        try writeShortcutBundle(named: "Old One", in: out, config: config(name: "Old One"), engineVersion: 0)
        await library.rescan()
        XCTAssertEqual(library.recordsNeedingRebuild.map(\.name), ["Old One"])
        let count = await state.rebuildAll()
        XCTAssertEqual(count, 1)
        XCTAssertTrue(library.recordsNeedingRebuild.isEmpty)
    }
}
```

Note the `AppState` initializer takes `launcherBinary:` so tests can inject a stand-in; the app passes `EmbeddedLauncher.url`.

- [ ] **Step 2: Implement `AppState`**

`App/Sources/App/AppState.swift`:

```swift
import AppKit
import DuplicatorCore
import Observation

struct AppError: Identifiable {
    let id = UUID()
    var context: String
    var message: String
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case apps = "Apps"
    case webApps = "Web Apps"
    case filesAndFolders = "Files & Folders"
    case commands = "Commands"

    var id: String { rawValue }

    /// `Files & Folders` spans two kinds; every other section maps to one.
    var kinds: [ShortcutKind] {
        switch self {
        case .apps: [.app]
        case .webApps: [.webApp]
        case .filesAndFolders: [.file, .folder]
        case .commands: [.cli]
        }
    }

    func records(in library: ShortcutLibrary) -> [ShortcutRecord] {
        kinds.flatMap { library.records(ofKind: $0) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Window-level state and every mutating action (spec §7). Views call these; they never touch ShortcutBuilder directly.
@MainActor
@Observable
final class AppState {
    let settings: AppSettings
    let library: ShortcutLibrary
    private let launcherBinary: URL

    var selection: URL?
    var isWizardPresented = false
    var wizardPrefillTarget: URL?
    var pendingError: AppError?

    init(settings: AppSettings, library: ShortcutLibrary, launcherBinary: URL) {
        self.settings = settings
        self.library = library
        self.launcherBinary = launcherBinary
    }

    var builder: ShortcutBuilder {
        ShortcutBuilder(launcherBinary: launcherBinary, signingIdentity: settings.signerIdentity)
    }

    var selectedRecord: ShortcutRecord? {
        selection.flatMap { library.record(for: $0) }
    }

    func present(_ error: Error, context: String) {
        pendingError = AppError(context: context, message: error.localizedDescription)
    }

    /// Creates in the output folder, rescans, selects the new bundle. Returns nil (and sets `pendingError`) on failure.
    func create(config: ShortcutConfig) async -> URL? {
        do {
            let url = try builder.create(config: config, in: settings.outputFolder)
            await library.rescan()
            selection = url
            return url
        } catch {
            present(error, context: "Could not create shortcut")
            return nil
        }
    }

    func save(record: ShortcutRecord, config: ShortcutConfig) async -> Bool {
        do {
            let url = try builder.regenerate(record: record, config: config)
            await library.rescan()
            selection = url
            return true
        } catch {
            present(error, context: "Could not save shortcut")
            return false
        }
    }

    func launch(_ record: ShortcutRecord) async {
        do { try await AppLauncher.launch(record) } catch { present(error, context: "Could not launch shortcut") }
    }

    func reveal(_ record: ShortcutRecord) {
        AppLauncher.revealInFinder(record.bundleURL)
    }

    func regenerate(_ record: ShortcutRecord) async {
        _ = await save(record: record, config: record.config)
    }

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

    func duplicate(_ record: ShortcutRecord, newName: String) async {
        do {
            let url = try builder.duplicate(record: record, newName: newName, in: record.bundleURL.deletingLastPathComponent())
            await library.rescan()
            selection = url
        } catch {
            present(error, context: "Could not duplicate shortcut")
        }
    }

    func export(_ record: ShortcutRecord, to destination: URL) async -> Bool {
        do {
            _ = try builder.export(record: record, to: destination)
            return true
        } catch {
            present(error, context: "Could not export shortcut")
            return false
        }
    }

    func delete(_ record: ShortcutRecord, removeData: Bool) async {
        do {
            try builder.delete(record: record, removeData: removeData)
            if selection == record.bundleURL { selection = nil }
            await library.rescan()
        } catch {
            present(error, context: "Could not delete shortcut")
        }
    }
}
```

- [ ] **Step 3: Run `AppStateTests`**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/AppStateTests 2>&1 | tail -3`
Expected: 6 passed. `ShortcutKind` cases are `app, webApp, file, folder, cli` (`Packages/DuplicatorCore/Sources/DuplicatorCore/Enums.swift`).

- [ ] **Step 4: App entry point and scenes**

Replace `App/Sources/App/MacAppDuplicatorApp.swift`:

```swift
import SwiftUI

@main
struct MacAppDuplicatorApp: App {
    @State private var appState: AppState

    init() {
        let settings = AppSettings(defaultSigningIdentity: SigningIdentities.defaultIdentity(from: SigningIdentities.load()))
        let library = ShortcutLibrary(settings: settings)
        _appState = State(initialValue: AppState(settings: settings, library: library, launcherBinary: EmbeddedLauncher.url))
    }

    var body: some Scene {
        WindowGroup("App Duplicator") {
            ContentView()
                .environment(appState)
                .frame(minWidth: 820, minHeight: 520)
                .task { appState.library.start() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Shortcut…") { appState.isWizardPresented = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .help) {
                Button("Known Limitations") { openLimitations() }
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }

        Window("Known Limitations", id: "known-limitations") {
            KnownLimitationsView()
                .frame(minWidth: 520, minHeight: 420)
        }
    }

    @Environment(\.openWindow) private var openWindow

    private func openLimitations() {
        openWindow(id: "known-limitations")
    }
}
```

`SettingsView` is Task 8. Until then the Task 6 implementer adds `App/Sources/Views/SettingsView.swift` containing `struct SettingsView: View { var body: some View { Text("Settings arrive in Task 8.").padding() } }`, which Task 8 replaces (same for `KnownLimitationsView`, see UI copy above). Both placeholders are listed in the commit so Task 8 modifies rather than creates them.

- [ ] **Step 5: ContentView, sidebar, row, empty state**

`App/Sources/Views/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var isRebuildAllPresented = false

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            SidebarView(selection: $appState.selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let record = appState.selectedRecord {
                ShortcutEditorView(record: record)
                    .id(record.bundleURL)
            } else if appState.library.records.isEmpty {
                EmptyLibraryView { appState.isWizardPresented = true }
            } else {
                ContentUnavailableView("Select a shortcut", systemImage: "square.on.square")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { appState.isWizardPresented = true } label: { Label("New Shortcut", systemImage: "plus") }
                    .help("New Shortcut (⌘N)")
            }
            ToolbarItem {
                Button("Rebuild All") { isRebuildAllPresented = true }
                    .disabled(appState.library.recordsNeedingRebuild.isEmpty)
            }
        }
        .sheet(isPresented: $appState.isWizardPresented) {
            NewShortcutWizard()
        }
        .sheet(isPresented: $isRebuildAllPresented) {
            RebuildAllSheet(count: appState.library.recordsNeedingRebuild.count) {
                _ = await appState.rebuildAll()
            }
        }
        .alert(item: $appState.pendingError) { error in
            Alert(title: Text(error.context), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let app = urls.first(where: { $0.pathExtension == "app" }) else { return false }
            appState.wizardPrefillTarget = app
            appState.isWizardPresented = true
            return true
        }
    }
}
```

`NewShortcutWizard` is Task 7; Task 6 adds the placeholder `App/Sources/Views/Wizard/NewShortcutWizard.swift`:

```swift
import SwiftUI

struct NewShortcutWizard: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Text("The New Shortcut wizard arrives in Task 7.")
            Button("Close") { dismiss() }
        }
        .padding(24)
    }
}
```

`App/Sources/Views/SidebarView.swift`:

```swift
import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Binding var selection: URL?

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarSection.allCases) { section in
                let records = section.records(in: appState.library)
                if !records.isEmpty || section == .apps {
                    Section(section.rawValue) {
                        ForEach(records) { record in
                            ShortcutRowView(record: record, isRunning: appState.library.isRunning(record))
                                .tag(record.bundleURL)
                                .contextMenu { rowMenu(record) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if !appState.library.warnings.isEmpty {
                VStack {
                    Spacer()
                    Label("\(appState.library.warnings.count) unreadable bundle(s) skipped", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(appState.library.warnings.joined(separator: "\n"))
                        .padding(8)
                }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ record: ShortcutRecord) -> some View {
        Button("Launch") { Task { await appState.launch(record) } }
        Button("Reveal in Finder") { appState.reveal(record) }
        Divider()
        Button("Regenerate") { Task { await appState.regenerate(record) } }
    }
}
```

`App/Sources/Views/ShortcutRowView.swift`:

```swift
import SwiftUI

struct ShortcutRowView: View {
    let record: ShortcutRecord
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.name).lineLimit(1)
                    if record.needsRebuild {
                        Text("Needs rebuild")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: Capsule())
                    }
                }
                subtitle
                    .font(.caption)
                    .lineLimit(1)
            }
            Spacer()
            if isRunning {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Running")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var icon: some View {
        if let url = record.iconURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if record.targetExists {
            let targetName = URL(fileURLWithPath: record.config.targetPath).deletingPathExtension().lastPathComponent
            Text([targetName, record.targetVersion].compactMap { $0 }.joined(separator: " "))
                .foregroundStyle(.secondary)
        } else {
            Text("Target missing").foregroundStyle(.red)
        }
    }
}
```

`App/Sources/Views/EmptyLibraryView.swift`:

```swift
import SwiftUI

struct EmptyLibraryView: View {
    let onNew: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No shortcuts yet", systemImage: "square.on.square.dashed")
        } description: {
            Text("Create a shortcut to run a second copy of an app with its own data, icon and Dock tile.")
        } actions: {
            Button("New Shortcut…", action: onNew).buttonStyle(.borderedProminent)
        }
    }
}
```

- [ ] **Step 6: Editor**

`App/Sources/Views/ShortcutEditorView.swift`:

```swift
import DuplicatorCore
import SwiftUI

/// Edits a copy of the record's config; Save rewrites and signs the bundle, Revert discards (spec §7).
struct ShortcutEditorView: View {
    @Environment(AppState.self) private var appState
    let record: ShortcutRecord

    @State private var draft: ShortcutConfig
    @State private var inspected: InspectedApp?
    @State private var isSaving = false
    @State private var isDuplicatePromptPresented = false
    @State private var duplicateName = ""
    @State private var exportedURL: URL?
    @State private var isDeletePresented = false

    init(record: ShortcutRecord) {
        self.record = record
        _draft = State(initialValue: record.config)
    }

    private var hasChanges: Bool { draft != record.config }

    var body: some View {
        Form {
            IdentitySection(draft: $draft, record: record)
            TargetSection(draft: $draft, inspected: inspected)
            LaunchSection(draft: $draft)
            AdvancedSection(draft: $draft)
            Section("Actions") {
                HStack {
                    Button("Launch") { Task { await appState.launch(record) } }
                        .disabled(!record.targetExists)
                    Button("Reveal in Finder") { appState.reveal(record) }
                    Button("Regenerate") { Task { await appState.regenerate(record) } }
                    Button("Duplicate…") {
                        duplicateName = "\(record.name) Copy"
                        isDuplicatePromptPresented = true
                    }
                    Button("Export…") { exportPanel() }
                    Button("Delete…", role: .destructive) { isDeletePresented = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(record.name)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if record.needsRebuild {
                    Label("Built with an older launcher. Save or Regenerate to update.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { draft = record.config }.disabled(!hasChanges || isSaving)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges || isSaving || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            .background(.bar)
        }
        .task(id: record.config.targetPath) {
            inspected = try? AppInspector().inspect(appAt: URL(fileURLWithPath: record.config.targetPath))
        }
        .alert("Duplicate Shortcut", isPresented: $isDuplicatePromptPresented) {
            TextField("New name", text: $duplicateName)
            Button("Cancel", role: .cancel) {}
            Button("Duplicate") { Task { await appState.duplicate(record, newName: duplicateName) } }
                .disabled(duplicateName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .sheet(item: $exportedURL) { url in
            ExportSheet(exportedURL: url)
        }
        .sheet(isPresented: $isDeletePresented) {
            DeleteShortcutSheet(record: record) { removeData in
                await appState.delete(record, removeData: removeData)
            }
        }
    }

    private func save() {
        isSaving = true
        var config = draft
        config.name = config.name.trimmingCharacters(in: .whitespaces)
        if config.name != record.config.name {
            config.slug = ShortcutConfig.slug(for: config.name)
            config.bundleIdentifier = ShortcutConfig.bundleIdentifier(forSlug: config.slug)
        }
        Task {
            _ = await appState.save(record: record, config: config)
            isSaving = false
        }
    }

    private func exportPanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = record.bundleURL.lastPathComponent
        panel.allowedContentTypes = [.applicationBundle]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if await appState.export(record, to: url) { exportedURL = url }
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
```

(The one `try?` on `AppInspector().inspect` in `.task` is deliberate: a missing target is already shown by the row and the badge falls back to `Unknown`.)

The `inspect` call is synchronous file I/O on the main actor; the target's Info.plist is small and this runs once per selection, which is acceptable for Phase 2. If the implementer prefers, wrap it in `Task.detached` and assign back on the main actor.

`App/Sources/Views/EditorSections.swift`:

```swift
import DuplicatorCore
import SwiftUI
import UniformTypeIdentifiers

struct IdentitySection: View {
    @Binding var draft: ShortcutConfig
    let record: ShortcutRecord

    var body: some View {
        Section("Identity") {
            TextField("Name", text: $draft.name)
            Picker("Icon", selection: $draft.iconMode) {
                Text("Copied from target").tag(IconMode.copied)
                Text("Custom file…").tag(IconMode.custom)
                Text("Generated tile").tag(IconMode.generated)
            }
            if draft.iconMode == .custom {
                LabeledContent("Icon file") {
                    HStack {
                        Text(draft.customIconPath ?? "No file chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { chooseIcon() }
                    }
                }
            }
            LabeledContent("Preview") {
                if let url = record.iconURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().frame(width: 64, height: 64)
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 48)).foregroundStyle(.secondary).frame(width: 64, height: 64)
                }
            }
        }
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.icns, .png, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { draft.customIconPath = url.path }
    }
}

struct TargetSection: View {
    @Binding var draft: ShortcutConfig
    let inspected: InspectedApp?

    var body: some View {
        Section("Target") {
            LabeledContent("Application") {
                HStack {
                    Text(draft.targetPath).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button("Choose…") { chooseTarget() }
                }
            }
            LabeledContent("Bundle ID", value: draft.targetBundleIdentifier)
            LabeledContent("Compatibility") {
                Text(CompatBadge.badge(for: inspected).label)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            if let inspected, !inspected.warnings.isEmpty {
                ForEach(inspected.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chooseTarget() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let identifier = Bundle(url: url)?.bundleIdentifier else { return }
        draft.targetPath = url.path
        draft.targetBundleIdentifier = identifier
    }
}

struct LaunchSection: View {
    @Binding var draft: ShortcutConfig

    var body: some View {
        Section("Launch") {
            Picker("Launch mode", selection: $draft.launchMode) {
                Text("Dock Shortcut").tag(LaunchMode.dockShortcut)
                Text("System Launch").tag(LaunchMode.systemLaunch)
            }
            Picker("Data", selection: $draft.dataMode) {
                Text("Auto").tag(DataMode.auto)
                Text("HOME override").tag(DataMode.homeOverride)
                Text("Disabled").tag(DataMode.disabled)
            }
            LabeledContent("Data folder") {
                HStack {
                    Text(draft.dataPath ?? ShortcutConfig.defaultDataPath(forSlug: draft.slug, home: FileManager.default.homeDirectoryForCurrentUser))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") { chooseDataFolder() }
                    if draft.dataPath != nil { Button("Default") { draft.dataPath = nil } }
                }
            }
            .disabled(draft.dataMode == .disabled)
            Picker("Appearance", selection: $draft.appearance) {
                Text("System").tag(Appearance.system)
                Text("Light").tag(Appearance.light)
                Text("Dark").tag(Appearance.dark)
            }
            TextField("Language", text: Binding(
                get: { draft.languageCode ?? "" },
                set: { draft.languageCode = $0.isEmpty ? nil : $0 }
            ), prompt: Text("en"))
            .help("Two-letter language code, blank for system")
        }
    }

    private func chooseDataFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { draft.dataPath = url.path }
    }
}

struct AdvancedSection: View {
    @Binding var draft: ShortcutConfig

    var body: some View {
        Section("Advanced") {
            LabeledContent("Arguments") {
                TextEditor(text: Binding(
                    get: { draft.arguments.joined(separator: "\n") },
                    set: { draft.arguments = $0.split(whereSeparator: \.isNewline).map(String.init) }
                ))
                .font(.body.monospaced())
                .frame(minHeight: 60)
                .help("One argument per line")
            }
            EnvironmentTableView(environment: $draft.environment)
            Toggle("Erase data on quit", isOn: $draft.eraseOnQuit).disabled(true).help("Coming in Phase 6")
            Toggle("Menu bar icon", isOn: $draft.menuBarIcon).disabled(true).help("Coming in Phase 6")
        }
    }
}
```

Case names above match `Enums.swift` (`LaunchMode.dockShortcut/.systemLaunch`, `DataMode.auto/.homeOverride/.disabled`, `Appearance.system/.light/.dark`).

- [ ] **Step 7: Environment table**

`App/Sources/Views/EnvironmentTableView.swift`:

```swift
import DuplicatorCore
import SwiftUI

/// Name/value editor. Values whose names match `SecretMasking` are hidden until the row's eye toggle is on (spec §7).
struct EnvironmentTableView: View {
    @Binding var environment: [String: String]
    @State private var revealed: Set<String> = []
    @State private var newName = ""
    @State private var newValue = ""

    private var names: [String] { environment.keys.sorted() }

    var body: some View {
        LabeledContent("Environment") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(names, id: \.self) { name in
                    HStack {
                        Text(name).font(.body.monospaced()).frame(width: 160, alignment: .leading)
                        if SecretMasking.isSecretKey(name) && !revealed.contains(name) {
                            Text(SecretMasking.maskedValue).foregroundStyle(.secondary)
                        } else {
                            TextField("Value", text: Binding(
                                get: { environment[name] ?? "" },
                                set: { environment[name] = $0 }
                            )).font(.body.monospaced())
                        }
                        if SecretMasking.isSecretKey(name) {
                            Toggle(isOn: Binding(
                                get: { revealed.contains(name) },
                                set: { if $0 { revealed.insert(name) } else { revealed.remove(name) } }
                            )) { Image(systemName: revealed.contains(name) ? "eye.slash" : "eye") }
                            .toggleStyle(.button)
                            .help(revealed.contains(name) ? "Hide value" : "Reveal value")
                        }
                        Button { environment.removeValue(forKey: name) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove \(name)")
                    }
                }
                HStack {
                    TextField("Name", text: $newName).font(.body.monospaced()).frame(width: 160)
                    TextField("Value", text: $newValue).font(.body.monospaced())
                    Button { add() } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Add variable")
                }
            }
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        environment[name] = newValue
        newName = ""
        newValue = ""
    }
}
```

- [ ] **Step 8: Sheets**

`App/Sources/Views/ExportSheet.swift`:

```swift
import AppKit
import SwiftUI

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let exportedURL: URL

    private var command: String { "xattr -dr com.apple.quarantine \"\(exportedURL.path)\"" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Shortcut").font(.headline)
            Text("The exported shortcut is signed with your identity. On another Mac, Gatekeeper may block it until you remove the quarantine flag:")
                .fixedSize(horizontal: false, vertical: true)
            Text(command)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
```

`App/Sources/Views/DeleteShortcutSheet.swift`:

```swift
import DuplicatorCore
import SwiftUI

struct DeleteShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss
    let record: ShortcutRecord
    let onDelete: (Bool) async -> Void
    @State private var removeData = false

    private var dataPath: String {
        record.config.dataPath ?? ShortcutConfig.defaultDataPath(forSlug: record.config.slug, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete “\(record.name)”?").font(.headline)
            Text("The shortcut is moved to the Trash. The target app is never touched.")
            Toggle("Also move the data folder to the Trash", isOn: $removeData)
            Text(dataPath).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    Task {
                        await onDelete(removeData)
                        dismiss()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
```

`App/Sources/Views/RebuildAllSheet.swift`:

```swift
import SwiftUI

struct RebuildAllSheet: View {
    @Environment(\.dismiss) private var dismiss
    let count: Int
    let onRebuild: () async -> Void
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rebuild \(count) shortcuts?").font(.headline)
            Text("Each shortcut is rewritten with the current launcher and signed again. Settings are kept.")
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(isWorking)
                Button("Rebuild") {
                    isWorking = true
                    Task {
                        await onRebuild()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
```

- [ ] **Step 9: Build and run tests**

Run: `cd "$REPO" && Tools/build-app.sh 2>&1 | tail -3 && Tools/test-app.sh 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`, `** TEST SUCCEEDED **`, 37 + 6 = 43 tests.

- [ ] **Step 10: UI smoke (implementer)**

Run the built app for five seconds and confirm it opens a window with the empty state or the existing `~/Applications/App Duplicator` shortcuts in the sidebar, then quit it:

```bash
cd "$REPO" && APP=$(find .build/app -name "MacAppDuplicator.app" -maxdepth 4 | head -1) && open "$APP" && sleep 5 && osascript -e 'tell application "MacAppDuplicator" to quit' 2>/dev/null || pkill -x MacAppDuplicator; echo "smoke done"
```

Do not launch any shortcut from the UI during the smoke. Record what the sidebar showed in the report.

- [ ] **Step 11: Commit**

```bash
cd "$REPO" && git add App/Sources App/Tests && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -q -F - <<'MSG'
feat(app): library window — sidebar, editor, sheets, actions

AppState owns the selection and every mutating action (create, save,
launch, regenerate, rebuild all, duplicate, export, delete) and surfaces
errors as alerts. NavigationSplitView with four kind sections, rows with
icon/version/running dot/Needs rebuild badge, grouped Form editor with
explicit Save/Revert, environment table with per-row secret reveal, and
export/delete/rebuild sheets. Wizard, Settings and Known Limitations are
placeholders replaced in Tasks 7 and 8.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 7: New Shortcut wizard

**Files:**
- Replace: `App/Sources/Views/Wizard/NewShortcutWizard.swift` (Task 6 placeholder)
- Create: `App/Sources/Views/Wizard/WizardModel.swift`, `WizardSteps.swift`, `InstalledAppsGrid.swift`, `AppDropZone.swift`
- Create: `App/Tests/Wizard/WizardModelTests.swift`

**Interfaces:**
- Consumes: `AppState` (`create(config:) async -> URL?`, `isWizardPresented`, `wizardPrefillTarget`, `settings.outputFolder`), `InstalledApps.scan(folders:)`, `InstalledApp`, `AppInspector().inspect(appAt:)`, `CompatBadge.badge(for:)`, `LaunchPlanPreview.make(config:bundleURL:)`, `ShortcutConfig`, `IconMode`, `DataMode`, `LaunchMode`.
- Produces:
  - `@MainActor @Observable final class WizardModel { enum Step: Int, CaseIterable { case kind, target, identity, data, review }; var step: Step; var kind: ShortcutKind; var targetURL: URL?; var inspected: InspectedApp?; var inspectError: String?; var name: String; var iconMode: IconMode; var customIconPath: String?; var dataMode: DataMode; var dataPath: String?; var launchMode: LaunchMode; var preview: LaunchPlanPreview?; var previewError: String?; var isCreating: Bool; init(prefillTarget: URL? = nil); var canAdvance: Bool; var isLastStep: Bool; func selectTarget(_ url: URL); func next(); func back(); func makeConfig() -> ShortcutConfig; func refreshPreview() }`
  - `struct NewShortcutWizard: View` (sheet root; reads `AppState` from environment; on Create calls `appState.create(config:)` and dismisses on success).
  - `struct InstalledAppsGrid: View { let apps: [InstalledApp]; @Binding var selection: URL? }`
  - `struct AppDropZone: View { let onDrop: (URL) -> Void; let onBrowse: () -> Void }`

**UI copy (verbatim):**
- Sheet title `New Shortcut`; step indicator `Step <n> of 5`.
- Kind step: title `What do you want to duplicate?`; options `Application` (enabled, subtitle `Run a second copy of an installed app with its own data`), `Web App` / `File or Folder` / `Command` (disabled, subtitle `Coming in a later phase`).
- Target step: title `Choose the application`; search field placeholder `Search applications`; drop zone text `Drop an app here` and button `Browse…`; inspect error shown red under the grid; on selection a footer line `<name> <version> · <CompatBadge label>`.
- Identity step: title `Name and icon`; `Name` field (default `<target name> Copy`, help `This becomes the Dock title and the bundle name`); `Icon` picker `Copied from target` / `Custom file…` / `Generated tile`; `Choose…` button when custom; preview 96 pt (target icon, custom file, or generated tile via `IconRenderer.generatedTile(initials:size:)`); `Launch mode` picker `Dock Shortcut` / `System Launch` (System Launch preselected and Dock Shortcut disabled when `inspected.hasLaunchConstraints || inspected.isPlatformBinary`, with help `This app is protected by launch constraints; System Launch is required`).
- Data step: title `Where does its data live?`; picker `Auto` (subtitle `Native apps get a separate HOME; Electron and Chromium apps get a separate user-data folder`), `HOME override` (subtitle `Always run with a separate HOME folder`), `Disabled` (subtitle `Share data with the original app. Two copies may conflict.`); `Data folder` path with `Choose…` / `Default`; note `Default: ~/Library/Application Support/App Duplicator/<slug>`.
- Review step: title `Review`; rows `Name`, `Target`, `Compatibility`, `Launch mode`, `Data`, `Icon`; collapsible `Launch plan` disclosure with `Executable`, `Arguments` (monospaced, one per line), `Environment additions` (masked, name=value per line), `Warnings` (each with triangle icon); `Create` button (default action), spinner while creating.
- Footer: `Cancel`, `Back` (hidden on first step), `Next` / `Create`.

- [ ] **Step 1: Write the failing `WizardModel` tests**

`App/Tests/Wizard/WizardModelTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

@MainActor
final class WizardModelTests: XCTestCase {
    private var dir: URL!
    private var target: URL!

    override func setUp() async throws {
        dir = try makeAppTemporaryDirectory()
        target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "2.1", in: dir)
        try FileManager.default.removeItem(at: target.appending(path: "Contents/MacOS/Target"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: target.appending(path: "Contents/MacOS/Target"))
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: dir)
    }

    func testInitialStateWithoutPrefill() {
        let model = WizardModel()
        XCTAssertEqual(model.step, .kind)
        XCTAssertEqual(model.kind, .app)
        XCTAssertTrue(model.canAdvance)
        XCTAssertNil(model.targetURL)
    }

    func testPrefillSkipsToIdentity() {
        let model = WizardModel(prefillTarget: target)
        XCTAssertEqual(model.step, .identity)
        XCTAssertEqual(model.targetURL, target)
        XCTAssertEqual(model.name, "Target Copy")
        XCTAssertNotNil(model.inspected)
    }

    func testTargetStepBlocksUntilSelected() {
        let model = WizardModel()
        model.next()
        XCTAssertEqual(model.step, .target)
        XCTAssertFalse(model.canAdvance)
        model.selectTarget(target)
        XCTAssertTrue(model.canAdvance)
        XCTAssertEqual(model.name, "Target Copy")
    }

    func testPlatformBinaryForcesSystemLaunch() {
        let model = WizardModel(prefillTarget: target)
        XCTAssertEqual(model.launchMode, .systemLaunch)
        XCTAssertTrue(model.inspected?.isPlatformBinary ?? false)
    }

    func testIdentityStepBlocksOnEmptyName() {
        let model = WizardModel(prefillTarget: target)
        model.name = "   "
        XCTAssertFalse(model.canAdvance)
        model.name = "Work"
        XCTAssertTrue(model.canAdvance)
    }

    func testMakeConfigDerivesSlugAndBundleIdentifier() {
        let model = WizardModel(prefillTarget: target)
        model.name = "Target Work"
        model.dataMode = .homeOverride
        model.iconMode = .generated
        let config = model.makeConfig()
        XCTAssertEqual(config.kind, .app)
        XCTAssertEqual(config.name, "Target Work")
        XCTAssertEqual(config.slug, ShortcutConfig.slug(for: "Target Work"))
        XCTAssertEqual(config.bundleIdentifier, ShortcutConfig.bundleIdentifier(forSlug: config.slug))
        XCTAssertEqual(config.targetPath, target.path)
        XCTAssertEqual(config.targetBundleIdentifier, "com.example.target")
        XCTAssertEqual(config.dataMode, .homeOverride)
        XCTAssertEqual(config.iconMode, .generated)
        XCTAssertEqual(config.launchMode, .systemLaunch)
        XCTAssertNil(config.dataPath)
    }

    func testReviewStepBuildsPreview() {
        let model = WizardModel(prefillTarget: target)
        model.next() // data
        model.next() // review
        XCTAssertEqual(model.step, .review)
        XCTAssertTrue(model.isLastStep)
        XCTAssertNotNil(model.preview)
        XCTAssertNil(model.previewError)
        XCTAssertEqual(model.preview?.launchMode, .systemLaunch)
        XCTAssertEqual(model.preview?.executablePath, target.appending(path: "Contents/MacOS/Target").path)
    }

    func testBackStopsAtFirstStep() {
        let model = WizardModel()
        model.back()
        XCTAssertEqual(model.step, .kind)
    }
}
```

- [ ] **Step 2: Implement `WizardModel`**

`App/Sources/Views/Wizard/WizardModel.swift`:

```swift
import DuplicatorCore
import Foundation
import Observation

/// State for the New Shortcut sheet. Pure model: no AppKit, so it is unit-testable.
@MainActor
@Observable
final class WizardModel {
    enum Step: Int, CaseIterable {
        case kind, target, identity, data, review
    }

    var step: Step = .kind
    var kind: ShortcutKind = .app
    private(set) var targetURL: URL?
    private(set) var inspected: InspectedApp?
    private(set) var inspectError: String?
    var name = ""
    var iconMode: IconMode = .copied
    var customIconPath: String?
    var dataMode: DataMode = .auto
    var dataPath: String?
    var launchMode: LaunchMode = .dockShortcut
    private(set) var preview: LaunchPlanPreview?
    private(set) var previewError: String?
    var isCreating = false

    init(prefillTarget: URL? = nil) {
        if let prefillTarget {
            selectTarget(prefillTarget)
            if inspected != nil { step = .identity }
        }
    }

    var isLastStep: Bool { step == .review }

    /// Dock Shortcut cannot exec a protected binary (spec §4.4); the picker is locked to System Launch.
    var requiresSystemLaunch: Bool {
        guard let inspected else { return false }
        return inspected.hasLaunchConstraints || inspected.isPlatformBinary
    }

    var canAdvance: Bool {
        switch step {
        case .kind: kind == .app
        case .target: inspected != nil
        case .identity: !name.trimmingCharacters(in: .whitespaces).isEmpty && (iconMode != .custom || customIconPath != nil)
        case .data: true
        case .review: preview != nil && !isCreating
        }
    }

    func selectTarget(_ url: URL) {
        targetURL = url
        do {
            let app = try AppInspector().inspect(appAt: url)
            inspected = app
            inspectError = nil
            if name.isEmpty || name == defaultName(for: nil) { name = defaultName(for: app) }
            if requiresSystemLaunch { launchMode = .systemLaunch }
        } catch {
            inspected = nil
            inspectError = error.localizedDescription
        }
    }

    private func defaultName(for app: InspectedApp?) -> String {
        guard let app else { return "" }
        return "\(app.name) Copy"
    }

    func next() {
        guard canAdvance, let i = Step.allCases.firstIndex(of: step), i + 1 < Step.allCases.count else { return }
        step = Step.allCases[i + 1]
        if step == .review { refreshPreview() }
    }

    func back() {
        guard let i = Step.allCases.firstIndex(of: step), i > 0 else { return }
        step = Step.allCases[i - 1]
    }

    func makeConfig() -> ShortcutConfig {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let slug = ShortcutConfig.slug(for: trimmed)
        return ShortcutConfig(
            kind: kind,
            name: trimmed,
            slug: slug,
            bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: slug),
            targetPath: targetURL?.path ?? "",
            targetBundleIdentifier: inspected?.bundleIdentifier ?? "",
            launchMode: requiresSystemLaunch ? .systemLaunch : launchMode,
            dataMode: dataMode,
            dataPath: dataPath,
            iconMode: iconMode,
            customIconPath: iconMode == .custom ? customIconPath : nil
        )
    }

    func refreshPreview() {
        do {
            preview = try LaunchPlanPreview.make(config: makeConfig(), bundleURL: nil)
            previewError = nil
        } catch {
            preview = nil
            previewError = error.localizedDescription
        }
    }
}
```

- [ ] **Step 3: Run the model tests**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/WizardModelTests 2>&1 | tail -3`
Expected: 8 passed.

- [ ] **Step 4: Grid and drop zone**

`App/Sources/Views/Wizard/InstalledAppsGrid.swift`:

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
                    .onTapGesture { selection = app.url }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selection == app.url ? .isSelected : [])
                    .accessibilityLabel(app.name)
                }
            }
            .padding(4)
        }
    }
}
```

`App/Sources/Views/Wizard/AppDropZone.swift`:

```swift
import SwiftUI

struct AppDropZone: View {
    let onDrop: (URL) -> Void
    let onBrowse: () -> Void
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app")
            Text("Drop an app here")
            Spacer()
            Button("Browse…", action: onBrowse)
        }
        .padding(12)
        .background(isTargeted ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6])).foregroundStyle(.secondary))
        .dropDestination(for: URL.self) { urls, _ in
            guard let app = urls.first(where: { $0.pathExtension == "app" }) else { return false }
            onDrop(app)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}
```

- [ ] **Step 5: Steps**

`App/Sources/Views/Wizard/WizardSteps.swift`:

```swift
import DuplicatorCore
import SwiftUI
import UniformTypeIdentifiers

struct KindStep: View {
    @Bindable var model: WizardModel

    private struct Option { let kind: ShortcutKind; let title: String; let subtitle: String; let enabled: Bool; let symbol: String }
    private let options = [
        Option(kind: .app, title: "Application", subtitle: "Run a second copy of an installed app with its own data", enabled: true, symbol: "app.badge"),
        Option(kind: .webApp, title: "Web App", subtitle: "Coming in a later phase", enabled: false, symbol: "globe"),
        Option(kind: .folder, title: "File or Folder", subtitle: "Coming in a later phase", enabled: false, symbol: "folder"),
        Option(kind: .cli, title: "Command", subtitle: "Coming in a later phase", enabled: false, symbol: "terminal"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What do you want to duplicate?").font(.title3)
            ForEach(options, id: \.kind) { option in
                Button {
                    model.kind = option.kind
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: option.symbol).font(.title2).frame(width: 32)
                        VStack(alignment: .leading) {
                            Text(option.title)
                            Text(option.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.kind == option.kind { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                    }
                    .padding(10)
                    .background(model.kind == option.kind ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!option.enabled)
            }
        }
    }
}

struct TargetStep: View {
    @Bindable var model: WizardModel
    @State private var apps: [InstalledApp] = []
    @State private var query = ""
    @State private var selection: URL?

    private var filtered: [InstalledApp] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose the application").font(.title3)
            TextField("Search applications", text: $query)
                .textFieldStyle(.roundedBorder)
            InstalledAppsGrid(apps: filtered, selection: $selection)
                .frame(minHeight: 220)
            AppDropZone(onDrop: { select($0) }, onBrowse: browse)
            if let error = model.inspectError {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption)
            }
            if let app = model.inspected {
                Text("\(app.name) \(app.version) · \(CompatBadge.badge(for: app).label)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            apps = await Task.detached { InstalledApps.scan() }.value
            selection = model.targetURL
        }
        .onChange(of: selection) { _, url in
            if let url { model.selectTarget(url) }
        }
    }

    private func select(_ url: URL) {
        selection = url
        model.selectTarget(url)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url { select(url) }
    }
}

struct IdentityStep: View {
    @Bindable var model: WizardModel

    var body: some View {
        Form {
            Text("Name and icon").font(.title3)
            TextField("Name", text: $model.name)
                .help("This becomes the Dock title and the bundle name")
            Picker("Icon", selection: $model.iconMode) {
                Text("Copied from target").tag(IconMode.copied)
                Text("Custom file…").tag(IconMode.custom)
                Text("Generated tile").tag(IconMode.generated)
            }
            if model.iconMode == .custom {
                LabeledContent("Icon file") {
                    HStack {
                        Text(model.customIconPath ?? "No file chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { chooseIcon() }
                    }
                }
            }
            LabeledContent("Preview") { preview.frame(width: 96, height: 96) }
            Picker("Launch mode", selection: $model.launchMode) {
                Text("Dock Shortcut").tag(LaunchMode.dockShortcut)
                Text("System Launch").tag(LaunchMode.systemLaunch)
            }
            .disabled(model.requiresSystemLaunch)
            .help(model.requiresSystemLaunch ? "This app is protected by launch constraints; System Launch is required" : "")
        }
        .formStyle(.columns)
    }

    @ViewBuilder
    private var preview: some View {
        switch model.iconMode {
        case .copied:
            if let url = model.inspected?.iconFileURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable()
            } else if let target = model.targetURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: target.path)).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        case .custom:
            if let path = model.customIconPath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.secondary)
            }
        case .generated:
            Image(decorative: IconRenderer.generatedTile(initials: IconRenderer.initials(for: model.name), size: 192), scale: 2)
                .resizable()
        }
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.icns, .png, .jpeg, .tiff]
        if panel.runModal() == .OK, let url = panel.url { model.customIconPath = url.path }
    }
}

struct DataStep: View {
    @Bindable var model: WizardModel

    private var slug: String { ShortcutConfig.slug(for: model.name.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where does its data live?").font(.title3)
            Picker("Data", selection: $model.dataMode) {
                option("Auto", "Native apps get a separate HOME; Electron and Chromium apps get a separate user-data folder").tag(DataMode.auto)
                option("HOME override", "Always run with a separate HOME folder").tag(DataMode.homeOverride)
                option("Disabled", "Share data with the original app. Two copies may conflict.").tag(DataMode.disabled)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            LabeledContent("Data folder") {
                HStack {
                    Text(model.dataPath ?? ShortcutConfig.defaultDataPath(forSlug: slug, home: FileManager.default.homeDirectoryForCurrentUser))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") { choose() }
                    if model.dataPath != nil { Button("Default") { model.dataPath = nil } }
                }
            }
            .disabled(model.dataMode == .disabled)
            Text("Default: ~/Library/Application Support/App Duplicator/\(slug)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func option(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { model.dataPath = url.path }
    }
}

struct ReviewStep: View {
    let model: WizardModel
    @State private var showPlan = false

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

    private var dataDescription: String {
        switch model.dataMode {
        case .auto: "Auto"
        case .homeOverride: "HOME override"
        case .disabled: "Disabled"
        }
    }

    private var iconDescription: String {
        switch model.iconMode {
        case .copied: "Copied from target"
        case .custom: model.customIconPath.map { "Custom: \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Custom file…"
        case .generated: "Generated tile"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func planRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }
}
```

- [ ] **Step 6: Wizard root**

Replace `App/Sources/Views/Wizard/NewShortcutWizard.swift`:

```swift
import SwiftUI

struct NewShortcutWizard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var model: WizardModel

    init() {
        _model = State(initialValue: WizardModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("New Shortcut").font(.headline)
                Spacer()
                Text("Step \(model.step.rawValue + 1) of \(WizardModel.Step.allCases.count)").font(.caption).foregroundStyle(.secondary)
            }
            Group {
                switch model.step {
                case .kind: KindStep(model: model)
                case .target: TargetStep(model: model)
                case .identity: IdentityStep(model: model)
                case .data: DataStep(model: model)
                case .review: ReviewStep(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.step != .kind {
                    Button("Back") { model.back() }.disabled(model.isCreating)
                }
                if model.isLastStep {
                    Button {
                        create()
                    } label: {
                        if model.isCreating { ProgressView().controlSize(.small) } else { Text("Create") }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canAdvance)
                } else {
                    Button("Next") { model.next() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canAdvance)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .onAppear {
            if let prefill = appState.wizardPrefillTarget {
                model = WizardModel(prefillTarget: prefill)
                appState.wizardPrefillTarget = nil
            }
        }
    }

    private func create() {
        model.isCreating = true
        Task {
            let url = await appState.create(config: model.makeConfig())
            model.isCreating = false
            if url != nil { dismiss() }
        }
    }
}
```

The `AppState.create` failure path leaves the sheet open and raises the error alert from `ContentView` (the alert is attached to the parent, so it appears above the sheet).

- [ ] **Step 7: Build and run all tests**

Run: `cd "$REPO" && Tools/build-app.sh 2>&1 | tail -3 && Tools/test-app.sh 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`, `** TEST SUCCEEDED **`, 43 + 8 = 51 tests.

- [ ] **Step 8: Commit**

```bash
cd "$REPO" && git add App/Sources/Views/Wizard App/Tests/Wizard && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -q -F - <<'MSG'
feat(app): New Shortcut wizard

Five-step sheet (kind, target, identity, data, review) driven by a
testable WizardModel. Installed-app grid with search, drop zone and
Browse, inspector-backed compatibility line, launch-mode lock for
launch-constrained targets, generated-tile preview, and a review step
with the masked launch plan. Only the Application kind is enabled; the
other kinds show "Coming in a later phase".

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 8: Settings, Diagnostics and Known Limitations

**Files:**
- Replace: `App/Sources/Views/SettingsView.swift`, `App/Sources/Views/KnownLimitationsView.swift` (Task 6 placeholders)
- Create: `App/Sources/Views/DiagnosticsView.swift`, `App/Sources/App/KnownLimitations.swift`, `App/Sources/Views/HomeSymlinkListEditor.swift`
- Modify: `App/Sources/Views/ShortcutEditorView.swift` (add a `Diagnostics…` button to the Actions row that presents `DiagnosticsView` as a sheet)
- Create: `App/Tests/App/KnownLimitationsTests.swift`, `App/Tests/App/DiagnosticsModelTests.swift`

**Interfaces:**
- Consumes: `AppSettings` (`outputFolder: URL`, `libraryFolders: [URL]`, `signingIdentity: String`, `homeSymlinkEntries: [String]`, `static adHocIdentityName`, `defaultOutputFolder(home:)`), `SigningIdentities.load()`, `LogReader` (`logFolder()`, `tail(name:lines:)`), `LaunchPlanPreview.make(config:bundleURL:)`, `ShortcutRecord`, `SecretMasking`.
- Produces:
  - `struct KnownLimitation: Identifiable, Hashable { let id: String; let title: String; let detail: String }` and `enum KnownLimitations { static let all: [KnownLimitation] }`.
  - `struct DiagnosticsModel { let shortcutName: String; let bundlePath: String; let targetPath: String; let executablePath: String; let launchMode: String; let arguments: [String]; let environment: [(key: String, value: String)]; let warnings: [String]; let logLines: [String]; let planError: String?; static func make(record: ShortcutRecord, logReader: LogReader = LogReader()) -> DiagnosticsModel; var reportText: String }`.
  - `struct DiagnosticsView: View { let record: ShortcutRecord }`.
  - `struct SettingsView: View`, `struct KnownLimitationsView: View`, `struct HomeSymlinkListEditor: View { @Binding var entries: [String] }`.

**UI copy (verbatim):**
- Settings tabs: `General`, `Signing`, `Data`.
- General: `Output folder` + `Choose…` + `Reset to Default`; `Library folders` list (output folder shown first and locked) with `+` / `−`; `Open Logs Folder` button; footer `Shortcuts are scanned from these folders at launch and whenever they change.`
- Signing: Picker `Signing identity` listing `Ad-hoc` first then each identity from `SigningIdentities.load()`; help text `Developer ID lets Gatekeeper trust exported shortcuts on other Macs. Ad-hoc signatures only work on this Mac.`; if the chosen identity is no longer installed show orange label `Identity not found in keychain; new shortcuts will be signed ad-hoc.`
- Data: heading `HOME override symlinks`; body `When a shortcut runs with a separate HOME, these entries are linked back to your real home folder so the app still sees them.`; list editor with `+` / `−` and `Reset to Default`.
- Diagnostics sheet: title `Diagnostics — <shortcut name>`; sections `Shortcut` (Bundle, Target, Executable, Launch mode), `Arguments`, `Environment` (masked, `KEY=value` rows), `Warnings`, `Recent log (last 200 lines)`; buttons `Copy Report`, `Open Log Folder`, `Done`.
- Known Limitations window content comes from `KnownLimitations.all` (below).

- [ ] **Step 1: Failing tests**

`App/Tests/App/KnownLimitationsTests.swift`:

```swift
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

    func testCoversSpecSection11Topics() {
        let ids = Set(KnownLimitations.all.map(\.id))
        for required in ["launch-constraints", "sandboxed-apps", "single-instance", "dock-redraw", "login-items", "updates", "notifications", "file-associations"] {
            XCTAssertTrue(ids.contains(required), "missing \(required)")
        }
    }
}
```

`App/Tests/App/DiagnosticsModelTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class DiagnosticsModelTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeAppTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    func testMasksSecretsAndIncludesLogTail() throws {
        let target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "1.0", in: dir)
        try FileManager.default.removeItem(at: target.appending(path: "Contents/MacOS/Target"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: target.appending(path: "Contents/MacOS/Target"))
        var config = makeConfig(name: "Target Work", targetPath: target.path)
        config.environment = ["API_TOKEN": "hunter2", "PLAIN": "ok"]
        let bundle = try writeShortcutBundle(named: "Target Work", in: dir, config: config)
        let record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))

        let logs = dir.appending(path: "logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "line1\nline2\n".write(to: logs.appending(path: "Target Work.log"), atomically: true, encoding: .utf8)

        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: logs))
        XCTAssertEqual(model.shortcutName, "Target Work")
        XCTAssertEqual(model.executablePath, target.appending(path: "Contents/MacOS/Target").path)
        XCTAssertEqual(model.launchMode, "System Launch")
        XCTAssertNil(model.planError)
        XCTAssertEqual(model.logLines, ["line1", "line2"])
        let env = Dictionary(uniqueKeysWithValues: model.environment.map { ($0.key, $0.value) })
        XCTAssertEqual(env["API_TOKEN"], SecretMasking.maskedValue)
        XCTAssertEqual(env["PLAIN"], "ok")
        XCTAssertTrue(model.reportText.contains("API_TOKEN=\(SecretMasking.maskedValue)"))
        XCTAssertFalse(model.reportText.contains("hunter2"))
        XCTAssertTrue(model.reportText.contains("line2"))
    }

    func testMissingTargetProducesPlanError() throws {
        let config = makeConfig(name: "Gone", targetPath: dir.appending(path: "Missing.app").path)
        let bundle = try writeShortcutBundle(named: "Gone", in: dir, config: config)
        let record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))
        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: dir))
        XCTAssertNotNil(model.planError)
        XCTAssertEqual(model.logLines, [])
        XCTAssertTrue(model.reportText.contains("Launch plan error"))
    }
}
```

`LogReader(folder:)` does not exist yet: Task 5 declared `LogReader { logFolder() -> URL; tail(name:lines:) }`. Add an initializer `init(folder: URL? = nil)` that overrides `logFolder()` when given; the default (nil) keeps the `~/Library/Logs/App Duplicator` behaviour. Keep Task 5's existing tests passing.

- [ ] **Step 2: Run tests, expect failure**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/KnownLimitationsTests -only-testing:MacAppDuplicatorTests/DiagnosticsModelTests 2>&1 | grep -E "error:|Executed" | head`
Expected: compile errors for `KnownLimitations`, `DiagnosticsModel`, `LogReader(folder:)`.

- [ ] **Step 3: `KnownLimitations`**

`App/Sources/App/KnownLimitations.swift`:

```swift
import Foundation

struct KnownLimitation: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
}

/// Spec §11. Shown in the Known Limitations window and linked from the wizard's compatibility line.
enum KnownLimitations {
    static let all: [KnownLimitation] = [
        KnownLimitation(
            id: "launch-constraints",
            title: "Apple apps and launch-constrained binaries cannot use Dock Shortcut",
            detail: "macOS refuses to run Apple's own apps, and third-party apps that opt into launch constraints, from any process that is not their own bundle. App Duplicator detects this and switches the shortcut to System Launch, which starts a new instance through Launch Services. The Dock then shows the target's own icon and name instead of the shortcut's."
        ),
        KnownLimitation(
            id: "sandboxed-apps",
            title: "Sandboxed apps ignore the HOME override",
            detail: "The App Sandbox fixes an app's container at ~/Library/Containers/<bundle id>, so two copies of a sandboxed app always share data. Shortcuts for sandboxed apps still work for a second Dock icon, but their data stays shared."
        ),
        KnownLimitation(
            id: "single-instance",
            title: "Some apps refuse to run twice",
            detail: "Apps that enforce a single instance with a lock file or a distributed notification exit immediately when a copy is already running, or hand the request to the existing instance. Nothing outside the app can change that."
        ),
        KnownLimitation(
            id: "dock-redraw",
            title: "The Dock tile keeps the shortcut's icon only until the app relaunches itself",
            detail: "Dock Shortcut relies on the Dock never redrawing a tile after the shortcut hands over to the target. Apps that relaunch themselves (for example after an update) come back under their own identity."
        ),
        KnownLimitation(
            id: "login-items",
            title: "Login items and helpers belong to the original app",
            detail: "Background helpers, login items and launch agents registered by the target run once, for the original bundle identifier. A shortcut does not get its own copy of them."
        ),
        KnownLimitation(
            id: "updates",
            title: "The target app updates itself as usual; the shortcut does not",
            detail: "Shortcuts point at the installed app, so an update to the app is picked up on the next launch. A shortcut built with an older App Duplicator launcher shows Needs rebuild in the sidebar; use Rebuild All to refresh it."
        ),
        KnownLimitation(
            id: "notifications",
            title: "Notifications are attributed to the original app",
            detail: "Notification Center keys on the running process's bundle identifier, which after the hand-over is the target's. Both copies share one notification settings entry."
        ),
        KnownLimitation(
            id: "file-associations",
            title: "Shortcuts do not register file types or URL schemes",
            detail: "Documents and links keep opening in the original app. Shortcuts are deliberately invisible to Launch Services' handler tables so they never hijack the target's associations."
        ),
        KnownLimitation(
            id: "electron-dark-mode",
            title: "Forcing dark mode only works for Chromium-based apps",
            detail: "The Dark appearance option adds Chromium's dark-mode flag, which Electron, Chromium and ToDesktop apps honour. Native apps follow the system appearance; only Light can be forced for them."
        ),
    ]
}
```

- [ ] **Step 4: `LogReader(folder:)` and `DiagnosticsModel`**

Modify `App/Sources/Services/LogReader.swift` so the type reads:

```swift
import DuplicatorCore
import Foundation

struct LogReader {
    private let folder: URL?

    init(folder: URL? = nil) {
        self.folder = folder
    }

    func logFolder() -> URL {
        folder ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/App Duplicator")
    }

    func tail(name: String, lines: Int = 200) -> [String] {
        let url = logFolder().appending(path: "\(name).log")
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        let all = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(all.suffix(lines))
    }
}
```

(The `try?` here is pre-existing from Task 5: a missing or unreadable log is "no lines", which is the documented contract. Keep it.)

`App/Sources/Views/DiagnosticsView.swift` (model and view together; the model is small and only this view uses it):

```swift
import DuplicatorCore
import SwiftUI

struct DiagnosticsModel {
    let shortcutName: String
    let bundlePath: String
    let targetPath: String
    let executablePath: String
    let launchMode: String
    let arguments: [String]
    let environment: [(key: String, value: String)]
    let warnings: [String]
    let logLines: [String]
    let planError: String?

    static func make(record: ShortcutRecord, logReader: LogReader = LogReader()) -> DiagnosticsModel {
        let logLines = logReader.tail(name: record.name)
        do {
            let preview = try LaunchPlanPreview.make(config: record.config, bundleURL: record.bundleURL)
            let env = preview.maskedEnvironment.keys.sorted().map { (key: $0, value: preview.maskedEnvironment[$0] ?? "") }
            return DiagnosticsModel(
                shortcutName: record.name,
                bundlePath: record.bundleURL.path,
                targetPath: record.config.targetPath,
                executablePath: preview.executablePath,
                launchMode: preview.launchMode == .systemLaunch ? "System Launch" : "Dock Shortcut",
                arguments: preview.arguments,
                environment: env,
                warnings: preview.warnings,
                logLines: logLines,
                planError: nil
            )
        } catch {
            return DiagnosticsModel(
                shortcutName: record.name,
                bundlePath: record.bundleURL.path,
                targetPath: record.config.targetPath,
                executablePath: "",
                launchMode: record.config.launchMode == .systemLaunch ? "System Launch" : "Dock Shortcut",
                arguments: [],
                environment: [],
                warnings: [],
                logLines: logLines,
                planError: error.localizedDescription
            )
        }
    }

    var reportText: String {
        var lines: [String] = []
        lines.append("App Duplicator diagnostics — \(shortcutName)")
        lines.append("Bundle: \(bundlePath)")
        lines.append("Target: \(targetPath)")
        if let planError {
            lines.append("Launch plan error: \(planError)")
        } else {
            lines.append("Executable: \(executablePath)")
            lines.append("Launch mode: \(launchMode)")
            lines.append("")
            lines.append("Arguments:")
            lines.append(contentsOf: arguments.map { "  \($0)" })
            lines.append("")
            lines.append("Environment:")
            lines.append(contentsOf: environment.map { "  \($0.key)=\($0.value)" })
            if !warnings.isEmpty {
                lines.append("")
                lines.append("Warnings:")
                lines.append(contentsOf: warnings.map { "  \($0)" })
            }
        }
        lines.append("")
        lines.append("Recent log (last \(logLines.count) lines):")
        lines.append(contentsOf: logLines)
        return lines.joined(separator: "\n")
    }
}

struct DiagnosticsView: View {
    let record: ShortcutRecord
    @Environment(\.dismiss) private var dismiss
    @State private var model: DiagnosticsModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics — \(record.name)").font(.headline)
            if let model {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        section("Shortcut") {
                            row("Bundle", model.bundlePath)
                            row("Target", model.targetPath)
                            if let error = model.planError {
                                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
                            } else {
                                row("Executable", model.executablePath)
                                row("Launch mode", model.launchMode)
                            }
                        }
                        if model.planError == nil {
                            section("Arguments") { mono(model.arguments.joined(separator: "\n")) }
                            section("Environment") { mono(model.environment.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")) }
                            if !model.warnings.isEmpty {
                                section("Warnings") {
                                    ForEach(model.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle") }
                                }
                            }
                        }
                        section("Recent log (last 200 lines)") { mono(model.logLines.joined(separator: "\n")) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button("Copy Report") {
                    guard let model else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.reportText, forType: .string)
                }
                .disabled(model == nil)
                Button("Open Log Folder") {
                    NSWorkspace.shared.open(LogReader().logFolder())
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .task {
            let record = record
            model = await Task.detached { DiagnosticsModel.make(record: record) }.value
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }

    private func mono(_ text: String) -> some View {
        Text(text.isEmpty ? "—" : text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}
```

`ShortcutRecord` is `Sendable` (Task 4), so the detached task is legal under strict concurrency.

Modify `App/Sources/Views/ShortcutEditorView.swift`: add `@State private var isDiagnosticsPresented = false`; in the Actions row, after `Export…`, insert `Button("Diagnostics…") { isDiagnosticsPresented = true }`; add `.sheet(isPresented: $isDiagnosticsPresented) { DiagnosticsView(record: record) }`.

- [ ] **Step 5: HOME symlink list editor and Settings**

`App/Sources/Views/HomeSymlinkListEditor.swift`:

```swift
import SwiftUI

/// Editable list of HOME-relative paths. Entries are trimmed; blank entries are dropped on commit.
struct HomeSymlinkListEditor: View {
    @Binding var entries: [String]
    @State private var selection: Int?
    @State private var newEntry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(selection: $selection) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    TextField("Path", text: Binding(
                        get: { entries.indices.contains(index) ? entries[index] : "" },
                        set: { entries[index] = $0 }
                    ))
                    .font(.body.monospaced())
                    .tag(index)
                }
            }
            .frame(minHeight: 140)
            .onSubmit { commit() }
            HStack {
                TextField("Add path, e.g. Library/Keychains", text: $newEntry)
                    .font(.body.monospaced())
                    .onSubmit(add)
                Button(action: add) { Image(systemName: "plus") }
                    .disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    if let selection, entries.indices.contains(selection) {
                        entries.remove(at: selection)
                        self.selection = nil
                    }
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
            }
        }
    }

    private func add() {
        let trimmed = newEntry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !entries.contains(trimmed) else { return }
        entries.append(trimmed)
        newEntry = ""
    }

    private func commit() {
        entries = entries.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
```

Replace `App/Sources/Views/SettingsView.swift`:

```swift
import DuplicatorCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        TabView {
            GeneralSettingsTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            SigningSettingsTab(settings: settings)
                .tabItem { Label("Signing", systemImage: "checkmark.seal") }
            DataSettingsTab(settings: settings)
                .tabItem { Label("Data", systemImage: "folder.badge.gearshape") }
        }
        .frame(width: 560, height: 400)
        .padding()
    }
}

private struct GeneralSettingsTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            LabeledContent("Output folder") {
                HStack {
                    Text(settings.outputFolder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") { chooseOutput() }
                    Button("Reset to Default") {
                        settings.outputFolder = AppSettings.defaultOutputFolder(home: FileManager.default.homeDirectoryForCurrentUser)
                    }
                }
            }
            LabeledContent("Library folders") {
                VStack(alignment: .leading, spacing: 6) {
                    List {
                        Label(settings.outputFolder.path, systemImage: "lock")
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        ForEach(settings.libraryFolders, id: \.self) { folder in
                            HStack {
                                Text(folder.path).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button {
                                    settings.libraryFolders.removeAll { $0 == folder }
                                } label: { Image(systemName: "minus") }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .frame(minHeight: 110)
                    Button { addLibraryFolder() } label: { Image(systemName: "plus") }
                }
            }
            Button("Open Logs Folder") {
                let folder = LogReader().logFolder()
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(folder)
            }
            Text("Shortcuts are scanned from these folders at launch and whenever they change.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.outputFolder
        if panel.runModal() == .OK, let url = panel.url { settings.outputFolder = url }
    }

    private func addLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url, url != settings.outputFolder, !settings.libraryFolders.contains(url) {
            settings.libraryFolders.append(url)
        }
    }
}

private struct SigningSettingsTab: View {
    @Bindable var settings: AppSettings
    @State private var identities: [String] = []

    private var isMissing: Bool {
        settings.signingIdentity != AppSettings.adHocIdentityName && !identities.contains(settings.signingIdentity)
    }

    var body: some View {
        Form {
            Picker("Signing identity", selection: $settings.signingIdentity) {
                Text(AppSettings.adHocIdentityName).tag(AppSettings.adHocIdentityName)
                ForEach(identities, id: \.self) { Text($0).tag($0) }
                if isMissing { Text(settings.signingIdentity).tag(settings.signingIdentity) }
            }
            Text("Developer ID lets Gatekeeper trust exported shortcuts on other Macs. Ad-hoc signatures only work on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            if isMissing {
                Label("Identity not found in keychain; new shortcuts will be signed ad-hoc.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .task { identities = await Task.detached { SigningIdentities.load() }.value }
    }
}

private struct DataSettingsTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOME override symlinks").font(.headline)
            Text("When a shortcut runs with a separate HOME, these entries are linked back to your real home folder so the app still sees them.")
                .font(.caption).foregroundStyle(.secondary)
            HomeSymlinkListEditor(entries: $settings.homeSymlinkEntries)
            HStack {
                Spacer()
                Button("Reset to Default") { settings.homeSymlinkEntries = HomeTreeBuilder.defaultSymlinkEntries }
            }
        }
        .padding(.top, 8)
    }
}
```

`HomeTreeBuilder.defaultSymlinkEntries` (DuplicatorCore) is the same array Task 4 used to seed `homeSymlinkEntries`; do not add an App-side copy. The `try? createDirectory` in `Open Logs Folder` is intentional: an existing folder is the normal case and the error is irrelevant to opening it.

The `SigningSettingsTab` `isMissing` tag row keeps the Picker's selection valid (SwiftUI logs and resets when the selection has no matching tag). The signer side already falls back to ad-hoc when the identity is absent (Task 4's `signerIdentity`).

Replace `App/Sources/Views/KnownLimitationsView.swift`:

```swift
import SwiftUI

struct KnownLimitationsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Known Limitations").font(.title2.weight(.semibold))
                Text("These come from how macOS launches and isolates apps. App Duplicator works around what it can and reports the rest.")
                    .foregroundStyle(.secondary)
                ForEach(KnownLimitations.all) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline)
                        Text(item.detail).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
```

- [ ] **Step 6: Build and run all tests**

Run: `cd "$REPO" && Tools/build-app.sh 2>&1 | tail -3 && Tools/test-app.sh 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`, `** TEST SUCCEEDED **`, 51 + 4 = 55 tests.

- [ ] **Step 7: Commit**

```bash
cd "$REPO" && git add App/Sources App/Tests && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -q -F - <<'MSG'
feat(app): Settings, Diagnostics sheet and Known Limitations

Settings window with General (output and library folders, logs),
Signing (identity picker with missing-identity warning) and Data (HOME
symlink list) tabs. Diagnostics sheet per shortcut shows the resolved
launch plan with masked environment and the last 200 log lines, with a
copyable report. Known Limitations window lists spec §11.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 9: End-to-end test, acceptance checklist, README

**Files:**
- Create: `App/Tests/EndToEnd/ShortcutBuilderEndToEndTests.swift`
- Create: `docs/acceptance/phase2-library-app.md`
- Modify: `README.md` (add a `## Phase 2 library app` section after `## Phase 1 engine`, before `## Phase 2 consumes`; rename `## Phase 2 consumes` to `## Core API used by the app`)

**Interfaces:**
- Consumes: `ShortcutBuilder(launcherBinary:signingIdentity:)` with `create(config:in:)`, `regenerate(record:config:)`, `duplicate(record:newName:in:)`, `export(record:to:)`, `delete(record:removeData:)`; `EmbeddedLauncher.url`; `LibraryScanner.record(forBundleAt:fileManager:)`; `LaunchPlanPreview.make(config:bundleURL:)`; `ShortcutConfig`; test helpers `makeAppTemporaryDirectory()`, `makeConfig(...)`.
- Produces: nothing new in code. The acceptance doc is the manual gate for Phase 2.

- [ ] **Step 1: Build the fixture**

Run: `cd "$REPO" && Tools/build-fixture.sh && ls .build/fixtures/FixtureApp.app/Contents/MacOS`
Expected: `FixtureApp`.

- [ ] **Step 2: End-to-end test**

`App/Tests/EndToEnd/ShortcutBuilderEndToEndTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

/// Builds a real shortcut for the FixtureApp with the embedded Launcher, then verifies the bundle the way
/// Finder, codesign and the library scanner would. Skips when the fixture has not been built.
final class ShortcutBuilderEndToEndTests: XCTestCase {
    private var dir: URL!
    private var fixture: URL!
    private var builder: ShortcutBuilder!

    override func setUpWithError() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        fixture = repoRoot.appending(path: ".build/fixtures/FixtureApp.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.appending(path: "Contents/MacOS/FixtureApp").path),
                          "FixtureApp missing; run Tools/build-fixture.sh")
        dir = try makeAppTemporaryDirectory()
        builder = ShortcutBuilder(launcherBinary: EmbeddedLauncher.url, signingIdentity: nil)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func config(name: String) -> ShortcutConfig {
        makeConfig(name: name, targetPath: fixture.path, targetBundleIdentifier: "com.mikekuta.appduplicator.fixture")
    }

    private func codesignVerify(_ bundle: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", bundle.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testCreateProducesLaunchableSignedBundle() throws {
        let bundle = try builder.create(config: config(name: "Fixture Work"), in: dir)
        XCTAssertEqual(bundle.lastPathComponent, "Fixture Work.app")

        let contents = bundle.appending(path: "Contents")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: contents.appending(path: "MacOS/Fixture Work").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: contents.appending(path: "Resources/AppIcon.icns").path))

        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: contents.appending(path: "Info.plist")), format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, ShortcutConfig.bundleIdentifier(forSlug: ShortcutConfig.slug(for: "Fixture Work")))
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(plist[ShortcutConfig.engineVersionInfoPlistKey] as? Int, ShortcutConfig.currentEngineVersion)
        XCTAssertNotNil(plist[ShortcutConfig.infoPlistKey])

        XCTAssertEqual(try codesignVerify(bundle), 0, "codesign --verify --deep --strict failed")

        let record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))
        XCTAssertEqual(record.name, "Fixture Work")
        XCTAssertEqual(record.targetVersion, "1.0")
        XCTAssertTrue(record.targetExists)
        XCTAssertFalse(record.needsRebuild)
        XCTAssertNotNil(record.iconURL)

        let preview = try LaunchPlanPreview.make(config: record.config, bundleURL: bundle)
        XCTAssertEqual(preview.executablePath, fixture.appending(path: "Contents/MacOS/FixtureApp").path)
        XCTAssertEqual(preview.launchMode, .dockShortcut)
        XCTAssertTrue(preview.environmentAdditions.keys.contains("HOME"), "native fixture should get a HOME override")
        XCTAssertTrue(preview.warnings.isEmpty, "unexpected warnings: \(preview.warnings)")
    }

    func testLifecycleRegenerateDuplicateExportDelete() throws {
        let bundle = try builder.create(config: config(name: "Fixture A"), in: dir)
        var record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))

        var changed = record.config
        changed.appearance = .light
        let regenerated = try builder.regenerate(record: record, config: changed)
        XCTAssertEqual(regenerated, bundle)
        record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))
        XCTAssertEqual(record.config.appearance, .light)
        XCTAssertEqual(try codesignVerify(bundle), 0)

        let copy = try builder.duplicate(record: record, newName: "Fixture B", in: dir)
        XCTAssertEqual(copy.lastPathComponent, "Fixture B.app")
        let copyRecord = try XCTUnwrap(LibraryScanner.record(forBundleAt: copy, fileManager: .default))
        XCTAssertEqual(copyRecord.config.slug, ShortcutConfig.slug(for: "Fixture B"))
        XCTAssertNotEqual(copyRecord.config.bundleIdentifier, record.config.bundleIdentifier)
        XCTAssertEqual(try codesignVerify(copy), 0)

        let exportDir = dir.appending(path: "export")
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let exported = try builder.export(record: copyRecord, to: exportDir.appending(path: "Fixture B.app"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appending(path: "Contents/Info.plist").path))

        try builder.delete(record: copyRecord, removeData: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
    }
}
```

`#filePath` is `App/Tests/EndToEnd/ShortcutBuilderEndToEndTests.swift`; four `deletingLastPathComponent()` calls reach the repo root. If Task 5's `delete(record:removeData:)` moves to the Trash rather than removing, the `fileExists` assertion on `copy.path` still holds (the bundle is gone from its folder).

- [ ] **Step 3: Run the end-to-end tests**

Run: `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/ShortcutBuilderEndToEndTests 2>&1 | tail -4`
Expected: 2 passed, `** TEST SUCCEEDED **`. Then run without the filter: 55 + 2 = 57 tests, `** TEST SUCCEEDED **`.

- [ ] **Step 4: Acceptance checklist**

`docs/acceptance/phase2-library-app.md`:

```markdown
# Phase 2 acceptance: library app

Manual gate. Automated coverage is `Tools/test-app.sh` (57 tests incl. the FixtureApp end-to-end test). The steps below need a person at the Mac. Steps 5 and 6 need Mike (they launch real apps).

## Step 1: Build

```bash
Tools/build-fixture.sh
Tools/build-app.sh
```

Expected: the second command prints the built `.app` path under `.build/DerivedData`. Open it with `open <path>`.

## Step 2: Library loads existing shortcuts

Expected on first launch: the sidebar's Apps section lists `Claude Work` and `Claude Personal` (built by Phase 1 `madctl`) with the Claude icon, subtitle `Claude <version>`, no `Needs rebuild` badge (engine version is still 1). Web Apps, Files & Folders and Commands sections are hidden.

## Step 3: New Shortcut wizard

1. ⌘N. Kind step: only `Application` is selectable; the other three show `Coming in a later phase`.
2. Target step: grid lists `/Applications`; search filters; choosing an Apple app (TextEdit) shows the compatibility line ending `HOME only` or `unsupported`, and the identity step then locks `Launch mode` to `System Launch`.
3. Choose the fixture instead: drag `.build/fixtures/FixtureApp.app` onto the drop zone. Compatibility reads `verified` or `auto`.
4. Identity: default name `FixtureApp Copy`; switch Icon to `Generated tile` and confirm the preview shows the initials `FC`.
5. Data: leave `Auto`. Note reads `Default: ~/Library/Application Support/App Duplicator/fixtureapp-copy`.
6. Review: Launch plan disclosure shows the executable path inside `FixtureApp.app`, `HOME=` and `CFFIXED_USER_HOME=` additions, no warnings. Create.

Expected: sheet closes, `FixtureApp Copy` is selected in the sidebar with the generated tile icon, and `~/Applications/App Duplicator/FixtureApp Copy.app` exists.

## Step 4: Editor

1. Change Name to `Fixture Renamed`, Save. Expected: sidebar row renames, selection follows, `~/Applications/App Duplicator/Fixture Renamed.app` exists and `FixtureApp Copy.app` is gone.
2. Add environment variable `API_TOKEN` = `abc`. Expected: the value shows as `••••••` until the eye toggle is pressed. Save.
3. `Diagnostics…`: Environment shows `API_TOKEN=••••••`; `Copy Report` puts the same masked text on the clipboard.
4. `Duplicate…` with name `Fixture Dup`. Expected: second row appears.
5. `Export…` to the Desktop. Expected: sheet shows the `xattr -dr com.apple.quarantine` command; the exported bundle opens in Finder.
6. `Delete…` on `Fixture Dup` with the data toggle off. Expected: the bundle is in the Trash; the app is still running; selection clears.

## Step 5: Launch (Mike)

Select `Fixture Renamed`, press `Launch`. Expected: a Dock tile titled `Fixture Renamed` with the generated tile icon; the sidebar row shows the green running dot within 2 s; `~/Library/Application Support/App Duplicator/fixture-renamed/` exists. Quit the fixture from its Dock menu. Expected: the dot disappears.

## Step 6: Claude Desktop two-account test (Mike)

Same as Phase 1 Steps 3 to 5 in `phase1-claude-desktop.md`, but launched from the library (`Launch` on `Claude Work`, then on `Claude Personal`). Both rows show the running dot while the two instances are open.

## Step 7: Settings, Rebuild All, Known Limitations

1. Settings → General: change the output folder to a temp folder and back. Expected: library rescans without restart.
2. Settings → Signing: the picker lists `Ad-hoc` and `Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)`. Choose Developer ID, create a shortcut, run `codesign -dv --verbose=2 <bundle>` in Terminal. Expected: `Authority=Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)` and `Runtime Version`. Switch back to Ad-hoc.
3. Edit `Contents/Info.plist` of `Fixture Renamed.app` and set `MADEngineVersion` to `0`. Expected: within 2 s the row shows `Needs rebuild` and the toolbar `Rebuild All` enables. Run it. Expected: badge clears, `codesign --verify --deep --strict` passes.
4. Help → Known Limitations. Expected: window with the nine entries from `KnownLimitations.all`.

## Teardown

Move `~/Applications/App Duplicator/Fixture Renamed.app` and `~/Library/Application Support/App Duplicator/fixture-renamed` to the Trash. Leave `Claude Work.app` and `Claude Personal.app` in place.

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
```

- [ ] **Step 5: README**

Insert after the `## Phase 1 engine` section (before the `## Phase 2 consumes` heading, which becomes `## Core API used by the app`):

```markdown
## Phase 2 library app

`MacAppDuplicator.app` is a SwiftUI library window over the shortcut bundles in `~/Applications/App Duplicator` (plus any folders added in Settings). There is no database: each shortcut's `Info.plist` `MADConfig` dictionary is the record.

### Build and test

```bash
Tools/build-fixture.sh     # test fixture app, needed by the end-to-end test
Tools/build-app.sh         # regenerates the Xcode project with xcodegen, embeds the release Launcher, prints the .app path
Tools/test-app.sh          # MacAppDuplicatorTests (57 tests)
```

The Xcode project under `App/` is generated from `App/project.yml` and git-ignored. Requirements: macOS 26 or later on Apple silicon, Xcode 26 or later, `xcodegen` (`brew install xcodegen`).

### What the app does

- Sidebar of shortcuts grouped by kind, with target version, running indicator and a `Needs rebuild` badge when the embedded launcher is older than the app's.
- New Shortcut wizard: pick an installed app (grid, search, drag-and-drop or Browse), name and icon (copied, custom file or generated tile), data mode, and a review step with the masked launch plan.
- Editor for every `MADConfig` field: launch mode, data mode and folder, appearance, language, arguments, environment (secret-looking keys masked), icon.
- Actions: Launch, Reveal in Finder, Regenerate, Duplicate, Export (with the quarantine-clearing command), Delete (Trash, optional data folder), Rebuild All.
- Diagnostics sheet: resolved executable, argv, masked environment, warnings and the last 200 log lines, copyable.
- Settings: output and library folders, signing identity (Ad-hoc or any Developer ID in the keychain), HOME-override symlink list.
- Help → Known Limitations.

Acceptance checklist: `docs/acceptance/phase2-library-app.md`.
```

- [ ] **Step 6: Commit**

```bash
cd "$REPO" && git add App/Tests/EndToEnd docs/acceptance/phase2-library-app.md README.md && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -q -F - <<'MSG'
test(app): FixtureApp end-to-end test, Phase 2 acceptance checklist, README

Builds a real shortcut with the embedded Launcher against the FixtureApp,
verifies the bundle layout, Info.plist keys, codesign --verify --deep
--strict, scanner record and launch plan preview, then exercises
regenerate, duplicate, export and delete. Skips when the fixture is not
built. Adds the manual acceptance checklist and the README section.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

## Self-review notes

- Spec §7 (library app) coverage: sidebar/rows (Task 6), wizard (7), editor (6), actions incl. Export/Delete/Rebuild All (6), Settings (8), Diagnostics (8), icons (2, 5), signing identity (4, 5, 8), folder watching and running indicator (4). Spec §11 Known Limitations: Task 8.
- Deferred to later phases by design, surfaced in the UI as disabled with a hint: web app / file / folder / command kinds (Phase 4–5), erase-on-quit and menu bar icon (Phase 6), profiles URL (Phase 3), `Locate…` button in launcher alerts (needs the library app's `mad://locate` handler; Phase 3).
- Test count ledger: Core 98 → 110 (Task 1). App bundle: Task 3 smoke 1 → Task 4 13 → Task 5 37 → Task 6 43 → Task 7 51 → Task 8 55 → Task 9 57.
