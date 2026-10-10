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
