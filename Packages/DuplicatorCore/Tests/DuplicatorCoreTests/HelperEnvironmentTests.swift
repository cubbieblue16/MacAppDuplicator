import XCTest
@testable import DuplicatorCore

final class HelperEnvironmentTests: XCTestCase {
    private let realHome = "/Users/mike"
    private let dataHome = "/Users/mike/Library/Application Support/App Duplicator/claude-work/mike"
    private let bundle = "/Users/mike/Applications/App Duplicator/Claude Work.app"

    func testTheHelperKeepsTheRealHomeAndCarriesTheShortcutMarker() {
        let base = ["HOME": realHome, "PATH": "/usr/bin:/bin", "USER": "mike"]
        let shortcut = [
            "HOME": dataHome, "CFFIXED_USER_HOME": dataHome, "PATH": "/opt/bin:/usr/bin:/bin", "USER": "mike",
            "MAD_SHORTCUT_BUNDLE": bundle, "MAD_SHORTCUT_NAME": "Claude Work", "API_TOKEN": "not-a-real-token",
        ]
        XCTAssertEqual(HelperEnvironment.helperEnvironment(shortcut: shortcut, base: base), [
            "HOME": realHome, "PATH": "/opt/bin:/usr/bin:/bin", "USER": "mike",
            "MAD_SHORTCUT_BUNDLE": bundle, "MAD_SHORTCUT_NAME": "Claude Work", "API_TOKEN": "not-a-real-token",
            "MAD_HELPER_TARGET_HOME": dataHome, "MAD_HELPER_TARGET_CFFIXED_USER_HOME": dataHome,
        ])
    }

    func testTheTargetEnvironmentIsTheShortcutEnvironmentAgain() {
        let cases: [(base: [String: String], shortcut: [String: String])] = [
            (["HOME": realHome], ["HOME": dataHome, "CFFIXED_USER_HOME": dataHome, "MAD_SHORTCUT_BUNDLE": bundle]),
            (["HOME": realHome], ["HOME": realHome, "MAD_SHORTCUT_BUNDLE": bundle]),
            (["HOME": "/tmp/home", "CFFIXED_USER_HOME": "/tmp/home"], ["HOME": dataHome, "CFFIXED_USER_HOME": dataHome]),
            ([:], ["PATH": "/usr/bin"]),
        ]
        for (base, shortcut) in cases {
            let helper = HelperEnvironment.helperEnvironment(shortcut: shortcut, base: base)
            XCTAssertEqual(helper["HOME"], base["HOME"])
            XCTAssertEqual(helper["CFFIXED_USER_HOME"], base["CFFIXED_USER_HOME"])
            XCTAssertEqual(HelperEnvironment.targetEnvironment(helper: helper), shortcut)
        }
    }

    func testStashKeysThatDidNotComeFromTheHelperAreDropped() {
        let shortcut = ["MAD_HELPER_TARGET_HOME": "/stray", "PATH": "/usr/bin"]
        let helper = HelperEnvironment.helperEnvironment(shortcut: shortcut, base: ["HOME": realHome])
        XCTAssertEqual(helper, ["HOME": realHome, "PATH": "/usr/bin"])
        XCTAssertEqual(HelperEnvironment.targetEnvironment(helper: helper), ["PATH": "/usr/bin"])
    }
}
