import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

/// Shortcuts built before install tokens existed (tokenless, ad hoc, not quarantined) read as not created here under
/// ad hoc signing (C3). They get one aggregate review with Trust All and Rebuild instead of one approval each; nothing is
/// stamped or re-signed until the user chooses it.
@MainActor
final class AppStateLegacyTrustTests: XCTestCase {
    private var dir: URL!
    private var out: URL!
    private var target: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var settings: AppSettings!
    private var library: ShortcutLibrary!
    private var state: AppState!

    override func setUp() async throws {
        dir = try makeAppTemporaryDirectory()
        out = dir.appending(path: "out", directoryHint: .isDirectory)
        target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "1", in: dir)
        try FileManager.default.removeItem(at: target.appending(path: "Contents/MacOS/Target"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: target.appending(path: "Contents/MacOS/Target"))
        (defaults, suite) = makeTestDefaults()
        settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        settings.outputFolder = out
        library = ShortcutLibrary(settings: settings)
        let launcher = dir.appending(path: "Launcher")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: launcher)
        state = AppState(settings: settings, library: library, launcherBinary: launcher)
    }

    override func tearDown() async throws {
        library.stop()
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: dir)
    }

    /// A shortcut as an earlier App Duplicator left it: no install token, signed ad hoc, not quarantined.
    @discardableResult
    private func writeLegacyShortcut(named name: String, targetPath: String? = nil, engineVersion: Int = ShortcutConfig.currentEngineVersion) throws -> URL {
        var config = makeConfig(name: name, targetPath: targetPath ?? target.path)
        config.iconMode = .generated
        config.engineVersion = engineVersion
        let bundle = try writeShortcutBundle(named: name, in: out, config: config, engineVersion: engineVersion)
        try adHocSignFixture(bundle)
        return bundle
    }

    private func info(of bundle: URL) throws -> NSDictionary {
        try XCTUnwrap(NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist")))
    }

    private func infoData(of bundle: URL) throws -> Data {
        try Data(contentsOf: bundle.appending(path: "Contents/Info.plist"))
    }

    // MARK: Trust All and Rebuild

    func testTrustAllStampsEveryReviewedShortcutAndMakesItOwn() async throws {
        let first = try writeLegacyShortcut(named: "A Legacy")
        let second = try writeLegacyShortcut(named: "B Legacy")
        await library.rescan()
        XCTAssertEqual(library.legacyCandidates.map(\.name), ["A Legacy", "B Legacy"])
        let before = try [infoData(of: first), infoData(of: second)]

        await state.reviewLegacyShortcuts()
        let review = try XCTUnwrap(state.pendingLegacyTrustReview)
        XCTAssertEqual(review.approvals.map(\.record.name), ["A Legacy", "B Legacy"])
        XCTAssertEqual(review.approvals.map(\.config), library.legacyCandidates.map(\.config), "each shows its own on-disk config")
        XCTAssertEqual(review.approvals.map(\.signature), [.adHoc, .adHoc])
        XCTAssertEqual(try [infoData(of: first), infoData(of: second)], before, "opening the review writes nothing")

        let results = await state.trustLegacyShortcuts(review)

        XCTAssertEqual(results.map(\.name), ["A Legacy", "B Legacy"])
        XCTAssertEqual(results.map(\.outcome), [.rebuilt, .rebuilt])
        for bundle in [first, second] {
            XCTAssertEqual(try info(of: bundle)[ShortcutConfig.installTokenInfoPlistKey] as? String, settings.installToken)
        }
        XCTAssertEqual(library.records.map(\.provenance), [.own, .own])
        XCTAssertTrue(library.legacyCandidates.isEmpty)
        XCTAssertNil(state.rebuildProgress, "progress is cleared when Trust All ends")
        XCTAssertNil(state.pendingError, "results are reported in the sheet, not in the error alert")
        XCTAssertNotNil(state.pendingLegacyTrustReview, "the same sheet shows the results until Done")
        state.closeLegacyTrustReview()
        XCTAssertNil(state.pendingLegacyTrustReview)
    }

    func testTrustAllSkipsAShortcutQuarantinedAfterTheReview() async throws {
        let received = try writeLegacyShortcut(named: "A Received Later")
        let legacy = try writeLegacyShortcut(named: "B Legacy")
        await library.rescan()
        await state.reviewLegacyShortcuts()
        let review = try XCTUnwrap(state.pendingLegacyTrustReview)
        XCTAssertEqual(review.approvals.count, 2)

        // Between the review and the click the bundle gains the download flag.
        let flag = Array("0083;00000000;Safari;".utf8)
        let result = received.withUnsafeFileSystemRepresentation { setxattr($0!, LibraryScanner.quarantineAttribute, flag, flag.count, 0, 0) }
        XCTAssertEqual(result, 0)
        let receivedInfo = try infoData(of: received)

        let results = await state.trustLegacyShortcuts(review)

        guard case .skipped(let reason) = results.first?.outcome else { return XCTFail("the quarantined shortcut must be skipped") }
        XCTAssertTrue(reason.contains("quarantined"), reason)
        XCTAssertEqual(results.last?.outcome, .rebuilt, "the loop carries on")
        XCTAssertEqual(try infoData(of: received), receivedInfo, "a skipped shortcut is not rewritten or re-signed")
        XCTAssertEqual(library.record(for: received)?.isForeign, true)
        XCTAssertEqual(library.record(for: legacy)?.provenance, .own)
    }

    func testTrustAllReportsAFailedRebuildAndCarriesOn() async throws {
        try writeLegacyShortcut(named: "A Broken", targetPath: dir.appending(path: "Missing.app").path)
        let legacy = try writeLegacyShortcut(named: "B Legacy")
        await library.rescan()
        await state.reviewLegacyShortcuts()
        let review = try XCTUnwrap(state.pendingLegacyTrustReview)

        let results = await state.trustLegacyShortcuts(review)

        XCTAssertEqual(results.map(\.name), ["A Broken", "B Legacy"])
        guard case .failed(let message) = results.first?.outcome else { return XCTFail("the missing target fails") }
        XCTAssertTrue(message.contains("Missing.app"), message)
        XCTAssertEqual(results.last?.outcome, .rebuilt)
        XCTAssertNil(state.pendingError)
        XCTAssertEqual(library.legacyCandidates.map(\.name), ["A Broken"], "a failed shortcut stays in the review")
        XCTAssertEqual(library.record(for: legacy)?.provenance, .own)
    }

    // MARK: When the review is offered

    func testTheReviewIsOfferedOnceAfterTheFirstScan() async throws {
        try writeLegacyShortcut(named: "Legacy")

        await state.offerLegacyTrustReviewIfNeeded()
        XCTAssertNil(state.pendingLegacyTrustReview, "nothing is offered before the first scan")

        await library.rescan()
        await state.offerLegacyTrustReviewIfNeeded()
        XCTAssertEqual(state.pendingLegacyTrustReview?.approvals.map(\.record.name), ["Legacy"])

        state.closeLegacyTrustReview()
        await library.rescan()
        await state.offerLegacyTrustReviewIfNeeded()
        XCTAssertNil(state.pendingLegacyTrustReview, "offered automatically at most once per launch")
        XCTAssertFalse(settings.legacyTrustPromptSuppressed)
    }

    func testTheReviewIsNotOfferedWithoutCandidatesOrAfterNotNow() async throws {
        await library.rescan()
        await state.offerLegacyTrustReviewIfNeeded()
        XCTAssertNil(state.pendingLegacyTrustReview, "no candidates, no review")

        settings.legacyTrustPromptSuppressed = true
        let suppressed = AppState(settings: settings, library: library, launcherBinary: dir.appending(path: "Launcher"))
        try writeLegacyShortcut(named: "Legacy")
        await library.rescan()
        await suppressed.offerLegacyTrustReviewIfNeeded()
        XCTAssertNil(suppressed.pendingLegacyTrustReview, "Not now stops the launch-time review")

        await suppressed.reviewLegacyShortcuts()
        XCTAssertEqual(suppressed.pendingLegacyTrustReview?.approvals.map(\.record.name), ["Legacy"],
                       "Review Earlier Shortcuts opens it whatever the flag says")
    }

    func testNotNowRemembersTheChoiceAndWritesNothing() async throws {
        let bundle = try writeLegacyShortcut(named: "Legacy")
        let before = try infoData(of: bundle)
        await library.rescan()
        await state.offerLegacyTrustReviewIfNeeded()
        XCTAssertNotNil(state.pendingLegacyTrustReview)

        state.postponeLegacyTrustReview()

        XCTAssertNil(state.pendingLegacyTrustReview)
        XCTAssertTrue(settings.legacyTrustPromptSuppressed)
        XCTAssertTrue(AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName).legacyTrustPromptSuppressed,
                      "the choice survives a relaunch")
        XCTAssertEqual(try infoData(of: bundle), before, "Not now writes nothing")
        XCTAssertEqual(library.legacyCandidates.map(\.name), ["Legacy"], "the banner still offers the review")
    }

    // MARK: Rebuild All

    func testRebuildAllPointsLegacyShortcutsAtTheReview() async throws {
        let legacy = try writeLegacyShortcut(named: "Legacy", engineVersion: 0)
        let before = try infoData(of: legacy)
        await library.rescan()
        XCTAssertEqual(library.recordsNeedingRebuild.map(\.name), ["Legacy"])

        let results = await state.rebuildAll()

        XCTAssertEqual(results.map(\.outcome), [.skipped(LegacyTrustReview.rebuildAllSkipReason)])
        XCTAssertTrue(LegacyTrustReview.rebuildAllSkipReason.contains("Review Earlier Shortcuts"))
        XCTAssertEqual(try infoData(of: legacy), before, "Rebuild All never trusts a shortcut")
        XCTAssertNil(state.pendingLegacyTrustReview, "Rebuild All does not open the review")
    }
}
