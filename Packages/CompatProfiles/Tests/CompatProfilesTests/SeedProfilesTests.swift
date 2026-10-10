import DuplicatorCore
import XCTest
@testable import CompatProfiles

/// Checks the bundled seed (`Packages/CompatProfiles/Resources/profiles.json`) against spec §8 and the Global
/// Constraints. The app bundles the same file through `App/project.yml`; `SmokeTests` checks the bundled copy.
final class SeedProfilesTests: XCTestCase {
    private let seedURL = URL(filePath: #filePath)
        .deletingLastPathComponent()   // CompatProfilesTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // CompatProfiles
        .appending(path: "Resources/profiles.json", directoryHint: .notDirectory)

    private func seed() throws -> ProfilesDocument {
        try ProfilesDocument.decodeValidated(from: Data(contentsOf: seedURL))
    }

    func testSeedListsExactlyTheEighteenSpecApps() throws {
        let expected: [String: (name: String, family: AppFamily?)] = [
            "com.anthropic.claudefordesktop": ("Claude", .electron),
            "com.google.Chrome": ("Google Chrome", .chromium),
            "com.brave.Browser": ("Brave Browser", .chromium),
            "com.microsoft.edgemac": ("Microsoft Edge", .chromium),
            "org.mozilla.firefox": ("Firefox", .firefox),
            "com.microsoft.VSCode": ("Visual Studio Code", .electron),
            "com.todesktop.230313mzl4w4u92": ("Cursor", .todesktop),
            "com.tinyspeck.slackmacgap": ("Slack", .electron),
            "com.hnc.Discord": ("Discord", .electron),
            "md.obsidian": ("Obsidian", .electron),
            "tv.plex.desktop": ("Plex", nil),
            "com.spotify.client": ("Spotify", nil),
            "org.whispersystems.signal-desktop": ("Signal", .electron),
            "ru.keepcoder.Telegram": ("Telegram", .native),
            "com.mitchellh.ghostty": ("Ghostty", .native),
            "com.googlecode.iterm2": ("iTerm2", .native),
            "com.apple.Terminal": ("Terminal", .native),
            "com.apple.dt.Xcode": ("Xcode", .native),
        ]
        let apps = try seed().apps
        XCTAssertEqual(Set(apps.keys), Set(expected.keys))
        for (identifier, entry) in expected {
            XCTAssertEqual(apps[identifier]?.name, entry.name, identifier)
            XCTAssertEqual(apps[identifier]?.family, entry.family, identifier)
        }
    }

    func testClaudeIsVerifiedAndTerminalIsSystemLaunchOnly() throws {
        let apps = try seed().apps
        let verifiedKeys = apps.filter { $0.value.status == .verified }.map(\.key)
        XCTAssertTrue(verifiedKeys.contains("com.anthropic.claudefordesktop"))
        XCTAssertFalse(apps.values.contains { $0.status == .unsupported })
        XCTAssertEqual(apps["com.apple.Terminal"]?.status, .partial)
        XCTAssertEqual(apps["com.apple.Terminal"]?.notes, "Apple platform binary, System Launch only.")
        XCTAssertEqual(apps["com.anthropic.claudefordesktop"]?.notes,
                       "Each instance has its own claude_desktop_config.json inside the data folder.")
        for (identifier, profile) in apps {
            XCTAssertFalse(profile.notes?.isEmpty ?? true, "\(identifier) explains its status")
        }
    }

    func testSeedCarriesNoLaunchValuesYet() throws {
        let document = try seed()
        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertNotNil(document.updated.wholeMatch(of: /^\d{4}-\d{2}-\d{2}$/), "updated is a YYYY-MM-DD date")
        XCTAssertGreaterThanOrEqual(document.updated, "2026-10-09")
        XCTAssertTrue(document.webApps.isEmpty, "web app presets arrive with the Phase 4 web shell")
        for (identifier, profile) in document.apps {
            XCTAssertEqual(profile.args, [], identifier)
            XCTAssertEqual(profile.env, [:], identifier)
            XCTAssertNil(profile.newWindowCommand, identifier)
        }
    }
}
