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
