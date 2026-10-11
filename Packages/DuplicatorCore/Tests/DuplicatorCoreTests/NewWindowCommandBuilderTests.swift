import XCTest
@testable import DuplicatorCore

final class NewWindowCommandBuilderTests: XCTestCase {
    private let dataPath = "/Users/me/Library/Application Support/App Duplicator/chrome-work"

    func testSplitsFirstThenSubstitutesSoPathsWithSpacesStayOneArgument() {
        let argv = NewWindowCommandBuilder.argv(
            template: "/usr/bin/open -na {target} --args --user-data-dir={dataPath}",
            targetPath: "/Applications/Google Chrome.app",
            targetBundleIdentifier: "com.google.Chrome",
            dataPath: dataPath
        )
        XCTAssertEqual(argv, [
            "/usr/bin/open", "-na", "/Applications/Google Chrome.app", "--args",
            "--user-data-dir=/Users/me/Library/Application Support/App Duplicator/chrome-work",
        ])
    }

    func testARelativeProgramRunsThroughUsrBinEnv() {
        let argv = NewWindowCommandBuilder.argv(
            template: "  open\t-n -b {bundleId}  ",
            targetPath: "/Applications/Example.app",
            targetBundleIdentifier: "com.example.app",
            dataPath: nil
        )
        XCTAssertEqual(argv, ["/usr/bin/env", "open", "-n", "-b", "com.example.app"])
    }

    func testNilOrBlankTemplatesAndAMissingDataPathProduceNoCommand() {
        for template in [nil, "", "  \t "] as [String?] {
            XCTAssertNil(NewWindowCommandBuilder.argv(
                template: template, targetPath: "/A.app", targetBundleIdentifier: "com.example.a", dataPath: dataPath))
        }
        XCTAssertNil(NewWindowCommandBuilder.argv(
            template: "/usr/bin/open -na {target} --args --user-data-dir={dataPath}",
            targetPath: "/A.app", targetBundleIdentifier: "com.example.a", dataPath: nil))
    }

    func testUnknownPlaceholdersStayLiteralAndSubstitutedValuesAreNotRescanned() {
        let argv = NewWindowCommandBuilder.argv(
            template: "/bin/echo {name} {target} {{bundleId}} {bundleId",
            targetPath: "/Apps/{bundleId}.app",
            targetBundleIdentifier: "com.example.a",
            dataPath: nil
        )
        XCTAssertEqual(argv, ["/bin/echo", "{name}", "/Apps/{bundleId}.app", "{com.example.a}", "{bundleId"])
    }

    func testValidationRefusesOverlongTemplatesAndControlCharacters() {
        XCTAssertNil(NewWindowCommandBuilder.validationMessage(for: nil))
        XCTAssertNil(NewWindowCommandBuilder.validationMessage(for: ""))
        XCTAssertNil(NewWindowCommandBuilder.validationMessage(for: "open -na {target}\t--args"))
        XCTAssertNil(NewWindowCommandBuilder.validationMessage(for: String(repeating: "a", count: 2_048)))
        XCTAssertEqual(NewWindowCommandBuilder.validationMessage(for: String(repeating: "a", count: 2_049)),
                       "The New Window command is longer than 2048 characters.")
        for template in ["open\u{0}-na", "open\n-na", "open\u{1B}[0m", "open\u{7F}"] {
            XCTAssertEqual(NewWindowCommandBuilder.validationMessage(for: template),
                           "The New Window command may not contain control characters.", template.debugDescription)
        }
    }
}
