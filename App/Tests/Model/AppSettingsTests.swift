import CompatProfiles
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

@MainActor
final class AppSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    // Async overrides run on the main actor, so they can touch the class's main-actor state (final review M19).
    override func setUp() async throws {
        (defaults, suite) = makeTestDefaults()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
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

    func testHomeSymlinkEntriesMustBeSingleNewNames() {
        XCTAssertNil(HomeSymlinkEntry.problem(with: ".aws", existing: [".ssh"]))
        XCTAssertNil(HomeSymlinkEntry.problem(with: "  .aws ", existing: []), "surrounding spaces are trimmed")
        XCTAssertEqual(HomeSymlinkEntry.normalized("  .aws "), ".aws")
        for invalid in ["", "   ", ".", "..", "Library/Keychains", "../escape", "/etc"] {
            XCTAssertNotNil(HomeSymlinkEntry.problem(with: invalid, existing: []), invalid)
        }
        XCTAssertNotNil(HomeSymlinkEntry.problem(with: ".SSH", existing: [".ssh"]), "duplicates match case-insensitively")
        for entry in HomeTreeBuilder.defaultSymlinkEntries {
            XCTAssertNil(HomeSymlinkEntry.problem(with: entry, existing: []), "every default entry is valid: \(entry)")
        }
    }

    func testAllLibraryFoldersDeduplicatesOutputFolder() throws {
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: "Ad-hoc")
        settings.libraryFolders = [settings.outputFolder]
        XCTAssertEqual(settings.allLibraryFolders.count, 1)
    }

    // MARK: Default signing identity loaded after launch (final review M15)

    func testAppliedDefaultIdentityIsUsedButNotPersisted() {
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        settings.applyDefaultSigningIdentity("Developer ID Application: Test (TEAMID)")
        XCTAssertEqual(settings.signingIdentity, "Developer ID Application: Test (TEAMID)")
        XCTAssertEqual(settings.signerIdentity, "Developer ID Application: Test (TEAMID)")

        let relaunched = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        XCTAssertEqual(relaunched.signingIdentity, AppSettings.adHocIdentityName, "a computed default is never stored as a choice")

        settings.signingIdentity = "Apple Development: Test (DEVTEAM)"
        let afterChoice = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        XCTAssertEqual(afterChoice.signingIdentity, "Apple Development: Test (DEVTEAM)", "a user choice still writes through")
    }

    func testAppliedDefaultNeverReplacesAChosenIdentity() {
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        // The user picks an identity in Settings before the launch-time load finishes.
        settings.signingIdentity = "Apple Development: Test (DEVTEAM)"
        settings.applyDefaultSigningIdentity("Developer ID Application: Test (TEAMID)")
        XCTAssertEqual(settings.signingIdentity, "Apple Development: Test (DEVTEAM)")

        let relaunched = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        relaunched.applyDefaultSigningIdentity("Developer ID Application: Test (TEAMID)")
        XCTAssertEqual(relaunched.signingIdentity, "Apple Development: Test (DEVTEAM)", "a stored choice wins on later launches")
    }

    func testLoadDefaultSigningIdentityRunsTheLoaderOffTheMainThread() async {
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        // The stub never spawns `security`. It returns the Developer ID identity only when it runs off the main thread,
        // so a loader run on the main thread leaves the ad hoc default in place and fails the assertion.
        await settings.loadDefaultSigningIdentity {
            Thread.isMainThread ? [] : ["Apple Development: Test (DEVTEAM)", "Developer ID Application: Test (TEAMID)"]
        }
        XCTAssertEqual(settings.signingIdentity, "Developer ID Application: Test (TEAMID)")
        let relaunched = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        XCTAssertEqual(relaunched.signingIdentity, AppSettings.adHocIdentityName)
    }

    func testLoadDefaultSigningIdentityFallsBackToAdHoc() async {
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        await settings.loadDefaultSigningIdentity { ["Apple Development: Test (DEVTEAM)"] }
        XCTAssertEqual(settings.signingIdentity, AppSettings.adHocIdentityName)
        XCTAssertNil(settings.signerIdentity)
    }

    func testProfilesURLDefaultsToTheConstantAndPersistsAChoice() {
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        XCTAssertEqual(settings.profilesURLString, ProfilesConstants.defaultURLString)
        XCTAssertEqual(settings.profilesURL?.absoluteString, ProfilesConstants.defaultURLString)
        let fork = "https://raw.githubusercontent.com/example/fork/main/profiles.json"
        settings.profilesURLString = fork
        XCTAssertEqual(AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName).profilesURLString, fork)
        settings.profilesURLString = ProfilesConstants.defaultURLString
        XCTAssertNil(defaults.object(forKey: "profilesURLString"), "the default is not stored, so a later default still applies")
    }

    func testProfilesURLIsNilUnlessItIsAnAllowedAddress() {
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        settings.profilesURLString = "  \(ProfilesConstants.defaultURLString)\n"
        XCTAssertEqual(settings.profilesURL?.absoluteString, ProfilesConstants.defaultURLString, "surrounding whitespace is ignored")
        for refused in ["http://raw.githubusercontent.com/example/fork/main/profiles.json",
                        "https://example.com/profiles.json", "", "not a url"] {
            settings.profilesURLString = refused
            XCTAssertNil(settings.profilesURL, refused)
        }
    }
}
