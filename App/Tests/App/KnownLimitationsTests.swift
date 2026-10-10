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
    /// The web-shell bullet (no passkeys) waits for the web shell phase.
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
}
