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
