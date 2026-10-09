import XCTest
@testable import DuplicatorCore

final class EnumsTests: XCTestCase {
    func testRawValuesAreTheSpellingsStoredInMADConfig() {
        XCTAssertEqual([ShortcutKind.app, .webApp, .file, .folder, .cli].map(\.rawValue), ["app", "webApp", "file", "folder", "cli"])
        XCTAssertEqual([LaunchMode.dockShortcut, .systemLaunch].map(\.rawValue), ["dockShortcut", "systemLaunch"])
        XCTAssertEqual([DataMode.auto, .homeOverride, .disabled].map(\.rawValue), ["auto", "homeOverride", "disabled"])
        XCTAssertEqual([Appearance.system, .light, .dark].map(\.rawValue), ["system", "light", "dark"])
        XCTAssertEqual(
            [AppFamily.todesktop, .electron, .chromium, .firefox, .eclipse, .native].map(\.rawValue),
            ["todesktop", "electron", "chromium", "firefox", "eclipse", "native"]
        )
    }

    func testEnumsRoundTripThroughPropertyListCoding() throws {
        struct Sample: Codable, Equatable {
            var kind: ShortcutKind
            var launchMode: LaunchMode
            var dataMode: DataMode
            var appearance: Appearance
            var family: AppFamily
        }
        let sample = Sample(kind: .webApp, launchMode: .systemLaunch, dataMode: .homeOverride, appearance: .dark, family: .todesktop)
        let data = try PropertyListEncoder().encode(sample)
        XCTAssertEqual(try PropertyListDecoder().decode(Sample.self, from: data), sample)
    }
}
