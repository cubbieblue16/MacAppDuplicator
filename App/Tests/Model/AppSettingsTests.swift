import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

@MainActor
final class AppSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        (defaults, suite) = makeTestDefaults()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testDefaults() {
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: "Developer ID Application: Test (TEAMID)")
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(settings.outputFolder.standardizedFileURL, home.appending(path: "Applications/App Duplicator", directoryHint: .isDirectory).standardizedFileURL)
        XCTAssertEqual(settings.libraryFolders, [])
        XCTAssertEqual(settings.signingIdentity, "Developer ID Application: Test (TEAMID)")
        XCTAssertEqual(settings.signerIdentity, "Developer ID Application: Test (TEAMID)")
        XCTAssertEqual(settings.homeSymlinkEntries, HomeTreeBuilder.defaultSymlinkEntries)
        XCTAssertEqual(settings.allLibraryFolders, [settings.outputFolder])
    }

    func testAdHocMapsToNilSignerIdentity() {
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        XCTAssertEqual(settings.signingIdentity, "Ad-hoc")
        XCTAssertNil(settings.signerIdentity)
    }

    func testValuesPersistAcrossInstances() throws {
        let folder = try makeAppTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = AppSettings(defaults: defaults, defaultSigningIdentity: "Ad-hoc")
        first.outputFolder = folder
        first.libraryFolders = [folder.appending(path: "extra", directoryHint: .isDirectory)]
        first.signingIdentity = "Developer ID Application: Test (TEAMID)"
        first.homeSymlinkEntries = ["Desktop"]

        let second = AppSettings(defaults: defaults, defaultSigningIdentity: "Ad-hoc")
        XCTAssertEqual(second.outputFolder.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(second.libraryFolders.map(\.lastPathComponent), ["extra"])
        XCTAssertEqual(second.signingIdentity, "Developer ID Application: Test (TEAMID)")
        XCTAssertEqual(second.homeSymlinkEntries, ["Desktop"])
        XCTAssertEqual(second.allLibraryFolders.count, 2)
    }

    func testAllLibraryFoldersDeduplicatesOutputFolder() throws {
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: "Ad-hoc")
        settings.libraryFolders = [settings.outputFolder]
        XCTAssertEqual(settings.allLibraryFolders.count, 1)
    }
}
