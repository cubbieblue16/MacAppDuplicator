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
