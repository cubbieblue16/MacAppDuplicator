import CompatProfiles
import XCTest
@testable import MacAppDuplicator

final class KnownLimitationsTests: XCTestCase {
    func testEntriesAreUniqueAndNonEmpty() {
        let ids = KnownLimitations.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertGreaterThanOrEqual(KnownLimitations.all.count, 6)
        for item in KnownLimitations.all {
            XCTAssertFalse(item.title.isEmpty)
            XCTAssertFalse(item.detail.isEmpty)
        }
    }

    /// The ids the Phase 2 plan prescribes. Spec §11 coverage is asserted by `testCoversEverySpecSection11Topic`.
    func testKeepsEveryEntryThePlanPrescribes() {
        let ids = Set(KnownLimitations.all.map(\.id))
        for required in ["launch-constraints", "sandboxed-apps", "single-instance", "dock-redraw", "login-items", "updates", "notifications", "file-associations"] {
            XCTAssertTrue(ids.contains(required), "missing \(required)")
        }
    }

    /// Spec §11 is "documented in-app and README": one entry per §11 bullet, each stating that bullet's point.
    /// The web-shell bullet (no passkeys) is `web-no-passkeys`, asserted in `testPhase4WebEntriesStateTheirPoint`.
    func testCoversEverySpecSection11Topic() throws {
        let topics: [(topic: String, id: String, mentions: String)] = [
            ("target Dock badges replace the shortcut's icon", "dock-redraw", "badge"),
            ("the Dock title can only be the bundle file name", "dock-title", "file name"),
            ("Apple platform binaries cannot use Dock Shortcut", "launch-constraints", "System Launch"),
            ("CFPreferences are shared in every data mode", "preferences", "~/Library/Preferences"),
            ("no dark override outside Chromium/Electron", "electron-dark-mode", "--force-dark-mode"),
            ("Disabled-mode launch-order handoff", "launch-order", "Disabled"),
            ("OAuth callbacks go to the instance that registered last", "oauth-callbacks", "registered"),
            ("push-notification clicks may front the wrong instance", "notifications", "wrong copy"),
            ("HOME override gives no separate Keychain or macOS user", "keychain", "Keychain"),
            ("sandboxed apps stay in their system container", "sandboxed-apps", "container"),
        ]
        let byID = Dictionary(KnownLimitations.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for topic in topics {
            let entry = try XCTUnwrap(byID[topic.id], "no entry for spec §11 topic: \(topic.topic)")
            XCTAssertTrue("\(entry.title) \(entry.detail)".contains(topic.mentions), "\(topic.id) does not mention \"\(topic.mentions)\"")
        }
    }

    /// Spec §11: links for the target's URL schemes reach whichever running instance registered the scheme last, so the
    /// entry must not promise that documents and links always open in the original app.
    func testFileAssociationsMatchesSpecURLRouting() throws {
        let entry = try XCTUnwrap(KnownLimitations.all.first { $0.id == "file-associations" })
        XCTAssertFalse(entry.detail.contains("keep opening in the original app"))
        XCTAssertTrue(entry.detail.contains("registered"))
    }

    /// Phase 3 (profiles): every profile-era limit is present, the Phase 2 entries are kept (14 + 6), ids stay unique and
    /// no entry is blank once whitespace is trimmed.
    func testKeepsEveryPhase3EntryThePlanPrescribes() {
        let ids = KnownLimitations.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate known-limitation ids")
        XCTAssertGreaterThanOrEqual(ids.count, 20)
        for required in ["profiles-advisory", "profiles-partial", "profile-updates", "sandboxed-badge", "slug-suffix", "export-replaces"] {
            XCTAssertTrue(ids.contains(required), "missing \(required)")
        }
        for item in KnownLimitations.all {
            XCTAssertFalse(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(item.id) has a blank title")
            XCTAssertFalse(item.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(item.id) has a blank detail")
        }
    }

    /// Each Phase 3 entry has its prescribed title and states its point: a Verified badge is one machine's check, partial
    /// profiles need review, updates are manual from the pinned host, sandboxed native apps never get a separable badge,
    /// colliding slugs get numbered, and export moves the old bundle to the Trash.
    func testPhase3EntriesStateTheirPoint() throws {
        let topics: [(id: String, title: String, mentions: [String])] = [
            ("profiles-advisory", "Compatibility profiles are advisory", ["Verified", "one Mac", "not a guarantee"]),
            ("profiles-partial", "Partial profiles need manual review", ["partial", "check"]),
            ("profile-updates", "Check Profile Updates is manual and fetches from one host",
             [ProfilesFetchPolicy.allowedHost, "never runs automatically"]),
            ("sandboxed-badge", "Sandboxed native apps cannot be separated", ["Unknown", "Unsupported", "container"]),
            ("slug-suffix", "Shortcuts whose names match get a numbered slug", ["-2", "-3"]),
            ("export-replaces", "Export replaces an existing shortcut by moving it to the Trash", ["Trash"]),
        ]
        let byID = Dictionary(KnownLimitations.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for topic in topics {
            let entry = try XCTUnwrap(byID[topic.id], "no entry \(topic.id)")
            XCTAssertEqual(entry.title, topic.title)
            for phrase in topic.mentions {
                XCTAssertTrue("\(entry.title) \(entry.detail)".contains(phrase), "\(topic.id) does not mention \"\(phrase)\"")
            }
        }
    }

    /// Phase 4 (web apps): the four web limits are present with their prescribed ids and titles, the earlier 20 are
    /// kept (35 in all with Phase 5's five and Phase 6's six), ids stay unique, and each entry states its point.
    func testPhase4WebEntriesStateTheirPoint() throws {
        let ids = KnownLimitations.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate known-limitation ids")
        XCTAssertEqual(ids.count, 35, "20 earlier, four web, five launcher and six helper entries")
        let topics: [(id: String, title: String, mentions: [String])] = [
            ("web-no-passkeys", "Web apps do not support passkeys", ["passkey", "WebAuthn"]),
            ("web-zoom-storage", "Web app zoom is remembered outside the shortcut", ["MADPageZoom", "sealed", "preferences"]),
            ("web-notification-permission", "Web notifications are always allowed, but macOS decides whether they appear",
             ["System Settings", "granted", "reload"]),
            ("web-popup-policy", "Web apps open other sites in your browser", ["Also open in app", "pop-up", "mailto:"]),
        ]
        let byID = Dictionary(KnownLimitations.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for topic in topics {
            let entry = try XCTUnwrap(byID[topic.id], "no entry \(topic.id)")
            XCTAssertEqual(entry.title, topic.title)
            for phrase in topic.mentions {
                XCTAssertTrue("\(entry.title) \(entry.detail)".contains(phrase), "\(topic.id) does not mention \"\(phrase)\"")
            }
        }
    }

    /// Phase 5 (launchers): the five launcher limits are present with their prescribed ids and titles, and each states its point.
    func testPhase5LauncherEntriesStateTheirPoint() throws {
        let topics: [(id: String, title: String, mentions: [String])] = [
            ("cli-terminal-applescript", "Commands in Terminal or iTerm2 need Automation permission",
             ["AppleScript", "allow", "System Settings > Privacy & Security > Automation", "tccutil reset AppleEvents <bundle id>"]),
            ("cli-terminal-history", "Terminal and iTerm2 keep the command in shell history",
             ["history file", "environment values", "No terminal", "Ghostty", "from a file"]),
            ("file-no-running-state", "File and folder shortcuts do not show a running state", ["Finder", "running indicator"]),
            ("cli-no-running-state", "Command shortcuts do not track the command", ["background", "Dock icon"]),
            ("cli-ghostty-path", "Ghostty commands start in Ghostty's own environment", ["PATH", "full path"]),
        ]
        let byID = Dictionary(KnownLimitations.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for topic in topics {
            let entry = try XCTUnwrap(byID[topic.id], "no entry \(topic.id)")
            XCTAssertEqual(entry.title, topic.title)
            for phrase in topic.mentions {
                XCTAssertTrue("\(entry.title) \(entry.detail)".contains(phrase), "\(topic.id) does not mention \"\(phrase)\"")
            }
        }
    }

    /// Phase 6 (helper): the six helper limits are present with their prescribed ids and titles, and each states its
    /// point: the running indicator waits for the helper, erase on quit confirms custom folders and refuses protected
    /// ones and can be skipped, the language needs AppleLanguages, the menu bar icon is in colour, New Window needs a
    /// command, and System Launch keeps the shortcut's own process open as the helper.
    func testPhase6HelperEntriesStateTheirPoint() throws {
        let topics: [(id: String, title: String, mentions: [String])] = [
            ("helper-running-until-exit", "A shortcut with a helper stays running until the helper exits",
             ["helper", "running indicator", "Erase on quit"]),
            ("erase-custom-folder-confirm", "Erase on quit asks before emptying a folder outside App Duplicator's data folder",
             ["~/Library/Application Support/App Duplicator/", "confirm", "Trash", "always refused", "logout"]),
            ("language-applelanguages", "The language setting works only in apps that honour AppleLanguages",
             ["-AppleLanguages", "-AppleLocale", "own language setting", "system language"]),
            ("helper-colour-icon", "The menu bar icon is the shortcut's icon in full colour",
             ["template", "light or dark menu bar"]),
            ("new-window-template", "New Window needs a command",
             ["{target}", "{bundleId}", "compatibility profile", "Advanced", "{dataPath}"]),
            ("system-launch-helper", "With System Launch, the shortcut itself stays open as the helper",
             ["no Dock icon", "Activity Monitor", "forward", "skips the erase"]),
        ]
        let byID = Dictionary(KnownLimitations.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for topic in topics {
            let entry = try XCTUnwrap(byID[topic.id], "no entry \(topic.id)")
            XCTAssertEqual(entry.title, topic.title)
            for phrase in topic.mentions {
                XCTAssertTrue("\(entry.title) \(entry.detail)".contains(phrase), "\(topic.id) does not mention \"\(phrase)\"")
            }
        }
    }
}
