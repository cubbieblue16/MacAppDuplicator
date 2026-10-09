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
