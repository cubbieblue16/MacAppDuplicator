import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class ExportInstructionsTests: XCTestCase {
    func testShellQuotingKeepsEveryCharacterLiteral() {
        XCTAssertEqual(ExportInstructions.shellQuoted("/Users/me/Desktop/Work.app"), "'/Users/me/Desktop/Work.app'")
        XCTAssertEqual(ExportInstructions.shellQuoted("/tmp/Bob's App.app"), #"'/tmp/Bob'\''s App.app'"#)
        // Double quotes, dollar signs and backticks are inert inside single quotes.
        XCTAssertEqual(ExportInstructions.shellQuoted(#"/tmp/a"b$HOME`id`.app"#), #"'/tmp/a"b$HOME`id`.app'"#)
    }

    func testQuotedPathSurvivesARealShell() throws {
        let path = #"/tmp/It's "a" $HOME `id` test.app"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s \(ExportInstructions.shellQuoted(path))"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), path)
    }

    func testQuarantineCommandSingleQuotesThePath() {
        let url = URL(fileURLWithPath: "/Users/me/Desktop/Bob's Work.app")
        XCTAssertEqual(ExportInstructions.quarantineCommand(for: url), #"xattr -dr com.apple.quarantine '/Users/me/Desktop/Bob'\''s Work.app'"#)
    }

    func testSigningSentenceFollowsTheSignature() {
        let adHoc = ExportInstructions.signingSentence(for: .adHoc)
        XCTAssertTrue(adHoc.contains("ad-hoc"), adHoc)
        XCTAssertFalse(adHoc.contains("your identity"), adHoc)

        let named = ExportInstructions.signingSentence(for: .identity("Developer ID Application: Example (TEAM123456)"))
        XCTAssertTrue(named.contains("Developer ID Application: Example (TEAM123456)"), named)
        XCTAssertFalse(named.contains("ad-hoc"), named)

        let unknown = ExportInstructions.signingSentence(for: .unknown)
        XCTAssertFalse(unknown.contains("signed with"), unknown)
        for sentence in [adHoc, named, unknown] {
            XCTAssertTrue(sentence.contains("quarantine"), sentence)
        }
    }

    func testSecretNoticeOnlyWhenAKeyLooksSecret() throws {
        XCTAssertNil(ExportInstructions.secretNotice(for: [:]))
        XCTAssertNil(ExportInstructions.secretNotice(for: ["PLAIN": "ok", "LANG": "en_US.UTF-8"]))
        let notice = try XCTUnwrap(ExportInstructions.secretNotice(for: ["PLAIN": "ok", "GITHUB_TOKEN": "hunter2", "api_key": "x"]))
        XCTAssertTrue(notice.contains("plain text"), notice)
        XCTAssertTrue(notice.contains("GITHUB_TOKEN"), notice)
        XCTAssertTrue(notice.contains("api_key"), notice)
        XCTAssertFalse(notice.contains("hunter2"), notice)
        XCTAssertFalse(notice.contains("PLAIN"), notice)
        XCTAssertFalse(notice.contains("\n"), notice)
    }

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
}
