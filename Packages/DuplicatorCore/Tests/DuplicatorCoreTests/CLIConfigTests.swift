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

    // MARK: Control characters (C5)

    func testDecodingRefusesControlCharactersInExecutableArgumentsAndWorkingDirectory() throws {
        let cases: [[String: Any]] = [
            ["executablePath": "/bin/ls\u{03}"],
            ["executablePath": "/bin/ls", "arguments": ["ok", "a\nb"]],
            ["executablePath": "/bin/ls", "arguments": ["tab\there"]],
            ["executablePath": "/bin/ls", "workingDirectory": "/tmp\u{7F}"],
        ]
        for dictionary in cases {
            let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
            XCTAssertThrowsError(try PropertyListDecoder().decode(CLIConfig.self, from: data), "\(dictionary)") { error in
                guard case DecodingError.dataCorrupted = error else { return XCTFail("expected dataCorrupted, got \(error)") }
            }
        }
    }

    func testDecodingKeepsOrdinaryPunctuationAndNonASCIIText() throws {
        let dictionary: [String: Any] = ["executablePath": "/bin/echo", "arguments": ["it's", "\\';x;#", "caf\u{E9} \u{1F600}"], "workingDirectory": "/tmp/dir name"]
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        XCTAssertEqual(try PropertyListDecoder().decode(CLIConfig.self, from: data).arguments.count, 3)
    }

    func testControlCharacterProblemAndEnvironmentCheck() {
        XCTAssertNil(CLIConfig(executablePath: "/bin/ls", arguments: ["-l"], workingDirectory: "/tmp").controlCharacterProblem)
        XCTAssertNotNil(CLIConfig(executablePath: "/bin/ls\u{1B}").controlCharacterProblem)
        XCTAssertNotNil(CLIConfig(executablePath: "/bin/ls", arguments: ["\u{0}"]).controlCharacterProblem)
        XCTAssertNotNil(CLIConfig(executablePath: "/bin/ls", workingDirectory: "/t\rmp").controlCharacterProblem)
        XCTAssertNil(CLIConfig.environmentControlCharacterProblem(["A": "b c"]))
        XCTAssertNotNil(CLIConfig.environmentControlCharacterProblem(["A\u{3}": "b"]))
        XCTAssertNotNil(CLIConfig.environmentControlCharacterProblem(["A": "b\n"]))
    }
}
