import CompatProfiles
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class ProfileSummaryTests: XCTestCase {
    func testRowsShowEveryFieldWithSecretsMasked() {
        let profile = AppProfile(name: "Target", status: .partial, family: .electron,
                                 args: ["--api-key", "hunter2", "--plain"], env: ["PLAIN": "ok", "API_TOKEN": "leaked"],
                                 notes: "Opens one window per data folder.")
        let rows = ProfileSummary.rows(for: profile, detectedFamily: .native)
        XCTAssertEqual(rows.map(\.label), ["Name", "Status", "Family", "Arguments", "Environment", "Notes", "Family note"])
        XCTAssertEqual(rows.map(\.value), [
            "Target",
            "Partial",
            "Electron",
            "--api-key •••••• --plain",
            "API_TOKEN=•••••• PLAIN=ok",
            "Opens one window per data folder.",
            "The profile lists family Electron but App Duplicator detected Native; launch settings follow the detected family.",
        ])
        for row in rows {
            XCTAssertFalse(row.value.contains("hunter2"), row.label)
            XCTAssertFalse(row.value.contains("leaked"), row.label)
        }
    }

    func testRowsWithoutAProfileOrWithOnlyTheRequiredFields() {
        XCTAssertEqual(ProfileSummary.rows(for: nil, detectedFamily: .native), [])
        XCTAssertEqual(ProfileSummary.rows(for: AppProfile(name: "Bare", status: .verified), detectedFamily: .electron), [
            ProfileSummary.Row(label: "Name", value: "Bare"),
            ProfileSummary.Row(label: "Status", value: "Verified"),
            ProfileSummary.Row(label: "Arguments", value: "None"),
            ProfileSummary.Row(label: "Environment", value: "None"),
        ])
        // Empty notes add no row.
        XCTAssertFalse(ProfileSummary.rows(for: AppProfile(name: "Bare", status: .partial, notes: ""), detectedFamily: nil)
            .contains { $0.label == "Notes" })
    }

    func testMatchLine() {
        let catalog = ProfileCatalog(
            document: ProfilesDocument(updated: "2026-10-09", apps: ["com.example.target": AppProfile(name: "Target", status: .verified)]),
            source: .cached
        )
        XCTAssertEqual(ProfileSummary.matchLine(bundleIdentifier: "com.example.target", catalog: catalog),
                       "com.example.target · Verified · updated 2026-10-09 · cached")
        // The catalog falls back to a case-insensitive match; the line shows the target's own identifier.
        XCTAssertEqual(ProfileSummary.matchLine(bundleIdentifier: "COM.EXAMPLE.TARGET", catalog: catalog),
                       "COM.EXAMPLE.TARGET · Verified · updated 2026-10-09 · cached")
        XCTAssertEqual(ProfileSummary.matchLine(bundleIdentifier: "com.example.other", catalog: catalog),
                       "No profile for com.example.other (profiles updated 2026-10-09, cached)")
        XCTAssertEqual(ProfileSummary.matchLine(bundleIdentifier: "com.example.target", catalog: .empty), "No profiles loaded.")
    }

    func testFamilyNoteStatusAndFamilyNames() {
        let electron = AppProfile(name: "X", status: .partial, family: .electron)
        XCTAssertNil(ProfileSummary.familyNote(profile: electron, detected: .electron))
        XCTAssertNil(ProfileSummary.familyNote(profile: electron, detected: nil))
        XCTAssertNil(ProfileSummary.familyNote(profile: AppProfile(name: "X", status: .partial), detected: .native))
        XCTAssertNil(ProfileSummary.familyNote(profile: nil, detected: .native))
        XCTAssertEqual(ProfileSummary.familyNote(profile: electron, detected: .chromium),
                       "The profile lists family Electron but App Duplicator detected Chromium; launch settings follow the detected family.")
        XCTAssertEqual(ProfileStatus.allCases.map(ProfileSummary.statusLabel), ["Verified", "Partial", "Unsupported"])
        XCTAssertEqual([AppFamily.todesktop, .electron, .chromium, .firefox, .eclipse, .native].map(ProfileSummary.familyName),
                       ["ToDesktop", "Electron", "Chromium", "Firefox", "Eclipse", "Native"])
    }
}
