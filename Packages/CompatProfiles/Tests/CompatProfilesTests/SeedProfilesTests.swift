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
        for (identifier, profile) in document.apps {
            XCTAssertEqual(profile.args, [], identifier)
            XCTAssertEqual(profile.env, [:], identifier)
            XCTAssertNil(profile.newWindowCommand, identifier)
        }
    }

    func testSeedShipsThreeWebAppPresets() throws {
        let document = try seed()
        XCTAssertGreaterThanOrEqual(document.updated, "2026-10-10", "the presets bump the seed date so a cached older copy never wins")
        let presets = document.webApps
        XCTAssertEqual(Set(presets.keys), ["whatsapp", "teams", "outlook"])

        let whatsapp = try XCTUnwrap(presets["whatsapp"])
        XCTAssertEqual(whatsapp.name, "WhatsApp")
        XCTAssertEqual(whatsapp.url, "https://web.whatsapp.com")
        XCTAssertEqual(whatsapp.userAgent, "chrome")
        XCTAssertEqual(whatsapp.badgeRegex, #"\((\d+)\)"#)
        XCTAssertEqual(whatsapp.extraHosts, ["whatsapp.com", "whatsapp.net"])

        let teams = try XCTUnwrap(presets["teams"])
        XCTAssertEqual(teams.name, "Microsoft Teams")
        XCTAssertEqual(teams.url, "https://teams.microsoft.com")
        XCTAssertEqual(teams.extraHosts, ["microsoft.com", "microsoftonline.com", "live.com", "office.com", "office.net", "skype.com"])

        let outlook = try XCTUnwrap(presets["outlook"])
        XCTAssertEqual(outlook.name, "Microsoft Outlook")
        XCTAssertEqual(outlook.url, "https://outlook.office.com/mail/")
        XCTAssertEqual(outlook.extraHosts, ["office.com", "office365.com", "microsoft.com", "microsoftonline.com", "live.com", "office.net"])

        for (key, preset) in presets {
            XCTAssertNil(preset.iconURL, "\(key): icons are fetched from the site")
            XCTAssertNoThrow(try WebAppURLValidator.validate(preset.url), key)
        }
        let parser = BadgeTitleParser(pattern: whatsapp.badgeRegex)
        XCTAssertFalse(parser.usedFallbackPattern)
        XCTAssertEqual(parser.count(in: "(3) WhatsApp"), 3)
    }

    func testSeedPresetHostsMatchThePinTable() throws {
        // The pin table in ProfilesDocument must track the bundled seed, or the seed would fail its own validation.
        let seeded = try seed().webApps
        for (id, host) in ProfilesDocument.pinnedWebAppHosts {
            let seededHost = seeded[id].flatMap { URLComponents(string: $0.url)?.host?.lowercased() }
            XCTAssertEqual(seededHost, host, id)
        }
    }
}
