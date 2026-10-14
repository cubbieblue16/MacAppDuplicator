import CompatProfiles
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class ProfileSummaryTests: XCTestCase {
    func testRowsShowEveryFieldWithProfileValuesInFull() {
        let profile = AppProfile(name: "Target", status: .partial, family: .electron,
                                 args: ["--api-key", "hunter2", "--plain"], env: ["PLAIN": "ok", "API_TOKEN": "leaked"],
                                 notes: "Opens one window per data folder.")
        let rows = ProfileSummary.rows(for: profile, detectedFamily: .native, maskProfileValues: false)
        XCTAssertEqual(rows.map(\.label), ["Name", "Status", "Family", "Arguments", "Environment", "Notes", "Family note"])
        XCTAssertEqual(rows.map(\.value), [
            "Target",
            "Partial",
            "Electron",
            "--api-key hunter2 --plain",
            "API_TOKEN=leaked PLAIN=ok",
            "Opens one window per data folder.",
            "The profile lists family Electron but App Duplicator detected Native; launch settings follow the detected family.",
        ])
        XCTAssertEqual(ProfileSummary.profileValuesCaption, "Values from the compatibility profile are shown in full.")
    }

    func testRowsMaskProfileValuesByDefault() {
        let profile = AppProfile(name: "Target", status: .partial, args: ["--api-key", "hunter2"], env: ["API_TOKEN": "leaked"])
        let rows = ProfileSummary.rows(for: profile, detectedFamily: nil)
        for row in rows {
            XCTAssertFalse(row.value.contains("hunter2"), row.label)
            XCTAssertFalse(row.value.contains("leaked"), row.label)
        }
    }

    func testRowsShowAttackerChosenKeyNamesThatSecretMaskingWouldHide() {
        let profile = AppProfile(name: "Target", status: .partial, env: ["GIT_CONFIG_KEY_0": "core.fsmonitor"])
        XCTAssertEqual(ProfileSummary.rows(for: profile, detectedFamily: nil, maskProfileValues: false).first { $0.label == "Environment" }?.value,
                       "GIT_CONFIG_KEY_0=core.fsmonitor")
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

    func testNewWindowRowIsShownInFullAndOnlyWhenPresent() throws {
        let profile = AppProfile(
            name: "Target", status: .verified, family: .native, args: [], env: [:],
            newWindowCommand: "/usr/bin/open -na {target} --args --api-key=hunter2", notes: "Sign in once."
        )
        let rows = ProfileSummary.rows(for: profile, detectedFamily: .native, maskProfileValues: false)
        let newWindow = try XCTUnwrap(rows.first { $0.label == "New Window" })
        XCTAssertEqual(newWindow.value, "/usr/bin/open -na {target} --args --api-key=hunter2")
        XCTAssertEqual(ProfileSummary.rows(for: profile, detectedFamily: .native).first { $0.label == "New Window" }?.value,
                       "/usr/bin/open -na {target} --args --api-key=\(SecretMasking.maskedValue)")
        let labels = rows.map(\.label)
        let environmentIndex = try XCTUnwrap(labels.firstIndex(of: "Environment"))
        let newWindowIndex = try XCTUnwrap(labels.firstIndex(of: "New Window"))
        let notesIndex = try XCTUnwrap(labels.firstIndex(of: "Notes"))
        XCTAssertEqual(newWindowIndex, environmentIndex + 1)
        XCTAssertEqual(notesIndex, newWindowIndex + 1)

        for template in [nil, "", "   "] as [String?] {
            let plain = AppProfile(name: "Target", status: .verified, family: .native, args: [], env: [:], newWindowCommand: template, notes: nil)
            XCTAssertFalse(
                ProfileSummary.rows(for: plain, detectedFamily: .native).contains { $0.label == "New Window" },
                String(describing: template)
            )
        }
    }

    func testDisallowedNewWindowTemplateIsReplacedByANote() throws {
        let profile = AppProfile(name: "Target", status: .verified, family: .native,
                                 newWindowCommand: "/bin/sh -c id")
        let rows = ProfileSummary.rows(for: profile, detectedFamily: .native)
        XCTAssertEqual(rows.first { $0.label == "New Window" }?.value, "Profile New Window command ignored (not allowed)")
        XCTAssertFalse(rows.contains { $0.value.contains("/bin/sh") })
    }
}
