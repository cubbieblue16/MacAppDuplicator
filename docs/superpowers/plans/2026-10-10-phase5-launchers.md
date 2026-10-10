# macOS App Duplicator Phase 5 (Launchers) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a shortcut bundle open a file or folder, or run a command (optionally in a terminal, optionally with its own HOME), with the same Dock identity, icon and library management that app and web-app shortcuts already have (spec §6).

**Architecture:** The `ShortcutKind` cases `.file`, `.folder` and `.cli` reuse the existing Launcher binary. `ShortcutConfig` gains two optional sub-configs, `FileConfig` and `CLIConfig`, stored in `MADConfig` exactly like `webApp`. Core gets a kind dispatch in `LaunchPreparer` that runs before `TargetResolver`/`AppInspector` and produces a `LauncherAction` (open URLs, or spawn an argv with an environment). A pure `TerminalCommandBuilder` turns a `CLIConfig` into the argv the Launcher spawns: `osascript` with a generated AppleScript for Terminal.app and iTerm2, `ghostty -e` for Ghostty, or the executable itself for "no terminal". The Launcher executes the action and exits; it never stays resident. The app gains wizard steps, editor sections, Diagnostics rows and library handling for the three kinds, with `ShortcutBuilder.writeLauncherKind` writing bundles through `BundleWriter.write(config:executable:iconFile:to:)` and a default icon rendered from `NSWorkspace.shared.icon(forFile:)`.

**Tech Stack:** Swift 6 language mode (Xcode 27.0, Swift 6.4), macOS 26+ arm64, SwiftUI + AppKit (app), Foundation + Darwin (Core), AppKit (Launcher: `NSWorkspace`, `posix_spawn`), xcodegen 2.45.3 (/usr/local/bin/xcodegen), XCTest.

## Global Constraints

Phase 4 constraints carry over verbatim unless a Phase 5 line below overrides them. In particular: macOS 26+ / arm64 only (`ARCHS = arm64`, `MACOSX_DEPLOYMENT_TARGET = 26.0`, `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`); Core imports Foundation, Security and Darwin only; XCTest only; no new `try?` except where this plan shows one, no empty `catch`, no `@unchecked Sendable`, no `swiftlint:disable`; never copy, repackage, patch or re-sign a target app; `SecretMasking` pattern `(?i)secret|token|key|password|passwd|credential` masks values as `••••••`; the Info.plist key set and `BundleWriter.forbiddenInfoPlistKeys` are unchanged; bundle ids are `com.mikekuta.appduplicator.<slug>`; shortcuts are written only to the chosen output directory; logs go to `~/Library/Logs/App Duplicator/<name>.log`.

Phase 5 additions:

- **Commands are argv arrays, never shell strings.** `CLIConfig.executablePath` plus `CLIConfig.arguments` is the argv. The only place a shell-quoted string is built is `TerminalCommandBuilder.shellQuoted(_:)` for the Terminal.app and iTerm2 AppleScript bodies, and every element is single-quoted with `'` → `'\''`. The AppleScript string literal itself escapes `\` and `"`.
- **No `osascript` in tests.** Unit tests assert the generated AppleScript and argv strings only. No test runs `osascript` against Terminal.app or iTerm2, and no test launches Terminal.app, iTerm2 or Ghostty. The gated integration test uses `TerminalChoice.none` with `/usr/bin/true` (or `/bin/sh -c` writing a dump file) only.
- **Tests stay in their sandbox.** No test touches the real `~/Library`, `~/Applications`, `UserDefaults.standard` or the network: every test works in a per-test temp folder (injected `home`/`fileManager`/`terminalLocator`), and the only process a test starts is the gated integration test's Launcher with `TerminalChoice.none`.
- **`dataMode` is `.disabled` for all three launcher kinds.** A command's own HOME is expressed only by `CLIConfig.homeOverride` (the planner derives the folder from the slug); `dataMode` and `dataPath` never carry it, so the data-mode machinery for apps is never reached for launcher kinds.
- **Target apps are never touched.** A launcher shortcut opens or runs something; it never modifies, copies, repackages or re-signs a target app, the opener app, the terminal app or the command's executable. Only the shortcut bundle itself is signed (ad hoc or with the chosen identity, as today).
- **The shortcut environment reaches Terminal.app and iTerm2 inline.** Those apps start a fresh login shell that does not inherit the Launcher's or `osascript`'s environment, so `LauncherActionPlanner` passes its `additions` (`MAD_SHORTCUT_NAME`, `MAD_SHORTCUT_BUNDLE` when known, `HOME`/`CFFIXED_USER_HOME` for `homeOverride`, then `config.environment`) to `TerminalCommandBuilder.argv(for:terminalApp:inlineEnvironment:)`, which writes `/usr/bin/env 'K=V'… '<exe>' '<args>'…` (sorted keys, every token shell-quoted). `.none` and Ghostty receive the environment through `posix_spawn` (Ghostty's `-e` runs the command with Ghostty's own PATH, known limitation `cli-ghostty-path`). The inlined values are part of the `osascript` argv, so they are visible in `ps` for the fraction of a second `osascript` runs; the shell command is never written to disk. Previews mask secret values before planning, so no secret reaches a displayed script.
- **Launcher-kind bundles use the Launcher binary** via `BundleWriter.write(config:executable:iconFile:to:)`. Invariants enforced by `ShortcutBuilder` for `.file`, `.folder` and `.cli`: `targetPath == ""`, `targetBundleIdentifier == ""`, `launchMode == .dockShortcut`, `dataMode == .disabled`, `dataPath == nil`, `engineVersion == ShortcutConfig.currentEngineVersion` (still 1). `.file`/`.folder` require `file != nil`; `.cli` requires `cli != nil`.
- **File/folder launches exit immediately.** The Launcher opens the URL(s) with `NSWorkspace`, waits for the open to complete (callback or 10 s cap), logs, and calls `exit(0)`. There is no resident process, so a file/folder tile shows no running indicator; `RunningShortcutMonitor` is pid/path based and needs no change.
- **CLI HOME override** reuses `HomeTreeBuilder` and the spec §4.3 rules: `HOME` and `CFFIXED_USER_HOME` point at `ShortcutConfig.defaultDataPath(forSlug:home:)` (the same directory an app shortcut would use), materialised with `HomeTreeBuilder.defaultSymlinkEntries`; nothing is created in the real HOME.
- **Terminal detection** uses `LSCopyApplicationURLsForBundleIdentifier` with `com.apple.Terminal`, `com.googlecode.iterm2` and `com.mitchellh.ghostty` (the ids already in `profiles.json`). A missing terminal is `LauncherError.terminalNotFound(TerminalChoice)` (exit code 5); a failed `posix_spawn` is `LauncherError.spawnFailed(errno:path:)` (exit code 3, same family as `execFailed`); a missing file/folder is `LauncherError.fileNotFound(path:)` (exit code 2).
- **Launcher log lines** for the new kinds: `kind file|folder|cli`, `open <path>` or `spawn <argv0> argc=<n> terminal=<choice>`, `exit <code>`. Argument values pass through `SecretMasking.maskArguments` before logging.
- Version bump at the end of the phase (`App/project.yml`): `MARKETING_VERSION 0.5.0`, `CURRENT_PROJECT_VERSION 4`.

## Inputs and conventions

- Spec: `docs/superpowers/specs/2026-10-09-macos-app-duplicator-design.md` §4.3 (HOME override) and §6 (files, folders, commands).
- Build and test commands (always `cd ~/Developer/MacAppDuplicator &&` first; the shell cwd resets per call):
  - Core: `swift test --filter DuplicatorCoreTests` (172 tests before this phase; 185 after Task 1, 222 after Task 2)
  - Launcher has no unit tests of its own; its logic lives in Core.
  - App: `Tools/test-app.sh` (prints `** TEST SUCCEEDED **`, ~1 min)
  - Gated: `MAD_INTEGRATION=1 swift test --filter IntegrationTests.<Class>` (dot form only; slash form runs 0 tests)
- Commit identity: `git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit`, every message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Existing patterns to mirror: `WebAppConfig` (sub-config with custom `init(from:)` and `decodeIfPresent` defaults), `WebEditorPolicy` (pure editor decisions), `WebShellLaunchTests` (gated launch test with redirected HOME and process reaping), `KindStep` options in `WizardSteps.swift`, `ReviewRow` in `WizardModel.swift`, `DiagnosticsModel.makeWeb` in `DiagnosticsView.swift`.

## File structure

Create:
- `Packages/DuplicatorCore/Sources/DuplicatorCore/FileConfig.swift` — `FileConfig` (path, optional opener app path) + validation.
- `Packages/DuplicatorCore/Sources/DuplicatorCore/CLIConfig.swift` — `CLIConfig`, `TerminalChoice`.
- `Packages/DuplicatorCore/Sources/DuplicatorCore/TerminalCommandBuilder.swift` — pure argv/AppleScript generation.
- `Packages/DuplicatorCore/Sources/DuplicatorCore/LauncherAction.swift` — `LauncherAction` enum + `LauncherActionPlanner`.
- `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/{FileConfigTests,CLIConfigTests,TerminalCommandBuilderTests,LauncherActionPlannerTests}.swift`
- `Launcher/Sources/Launcher/OpenItems.swift` — file/folder open + exit.
- `Launcher/Sources/Launcher/Spawn.swift` — `posix_spawn` wrapper.
- `App/Sources/Services/LauncherEditorPolicy.swift` — pure editor decisions for the three kinds.
- `App/Sources/Views/Wizard/FileTargetStep.swift`, `App/Sources/Views/Wizard/CommandTargetStep.swift`
- `App/Sources/Views/FileSection.swift`, `App/Sources/Views/CommandSection.swift`
- `App/Tests/Services/LauncherEditorPolicyTests.swift`, `App/Tests/Wizard/WizardModelLauncherTests.swift`, `App/Tests/Services/ShortcutBuilderLauncherTests.swift` (also holds `LaunchPlanPreviewLauncherTests`), `App/Tests/Model/LibraryScannerLauncherTests.swift`, `App/Tests/Model/LibraryScannerLauncherTests.swift`
- `Tests/Integration/CLILaunchTests.swift` (gated)
- `docs/acceptance/phase5-launchers.md`

Modify:
- `Packages/DuplicatorCore/Sources/DuplicatorCore/{Enums,ShortcutConfig,LaunchPreparer,LauncherError,LauncherError+ExitCode}.swift`
- `Launcher/Sources/Launcher/main.swift`
- `App/Sources/Services/{ShortcutBuilder,IconResolver,TargetResolver+ResolvedPath,CompatBadge,LaunchPlanPreview}.swift`
- `App/Sources/Views/Wizard/{WizardModel,WizardSteps,NewShortcutWizard}.swift`
- `App/Sources/Views/{EditorSections,ShortcutEditorView,DiagnosticsView,ShortcutRowView,DeleteShortcutSheet}.swift`
- `App/Sources/Model/{LibraryScanner,ShortcutLibrary,ShortcutRecord}.swift`
- `App/Sources/App/{AppState,KnownLimitations}.swift`
- `App/Tests/Services/IconResolverTests.swift` (appends `IconResolverLauncherTests`), `App/Tests/App/KnownLimitationsTests.swift` (count 24 -> 28)
- `App/project.yml`, `README.md`

---

### Task 1: Core config — `FileConfig`, `CLIConfig`, `TerminalChoice` on `ShortcutConfig`

**Files:**
- Create: `Packages/DuplicatorCore/Sources/DuplicatorCore/FileConfig.swift`, `Packages/DuplicatorCore/Sources/DuplicatorCore/CLIConfig.swift`
- Modify: `Packages/DuplicatorCore/Sources/DuplicatorCore/Enums.swift` (`ShortcutKind` doc comment), `Packages/DuplicatorCore/Sources/DuplicatorCore/ShortcutConfig.swift` (two new optional stored properties, memberwise init defaults, `init(from:)` decodeIfPresent)
- Test: `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/FileConfigTests.swift`, `.../CLIConfigTests.swift`, extend `.../ShortcutConfigTests.swift` (MADConfig round-trip for each kind)

**Interfaces:**
- Consumes: `ShortcutConfig`, `WebAppConfig` pattern.
- Produces:
  ```swift
  public struct FileConfig: Codable, Hashable, Sendable {
      public var path: String                 // absolute path of the file or folder
      public var openerAppPath: String?       // nil = default handler (`NSWorkspace.open`)
      public init(path: String, openerAppPath: String? = nil)
      public static func normalizedPath(_ raw: String) -> String   // expands ~, standardizes, strips trailing "/"
  }
  public enum TerminalChoice: String, Codable, CaseIterable, Sendable { case none, terminal, iterm2, ghostty
      public var bundleIdentifier: String? }   // nil for .none; com.apple.Terminal / com.googlecode.iterm2 / com.mitchellh.ghostty
  public struct CLIConfig: Codable, Hashable, Sendable {
      public var executablePath: String
      public var arguments: [String]
      public var workingDirectory: String?
      public var terminal: TerminalChoice      // default .terminal
      public var homeOverride: Bool            // default false
      public init(executablePath: String, arguments: [String] = [], workingDirectory: String? = nil, terminal: TerminalChoice = .terminal, homeOverride: Bool = false)
  }
  // ShortcutConfig additions
  public var file: FileConfig?
  public var cli: CLIConfig?
  ```
  Memberwise init gains `file: FileConfig? = nil, cli: CLIConfig? = nil` after `webApp`. `init(from:)` decodes both with `decodeIfPresent`. `engineVersion` stays 1.

#### Group A: `FileConfig`

- [ ] **Step 1: Write the failing `FileConfig` tests**

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/FileConfigTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore

final class FileConfigTests: XCTestCase {
    func testInitializerDefaults() {
        let config = FileConfig(path: "/Users/test/Documents/Report.pdf")
        XCTAssertEqual(config.path, "/Users/test/Documents/Report.pdf")
        XCTAssertNil(config.openerAppPath)
    }

    func testNormalizedPathExpandsTildeAndStripsTrailingSlashes() {
        XCTAssertEqual(FileConfig.normalizedPath("~/Documents/Report.pdf"), NSHomeDirectory() + "/Documents/Report.pdf")
        XCTAssertEqual(FileConfig.normalizedPath("~"), NSHomeDirectory())
        XCTAssertEqual(FileConfig.normalizedPath("/Users/test/Projects/"), "/Users/test/Projects")
        XCTAssertEqual(FileConfig.normalizedPath("/Users/test/Projects///"), "/Users/test/Projects")
        XCTAssertEqual(FileConfig.normalizedPath("/"), "/")
        XCTAssertEqual(FileConfig.normalizedPath(""), "")
    }

    func testNormalizedPathRemovesDotComponentsWithoutTouchingTheFileSystem() {
        XCTAssertEqual(FileConfig.normalizedPath("/Users/test/./Projects/../Notes"), "/Users/test/Notes")
        // A path that does not exist is standardized too, and symlinks such as /tmp are not resolved.
        XCTAssertEqual(FileConfig.normalizedPath("/tmp/mad-does-not-exist/../x"), "/tmp/x")
        XCTAssertEqual(FileConfig.normalizedPath("relative/folder/"), "relative/folder")
    }

    func testCodableRoundTripOmitsANilOpener() throws {
        let plain = FileConfig(path: "/Users/test/Projects")
        let withOpener = FileConfig(path: "/Users/test/Notes.md", openerAppPath: "/Applications/TextEdit.app")
        for config in [plain, withOpener] {
            let data = try PropertyListEncoder().encode(config)
            XCTAssertEqual(try PropertyListDecoder().decode(FileConfig.self, from: data), config)
        }
        let encoded = try PropertyListEncoder().encode(plain)
        let dictionary = try XCTUnwrap(PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
        XCTAssertEqual(Set(dictionary.keys), ["path"])
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.FileConfigTests 2>&1 | grep -E "error:" | head -5`
Expected: build errors such as `cannot find 'FileConfig' in scope`; no tests run.

- [ ] **Step 3: Implement `FileConfig`**

Create `Packages/DuplicatorCore/Sources/DuplicatorCore/FileConfig.swift`:

```swift
import Foundation

/// File and folder shortcut settings (spec §6). Set exactly when `ShortcutConfig.kind` is `.file` or `.folder`.
public struct FileConfig: Codable, Hashable, Sendable {
    /// Absolute path of the file or folder the shortcut opens.
    public var path: String
    /// Absolute path of the app that opens `path`; nil opens it with its default handler (`NSWorkspace.open`).
    public var openerAppPath: String?

    public init(path: String, openerAppPath: String? = nil) {
        self.path = path
        self.openerAppPath = openerAppPath
    }

    /// `raw` with a leading `~` expanded, `.` and `..` components removed (lexically, the file system is not
    /// consulted) and trailing `/` stripped. `"/"` stays `"/"`; a relative path only loses its trailing `/`.
    public static func normalizedPath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let standardized = expanded.hasPrefix("/") ? URL(filePath: expanded).standardized.path : expanded
        var path = standardized
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
```

`normalizedPath` is lexical on purpose: it runs in the app's wizard and in the Launcher, and must not resolve symlinks (a `/tmp/...` path stays `/tmp/...`, not `/private/tmp/...`).

- [ ] **Step 4: Run the tests and watch them pass**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.FileConfigTests 2>&1 | grep -E "Executed|error:" | tail -2`
Expected: `Executed 4 tests, with 0 failures`.

#### Group B: `TerminalChoice` and `CLIConfig`

- [ ] **Step 5: Write the failing `CLIConfig` tests**

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/CLIConfigTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore

final class CLIConfigTests: XCTestCase {
    func testInitializerDefaults() {
        let config = CLIConfig(executablePath: "/opt/homebrew/bin/htop")
        XCTAssertEqual(config.executablePath, "/opt/homebrew/bin/htop")
        XCTAssertEqual(config.arguments, [])
        XCTAssertNil(config.workingDirectory)
        XCTAssertEqual(config.terminal, TerminalChoice.terminal)
        XCTAssertFalse(config.homeOverride)
    }

    func testTerminalChoiceRawValuesAndBundleIdentifiers() {
        XCTAssertEqual(TerminalChoice.allCases, [TerminalChoice.none, TerminalChoice.terminal, TerminalChoice.iterm2, TerminalChoice.ghostty])
        XCTAssertEqual(TerminalChoice.allCases.map(\.rawValue), ["none", "terminal", "iterm2", "ghostty"])
        XCTAssertNil(TerminalChoice.none.bundleIdentifier)
        XCTAssertEqual(TerminalChoice.terminal.bundleIdentifier, "com.apple.Terminal")
        XCTAssertEqual(TerminalChoice.iterm2.bundleIdentifier, "com.googlecode.iterm2")
        XCTAssertEqual(TerminalChoice.ghostty.bundleIdentifier, "com.mitchellh.ghostty")
    }

    func testCodableRoundTripKeepsEveryField() throws {
        let config = CLIConfig(
            executablePath: "/usr/bin/ssh",
            arguments: ["-p", "2222", "user@host name"],
            workingDirectory: "~/Projects",
            terminal: TerminalChoice.ghostty,
            homeOverride: true
        )
        let data = try PropertyListEncoder().encode(config)
        XCTAssertEqual(try PropertyListDecoder().decode(CLIConfig.self, from: data), config)
    }

    func testDecodingFillsMissingKeysWithTheInitializerDefaults() throws {
        let minimal: [String: Any] = ["executablePath": "/bin/ls"]
        let data = try PropertyListSerialization.data(fromPropertyList: minimal, format: .xml, options: 0)
        XCTAssertEqual(try PropertyListDecoder().decode(CLIConfig.self, from: data), CLIConfig(executablePath: "/bin/ls"))
    }

    func testDecodingRejectsAMissingExecutableAndAnUnknownTerminal() throws {
        let noExecutable: [String: Any] = ["arguments": ["-l"]]
        let unknownTerminal: [String: Any] = ["executablePath": "/bin/ls", "terminal": "kitty"]
        for dictionary in [noExecutable, unknownTerminal] {
            let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
            XCTAssertThrowsError(try PropertyListDecoder().decode(CLIConfig.self, from: data))
        }
    }
}
```

- [ ] **Step 6: Run them and watch them fail**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.CLIConfigTests 2>&1 | grep -E "error:" | head -5`
Expected: build errors such as `cannot find 'CLIConfig' in scope` and `cannot find 'TerminalChoice' in scope`; no tests run.

- [ ] **Step 7: Implement `TerminalChoice` and `CLIConfig`**

Create `Packages/DuplicatorCore/Sources/DuplicatorCore/CLIConfig.swift`:

```swift
import Foundation

/// The terminal a command shortcut runs in (spec §6). `.none` starts the command detached, with no window.
public enum TerminalChoice: String, Codable, CaseIterable, Sendable {
    case none, terminal, iterm2, ghostty

    /// The terminal app's bundle identifier, used to locate it; nil for `.none`.
    public var bundleIdentifier: String? {
        switch self {
        case .none:
            return nil
        case .terminal:
            return "com.apple.Terminal"
        case .iterm2:
            return "com.googlecode.iterm2"
        case .ghostty:
            return "com.mitchellh.ghostty"
        }
    }
}

/// Command shortcut settings (spec §6). Set exactly when `ShortcutConfig.kind == .cli`. The command is an argv
/// array, never a shell string: `executablePath` is argv[0] and `arguments` follow it unchanged.
public struct CLIConfig: Codable, Hashable, Sendable {
    /// Absolute path of the executable (a leading `~` is expanded at launch).
    public var executablePath: String
    public var arguments: [String]
    /// Directory the command starts in (a leading `~` is expanded at launch); nil keeps the launcher's directory.
    public var workingDirectory: String?
    public var terminal: TerminalChoice
    /// Runs the command with `HOME` and `CFFIXED_USER_HOME` pointing at the shortcut's own HOME tree (spec §4.3).
    public var homeOverride: Bool

    public init(
        executablePath: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        terminal: TerminalChoice = .terminal,
        homeOverride: Bool = false
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.terminal = terminal
        self.homeOverride = homeOverride
    }

    private enum CodingKeys: String, CodingKey {
        case executablePath, arguments, workingDirectory, terminal, homeOverride
    }

    /// Only `executablePath` is required on input; every other key falls back to the initializer default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            executablePath: try container.decode(String.self, forKey: .executablePath),
            arguments: try container.decodeIfPresent([String].self, forKey: .arguments) ?? [],
            workingDirectory: try container.decodeIfPresent(String.self, forKey: .workingDirectory),
            terminal: try container.decodeIfPresent(TerminalChoice.self, forKey: .terminal) ?? .terminal,
            homeOverride: try container.decodeIfPresent(Bool.self, forKey: .homeOverride) ?? false
        )
    }
}
```

Always write `TerminalChoice.none` in full where the type is not obvious (`terminal: TerminalChoice.none`), so it cannot be read as `Optional.none`.

- [ ] **Step 8: Run the tests and watch them pass**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.CLIConfigTests 2>&1 | grep -E "Executed|error:" | tail -2`
Expected: `Executed 5 tests, with 0 failures`.

#### Group C: `ShortcutConfig.file` / `ShortcutConfig.cli`

- [ ] **Step 9: Extend `ShortcutConfigTests`**

In `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/ShortcutConfigTests.swift`, replace the final test and the class's closing brace (lines 151–155).

Old:

```swift
    func testConfigIsHashable() {
        let set: Set<ShortcutConfig> = [makeConfig(), makeConfig()]
        XCTAssertEqual(set.count, 1)
    }
}
```

New:

```swift
    func testConfigIsHashable() {
        let set: Set<ShortcutConfig> = [makeConfig(), makeConfig()]
        XCTAssertEqual(set.count, 1)
    }

    // MARK: Launcher kinds (Phase 5)

    private func makeLauncherConfig(kind: ShortcutKind, file: FileConfig? = nil, cli: CLIConfig? = nil) -> ShortcutConfig {
        ShortcutConfig(
            kind: kind,
            name: "Projects",
            slug: "projects",
            bundleIdentifier: "com.mikekuta.appduplicator.projects",
            targetPath: "",
            targetBundleIdentifier: "",
            launchMode: .dockShortcut,
            dataMode: .disabled,
            file: file,
            cli: cli
        )
    }

    func testLauncherSubConfigsDefaultToNil() {
        let config = ShortcutConfig(name: "N", slug: "n", bundleIdentifier: "b", targetPath: "/A.app", targetBundleIdentifier: "a")
        XCTAssertNil(config.file)
        XCTAssertNil(config.cli)
        XCTAssertEqual(config.engineVersion, 1)
    }

    func testEveryKindRoundTripsThroughMADConfig() throws {
        let webApp = ShortcutConfig(
            kind: .webApp, name: "Mail", slug: "mail", bundleIdentifier: "com.mikekuta.appduplicator.mail",
            targetPath: "", targetBundleIdentifier: "", dataMode: .disabled, webApp: WebAppConfig(url: "https://mail.example.com")
        )
        let configs = [
            makeConfig(),
            webApp,
            makeLauncherConfig(kind: .file, file: FileConfig(path: "/Users/test/Notes.md", openerAppPath: "/Applications/TextEdit.app")),
            makeLauncherConfig(kind: .folder, file: FileConfig(path: "/Users/test/Projects")),
            makeLauncherConfig(
                kind: .cli,
                cli: CLIConfig(
                    executablePath: "/usr/bin/top",
                    arguments: ["-o", "cpu"],
                    workingDirectory: "~",
                    terminal: .iterm2,
                    homeOverride: true
                )
            ),
        ]
        for config in configs {
            XCTAssertEqual(try ShortcutConfig(plistDictionary: config.plistDictionary()), config, "kind \(config.kind)")
        }
    }

    func testLauncherSubConfigsAreWrittenOnlyWhenSet() throws {
        let folder = makeLauncherConfig(kind: .folder, file: FileConfig(path: "/Users/test/Projects")).plistDictionary()
        XCTAssertEqual(folder["kind"] as? String, "folder")
        XCTAssertEqual((folder["file"] as? [String: Any])?["path"] as? String, "/Users/test/Projects")
        XCTAssertNil(folder["cli"])
        XCTAssertNil(folder["webApp"])
        XCTAssertNil(folder["dataPath"])
        XCTAssertEqual(folder["targetPath"] as? String, "")
        XCTAssertEqual(folder["engineVersion"] as? Int, 1)

        let command = makeLauncherConfig(kind: .cli, cli: CLIConfig(executablePath: "/bin/ls", terminal: TerminalChoice.none))
        let dictionary = command.plistDictionary()
        let cli = try XCTUnwrap(dictionary["cli"] as? [String: Any])
        XCTAssertEqual(cli["executablePath"] as? String, "/bin/ls")
        XCTAssertEqual(cli["arguments"] as? [String], [])
        XCTAssertEqual(cli["terminal"] as? String, "none")
        XCTAssertEqual(cli["homeOverride"] as? Bool, false)
        XCTAssertNil(cli["workingDirectory"])
        XCTAssertNil(dictionary["file"])

        XCTAssertNil(makeConfig().plistDictionary()["file"])
        XCTAssertNil(makeConfig().plistDictionary()["cli"])
    }

    func testCorruptLauncherSubConfigThrowsConfigCorrupt() {
        var dictionary = makeLauncherConfig(kind: .cli, cli: CLIConfig(executablePath: "/bin/ls")).plistDictionary()
        dictionary["cli"] = ["arguments": ["-l"]]
        XCTAssertThrowsError(try ShortcutConfig(plistDictionary: dictionary)) { error in
            guard case LauncherError.configCorrupt = error else {
                return XCTFail("expected configCorrupt, got \(error)")
            }
        }
    }
}
```

- [ ] **Step 10: Run them and watch them fail**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.ShortcutConfigTests 2>&1 | grep -E "error:" | head -5`
Expected: build errors such as `extra arguments at positions` / `extra argument 'file' in call` and `value of type 'ShortcutConfig' has no member 'cli'`; no tests run.

- [ ] **Step 11: Add the two optional fields to `ShortcutConfig` and update the `ShortcutKind` doc comment**

Edit 1, `Enums.swift` line 3.

Old:

```swift
/// What a shortcut launches (spec §3.1). Phase 1 implements `.app` only.
```

New:

```swift
/// What a shortcut launches (spec §3.1): `.app` runs the Launcher and execs a target app, `.webApp` runs WebShell
/// (spec §5), and `.file`, `.folder` and `.cli` run the Launcher, which opens or spawns and exits (spec §6).
```

Edit 2, `ShortcutConfig.swift` lines 35–37 (stored properties).

Old:

```swift
    /// Web app settings; set exactly when `kind == .webApp`, nil otherwise (spec §5).
    public var webApp: WebAppConfig?
    public var engineVersion: Int
```

New:

```swift
    /// Web app settings; set exactly when `kind == .webApp`, nil otherwise (spec §5).
    public var webApp: WebAppConfig?
    /// File or folder settings; set exactly when `kind` is `.file` or `.folder`, nil otherwise (spec §6).
    public var file: FileConfig?
    /// Command settings; set exactly when `kind == .cli`, nil otherwise (spec §6).
    public var cli: CLIConfig?
    public var engineVersion: Int
```

Edit 3, `ShortcutConfig.swift` lines 57–59 (memberwise init parameters).

Old:

```swift
        homeSymlinkEntries: [String]? = nil,
        webApp: WebAppConfig? = nil,
        engineVersion: Int = ShortcutConfig.currentEngineVersion
```

New:

```swift
        homeSymlinkEntries: [String]? = nil,
        webApp: WebAppConfig? = nil,
        file: FileConfig? = nil,
        cli: CLIConfig? = nil,
        engineVersion: Int = ShortcutConfig.currentEngineVersion
```

Edit 4, `ShortcutConfig.swift` lines 78–80 (memberwise init body).

Old:

```swift
        self.homeSymlinkEntries = homeSymlinkEntries
        self.webApp = webApp
        self.engineVersion = engineVersion
```

New:

```swift
        self.homeSymlinkEntries = homeSymlinkEntries
        self.webApp = webApp
        self.file = file
        self.cli = cli
        self.engineVersion = engineVersion
```

Edit 5, `ShortcutConfig.swift` line 86 (`CodingKeys`).

Old:

```swift
        case iconMode, customIconPath, homeSymlinkEntries, webApp, engineVersion
```

New:

```swift
        case iconMode, customIconPath, homeSymlinkEntries, webApp, file, cli, engineVersion
```

Edit 6, `ShortcutConfig.swift` line 89 (`init(from:)` doc comment).

Old:

```swift
    /// Decodes Phase 1 to 3 dictionaries too: `iconMode`, `customIconPath`, `homeSymlinkEntries` and `webApp` are optional on input.
```

New:

```swift
    /// Decodes Phase 1 to 4 dictionaries too: `iconMode`, `customIconPath`, `homeSymlinkEntries`, `webApp`, `file` and `cli`
    /// are optional on input.
```

Edit 7, `ShortcutConfig.swift` lines 110–111 (`init(from:)` body).

Old:

```swift
        webApp = try container.decodeIfPresent(WebAppConfig.self, forKey: .webApp)
        engineVersion = try container.decode(Int.self, forKey: .engineVersion)
```

New:

```swift
        webApp = try container.decodeIfPresent(WebAppConfig.self, forKey: .webApp)
        file = try container.decodeIfPresent(FileConfig.self, forKey: .file)
        cli = try container.decodeIfPresent(CLIConfig.self, forKey: .cli)
        engineVersion = try container.decode(Int.self, forKey: .engineVersion)
```

`plistDictionary()` needs no change: it encodes through `PropertyListEncoder`, which omits nil optionals, so existing shortcuts keep their exact key set and `engineVersion` stays 1.

- [ ] **Step 12: Run the three suites and watch them pass**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.ShortcutConfigTests 2>&1 | grep -E "Executed|error:" | tail -2`
Expected: `Executed 16 tests, with 0 failures` (12 existing + 4 new).
Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.FileConfigTests 2>&1 | grep -E "Executed|error:" | tail -2`
Expected: `Executed 4 tests, with 0 failures`.
Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.CLIConfigTests 2>&1 | grep -E "Executed|error:" | tail -2`
Expected: `Executed 5 tests, with 0 failures`.
Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests 2>&1 | grep -E "Executed|error:" | tail -1`
Expected: `Executed 185 tests, with 0 failures` (172 at HEAD `8631c10` + 13 new).

- [ ] **Step 13: Commit**

```bash
cd ~/Developer/MacAppDuplicator && git add Packages/DuplicatorCore/Sources/DuplicatorCore/FileConfig.swift Packages/DuplicatorCore/Sources/DuplicatorCore/CLIConfig.swift Packages/DuplicatorCore/Sources/DuplicatorCore/Enums.swift Packages/DuplicatorCore/Sources/DuplicatorCore/ShortcutConfig.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/FileConfigTests.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/CLIConfigTests.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/ShortcutConfigTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Add FileConfig, CLIConfig and TerminalChoice to ShortcutConfig" -m "File, folder and command shortcuts get their own optional MADConfig sections. Both decode to nil when absent, so every Phase 1 to 4 shortcut still loads, and CLIConfig needs only executablePath on input." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 2: Core launcher planning — `LauncherAction`, `TerminalCommandBuilder`, `LaunchPreparer` kind dispatch, new `LauncherError` cases

**Files:**
- Create: `Packages/DuplicatorCore/Sources/DuplicatorCore/LauncherAction.swift`, `Packages/DuplicatorCore/Sources/DuplicatorCore/TerminalCommandBuilder.swift`
- Modify: `Packages/DuplicatorCore/Sources/DuplicatorCore/LaunchPreparer.swift`, `.../LauncherError.swift`, `.../LauncherError+ExitCode.swift`
- Test: `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/TerminalCommandBuilderTests.swift`, `.../LauncherActionPlannerTests.swift`, extend `.../LauncherErrorTests.swift`

**Interfaces:**
- Consumes: Task 1 types, `HomeTreeBuilder`, `ShortcutConfig.defaultDataPath(forSlug:home:)`, `SecretMasking`.
- Produces:
  ```swift
  public enum LauncherAction: Equatable, Sendable {
      case open(items: [URL], openerApp: URL?)                     // file / folder
      case spawn(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL?, terminal: TerminalChoice)
  }
  public struct TerminalCommandBuilder: Sendable {
      public static func shellQuoted(_ argv: [String]) -> String                  // 'a' 'b c' with '\'' escaping
      public static func appleScriptLiteral(_ text: String) -> String             // "..." with \\ and \" escaped
      public static func terminalScript(command: String, workingDirectory: String?) -> String   // tell application "Terminal" ... do script ...
      public static func iTermScript(command: String, workingDirectory: String?) -> String      // create window with default profile command ...
      public func argv(for cli: CLIConfig, terminalApp: URL?, inlineEnvironment: [String: String]) throws -> [String]  // inlineEnvironment: Terminal/iTerm2 run `/usr/bin/env 'K=V'… exe args…` in the new shell; .none/.ghostty ignore it. .none → [exe]+args; .terminal/.iterm2 → ["/usr/bin/osascript","-e",script]; .ghostty → [<ghostty binary>, "-e", exe, args...]
  }
  public struct LauncherActionPlanner {   // NOT Sendable: it stores a FileManager
      public init(fileManager: FileManager = .default, realHome: URL, terminalLocator: @escaping @Sendable (TerminalChoice) -> URL?)
      public func plan(config: ShortcutConfig, baseEnvironment: [String: String], shortcutBundleURL: URL?) throws -> LauncherAction
  }
  // LaunchPreparer
  public enum PreparedShortcut: Sendable { case app(PreparedLaunch), launcher(LauncherAction, ShortcutConfig) }
  public func prepareShortcut(infoDictionary:shortcutBundleURL:baseEnvironment:realHome:terminalLocator:) throws -> PreparedShortcut
  // LauncherError new cases
  case fileNotFound(path: String)                 // exit 2
  case terminalNotFound(TerminalChoice)           // exit 5
  case spawnFailed(errno: Int32, path: String)    // exit 3
  case launcherConfigMissing(ShortcutKind)        // exit 1 ("Shortcut is damaged — open macOS App Duplicator and Regenerate.")
  ```
  The planner also throws the existing `dataPathNotWritable(String)` (exit 4) when the shortcut's HOME folder cannot be created.

  The planner computes `additions` = `MAD_SHORTCUT_NAME`, `MAD_SHORTCUT_BUNDLE` (when the bundle URL is known), `HOME`/`CFFIXED_USER_HOME` when `homeOverride`, then `config.environment` (last wins). The `.spawn` environment is the base environment minus `MAD_*`, merged with `additions`. Terminal.app and iTerm2 open a fresh login shell that does not inherit `osascript`'s environment, so for those two the same `additions` are also written into the shell command through `TerminalCommandBuilder.argv(for:terminalApp:inlineEnvironment:)`. "No terminal" and Ghostty receive them through `posix_spawn`.

#### Group A: new `LauncherError` cases

- [ ] **Step 1: Extend `LauncherErrorTests`**

In `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/LauncherErrorTests.swift`, replace the last test and the class's closing brace (lines 26–34).

Old:

```swift
    func testExitCodesFollowTheErrorTable() {
        XCTAssertEqual(LauncherError.configMissing.exitCode, 1)
        XCTAssertEqual(LauncherError.configCorrupt("x").exitCode, 1)
        XCTAssertEqual(LauncherError.targetNotFound(path: "/x", bundleID: "y").exitCode, 2)
        XCTAssertEqual(LauncherError.notAnAppBundle("/x").exitCode, 2)
        XCTAssertEqual(LauncherError.execFailed(errno: EACCES, path: "/x").exitCode, 3)
        XCTAssertEqual(LauncherError.dataPathNotWritable("/x").exitCode, 4)
    }
}
```

New:

```swift
    func testExitCodesFollowTheErrorTable() {
        XCTAssertEqual(LauncherError.configMissing.exitCode, 1)
        XCTAssertEqual(LauncherError.configCorrupt("x").exitCode, 1)
        XCTAssertEqual(LauncherError.targetNotFound(path: "/x", bundleID: "y").exitCode, 2)
        XCTAssertEqual(LauncherError.notAnAppBundle("/x").exitCode, 2)
        XCTAssertEqual(LauncherError.execFailed(errno: EACCES, path: "/x").exitCode, 3)
        XCTAssertEqual(LauncherError.dataPathNotWritable("/x").exitCode, 4)
    }

    func testLauncherKindMessages() {
        XCTAssertEqual(
            LauncherError.fileNotFound(path: "/Users/test/Notes.md").errorDescription,
            "The file, folder or command was not found.\nStored path: /Users/test/Notes.md"
        )
        XCTAssertEqual(
            LauncherError.terminalNotFound(.terminal).errorDescription,
            "Terminal is not installed. Choose another terminal in macOS App Duplicator."
        )
        XCTAssertEqual(
            LauncherError.terminalNotFound(.iterm2).errorDescription,
            "iTerm2 is not installed. Choose another terminal in macOS App Duplicator."
        )
        XCTAssertEqual(
            LauncherError.terminalNotFound(.ghostty).errorDescription,
            "Ghostty is not installed. Choose another terminal in macOS App Duplicator."
        )
        XCTAssertEqual(
            LauncherError.terminalNotFound(TerminalChoice.none).errorDescription,
            "The selected terminal is not installed. Choose another terminal in macOS App Duplicator."
        )
        XCTAssertEqual(
            LauncherError.spawnFailed(errno: EACCES, path: "/usr/local/bin/tool").errorDescription,
            "Could not start /usr/local/bin/tool: Permission denied"
        )
        XCTAssertEqual(
            LauncherError.launcherConfigMissing(.cli).errorDescription,
            "Shortcut is damaged — open macOS App Duplicator and Regenerate. (The cli settings are missing.)"
        )
        XCTAssertEqual(
            LauncherError.launcherConfigMissing(.folder).errorDescription,
            "Shortcut is damaged — open macOS App Duplicator and Regenerate. (The folder settings are missing.)"
        )
    }

    func testLauncherKindExitCodes() {
        XCTAssertEqual(LauncherError.launcherConfigMissing(.file).exitCode, 1)
        XCTAssertEqual(LauncherError.fileNotFound(path: "/x").exitCode, 2)
        XCTAssertEqual(LauncherError.spawnFailed(errno: ENOENT, path: "/x").exitCode, 3)
        XCTAssertEqual(LauncherError.terminalNotFound(.ghostty).exitCode, 5)
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.LauncherErrorTests 2>&1 | grep -E "error:" | head -5`
Expected: build errors such as `type 'LauncherError' has no member 'fileNotFound'`; no tests run.

- [ ] **Step 3: Add the four cases, their messages and exit codes**

Replace the whole of `Packages/DuplicatorCore/Sources/DuplicatorCore/LauncherError.swift` with:

```swift
import Foundation

/// Every failure the launcher reports (spec §4.7). Exit codes live in `LauncherError+ExitCode.swift`.
public enum LauncherError: Error, LocalizedError {
    case configMissing
    case configCorrupt(String)
    case targetNotFound(path: String, bundleID: String)
    case dataPathNotWritable(String)
    case execFailed(errno: Int32, path: String)
    case notAnAppBundle(String)
    /// A file or folder shortcut's item, its opener app, a command's executable or working directory is missing.
    case fileNotFound(path: String)
    /// The command shortcut's terminal app is not installed.
    case terminalNotFound(TerminalChoice)
    /// `posix_spawn` failed for a command shortcut.
    case spawnFailed(errno: Int32, path: String)
    /// A launcher-kind `MADConfig` has no `file` / `cli` settings.
    case launcherConfigMissing(ShortcutKind)

    public var errorDescription: String? {
        switch self {
        case .configMissing:
            return "Shortcut is damaged — open macOS App Duplicator and Regenerate. (MADConfig is missing.)"
        case .configCorrupt(let detail):
            return "Shortcut is damaged — open macOS App Duplicator and Regenerate. (\(detail))"
        case .targetNotFound(let path, let bundleID):
            return "The target app was not found.\nStored path: \(path)\nBundle ID: \(bundleID)"
        case .dataPathNotWritable(let path):
            return "The data folder is not writable: \(path)"
        case .execFailed(let code, let path):
            return "Could not start \(path): \(String(cString: strerror(code)))"
        case .notAnAppBundle(let path):
            return "\(path) is not a valid application bundle."
        case .fileNotFound(let path):
            return "The file, folder or command was not found.\nStored path: \(path)"
        case .terminalNotFound(let terminal):
            return "\(Self.terminalName(terminal)) is not installed. Choose another terminal in macOS App Duplicator."
        case .spawnFailed(let code, let path):
            return "Could not start \(path): \(String(cString: strerror(code)))"
        case .launcherConfigMissing(let kind):
            return "Shortcut is damaged — open macOS App Duplicator and Regenerate. (The \(kind.rawValue) settings are missing.)"
        }
    }

    private static func terminalName(_ terminal: TerminalChoice) -> String {
        switch terminal {
        case .none:
            return "The selected terminal"
        case .terminal:
            return "Terminal"
        case .iterm2:
            return "iTerm2"
        case .ghostty:
            return "Ghostty"
        }
    }
}
```

Replace the whole of `Packages/DuplicatorCore/Sources/DuplicatorCore/LauncherError+ExitCode.swift` with:

```swift
import Foundation

extension LauncherError {
    /// Launcher process exit code (spec §4.7).
    public var exitCode: Int32 {
        switch self {
        case .configMissing, .configCorrupt, .launcherConfigMissing:
            return 1
        case .targetNotFound, .notAnAppBundle, .fileNotFound:
            return 2
        case .execFailed, .spawnFailed:
            return 3
        case .dataPathNotWritable:
            return 4
        case .terminalNotFound:
            return 5
        }
    }
}
```

Nothing outside Core switches exhaustively over `LauncherError` (the Launcher's `fail` reads `exitCode`), so adding cases breaks no caller.

- [ ] **Step 4: Run the tests and watch them pass**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.LauncherErrorTests 2>&1 | grep -E "Executed|error:" | tail -2`
Expected: `Executed 4 tests, with 0 failures`.

#### Group B: `TerminalCommandBuilder`

- [ ] **Step 5: Write the failing `TerminalCommandBuilder` tests**

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/TerminalCommandBuilderTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore

final class TerminalCommandBuilderTests: XCTestCase {
    private let terminalApp = URL(filePath: "/System/Applications/Utilities/Terminal.app", directoryHint: .isDirectory)
    private let iTermApp = URL(filePath: "/Applications/iTerm.app", directoryHint: .isDirectory)
    private let ghosttyApp = URL(filePath: "/Applications/Ghostty.app", directoryHint: .isDirectory)

    func testShellQuotedWrapsEveryElementAndEscapesSingleQuotes() {
        XCTAssertEqual(TerminalCommandBuilder.shellQuoted(["/bin/echo", "a b", "it's"]), #"'/bin/echo' 'a b' 'it'\''s'"#)
        XCTAssertEqual(TerminalCommandBuilder.shellQuoted(["$HOME", "`x`", ""]), #"'$HOME' '`x`' ''"#)
        XCTAssertEqual(TerminalCommandBuilder.shellQuoted([]), "")
    }

    func testAppleScriptLiteralEscapesBackslashesBeforeQuotes() {
        XCTAssertEqual(TerminalCommandBuilder.appleScriptLiteral(#"say "hi" \n"#), #""say \"hi\" \\n""#)
        XCTAssertEqual(TerminalCommandBuilder.appleScriptLiteral(#"\""#), #""\\\"""#)
        XCTAssertEqual(TerminalCommandBuilder.appleScriptLiteral("plain"), #""plain""#)
    }

    func testTerminalScriptWithAndWithoutWorkingDirectory() {
        XCTAssertEqual(
            TerminalCommandBuilder.terminalScript(command: "'/usr/bin/top' '-o' 'cpu'", workingDirectory: nil),
            #"""
            tell application "Terminal"
                activate
                do script "'/usr/bin/top' '-o' 'cpu'"
            end tell
            """#
        )
        XCTAssertEqual(
            TerminalCommandBuilder.terminalScript(command: "'/bin/ls'", workingDirectory: #"/Users/test/My "Dir""#),
            #"""
            tell application "Terminal"
                activate
                do script "cd '/Users/test/My \"Dir\"' && '/bin/ls'"
            end tell
            """#
        )
    }

    func testITermScriptWithAndWithoutWorkingDirectory() {
        XCTAssertEqual(
            TerminalCommandBuilder.iTermScript(command: "'/usr/bin/top'", workingDirectory: nil),
            #"""
            tell application "iTerm2"
                activate
                create window with default profile command "'/usr/bin/top'"
            end tell
            """#
        )
        XCTAssertEqual(
            TerminalCommandBuilder.iTermScript(command: "'/usr/bin/top'", workingDirectory: "/Users/test/it's"),
            #"""
            tell application "iTerm2"
                activate
                create window with default profile command "cd '/Users/test/it'\\''s' && '/usr/bin/top'"
            end tell
            """#
        )
    }

    func testArgvForNoneIsTheCommandItself() throws {
        let cli = CLIConfig(executablePath: "/bin/sh", arguments: ["-c", "echo hi"], workingDirectory: "/tmp", terminal: TerminalChoice.none)
        XCTAssertEqual(try TerminalCommandBuilder().argv(for: cli, terminalApp: nil, inlineEnvironment: [:]), ["/bin/sh", "-c", "echo hi"])
    }

    func testArgvForTerminalRunsOsascriptWithTheTerminalScript() throws {
        let cli = CLIConfig(executablePath: "/usr/bin/top", arguments: ["-o", "cpu"], workingDirectory: "~/Projects", terminal: .terminal)
        let argv = try TerminalCommandBuilder().argv(for: cli, terminalApp: terminalApp, inlineEnvironment: [:])
        let script = TerminalCommandBuilder.terminalScript(command: "'/usr/bin/top' '-o' 'cpu'", workingDirectory: NSHomeDirectory() + "/Projects")
        XCTAssertEqual(argv, ["/usr/bin/osascript", "-e", script])
        XCTAssertTrue(argv[2].contains("do script \"cd '\(NSHomeDirectory())/Projects' && '/usr/bin/top' '-o' 'cpu'\""), argv[2])
    }

    func testArgvForITermRunsOsascriptWithTheITermScript() throws {
        let cli = CLIConfig(executablePath: "/usr/bin/ssh", arguments: ["it's"], terminal: .iterm2)
        let argv = try TerminalCommandBuilder().argv(for: cli, terminalApp: iTermApp, inlineEnvironment: [:])
        XCTAssertEqual(argv, ["/usr/bin/osascript", "-e", TerminalCommandBuilder.iTermScript(command: #"'/usr/bin/ssh' 'it'\''s'"#, workingDirectory: nil)])
        XCTAssertTrue(argv[2].contains(#"create window with default profile command "'/usr/bin/ssh' 'it'\\''s'""#), argv[2])
    }

    func testArgvForGhosttyRunsTheGhosttyBinaryWithDashE() throws {
        let cli = CLIConfig(executablePath: "/opt/homebrew/bin/htop", arguments: ["-d", "10"], workingDirectory: "/tmp", terminal: .ghostty)
        XCTAssertEqual(
            try TerminalCommandBuilder().argv(for: cli, terminalApp: ghosttyApp, inlineEnvironment: [:]),
            ["/Applications/Ghostty.app/Contents/MacOS/ghostty", "-e", "/opt/homebrew/bin/htop", "-d", "10"]
        )
    }

    func testArgvThrowsTerminalNotFoundWhenTheTerminalAppIsMissing() {
        for choice in [TerminalChoice.terminal, TerminalChoice.iterm2, TerminalChoice.ghostty] {
            let cli = CLIConfig(executablePath: "/bin/ls", terminal: choice)
            XCTAssertThrowsError(try TerminalCommandBuilder().argv(for: cli, terminalApp: nil, inlineEnvironment: [:])) { error in
                guard case LauncherError.terminalNotFound(let reported) = error else {
                    return XCTFail("expected terminalNotFound, got \(error)")
                }
                XCTAssertEqual(reported, choice)
            }
        }
    }

    // MARK: Inline environment (Terminal.app and iTerm2 start a fresh login shell, so the environment goes into the command)

    func testTerminalAndITermWriteTheSortedEnvironmentAfterUsrBinEnv() throws {
        let environment = ["MAD_SHORTCUT_NAME": "Top", "HOME": "/Users/test/own", "A_FIRST": "1"]
        let command = "/usr/bin/env 'A_FIRST=1' 'HOME=/Users/test/own' 'MAD_SHORTCUT_NAME=Top' '/usr/bin/top' '-o' 'cpu'"
        var cli = CLIConfig(executablePath: "/usr/bin/top", arguments: ["-o", "cpu"], workingDirectory: "/tmp", terminal: .terminal)

        let terminalArgv = try TerminalCommandBuilder().argv(for: cli, terminalApp: terminalApp, inlineEnvironment: environment)
        XCTAssertEqual(terminalArgv, ["/usr/bin/osascript", "-e", TerminalCommandBuilder.terminalScript(command: command, workingDirectory: "/tmp")])
        XCTAssertTrue(terminalArgv[2].contains("do script \"cd '/tmp' && /usr/bin/env 'A_FIRST=1' 'HOME=/Users/test/own'"), terminalArgv[2])

        cli.terminal = .iterm2
        let iTermArgv = try TerminalCommandBuilder().argv(for: cli, terminalApp: iTermApp, inlineEnvironment: environment)
        XCTAssertEqual(iTermArgv, ["/usr/bin/osascript", "-e", TerminalCommandBuilder.iTermScript(command: command, workingDirectory: "/tmp")])
    }

    func testInlineEnvironmentValueWithSpaceAndSingleQuoteIsQuoted() throws {
        let cli = CLIConfig(executablePath: "/bin/ls", terminal: .terminal)
        let argv = try TerminalCommandBuilder().argv(for: cli, terminalApp: terminalApp, inlineEnvironment: ["GREETING": "it's a test"])
        XCTAssertEqual(
            argv,
            ["/usr/bin/osascript", "-e", TerminalCommandBuilder.terminalScript(command: #"/usr/bin/env 'GREETING=it'\''s a test' '/bin/ls'"#, workingDirectory: nil)]
        )
        XCTAssertTrue(argv[2].contains(#"do script "/usr/bin/env 'GREETING=it'\\''s a test' '/bin/ls'""#), argv[2])
    }

    func testEmptyInlineEnvironmentAddsNoEnvPrefix() throws {
        let cli = CLIConfig(executablePath: "/usr/bin/top", terminal: .terminal)
        let argv = try TerminalCommandBuilder().argv(for: cli, terminalApp: terminalApp, inlineEnvironment: [:])
        XCTAssertEqual(argv, ["/usr/bin/osascript", "-e", TerminalCommandBuilder.terminalScript(command: "'/usr/bin/top'", workingDirectory: nil)])
        XCTAssertFalse(argv[2].contains("/usr/bin/env"), argv[2])
    }

    func testNoTerminalAndGhosttyIgnoreTheInlineEnvironment() throws {
        let environment = ["HOME": "/Users/test/own", "MAD_SHORTCUT_NAME": "Top"]
        let plain = CLIConfig(executablePath: "/bin/sh", arguments: ["-c", "echo hi"], terminal: TerminalChoice.none)
        XCTAssertEqual(try TerminalCommandBuilder().argv(for: plain, terminalApp: nil, inlineEnvironment: environment), ["/bin/sh", "-c", "echo hi"])
        let ghostty = CLIConfig(executablePath: "/opt/homebrew/bin/htop", arguments: ["-d", "10"], terminal: .ghostty)
        XCTAssertEqual(
            try TerminalCommandBuilder().argv(for: ghostty, terminalApp: ghosttyApp, inlineEnvironment: environment),
            ["/Applications/Ghostty.app/Contents/MacOS/ghostty", "-e", "/opt/homebrew/bin/htop", "-d", "10"]
        )
    }
}
```

- [ ] **Step 6: Run them and watch them fail**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.TerminalCommandBuilderTests 2>&1 | grep -E "error:" | head -5`
Expected: build errors such as `cannot find 'TerminalCommandBuilder' in scope`; no tests run.

- [ ] **Step 7: Implement `TerminalCommandBuilder`**

Create `Packages/DuplicatorCore/Sources/DuplicatorCore/TerminalCommandBuilder.swift`:

```swift
import Foundation

/// Builds the argv the Launcher spawns for a command shortcut (spec §6). Terminal.app and iTerm2 get an AppleScript
/// run by `/usr/bin/osascript`, Ghostty gets its own binary with `-e`, and `.none` runs the command itself.
public struct TerminalCommandBuilder: Sendable {
    /// The AppleScript runner for Terminal.app and iTerm2.
    public static let osascriptPath = "/usr/bin/osascript"

    public init() {}

    /// Every element wrapped in single quotes, `'` written as `'\''`, joined with spaces: `'a' 'b c'`.
    public static func shellQuoted(_ argv: [String]) -> String {
        argv.map { "'" + $0.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }.joined(separator: " ")
    }

    /// An AppleScript string literal: `\` escaped first, then `"`, wrapped in double quotes.
    public static func appleScriptLiteral(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    /// Terminal.app: activate, then `do script` the command in a new window.
    public static func terminalScript(command: String, workingDirectory: String?) -> String {
        """
        tell application "Terminal"
            activate
            do script \(appleScriptLiteral(shellCommand(command, workingDirectory: workingDirectory)))
        end tell
        """
    }

    /// iTerm2: activate, then a new window with the default profile running the command.
    public static func iTermScript(command: String, workingDirectory: String?) -> String {
        """
        tell application "iTerm2"
            activate
            create window with default profile command \(appleScriptLiteral(shellCommand(command, workingDirectory: workingDirectory)))
        end tell
        """
    }

    /// `cd '<dir>' && <command>` when a working directory is set, else `command`.
    static func shellCommand(_ command: String, workingDirectory: String?) -> String {
        guard let workingDirectory, !workingDirectory.isEmpty else {
            return command
        }
        return "cd \(shellQuoted([workingDirectory])) && \(command)"
    }

    /// The command as the shell in a new Terminal or iTerm2 window must run it. That window starts a fresh login shell
    /// that does not inherit `osascript`'s environment, so a non-empty `environment` is written into the command:
    /// `/usr/bin/env 'K=V' … '<exe>' '<arg>' …` with the keys sorted and every token shell-quoted. An empty one
    /// gives just the quoted command, with no `/usr/bin/env`.
    static func inlineCommand(_ command: [String], environment: [String: String]) -> String {
        guard !environment.isEmpty else {
            return shellQuoted(command)
        }
        let assignments = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return "/usr/bin/env " + shellQuoted(assignments + command)
    }

    /// The argv for `cli`: `.none` → `[exe] + args`; `.terminal` / `.iterm2` → `["/usr/bin/osascript", "-e", script]`;
    /// `.ghostty` → `[<Ghostty.app>/Contents/MacOS/ghostty, "-e", exe] + args`. `terminalApp` is the terminal's `.app`
    /// URL. A leading `~` in `cli.workingDirectory` is expanded. `inlineEnvironment` is written into the shell command
    /// for `.terminal` / `.iterm2` only (see `inlineCommand`); `.none` and `.ghostty` ignore it, because the Launcher
    /// hands the environment to those processes through `posix_spawn`.
    /// - Throws: `LauncherError.terminalNotFound` when `cli.terminal` needs an app and `terminalApp` is nil.
    public func argv(for cli: CLIConfig, terminalApp: URL?, inlineEnvironment: [String: String]) throws -> [String] {
        let command = [cli.executablePath] + cli.arguments
        let workingDirectory = cli.workingDirectory.map { ($0 as NSString).expandingTildeInPath }
        switch cli.terminal {
        case .none:
            return command
        case .terminal:
            guard terminalApp != nil else {
                throw LauncherError.terminalNotFound(.terminal)
            }
            let script = Self.terminalScript(command: Self.inlineCommand(command, environment: inlineEnvironment), workingDirectory: workingDirectory)
            return [Self.osascriptPath, "-e", script]
        case .iterm2:
            guard terminalApp != nil else {
                throw LauncherError.terminalNotFound(.iterm2)
            }
            let script = Self.iTermScript(command: Self.inlineCommand(command, environment: inlineEnvironment), workingDirectory: workingDirectory)
            return [Self.osascriptPath, "-e", script]
        case .ghostty:
            guard let terminalApp else {
                throw LauncherError.terminalNotFound(.ghostty)
            }
            let ghostty = terminalApp.appending(path: "Contents/MacOS/ghostty", directoryHint: .notDirectory)
            return [ghostty.path, "-e"] + command
        }
    }
}
```

The command is always an argv array that is quoted here, never a shell string from the user, so a `'`, `$`, `` ` `` or `"` in any argument or environment value reaches the program unchanged. The quoting order matters: shell-quote each element first, then escape the whole command for the AppleScript literal (`\` before `"`). With an inline environment the command runs as `cd '<dir>' && /usr/bin/env 'K=V' … '<exe>' …`: the command runs inside the new login shell rather than replacing it (no `exec`), so when it ends the window drops back to a usable prompt instead of `[Process completed]`.

- [ ] **Step 8: Run the tests and watch them pass**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.TerminalCommandBuilderTests 2>&1 | grep -E "Executed|error:" | tail -2`
Expected: `Executed 13 tests, with 0 failures`.

#### Group C: `LauncherAction`, `LauncherActionPlanner` and `LaunchPreparer.prepareShortcut`

- [ ] **Step 9: Write the failing planner tests**

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/LauncherActionPlannerTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore

final class LauncherActionPlannerTests: XCTestCase {
    private static let installed: @Sendable (TerminalChoice) -> URL? = { choice in
        switch choice {
        case .none:
            return nil
        case .terminal:
            return URL(filePath: "/System/Applications/Utilities/Terminal.app", directoryHint: .isDirectory)
        case .iterm2:
            return URL(filePath: "/Applications/iTerm.app", directoryHint: .isDirectory)
        case .ghostty:
            return URL(filePath: "/Applications/Ghostty.app", directoryHint: .isDirectory)
        }
    }

    private static let nothingInstalled: @Sendable (TerminalChoice) -> URL? = { _ in nil }

    private func makeConfig(
        kind: ShortcutKind,
        file: FileConfig? = nil,
        cli: CLIConfig? = nil,
        environment: [String: String] = [:]
    ) -> ShortcutConfig {
        ShortcutConfig(
            kind: kind,
            name: "Projects",
            slug: "projects",
            bundleIdentifier: "com.mikekuta.appduplicator.projects",
            targetPath: "",
            targetBundleIdentifier: "",
            dataMode: .disabled,
            environment: environment,
            file: file,
            cli: cli
        )
    }

    private func makePlanner(
        realHome: URL,
        locator: @escaping @Sendable (TerminalChoice) -> URL? = LauncherActionPlannerTests.installed
    ) -> LauncherActionPlanner {
        LauncherActionPlanner(realHome: realHome, terminalLocator: locator)
    }

    private func assertLauncherError(
        _ expression: @autoclosure () throws -> LauncherAction,
        file: StaticString = #filePath,
        line: UInt = #line,
        matches: (LauncherError) -> Bool
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let launcherError = error as? LauncherError else {
                return XCTFail("expected LauncherError, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(matches(launcherError), "unexpected error: \(launcherError)", file: file, line: line)
        }
    }

    // MARK: File and folder shortcuts

    func testFileShortcutOpensThePathWithTheDefaultHandler() throws {
        let root = try makeTemporaryDirectory()
        let report = root.appending(path: "Report.pdf")
        try Data("pdf".utf8).write(to: report)
        let config = makeConfig(kind: .file, file: FileConfig(path: report.path))

        let action = try makePlanner(realHome: root).plan(config: config, baseEnvironment: [:], shortcutBundleURL: nil)

        XCTAssertEqual(action, .open(items: [URL(filePath: report.path, directoryHint: .checkFileSystem)], openerApp: nil))
    }

    func testFolderShortcutStripsTheTrailingSlashAndKeepsTheOpener() throws {
        let root = try makeTemporaryDirectory()
        let folder = root.appending(path: "Projects", directoryHint: .isDirectory)
        let opener = root.appending(path: "Opener.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: opener, withIntermediateDirectories: true)
        let config = makeConfig(kind: .folder, file: FileConfig(path: folder.path + "/", openerAppPath: opener.path))

        let action = try makePlanner(realHome: root).plan(config: config, baseEnvironment: [:], shortcutBundleURL: nil)

        XCTAssertEqual(
            action,
            .open(
                items: [URL(filePath: folder.path, directoryHint: .checkFileSystem)],
                openerApp: URL(filePath: opener.path, directoryHint: .isDirectory)
            )
        )
    }

    func testMissingFileOrOpenerThrowsFileNotFound() throws {
        let root = try makeTemporaryDirectory()
        let missing = root.appending(path: "Missing.txt").path
        let planner = makePlanner(realHome: root)
        assertLauncherError(
            try planner.plan(config: makeConfig(kind: .file, file: FileConfig(path: missing)), baseEnvironment: [:], shortcutBundleURL: nil)
        ) { error in
            if case .fileNotFound(let path) = error { return path == missing }
            return false
        }

        let missingOpener = root.appending(path: "Nope.app").path
        let config = makeConfig(kind: .folder, file: FileConfig(path: root.path, openerAppPath: missingOpener))
        assertLauncherError(try planner.plan(config: config, baseEnvironment: [:], shortcutBundleURL: nil)) { error in
            if case .fileNotFound(let path) = error { return path == missingOpener }
            return false
        }
    }

    func testMissingSubConfigThrowsLauncherConfigMissing() throws {
        let planner = makePlanner(realHome: try makeTemporaryDirectory())
        for kind in [ShortcutKind.file, ShortcutKind.folder, ShortcutKind.cli] {
            assertLauncherError(try planner.plan(config: makeConfig(kind: kind), baseEnvironment: [:], shortcutBundleURL: nil)) { error in
                if case .launcherConfigMissing(let reported) = error { return reported == kind }
                return false
            }
        }
    }

    func testAppAndWebAppAreNotLauncherKinds() throws {
        let planner = makePlanner(realHome: try makeTemporaryDirectory())
        for kind in [ShortcutKind.app, ShortcutKind.webApp] {
            assertLauncherError(try planner.plan(config: makeConfig(kind: kind), baseEnvironment: [:], shortcutBundleURL: nil)) { error in
                if case .configCorrupt(let detail) = error { return detail == "\(kind.rawValue) is not a launcher kind" }
                return false
            }
        }
    }

    // MARK: Command shortcuts

    func testDetachedCommandGetsTheShortcutEnvironment() throws {
        let root = try makeTemporaryDirectory()
        let cli = CLIConfig(executablePath: "/bin/sh", arguments: ["-c", "env"], workingDirectory: root.path, terminal: TerminalChoice.none)
        let config = makeConfig(kind: .cli, cli: cli, environment: ["PATH": "/opt/bin", "API_TOKEN": "secret"])
        let base = ["PATH": "/usr/bin", "LANG": "en_US.UTF-8", "MAD_TARGET": "stale", "MAD_SHORTCUT_NAME": "Stale"]

        let action = try makePlanner(realHome: root).plan(
            config: config,
            baseEnvironment: base,
            shortcutBundleURL: URL(filePath: "/Applications/Projects.app", directoryHint: .isDirectory)
        )

        XCTAssertEqual(
            action,
            .spawn(
                executable: URL(filePath: "/bin/sh", directoryHint: .notDirectory),
                arguments: ["-c", "env"],
                environment: [
                    "PATH": "/opt/bin",
                    "LANG": "en_US.UTF-8",
                    "API_TOKEN": "secret",
                    "MAD_SHORTCUT_NAME": "Projects",
                    "MAD_SHORTCUT_BUNDLE": "/Applications/Projects.app",
                ],
                workingDirectory: URL(filePath: root.path, directoryHint: .isDirectory),
                terminal: TerminalChoice.none
            )
        )
    }

    func testTildeWorkingDirectoryIsExpandedAndNilBundleIsLeftOut() throws {
        let cli = CLIConfig(executablePath: "/bin/ls", workingDirectory: "~", terminal: TerminalChoice.none)

        let action = try makePlanner(realHome: try makeTemporaryDirectory())
            .plan(config: makeConfig(kind: .cli, cli: cli), baseEnvironment: [:], shortcutBundleURL: nil)

        XCTAssertEqual(
            action,
            .spawn(
                executable: URL(filePath: "/bin/ls", directoryHint: .notDirectory),
                arguments: [],
                environment: ["MAD_SHORTCUT_NAME": "Projects"],
                workingDirectory: URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory),
                terminal: TerminalChoice.none
            )
        )
    }

    func testMissingOrUnusableExecutableThrowsFileNotFound() throws {
        let root = try makeTemporaryDirectory()
        let script = root.appending(path: "tool.sh")
        try Data("echo hi\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
        let planner = makePlanner(realHome: root)

        for path in [root.appending(path: "missing-tool").path, script.path, root.path] {
            let config = makeConfig(kind: .cli, cli: CLIConfig(executablePath: path, terminal: TerminalChoice.none))
            assertLauncherError(try planner.plan(config: config, baseEnvironment: [:], shortcutBundleURL: nil)) { error in
                if case .fileNotFound(let reported) = error { return reported == path }
                return false
            }
        }
    }

    func testMissingWorkingDirectoryThrowsFileNotFound() throws {
        let root = try makeTemporaryDirectory()
        let missing = root.appending(path: "gone").path
        let config = makeConfig(kind: .cli, cli: CLIConfig(executablePath: "/bin/ls", workingDirectory: missing, terminal: TerminalChoice.none))

        assertLauncherError(try makePlanner(realHome: root).plan(config: config, baseEnvironment: [:], shortcutBundleURL: nil)) { error in
            if case .fileNotFound(let path) = error { return path == missing }
            return false
        }
    }

    func testTerminalChoiceRunsOsascriptAndTheScriptChangesDirectory() throws {
        let root = try makeTemporaryDirectory()
        let cli = CLIConfig(executablePath: "/usr/bin/top", arguments: ["-o", "cpu"], workingDirectory: root.path, terminal: .terminal)

        let action = try makePlanner(realHome: root).plan(config: makeConfig(kind: .cli, cli: cli), baseEnvironment: [:], shortcutBundleURL: nil)

        XCTAssertEqual(
            action,
            .spawn(
                executable: URL(filePath: "/usr/bin/osascript", directoryHint: .notDirectory),
                arguments: ["-e", TerminalCommandBuilder.terminalScript(
                    command: "/usr/bin/env 'MAD_SHORTCUT_NAME=Projects' '/usr/bin/top' '-o' 'cpu'",
                    workingDirectory: root.path
                )],
                environment: ["MAD_SHORTCUT_NAME": "Projects"],
                workingDirectory: nil,
                terminal: .terminal
            )
        )
    }

    func testGhosttyRunsItsBinaryAndKeepsTheWorkingDirectory() throws {
        let root = try makeTemporaryDirectory()
        let cli = CLIConfig(executablePath: "/bin/ls", arguments: ["-la"], workingDirectory: root.path, terminal: .ghostty)

        let action = try makePlanner(realHome: root).plan(config: makeConfig(kind: .cli, cli: cli), baseEnvironment: [:], shortcutBundleURL: nil)

        XCTAssertEqual(
            action,
            .spawn(
                executable: URL(filePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty", directoryHint: .notDirectory),
                arguments: ["-e", "/bin/ls", "-la"],
                environment: ["MAD_SHORTCUT_NAME": "Projects"],
                workingDirectory: URL(filePath: root.path, directoryHint: .isDirectory),
                terminal: .ghostty
            )
        )
    }

    func testTerminalScriptCarriesTheWholeShortcutEnvironment() throws {
        let realHome = try makeTemporaryDirectory()
        let cli = CLIConfig(executablePath: "/usr/bin/top", terminal: .iterm2, homeOverride: true)
        let config = makeConfig(kind: .cli, cli: cli, environment: ["API_MODE": "fast mode"])
        let bundle = URL(filePath: "/Applications/Projects.app", directoryHint: .isDirectory)

        let action = try makePlanner(realHome: realHome).plan(config: config, baseEnvironment: ["PATH": "/usr/bin"], shortcutBundleURL: bundle)

        guard case .spawn(_, let arguments, let environment, _, _) = action else {
            return XCTFail("expected spawn, got \(action)")
        }
        let home = try XCTUnwrap(environment["HOME"])
        let command = "/usr/bin/env " + TerminalCommandBuilder.shellQuoted([
            "API_MODE=fast mode", "CFFIXED_USER_HOME=\(home)", "HOME=\(home)",
            "MAD_SHORTCUT_BUNDLE=/Applications/Projects.app", "MAD_SHORTCUT_NAME=Projects", "/usr/bin/top",
        ])
        XCTAssertEqual(arguments, ["-e", TerminalCommandBuilder.iTermScript(command: command, workingDirectory: nil)])
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["MAD_SHORTCUT_NAME"], "Projects")
        XCTAssertEqual(environment["API_MODE"], "fast mode")
    }

    func testUninstalledTerminalDoesNotCreateTheHomeFolder() throws {
        let realHome = try makeTemporaryDirectory()
        let planner = makePlanner(realHome: realHome, locator: LauncherActionPlannerTests.nothingInstalled)
        let config = makeConfig(kind: .cli, cli: CLIConfig(executablePath: "/usr/bin/top", terminal: .terminal, homeOverride: true))

        assertLauncherError(try planner.plan(config: config, baseEnvironment: [:], shortcutBundleURL: nil)) { error in
            if case .terminalNotFound(let choice) = error { return choice == .terminal }
            return false
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ShortcutConfig.defaultDataPath(forSlug: "projects", home: realHome)))
    }

    func testUninstalledTerminalThrowsTerminalNotFound() throws {
        let planner = makePlanner(realHome: try makeTemporaryDirectory(), locator: LauncherActionPlannerTests.nothingInstalled)
        let config = makeConfig(kind: .cli, cli: CLIConfig(executablePath: "/usr/bin/top", terminal: .iterm2))

        assertLauncherError(try planner.plan(config: config, baseEnvironment: [:], shortcutBundleURL: nil)) { error in
            if case .terminalNotFound(let choice) = error { return choice == .iterm2 }
            return false
        }
    }

    // MARK: HOME override (spec §4.3)

    func testHomeOverrideBuildsTheShortcutHomeTree() throws {
        let realHome = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: realHome.appending(path: "Documents"), withIntermediateDirectories: true)
        let cli = CLIConfig(executablePath: "/bin/ls", terminal: TerminalChoice.none, homeOverride: true)

        let action = try makePlanner(realHome: realHome).plan(config: makeConfig(kind: .cli, cli: cli), baseEnvironment: [:], shortcutBundleURL: nil)

        guard case .spawn(_, _, let environment, _, _) = action else {
            return XCTFail("expected spawn, got \(action)")
        }
        let home = URL(filePath: ShortcutConfig.defaultDataPath(forSlug: "projects", home: realHome)).standardizedFileURL.path
        XCTAssertEqual(environment["HOME"], home)
        XCTAssertEqual(environment["CFFIXED_USER_HOME"], home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/" + HomeTreeBuilder.markerFileName))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: home + "/Documents"),
            realHome.appending(path: "Documents").path
        )
    }

    func testHomeOverrideUsesAUserSubfolderWhenTheDataFolderIsNotEmpty() throws {
        let realHome = try makeTemporaryDirectory()
        let dataPath = URL(filePath: ShortcutConfig.defaultDataPath(forSlug: "projects", home: realHome), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dataPath, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: dataPath.appending(path: "notes.txt"))
        let cli = CLIConfig(executablePath: "/bin/ls", terminal: TerminalChoice.none, homeOverride: true)

        let action = try makePlanner(realHome: realHome).plan(config: makeConfig(kind: .cli, cli: cli), baseEnvironment: [:], shortcutBundleURL: nil)

        guard case .spawn(_, _, let environment, _, _) = action else {
            return XCTFail("expected spawn, got \(action)")
        }
        XCTAssertEqual(environment["HOME"], dataPath.standardizedFileURL.appending(path: NSUserName()).path)
    }

    func testHomeOverrideFailureThrowsDataPathNotWritable() throws {
        let realHome = try makeTemporaryDirectory()
        try Data().write(to: realHome.appending(path: "Library"))
        let cli = CLIConfig(executablePath: "/bin/ls", terminal: TerminalChoice.none, homeOverride: true)
        let expected = ShortcutConfig.defaultDataPath(forSlug: "projects", home: realHome)

        assertLauncherError(
            try makePlanner(realHome: realHome).plan(config: makeConfig(kind: .cli, cli: cli), baseEnvironment: [:], shortcutBundleURL: nil)
        ) { error in
            if case .dataPathNotWritable(let path) = error { return path == expected }
            return false
        }
    }

    func testShortcutEnvironmentWinsOverTheHomeOverride() throws {
        let realHome = try makeTemporaryDirectory()
        let cli = CLIConfig(executablePath: "/bin/ls", terminal: TerminalChoice.none, homeOverride: true)
        let config = makeConfig(kind: .cli, cli: cli, environment: ["HOME": "/Users/test/custom"])

        let action = try makePlanner(realHome: realHome).plan(config: config, baseEnvironment: ["HOME": "/Users/real"], shortcutBundleURL: nil)

        guard case .spawn(_, _, let environment, _, _) = action else {
            return XCTFail("expected spawn, got \(action)")
        }
        XCTAssertEqual(environment["HOME"], "/Users/test/custom")
        XCTAssertEqual(
            environment["CFFIXED_USER_HOME"],
            URL(filePath: ShortcutConfig.defaultDataPath(forSlug: "projects", home: realHome)).standardizedFileURL.path
        )
    }

    // MARK: LaunchPreparer.prepareShortcut

    func testPrepareShortcutSendsLauncherKindsToThePlanner() throws {
        let root = try makeTemporaryDirectory()
        let config = makeConfig(kind: .folder, file: FileConfig(path: root.path))

        let prepared = try LaunchPreparer(realHome: root).prepareShortcut(
            infoDictionary: [ShortcutConfig.infoPlistKey: config.plistDictionary()],
            shortcutBundleURL: URL(filePath: "/Applications/Projects.app", directoryHint: .isDirectory),
            baseEnvironment: [:],
            realHome: root,
            terminalLocator: LauncherActionPlannerTests.installed
        )

        guard case .launcher(let action, let decoded) = prepared else {
            return XCTFail("expected launcher, got \(prepared)")
        }
        XCTAssertEqual(action, .open(items: [URL(filePath: root.path, directoryHint: .checkFileSystem)], openerApp: nil))
        XCTAssertEqual(decoded, config)
    }

    func testPrepareShortcutKeepsTheAppPathUnchanged() throws {
        let root = try makeTemporaryDirectory()
        let target = try FixtureBundle(name: "Target").writeSigned(in: root)
        let config = ShortcutConfig(
            name: "Target Work",
            slug: "target-work",
            bundleIdentifier: "com.mikekuta.appduplicator.target-work",
            targetPath: target.path,
            targetBundleIdentifier: "com.example.fixture",
            dataMode: .disabled
        )
        let info: [String: Any] = [ShortcutConfig.infoPlistKey: config.plistDictionary()]
        let bundleURL = URL(filePath: "/Applications/Target Work.app", directoryHint: .isDirectory)
        let preparer = LaunchPreparer(realHome: root)

        let prepared = try preparer.prepareShortcut(
            infoDictionary: info,
            shortcutBundleURL: bundleURL,
            baseEnvironment: ["PATH": "/usr/bin"],
            realHome: root,
            terminalLocator: LauncherActionPlannerTests.nothingInstalled
        )

        guard case .app(let launch) = prepared else {
            return XCTFail("expected app, got \(prepared)")
        }
        XCTAssertEqual(launch, try preparer.prepare(infoDictionary: info, shortcutBundleURL: bundleURL, baseEnvironment: ["PATH": "/usr/bin"]))
    }

    func testPrepareShortcutRejectsWebAppBundles() throws {
        let root = try makeTemporaryDirectory()
        var config = makeConfig(kind: .webApp)
        config.webApp = WebAppConfig(url: "https://mail.example.com")

        XCTAssertThrowsError(
            try LaunchPreparer(realHome: root).prepareShortcut(
                infoDictionary: [ShortcutConfig.infoPlistKey: config.plistDictionary()],
                shortcutBundleURL: URL(filePath: "/Applications/Mail.app", directoryHint: .isDirectory),
                baseEnvironment: [:],
                realHome: root,
                terminalLocator: LauncherActionPlannerTests.installed
            )
        ) { error in
            guard case LauncherError.configCorrupt(let detail) = error else {
                return XCTFail("expected configCorrupt, got \(error)")
            }
            XCTAssertEqual(detail, "web app bundles are run by WebShell")
        }
    }

    func testPrepareShortcutWithoutMADConfigThrowsConfigMissing() throws {
        let root = try makeTemporaryDirectory()

        XCTAssertThrowsError(
            try LaunchPreparer(realHome: root).prepareShortcut(
                infoDictionary: [:],
                shortcutBundleURL: URL(filePath: "/Applications/X.app", directoryHint: .isDirectory),
                baseEnvironment: [:],
                realHome: root,
                terminalLocator: LauncherActionPlannerTests.installed
            )
        ) { error in
            guard case LauncherError.configMissing = error else {
                return XCTFail("expected configMissing, got \(error)")
            }
        }
    }
}
```

- [ ] **Step 10: Run them and watch them fail**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.LauncherActionPlannerTests 2>&1 | grep -E "error:" | head -5`
Expected: build errors such as `cannot find 'LauncherActionPlanner' in scope` and `value of type 'LaunchPreparer' has no member 'prepareShortcut'`; no tests run.

- [ ] **Step 11: Implement `LauncherAction` and `LauncherActionPlanner`**

Create `Packages/DuplicatorCore/Sources/DuplicatorCore/LauncherAction.swift`:

```swift
import Foundation

/// What the Launcher does for a file, folder or command shortcut (spec §6). Both actions end with the Launcher exiting.
public enum LauncherAction: Equatable, Sendable {
    /// Open `items` with `openerApp`, or with each item's default handler when nil (file and folder shortcuts).
    case open(items: [URL], openerApp: URL?)
    /// Start `executable` detached with exactly these arguments (argv[1...]) and environment (command shortcuts).
    /// `workingDirectory` is nil for Terminal.app and iTerm2, whose script `cd`s itself.
    case spawn(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL?, terminal: TerminalChoice)
}

/// Turns a launcher-kind `ShortcutConfig` into a `LauncherAction`: validates paths, finds the terminal, builds the
/// environment and, for `CLIConfig.homeOverride`, materialises the shortcut's HOME tree (spec §4.3).
/// Not `Sendable`: it stores a `FileManager`, which is not `Sendable` (same as `LaunchPreparer` and `HomeTreeBuilder`).
public struct LauncherActionPlanner {
    let fileManager: FileManager
    let realHome: URL
    let terminalLocator: @Sendable (TerminalChoice) -> URL?

    /// - Parameter terminalLocator: the terminal app's `.app` URL, or nil when it is not installed. Called only for
    ///   choices that have a `bundleIdentifier`.
    public init(fileManager: FileManager = .default, realHome: URL, terminalLocator: @escaping @Sendable (TerminalChoice) -> URL?) {
        self.fileManager = fileManager
        self.realHome = realHome
        self.terminalLocator = terminalLocator
    }

    /// - Throws: `LauncherError` (`launcherConfigMissing`, `fileNotFound`, `terminalNotFound`, `dataPathNotWritable`,
    ///   and `configCorrupt` for `.app` / `.webApp`, which are not launcher kinds).
    public func plan(config: ShortcutConfig, baseEnvironment: [String: String], shortcutBundleURL: URL?) throws -> LauncherAction {
        switch config.kind {
        case .file, .folder:
            guard let file = config.file else {
                throw LauncherError.launcherConfigMissing(config.kind)
            }
            return try planOpen(file)
        case .cli:
            guard let cli = config.cli else {
                throw LauncherError.launcherConfigMissing(.cli)
            }
            return try planSpawn(cli, config: config, baseEnvironment: baseEnvironment, shortcutBundleURL: shortcutBundleURL)
        case .app, .webApp:
            throw LauncherError.configCorrupt("\(config.kind.rawValue) is not a launcher kind")
        }
    }

    private func planOpen(_ file: FileConfig) throws -> LauncherAction {
        let path = FileConfig.normalizedPath(file.path)
        guard !path.isEmpty, fileManager.fileExists(atPath: path) else {
            throw LauncherError.fileNotFound(path: path)
        }
        var openerApp: URL?
        if let rawOpener = file.openerAppPath, !rawOpener.isEmpty {
            let opener = FileConfig.normalizedPath(rawOpener)
            guard fileManager.fileExists(atPath: opener) else {
                throw LauncherError.fileNotFound(path: opener)
            }
            openerApp = URL(filePath: opener, directoryHint: .isDirectory)
        }
        return .open(items: [URL(filePath: path, directoryHint: .checkFileSystem)], openerApp: openerApp)
    }

    private func planSpawn(
        _ cli: CLIConfig,
        config: ShortcutConfig,
        baseEnvironment: [String: String],
        shortcutBundleURL: URL?
    ) throws -> LauncherAction {
        var resolved = cli
        resolved.executablePath = (cli.executablePath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.executablePath, isDirectory: &isDirectory), !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: resolved.executablePath) else {
            throw LauncherError.fileNotFound(path: resolved.executablePath)
        }

        var workingDirectory: URL?
        if let rawDirectory = cli.workingDirectory, !rawDirectory.isEmpty {
            let path = (rawDirectory as NSString).expandingTildeInPath
            var isFolder: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
                throw LauncherError.fileNotFound(path: path)
            }
            workingDirectory = URL(filePath: path, directoryHint: .isDirectory)
            resolved.workingDirectory = path
        } else {
            resolved.workingDirectory = nil
        }

        let terminalApp = cli.terminal.bundleIdentifier == nil ? nil : terminalLocator(cli.terminal)
        // Checked before the HOME tree is created, so a missing terminal leaves nothing behind.
        if cli.terminal.bundleIdentifier != nil, terminalApp == nil {
            throw LauncherError.terminalNotFound(cli.terminal)
        }

        // What the shortcut adds to the environment; `config.environment` wins over everything else.
        var additions: [String: String] = [DataSeparationPlanner.shortcutNameKey: config.name]
        if let shortcutBundleURL {
            additions[DataSeparationPlanner.shortcutBundleKey] = shortcutBundleURL.path
        }
        if cli.homeOverride {
            let home = try materializeHome(for: config)
            additions["HOME"] = home.path
            additions["CFFIXED_USER_HOME"] = home.path
        }
        additions.merge(config.environment) { _, shortcut in shortcut }

        // `.none` and Ghostty receive `additions` through the spawned process's environment below; Terminal.app and
        // iTerm2 start a fresh login shell, so the builder also writes them into the shell command.
        let argv = try TerminalCommandBuilder().argv(for: resolved, terminalApp: terminalApp, inlineEnvironment: additions)
        guard let executable = argv.first else {
            throw LauncherError.launcherConfigMissing(.cli)
        }

        var environment = baseEnvironment.filter { !$0.key.hasPrefix(DataSeparationPlanner.internalVariablePrefix) }
        environment.merge(additions) { _, added in added }

        let scriptsChangeDirectory = cli.terminal == .terminal || cli.terminal == .iterm2
        return .spawn(
            executable: URL(filePath: executable, directoryHint: .notDirectory),
            arguments: Array(argv.dropFirst()),
            environment: environment,
            workingDirectory: scriptsChangeDirectory ? nil : workingDirectory,
            terminal: cli.terminal
        )
    }

    /// Creates `ShortcutConfig.defaultDataPath(forSlug:home:)` and builds the HOME tree in it. Returns the effective
    /// HOME, which is `<path>/<NSUserName()>` when the folder already held other files (spec §4.3).
    private func materializeHome(for config: ShortcutConfig) throws -> URL {
        let path = URL(filePath: ShortcutConfig.defaultDataPath(forSlug: config.slug, home: realHome), directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
            let symlinkEntries = config.homeSymlinkEntries ?? HomeTreeBuilder.defaultSymlinkEntries
            return try HomeTreeBuilder(fileManager: fileManager, realHome: realHome, symlinkEntries: symlinkEntries).materialize(at: path)
        } catch {
            throw LauncherError.dataPathNotWritable(path.path)
        }
    }
}
```

Notes for the implementer:
- `LauncherActionPlanner` is deliberately **not** `Sendable`: it stores a `FileManager`, which is not `Sendable` on the macOS 26 SDK (the compiler rejects `stored property 'fileManager' of 'Sendable'-conforming struct 'LauncherActionPlanner' has non-Sendable type 'FileManager'`). `LaunchPreparer` and `HomeTreeBuilder` follow the same rule. Do not add `@unchecked`.
- `terminalLocator` is stored, so the initializer parameter is `@escaping @Sendable`.
- Terminal.app and iTerm2 open a fresh login shell that does not inherit `osascript`'s environment (AppleScript only asks the terminal to open a window), so `additions` (`MAD_SHORTCUT_NAME`, `MAD_SHORTCUT_BUNDLE`, the HOME override and `config.environment`, last wins) are also written into the shell command by `TerminalCommandBuilder`: `cd '<dir>' && /usr/bin/env 'K=V' … '<exe>' …`. The `.spawn` environment still carries the same values, which is harmless for `osascript` and is what `.none` and Ghostty use. Only `.none` and Ghostty get the working directory through `posix_spawn`; the AppleScript terminals get it through the script's `cd`.
- The planner checks `terminalNotFound` before it materialises the HOME tree (the builder needs the HOME path inside `additions`), so a missing terminal never creates the shortcut's folder (`testUninstalledTerminalDoesNotCreateTheHomeFolder`).
- The inline values appear in the `osascript` argument list, so the same user can see them in `ps` while the launcher runs. Command arguments already are visible there; this is the same exposure. Diagnostics and the wizard preview mask secrets before planning (Task 4).

- [ ] **Step 12: Add `PreparedShortcut` and `prepareShortcut` to `LaunchPreparer`**

`prepare(infoDictionary:shortcutBundleURL:baseEnvironment:)` itself does not change. In `Packages/DuplicatorCore/Sources/DuplicatorCore/LaunchPreparer.swift`, edit 1 replaces lines 3–14.

Old:

```swift
/// The resolved inputs for one launch.
public struct PreparedLaunch: Equatable, Sendable {
    public let config: ShortcutConfig
    public let app: InspectedApp
    public let plan: LaunchPlan

    public init(config: ShortcutConfig, app: InspectedApp, plan: LaunchPlan) {
        self.config = config
        self.app = app
        self.plan = plan
    }
}
```

New:

```swift
/// The resolved inputs for one launch.
public struct PreparedLaunch: Equatable, Sendable {
    public let config: ShortcutConfig
    public let app: InspectedApp
    public let plan: LaunchPlan

    public init(config: ShortcutConfig, app: InspectedApp, plan: LaunchPlan) {
        self.config = config
        self.app = app
        self.plan = plan
    }
}

/// What the Launcher runs for one shortcut: an app shortcut's prepared exec, or a file, folder or command action.
public enum PreparedShortcut: Sendable {
    case app(PreparedLaunch)
    case launcher(LauncherAction, ShortcutConfig)
}
```

Edit 2 replaces the last three lines of the file (lines 65–67).

Old:

```swift
        return PreparedLaunch(config: config, app: app, plan: plan)
    }
}
```

New:

```swift
        return PreparedLaunch(config: config, app: app, plan: plan)
    }

    /// Reads `MADConfig` and dispatches by kind: `.app` → `prepare(infoDictionary:shortcutBundleURL:baseEnvironment:)`
    /// unchanged; `.file` / `.folder` / `.cli` → `LauncherActionPlanner`; `.webApp` → `configCorrupt` (web app bundles
    /// run WebShell, never the Launcher).
    /// - Parameters:
    ///   - realHome: the user's real home, for a command's HOME-override tree. The Launcher passes the same URL it
    ///     gave `init(realHome:)`.
    ///   - terminalLocator: the terminal app's `.app` URL, or nil when it is not installed.
    /// - Throws: `LauncherError`.
    public func prepareShortcut(
        infoDictionary: [String: Any],
        shortcutBundleURL: URL,
        baseEnvironment: [String: String],
        realHome: URL,
        terminalLocator: @escaping @Sendable (TerminalChoice) -> URL?
    ) throws -> PreparedShortcut {
        guard let rawConfig = infoDictionary[ShortcutConfig.infoPlistKey] else {
            throw LauncherError.configMissing
        }
        guard let configDictionary = rawConfig as? [String: Any] else {
            throw LauncherError.configCorrupt("MADConfig is not a dictionary")
        }
        let config = try ShortcutConfig(plistDictionary: configDictionary)
        switch config.kind {
        case .app:
            return .app(try prepare(infoDictionary: infoDictionary, shortcutBundleURL: shortcutBundleURL, baseEnvironment: baseEnvironment))
        case .webApp:
            throw LauncherError.configCorrupt("web app bundles are run by WebShell")
        case .file, .folder, .cli:
            let planner = LauncherActionPlanner(fileManager: fileManager, realHome: realHome, terminalLocator: terminalLocator)
            let action = try planner.plan(config: config, baseEnvironment: baseEnvironment, shortcutBundleURL: shortcutBundleURL)
            return .launcher(action, config)
        }
    }
}
```

- [ ] **Step 13: Run the tests and watch them pass**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.LauncherActionPlannerTests 2>&1 | grep -E "Executed|error:" | tail -2`
Expected: `Executed 22 tests, with 0 failures`.
Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.LaunchPreparerTests 2>&1 | grep -E "Executed|error:" | tail -2`
Expected: the same count as before this task, 0 failures (`prepare` is unchanged).

- [ ] **Step 14: Run the whole Core suite, the forbidden-construct check and a full build**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests 2>&1 | grep -E "Executed|error:" | tail -1`
Expected: `Executed 222 tests, with 0 failures` (185 after Task 1 + 2 new `LauncherErrorTests` + 13 + 22).
Run: `cd ~/Developer/MacAppDuplicator && grep -nE 'try\?|@unchecked|swiftlint:disable|nonisolated\(unsafe\)' Packages/DuplicatorCore/Sources/DuplicatorCore/{FileConfig,CLIConfig,TerminalCommandBuilder,LauncherAction,LauncherError,LauncherError+ExitCode,LaunchPreparer}.swift`
Expected: no output.
Run: `cd ~/Developer/MacAppDuplicator && swift build 2>&1 | tail -1`
Expected: `Build complete!` (the Launcher still calls `prepare`, which is unchanged).

- [ ] **Step 15: Commit**

```bash
cd ~/Developer/MacAppDuplicator && git add Packages/DuplicatorCore/Sources/DuplicatorCore/LauncherAction.swift Packages/DuplicatorCore/Sources/DuplicatorCore/TerminalCommandBuilder.swift Packages/DuplicatorCore/Sources/DuplicatorCore/LaunchPreparer.swift Packages/DuplicatorCore/Sources/DuplicatorCore/LauncherError.swift Packages/DuplicatorCore/Sources/DuplicatorCore/LauncherError+ExitCode.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/TerminalCommandBuilderTests.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/LauncherActionPlannerTests.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/LauncherErrorTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Plan file, folder and command launches in Core" -m "LauncherActionPlanner turns a launcher-kind MADConfig into an open or spawn action: it validates paths, finds the terminal, quotes the argv for Terminal.app, iTerm2 or Ghostty, builds the environment and, for homeOverride, the shortcut's HOME tree. LaunchPreparer.prepareShortcut dispatches by kind and keeps the app path unchanged. LauncherError gains fileNotFound (2), terminalNotFound (5), spawnFailed (3) and launcherConfigMissing (1)." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 3: Launcher — kind dispatch, `OpenItems`, `Spawn`

**Files:**
- Create: `Launcher/Sources/Launcher/OpenItems.swift`, `Launcher/Sources/Launcher/Spawn.swift`
- Modify: `Launcher/Sources/Launcher/main.swift`
- Test: gated `Tests/Integration/CLILaunchTests.swift` (`TerminalChoice.none`, `/bin/sh -c 'env > "$MAD_FIXTURE_DUMP"'`, asserts `MAD_SHORTCUT_NAME`, HOME override path and exit log line)

**Interfaces:**
- Consumes: Task 2 `PreparedShortcut`, `LauncherAction`, `LaunchLogger`, `fail(_:logger:)`.
- Produces:
  ```swift
  @MainActor func openItems(_ items: [URL], openerApp: URL?, logger: LaunchLogger) -> Never   // NSWorkspace.shared.open / openApplication(at:configuration:) with urls; waits ≤10 s; exit(0) or fail(.fileNotFound)
  func spawnDetached(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL?) -> Result<pid_t, LauncherError>   // posix_spawn with POSIX_SPAWN_SETSID; no wait
  ```
  `main.swift`: decode `MADConfig` → `switch config.kind` → `.app` keeps today's path verbatim; `.webApp` → `fail(.configCorrupt("web app bundles run WebShell"))`; `.file/.folder` → `openItems`; `.cli` → `spawnDetached` then `logger.log("exit 0")`, `exit(0)`.

#### Group A: gated command-shortcut test

- [ ] **Step 1: Write the failing gated test**

Create `Tests/Integration/CLILaunchTests.swift`:

```swift
// Gated integration test: run a command shortcut whose executable is the Launcher binary.
//
// Prerequisites (run from the repo root):
//   swift build -c release --product Launcher
//   MAD_INTEGRATION=1 swift test --filter IntegrationTests.CLILaunchTests
//
// Without MAD_INTEGRATION=1 the test is skipped. The shortcut runs `/bin/sh -c 'env > "$MAD_FIXTURE_DUMP"'` with
// `TerminalChoice.none`, so no terminal app opens and nothing runs osascript. The Launcher exits as soon as the
// command is spawned and never checks in with LaunchServices as an app, so the test runs the bundle's executable
// directly (`Bundle.main` still resolves to the shortcut bundle) and asserts its exit status. HOME and
// CFFIXED_USER_HOME point at a temp directory, so the Launcher's log and the command's HOME tree stay out of ~/Library.

import DuplicatorCore
import Foundation
import XCTest

@MainActor
final class CLILaunchTests: XCTestCase {
    /// Repo root: three directories above `Tests/Integration/<this file>`.
    private let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var launcher: URL { root.appendingPathComponent(".build/release/Launcher") }

    private let shortcutName = "MAD CLI Smoke"

    /// What `/bin/sh` may be once it has exec'd: macOS ships `/bin/sh` as a shim that re-execs the selected shell.
    private let shellPaths: Set<String> = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash"]

    // MARK: - Helpers (same shape as WebShellLaunchTests)

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

    /// The pid from the Launcher's `spawned pid=<n>` log line, or nil before that line is written.
    private func spawnedPID(in logText: String) -> pid_t? {
        for line in logText.split(separator: "\n") {
            if let range = line.range(of: "spawned pid=") {
                return pid_t(line[range.upperBound...].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Kills the spawned shell if it is somehow still alive. The pid is only signalled while it still belongs to a
    /// shell binary, so a recycled pid is never touched.
    private func reapShell(_ pid: pid_t?) async throws {
        guard let pid else { return }
        let deadline = Date().addingTimeInterval(5)
        while shellPaths.contains(resolved(processPath(pid))) && Date() < deadline {
            if kill(pid, SIGKILL) != 0 && errno != ESRCH {
                XCTFail("kill(\(pid), SIGKILL) failed with errno \(errno)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// `KEY=VALUE` lines from `env`; a line without `=` (a multi-line value's continuation) is skipped.
    private func parseEnvironment(_ text: String) -> [String: String] {
        var environment: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            environment[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        return environment
    }

    // MARK: - Tests

    func testDetachedCommandShortcutRunsWithTheShortcutEnvironment() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAD_INTEGRATION"] == "1", "Set MAD_INTEGRATION=1")
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else {
            XCTFail("Run: swift build -c release --product Launcher")
            return
        }

        let tmp = try makeTempDirectory()
        let home = tmp.appendingPathComponent("home", isDirectory: true)
        let output = tmp.appendingPathComponent("out", isDirectory: true)
        let dump = tmp.appendingPathComponent("env.txt")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let slug = ShortcutConfig.slug(for: shortcutName)
        let config = ShortcutConfig(
            kind: .cli,
            name: shortcutName,
            slug: slug,
            bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: slug),
            targetPath: "",
            targetBundleIdentifier: "",
            launchMode: .dockShortcut,
            dataMode: .disabled,
            environment: ["MAD_FIXTURE_DUMP": dump.path],
            cli: CLIConfig(
                executablePath: "/bin/sh",
                arguments: ["-c", "env > \"$MAD_FIXTURE_DUMP\""],
                terminal: TerminalChoice.none,
                homeOverride: true
            )
        )
        let bundle = try BundleWriter().write(config: config, executable: launcher, iconFile: nil, to: output)
        try Signer().sign(bundle: bundle, identity: nil)
        let executable = try XCTUnwrap(Bundle(url: bundle)?.executableURL, "Shortcut bundle has no executable")
        let logURL = home.appendingPathComponent(
            "Library/Logs/App Duplicator/\(ShortcutConfig.fileSystemName(for: shortcutName)).log"
        )
        let expectedHome = resolved(ShortcutConfig.defaultDataPath(forSlug: slug, home: home))

        // Teardown blocks run last-in-first-out: the shell and any Launcher copy are reaped before the temp
        // directory is removed, including when the wait loop below throws.
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

        // Collect everything first; assert only after every process is gone, so a failed assertion can never leave
        // one running.
        var logText = ""
        var dumpText = ""
        let deadline = Date().addingTimeInterval(10)
        while (process.isRunning || !logText.contains("exit 0") || !dumpText.contains("MAD_SHORTCUT_NAME=")) && Date() < deadline {
            if FileManager.default.fileExists(atPath: logURL.path) {
                logText = try String(contentsOf: logURL, encoding: .utf8)
            }
            if FileManager.default.fileExists(atPath: dump.path) {
                dumpText = try String(contentsOf: dump, encoding: .utf8)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let launcherFinished = !process.isRunning
        let shellPID = spawnedPID(in: logText)

        if !launcherFinished {
            process.terminate()
        }
        try await reapShell(shellPID)
        try await reapLeftovers(runningFrom: executable)

        XCTAssertTrue(launcherFinished, "The Launcher was still running after 10 s. Log: \(logText)")
        if launcherFinished {
            XCTAssertEqual(process.terminationStatus, 0, "Launcher log: \(logText)")
        }
        XCTAssertNotNil(shellPID, "No spawned pid line. Log: \(logText)")
        XCTAssertTrue(logText.contains("kind cli"), "Launcher log: \(logText)")
        XCTAssertTrue(logText.contains("spawn /bin/sh argc=3 terminal=none"), "Launcher log: \(logText)")
        XCTAssertTrue(logText.contains("exit 0"), "Launcher log: \(logText)")
        XCTAssertFalse(logText.contains("osascript"), "Launcher log: \(logText)")

        let dumped = parseEnvironment(dumpText)
        XCTAssertEqual(dumped["MAD_SHORTCUT_NAME"], shortcutName)
        XCTAssertEqual(dumped["MAD_SHORTCUT_BUNDLE"].map(resolved), resolved(bundle))
        XCTAssertEqual(dumped["MAD_FIXTURE_DUMP"], dump.path)
        XCTAssertNil(dumped["MAD_INTEGRATION"], "MAD_* variables from the Launcher's own environment must not reach the command")
        XCTAssertEqual(dumped["HOME"].map(resolved), expectedHome)
        XCTAssertEqual(dumped["CFFIXED_USER_HOME"].map(resolved), expectedHome)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expectedHome + "/" + HomeTreeBuilder.markerFileName),
            "HOME tree not built at \(expectedHome)"
        )
        XCTAssertTrue(pids(runningFrom: executable).isEmpty, "A Launcher process was left running")
    }
}
```

The test runs only `/bin/sh -c 'env > "$MAD_FIXTURE_DUMP"'` with `TerminalChoice.none`: no terminal app opens and nothing runs `osascript`. It is gated by `MAD_INTEGRATION=1` like the other integration tests, and skipped otherwise.

- [ ] **Step 2: Build today's Launcher and watch the test fail**

Run: `cd ~/Developer/MacAppDuplicator && swift build -c release --product Launcher 2>&1 | tail -1 && MAD_INTEGRATION=1 swift test --filter IntegrationTests.CLILaunchTests 2>&1 | grep -E "error:|Executed" | head -8`
Expected: FAIL. Today's Launcher treats every bundle as an app shortcut, so the empty `targetPath` stops it with `targetNotFound` (`exit 2` in its log) and a "Shortcut could not start" alert appears. The test terminates it after 10 s and reports `The Launcher was still running after 10 s`, plus failures for `kind cli`, `spawn /bin/sh argc=3 terminal=none` and `MAD_SHORTCUT_NAME`. Dismiss the alert if it is still showing.

#### Group B: `spawnDetached`, `openItems` and the kind dispatch

- [ ] **Step 3: Implement `spawnDetached`**

Create `Launcher/Sources/Launcher/Spawn.swift`:

```swift
import Darwin
import DuplicatorCore
import Foundation

/// Starts a command shortcut's process and returns without waiting for it (spec §6). `POSIX_SPAWN_SETSID` puts the
/// child in its own session, so it outlives the Launcher (which exits right after) and is re-parented to launchd.
/// `environment` is the complete environment, passed as sorted `KEY=VALUE` strings like `execTarget`; a non-nil
/// `workingDirectory` becomes the child's current directory. Every `strdup` copy is freed before returning.
/// - Returns: the child's pid, or `LauncherError.spawnFailed` with the `posix_spawn*` error code.
func spawnDetached(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    workingDirectory: URL?
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
    code = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
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

    var pid: pid_t = 0
    code = posix_spawn(&pid, path, &fileActions, &attributes, &cArgv, &cEnvp)
    guard code == 0 else {
        return .failure(.spawnFailed(errno: code, path: path))
    }
    return .success(pid)
}
```

The Launcher does not `waitpid`: it exits right after the spawn, the child (its own session leader through `POSIX_SPAWN_SETSID`) is re-parented to launchd, and launchd reaps it.

- [ ] **Step 4: Implement `openItems`**

Create `Launcher/Sources/Launcher/OpenItems.swift`:

```swift
import AppKit
import DuplicatorCore
import os

/// Opens a file or folder shortcut's items, then exits (spec §6). With no `openerApp` each item goes to its default
/// handler through `NSWorkspace.open(_:)`, which answers synchronously. With an `openerApp` the open is asynchronous:
/// the Launcher is a plain `main.swift` with no `NSApplication` run loop, so the main thread polls a semaphore and pumps
/// `RunLoop.main` in 50 ms slices (the same wait as `launchViaSystem`) until the completion handler signals or 10 s
/// pass. On timeout the request is already with LaunchServices, so a slow cold launch of the opener is logged and
/// the Launcher still exits 0 rather than reporting the item as missing.
@MainActor
func openItems(_ items: [URL], openerApp: URL?, logger: LaunchLogger) -> Never {
    for item in items where !FileManager.default.fileExists(atPath: item.path) {
        fail(LauncherError.fileNotFound(path: item.path), logger: logger)
    }
    for item in items {
        logger.log("open \(item.path)")
    }

    guard let openerApp else {
        for item in items where !NSWorkspace.shared.open(item) {
            logger.log("open failed: no default handler accepted \(item.path)")
            fail(LauncherError.fileNotFound(path: item.path), logger: logger)
        }
        logger.log("exit 0")
        exit(0)
    }

    logger.log("opener \(openerApp.path)")
    let done = DispatchSemaphore(value: 0)
    let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
    NSWorkspace.shared.open(items, withApplicationAt: openerApp, configuration: NSWorkspace.OpenConfiguration()) { _, error in
        failure.withLock { $0 = error?.localizedDescription }
        done.signal()
    }

    // The completion handler's queue is not documented, so the main thread must not block on the semaphore.
    let deadline = Date(timeIntervalSinceNow: 10)
    var completed = false
    while !completed, Date() < deadline {
        completed = done.wait(timeout: .now()) == .success
        if !completed {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    if !completed {
        logger.log("open still pending after 10 s")
    } else if let message = failure.withLock({ $0 }) {
        logger.log("open failed: \(message)")
        fail(LauncherError.fileNotFound(path: openerApp.path), logger: logger)
    }
    logger.log("exit 0")
    exit(0)
}
```

How the completion handler is waited for: the Launcher is a plain `main.swift` with no `NSApplication` run loop, so the main thread polls a `DispatchSemaphore` with `wait(timeout: .now())` and, between polls, pumps `RunLoop.main.run(mode: .default, before: now + 0.05 s)` until the handler signals or the 10 s deadline passes. This is the wait `launchViaSystem` already uses; blocking on the semaphore instead could deadlock if AppKit delivers the handler on the main queue.

- [ ] **Step 5: Dispatch by kind in `main.swift`**

In `Launcher/Sources/Launcher/main.swift`, replace lines 11–20. Everything after them (the app path from `let config = prepared.config` to the final `fail`) stays exactly as it is.

Old:

```swift
let prepared: PreparedLaunch
do {
    prepared = try LaunchPreparer(realHome: realHome).prepare(
        infoDictionary: Bundle.main.infoDictionary ?? [:],
        shortcutBundleURL: Bundle.main.bundleURL,
        baseEnvironment: base
    )
} catch {
    fail(error, logger: logger)
}
```

New:

```swift
let shortcut: PreparedShortcut
do {
    shortcut = try LaunchPreparer(realHome: realHome).prepareShortcut(
        infoDictionary: Bundle.main.infoDictionary ?? [:],
        shortcutBundleURL: Bundle.main.bundleURL,
        baseEnvironment: base,
        realHome: realHome,
        terminalLocator: { choice in
            choice.bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        }
    )
} catch {
    fail(error, logger: logger)
}

// File, folder and command shortcuts (spec §6) open or spawn, then exit; every branch below ends in `exit` or `fail`.
// App shortcuts fall through to the unchanged Phase 1 path. Web app bundles never reach here: `prepareShortcut`
// rejects them with `configCorrupt`, because they run WebShell.
let prepared: PreparedLaunch
switch shortcut {
case .app(let launch):
    prepared = launch
case .launcher(let action, let launcherConfig):
    logger.log("kind \(launcherConfig.kind.rawValue)")
    switch action {
    case .open(let items, let openerApp):
        openItems(items, openerApp: openerApp, logger: logger)
    case .spawn(let executable, let arguments, let environment, let workingDirectory, let terminal):
        logger.log("spawn \(executable.path) argc=\(arguments.count + 1) terminal=\(terminal.rawValue)")
        logger.log(arguments: [executable.path] + arguments)
        logger.log(environment: environment)
        switch spawnDetached(executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory) {
        case .success(let pid):
            logger.log("spawned pid=\(pid)")
            logger.log("exit 0")
            exit(0)
        case .failure(let error):
            fail(error, logger: logger)
        }
    }
}
```

Every `.launcher` branch ends in `exit` or `fail` (both `Never`), so `prepared` is definitely initialised on the only path that reaches the app code. `logger.log(arguments:)` masks secrets itself (`SecretMasking.maskArguments`), so the raw argv is passed. `spawned pid=<n>` is an extra line the gated test uses to reap the command precisely.

- [ ] **Step 6: Build and watch the gated test pass**

Run: `cd ~/Developer/MacAppDuplicator && swift build 2>&1 | tail -1`
Expected: `Build complete!`
Run: `cd ~/Developer/MacAppDuplicator && swift build -c release --product Launcher 2>&1 | tail -1 && MAD_INTEGRATION=1 swift test --filter IntegrationTests.CLILaunchTests 2>&1 | grep -E "error:|Executed" | tail -2`
Expected: `Executed 1 test, with 0 failures`, no alert, no terminal window.
Run: `cd ~/Developer/MacAppDuplicator && swift test --filter IntegrationTests.CLILaunchTests 2>&1 | grep -E "skipped|Executed" | tail -2`
Expected: the test is skipped (`Set MAD_INTEGRATION=1`) and `Executed 1 test, with 0 failures`.

- [ ] **Step 7: Regression checks**

Run: `cd ~/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests 2>&1 | grep -E "Executed|error:" | tail -1`
Expected: `Executed 222 tests, with 0 failures`.
Run: `cd ~/Developer/MacAppDuplicator && MAD_INTEGRATION=1 swift test --filter IntegrationTests.LaunchIntegrationTests 2>&1 | grep -E "error:|Executed" | tail -2`
Expected: the same result as before this task, 0 failures (the app-shortcut path is unchanged).
Run: `cd ~/Developer/MacAppDuplicator && grep -nE 'try\?|@unchecked|swiftlint:disable|nonisolated\(unsafe\)' Launcher/Sources/Launcher/{OpenItems,Spawn,main}.swift Tests/Integration/CLILaunchTests.swift`
Expected: no output.

- [ ] **Step 8: Commit**

```bash
cd ~/Developer/MacAppDuplicator && git add Launcher/Sources/Launcher/OpenItems.swift Launcher/Sources/Launcher/Spawn.swift Launcher/Sources/Launcher/main.swift Tests/Integration/CLILaunchTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Run file, folder and command shortcuts from the Launcher" -m "main.swift now goes through prepareShortcut: app shortcuts keep the unchanged exec path, file and folder shortcuts open through NSWorkspace with a 10 s wait, and command shortcuts start with posix_spawn in their own session and the Launcher exits 0. A gated integration test runs a detached /bin/sh command and checks its environment and HOME tree." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Deviations from the skeleton (Tasks 1–3)

1. **`LauncherActionPlanner` is not `Sendable`.** The skeleton declares `public struct LauncherActionPlanner: Sendable` with a `fileManager:` init parameter. `FileManager` is not `Sendable` on the macOS 26 SDK, so storing it in a `Sendable` struct does not compile, and `@unchecked` is forbidden. Nothing needs the planner to cross an isolation boundary (`LaunchPreparer` and `HomeTreeBuilder` are not `Sendable` either). The `terminalLocator` parameter is also `@escaping`, because it is stored.
2. **HOME override.** `HOME` and `CFFIXED_USER_HOME` are the path `HomeTreeBuilder.materialize(at:)` returns, which is `<defaultDataPath>/<NSUserName()>` when that folder already held other files (spec §4.3). Symlinks use `config.homeSymlinkEntries ?? HomeTreeBuilder.defaultSymlinkEntries`, the same rule as `LaunchPreparer`. A failure to create the tree throws `dataPathNotWritable` (exit 4), a case the brief's error table does not list.
3. **Web app message and `main.swift` switch.** `prepareShortcut` rejects `.webApp` with `configCorrupt("web app bundles are run by WebShell")` (the brief's wording; the skeleton's `main.swift` line says "web app bundles run WebShell"). `PreparedShortcut` has only `.app` and `.launcher`, so `main.swift` switches over that instead of over `config.kind`, and the web-app rejection reaches `fail` through the `catch`.

Smaller choices a reviewer should know about:
- The iTerm2 script adds `activate` (the brief listed it for Terminal.app only), so the new window comes to the front.
- A missing working directory throws `fileNotFound(path: <dir>)`. For Terminal.app and iTerm2, `.spawn.workingDirectory` is nil because the script `cd`s. For `.none` and Ghostty, the directory is set with `posix_spawn_file_actions_addchdir_np`.
- `openItems` exits 0 when the opener has not answered after 10 s (the request is already with LaunchServices). It fails with `fileNotFound` only on a reported error.
- The gated test runs the bundle's executable with `Process`, not `NSWorkspace.openApplication`, because the Launcher exits before it would check in as an app. `Bundle.main` still resolves to the shortcut bundle, and the test can assert the exit status.
- **Terminal environment (Amendment A).** Terminal.app and iTerm2 open a fresh login shell that does not inherit `osascript`'s environment, so the planner writes `MAD_SHORTCUT_NAME`, `MAD_SHORTCUT_BUNDLE`, the HOME override and `config.environment` into the shell command as `/usr/bin/env K=V … <exe> <args>` (`TerminalCommandBuilder.argv(for:terminalApp:inlineEnvironment:)`). The command runs inside the login shell (no `exec`), so the window returns to a prompt when it ends.
- **Manual check for Task 6 (needs a real Mac, not run):** run a command shortcut in Terminal.app and in iTerm2 and confirm `env` inside the window shows `MAD_SHORTCUT_NAME`, the HOME override and the shortcut's own variables, and that iTerm2's `command` runs `cd '<dir>' && exec …` through a shell.

### Verification already done by the planner (scratchpad copy, not the repo)

A copy of the package at the repo's HEAD (`8631c10`), with only these edits applied, gave these results:
- Task 1: `FileConfigTests` 4/0, `CLIConfigTests` 5/0, `ShortcutConfigTests` 16/0.
- Task 2: `LauncherErrorTests` 4/0, `TerminalCommandBuilderTests` 13/0, `LauncherActionPlannerTests` 22/0. Whole Core suite: `Executed 222 tests, with 0 failures`. (The planner author ran 9, 20 and 216 before Amendment A; the stitching pass applied the inline-environment change and its 6 new tests and re-ran them in the scratch copy, see the stitch report.) The forbidden-construct grep found no matches.
- Task 3: `swift build` was clean, and `MAD_INTEGRATION=1 swift test --filter IntegrationTests.CLILaunchTests` gave `Executed 1 test, with 0 failures` in 0.50 s with the release Launcher.

The plan was also applied mechanically to a `git archive HEAD` export: every Old block matched exactly once, and the result is byte-for-byte the tested files. The one exception is `LauncherErrorTests.swift`, where the plan keeps `testExitCodesFollowTheErrorTable` in place and the tested copy had it third of four; the method bodies are identical. The "Expected FAIL" texts and the repo line numbers were not executed in the repo. Line numbers are from HEAD `8631c10`.

---

### Task 4: App — icons and builder for launcher kinds

**Files:**
- Modify: `App/Sources/Services/IconResolver.swift`, `App/Sources/Services/IconRenderer.swift` (only if a new helper is needed), `App/Sources/Services/ShortcutBuilder.swift`, `App/Sources/Services/TargetResolver+ResolvedPath.swift`, `App/Sources/Services/CompatBadge.swift`, `App/Sources/Services/LaunchPlanPreview.swift`
- Test: `App/Tests/Services/ShortcutBuilderLauncherTests.swift`, extend `App/Tests/Services/IconResolverTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2, `BundleWriter.write(config:executable:iconFile:to:)`, `Signer`.
- Produces:
  ```swift
  // IconResolver
  func launcherIconFile(for config: ShortcutConfig, scratchDirectory: URL) throws -> URL?   // .copied → NSWorkspace.shared.icon(forFile: path or executable) → IconRenderer.writeICNS(from:to:) "item-icon.icns"; .custom/.generated as today
  // ShortcutBuilder
  enum BuilderError { ... case launcherConfigMissing(ShortcutKind), itemMissing(String) }
  private func writeLauncherKind(config:in:existingIcon:) throws -> URL   // enforces Phase 5 invariants, writes with launcherBinary, signs
  // TargetResolver+ResolvedPath: guard config.kind == .app else { return nil }
  // CompatBadge.isShown(for:): kind == .app
  // LaunchPlanPreview.make: for .cli builds from LauncherActionPlanner (argv masked, env additions); for .file/.folder a preview with executablePath = item path and empty arguments; .webApp unchanged
  ```

Line numbers below are at HEAD `8631c10` before this task's edits; when a step inserts lines, later refs in the same file name the anchor text too. Tasks 1–2 must be merged first (`FileConfig`, `CLIConfig`, `TerminalChoice`, `ShortcutConfig.file`/`.cli`, `LauncherActionPlanner`, `LauncherError.launcherConfigMissing`). `IconRenderer.swift` needs no change: `IconRenderer.writeICNS(from image: CGImage, to url: URL) throws` (lines 121–143) already takes a `CGImage`.

- [ ] **Step 1: Failing tests for launcher icons.** Append a new class to the end of `App/Tests/Services/IconResolverTests.swift` (after the closing `}` of `IconResolverTests` on line 123). It has its own temp folder so it does not depend on the existing class's fixtures:

```swift

/// Phase 5: icons for file, folder and command shortcuts. Every fixture lives in a per-test temp folder.
final class IconResolverLauncherTests: XCTestCase {
    private var dir: URL!
    private var scratch: URL!

    override func setUpWithError() throws {
        dir = try makeAppTemporaryDirectory()
        scratch = dir.appending(path: "scratch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    private func launcherConfig(
        kind: ShortcutKind, file: FileConfig? = nil, cli: CLIConfig? = nil, iconMode: IconMode = .copied, customIconPath: String? = nil
    ) -> ShortcutConfig {
        ShortcutConfig(
            kind: kind, name: "Launcher Icon", slug: "launcher-icon", bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: "launcher-icon"),
            targetPath: "", targetBundleIdentifier: "", launchMode: .dockShortcut, dataMode: .disabled, dataPath: nil,
            iconMode: iconMode, customIconPath: customIconPath, file: file, cli: cli
        )
    }

    private func isICNS(_ url: URL) throws -> Bool {
        String(decoding: try Data(contentsOf: url).prefix(4), as: UTF8.self) == "icns"
    }

    func testCopiedIconOfAFileIsRenderedToItemIcon() throws {
        let item = dir.appending(path: "notes.txt")
        try Data("notes".utf8).write(to: item)
        let url = try XCTUnwrap(IconResolver.launcherIconFile(for: launcherConfig(kind: .file, file: FileConfig(path: item.path)), scratchDirectory: scratch))
        XCTAssertEqual(url, scratch.appending(path: "item-icon.icns"))
        XCTAssertTrue(try isICNS(url))
    }

    func testCopiedIconOfAFolderAndOfAnExecutable() throws {
        let folder = dir.appending(path: "Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folderIcon = try XCTUnwrap(IconResolver.launcherIconFile(for: launcherConfig(kind: .folder, file: FileConfig(path: folder.path)), scratchDirectory: scratch))
        XCTAssertTrue(try isICNS(folderIcon))
        try FileManager.default.removeItem(at: folderIcon)

        let tool = dir.appending(path: "tool")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: tool)
        let toolIcon = try XCTUnwrap(IconResolver.launcherIconFile(for: launcherConfig(kind: .cli, cli: CLIConfig(executablePath: tool.path)), scratchDirectory: scratch))
        XCTAssertEqual(toolIcon.lastPathComponent, "item-icon.icns")
        XCTAssertTrue(try isICNS(toolIcon))
    }

    func testGeneratedAndCustomModesWorkAsForAppShortcuts() throws {
        let generated = try XCTUnwrap(IconResolver.launcherIconFile(for: launcherConfig(kind: .folder, file: FileConfig(path: dir.path), iconMode: .generated), scratchDirectory: scratch))
        XCTAssertEqual(generated.lastPathComponent, "generated-icon.icns")
        XCTAssertTrue(try isICNS(generated))

        let missingCustom = dir.appending(path: "missing.png").path
        let config = launcherConfig(kind: .file, file: FileConfig(path: dir.path), iconMode: .custom, customIconPath: missingCustom)
        XCTAssertThrowsError(try IconResolver.launcherIconFile(for: config, scratchDirectory: scratch)) { error in
            guard case IconResolver.IconError.customFileMissing(let path) = error, path == missingCustom else { return XCTFail("\(error)") }
        }
    }

    func testCopiedIconWithoutSettingsIsNil() throws {
        XCTAssertNil(try IconResolver.launcherIconFile(for: launcherConfig(kind: .cli), scratchDirectory: scratch))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }
}
```

- [ ] **Step 2: Run, expect failure.** `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/IconResolverLauncherTests 2>&1 | tail -4` — build error `type 'IconResolver' has no member 'launcherIconFile'` and `** TEST FAILED **`.

- [ ] **Step 3: Implement `IconResolver.launcherIconFile`.** In `App/Sources/Services/IconResolver.swift`:
  1. Add `import AppKit` as the first import (above `import DuplicatorCore`, lines 1–3 become `AppKit`, `DuplicatorCore`, `Foundation`, `os`). AppKit is needed for `NSWorkspace` and `NSImage`.
  2. Replace lines 21–45 (the doc comment and `iconFile(for:app:scratchDirectory:)`) with the block below. `.custom` and `.generated` move into the shared `madeIconFile` so app and launcher shortcuts use one code path; `iconFile`'s behaviour is unchanged.

```swift
    /// - Returns: the target's own icon (`.copied`), a converted copy of `customIconPath` in `scratchDirectory` (`.custom`),
    ///   a generated tile in `scratchDirectory` (`.generated`), or nil when the target has no icon to copy.
    static func iconFile(for config: ShortcutConfig, app: InspectedApp, scratchDirectory: URL) throws -> URL? {
        switch config.iconMode {
        case .copied:
            return app.iconFileURL
        case .custom, .generated:
            return try madeIconFile(for: config, scratchDirectory: scratchDirectory)
        }
    }

    /// Phase 5: the icon of a file, folder or command shortcut. `.copied` renders the Finder icon of the item (file and
    /// folder) or of the executable (command) into `item-icon.icns`; `.custom` and `.generated` work as for app shortcuts.
    /// - Returns: nil for `.copied` when the config has no `file`/`cli` settings (`ShortcutBuilder` refuses those first).
    static func launcherIconFile(for config: ShortcutConfig, scratchDirectory: URL) throws -> URL? {
        switch config.iconMode {
        case .custom, .generated:
            return try madeIconFile(for: config, scratchDirectory: scratchDirectory)
        case .copied:
            guard let path = launcherItemPath(of: config) else { return nil }
            let image = NSWorkspace.shared.icon(forFile: path)
            var proposed = CGRect(origin: .zero, size: NSSize(width: 1024, height: 1024))
            guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
                throw IconError.renderFailed("No icon image for \(path)")
            }
            // Fixed scratch name, as for the other modes: the scratch directory is already per build.
            let out = scratchDirectory.appending(path: "item-icon.icns")
            do { try IconRenderer.writeICNS(from: cgImage, to: out) } catch {
                throw IconError.renderFailed(error.localizedDescription)
            }
            return out
        }
    }

    /// The path whose Finder icon a `.copied` launcher icon shows: the item for a file or folder, the executable for a command.
    static func launcherItemPath(of config: ShortcutConfig) -> String? {
        switch config.kind {
        case .file, .folder: config.file?.path
        case .cli: config.cli?.executablePath
        case .app, .webApp: nil
        }
    }

    /// `.custom` (a converted copy of `customIconPath`) and `.generated` (a letter tile for the name), shared by app and
    /// launcher shortcuts. Fixed scratch names: the scratch directory is already per build, and a slug from a hand-edited
    /// config (for example one containing "../") must never steer where the file is written.
    private static func madeIconFile(for config: ShortcutConfig, scratchDirectory: URL) throws -> URL? {
        switch config.iconMode {
        case .copied:
            return nil
        case .custom:
            guard let path = config.customIconPath, FileManager.default.fileExists(atPath: path) else {
                throw IconError.customFileMissing(config.customIconPath ?? "")
            }
            let out = scratchDirectory.appending(path: "custom-icon.icns")
            do { try IconRenderer.writeICNS(fromImageFile: URL(fileURLWithPath: path), to: out) } catch {
                throw IconError.renderFailed(error.localizedDescription)
            }
            return out
        case .generated:
            let out = scratchDirectory.appending(path: "generated-icon.icns")
            do { try IconRenderer.writeICNS(generatedFor: config.name, to: out) } catch {
                throw IconError.renderFailed(error.localizedDescription)
            }
            return out
        }
    }
```

- [ ] **Step 4: Run, expect pass.** `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/IconResolverLauncherTests 2>&1 | tail -4` — `Test Suite 'IconResolverLauncherTests' passed`, `** TEST SUCCEEDED **`. Then `Tools/test-app.sh -only-testing:MacAppDuplicatorTests/IconResolverTests 2>&1 | tail -4` — the existing app-shortcut icon tests still pass (`** TEST SUCCEEDED **`).

- [ ] **Step 5: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add App/Sources/Services/IconResolver.swift App/Tests/Services/IconResolverTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Icons for file, folder and command shortcuts

IconResolver.launcherIconFile renders the Finder icon of the item or the
executable into item-icon.icns; custom and generated icons share one code
path with app shortcuts.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 6: Failing tests for the builder and the launch preview.** Create `App/Tests/Services/ShortcutBuilderLauncherTests.swift` (the `project.yml` `Tests` glob picks it up; `Tools/test-app.sh` regenerates the project with xcodegen). The fake Launcher is a copy of `/bin/echo`, as in `ShortcutBuilderTests`; nothing is launched, no terminal is located for real and nothing runs `osascript` (the planner only builds argv).

```swift
import DuplicatorCore
import XCTest
@testable import MacAppDuplicator

/// Phase 5: file, folder and command shortcuts are written with the Launcher binary, signed, and keep their invariants.
final class ShortcutBuilderLauncherTests: XCTestCase {
    private var dir: URL!
    private var out: URL!
    private var builder: ShortcutBuilder!

    override func setUpWithError() throws {
        dir = try makeAppTemporaryDirectory()
        out = dir.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let launcher = dir.appending(path: "Launcher")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: launcher)
        let webShell = dir.appending(path: "WebShell")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: webShell)
        builder = ShortcutBuilder(launcherBinary: launcher, webShellBinary: webShell, signingIdentity: nil)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    /// A config carrying stale app-shortcut fields that the builder must clear.
    private func dirtyConfig(kind: ShortcutKind, name: String = "Launcher Work", file: FileConfig? = nil, cli: CLIConfig? = nil) -> ShortcutConfig {
        let slug = ShortcutConfig.slug(for: name)
        return ShortcutConfig(
            kind: kind, name: name, slug: slug, bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: slug),
            targetPath: dir.appending(path: "Stale.app").path, targetBundleIdentifier: "com.example.stale",
            launchMode: .systemLaunch, dataMode: .auto, dataPath: dir.appending(path: "Data").path,
            iconMode: .generated, file: file, cli: cli
        )
    }

    private func makeTool() throws -> URL {
        let tool = dir.appending(path: "tool")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: tool)
        return tool
    }

    private func makeItem() throws -> URL {
        let item = dir.appending(path: "notes.txt")
        try Data("notes".utf8).write(to: item)
        return item
    }

    private func assertValidSignature(_ bundle: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", bundle.path]
        verify.standardError = Pipe()
        try verify.run()
        verify.waitUntilExit()
        XCTAssertEqual(verify.terminationStatus, 0, "codesign --verify failed for \(bundle.lastPathComponent)", file: file, line: line)
    }

    private func assertLauncherInvariants(_ config: ShortcutConfig, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(config.targetPath, "", file: file, line: line)
        XCTAssertEqual(config.targetBundleIdentifier, "", file: file, line: line)
        XCTAssertEqual(config.launchMode, .dockShortcut, file: file, line: line)
        XCTAssertEqual(config.dataMode, .disabled, file: file, line: line)
        XCTAssertNil(config.dataPath, file: file, line: line)
        XCTAssertNil(config.webApp, file: file, line: line)
        XCTAssertEqual(config.engineVersion, ShortcutConfig.currentEngineVersion, file: file, line: line)
    }

    func testCreateFileShortcutClearsAppFieldsAndSigns() throws {
        let item = try makeItem()
        var config = dirtyConfig(kind: .file, file: FileConfig(path: item.path), cli: CLIConfig(executablePath: "/bin/echo"))
        config.iconMode = .copied
        let bundle = try builder.create(config: config, in: out)
        let saved = try LibraryScanner.record(forBundleAt: bundle).config
        XCTAssertEqual(saved.kind, .file)
        XCTAssertEqual(saved.file, FileConfig(path: item.path))
        XCTAssertNil(saved.cli)
        assertLauncherInvariants(saved)
        try assertValidSignature(bundle)
    }

    func testCreateFolderAndCommandShortcuts() throws {
        let folder = dir.appending(path: "Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folderBundle = try builder.create(config: dirtyConfig(kind: .folder, name: "Projects", file: FileConfig(path: folder.path)), in: out)
        let folderConfig = try LibraryScanner.record(forBundleAt: folderBundle).config
        XCTAssertEqual(folderConfig.kind, .folder)
        assertLauncherInvariants(folderConfig)
        try assertValidSignature(folderBundle)

        let tool = try makeTool()
        let cli = CLIConfig(executablePath: tool.path, arguments: ["hello world", "it's"], workingDirectory: "~/", terminal: .none, homeOverride: true)
        let cliBundle = try builder.create(config: dirtyConfig(kind: .cli, name: "Echo", file: FileConfig(path: folder.path), cli: cli), in: out)
        let cliConfig = try LibraryScanner.record(forBundleAt: cliBundle).config
        XCTAssertEqual(cliConfig.cli, cli)
        XCTAssertNil(cliConfig.file)
        assertLauncherInvariants(cliConfig)
        try assertValidSignature(cliBundle)
    }

    func testMissingSettingsOrItemThrowsAndWritesNothing() throws {
        XCTAssertThrowsError(try builder.create(config: dirtyConfig(kind: .cli), in: out)) { error in
            guard case ShortcutBuilder.BuilderError.launcherConfigMissing(let kind) = error, kind == .cli else { return XCTFail("\(error)") }
        }
        let missing = dir.appending(path: "missing.txt").path
        XCTAssertThrowsError(try builder.create(config: dirtyConfig(kind: .file, file: FileConfig(path: missing)), in: out)) { error in
            guard case ShortcutBuilder.BuilderError.itemMissing(let path) = error, path == missing else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    func testRegenerateRewritesArgumentsInPlace() throws {
        let tool = try makeTool()
        let cli = CLIConfig(executablePath: tool.path, arguments: ["one"], terminal: .none)
        let bundle = try builder.create(config: dirtyConfig(kind: .cli, name: "Echo", cli: cli), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        var changed = record.config
        changed.cli?.arguments = ["two", "three"]
        let rewritten = try builder.regenerate(record: record, config: changed)
        XCTAssertEqual(rewritten.standardizedFileURL.path, bundle.standardizedFileURL.path)
        let saved = try LibraryScanner.record(forBundleAt: rewritten).config
        XCTAssertEqual(saved.cli?.arguments, ["two", "three"])
        XCTAssertEqual(saved.cli?.executablePath, tool.path)
        try assertValidSignature(rewritten)
    }

    func testDuplicateGetsANewSlugAndKeepsTheCommand() throws {
        let tool = try makeTool()
        let cli = CLIConfig(executablePath: tool.path, arguments: ["one"], terminal: .none, homeOverride: true)
        let bundle = try builder.create(config: dirtyConfig(kind: .cli, name: "Echo", cli: cli), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        let copy = try builder.duplicate(record: record, newName: "Echo Copy", in: out, takenSlugs: [record.config.slug])
        let copied = try LibraryScanner.record(forBundleAt: copy).config
        XCTAssertNotEqual(copied.slug, record.config.slug)
        XCTAssertEqual(copied.bundleIdentifier, ShortcutConfig.bundleIdentifier(forSlug: copied.slug))
        XCTAssertEqual(copied.cli, cli)
        assertLauncherInvariants(copied)
        try assertValidSignature(copy)
    }

    func testExportCopyWritesALauncherBundle() throws {
        let item = try makeItem()
        let bundle = try builder.create(config: dirtyConfig(kind: .file, file: FileConfig(path: item.path)), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        let exportFolder = dir.appending(path: "export", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        let outcome = try builder.exportCopy(record: record, to: exportFolder.appending(path: "Notes.app"))
        XCTAssertNil(outcome.trashedExisting)
        let exported = try LibraryScanner.record(forBundleAt: outcome.exportedURL).config
        XCTAssertEqual(exported.kind, .file)
        XCTAssertEqual(exported.file, FileConfig(path: item.path))
        try assertValidSignature(outcome.exportedURL)
    }

    func testLauncherKindsHaveNoResolvedTargetAndNoCompatBadge() {
        for kind in [ShortcutKind.file, .folder, .cli] {
            XCTAssertNil(TargetResolver().resolvedPath(for: dirtyConfig(kind: kind)), "\(kind)")
            XCTAssertFalse(CompatBadge.isShown(for: kind), "\(kind)")
        }
        XCTAssertTrue(CompatBadge.isShown(for: .app))
        XCTAssertFalse(CompatBadge.isShown(for: .webApp))
    }
}

/// Phase 5: the launch preview for file, folder and command shortcuts. The terminal locator is always a test closure.
final class LaunchPlanPreviewLauncherTests: XCTestCase {
    private var dir: URL!
    private static let noTerminal: @Sendable (TerminalChoice) -> URL? = { _ in nil }

    override func setUpWithError() throws {
        dir = try makeAppTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    private func config(kind: ShortcutKind, file: FileConfig? = nil, cli: CLIConfig? = nil, environment: [String: String] = [:]) -> ShortcutConfig {
        ShortcutConfig(
            kind: kind, name: "Preview Work", slug: "preview-work", bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: "preview-work"),
            targetPath: "", targetBundleIdentifier: "", launchMode: .dockShortcut, dataMode: .disabled, dataPath: nil,
            environment: environment, file: file, cli: cli
        )
    }

    private func makeTool() throws -> URL {
        let tool = dir.appending(path: "tool")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: tool)
        return tool
    }

    func testFilePreviewShowsTheItemAndWarnsWhenItIsMissing() throws {
        let item = dir.appending(path: "notes.txt")
        try Data("notes".utf8).write(to: item)
        let present = try LaunchPlanPreview.make(config: config(kind: .file, file: FileConfig(path: item.path)), bundleURL: nil)
        XCTAssertEqual(present.executablePath, item.path)
        XCTAssertEqual(present.arguments, [])
        XCTAssertEqual(present.warnings, [])
        XCTAssertEqual(present.launchMode, .dockShortcut)

        let missingPath = dir.appending(path: "gone").path
        let missing = try LaunchPlanPreview.make(config: config(kind: .folder, file: FileConfig(path: missingPath)), bundleURL: nil)
        XCTAssertEqual(missing.executablePath, missingPath)
        XCTAssertEqual(missing.warnings, ["Item not found"])
    }

    func testCommandPreviewWithoutTerminalMasksSecrets() throws {
        let tool = try makeTool()
        let cli = CLIConfig(executablePath: tool.path, arguments: ["--token", "hunter2", "two words"], terminal: .none)
        let preview = try LaunchPlanPreview.make(
            config: config(kind: .cli, cli: cli, environment: ["API_TOKEN": "hunter2"]), bundleURL: nil, terminalLocator: Self.noTerminal, home: dir
        )
        XCTAssertEqual(preview.executablePath, tool.path)
        XCTAssertEqual(preview.arguments, ["--token", SecretMasking.maskedValue, "two words"])
        XCTAssertEqual(preview.environmentAdditions[DataSeparationPlanner.shortcutNameKey], "Preview Work")
        XCTAssertEqual(preview.environmentAdditions["API_TOKEN"], SecretMasking.maskedValue)
        XCTAssertFalse(preview.maskedEnvironment.values.contains("hunter2"))
        XCTAssertEqual(preview.warnings, [])
    }

    func testCommandPreviewInTerminalBuildsTheScriptWithoutTheSecret() throws {
        let tool = try makeTool()
        let fakeTerminal = dir.appending(path: "Terminal.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fakeTerminal, withIntermediateDirectories: true)
        let cli = CLIConfig(executablePath: tool.path, arguments: ["--password", "hunter2"], terminal: .terminal)
        let preview = try LaunchPlanPreview.make(config: config(kind: .cli, cli: cli), bundleURL: nil, terminalLocator: { _ in fakeTerminal }, home: dir)
        XCTAssertEqual(preview.executablePath, "/usr/bin/osascript")
        XCTAssertEqual(preview.arguments.first, "-e")
        XCTAssertTrue(preview.arguments.joined(separator: " ").contains("do script"))
        XCTAssertFalse(preview.arguments.joined(separator: " ").contains("hunter2"))
    }

    func testTerminalPreviewScriptCarriesTheMaskedEnvironmentAndOwnHome() throws {
        let tool = try makeTool()
        let fakeTerminal = dir.appending(path: "iTerm.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fakeTerminal, withIntermediateDirectories: true)
        let home = dir.appending(path: "home", directoryHint: .isDirectory)
        let cli = CLIConfig(executablePath: tool.path, terminal: .iterm2, homeOverride: true)
        let preview = try LaunchPlanPreview.make(
            config: config(kind: .cli, cli: cli, environment: ["API_TOKEN": "hunter2", "MODE": "fast"]),
            bundleURL: nil, terminalLocator: { _ in fakeTerminal }, home: home
        )
        let script = preview.arguments.joined(separator: " ")
        let ownHome = ShortcutConfig.defaultDataPath(forSlug: "preview-work", home: home)
        XCTAssertTrue(script.contains("/usr/bin/env"), script)
        XCTAssertTrue(script.contains("MODE=fast"), script)
        XCTAssertTrue(script.contains("HOME=\(ownHome)"), script)
        XCTAssertFalse(script.contains("hunter2"), script)
        XCTAssertEqual(preview.environmentAdditions["API_TOKEN"], SecretMasking.maskedValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownHome))
    }

    func testHomeOverridePreviewReportsTheFolderWithoutCreatingIt() throws {
        let tool = try makeTool()
        let home = dir.appending(path: "home", directoryHint: .isDirectory)
        let cli = CLIConfig(executablePath: tool.path, terminal: .none, homeOverride: true)
        let preview = try LaunchPlanPreview.make(config: config(kind: .cli, cli: cli), bundleURL: nil, terminalLocator: Self.noTerminal, home: home)
        let ownHome = ShortcutConfig.defaultDataPath(forSlug: "preview-work", home: home)
        XCTAssertEqual(preview.environmentAdditions["HOME"], ownHome)
        XCTAssertEqual(preview.environmentAdditions["CFFIXED_USER_HOME"], ownHome)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownHome))
    }

    func testMissingSettingsThrow() {
        XCTAssertThrowsError(try LaunchPlanPreview.make(config: config(kind: .cli), bundleURL: nil, terminalLocator: Self.noTerminal, home: dir)) { error in
            guard case LauncherError.launcherConfigMissing(.cli) = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try LaunchPlanPreview.make(config: config(kind: .file), bundleURL: nil)) { error in
            guard case LauncherError.launcherConfigMissing(.file) = error else { return XCTFail("\(error)") }
        }
    }
}
```

- [ ] **Step 7: Run, expect failure.** `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/ShortcutBuilderLauncherTests -only-testing:MacAppDuplicatorTests/LaunchPlanPreviewLauncherTests 2>&1 | tail -4` — build errors `type 'ShortcutBuilder.BuilderError' has no member 'launcherConfigMissing'` and `extra arguments at positions #3, #4 in call` (the preview's `terminalLocator:`/`home:`), `** TEST FAILED **`.

- [ ] **Step 8: Implement the builder.** In `App/Sources/Services/ShortcutBuilder.swift`:
  1. After `case webAppConfigMissing` (line 18) add:

```swift
        /// Phase 5: a `.file`, `.folder` or `.cli` config without its `file`/`cli` settings; carries the kind.
        case launcherConfigMissing(ShortcutKind)
        /// Phase 5: the file, folder or command executable a launcher shortcut opens does not exist; carries the path.
        case itemMissing(String)
```

  2. In `errorDescription`, after `case .webAppConfigMissing: "The shortcut has no web app settings."` (line 29) add:

```swift
            case .launcherConfigMissing: "The shortcut has no file, folder or command settings."
            case .itemMissing(let path): "Nothing exists at \(path)."
```

  3. In `write(config:in:webIconData:existingIcon:)` replace the three-line `if config.kind == .webApp { … }` block (lines 258–260) with:

```swift
        switch config.kind {
        case .webApp:
            return try writeWebApp(config: config, in: directory, webIconData: webIconData, existingIcon: existingIcon)
        case .file, .folder, .cli:
            return try writeLauncherKind(config: config, in: directory, existingIcon: existingIcon)
        case .app:
            break
        }
```

  4. After `writeWebApp` (its closing `}` is line 293, just above `private func makeScratch()`) add:

```swift

    /// Phase 5: a file, folder or command shortcut. The Launcher binary is the executable (it reads `kind` from the config
    /// and opens the item or spawns the command). There is no target app, no data-folder resolution and no launch-mode
    /// choice, and only the sub-config matching the kind is kept; the wizard and the editor enforce the same invariants.
    /// `duplicate`, `regenerate` and `exportCopy` need no launcher-specific code: they go through `write` or copy the bundle.
    private func writeLauncherKind(config: ShortcutConfig, in directory: URL, existingIcon: URL?) throws -> URL {
        var config = config
        let itemPath: String
        switch config.kind {
        case .file, .folder:
            guard let file = config.file else { throw BuilderError.launcherConfigMissing(config.kind) }
            itemPath = file.path
            config.cli = nil
        case .cli:
            guard let cli = config.cli else { throw BuilderError.launcherConfigMissing(config.kind) }
            itemPath = cli.executablePath
            config.file = nil
        case .app, .webApp:
            throw BuilderError.launcherConfigMissing(config.kind)
        }
        guard fileManager.fileExists(atPath: itemPath) else { throw BuilderError.itemMissing(itemPath) }
        config.webApp = nil
        config.targetPath = ""
        config.targetBundleIdentifier = ""
        config.launchMode = .dockShortcut
        config.dataMode = .disabled
        config.dataPath = nil
        config.engineVersion = ShortcutConfig.currentEngineVersion
        let scratch = try makeScratch()
        defer { removeScratch(scratch) }
        var icon = try IconResolver.launcherIconFile(for: config, scratchDirectory: scratch)
        if icon == nil, let existingIcon {
            // Copied into scratch first: a regenerate rewrites the bundle that holds `existingIcon`.
            let kept = scratch.appending(path: "existing-icon.icns")
            try fileManager.copyItem(at: existingIcon, to: kept)
            icon = kept
        }
        let bundle = try BundleWriter(fileManager: fileManager).write(config: config, executable: launcherBinary, iconFile: icon, to: directory)
        try Signer().sign(bundle: bundle, identity: signingIdentity)
        return bundle
    }
```

- [ ] **Step 9: Implement the target and badge guards.**
  1. `App/Sources/Services/TargetResolver+ResolvedPath.swift`: replace lines 20–22 (the two-line comment and `guard config.kind != .webApp else { return nil }`) with:

```swift
        // Only application shortcuts have a target app. Web apps (Phase 4) and file, folder and command shortcuts (Phase 5)
        // store empty targetPath and targetBundleIdentifier: export, delete and the data-path guard must never go looking
        // for one, whatever a hand-edited plist left in the bundle id.
        guard config.kind == .app else { return nil }
```

  2. `App/Sources/Services/CompatBadge.swift`: replace lines 15–17 with:

```swift
    /// Whether a shortcut of `kind` shows a compatibility badge. Badges rate how a target app is launched, so only
    /// application shortcuts show one: a web app (skeleton decision 14) and file, folder and command shortcuts (Phase 5) have no target app.
    static func isShown(for kind: ShortcutKind) -> Bool { kind == .app }
```

- [ ] **Step 10: Implement the launch preview.** Replace the whole of `App/Sources/Services/LaunchPlanPreview.swift` (32 lines) with the file below. Existing callers (`DiagnosticsView.swift:64`, `WizardModel.swift:259`, `ShortcutBuilderEndToEndTests.swift:65`, `LaunchPlanPreviewTests`) keep compiling through the defaulted parameters, and the `.app` body is unchanged. The `.cli` preview masks the arguments and the shortcut's environment values before planning, because Terminal.app and iTerm2 fold the whole command line and (Amendment A) the whole shortcut environment into one `osascript -e` script that masking cannot reach afterwards. It plans with `homeOverride` off so that the preview never creates or populates the shortcut's own HOME (the planner does both); instead it hands the own-HOME path to the planner as part of the (masked) environment, so the preview script and the reported environment show it exactly as the planner would. A shortcut's own `HOME` variable still wins, as it does at launch.

```swift
import AppKit
import DuplicatorCore
import Foundation

/// What the launcher would exec for a config, with secrets masked, for Diagnostics and the wizard review step (spec §7).
/// Phase 5: a file or folder shortcut previews the item it opens; a command shortcut previews the argv the Launcher plans.
struct LaunchPlanPreview: Sendable {
    var executablePath: String
    /// argv after argv[0] (planner arguments, then the shortcut's), secret values masked per `SecretMasking.maskArguments`.
    var arguments: [String]
    /// Full target environment, masked per `SecretMasking`.
    var maskedEnvironment: [String: String]
    /// Only the variables the launcher adds or changes relative to this process's environment, masked.
    var environmentAdditions: [String: String]
    var warnings: [String]
    var launchMode: LaunchMode
    /// The family AppInspector detected for the target, the one the planner used (`.native` for launcher kinds).
    var family: AppFamily

    /// Resolves a terminal choice to its installed app the way the Launcher does, through its bundle identifier.
    static let installedTerminal: @Sendable (TerminalChoice) -> URL? = { choice in
        choice.bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// - Parameters:
    ///   - terminalLocator: finds the terminal app for a `.cli` preview; tests pass a closure that never touches the system.
    ///   - home: the real home folder a command's own HOME lives under; the preview never creates that folder.
    static func make(
        config: ShortcutConfig,
        bundleURL: URL?,
        terminalLocator: @escaping @Sendable (TerminalChoice) -> URL? = installedTerminal,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> LaunchPlanPreview {
        switch config.kind {
        case .file, .folder:
            return try makeItem(config: config)
        case .cli:
            return try makeCommand(config: config, bundleURL: bundleURL, terminalLocator: terminalLocator, home: home)
        case .app, .webApp:
            break
        }
        let app = try AppInspector().inspect(appAt: URL(fileURLWithPath: config.targetPath))
        let base = ProcessInfo.processInfo.environment
        let plan = DataSeparationPlanner().plan(app: app, config: config, baseEnvironment: base, shortcutBundleURL: bundleURL)
        return LaunchPlanPreview(
            executablePath: plan.executableURL.path,
            arguments: SecretMasking.maskArguments(plan.arguments),
            maskedEnvironment: SecretMasking.mask(plan.environment),
            environmentAdditions: SecretMasking.mask(plan.environmentAdditions(relativeTo: base)),
            warnings: plan.warnings,
            launchMode: plan.launchMode,
            family: app.family
        )
    }

    /// A file or folder shortcut opens its item: the preview shows the item as the "executable", with no arguments.
    private static func makeItem(config: ShortcutConfig) throws -> LaunchPlanPreview {
        guard let file = config.file else { throw LauncherError.launcherConfigMissing(config.kind) }
        return LaunchPlanPreview(
            executablePath: file.path,
            arguments: [],
            maskedEnvironment: [:],
            environmentAdditions: [:],
            warnings: FileManager.default.fileExists(atPath: file.path) ? [] : ["Item not found"],
            launchMode: .dockShortcut,
            family: .native
        )
    }

    /// A command shortcut previews the `.spawn` the Launcher plans: `/usr/bin/osascript -e <script>` for Terminal and
    /// iTerm2, Ghostty's own binary, or the executable itself for "No terminal".
    private static func makeCommand(
        config: ShortcutConfig, bundleURL: URL?, terminalLocator: @escaping @Sendable (TerminalChoice) -> URL?, home: URL
    ) throws -> LaunchPlanPreview {
        guard let cli = config.cli else { throw LauncherError.launcherConfigMissing(config.kind) }
        var planned = config
        planned.cli?.arguments = SecretMasking.maskArguments(cli.arguments)
        planned.cli?.homeOverride = false
        // Masked before planning: Terminal.app and iTerm2 write the environment into the osascript script.
        var plannedEnvironment = SecretMasking.mask(config.environment)
        if cli.homeOverride {
            // Same keys and value the planner would set; the shortcut's own environment still wins, as it does at launch.
            let ownHome = ShortcutConfig.defaultDataPath(forSlug: config.slug, home: home)
            for key in ["HOME", "CFFIXED_USER_HOME"] where plannedEnvironment[key] == nil {
                plannedEnvironment[key] = ownHome
            }
        }
        planned.environment = plannedEnvironment
        let base = ProcessInfo.processInfo.environment
        let action = try LauncherActionPlanner(realHome: home, terminalLocator: terminalLocator)
            .plan(config: planned, baseEnvironment: base, shortcutBundleURL: bundleURL)
        guard case .spawn(let executable, let arguments, let environment, _, _) = action else {
            throw LauncherError.launcherConfigMissing(config.kind)
        }
        let additions = environment.filter { base[$0.key] != $0.value }
        return LaunchPlanPreview(
            executablePath: executable.path,
            arguments: SecretMasking.maskArguments(arguments),
            maskedEnvironment: SecretMasking.mask(environment),
            environmentAdditions: SecretMasking.mask(additions),
            warnings: [],
            launchMode: .dockShortcut,
            family: .native
        )
    }
}
```

- [ ] **Step 11: Run, expect pass.** `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/ShortcutBuilderLauncherTests -only-testing:MacAppDuplicatorTests/LaunchPlanPreviewLauncherTests 2>&1 | tail -4` — both suites pass, `** TEST SUCCEEDED **`. Then the full app suite: `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh 2>&1 | tail -4` — `** TEST SUCCEEDED **` (the app-shortcut and web app builder, preview and badge tests are unchanged).

- [ ] **Step 12: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add App/Sources/Services/ShortcutBuilder.swift App/Sources/Services/TargetResolver+ResolvedPath.swift App/Sources/Services/CompatBadge.swift App/Sources/Services/LaunchPlanPreview.swift App/Tests/Services/ShortcutBuilderLauncherTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Build file, folder and command shortcuts

ShortcutBuilder writes launcher kinds with the Launcher binary, enforces
their invariants and signs them; duplicate, regenerate and export work
unchanged. Launch previews show the opened item or the planned command
with secrets masked. Launcher kinds have no resolved target and no
compatibility badge.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 5: App — wizard for files, folders and commands

**Files:**
- Create: `App/Sources/Views/Wizard/FileTargetStep.swift`, `App/Sources/Views/Wizard/CommandTargetStep.swift`
- Modify: `App/Sources/Views/Wizard/WizardModel.swift`, `App/Sources/Views/Wizard/WizardSteps.swift` (enable `.folder` and `.cli` options; split `.folder` option into "File or Folder" picking kind by the chosen item type), `App/Sources/Views/Wizard/NewShortcutWizard.swift`
- Test: `App/Tests/Wizard/WizardModelLauncherTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 2, 4.
- Produces (WizardModel additions):
  ```swift
  var itemPath: String?            // file/folder; selecting sets kind to .file or .folder by isDirectory
  var openerAppPath: String?
  var cliExecutable: String        // validated: absolute, executable
  var cliArguments: [String]       // from a multi-line field, one per line
  var cliWorkingDirectory: String?
  var terminal: TerminalChoice = .terminal
  var cliHomeOverride = false
  func selectItem(_ url: URL)
  func makeFileConfig() -> ShortcutConfig
  func makeCLIConfig() -> ShortcutConfig
  var launcherReviewRows: [ReviewRow]
  ```
  `steps`: file/folder → `[.kind, .target, .identity, .review]`; cli → `[.kind, .target, .identity, .data, .review]` where `.data` shows only the HOME-override toggle for cli. `canAdvance(.kind)` true for all five kinds; `.target` true when `itemPath != nil` (file/folder) or `cliExecutable` validates (cli).

Line numbers are at HEAD `8631c10`. Deviation (additive to the skeleton's WizardModel list, all needed by the views or the tests): `itemError`/`openerError` (read-only messages), `selectOpener(_:)`, `chooseKind(_:)`, `validatedCLIExecutable`/`cliExecutableError`, `static parseArguments(_:)`, `static terminalChoices`, `nonisolated static terminalLabel(_:)`, `isLauncherKind`, `launcherIconPath`, `copiedIconLabel` and `commandHomePath`. `cliArguments` stays a plain `[String]`; the multi-line text lives in the view and goes through `parseArguments`.

- [ ] **Step 1: Failing tests for the launcher wizard.** Create `App/Tests/Wizard/WizardModelLauncherTests.swift` (picked up by the `project.yml` `Tests` glob; `Tools/test-app.sh` regenerates the project with xcodegen). `WizardModel()` never fetches for these kinds (the icon fetch runs only for `.webApp`), the preview never locates a terminal for `.none`, and no test reads the real HOME folders.

```swift
import DuplicatorCore
import XCTest
@testable import MacAppDuplicator

/// Phase 5: the wizard's file, folder and command paths. Fixtures live in a per-test temp folder; nothing is launched.
@MainActor
final class WizardModelLauncherTests: XCTestCase {
    private func makeDir() throws -> URL {
        let dir = try makeAppTemporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeTool(in dir: URL) throws -> URL {
        let tool = dir.appending(path: "tool")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: tool)
        return tool
    }

    func testStepsPerKindAndEveryKindCanLeaveTheKindStep() {
        let model = WizardModel()
        for kind in [ShortcutKind.app, .webApp, .file, .folder, .cli] {
            model.chooseKind(kind)
            XCTAssertTrue(model.canAdvance, "\(kind)")
        }
        model.kind = .file
        XCTAssertEqual(model.steps, [.kind, .target, .identity, .review])
        model.kind = .folder
        XCTAssertEqual(model.steps, [.kind, .target, .identity, .review])
        model.kind = .cli
        XCTAssertEqual(model.steps, [.kind, .target, .identity, .data, .review])
        model.kind = .app
        XCTAssertEqual(model.steps, [.kind, .target, .identity, .data, .review])
    }

    func testSelectItemPicksFileOrFolderAndRefusesShortcuts() throws {
        let dir = try makeDir()
        let file = dir.appending(path: "Report.pdf")
        try Data("pdf".utf8).write(to: file)
        let folder = dir.appending(path: "Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = WizardModel()
        model.chooseKind(.folder)
        model.next()
        XCTAssertEqual(model.step, .target)
        XCTAssertFalse(model.canAdvance)

        model.selectItem(file)
        XCTAssertEqual(model.kind, .file)
        XCTAssertEqual(model.itemPath, FileConfig.normalizedPath(file.path))
        XCTAssertNil(model.itemError)
        XCTAssertTrue(model.canAdvance)

        model.selectItem(folder)
        XCTAssertEqual(model.kind, .folder)
        XCTAssertEqual(model.itemPath, FileConfig.normalizedPath(folder.path))

        let shortcut = try writeShortcutBundle(
            named: "Other Shortcut", in: dir, config: makeConfig(name: "Other Shortcut", targetPath: dir.appending(path: "Target.app").path)
        )
        model.selectItem(shortcut)
        XCTAssertNil(model.itemPath)
        XCTAssertNotNil(model.itemError)
        XCTAssertFalse(model.canAdvance)
    }

    func testCommandExecutableMustBeAnAbsoluteExecutableFile() throws {
        let dir = try makeDir()
        let model = WizardModel()
        model.chooseKind(.cli)
        model.next()
        XCTAssertEqual(model.step, .target)
        XCTAssertFalse(model.canAdvance)

        model.cliExecutable = "tool"
        XCTAssertEqual(model.cliExecutableError, "Use a full path that starts with /.")
        model.cliExecutable = dir.appending(path: "missing").path
        XCTAssertEqual(model.cliExecutableError, "Nothing exists at \(dir.appending(path: "missing").path).")
        model.cliExecutable = dir.path
        XCTAssertEqual(model.cliExecutableError, "\(dir.path) is a folder, not a program.")
        let plain = dir.appending(path: "plain.txt")
        try Data("x".utf8).write(to: plain)
        model.cliExecutable = plain.path
        XCTAssertEqual(model.cliExecutableError, "\(plain.path) is not executable.")
        XCTAssertNil(model.validatedCLIExecutable)
        XCTAssertFalse(model.canAdvance)

        let tool = try makeTool(in: dir)
        model.cliExecutable = "  \(tool.path)  "
        XCTAssertNil(model.cliExecutableError)
        XCTAssertEqual(model.validatedCLIExecutable, tool.path)
        XCTAssertTrue(model.canAdvance)
    }

    func testArgumentsAreOnePerLineTrimmedWithoutEmptyLines() {
        XCTAssertEqual(WizardModel.parseArguments("  --name \n\n\"two words\"\r\n it's \n   \n"), ["--name", "\"two words\"", "it's"])
        XCTAssertEqual(WizardModel.parseArguments(""), [])
    }

    func testFileConfigCarriesItemOpenerAndInvariants() throws {
        let dir = try makeDir()
        let item = dir.appending(path: "Report.pdf")
        try Data("pdf".utf8).write(to: item)
        let opener = dir.appending(path: "Viewer.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: opener, withIntermediateDirectories: true)
        let model = WizardModel(takenSlugs: ["report"])
        model.chooseKind(.folder)
        model.next()
        model.selectItem(item)
        model.selectOpener(opener)
        XCTAssertNil(model.openerError)
        model.next()
        XCTAssertEqual(model.step, .identity)
        XCTAssertEqual(model.name, "Report")
        XCTAssertEqual(model.copiedIconLabel, "Copied from item")

        let config = model.makeConfig()
        XCTAssertEqual(config.kind, .file)
        XCTAssertNotEqual(config.slug, "report")
        XCTAssertEqual(config.bundleIdentifier, ShortcutConfig.bundleIdentifier(forSlug: config.slug))
        XCTAssertEqual(config.file, FileConfig(path: FileConfig.normalizedPath(item.path), openerAppPath: FileConfig.normalizedPath(opener.path)))
        XCTAssertNil(config.cli)
        XCTAssertEqual(config.targetPath, "")
        XCTAssertEqual(config.targetBundleIdentifier, "")
        XCTAssertEqual(config.launchMode, .dockShortcut)
        XCTAssertEqual(config.dataMode, .disabled)
        XCTAssertNil(config.dataPath)
        XCTAssertEqual(model.makeFileConfig(), config)
        XCTAssertEqual(model.launcherReviewRows.map(\.label), ["Name", "File", "Open with", "Icon"])
        XCTAssertEqual(model.launcherReviewRows[2].value, "Viewer")

        model.next()
        XCTAssertEqual(model.step, .review)
        XCTAssertEqual(model.preview?.executablePath, FileConfig.normalizedPath(item.path))
        XCTAssertTrue(model.canAdvance)
    }

    func testOpenerMustBeAnApp() throws {
        let dir = try makeDir()
        let model = WizardModel()
        model.selectOpener(dir.appending(path: "notes.txt"))
        XCTAssertNil(model.openerAppPath)
        XCTAssertNotNil(model.openerError)
        model.selectOpener(nil)
        XCTAssertNil(model.openerAppPath)
        XCTAssertNil(model.openerError)
    }

    func testCommandConfigReviewRowsAndPreview() throws {
        let dir = try makeDir()
        let tool = try makeTool(in: dir)
        let model = WizardModel()
        model.chooseKind(.cli)
        model.next()
        model.cliExecutable = tool.path
        model.cliArguments = WizardModel.parseArguments("--token\nhunter2\ntwo words")
        model.cliWorkingDirectory = "  "
        model.terminal = .none
        model.next()
        XCTAssertEqual(model.step, .identity)
        XCTAssertEqual(model.name, "tool")
        XCTAssertEqual(model.copiedIconLabel, "Copied from executable")
        model.next()
        XCTAssertEqual(model.step, .data)
        model.cliHomeOverride = true
        model.next()
        XCTAssertEqual(model.step, .review)

        let config = model.makeConfig()
        XCTAssertEqual(config.kind, .cli)
        XCTAssertEqual(
            config.cli,
            CLIConfig(executablePath: tool.path, arguments: ["--token", "hunter2", "two words"], workingDirectory: nil, terminal: .none, homeOverride: true)
        )
        XCTAssertNil(config.file)
        XCTAssertEqual(config.dataMode, .disabled)
        XCTAssertEqual(model.makeCLIConfig(), config)

        let rows = Dictionary(uniqueKeysWithValues: model.launcherReviewRows.map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Executable"], tool.path)
        XCTAssertEqual(rows["Arguments"], "--token \(SecretMasking.maskedValue) \"two words\"")
        XCTAssertEqual(rows["Working directory"], "Default")
        XCTAssertEqual(rows["Terminal"], "No terminal (run in background)")
        XCTAssertEqual(rows["HOME"], "Own HOME: \(model.commandHomePath)")
        XCTAssertFalse(model.launcherReviewRows.contains { $0.value.contains("hunter2") })

        let preview = try XCTUnwrap(model.preview, model.previewError ?? "no preview")
        XCTAssertEqual(preview.executablePath, tool.path)
        XCTAssertFalse(preview.arguments.contains("hunter2"))
        XCTAssertTrue(model.canAdvance)
    }

    func testTerminalLabelsAndPickerOrder() {
        XCTAssertEqual(WizardModel.terminalChoices, [.terminal, .iterm2, .ghostty, .none])
        XCTAssertEqual(WizardModel.terminalChoices.map(WizardModel.terminalLabel), ["Terminal", "iTerm2", "Ghostty", "No terminal (run in background)"])
    }
}
```

- [ ] **Step 2: Run, expect failure.** `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/WizardModelLauncherTests 2>&1 | tail -4` — build error `value of type 'WizardModel' has no member 'chooseKind'`, `** TEST FAILED **`.

- [ ] **Step 3: Implement the WizardModel additions.** In `App/Sources/Views/Wizard/WizardModel.swift` (the model stays free of AppKit; `NSString` is Foundation):
  1. After `private var suggestedName = ""` (line 80) add the state:

```swift

    // MARK: Launcher state (Phase 5)

    /// The file or folder a `.file`/`.folder` shortcut opens; `selectItem` sets it and picks the kind.
    var itemPath: String?
    /// The app that opens the item; nil opens it with the app macOS picks.
    var openerAppPath: String?
    /// The program a `.cli` shortcut runs, as typed; `validatedCLIExecutable` is the checked form.
    var cliExecutable = ""
    /// One argument per entry, already trimmed and without empty entries (see `parseArguments`).
    var cliArguments: [String] = []
    var cliWorkingDirectory: String?
    var terminal: TerminalChoice = .terminal
    var cliHomeOverride = false
    private(set) var itemError: String?
    private(set) var openerError: String?
    private var itemIsDirectory = false
```

  2. Replace the `steps` property with its doc comment (lines 128–132) with:

```swift
    /// The steps this kind of shortcut goes through. A web app has no Data step (its data lives in a private web data
    /// store); Web App Options takes that slot. A file or folder shortcut has no data at all; a command's Data step only
    /// offers its own HOME.
    var steps: [Step] {
        switch kind {
        case .webApp: [.kind, .target, .identity, .webOptions, .review]
        case .file, .folder: [.kind, .target, .identity, .review]
        case .app, .cli: [.kind, .target, .identity, .data, .review]
        }
    }
```

  3. Replace the `var canAdvance: Bool { … }` property (lines 163–173) with:

```swift
    var canAdvance: Bool {
        switch step {
        case .kind: true
        case .target:
            switch kind {
            case .app: inspected != nil
            case .webApp: validatedWebURL != nil
            case .file, .folder: itemPath != nil
            case .cli: validatedCLIExecutable != nil
            }
        case .identity: !name.trimmingCharacters(in: .whitespaces).isEmpty && (iconMode != .custom || customIconPath != nil)
        case .data, .webOptions: true
        case .review:
            switch kind {
            case .webApp: !isCreating && webIconFetchState != .fetching
            case .app, .file, .folder, .cli: preview != nil && !isCreating
            }
        }
    }
```

  4. Replace `func next()` (lines 214–219) with:

```swift
    func next() {
        guard canAdvance, let i = steps.firstIndex(of: step), i + 1 < steps.count else { return }
        step = steps[i + 1]
        if step == .identity, kind == .webApp { startIconFetch() }
        if step == .identity, isLauncherKind { suggestLauncherName() }
        if step == .review { refreshPreview() }
    }
```

  5. In `makeConfig()`, after `if kind == .webApp { return makeWebConfig(name: trimmed, slug: finalSlug) }` (line 230) add:

```swift
        if kind == .file || kind == .folder { return makeFileConfig() }
        if kind == .cli { return makeCLIConfig() }
```

  6. In `iconDescription` (lines 338–345) replace the `.copied` line with `case .copied: copiedIconLabel`.
  7. Before the class's closing `}` (line 459) add:

```swift

    // MARK: Launchers (Phase 5)

    /// The terminal picker's order: Terminal first, background last.
    static let terminalChoices: [TerminalChoice] = [.terminal, .iterm2, .ghostty, .none]

    /// The picker label for a terminal choice. Nonisolated so Diagnostics (built off the main actor) could share it.
    nonisolated static func terminalLabel(_ choice: TerminalChoice) -> String {
        switch choice {
        case .terminal: "Terminal"
        case .iterm2: "iTerm2"
        case .ghostty: "Ghostty"
        case .none: "No terminal (run in background)"
        }
    }

    /// One argument per line: each line trimmed, empty lines dropped. Quotes are kept as typed (no shell parsing).
    static func parseArguments(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var isLauncherKind: Bool { kind == .file || kind == .folder || kind == .cli }

    /// What the identity step's Copied option is called for this kind.
    var copiedIconLabel: String {
        switch kind {
        case .webApp: "Fetched from site"
        case .file, .folder: "Copied from item"
        case .cli: "Copied from executable"
        case .app: "Copied from target"
        }
    }

    /// The path whose Finder icon the identity step previews for a launcher kind.
    var launcherIconPath: String? {
        switch kind {
        case .file, .folder: itemPath
        case .cli: validatedCLIExecutable
        case .app, .webApp: nil
        }
    }

    /// Where a command's own HOME would live (`ShortcutConfig.defaultDataPath` for the current slug).
    var commandHomePath: String {
        ShortcutConfig.defaultDataPath(forSlug: slug, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// The kind step's options. "File or Folder" is offered as `.folder`; choosing it keeps the kind an already chosen item decided.
    func chooseKind(_ chosen: ShortcutKind) {
        guard chosen == .file || chosen == .folder else {
            kind = chosen
            return
        }
        kind = itemPath != nil && !itemIsDirectory ? .file : .folder
    }

    /// Picks the item a launcher opens. A folder that is not a package becomes `.folder`; a file or a package (an app, a
    /// document bundle) becomes `.file`. App Duplicator shortcuts are refused: opening one would chain launchers.
    func selectItem(_ url: URL) {
        itemError = nil
        guard !TargetGuard.isShortcutBundle(at: url) else {
            itemPath = nil
            itemError = TargetGuard.refusalMessage(forAppAt: url)
            return
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        } catch {
            itemPath = nil
            itemError = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }
        itemIsDirectory = values.isDirectory == true && values.isPackage != true
        kind = itemIsDirectory ? .folder : .file
        itemPath = FileConfig.normalizedPath(url.path)
    }

    /// The app that opens the item, or nil for the default app. Only `.app` bundles that are not shortcuts are accepted.
    func selectOpener(_ url: URL?) {
        openerError = nil
        guard let url else {
            openerAppPath = nil
            return
        }
        guard url.pathExtension == "app" else {
            openerError = "\(url.lastPathComponent) is not an app."
            return
        }
        guard !TargetGuard.isShortcutBundle(at: url) else {
            openerError = TargetGuard.refusalMessage(forAppAt: url)
            return
        }
        openerAppPath = FileConfig.normalizedPath(url.path)
    }

    /// Why the executable field does not validate, or nil when it does.
    var cliExecutableError: String? {
        let path = Self.expandedPath(cliExecutable)
        if path.isEmpty { return "Choose the program to run." }
        guard path.hasPrefix("/") else { return "Use a full path that starts with /." }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return "Nothing exists at \(path)." }
        guard !isDirectory.boolValue else { return "\(path) is a folder, not a program." }
        guard FileManager.default.isExecutableFile(atPath: path) else { return "\(path) is not executable." }
        return nil
    }

    /// The executable once it is an absolute path to an existing, executable file (trimmed, `~` expanded); nil otherwise.
    var validatedCLIExecutable: String? {
        cliExecutableError == nil ? Self.expandedPath(cliExecutable) : nil
    }

    func makeFileConfig() -> ShortcutConfig {
        let finalSlug = slug
        return ShortcutConfig(
            kind: kind == .folder ? .folder : .file,
            name: name.trimmingCharacters(in: .whitespaces),
            slug: finalSlug,
            bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: finalSlug),
            targetPath: "",
            targetBundleIdentifier: "",
            launchMode: .dockShortcut,
            dataMode: .disabled,
            dataPath: nil,
            iconMode: iconMode,
            customIconPath: iconMode == .custom ? customIconPath : nil,
            file: FileConfig(path: itemPath ?? "", openerAppPath: openerAppPath)
        )
    }

    func makeCLIConfig() -> ShortcutConfig {
        let finalSlug = slug
        return ShortcutConfig(
            kind: .cli,
            name: name.trimmingCharacters(in: .whitespaces),
            slug: finalSlug,
            bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: finalSlug),
            targetPath: "",
            targetBundleIdentifier: "",
            launchMode: .dockShortcut,
            dataMode: .disabled,
            dataPath: nil,
            iconMode: iconMode,
            customIconPath: iconMode == .custom ? customIconPath : nil,
            cli: CLIConfig(
                executablePath: validatedCLIExecutable ?? Self.expandedPath(cliExecutable),
                arguments: cliArguments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                workingDirectory: trimmedWorkingDirectory,
                terminal: terminal,
                homeOverride: cliHomeOverride
            )
        )
    }

    /// The review step's rows for file, folder and command shortcuts. Arguments are masked like the launch plan.
    var launcherReviewRows: [ReviewRow] {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .file, .folder:
            return [
                ReviewRow("Name", trimmedName),
                ReviewRow(kind == .folder ? "Folder" : "File", itemPath ?? "None"),
                ReviewRow("Open with", openerAppPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Default app"),
                ReviewRow("Icon", iconDescription),
            ]
        case .cli:
            let arguments = SecretMasking.maskArguments(cliArguments).map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            return [
                ReviewRow("Name", trimmedName),
                ReviewRow("Executable", validatedCLIExecutable ?? cliExecutable),
                ReviewRow("Arguments", arguments.isEmpty ? "None" : arguments.joined(separator: " ")),
                ReviewRow("Working directory", trimmedWorkingDirectory ?? "Default"),
                ReviewRow("Terminal", Self.terminalLabel(terminal)),
                ReviewRow("HOME", cliHomeOverride ? "Own HOME: \(commandHomePath)" : "Your HOME"),
                ReviewRow("Icon", iconDescription),
            ]
        case .app, .webApp:
            return []
        }
    }

    private var trimmedWorkingDirectory: String? {
        guard let raw = cliWorkingDirectory?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return raw
    }

    private static func expandedPath(_ raw: String) -> String {
        NSString(string: raw.trimmingCharacters(in: .whitespaces)).expandingTildeInPath
    }

    /// Fills the name from the item (without its extension for a file) or the executable, unless the user typed one.
    private func suggestLauncherName() {
        guard let source = kind == .cli ? validatedCLIExecutable : itemPath else { return }
        let url = URL(fileURLWithPath: source)
        let candidate = kind == .file ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        if name.isEmpty || name == suggestedName {
            name = candidate
            suggestedName = name
        }
    }
```

- [ ] **Step 4: Run, expect pass.** `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/WizardModelLauncherTests 2>&1 | tail -4` — `Test Suite 'WizardModelLauncherTests' passed`, `** TEST SUCCEEDED **`. Also `Tools/test-app.sh -only-testing:MacAppDuplicatorTests/WebWizardModelTests 2>&1 | tail -4` — unchanged web wizard behaviour, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Create `App/Sources/Views/Wizard/FileTargetStep.swift`** (picked up by the `project.yml` `Sources` glob):

```swift
import AppKit
import DuplicatorCore
import SwiftUI
import UniformTypeIdentifiers

/// Phase 5 target step for "File or Folder": pick the item (the model sets `.file` or `.folder` from what was chosen)
/// and, optionally, the app that opens it.
struct FileTargetStep: View {
    @Bindable var model: WizardModel

    var body: some View {
        Form {
            Section("Item") {
                LabeledContent("Opens") {
                    HStack {
                        Text(model.itemPath ?? "Nothing chosen")
                            .foregroundStyle(model.itemPath == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseItem)
                            .help("Choose the file or folder this shortcut opens")
                    }
                }
                if let error = model.itemError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if model.itemPath != nil {
                    LabeledContent("Kind", value: model.kind == .folder ? "Folder" : "File")
                }
            }
            Section("Open with") {
                LabeledContent("App") {
                    HStack {
                        Text(model.openerAppPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Default app")
                        Button("Choose…", action: chooseOpener)
                            .help("Open the item with a specific app instead of its default app")
                        if model.openerAppPath != nil {
                            Button("Use Default") { model.selectOpener(nil) }
                                .help("Open the item with the app macOS picks for it")
                        }
                    }
                }
                if let error = model.openerError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.columns)
    }

    private func chooseItem() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the file or folder this shortcut opens."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.selectItem(url)
    }

    /// Starts in /Applications, but an app anywhere is accepted.
    private func chooseOpener() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Choose"
        panel.message = "Choose the app that opens the item."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.selectOpener(url)
    }
}
```

- [ ] **Step 6: Create `App/Sources/Views/Wizard/CommandTargetStep.swift`** with the command target step and the command's Data step:

```swift
import AppKit
import DuplicatorCore
import SwiftUI

/// Phase 5 target step for "Command": the program, its arguments (one per line), the working directory and where it runs.
struct CommandTargetStep: View {
    @Bindable var model: WizardModel
    @State private var argumentsText = ""

    var body: some View {
        Form {
            Section("Program") {
                LabeledContent("Executable") {
                    HStack {
                        TextField("Executable", text: $model.cliExecutable, prompt: Text("/usr/local/bin/tool"))
                            .labelsHidden()
                            .help("The full path of the program or script to run")
                        Button("Choose…", action: chooseExecutable)
                            .help("Choose the program or script to run")
                    }
                }
                if !model.cliExecutable.trimmingCharacters(in: .whitespaces).isEmpty, let error = model.cliExecutableError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Arguments") {
                    TextEditor(text: $argumentsText)
                        .font(.body.monospaced())
                        .frame(minHeight: 72)
                        .help("One argument per line. Spaces and quotes are passed exactly as typed; empty lines are ignored.")
                }
                LabeledContent("Working directory") {
                    TextField("Working directory", text: workingDirectory, prompt: Text("Default"))
                        .labelsHidden()
                        .help("The folder the command starts in; ~ means your home folder")
                }
            }
            Section("Run in") {
                Picker("Terminal", selection: $model.terminal) {
                    ForEach(WizardModel.terminalChoices, id: \.self) { choice in
                        Text(WizardModel.terminalLabel(choice)).tag(choice)
                    }
                }
                .help("Terminal and iTerm2 are driven through AppleScript, so macOS asks once for permission. No terminal runs the command in the background.")
            }
        }
        .formStyle(.columns)
        .onAppear { argumentsText = model.cliArguments.joined(separator: "\n") }
        .onChange(of: argumentsText) { _, text in model.cliArguments = WizardModel.parseArguments(text) }
    }

    private var workingDirectory: Binding<String> {
        Binding(get: { model.cliWorkingDirectory ?? "" }, set: { model.cliWorkingDirectory = $0.isEmpty ? nil : $0 })
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the program or script to run."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.cliExecutable = url.path
    }
}

/// Phase 5 Data step for a command: only the own-HOME toggle (a command has no target app data to separate).
struct CommandDataStep: View {
    @Bindable var model: WizardModel

    var body: some View {
        Form {
            Section("Data") {
                Toggle("Give this command its own HOME", isOn: $model.cliHomeOverride)
                    .help("Runs the command with HOME set to a private folder, so its dotfiles and settings stay apart from yours")
                if model.cliHomeOverride {
                    Text("HOME will be \(model.commandHomePath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.columns)
    }
}
```

- [ ] **Step 7: Wire the steps.**
  1. `App/Sources/Views/Wizard/WizardSteps.swift`, `KindStep`:
     - Replace lines 13–14 (the two disabled options) with:

```swift
            Option(kind: .folder, title: "File or Folder", subtitle: "Open a document or folder from the Dock", enabled: true, symbol: "folder"),
            Option(kind: .cli, title: "Command", subtitle: "Run a program or script, in a terminal or in the background", enabled: true, symbol: "terminal"),
```

     - Line 22: `model.kind = option.kind` becomes `model.chooseKind(option.kind)`.
     - Lines 31 and 34: replace both `model.kind == option.kind` with `isSelected(option)`, and add inside `KindStep` (after `body`):

```swift
    /// "File or Folder" is offered as `.folder` but stays selected once a chosen file made the kind `.file`.
    private func isSelected(_ option: Option) -> Bool {
        option.kind == .folder ? (model.kind == .file || model.kind == .folder) : model.kind == option.kind
    }
```

  2. `IdentityStep` in the same file:
     - Line 104: `Text(model.kind == .webApp ? "Fetched from site" : "Copied from target").tag(IconMode.copied)` becomes `Text(model.copiedIconLabel).tag(IconMode.copied)`.
     - Line 120: `if model.kind != .webApp {` (the Launch mode picker) becomes `if model.kind == .app {`.
     - In the `.copied` case of the icon preview (lines 135–150), put `if model.isLauncherKind { launcherIconPreview } else ` in front of that case's first `if`, and add inside `IdentityStep`:

```swift
    /// A launcher's Copied icon is the Finder icon of its item or executable, the same image the builder renders.
    @ViewBuilder private var launcherIconPreview: some View {
        if let path = model.launcherIconPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
        } else {
            Image(systemName: "app.dashed").resizable()
        }
    }
```

  3. `ReviewStep` in the same file:
     - Lines 246–258: change `} else {` after the web rows' `ForEach` block to `} else if model.isLauncherKind { ForEach(model.launcherReviewRows, id: \.label) { row($0.label, $0.value) } } else {` so launcher kinds show their rows and the app rows stay as they are.
     - Line 266: `if model.kind != .webApp, let profile = model.profile` becomes `if model.kind == .app, let profile = model.profile`.
  4. `App/Sources/Views/Wizard/NewShortcutWizard.swift`, in the step switch (lines 22–30), replace the `.target` and `.data` bodies with:

```swift
            case .target:
                switch model.kind {
                case .webApp: WebTargetStep(model: model)
                case .file, .folder: FileTargetStep(model: model)
                case .cli: CommandTargetStep(model: model)
                case .app: TargetStep(model: model)
                }
            case .data:
                if model.kind == .cli { CommandDataStep(model: model) } else { DataStep(model: model) }
```

  `appState.create(config: model.makeConfig(), webIconData: model.webIconPayload)` (line 77) needs no change: `makeConfig()` now dispatches to `makeFileConfig()`/`makeCLIConfig()`.

- [ ] **Step 8: Run the full app suite.** `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh 2>&1 | tail -4` — `** TEST SUCCEEDED **`, no new `warning:` lines in the filtered output.

- [ ] **Step 9: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add App/Sources/Views/Wizard/WizardModel.swift App/Sources/Views/Wizard/WizardSteps.swift App/Sources/Views/Wizard/NewShortcutWizard.swift App/Sources/Views/Wizard/FileTargetStep.swift App/Sources/Views/Wizard/CommandTargetStep.swift App/Tests/Wizard/WizardModelLauncherTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Wizard for file, folder and command shortcuts

The kind step offers File or Folder and Command. Choosing an item sets
.file or .folder; an optional opener app is supported. A command takes an
executable, one argument per line, a working directory, a terminal and an
optional own HOME. Review rows mask secret arguments.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```


### Task 6: App — editor, Diagnostics, library, docs, version

**Files:**
- Create: `App/Sources/Services/LauncherEditorPolicy.swift`, `App/Sources/Views/FileSection.swift`, `App/Sources/Views/CommandSection.swift`, `App/Tests/Services/LauncherEditorPolicyTests.swift`, `docs/acceptance/phase5-launchers.md`
- Modify: `App/Sources/Views/ShortcutEditorView.swift`, `App/Sources/Views/EditorSections.swift` (IdentitySection icon label per kind), `App/Sources/Views/DiagnosticsView.swift` (`LauncherDetails`, `makeLauncher`, report text, rows), `App/Sources/Views/ShortcutRowView.swift` (subtitle: item name / executable name), `App/Sources/Views/DeleteShortcutSheet.swift` (no data options for file/folder; cli offers HOME-override removal only when `homeOverride`), `App/Sources/Model/LibraryScanner.swift` (`targetExists` = item/executable exists for the new kinds), `App/Sources/Model/ShortcutLibrary.swift` (kind grouping unchanged; verify `SidebarSection.kinds` already lists the three kinds), `App/Sources/App/AppState.swift` (remove-data paths), `App/Sources/App/KnownLimitations.swift` (`cli-terminal-applescript`, `file-no-running-state`, `cli-no-running-state`, `cli-ghostty-path`), `README.md` (`## Phase 5 launchers`), `App/project.yml` (0.5.0 / 4)
- Test: `App/Tests/Services/LauncherEditorPolicyTests.swift`, `App/Tests/Model/LibraryScannerLauncherTests.swift` (new; covers the scanner and the diagnostics model), `App/Tests/App/KnownLimitationsTests.swift` (count 24 -> 28, new Phase 5 test)

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces: `LauncherEditorPolicy.saveConfig(draft:saved:) -> ShortcutConfig` (keeps slug/bundleIdentifier, enforces invariants), `LauncherEditorPolicy.validationMessage(for draft:) -> String?`, `DiagnosticsModel.LauncherDetails { kind, itemPath?, openerApp?, executable?, argv (masked), terminal?, homeOverride, workingDirectory? }`.

Line numbers are at HEAD `8631c10`; Tasks 4–5 are merged first (`LaunchPlanPreview.make` handles launcher kinds, `WizardModel.terminalChoices`/`terminalLabel`/`parseArguments` exist). `SidebarSection` already maps `.filesAndFolders` to `[.file, .folder]` and `.commands` to `[.cli]` (AppState lines 12–34) and `ShortcutLibrary` filters by kind, so neither changes. The editor keeps a launcher's kind: re-choosing the item offers only files for `.file` and only folders for `.folder` (switching type is a new shortcut). Like a web app, a rename keeps the saved slug and bundle identifier, so a command's own HOME (`defaultDataPath(forSlug:)`) does not move.

- [ ] **Step 1: Failing policy tests.** Create `App/Tests/Services/LauncherEditorPolicyTests.swift` (picked up by the `project.yml` `Tests` glob; `Tools/test-app.sh` regenerates the project with xcodegen). Paths are plain strings; nothing on disk is read.

```swift
import DuplicatorCore
import XCTest
@testable import MacAppDuplicator

final class LauncherEditorPolicyTests: XCTestCase {
    private func launcher(kind: ShortcutKind, name: String = "Notes", file: FileConfig? = nil, cli: CLIConfig? = nil) -> ShortcutConfig {
        ShortcutConfig(
            kind: kind, name: name, slug: "notes", bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: "notes"),
            targetPath: "", targetBundleIdentifier: "", launchMode: .dockShortcut, dataMode: .disabled, dataPath: nil,
            iconMode: .copied, customIconPath: nil, file: file, cli: cli
        )
    }

    func testLauncherKinds() {
        XCTAssertTrue(LauncherEditorPolicy.isLauncherKind(.file))
        XCTAssertTrue(LauncherEditorPolicy.isLauncherKind(.folder))
        XCTAssertTrue(LauncherEditorPolicy.isLauncherKind(.cli))
        XCTAssertFalse(LauncherEditorPolicy.isLauncherKind(.app))
        XCTAssertFalse(LauncherEditorPolicy.isLauncherKind(.webApp))
    }

    func testFileSaveKeepsSlugAndEnforcesInvariants() {
        let saved = launcher(kind: .file, file: FileConfig(path: "/Users/me/Notes.txt", openerAppPath: nil))
        var draft = saved
        draft.name = "  Renamed Notes  "
        draft.slug = "renamed-notes"
        draft.bundleIdentifier = "com.example.other"
        draft.targetPath = "/Applications/Stray.app"
        draft.dataMode = .homeOverride
        draft.dataPath = "/tmp/stray"
        draft.file = FileConfig(path: "/Users/me/Docs/../Notes.txt", openerAppPath: "")
        draft.cli = CLIConfig(executablePath: "/bin/echo", arguments: [], workingDirectory: nil, terminal: .none, homeOverride: false)

        let config = LauncherEditorPolicy.saveConfig(draft: draft, saved: saved)
        XCTAssertEqual(config.name, "Renamed Notes")
        XCTAssertEqual(config.slug, saved.slug)
        XCTAssertEqual(config.bundleIdentifier, saved.bundleIdentifier)
        XCTAssertEqual(config.targetPath, "")
        XCTAssertEqual(config.targetBundleIdentifier, "")
        XCTAssertEqual(config.launchMode, .dockShortcut)
        XCTAssertEqual(config.dataMode, .disabled)
        XCTAssertNil(config.dataPath)
        XCTAssertNil(config.cli)
        XCTAssertNil(config.webApp)
        XCTAssertEqual(config.file, FileConfig(path: FileConfig.normalizedPath("/Users/me/Docs/../Notes.txt"), openerAppPath: nil))
    }

    func testCommandSaveTrimsFields() {
        let saved = launcher(kind: .cli, name: "Tool", cli: CLIConfig(executablePath: "/bin/echo", arguments: [], workingDirectory: nil, terminal: .terminal, homeOverride: false))
        var draft = saved
        draft.cli = CLIConfig(executablePath: "  /bin/echo ", arguments: [" --name ", "", "two words"], workingDirectory: "   ", terminal: .iterm2, homeOverride: true)
        draft.file = FileConfig(path: "/tmp/stray", openerAppPath: nil)

        let config = LauncherEditorPolicy.saveConfig(draft: draft, saved: saved)
        XCTAssertEqual(config.cli, CLIConfig(executablePath: "/bin/echo", arguments: ["--name", "two words"], workingDirectory: nil, terminal: .iterm2, homeOverride: true))
        XCTAssertNil(config.file)
        XCTAssertEqual(config.dataMode, .disabled)
    }

    func testValidationMessages() {
        XCTAssertEqual(LauncherEditorPolicy.validationMessage(for: launcher(kind: .file)), "Choose the file or folder this shortcut opens.")
        XCTAssertEqual(
            LauncherEditorPolicy.validationMessage(for: launcher(kind: .folder, file: FileConfig(path: "Projects", openerAppPath: nil))),
            "Use a full path that starts with /."
        )
        XCTAssertNil(LauncherEditorPolicy.validationMessage(for: launcher(kind: .folder, file: FileConfig(path: "/Users/me/Projects", openerAppPath: nil))))
        let emptyCommand = CLIConfig(executablePath: "  ", arguments: [], workingDirectory: nil, terminal: .none, homeOverride: false)
        XCTAssertEqual(LauncherEditorPolicy.validationMessage(for: launcher(kind: .cli, cli: emptyCommand)), "Enter the program to run.")
        let relative = CLIConfig(executablePath: "tool", arguments: [], workingDirectory: nil, terminal: .none, homeOverride: false)
        XCTAssertEqual(LauncherEditorPolicy.validationMessage(for: launcher(kind: .cli, cli: relative)), "Use a full path that starts with /.")
        XCTAssertNil(LauncherEditorPolicy.validationMessage(for: launcher(kind: .app)))
    }

    func testLabelsSubtitlesAndCommandHome() {
        XCTAssertEqual(LauncherEditorPolicy.iconLabel(.copied, kind: .file), "Copied from item")
        XCTAssertEqual(LauncherEditorPolicy.iconLabel(.copied, kind: .cli), "Copied from executable")
        XCTAssertEqual(LauncherEditorPolicy.iconLabel(.copied, kind: .app), "Copied from target")
        XCTAssertEqual(LauncherEditorPolicy.iconLabel(.generated, kind: .folder), "Generated tile")
        XCTAssertEqual(LauncherEditorPolicy.subtitle(for: launcher(kind: .file, file: FileConfig(path: "/Users/me/Report.pdf", openerAppPath: nil))), "Report.pdf")
        let tool = CLIConfig(executablePath: "/opt/bin/tool", arguments: ["--token", "x"], workingDirectory: nil, terminal: .none, homeOverride: false)
        XCTAssertEqual(LauncherEditorPolicy.subtitle(for: launcher(kind: .cli, cli: tool)), "tool")

        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        XCTAssertNil(LauncherEditorPolicy.commandHomePath(for: launcher(kind: .cli, cli: tool), home: home))
        var own = tool
        own.homeOverride = true
        XCTAssertEqual(
            LauncherEditorPolicy.commandHomePath(for: launcher(kind: .cli, cli: own), home: home),
            ShortcutConfig.defaultDataPath(forSlug: "notes", home: home)
        )
        XCTAssertNil(LauncherEditorPolicy.commandHomePath(for: launcher(kind: .file, file: FileConfig(path: "/a", openerAppPath: nil)), home: home))
    }
}
```

- [ ] **Step 2: Run, expect failure.** `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/LauncherEditorPolicyTests 2>&1 | tail -4` — build error `cannot find 'LauncherEditorPolicy' in scope`, `** TEST FAILED **`.

- [ ] **Step 3: Create `App/Sources/Services/LauncherEditorPolicy.swift`** (`Sources` glob). `nonisolated` because `DiagnosticsModel.make` runs off the main actor.

```swift
import DuplicatorCore
import Foundation

/// The editor rules for file, folder and command shortcuts, kept out of the views so they are unit-tested (mirrors
/// `WebEditorPolicy`).
nonisolated enum LauncherEditorPolicy {
    static func isLauncherKind(_ kind: ShortcutKind) -> Bool {
        kind == .file || kind == .folder || kind == .cli
    }

    /// The config Save writes for a launcher. It trims the name and keeps the saved slug and bundle identifier (a
    /// command's own HOME is filed under the slug), re-applies the launcher invariants (no target, Dock Shortcut,
    /// data Disabled), keeps only the sub-config of the kind, and cleans the fields: a normalized item path, a blank
    /// opener as nil, a trimmed executable, a blank working directory as nil, trimmed arguments without empty ones.
    static func saveConfig(draft: ShortcutConfig, saved: ShortcutConfig) -> ShortcutConfig {
        var config = draft
        config.name = draft.name.trimmingCharacters(in: .whitespaces)
        config.slug = saved.slug
        config.bundleIdentifier = saved.bundleIdentifier
        config.targetPath = ""
        config.targetBundleIdentifier = ""
        config.launchMode = .dockShortcut
        config.dataMode = .disabled
        config.dataPath = nil
        config.webApp = nil
        switch draft.kind {
        case .file, .folder:
            config.cli = nil
            config.file = draft.file.map { file in
                FileConfig(path: FileConfig.normalizedPath(file.path), openerAppPath: blankToNil(file.openerAppPath).map(FileConfig.normalizedPath))
            }
        case .cli:
            config.file = nil
            config.cli = draft.cli.map { cli in
                CLIConfig(
                    executablePath: cli.executablePath.trimmingCharacters(in: .whitespaces),
                    arguments: cli.arguments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                    workingDirectory: blankToNil(cli.workingDirectory),
                    terminal: cli.terminal,
                    homeOverride: cli.homeOverride
                )
            }
        case .app, .webApp:
            break
        }
        return config
    }

    /// Why Save is not allowed, or nil. Only the shape of the path is checked; a missing item shows as "Item missing".
    static func validationMessage(for config: ShortcutConfig) -> String? {
        switch config.kind {
        case .file, .folder:
            let path = config.file?.path.trimmingCharacters(in: .whitespaces) ?? ""
            if path.isEmpty { return "Choose the file or folder this shortcut opens." }
            return path.hasPrefix("/") ? nil : "Use a full path that starts with /."
        case .cli:
            let path = config.cli?.executablePath.trimmingCharacters(in: .whitespaces) ?? ""
            if path.isEmpty { return "Enter the program to run." }
            return path.hasPrefix("/") ? nil : "Use a full path that starts with /."
        case .app, .webApp:
            return nil
        }
    }

    static func iconLabel(_ mode: IconMode, kind: ShortcutKind) -> String {
        switch mode {
        case .copied:
            switch kind {
            case .file, .folder: "Copied from item"
            case .cli: "Copied from executable"
            case .webApp: "Fetched from site"
            case .app: "Copied from target"
            }
        case .custom: "Custom file"
        case .generated: "Generated tile"
        }
    }

    /// The library row's subtitle: the item's or the executable's last path component.
    static func subtitle(for config: ShortcutConfig) -> String {
        switch config.kind {
        case .file, .folder: config.file.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? ""
        case .cli: config.cli.map { URL(fileURLWithPath: $0.executablePath).lastPathComponent } ?? ""
        case .app, .webApp: ""
        }
    }

    /// A command's own HOME folder when it has one (`cli.homeOverride`), else nil.
    static func commandHomePath(for config: ShortcutConfig, home: URL) -> String? {
        guard config.kind == .cli, config.cli?.homeOverride == true else { return nil }
        return ShortcutConfig.defaultDataPath(forSlug: config.slug, home: home)
    }

    private static func blankToNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
```

- [ ] **Step 4: Run, expect pass.** Same command as Step 2 — `Test Suite 'LauncherEditorPolicyTests' passed`, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add App/Sources/Services/LauncherEditorPolicy.swift App/Tests/Services/LauncherEditorPolicyTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Add LauncherEditorPolicy for launcher shortcuts

Save keeps the slug and bundle id, re-applies the launcher invariants and
cleans the item, opener, executable, arguments and working directory.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 6: Failing scanner and diagnostics tests.** Create `App/Tests/Model/LibraryScannerLauncherTests.swift` (`Tests` glob; the script regenerates the project). Logs are read from the per-test folder (`LogReader(folder:)`); the command uses `.none`, so no terminal is located and nothing runs.

```swift
import DuplicatorCore
import XCTest
@testable import MacAppDuplicator

final class LibraryScannerLauncherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeAppTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    private func launcherConfig(kind: ShortcutKind, name: String, file: FileConfig? = nil, cli: CLIConfig? = nil) -> ShortcutConfig {
        let slug = ShortcutConfig.slug(for: name)
        return ShortcutConfig(
            kind: kind, name: name, slug: slug, bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: slug),
            targetPath: "", targetBundleIdentifier: "", launchMode: .dockShortcut, dataMode: .disabled, dataPath: nil,
            iconMode: .generated, customIconPath: nil, file: file, cli: cli
        )
    }

    func testTargetExistsFollowsTheItemOrExecutable() throws {
        let item = dir.appending(path: "Report.pdf")
        try Data("pdf".utf8).write(to: item)
        let present = try writeShortcutBundle(
            named: "Report", in: dir, config: launcherConfig(kind: .file, name: "Report", file: FileConfig(path: item.path, openerAppPath: nil))
        )
        let gone = try writeShortcutBundle(
            named: "Gone", in: dir,
            config: launcherConfig(kind: .folder, name: "Gone", file: FileConfig(path: dir.appending(path: "Missing").path, openerAppPath: nil))
        )
        let tool = dir.appending(path: "tool")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: tool)
        let command = try writeShortcutBundle(
            named: "Tool", in: dir,
            config: launcherConfig(kind: .cli, name: "Tool", cli: CLIConfig(executablePath: tool.path, arguments: [], workingDirectory: nil, terminal: .none, homeOverride: false))
        )

        let presentRecord = try LibraryScanner.record(forBundleAt: present, fileManager: .default)
        XCTAssertTrue(presentRecord.targetExists)
        XCTAssertNil(presentRecord.targetVersion)
        XCTAssertFalse(try LibraryScanner.record(forBundleAt: gone, fileManager: .default).targetExists)
        XCTAssertTrue(try LibraryScanner.record(forBundleAt: command, fileManager: .default).targetExists)
        try FileManager.default.removeItem(at: tool)
        XCTAssertFalse(try LibraryScanner.record(forBundleAt: command, fileManager: .default).targetExists)
    }

    func testCommandDiagnosticsShowMaskedPlanAndLauncherRows() throws {
        let tool = dir.appending(path: "tool")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: tool)
        let cli = CLIConfig(executablePath: tool.path, arguments: ["--token", "hunter2", "two words"], workingDirectory: nil, terminal: .none, homeOverride: false)
        let bundle = try writeShortcutBundle(named: "Tool", in: dir, config: launcherConfig(kind: .cli, name: "Tool", cli: cli))
        let record = try LibraryScanner.record(forBundleAt: bundle, fileManager: .default)

        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: dir))
        XCTAssertNil(model.planError)
        XCTAssertNil(model.web)
        XCTAssertEqual(
            model.launcher,
            DiagnosticsModel.LauncherDetails(kind: "Command", item: nil, openWith: nil, terminal: "No terminal (run in background)", workingDirectory: "Default", ownHome: "No")
        )
        XCTAssertEqual(model.executablePath, tool.path)
        XCTAssertTrue(model.arguments.contains(SecretMasking.maskedValue))
        XCTAssertFalse(model.reportText.contains("hunter2"))
        XCTAssertTrue(model.reportText.contains("Kind: Command"))
        XCTAssertTrue(model.reportText.contains("Terminal: No terminal (run in background)"))
    }

    func testFileDiagnosticsShowItemAndOpener() throws {
        let item = dir.appending(path: "Report.pdf")
        try Data("pdf".utf8).write(to: item)
        let file = FileConfig(path: item.path, openerAppPath: "/Applications/Preview.app")
        let bundle = try writeShortcutBundle(named: "Report", in: dir, config: launcherConfig(kind: .file, name: "Report", file: file))
        let record = try LibraryScanner.record(forBundleAt: bundle, fileManager: .default)

        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: dir))
        XCTAssertEqual(
            model.launcher,
            DiagnosticsModel.LauncherDetails(kind: "File", item: item.path, openWith: "Preview", terminal: nil, workingDirectory: nil, ownHome: nil)
        )
        XCTAssertTrue(model.reportText.contains("Item: \(item.path)"))
        XCTAssertTrue(model.reportText.contains("Open with: Preview"))
    }
}
```

`"/Applications/Preview.app"` is only a string stored in the config; the file plan never opens or stats the opener.

- [ ] **Step 7: Run, expect failure.** `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/LibraryScannerLauncherTests 2>&1 | tail -4` — build error `value of type 'DiagnosticsModel' has no member 'launcher'`, `** TEST FAILED **`.

- [ ] **Step 8: Scanner.** In `App/Sources/Model/LibraryScanner.swift` (line numbers at HEAD `8631c10`), replace the web comment and three constants:

Old:

```swift
        // A web app has no target app: it is never "missing" and has no version to read.
        let isWebApp = config.kind == .webApp
        let targetURL = URL(fileURLWithPath: config.targetPath)
        let targetExists = isWebApp || fileManager.fileExists(atPath: targetURL.path)
```

New:

```swift
        // A web app has no target app: it is never "missing" and has no version to read. A launcher's target is the
        // item it opens or the program it runs (Phase 5); it has no version either.
        let targetURL = URL(fileURLWithPath: config.targetPath)
        let targetExists: Bool
        switch config.kind {
        case .webApp: targetExists = true
        case .file, .folder: targetExists = config.file.map { fileManager.fileExists(atPath: $0.path) } ?? false
        case .cli: targetExists = config.cli.map { fileManager.fileExists(atPath: $0.executablePath) } ?? false
        case .app: targetExists = fileManager.fileExists(atPath: targetURL.path)
        }
```

Then replace the one other use of `isWebApp`, which is gone:

Old:

```swift
        if targetExists, !isWebApp,
```

New:

```swift
        if targetExists, config.kind == .app,
```

- [ ] **Step 9: Diagnostics model.** In `App/Sources/Views/DiagnosticsView.swift`:
  1. After `var web: WebDetails?` (line 28) add:

```swift
    /// Set for a file, folder or command shortcut (Phase 5); nil for every other kind. Defaulted like `web`.
    var launcher: LauncherDetails?

    /// What a launcher's Diagnostics shows besides the launch plan. Every value is display text.
    struct LauncherDetails: Equatable {
        /// "File", "Folder" or "Command".
        let kind: String
        /// The item a file or folder shortcut opens (nil for a command).
        let item: String?
        /// The opener app's name, or "Default app" (nil for a command).
        let openWith: String?
        /// The terminal label (`WizardModel.terminalLabel`) for a command.
        let terminal: String?
        /// The command's working directory, or "Default".
        let workingDirectory: String?
        /// The command's own HOME path, or "No".
        let ownHome: String?
    }
```

  2. In `make(record:logReader:profileCatalog:)`, extend the web dispatch (lines 49–51):

Old:

```swift
        if record.config.kind == .webApp {
            return makeWeb(record: record, logLines: logLines)
        }
```

New:

```swift
        if record.config.kind == .webApp {
            return makeWeb(record: record, logLines: logLines)
        }
        if LauncherEditorPolicy.isLauncherKind(record.config.kind) {
            return makeLauncher(record: record, logLines: logLines)
        }
```

  3. After `makeWeb` (its closing `}`, just above the doc comment of `storedPathDiffers`) add:

```swift
    /// A launcher has no profile or target app; the plan comes from `LaunchPlanPreview` (masked argv, environment
    /// additions only) and the launcher's own settings fill `launcher`.
    private static func makeLauncher(record: ShortcutRecord, logLines: [String]) -> DiagnosticsModel {
        let config = record.config
        let details = launcherDetails(for: config)
        let itemPath = config.file?.path ?? config.cli?.executablePath ?? ""
        let notApplicable = "Not applicable (\(details.kind.lowercased()) shortcut)"
        do {
            let preview = try LaunchPlanPreview.make(config: config, bundleURL: record.bundleURL)
            let env = preview.environmentAdditions.keys.sorted().map { key in
                (key: key, value: SecretMasking.isSecretKey(key) ? SecretMasking.maskedValue : preview.environmentAdditions[key] ?? "")
            }
            return DiagnosticsModel(
                shortcutName: record.name, bundlePath: record.bundleURL.path, engineVersion: record.engineVersion,
                profileMatch: notApplicable, profileRows: [], storedTargetPath: itemPath,
                resolvedTargetPath: record.targetExists ? itemPath : nil, executablePath: preview.executablePath,
                launchMode: "Dock Shortcut", arguments: preview.arguments, environment: env, warnings: preview.warnings,
                logLines: logLines, planError: nil, launcher: details
            )
        } catch {
            return DiagnosticsModel(
                shortcutName: record.name, bundlePath: record.bundleURL.path, engineVersion: record.engineVersion,
                profileMatch: notApplicable, profileRows: [], storedTargetPath: itemPath,
                resolvedTargetPath: record.targetExists ? itemPath : nil, executablePath: "",
                launchMode: "Dock Shortcut", arguments: [], environment: [], warnings: [],
                logLines: logLines, planError: error.localizedDescription, launcher: details
            )
        }
    }

    private static func launcherDetails(for config: ShortcutConfig) -> LauncherDetails {
        if config.kind == .cli, let cli = config.cli {
            let home = LauncherEditorPolicy.commandHomePath(for: config, home: FileManager.default.homeDirectoryForCurrentUser)
            return LauncherDetails(
                kind: "Command", item: nil, openWith: nil, terminal: WizardModel.terminalLabel(cli.terminal),
                workingDirectory: cli.workingDirectory ?? "Default", ownHome: home ?? "No"
            )
        }
        let opener = config.file?.openerAppPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        return LauncherDetails(
            kind: config.kind == .folder ? "Folder" : "File", item: config.file?.path ?? "None", openWith: opener ?? "Default app",
            terminal: nil, workingDirectory: nil, ownHome: nil
        )
    }
```

  4. In `reportText` (lines 172–205), the kind block is `if let web { … } else { … }` and the shared tail already prints `Launch plan error:` or `Executable:`, `Launch mode:`, `Arguments:`, `Environment:` and `Warnings:` whenever `web == nil`, so a launcher only needs its own identification lines in front of that tail. Do not print the plan again.

Old:

```swift
        if let web {
            lines.append("Kind: Web app")
```

New:

```swift
        if let launcher {
            lines.append("Kind: \(launcher.kind)")
            if let item = launcher.item { lines.append("Item: \(item)") }
            if let openWith = launcher.openWith { lines.append("Open with: \(openWith)") }
            if let terminal = launcher.terminal { lines.append("Terminal: \(terminal)") }
            if let workingDirectory = launcher.workingDirectory { lines.append("Working directory: \(workingDirectory)") }
            if let ownHome = launcher.ownHome { lines.append("Own HOME: \(ownHome)") }
        } else if let web {
            lines.append("Kind: Web app")
```

  5. In the view, the Shortcut section's kind block (lines 232–252) is `if let web = model.web { … } else { Profile/Target rows }`, followed by a plan block (`Executable`, `Launch mode`) that already runs for every kind except web apps, so a launcher keeps the Executable and Launch mode rows and the Arguments, Environment and Warnings sections (lines 252 and 260 stay as they are).

Old:

```swift
                            if let web = model.web {
                                row("Kind", "Web app")
```

New:

```swift
                            if let launcher = model.launcher {
                                row("Kind", launcher.kind)
                                if let item = launcher.item { row("Item", item) }
                                if let openWith = launcher.openWith { row("Open with", openWith) }
                                if let terminal = launcher.terminal { row("Terminal", terminal) }
                                if let workingDirectory = launcher.workingDirectory { row("Working directory", workingDirectory) }
                                if let ownHome = launcher.ownHome { row("Own HOME", ownHome) }
                            } else if let web = model.web {
                                row("Kind", "Web app")
```

- [ ] **Step 10: Run, expect pass.** `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/LibraryScannerLauncherTests 2>&1 | tail -4` — `** TEST SUCCEEDED **`; then `-only-testing:MacAppDuplicatorTests/DiagnosticsModelTests` and `-only-testing:MacAppDuplicatorTests/LibraryScannerTests` — both `** TEST SUCCEEDED **` (app and web paths unchanged).

- [ ] **Step 11: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add App/Sources/Model/LibraryScanner.swift App/Sources/Views/DiagnosticsView.swift App/Tests/Model/LibraryScannerLauncherTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Scan and diagnose launcher shortcuts

A launcher's target exists when its item or executable does. Diagnostics
shows the kind, item, opener, terminal, working directory, own HOME and the
masked launch plan.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 12: Editor sections.** Append to `App/Sources/Views/EditorSections.swift`:

```swift
/// Phase 5: a file or folder shortcut's item and opener. Re-choosing keeps the kind (files for `.file`, folders for `.folder`).
struct FileSection: View {
    @Binding var draft: ShortcutConfig
    @State private var choiceError: String?

    var body: some View {
        Section(draft.kind == .folder ? "Folder" : "File") {
            LabeledContent("Opens") {
                HStack {
                    Text(draft.file?.path ?? "Nothing chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…", action: chooseItem)
                        .help(draft.kind == .folder ? "Choose the folder this shortcut opens" : "Choose the file this shortcut opens")
                }
            }
            LabeledContent("Open with") {
                HStack {
                    Text(draft.file?.openerAppPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Default app")
                    Button("Choose…", action: chooseOpener)
                        .help("Open the item with a specific app instead of its default app")
                    if draft.file?.openerAppPath != nil {
                        Button("Use Default") { draft.file?.openerAppPath = nil }
                            .help("Open the item with the app macOS picks for it")
                    }
                }
            }
            if let message = choiceError ?? LauncherEditorPolicy.validationMessage(for: draft) {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func chooseItem() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = draft.kind == .file
        panel.canChooseDirectories = draft.kind == .folder
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !TargetGuard.isShortcutBundle(at: url) else {
            choiceError = TargetGuard.refusalMessage(forAppAt: url)
            return
        }
        choiceError = nil
        draft.file = FileConfig(path: FileConfig.normalizedPath(url.path), openerAppPath: draft.file?.openerAppPath)
    }

    private func chooseOpener() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !TargetGuard.isShortcutBundle(at: url) else {
            choiceError = TargetGuard.refusalMessage(forAppAt: url)
            return
        }
        choiceError = nil
        draft.file?.openerAppPath = FileConfig.normalizedPath(url.path)
    }
}

/// Phase 5: a command shortcut's program, arguments (one per line), working directory, terminal and own HOME.
struct CommandSection: View {
    @Binding var draft: ShortcutConfig
    @State private var argumentsText = ""

    var body: some View {
        Section("Command") {
            LabeledContent("Executable") {
                HStack {
                    TextField("Executable", text: executable, prompt: Text("/usr/local/bin/tool"))
                        .labelsHidden()
                        .help("The full path of the program or script to run")
                    Button("Choose…", action: chooseExecutable)
                        .help("Choose the program or script to run")
                }
            }
            LabeledContent("Arguments") {
                TextEditor(text: $argumentsText)
                    .font(.body.monospaced())
                    .frame(minHeight: 72)
                    .help("One argument per line. Spaces and quotes are passed exactly as typed; empty lines are ignored.")
            }
            TextField("Working directory", text: workingDirectory, prompt: Text("Default"))
                .help("The folder the command starts in")
            Picker("Terminal", selection: terminal) {
                ForEach(WizardModel.terminalChoices, id: \.self) { choice in
                    Text(WizardModel.terminalLabel(choice)).tag(choice)
                }
            }
            .help("Terminal and iTerm2 are driven through AppleScript, so macOS asks once for permission. No terminal runs the command in the background.")
            Toggle("Give this command its own HOME", isOn: homeOverride)
                .help("Runs the command with HOME set to a private folder under ~/Library/Application Support/App Duplicator")
            if let message = LauncherEditorPolicy.validationMessage(for: draft) {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { argumentsText = draft.cli?.arguments.joined(separator: "\n") ?? "" }
        .onChange(of: argumentsText) { _, text in draft.cli?.arguments = WizardModel.parseArguments(text) }
    }

    private var executable: Binding<String> {
        Binding(get: { draft.cli?.executablePath ?? "" }, set: { draft.cli?.executablePath = $0 })
    }

    private var workingDirectory: Binding<String> {
        Binding(get: { draft.cli?.workingDirectory ?? "" }, set: { draft.cli?.workingDirectory = $0.isEmpty ? nil : $0 })
    }

    private var terminal: Binding<TerminalChoice> {
        Binding(get: { draft.cli?.terminal ?? .terminal }, set: { draft.cli?.terminal = $0 })
    }

    private var homeOverride: Binding<Bool> {
        Binding(get: { draft.cli?.homeOverride ?? false }, set: { draft.cli?.homeOverride = $0 })
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.cli?.executablePath = url.path
    }
}
```

  No import changes: `EditorSections.swift` already uses `NSOpenPanel` (lines 44 and 88) through its `SwiftUI` import and `UTType` through `UniformTypeIdentifiers`. In `IdentitySection` (lines 21–24) replace the three `Text(...).tag(...)` lines of the non-web `else` branch with:

```swift
                    ForEach([IconMode.copied, .custom, .generated], id: \.self) { mode in
                        Text(LauncherEditorPolicy.iconLabel(mode, kind: draft.kind)).tag(mode)
                    }
```

- [ ] **Step 13: Editor view, row and delete sheet.** Line numbers are at HEAD `8631c10`.
  1. `App/Sources/Views/ShortcutEditorView.swift`:

     a. After `isWebApp` (line 32):

Old:

```swift
    private var isWebApp: Bool { record.config.kind == .webApp }
```

New:

```swift
    private var isWebApp: Bool { record.config.kind == .webApp }

    private var isLauncher: Bool { LauncherEditorPolicy.isLauncherKind(record.config.kind) }
```

     b. In the Form (lines 40–48), add the launcher branch between the web branch and the app branch:

Old:

```swift
                WebAppSection(draft: $draft, record: record, urlIsValid: $webURLIsValid).id(revertCount)
            } else {
```

New:

```swift
                WebAppSection(draft: $draft, record: record, urlIsValid: $webURLIsValid).id(revertCount)
            } else if isLauncher {
                // A launcher has no target app, profile, launch mode or data mode; its settings live in one section.
                if record.config.kind == .cli {
                    CommandSection(draft: $draft).id(revertCount)
                } else {
                    FileSection(draft: $draft)
                }
            } else {
```

     c. Save button (lines 82–85):

Old:

```swift
                    .disabled(!hasChanges || isSaving || !webURLIsValid || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
```

New:

```swift
                    .disabled(
                        !hasChanges || isSaving || !webURLIsValid || draft.name.trimmingCharacters(in: .whitespaces).isEmpty
                            || (isLauncher && LauncherEditorPolicy.validationMessage(for: draft) != nil)
                    )
```

     d. The target inspection task (line 91): launchers have no target to inspect.

Old:

```swift
            guard !isWebApp else {
```

New:

```swift
            guard draft.kind == .app else {
```

     e. `save()` (lines 137–143):

Old:

```swift
            config = WebEditorPolicy.saveConfig(draft: draft, saved: record.config)
        } else {
```

New:

```swift
            config = WebEditorPolicy.saveConfig(draft: draft, saved: record.config)
        } else if isLauncher {
            // Keeps the slug and bundle identifier on a rename, so a command's own HOME does not move.
            config = LauncherEditorPolicy.saveConfig(draft: draft, saved: record.config)
        } else {
```

  2. `App/Sources/Views/ShortcutRowView.swift`, `subtitle` (lines 45–56):

Old:

```swift
            Text(record.webAppHost ?? "Web App").foregroundStyle(.secondary)
        } else if record.targetExists {
```

New:

```swift
            Text(record.webAppHost ?? "Web App").foregroundStyle(.secondary)
        } else if LauncherEditorPolicy.isLauncherKind(record.config.kind) {
            if record.targetExists {
                Text(LauncherEditorPolicy.subtitle(for: record.config)).foregroundStyle(.secondary)
            } else {
                Text("Item missing").foregroundStyle(.red)
            }
        } else if record.targetExists {
```

  3. `App/Sources/Views/DeleteShortcutSheet.swift`:

Old:

```swift
            Text(isWebApp ? "The web app is moved to the Trash." : "The shortcut is moved to the Trash. The target app is never touched.")
```

New:

```swift
            Text(Self.message(for: record.config.kind))
```

Old:

```swift
                Toggle("Also move the data folder to the Trash", isOn: $removeData)
```

New:

```swift
                Toggle(
                    record.config.kind == .cli ? "Also move the command's own HOME folder to the Trash" : "Also move the data folder to the Trash",
                    isOn: $removeData
                )
```

     and add inside the struct, directly above `var body: some View {`:

```swift
    static func message(for kind: ShortcutKind) -> String {
        switch kind {
        case .webApp: "The web app is moved to the Trash."
        case .app: "The shortcut is moved to the Trash. The target app is never touched."
        case .file, .folder, .cli: "The shortcut is moved to the Trash. The file, folder or command it opens is never touched."
        }
    }
```

  The toggle appears only for `.available`, which Step 14 returns only for a command with its own HOME folder on disk. `isWebApp` in the sheet is still used elsewhere in the file; leave it.

- [ ] **Step 14: AppState delete paths.** In `App/Sources/App/AppState.swift` (line numbers at HEAD `8631c10`):
  1. `dataFolderDeletionOption(for:)`, after the web app `return` (lines 282–284). The launcher branch must come before the `dataMode != .disabled` guard, because launchers are always `.disabled`:

Old:

```swift
            return .unavailable(note: "A web app keeps its logins and cookies in web data, not in a data folder.")
        }
```

New:

```swift
            return .unavailable(note: "A web app keeps its logins and cookies in web data, not in a data folder.")
        }
        if record.config.kind == .file || record.config.kind == .folder {
            return .unavailable(note: "A file or folder shortcut has no data folder.")
        }
        if record.config.kind == .cli {
            guard let homePath = LauncherEditorPolicy.commandHomePath(for: record.config, home: home) else {
                return .unavailable(note: "This command uses your HOME, so it has no data folder of its own.")
            }
            let folder = URL(fileURLWithPath: homePath, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .unavailable(note: "No HOME folder exists at \(folder.path).")
            }
            let dataRoot = CanonicalPath(ShortcutConfig.dataRoot(home: home).path)
            return .available(folder: folder, outsideDataRoot: !CanonicalPath(folder.path).isInside(dataRoot))
        }
```

  2. `dataPathsInUse(excluding:)` (line 311), so another shortcut's own HOME is never offered or trashed twice:

Old:

```swift
            .compactMap { $0.config.effectiveDataPath(home: home) }
```

New:

```swift
            .compactMap { $0.config.effectiveDataPath(home: home) ?? LauncherEditorPolicy.commandHomePath(for: $0.config, home: home) }
```

  3. `delete(_:removeData:removeWebData:)` (lines 219–243): `ShortcutBuilder.delete` trashes data only for `dataMode != .disabled`, and launchers are always `.disabled`, so the command HOME is trashed here, after the shortcut itself:

Old:

```swift
        do {
            let trashed = try builder.delete(
                record: record, removeData: removeData,
                libraryFolders: settings.allLibraryFolders, otherRecordDataPaths: dataPathsInUse(excluding: record.bundleURL),
                shortcutBundles: library.records.map(\.bundleURL)
            )
            selection = nil
```

New:

```swift
        let commandHome = record.config.kind == .cli && removeData ? dataFolderDeletionOption(for: record) : nil
        do {
            var trashed = try builder.delete(
                record: record, removeData: removeData,
                libraryFolders: settings.allLibraryFolders, otherRecordDataPaths: dataPathsInUse(excluding: record.bundleURL),
                shortcutBundles: library.records.map(\.bundleURL)
            )
            if case .available(let folder, _) = commandHome {
                // The shortcut is already in the Trash here, so a failure must not read as "could not delete shortcut".
                do {
                    var resulting: NSURL?
                    try FileManager.default.trashItem(at: folder, resultingItemURL: &resulting)
                    trashed.append((resulting as URL?) ?? folder)
                } catch {
                    pendingError = AppError(
                        context: "Could not remove the command's HOME folder",
                        message: "The shortcut was moved to the Trash, but its HOME folder at \(folder.path) could not be. \(error.localizedDescription)"
                    )
                }
            }
            selection = nil
```

- [ ] **Step 15: Build and run the suite.** `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh 2>&1 | tail -4` — `** TEST SUCCEEDED **`.

- [ ] **Step 16: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add App/Sources/Views/EditorSections.swift App/Sources/Views/ShortcutEditorView.swift App/Sources/Views/ShortcutRowView.swift App/Sources/Views/DeleteShortcutSheet.swift App/Sources/App/AppState.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Edit, list and delete launcher shortcuts

The editor shows a File or Command section, the library row shows the item
or executable (red Item missing when gone), and delete offers to trash a
command's own HOME folder only when it has one.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 17: Known limitations, README, acceptance, version.**
  1. `App/Sources/App/KnownLimitations.swift` (line numbers at HEAD `8631c10`). First the doc comment (lines 9–13):

Old:

```swift
/// profiles, manual updates from one host, sandboxed badges, numbered slugs, export's Trash replacement). Phase 4 adds
/// the four web app limits (passkeys, zoom storage, notification permission, pop-up and off-site links). Shown in the
/// Known Limitations window and linked from the wizard's compatibility line.
```

New:

```swift
/// profiles, manual updates from one host, sandboxed badges, numbered slugs, export's Trash replacement). Phase 4 adds
/// the four web app limits (passkeys, zoom storage, notification permission, pop-up and off-site links). Phase 5 adds
/// the four launcher limits (terminal AppleScript, no running state for files or commands, Ghostty path). Shown in the
/// Known Limitations window and linked from the wizard's compatibility line.
```

Then the four entries, after the `web-popup-policy` entry (lines 131–135):

Old (the end of the `web-popup-policy` entry and of the file):

```swift
        ),
    ]
}
```

New (the entries are appended after the existing last one):

```swift
        ),
        KnownLimitation(
            id: "cli-terminal-applescript",
            title: "Commands in Terminal or iTerm2 need Automation permission",
            detail: "A command shortcut that runs in Terminal or iTerm2 drives that app through AppleScript, so macOS asks once to let the shortcut control it, and the command does not start until you allow it."
        ),
        KnownLimitation(
            id: "file-no-running-state",
            title: "File and folder shortcuts do not show a running state",
            detail: "A file or folder shortcut hands the item to Finder or its opener app and quits, so its Dock icon never shows a running indicator."
        ),
        KnownLimitation(
            id: "cli-no-running-state",
            title: "Command shortcuts do not track the command",
            detail: "A command shortcut starts the command in a terminal or in the background and quits, so its Dock icon does not show whether the command is still running."
        ),
        KnownLimitation(
            id: "cli-ghostty-path",
            title: "Ghostty commands start in Ghostty's own environment",
            detail: "A command sent to Ghostty runs with the PATH and shell setup of the Ghostty window it opens, not the shortcut's environment, so a program that is not on that PATH needs its full path."
        ),
    ]
}
```

     The entry count is now 28, so the existing test must change with it. In `App/Tests/App/KnownLimitationsTests.swift` (line 97 asserts `24`, which fails once the four entries exist):

Old:

```swift
    /// Phase 4 (web apps): the four web limits are present with their prescribed ids and titles, the earlier 20 are
    /// kept (24 in all), ids stay unique, and each entry states its point.
```

New:

```swift
    /// Phase 4 (web apps): the four web limits are present with their prescribed ids and titles, the earlier 20 are
    /// kept (28 in all with Phase 5's four), ids stay unique, and each entry states its point.
```

Old:

```swift
        XCTAssertEqual(ids.count, 24, "20 earlier entries plus the four web entries")
```

New:

```swift
        XCTAssertEqual(ids.count, 28, "20 earlier entries plus the four web entries plus the four launcher entries")
```

Then add the Phase 5 test at the end of the class:

Old:

```swift
            ("web-popup-policy", "Web apps open other sites in your browser", ["Also open in app", "pop-up", "mailto:"]),
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

New:

```swift
            ("web-popup-policy", "Web apps open other sites in your browser", ["Also open in app", "pop-up", "mailto:"]),
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

    /// Phase 5 (launchers): the four launcher limits are present with their prescribed ids and titles, and each states its point.
    func testPhase5LauncherEntriesStateTheirPoint() throws {
        let topics: [(id: String, title: String, mentions: [String])] = [
            ("cli-terminal-applescript", "Commands in Terminal or iTerm2 need Automation permission", ["AppleScript", "allow"]),
            ("file-no-running-state", "File and folder shortcuts do not show a running state", ["Finder", "running indicator"]),
            ("cli-no-running-state", "Command shortcuts do not track the command", ["background", "Dock icon"]),
            ("cli-ghostty-path", "Ghostty commands start in Ghostty's own environment", ["PATH", "full path"]),
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

  2. `README.md` (line numbers at HEAD `8631c10`): insert the section below between the `Acceptance checklist: \`docs/acceptance/phase4-webshell.md\`.` line (line 128) and `## Core API used by the app` (line 130), keeping one blank line on each side:

```markdown
## Phase 5 launchers

New Shortcut also makes shortcuts that are not apps:

- **File or Folder** opens a document or folder from the Dock with the shortcut's own name and icon. A folder opens in Finder; a file opens in its default app or in an app you choose under Open with.
- **Command** runs a program or script with one argument per line (spaces and quotes are passed as typed), an optional working directory, and a choice of Terminal, iTerm2, Ghostty or no terminal (run in background). In the background it can get its own HOME under `~/Library/Application Support/App Duplicator/<slug>`, so its dotfiles stay apart from yours.

The default icon is the item's or the program's Finder icon. Diagnostics shows the item, opener, terminal, working directory, own HOME and the masked command line. The library row shows Item missing in red when the item or program is gone. Deleting never touches the item or program; a command's own HOME folder is offered for the Trash only when it has one. Commands in Terminal or iTerm2 ask once for Automation permission (see Known Limitations).

Acceptance checklist: docs/acceptance/phase5-launchers.md
```

  3. `App/project.yml` (lines 56–57):

Old:

```yaml
        CURRENT_PROJECT_VERSION: "3"
        MARKETING_VERSION: "0.4.0"
```

New:

```yaml
        CURRENT_PROJECT_VERSION: "4"
        MARKETING_VERSION: "0.5.0"
```

  4. Create `docs/acceptance/phase5-launchers.md`:

```markdown
# Phase 5 acceptance: launchers

Manual checks for file, folder and command shortcuts on a real Mac. Run them in order on a build of this commit. Every shortcut made here is moved to the Trash at the end; nothing is deleted outright.

## Preconditions

- macOS 26 on Apple silicon, signed in to a normal user account.
- A test folder `~/Desktop/AD Phase 5` containing a folder `Projects`, a text file `notes.txt`, and an executable script `args.sh` with:
  `#!/bin/sh` / `for a in "$@"; do printf '[%s]\n' "$a"; done; echo "HOME=$HOME"; echo "MAD_SHORTCUT_NAME=$MAD_SHORTCUT_NAME"; read -r _`
  (`chmod +x args.sh`).
- TextEdit installed (it is part of macOS). iTerm2 is optional; Step 5 is skipped without it.
- Note the modification time of `~/.zshrc` (or any dotfile in your HOME) before Step 6: `stat -f %m ~/.zshrc`.

## Step 1: Build

- [ ] **1.1** `Tools/build-app.sh --configuration Release` succeeds.
- [ ] **1.2** About App Duplicator shows `Version 0.5.0 (4)`.

## Step 2: Folder shortcut

- [ ] **2.1** New Shortcut → File or Folder → Choose… → `Projects`. The Kind row shows Folder; Next suggests the name `Projects`.
- [ ] **2.2** Create. The shortcut appears under Files and Folders with the subtitle `Projects`.
- [ ] **2.3** Launch it from the Dock: Finder opens `Projects`, and the Dock shows the shortcut's own icon and name while it opens.

## Step 3: File shortcut with an explicit opener

- [ ] **3.1** New Shortcut → File or Folder → Choose… → `notes.txt`; Open with → Choose… → TextEdit. Review shows File, Open with `TextEdit`.
- [ ] **3.2** Create and launch: `notes.txt` opens in TextEdit (not the default app if it differs).
- [ ] **3.3** Edit the shortcut: Open with → Use Default, Save, launch: the file opens in its default app.

## Step 4: Command in Terminal with spaces and quotes

- [ ] **4.1** New Shortcut → Command → Choose… → `args.sh`. Arguments, one per line: `two words`, `"quoted"`, `it's`. Terminal: Terminal.
- [ ] **4.2** Create and launch. macOS asks once to let the shortcut control Terminal; allow it.
- [ ] **4.3** Terminal prints `[two words]`, `["quoted"]`, `[it's]` on three lines, `HOME=` your real HOME, and `MAD_SHORTCUT_NAME=` the shortcut's name (the shortcut's environment is written inline into the new shell, so it must show up here).

## Step 5: Command in iTerm2 (skip without iTerm2)

- [ ] **5.1** Duplicate the Step 4 shortcut, set Terminal to iTerm2, Save, launch. Allow the Automation prompt.
- [ ] **5.2** iTerm2 prints the same three bracketed lines, the real HOME and `MAD_SHORTCUT_NAME=` the shortcut's name.

## Step 6: Background command with its own HOME

- [ ] **6.1** New Shortcut → Command → `args.sh`, no arguments, Terminal: No terminal (run in background). On the Data step turn on Give this command its own HOME; the caption shows `~/Library/Application Support/App Duplicator/<slug>`.
- [ ] **6.2** Create and launch. `~/Library/Application Support/App Duplicator/<slug>` now exists.
- [ ] **6.3** `stat -f %m ~/.zshrc` shows the same time as before: the real HOME is untouched.

## Step 7: Diagnostics

- [ ] **7.1** Diagnostics for the Step 3 shortcut shows Kind File, Item, Open with.
- [ ] **7.2** Diagnostics for the Step 6 shortcut shows Kind Command, Terminal `No terminal (run in background)`, Working directory `Default`, Own HOME with the path, and the command line. Copy Report contains the same lines.
- [ ] **7.3** Add an argument `--token` / `secret123` to a command, Save, open Diagnostics: the command line shows `--token ••••••`, and the copied report does not contain `secret123`.

## Step 8: Duplicate, regenerate, delete

- [ ] **8.1** Duplicate the Step 2 shortcut: the copy has a new name and slug and opens the same folder.
- [ ] **8.2** Regenerate the Step 3 shortcut: it still opens `notes.txt` in its opener; Diagnostics shows the current engine version.
- [ ] **8.3** Rename `notes.txt` in Finder: the Step 3 row shows Item missing in red. Rename it back: the row returns to normal after a rescan.
- [ ] **8.4** Delete the Step 2 shortcut: the sheet shows no data-folder toggle, and `Projects` is untouched.
- [ ] **8.5** Delete the Step 6 shortcut with Also move the command's own HOME folder to the Trash on: the shortcut and `~/Library/Application Support/App Duplicator/<slug>` are both in the Trash.
- [ ] **8.6** Delete the Step 4 shortcut: no HOME toggle is shown, and `args.sh` is untouched.

## Teardown

- Move every remaining Phase 5 shortcut and `~/Desktop/AD Phase 5` to the Trash. Do not empty the Trash as part of this checklist.
- Optionally remove the Automation grants in System Settings → Privacy & Security → Automation.

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
| 8 | | | |
```

- [ ] **Step 18: Run the full suite and build.** `cd ~/Developer/MacAppDuplicator && Tools/test-app.sh 2>&1 | tail -4` — `** TEST SUCCEEDED **`; `Tools/build-app.sh --configuration Release 2>&1 | tail -2` — `** BUILD SUCCEEDED **`.

- [ ] **Step 19: Commit.**

```bash
cd ~/Developer/MacAppDuplicator && git add App/Sources/App/KnownLimitations.swift App/Tests/App/KnownLimitationsTests.swift README.md App/project.yml docs/acceptance/phase5-launchers.md && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Document Phase 5 launchers and bump to 0.5.0 (4)

Known limitations for terminal AppleScript, running state and Ghostty, a
README section and the Phase 5 acceptance checklist.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

