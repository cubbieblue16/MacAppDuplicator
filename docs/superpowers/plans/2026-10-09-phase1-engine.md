# macOS App Duplicator Phase 1 (Engine) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the DuplicatorCore library, the Launcher executable (Dock Shortcut and System Launch), and the `madctl` generator CLI, gated by the Claude Desktop two-account acceptance test (spec §12 item 1).

**Architecture:** One root SwiftPM package with explicit `path:` targets that match spec §3 (Core library, Launcher, madctl, unit and integration test targets). Core is pure logic (inspect, plan, build HOME tree, write and sign bundles); Launcher is a thin shell that calls `LaunchPreparer` then `execve` or `NSWorkspace`; `madctl` is a thin shell over Core for generating and previewing shortcuts. The helper role (spec §4.6) is deferred and represented by one no-op hook.

**Tech Stack:** Swift 6 language mode (Xcode 27, Swift 6.4), macOS 26+ arm64, Foundation + Security (Core), AppKit (Launcher), swift-argument-parser 1.5.0+ (madctl only), XCTest.

## Global Constraints

- Target macOS 26+, Apple Silicon only. `swift-tools-version: 6.2`, `swiftLanguageModes: [.v6]`, `platforms: [.macOS(.v26)]`.
- DuplicatorCore imports Foundation and Security only (no AppKit). Launcher may import AppKit. madctl is the only target that depends on swift-argument-parser. XCTest only (no swift-testing).
- Never copy, repackage, patch, inject into or re-sign the target app (spec §2). No private APIs; only `execve`, `posix_spawn`, LaunchServices and `NSWorkspace`.
- Secrets never logged: env keys matching `(?i)secret|token|key|password|passwd|credential` are masked in logs, diagnostics and previews (spec §2). The signing identity is referred to by display name only (spec §9).
- Shortcut `Info.plist` carries only the keys in spec §3.2 and never `CFBundleURLTypes`, `CFBundleDocumentTypes`, `UTExportedTypeDeclarations` or `UTImportedTypeDeclarations`. The icon is copied, never symlinked.
- Bundle identifier `com.mikekuta.appduplicator.<slug>`; default data path `~/Library/Application Support/App Duplicator/<slug>`; default output `~/Applications/App Duplicator`.
- Final argv = `[targetExecutable] + plannerArgs + userArgs`; final env = inherited (minus `MAD_*`) + planner + `MAD_SHORTCUT_BUNDLE` and `MAD_SHORTCUT_NAME` + user env (spec §4.4). HOME override sets both `HOME` and `CFFIXED_USER_HOME`. `-AppleInterfaceStyle` is never emitted (spec §4.5).
- Launcher exit codes (spec §4.7): 1 config missing or corrupt, 2 target not found or not an app bundle, 3 exec failed, 4 data path not writable.
- Every commit message ends with the line `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Repository: `/Users/cubbieblue16/Developer/MacAppDuplicator`, branch `main`.
- Additive-only after Task 2: later tasks may add files and add tests, and never delete or weaken an existing public symbol or test.

## Inputs and conventions

- `$DRAFTS` = the draft tree handed to the implementer with this plan. It contains `Packages/DuplicatorCore/Sources/DuplicatorCore/*.swift` (15 files) and `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/*.swift` (10 files). The drafts already implement the pinned public API and design deltas 1 to 7. They compiled once as a library and their tests have never run.
- `$REPO` = `/Users/cubbieblue16/Developer/MacAppDuplicator`. All commands run from `$REPO`.
- Build products: `swift build -c release` produces `$REPO/.build/release/Launcher` and `$REPO/.build/release/madctl`.

## File map

| Path | Responsibility | Task |
|---|---|---|
| `Package.swift`, `.gitignore` | Targets, dependency, ignores | 1 |
| `Packages/DuplicatorCore/Sources/DuplicatorCore/*.swift` | Models, inspection, planning, HOME tree, bundle writing, signing, logging, `LaunchPreparer` | 2 |
| `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/*.swift` | Unit tests (10 drafted, 3 authored here) | 2, 3 |
| `Launcher/Sources/Launcher/{main,Alerts,Exec,SystemLaunch}.swift` | Launch shell | 4, 5 |
| `Tools/madctl/Sources/madctl/*.swift` | `inspect`, `plan`, `new` | 1, 6, 7 |
| `Tests/Fixtures/FixtureApp/main.swift`, `Tools/build-fixture.sh` | Integration fixture app | 8 |
| `Tests/Integration/*.swift` | Gated integration tests | 9 |
| `Tools/smoke-dock-identity.sh`, `docs/acceptance/phase1-claude-desktop.md`, `README.md` | Smoke, acceptance, docs | 10 to 13 |

---

### Task 1: Scaffold the package

**Files:**
- Create: `Package.swift`
- Create: `Packages/DuplicatorCore/Sources/DuplicatorCore/Placeholder.swift`
- Create: `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/PlaceholderTests.swift`
- Create: `Launcher/Sources/Launcher/main.swift`
- Create: `Tools/madctl/Sources/madctl/Madctl.swift`
- Create: `Tests/Integration/PlaceholderTests.swift`
- Modify: `.gitignore` (append two lines)

**Interfaces:**
- Consumes: nothing.
- Produces: targets `DuplicatorCore` (library), `DuplicatorCoreTests`, `Launcher` (executable), `madctl` (executable, depends on `ArgumentParser`), `IntegrationTests`. Later tasks replace the placeholder files and never edit `Package.swift` again.

- [ ] **Step 1: Write `Package.swift` exactly**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacAppDuplicator",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DuplicatorCore", targets: ["DuplicatorCore"]),
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
        .executableTarget(name: "Launcher", dependencies: ["DuplicatorCore"], path: "Launcher/Sources/Launcher"),
        .executableTarget(name: "madctl",
                          dependencies: ["DuplicatorCore", .product(name: "ArgumentParser", package: "swift-argument-parser")],
                          path: "Tools/madctl/Sources/madctl"),
        .testTarget(name: "IntegrationTests", path: "Tests/Integration"),
    ],
    swiftLanguageModes: [.v6]
)
```

- [ ] **Step 2: Write the placeholder sources** (SwiftPM rejects a target directory without a source file)
  - `Placeholder.swift` (Core): one line `import Foundation`.
  - `PlaceholderTests.swift` (both test targets): one line `import XCTest` followed by `final class PlaceholderTests: XCTestCase { func testPlaceholder() {} }`. The IntegrationTests copy is the same text.
  - `Launcher/.../main.swift`: a single comment line `// Launcher entry point; implemented in Task 4.` An `@main` type must not live in a file named `main.swift`, so the Launcher uses top-level code in `main.swift` and no `@main`.
  - `Madctl.swift`: `import ArgumentParser` then `@main struct Madctl: ParsableCommand { static let configuration = CommandConfiguration(commandName: "madctl", abstract: "macOS App Duplicator command-line generator.") }`. madctl uses `@main` in `Madctl.swift`, never in `main.swift`.

- [ ] **Step 3: Append to `.gitignore`** the lines `/.build/` and `/.build/fixtures/`.

- [ ] **Step 4: Build.** Run `swift build 2>&1 | tail -5`. Expected: last line `Build complete!` and zero `error:` lines. The first run fetches swift-argument-parser. Then `swift test 2>&1 | tail -3`. Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Package.resolved .gitignore Packages Launcher Tools Tests
git commit -m "$(cat <<'EOF'
build: scaffold SwiftPM package with Core, Launcher, madctl and test targets

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Import the draft Core and make its unit tests pass

**Files:**
- Delete: `Packages/DuplicatorCore/Sources/DuplicatorCore/Placeholder.swift`, `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/PlaceholderTests.swift`
- Create (copy from `$DRAFTS`, same relative paths): the 15 Core sources `AppInspector, BundleWriter, DataSeparationPlanner, Enums, HomeTreeBuilder, InfoPlistReader, LaunchLogger, LaunchPlan, LaunchPreparer, LauncherError+ExitCode, LauncherError, SecretMasking, ShortcutConfig, Signer, TargetResolver` (each `.swift`) and the 10 test files `AppInspectorTests, DataSeparationPlannerTests, EnumsTests, HomeTreeBuilderTests, LaunchLoggerTests, LauncherErrorTests, SecretMaskingTests, ShortcutConfigTests, TargetResolverTests, TestSupport` (each `.swift`)
- Create (authored here, no draft exists): `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/{BundleWriterTests,SignerTests,LaunchPreparerTests}.swift`

**Interfaces:**
- Consumes: Task 1 targets.
- Produces (public API; the drafts match the brief and add the marked extras; Tasks 4 to 7 rely on these exact signatures):
  - `enum ShortcutKind/LaunchMode/DataMode/Appearance/AppFamily: String, Codable, Sendable` with the pinned cases (`LaunchMode`: `dockShortcut, systemLaunch`; `DataMode`: `auto, homeOverride, disabled`).
  - `struct ShortcutConfig: Codable, Equatable, Sendable`: memberwise `init(kind: = .app, name:, slug:, bundleIdentifier:, targetPath:, targetBundleIdentifier:, launchMode: = .dockShortcut, dataMode: = .auto, dataPath: String? = nil, environment: = [:], arguments: = [], appearance: = .system, languageCode: String? = nil, eraseOnQuit: = false, menuBarIcon: = false, engineVersion: = currentEngineVersion)`; `plistDictionary() -> [String: Any]`; `init(plistDictionary: [String: Any]) throws`; extras: `static let currentEngineVersion = 1`, `infoPlistKey = "MADConfig"`, `engineVersionInfoPlistKey = "MADEngineVersion"`, `static func slug(for:) -> String`, `bundleIdentifier(forSlug:) -> String`, `defaultDataPath(forSlug:home:) -> String`, `fileSystemName(for:) -> String`.
  - `struct InspectedApp: Equatable, Sendable`: `bundleURL, bundleIdentifier, name, version, executableURL, family, isSandboxed, iconFileURL, isPlatformBinary, hasLaunchConstraints, lsEnvironment: [String: String], warnings: [String]` (extra: `warnings`).
  - `struct AppInspector { init(); func inspect(appAt url: URL) throws -> InspectedApp }`.
  - `struct LaunchPlan: Equatable, Sendable`: `executableURL, arguments, environment, directoriesToCreate, homeOverridePath: URL?, warnings, launchMode`; extras `applyingEffectiveHome(_ effectiveHome: URL) -> LaunchPlan`, `environmentAdditions(relativeTo base: [String: String]) -> [String: String]`.
  - `struct DataSeparationPlanner { init(); func plan(app: InspectedApp, config: ShortcutConfig, baseEnvironment: [String: String], shortcutBundleURL: URL? = nil) -> LaunchPlan }` (the defaulted fourth parameter is an extra).
  - `struct HomeTreeBuilder { init(fileManager: FileManager = .default, realHome: URL, symlinkEntries: [String] = HomeTreeBuilder.defaultSymlinkEntries); static let defaultSymlinkEntries: [String]; func materialize(at path: URL) throws -> URL }`.
  - `struct BundleWriter { init(fileManager: FileManager = .default); static let forbiddenInfoPlistKeys: [String]; func write(config: ShortcutConfig, app: InspectedApp, launcherBinary: URL, to directory: URL) throws -> URL }`.
  - `struct Signer { init(); static func arguments(bundle: URL, identity: String?) -> [String]; func sign(bundle: URL, identity: String?) throws }` and `struct SignerError: Error, LocalizedError, Equatable { status: Int32; message: String }`.
  - `enum SecretMasking { static let maskedValue = "••••••"; static func isSecretKey(_:) -> Bool; static func mask(_ env: [String: String]) -> [String: String] }`.
  - `struct TargetResolver { init(); func resolve(config: ShortcutConfig) throws -> URL }`.
  - `enum LauncherError: Error, LocalizedError { configMissing; configCorrupt(String); targetNotFound(path: String, bundleID: String); dataPathNotWritable(String); execFailed(errno: Int32, path: String); notAnAppBundle(String) }` plus `var exitCode: Int32` (1, 2, 3, 4 per Global Constraints).
  - `struct LaunchLogger: Sendable { init(name: String); func log(_ line: String); func log(environment: [String: String]) }` writing `~/Library/Logs/App Duplicator/<Name>.log`, rotating to `.log.1` above 1 048 576 bytes.
  - `struct PreparedLaunch: Equatable, Sendable { config; app; plan }` and `struct LaunchPreparer { init(fileManager: FileManager = .default, realHome: URL); func prepare(infoDictionary: [String: Any], shortcutBundleURL: URL, baseEnvironment: [String: String]) throws -> PreparedLaunch }` (extra to the brief: it runs spec §3.4 steps 2 to 4 in Core so they are unit-tested).

- [ ] **Step 1: Copy the drafts.** `rm` the two placeholder files, then `cp "$DRAFTS"/Packages/DuplicatorCore/Sources/DuplicatorCore/*.swift Packages/DuplicatorCore/Sources/DuplicatorCore/` and the same for `Tests/DuplicatorCoreTests`. Run `find Packages -name '._*' -delete` (macOS copies can carry AppleDouble sidecars) and `ls Packages/DuplicatorCore/Sources/DuplicatorCore | wc -l`. Expected: `15`.

- [ ] **Step 2: Build.** Run `swift build --build-tests 2>&1 | tail -15`. Expected: `Build complete!`. Fix compile errors in place; keep every public signature listed above unchanged.

- [ ] **Step 3: Author `BundleWriterTests.swift`** (XCTest, `@testable import DuplicatorCore`, uses `TestSupport.swift` helpers `makeTemporaryDirectory`, `FixtureBundle`). Build the `InspectedApp` by writing a `FixtureBundle` with `info: ["CFBundleIconFile": "AppIcon", "LSEnvironment": ["A": "target", "B": "target"]]` and `files: ["Resources/AppIcon.icns"]` (then overwrite that file with bytes `[1, 2, 3]`) and calling `AppInspector().inspect`. The launcher binary is a temp file containing the ASCII text `launcher`. Config: name `Claude Work`, slug `claude-work`, `environment: ["B": "shortcut", "C": "shortcut"]`. Tests, each with exact assertions:
  1. `testLayout`: result URL equals `<out>/Claude Work.app`; exist `Contents/Info.plist`, `Contents/PkgInfo` (content `APPL????`), `Contents/MacOS/Claude Work` (content `launcher`, POSIX permissions `0o755`), `Contents/Resources/AppIcon.icns` (content `[1,2,3]`, and `FileManager.destinationOfSymbolicLink` throws, proving a copy).
  2. `testInfoPlistKeys`: plist parses; `CFBundleName` and `CFBundleDisplayName` equal `Claude Work`; `CFBundleIdentifier` equals config's; `CFBundleExecutable` equals `Claude Work`; `CFBundleIconFile` equals `AppIcon`; `CFBundlePackageType` equals `APPL`; `LSMinimumSystemVersion` equals `26.0`; `NSHighResolutionCapable` is `true`; `MADEngineVersion` equals `1`; `ShortcutConfig(plistDictionary: plist["MADConfig"] as! [String: Any]) == config`; file begins with the bytes `<?xml` (XML format).
  3. `testForbiddenKeysAbsent`: none of `BundleWriter.forbiddenInfoPlistKeys` is a key, and no key has prefix `UT`.
  4. `testLSEnvironmentMergeOrder`: `LSEnvironment == ["A": "target", "B": "shortcut", "C": "shortcut"]`.
  5. `testNoIconOmitsIconKeys`: target without icon gives no `CFBundleIconFile` key and no `AppIcon.icns` file.
  6. `testAtomicAndReplacing`: after the write, the names inside `<out>` are exactly `["Claude Work.app"]` (no `.tmp` or `.old` leftovers); a second write with different launcher bytes replaces the bundle, the executable holds the new bytes, and `<out>` still has exactly one entry.
  7. `testSlashInNameBecomesDash`: name `Work/Personal` writes `Work-Personal.app` while `CFBundleName` stays `Work/Personal`.

- [ ] **Step 4: Author `SignerTests.swift`.** Write a bundle with `BundleWriter` using `/usr/bin/true` as `launcherBinary`, call `Signer().sign(bundle:identity: nil)`, then `runCommand("/usr/bin/codesign", ["--verify", "--strict", bundle.path])` must return status 0. Also: `Signer.arguments(bundle: b, identity: nil) == ["--force", "--sign", "-", b.path]`; with identity `Developer ID Application: Example` the array is `["--force", "--sign", "Developer ID Application: Example", "--options", "runtime", "--timestamp", b.path]` and contains no `--deep`; signing a nonexistent path throws `SignerError` with `status != 0` and a non-empty `message`.

- [ ] **Step 5: Author `LaunchPreparerTests.swift`.** Target is `FixtureBundle(name: "Target").writeSigned(in:)` (native, not platform). `realHome` is a temp dir containing an empty `Documents` directory. Tests: (a) `.homeOverride` config with `dataPath` `<tmp>/home` and `Info.plist` dictionary `["MADConfig": config.plistDictionary()]` gives `plan.environment["HOME"] == plan.environment["CFFIXED_USER_HOME"] == <tmp>/home`, the directory exists and holds `Library/Application Support` plus a `Documents` symlink; (b) dictionary without `MADConfig` throws `.configMissing`; (c) `MADConfig` set to a String throws `.configCorrupt`; (d) `targetPath` nonexistent with `targetBundleIdentifier` `com.example.not-installed` throws `.targetNotFound`; (e) `.auto` electron-style target with `dataPath` located under a regular file throws `.dataPathNotWritable` (exit code 4); (f) `.disabled` creates no directories.

- [ ] **Step 6: Run the unit suite.** Run `swift test --filter DuplicatorCoreTests 2>&1 | tail -20`. Expected: `Executed N tests, with 0 failures` (record N), real-app tests run, none skipped for TextEdit or Terminal. Swift 6 pitfalls to avoid when fixing failures: no `static let` `Regex` values (not Sendable; use `String.range(of:options: .regularExpression)` or `NSRegularExpression`); no `override func setUp()` on isolated XCTestCase subclasses (use `addTeardownBlock` as `TestSupport.swift` does); real-app tests keep their `try XCTSkipUnless(FileManager.default.fileExists(...))` guards.

- [ ] **Step 7: Reviewer checklist for this task** (reviewer greps the diff): public API above matches exactly; delta 2 (icon copy in `BundleWriter`), 3 (Info.plist keys and forbidden keys), 4 (`isPlatformBinary`, `hasLaunchConstraints`, `lsEnvironment`, forced `systemLaunch` in the planner), 5 (`HOME` and `CFFIXED_USER_HOME` in the planner), 6 (chromium rule, no `libEGL`), 7 (appearance mapping, no `-AppleInterfaceStyle`) are visible in code and covered by a test; no `@unchecked Sendable`, no `swiftlint:disable`, no empty `catch {}`. The drafts contain `try?` at these sites, all best-effort filesystem probes or cleanup: `ShortcutConfig.swift:69-70`, `BundleWriter.swift:51,83,92,95`, `InfoPlistReader.swift:11-12`, `LaunchLogger.swift:43-55`, `HomeTreeBuilder.swift:75`, `AppInspector.swift:140`. They are accepted as is; this task adds none.

- [ ] **Step 8: Commit**

```bash
git add Packages/DuplicatorCore
git commit -m "$(cat <<'EOF'
feat(core): import DuplicatorCore engine with unit tests

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: AppInspector real-app tests

**Files:**
- Test: `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/AppInspectorTests.swift` (drafted tests already exist at `testTextEditIsASandboxedPlatformBinary`, `testTerminalIsAPlatformBinaryWithoutSandbox`, `testClaudeDesktopIsElectron`; add one test)

**Interfaces:**
- Consumes: `AppInspector.inspect(appAt:) -> InspectedApp`.
- Produces: nothing new.

- [ ] **Step 1: Add `testBraveIsChromium`** in the "Real apps" section of `AppInspectorTests.swift`: path `/Applications/Brave Browser.app`, `try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "Brave Browser is not installed")`, assert `app.family == .chromium`, `app.isPlatformBinary == false`. It guards the §4.2 rule that Brave ships no `libEGL`.

- [ ] **Step 2: Run** `swift test --filter 'AppInspectorTests/test(TextEdit|Terminal|Claude|Brave)' 2>&1 | tail -15`. Expected: four tests, 0 failures; TextEdit asserts `isPlatformBinary == true`, `isSandboxed == true`, `family == .native`; Claude Desktop (when installed) asserts `isPlatformBinary == false`, `family == .electron`. If the output says `skipped` for TextEdit, stop and report: TextEdit always exists on macOS 26+.

- [ ] **Step 3: Commit**

```bash
git add Packages/DuplicatorCore/Tests/DuplicatorCoreTests/AppInspectorTests.swift
git commit -m "$(cat <<'EOF'
test(core): cover Brave as a chromium real-app case

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Launcher, Dock Shortcut path

**Files:**
- Modify: `Launcher/Sources/Launcher/main.swift` (replace the comment)
- Create: `Launcher/Sources/Launcher/Alerts.swift`, `Launcher/Sources/Launcher/Exec.swift`

**Interfaces:**
- Consumes: `LaunchPreparer(realHome:).prepare(infoDictionary:shortcutBundleURL:baseEnvironment:) throws -> PreparedLaunch`; `LaunchLogger(name:)`, `.log(_:)`, `.log(environment:)`; `LauncherError.exitCode`; `LaunchPlan` fields.
- Produces (module-internal): `@MainActor func fail(_ error: Error, logger: LaunchLogger) -> Never` (Alerts.swift); `func execTarget(_ plan: LaunchPlan) -> Int32` returning `errno` only when `execve` returned (Exec.swift); `func spawnHelperIfNeeded(config: ShortcutConfig)` (main.swift or Exec.swift); `@MainActor func launchViaSystem(prepared: PreparedLaunch, logger: LaunchLogger) -> Never` is added in Task 5; this task defines a version that calls `fail(LauncherError.execFailed(errno: ENOTSUP, path: plan.executableURL.path), logger:)`.

- [ ] **Step 1: Specify `main.swift` flow** (top-level code, Swift 6 runs it on the main actor). In order:
  1. `let shortcutName = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent`; `let logger = LaunchLogger(name: shortcutName)`; log `start pid=<getpid()> bundle=<Bundle.main.bundlePath>`.
  2. `let base = ProcessInfo.processInfo.environment`; `let realHome = FileManager.default.homeDirectoryForCurrentUser`.
  3. `do { prepared = try LaunchPreparer(realHome: realHome).prepare(infoDictionary: Bundle.main.infoDictionary ?? [:], shortcutBundleURL: Bundle.main.bundleURL, baseEnvironment: base) } catch { fail(error, logger: logger) }`. `prepare` performs spec §3.4 steps 2 to 4 and the §9 target validation (`AppInspector.inspect` rejects anything that is not a directory ending `.app` with `Contents/Info.plist` and an existing executable `CFBundleExecutable`; it throws `notAnAppBundle`, exit 2). Directories are created and the HOME tree is materialised inside it, so the launcher does not repeat them.
  4. Log `config name=<name> mode=<launchMode> data=<dataMode>`, `target <executable path>`, one `warning <text>` per `plan.warnings`, `argv <joined with spaces after argv[0]>`, `mode <plan.launchMode>`, then `logger.log(environment: plan.environment)` (the logger masks secrets; never log raw env).
  5. `spawnHelperIfNeeded(config: prepared.config)`.
  6. If `prepared.plan.launchMode == .systemLaunch` call `launchViaSystem` (Task 5). Otherwise log `exec` and call `execTarget`; when it returns, `fail(LauncherError.execFailed(errno: code, path: plan.executableURL.path), logger: logger)`.

- [ ] **Step 2: Doc comments to write, with this content:**
  - Above the exec call in `main.swift`: "Dock Shortcut mode (spec §4.1). LaunchServices started this process as the shortcut bundle, so the Dock draws the tile from the shortcut: title is the bundle file name, icon is `CFBundleIconFile`. After `execve`, the target's `LSApplicationCheckIn` (about 0.5 to 1 s later) re-registers this process under the target's bundle id and path, so `lsappinfo`, Activity Monitor and `NSRunningApplication` report the target. The Dock does not redraw on check-in, so the tile keeps the shortcut's name and icon for the life of the process."
  - On `spawnHelperIfNeeded(config:)`: "Fork point for the helper role (spec §4.6: status item, process watch, erase-on-quit). Phase 6 implements it; until then it intentionally does nothing, and the call site exists so the launch order in spec §3.4 step 5 is fixed." Body: `_ = config`.

- [ ] **Step 3: `Exec.swift`.** Build argv and envp as C arrays and call `Darwin.execve`; capture `errno` on the line directly after the call. Free nothing (the process image is replaced on success; on failure the process exits right after the alert).

```swift
import Darwin
import DuplicatorCore

func execTarget(_ plan: LaunchPlan) -> Int32 {
    let path = plan.executableURL.path
    let argv = [path] + plan.arguments
    let envp = plan.environment.map { "\($0.key)=\($0.value)" }.sorted()
    var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    var cEnvp: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) } + [nil]
    Darwin.execve(path, &cArgv, &cEnvp)
    return errno
}
```

- [ ] **Step 4: `Alerts.swift`.** `@MainActor func fail(_ error: Error, logger: LaunchLogger) -> Never`: log `error <localizedDescription>` and `exit <code>`; `let code = (error as? LauncherError)?.exitCode ?? 3`; `NSApplication.shared`, then `NSApp.setActivationPolicy(.regular)` and `NSApp.activate()` before the alert (a faceless process cannot show one otherwise); `NSAlert` with `messageText` `Shortcut could not start`, `informativeText` `error.localizedDescription`, `alertStyle = .critical`, one button `OK`; `runModal()`; `exit(code)`. The spec §4.7 "Locate..." button is deferred to Phase 2 (it needs the library app's `mad://locate` handler).

- [ ] **Step 5: Build and smoke.** `swift build -c release --product Launcher 2>&1 | tail -3` expects `Build complete!`. Negative smoke without a bundle: `.build/release/Launcher; echo "exit=$?"`. Because `Bundle.main.infoDictionary` is nil for a bare binary this opens the alert and exits 1 on OK. Dismiss it with `osascript -e 'tell application "System Events" to click button "OK" of window 1 of (first process whose name is "Launcher")'` run from a second shell, or by clicking OK. Expected final line `exit=1`, and `tail -2 ~/Library/Logs/App\ Duplicator/Launcher.log` shows `exit 1`. The positive path is proven in Tasks 9 and 10.

- [ ] **Step 6: Commit**

```bash
git add Launcher/Sources/Launcher
git commit -m "$(cat <<'EOF'
feat(launcher): Dock Shortcut path with execve, alerts and logging

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Launcher, System Launch path

**Files:**
- Create: `Launcher/Sources/Launcher/SystemLaunch.swift`
- Modify: `Launcher/Sources/Launcher/main.swift` (the `.systemLaunch` branch only; remove the Task 4 stand-in)

**Interfaces:**
- Consumes: `LaunchPlan.environmentAdditions(relativeTo:)`, `LaunchPlan.arguments`, `fail(_:logger:)`, `LauncherError.execFailed`.
- Produces: `@MainActor func launchViaSystem(prepared: PreparedLaunch, logger: LaunchLogger) -> Never` that exits 0 after a successful launch and 3 (via `fail`) otherwise.

- [ ] **Step 1: Specify `launchViaSystem`.** Configure `NSWorkspace.OpenConfiguration`: `arguments = plan.arguments`, `environment = plan.environmentAdditions(relativeTo: ProcessInfo.processInfo.environment)` (LaunchServices merges these over its own environment, so only the differences are sent), `createsNewApplicationInstance = true`, `activates = true`. Call `NSWorkspace.shared.openApplication(at: prepared.app.bundleURL, configuration: configuration) { _, error in ... }`. The handler stores the error text in an `OSAllocatedUnfairLock<String?>` (module `os`) and signals a `DispatchSemaphore`. The handler's queue is not documented, so the main thread must not block on the semaphore. Pump the run loop while polling it, with a 30 s deadline:

```swift
let done = DispatchSemaphore(value: 0)
let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
// openApplication(...) { _, error in failure.withLock { $0 = error?.localizedDescription }; done.signal() }
let deadline = Date(timeIntervalSinceNow: 30)
while done.wait(timeout: .now()) == .timedOut, Date() < deadline {
    RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
}
```

  After the loop: if the deadline passed or `failure` holds a message, log `system launch failed: <text>` and `fail(LauncherError.execFailed(errno: ETIMEDOUT or EIO, path: bundlePath), logger:)` (use `ETIMEDOUT` for the deadline, `EIO` for a reported error); otherwise log `system launch ok` and `exit(0)`.

- [ ] **Step 2: Wire it** in `main.swift`: the `.systemLaunch` branch logs `system launch` and calls `launchViaSystem(prepared:logger:)`.

- [ ] **Step 3: Build.** `swift build -c release --product Launcher 2>&1 | tail -3` expects `Build complete!`. Behavioural proof lands in Task 10 step 4 (fixture launched with `--mode system`).

- [ ] **Step 4: Commit**

```bash
git add Launcher/Sources/Launcher
git commit -m "$(cat <<'EOF'
feat(launcher): System Launch path via NSWorkspace.openApplication

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: madctl `inspect` and `plan`

**Files:**
- Modify: `Tools/madctl/Sources/madctl/Madctl.swift` (register subcommands)
- Create: `Tools/madctl/Sources/madctl/Options.swift`, `ConfigFactory.swift`, `InspectCommand.swift`, `PlanCommand.swift`

**Interfaces:**
- Consumes: `AppInspector`, `DataSeparationPlanner`, `ShortcutConfig` (slug, bundle id, default data path helpers), `SecretMasking.mask`.
- Produces (module-internal, used by Task 7): `struct ShortcutOptions: ParsableArguments` (all shared flags), `func makeConfig(app: InspectedApp, options: ShortcutOptions) throws -> ShortcutConfig`, `func inspectApp(at path: String) throws -> InspectedApp`.

- [ ] **Step 1: `Options.swift`.** Local enums `DataModeOption: String, CaseIterable, ExpressibleByArgument { case auto, home, disabled }` (mapped to `DataMode.auto/.homeOverride/.disabled`), `LaunchModeOption { case dock, system }` (to `.dockShortcut/.systemLaunch`), `AppearanceOption { case system, light, dark }`. `ShortcutOptions`:

```swift
struct ShortcutOptions: ParsableArguments {
    @Option(help: "Shortcut name; defaults to the target app's name.") var name: String?
    @Option(name: .customLong("data-mode"), help: "auto, home or disabled.") var dataMode: DataModeOption = .auto
    @Option(name: .customLong("data-path")) var dataPath: String?
    @Option(help: "dock or system.") var mode: LaunchModeOption = .dock
    @Option(name: .customLong("env"), help: "K=V; repeatable.") var env: [String] = []
    @Option(name: .customLong("arg"), help: "Extra argument; repeatable.") var arg: [String] = []
    @Option var appearance: AppearanceOption = .system
    @Option var language: String?
}
```

- [ ] **Step 2: `ConfigFactory.swift`.** `makeConfig` rules: `name = options.name ?? app.name`; `slug = ShortcutConfig.slug(for: name)`; `bundleIdentifier = ShortcutConfig.bundleIdentifier(forSlug: slug)`; `targetPath = app.bundleURL.path`; `targetBundleIdentifier = app.bundleIdentifier`; `kind = .app`; `dataPath = options.dataPath` if given, else `ShortcutConfig.defaultDataPath(forSlug: slug, home: FileManager.default.homeDirectoryForCurrentUser)` when mode is auto or home, else `nil`; `--env` entries split at the first `=` (a missing `=` or empty key throws `ValidationError("--env expects K=V: <value>")`, exit 64); `--arg` values pass through unchanged; `--language` goes to `languageCode`. `inspectApp(at:)` wraps `AppInspector().inspect(appAt: URL(filePath: path, directoryHint: .isDirectory))`.

- [ ] **Step 3: `inspect` command** (`madctl inspect <app-path>`). Output, one `key: value` per line in this order: `name`, `bundle-id`, `version`, `family`, `sandboxed` (true/false), `platform-binary`, `launch-constraints`, `executable` (path), `icon` (path or `none`), then one `warning: <text>` per entry in `InspectedApp.warnings`. Exit 0. A non-app path prints the `LauncherError` description to stderr and exits 1.

- [ ] **Step 4: `plan` command** (`madctl plan <app-path>` plus the `ShortcutOptions` flags). Resolve the config with `makeConfig`, then `DataSeparationPlanner().plan(app:config:baseEnvironment: ProcessInfo.processInfo.environment)`. Output sections in this exact shape, indentation two spaces:

```
mode: dockShortcut
argv:
  /Applications/Claude.app/Contents/MacOS/Claude
  --user-data-dir=/Users/me/Library/Application Support/App Duplicator/claude-work
env:
  HOME=...            (only variables new or changed versus the current environment, sorted by key, values masked by SecretMasking.mask)
warnings:
  <one per line; the section is omitted when empty>
```
  argv is one element per line with argv[0] first, so spaces inside a path stay visible. The `env:` section uses `plan.environmentAdditions(relativeTo: ProcessInfo.processInfo.environment)` passed through `SecretMasking.mask`.

- [ ] **Step 5: Register** `InspectCommand` and `PlanCommand` in `Madctl.configuration.subcommands`. Build and run:
  - `swift build -c release --product madctl 2>&1 | tail -2` expects `Build complete!`.
  - `.build/release/madctl inspect /Applications/Claude.app` expects `family: electron`, `sandboxed: false`, `platform-binary: false`, `bundle-id: com.anthropic.claudefordesktop` (when installed).
  - `.build/release/madctl plan /Applications/Claude.app --name "Claude Work"` expects an argv line `--user-data-dir=<home>/Library/Application Support/App Duplicator/claude-work`, and an env section containing `MAD_SHORTCUT_NAME=Claude Work`.
  - `.build/release/madctl plan /System/Applications/TextEdit.app` expects `mode: systemLaunch` and a `warnings:` section mentioning `Apple platform binary`.
  - `.build/release/madctl plan /Applications/Claude.app --appearance light` expects argv lines `-NSRequiresAquaSystemAppearance` then `YES`; `--appearance dark` expects `--force-dark-mode`.
  - `.build/release/madctl plan /Applications/Claude.app --env BADFLAG; echo $?` expects `64`.

- [ ] **Step 6: Commit**

```bash
git add Tools/madctl/Sources/madctl
git commit -m "$(cat <<'EOF'
feat(madctl): inspect and plan commands

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: madctl `new`

**Files:**
- Create: `Tools/madctl/Sources/madctl/NewCommand.swift`
- Modify: `Tools/madctl/Sources/madctl/Madctl.swift` (add `NewCommand.self`)

**Interfaces:**
- Consumes: `ShortcutOptions`, `makeConfig`, `inspectApp(at:)` (Task 6); `BundleWriter.write(config:app:launcherBinary:to:)`; `Signer().sign(bundle:identity:)`.
- Produces: `madctl new <app-path> --name N [shared flags] [--out DIR] [--launcher PATH] [--identity NAME]`; stdout is exactly one line, the absolute bundle path.

- [ ] **Step 1: Specify `NewCommand`.** Flags: shared `@OptionGroup var options: ShortcutOptions`; `--name` is required for `new` (validate `options.name != nil`, else `ValidationError("new requires --name")`, exit 64); `--out DIR` default `~/Applications/App Duplicator` (created if missing); `--launcher PATH` default `Launcher` in the same directory as the running madctl (`Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "Launcher")`); `--identity NAME` optional (nil means ad-hoc signing). Steps: inspect target, `makeConfig`, check the launcher file exists and is executable (else print `launcher not found: <path>` to stderr and exit 1), `BundleWriter().write(...)`, `Signer().sign(bundle:identity:)`, then `print(bundle.path)`. Diagnostics (warnings from `InspectedApp.warnings` and the planner's `plan.warnings`, each as `warning: <text>`) go to stderr. Runtime errors (`LauncherError`, `SignerError`, file errors) print `error: <description>` to stderr and exit 1.

- [ ] **Step 2: Build and run.** `swift build -c release 2>&1 | tail -2` expects `Build complete!`. Then:
  ```bash
  OUT=$(mktemp -d)
  .build/release/madctl new /Applications/Claude.app --name "Claude Work" --out "$OUT"
  ```
  Expected stdout: `$OUT/Claude Work.app`. Verify:
  - `codesign --verify --strict "$OUT/Claude Work.app"; echo $?` prints `0`.
  - `plutil -extract MADConfig.dataPath raw "$OUT/Claude Work.app/Contents/Info.plist"` prints `<home>/Library/Application Support/App Duplicator/claude-work`.
  - `plutil -extract CFBundleIdentifier raw "$OUT/Claude Work.app/Contents/Info.plist"` prints `com.mikekuta.appduplicator.claude-work`.
  - `ls "$OUT/Claude Work.app/Contents/Resources"` shows `AppIcon.icns`; `ls -l` of it shows a regular file (first column starts with `-`).
  - `.build/release/madctl new /Applications/Claude.app --out "$OUT"; echo $?` prints `64`.
  Clean up with `rm -rf "$OUT"`.

- [ ] **Step 3: Commit**

```bash
git add Tools/madctl/Sources/madctl
git commit -m "$(cat <<'EOF'
feat(madctl): new command writes and signs shortcut bundles

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Fixture app and build script

**Files:**
- Create: `Tests/Fixtures/FixtureApp/main.swift`
- Create: `Tools/build-fixture.sh` (mode 0755)

**Interfaces:**
- Consumes: nothing from Core.
- Produces: `.build/fixtures/FixtureApp.app` (bundle id `com.mikekuta.appduplicator.fixture`, executable `Contents/MacOS/FixtureApp`) and the dump contract used by Tasks 9 and 10: JSON object `{"bundlePath": String, "homeDirectory": String, "arguments": [String], "environment": {String: String}}` written to the path in env `MAD_FIXTURE_DUMP`.

- [ ] **Step 1: Write `Tests/Fixtures/FixtureApp/main.swift`.** Behaviour: `import AppKit`; `NSApplication.shared`, `.setActivationPolicy(.regular)`; one `NSWindow` titled `MAD Fixture` (320x120, titled and closable) ordered front; if `MAD_FIXTURE_DUMP` is set, write the JSON above with `JSONSerialization` (`bundlePath = Bundle.main.bundlePath`, `homeDirectory = NSHomeDirectory()`, `arguments = CommandLine.arguments`, `environment = ProcessInfo.processInfo.environment`) using `.atomic` writes; a one-shot `Timer` terminates the app after `MAD_FIXTURE_LIFETIME` seconds (Double, default 3; extension to delta 8 so the Task 10 smoke can inspect the Dock before exit); then `app.run()`. The script compiles it with `-swift-version 5`, so top-level `NSApp.terminate(nil)` inside the timer closure needs no actor annotation.

- [ ] **Step 2: Write `Tools/build-fixture.sh`** (bash, `set -euo pipefail`). Behaviour: `ROOT` is the repo root derived from the script path; `OUT="$ROOT/.build/fixtures/FixtureApp.app"`; remove `OUT`, create `Contents/MacOS` and `Contents/Resources`; run `swiftc -target arm64-apple-macos26.0 -swift-version 5 -O -o "$OUT/Contents/MacOS/FixtureApp" "$ROOT/Tests/Fixtures/FixtureApp/main.swift"`; copy `/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns` to `Resources/AppIcon.icns`; write `Contents/Info.plist` with `CFBundleIdentifier` `com.mikekuta.appduplicator.fixture`, `CFBundleName` and `CFBundleDisplayName` `FixtureApp`, `CFBundleExecutable` `FixtureApp`, `CFBundleIconFile` `AppIcon`, `CFBundlePackageType` `APPL`, `CFBundleShortVersionString` `1.0`, `CFBundleVersion` `1`, `LSMinimumSystemVersion` `26.0`, `NSPrincipalClass` `NSApplication`, `NSHighResolutionCapable` true; run `codesign --force --sign - "$OUT"` and `codesign --verify --strict "$OUT"`; print `$OUT`. Run `chmod +x Tools/build-fixture.sh`.

- [ ] **Step 3: Run.** `Tools/build-fixture.sh; echo "exit=$?"` expects the last two lines `$REPO/.build/fixtures/FixtureApp.app` and `exit=0`. Then start the fixture directly (`open` drops the environment): `D=$(mktemp -d); MAD_FIXTURE_DUMP=$D/dump.json .build/fixtures/FixtureApp.app/Contents/MacOS/FixtureApp &`, wait 1.5 s, and run `plutil -p $D/dump.json | head -6`. Expected: `bundlePath` ending in `FixtureApp.app` and `homeDirectory` equal to the real home. The process exits by itself after about 3 s. Then `rm -rf $D`.

- [ ] **Step 4: Commit**

```bash
git add Tests/Fixtures/FixtureApp/main.swift Tools/build-fixture.sh
git commit -m "$(cat <<'EOF'
test: add FixtureApp and build script for integration tests

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Integration tests (gated)

**Files:**
- Delete: `Tests/Integration/PlaceholderTests.swift`
- Create: `Tests/Integration/LaunchIntegrationTests.swift`

**Interfaces:**
- Consumes: `.build/release/Launcher`, `.build/release/madctl`, `.build/fixtures/FixtureApp.app`, the dump contract from Task 8, `madctl new` stdout contract from Task 7.
- Produces: tests `testHomeModeLaunchDumpsExpectedIdentity` and `testLightAppearanceReachesTheTargetArguments`.

- [ ] **Step 1: Prerequisites to document in the file header comment and run:** `swift build -c release` and `Tools/build-fixture.sh`, then `MAD_INTEGRATION=1 swift test --filter IntegrationTests`. The test target has no dependencies. It locates the repo root from `#filePath` (three directories above `Tests/Integration/<file>`).

- [ ] **Step 2: Shared helpers in the test file.** `skipUnlessEnabled()`: `try XCTSkipUnless(ProcessInfo.processInfo.environment["MAD_INTEGRATION"] == "1", "Set MAD_INTEGRATION=1")`; then `XCTAssertTrue(FileManager.default.isExecutableFile(atPath: launcher))` for the three artifacts with the failure message `Run: swift build -c release && Tools/build-fixture.sh`. `makeShortcut(name:extraArgs:) throws -> URL`: runs `madctl new <fixture> --name <name> --launcher <launcher> --out <tmp>/out --env MAD_FIXTURE_DUMP=<tmp>/dump.json <extraArgs>` with `Process`, asserts exit 0, returns the trimmed stdout as the bundle URL. The dump path travels through `--env` (config environment), because the planner strips inherited `MAD_*` variables. `launchAndWaitForDump(bundle:) async throws -> (pid: pid_t, dump: Dump)`: `NSWorkspace.shared.openApplication(at:configuration:)` with a default `OpenConfiguration` (the async overload, `createsNewApplicationInstance = true`); keep the returned `NSRunningApplication`; poll every 50 ms for up to 10 s until `<tmp>/dump.json` decodes into `struct Dump: Decodable { bundlePath: String; homeDirectory: String; arguments: [String]; environment: [String: String] }`; capture `proc_pidpath` of the pid in the same iteration the file first decodes; terminate the app afterwards (`terminate()`, then `forceTerminate()` after 3 s) and assert `isTerminated` within 5 s. Pid path helper:

```swift
func processPath(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    return length > 0 ? String(cString: buffer) : ""
}
```

- [ ] **Step 3: `testHomeModeLaunchDumpsExpectedIdentity`.** Shortcut name `MAD Fixture Home`, extra args `--data-mode home --data-path <tmp>/home`. Assertions (all paths compared after `URL.resolvingSymlinksInPath().path`, because the temp dir is under `/var` which is a symlink to `/private/var`): the pid's `processPath` equals the fixture `Contents/MacOS/FixtureApp`; `dump.homeDirectory` equals `<tmp>/home`; `dump.environment["HOME"]` and `dump.environment["CFFIXED_USER_HOME"]` both equal `<tmp>/home`; `dump.environment["MAD_SHORTCUT_NAME"] == "MAD Fixture Home"`; `dump.bundlePath` ends with `FixtureApp.app`; the directory `<tmp>/home/Library/Application Support` exists.

- [ ] **Step 4: `testLightAppearanceReachesTheTargetArguments`.** Shortcut name `MAD Fixture Light`, extra args `--data-mode disabled --appearance light`. Assertions: `dump.arguments` contains `-NSRequiresAquaSystemAppearance` and the element after it is `YES`; no element equals `-AppleInterfaceStyle`.

- [ ] **Step 5: Run.** `swift build -c release && Tools/build-fixture.sh >/dev/null && MAD_INTEGRATION=1 swift test --filter IntegrationTests 2>&1 | tail -12`. Expected `Executed 2 tests, with 0 failures`. Without the variable, `swift test --filter IntegrationTests 2>&1 | tail -4` expects 2 tests skipped and 0 failures. The fixture opens a window for about 3 s per test; that is expected.

- [ ] **Step 6: Commit**

```bash
git add Tests/Integration
git commit -m "$(cat <<'EOF'
test: gated integration tests launch fixture through generated shortcuts

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Dock-identity smoke (manual check, scripted)

**Files:**
- Create: `Tools/smoke-dock-identity.sh` (mode 0755)

**Interfaces:**
- Consumes: Tasks 7 and 8 outputs. Produces: a script that prints pass or fail lines and leaves one Dock tile on screen for 30 s so a human can look at it.

- [ ] **Step 1: Write the script** (bash, `set -euo pipefail`; run from the repo root). Behaviour: build nothing, require `.build/release/madctl`, `.build/release/Launcher`, `.build/fixtures/FixtureApp.app` (print `missing: <path>` and exit 1 otherwise); `OUT=$(mktemp -d)`; run `.build/release/madctl new .build/fixtures/FixtureApp.app --name "Smoke Tile" --data-mode disabled --env MAD_FIXTURE_LIFETIME=30 --out "$OUT"`; `open "$OUT/Smoke Tile.app"`; sleep 2 s; `PID=$(pgrep -f 'FixtureApp.app/Contents/MacOS/FixtureApp' | head -1)`; `ASN=$(lsappinfo find pid=$PID)`; `lsappinfo info -only bundlepath "$ASN"` must contain `FixtureApp.app` (print `PASS: lsappinfo reports the target bundle`, else `FAIL` and exit 1); print `LOOK NOW: the Dock tile should read "Smoke Tile" and show the generic application icon, not "FixtureApp"`; sleep 30; `pkill -f 'FixtureApp.app/Contents/MacOS/FixtureApp' || true`; `rm -rf "$OUT"`.

- [ ] **Step 2: Run** (needs Mike, or the orchestrator with Mike's awareness, at the screen): `Tools/smoke-dock-identity.sh`. Expected output: one `PASS` line, then the `LOOK NOW` line. Visual expected result: the Dock tile is titled `Smoke Tile` while `lsappinfo` reports `FixtureApp.app`. If the tile reads `FixtureApp` instead, stop and report; spec §4.1 would be wrong on this OS build.

- [ ] **Step 3: System Launch proof for Task 5.** Run `OUT=$(mktemp -d); .build/release/madctl new .build/fixtures/FixtureApp.app --name "Smoke System" --mode system --data-mode disabled --env MAD_FIXTURE_DUMP=$OUT/d.json --env MAD_FIXTURE_LIFETIME=5 --out "$OUT"; open "$OUT/Smoke System.app"; sleep 3; cat $OUT/d.json | head -c 300; pkill -f FixtureApp.app/Contents/MacOS || true; rm -rf $OUT`. Expected: the JSON appears (the fixture started through `NSWorkspace`) and `tail -3 ~/Library/Logs/App\ Duplicator/Smoke\ System.log` contains `system launch ok`.

- [ ] **Step 4: Commit**

```bash
git add Tools/smoke-dock-identity.sh
git commit -m "$(cat <<'EOF'
test: scripted Dock identity smoke check

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Acceptance, Claude Desktop two-account test (manual gate)

**Do not run without Mike present; sign-ins are his.**

**Files:**
- Create: `docs/acceptance/phase1-claude-desktop.md`

**Interfaces:**
- Consumes: release builds of `madctl` and `Launcher`; `/Applications/Claude.app` (Electron, not sandboxed, bundle id `com.anthropic.claudefordesktop`, original data dir `~/Library/Application Support/Claude`).
- Produces: a checked-in checklist plus a results block filled after the run.

- [ ] **Step 1: Create the checklist file** containing the commands below verbatim, each followed by its expected result.

- [ ] **Step 2: Generate (no sign-in needed).**
  ```bash
  swift build -c release
  .build/release/madctl new /Applications/Claude.app --name "Claude Work"
  .build/release/madctl new /Applications/Claude.app --name "Claude Personal"
  ```
  Expected stdout: `~/Applications/App Duplicator/Claude Work.app` and `~/Applications/App Duplicator/Claude Personal.app` (expanded paths).

- [ ] **Step 3: Launch (Mike).** `open ~/Applications/App\ Duplicator/Claude\ Work.app ~/Applications/App\ Duplicator/Claude\ Personal.app`. Mike signs in to a different account in each window.

- [ ] **Step 4: Verify.**
  - Distinct data dirs: `ps -axo pid=,args= | grep -F 'Claude.app/Contents/MacOS/Claude --user-data-dir=' | grep -v grep`. Expected: exactly two lines, one ending `.../App Duplicator/claude-work`, one ending `.../App Duplicator/claude-personal`.
  - Two Dock tiles named `Claude Work` and `Claude Personal`, both with the Claude icon (visual).
  - Own config files: in each window open Settings, Developer, Edit Config (creates the file), then `ls -l ~/Library/Application\ Support/App\ Duplicator/claude-work/claude_desktop_config.json ~/Library/Application\ Support/App\ Duplicator/claude-personal/claude_desktop_config.json`. Expected: two distinct files; the original `~/Library/Application Support/Claude` is untouched.
  - `lsappinfo` and Activity Monitor show `com.anthropic.claudefordesktop` for both processes. This is expected (spec §4.1): LaunchServices re-registers the target at check-in while the Dock tile keeps the shortcut's name and icon.
  - Logs: `tail -5 ~/Library/Logs/App\ Duplicator/Claude\ Work.log` shows the `exec` line and no secret values.

- [ ] **Step 5: Teardown.** Quit both instances; delete only the two shortcut bundles with `rm -rf ~/Applications/App\ Duplicator/Claude\ Work.app ~/Applications/App\ Duplicator/Claude\ Personal.app`. The data folders stay until Mike removes them (shortcut and data are separate, spec §2).

- [ ] **Step 6: Record results** in the checklist file under a heading `Results (date, macOS build)`, one pass or fail line per bullet in Step 4, then commit:

```bash
git add docs/acceptance/phase1-claude-desktop.md
git commit -m "$(cat <<'EOF'
docs: Phase 1 Claude Desktop acceptance checklist and results

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: README, Phase 1 engine section

**Files:**
- Create: `README.md` (repository root)

**Interfaces:**
- Consumes: Tasks 6 and 7 command contracts. Produces: the documented usage.

- [ ] **Step 1: Write `README.md`** with a title and one-sentence description, then the section `## Phase 1 engine` containing: build commands (`swift build -c release`, `swift test --filter DuplicatorCoreTests`, `Tools/build-fixture.sh`, `MAD_INTEGRATION=1 swift test --filter IntegrationTests`); a `madctl` usage block listing exactly `madctl inspect <app-path>`, `madctl plan <app-path> [--data-mode auto|home|disabled] [--data-path P] [--mode dock|system] [--env K=V ...] [--arg A ...] [--appearance system|light|dark] [--language CODE] [--name N]`, `madctl new <app-path> --name N [same flags] [--out DIR] [--launcher PATH] [--identity NAME]`, with the defaults from Task 7; the sentence "Launcher events are logged to `~/Library/Logs/App Duplicator/<Name>.log` (rotated at 1 MB, secrets masked)"; and a `### Known limitations` list that copies every bullet of spec §11 verbatim.

- [ ] **Step 2: Check.** `grep -c '^- ' README.md` is at least 11 (the §11 bullets), and `grep -n 'Phase 1 engine' README.md` finds the heading.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: README Phase 1 engine usage and known limitations

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: Final verification, Phase 2 hand-off and tag

**Files:**
- Modify: `README.md` (append `## Phase 2 consumes`)

**Interfaces:**
- Consumes: everything above. Produces: tag `phase1-engine`.

- [ ] **Step 1: Full verification.** `swift build -c release 2>&1 | tail -2` expects `Build complete!`. `Tools/build-fixture.sh >/dev/null`. `MAD_INTEGRATION=1 swift test 2>&1 | tail -6` expects `with 0 failures` across `DuplicatorCoreTests` and `IntegrationTests`. `git status --short` expects empty output. Do not tag if Task 11's recorded results contain a failure.

- [ ] **Step 2: Append to `README.md`** the section `## Phase 2 consumes` listing, as bullets: `BundleWriter.write(config:app:launcherBinary:to:)` (creates `<Name>.app`), `Signer.sign(bundle:identity:)` and `Signer.arguments(bundle:identity:)`, `ShortcutConfig` (init, `plistDictionary()`, `init(plistDictionary:)`, `slug(for:)`, `bundleIdentifier(forSlug:)`, `defaultDataPath(forSlug:home:)`, `fileSystemName(for:)`), `AppInspector.inspect(appAt:)` and `InspectedApp` (family, sandbox, platform-binary, launch-constraint flags, icon URL, `warnings`), `DataSeparationPlanner.plan(app:config:baseEnvironment:shortcutBundleURL:)` for previews, `HomeTreeBuilder`, `SecretMasking.mask`, and the `Launcher` release binary at `.build/release/Launcher` to embed as a resource. Add one line that the Phase 3 insertion point for profiles is the doc comment on `DataSeparationPlanner.plan`.

- [ ] **Step 3: Commit, then tag**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: list Phase 1 API consumed by Phase 2

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
git tag phase1-engine
git tag --list phase1-engine
```
Expected: the last command prints `phase1-engine`.

---

## Self-review

**Spec coverage.** §2: Global Constraints, Task 2 reviewer checklist, Task 7 (no target mutation), Task 4 (masked env logging). §3.1 and §3.2: Tasks 2 (BundleWriter tests 1 to 7) and 7. §3.3: Task 7. §3.4 steps 2 to 4: `LaunchPreparer` (Task 2 test c to f, Task 4); step 5 as the no-op `spawnHelperIfNeeded`; step 6 and System Launch: Tasks 4 and 5. §4.1: Task 4 doc comment, Task 5, planner forcing in Task 2 and Task 6 TextEdit check. §4.2: Tasks 2 and 3. §4.3 to §4.5: Task 2 planner and HomeTreeBuilder tests, Task 6 plan output, Task 9 asserts. §4.6: deferred hook only. §4.7: exit codes in Tasks 2 and 4; the "Locate..." button is deferred to Phase 2. §9: `AppInspector.inspect` validation inside `prepare`, Signer without `--deep`, no shell interpolation (argv arrays). §10: unit (Task 2), integration (Task 9), acceptance (Task 11). Web shell, profiles and library app are other phases.

**Type consistency.** Signatures in Task 2 Interfaces were checked against the draft sources (`grep "public "`): the extras (`InspectedApp.warnings`, `LaunchPlan.applyingEffectiveHome`, `LaunchPlan.environmentAdditions`, planner `shortcutBundleURL:`, `LaunchPreparer`, `PreparedLaunch`, `SignerError`, `Signer.arguments`, `BundleWriter.forbiddenInfoPlistKeys`, `LauncherError.exitCode`) are the only deviations from the brief and all are additive.
