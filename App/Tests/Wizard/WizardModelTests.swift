import CompatProfiles
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

@MainActor
final class WizardModelTests: XCTestCase {
    private var dir: URL!
    private var target: URL!

    override func setUp() async throws {
        dir = try makeAppTemporaryDirectory()
        target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "2.1", in: dir)
        try FileManager.default.removeItem(at: target.appending(path: "Contents/MacOS/Target"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: target.appending(path: "Contents/MacOS/Target"))
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: dir)
    }

    func testLaunchModeResetsWhenNewTargetIsUnprotected() throws {
        let plain = try writeFakeTarget(named: "Plain", bundleIdentifier: "com.example.plain", version: "1.0", in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plain.appending(path: "Contents/MacOS/Plain").path)
        let model = WizardModel(prefillTarget: target)
        XCTAssertEqual(model.launchMode, .systemLaunch)
        model.selectTarget(plain)
        XCTAssertNotNil(model.inspected)
        XCTAssertFalse(model.requiresSystemLaunch)
        XCTAssertEqual(model.launchMode, .dockShortcut)
    }

    func testInitialStateWithoutPrefill() {
        let model = WizardModel()
        XCTAssertEqual(model.step, .kind)
        XCTAssertEqual(model.kind, .app)
        XCTAssertTrue(model.canAdvance)
        XCTAssertNil(model.targetURL)
    }

    func testPrefillSkipsToIdentity() {
        let model = WizardModel(prefillTarget: target)
        XCTAssertEqual(model.step, .identity)
        XCTAssertEqual(model.targetURL, target)
        XCTAssertEqual(model.name, "Target Copy")
        XCTAssertNotNil(model.inspected)
    }

    func testTargetStepBlocksUntilSelected() {
        let model = WizardModel()
        model.next()
        XCTAssertEqual(model.step, .target)
        XCTAssertFalse(model.canAdvance)
        model.selectTarget(target)
        XCTAssertTrue(model.canAdvance)
        XCTAssertEqual(model.name, "Target Copy")
    }

    func testPlatformBinaryForcesSystemLaunch() {
        let model = WizardModel(prefillTarget: target)
        XCTAssertEqual(model.launchMode, .systemLaunch)
        XCTAssertTrue(model.inspected?.isPlatformBinary ?? false)
    }

    func testIdentityStepBlocksOnEmptyName() {
        let model = WizardModel(prefillTarget: target)
        model.name = "   "
        XCTAssertFalse(model.canAdvance)
        model.name = "Work"
        XCTAssertTrue(model.canAdvance)
    }

    func testMakeConfigDerivesSlugAndBundleIdentifier() {
        let model = WizardModel(prefillTarget: target)
        model.name = "Target Work"
        model.dataMode = .homeOverride
        model.iconMode = .generated
        let config = model.makeConfig()
        XCTAssertEqual(config.kind, .app)
        XCTAssertEqual(config.name, "Target Work")
        XCTAssertEqual(config.slug, ShortcutConfig.slug(for: "Target Work"))
        XCTAssertEqual(config.bundleIdentifier, ShortcutConfig.bundleIdentifier(forSlug: config.slug))
        XCTAssertEqual(config.targetPath, target.path)
        XCTAssertEqual(config.targetBundleIdentifier, "com.example.target")
        XCTAssertEqual(config.dataMode, .homeOverride)
        XCTAssertEqual(config.iconMode, .generated)
        XCTAssertEqual(config.launchMode, .systemLaunch)
        XCTAssertNil(config.dataPath)
    }

    func testAShortcutIsRefusedAsTheTargetWithTheExactMessage() throws {
        let shortcut = try writeShortcutBundle(named: "Claude Work", in: dir, config: makeConfig(name: "Claude Work", targetPath: target.path))
        let model = WizardModel()
        model.selectTarget(target)
        XCTAssertNotNil(model.inspected, "precondition: a real app is accepted")

        model.selectTarget(shortcut)
        XCTAssertNil(model.targetURL)
        XCTAssertNil(model.inspected)
        XCTAssertNil(model.profile)
        XCTAssertEqual(model.inspectError, "Claude Work is an App Duplicator shortcut, not an app. Choose the original app instead.")
        model.step = .target
        XCTAssertFalse(model.canAdvance)
    }

    func testAShortcutPrefillIsRefusedAndStaysOnTheFirstStep() throws {
        let shortcut = try writeShortcutBundle(named: "Claude Work", in: dir, config: makeConfig(name: "Claude Work", targetPath: target.path))
        let model = WizardModel(prefillTarget: shortcut)
        XCTAssertEqual(model.step, .kind)
        XCTAssertNil(model.inspected)
        XCTAssertEqual(model.inspectError, "Claude Work is an App Duplicator shortcut, not an app. Choose the original app instead.")
    }

    func testMakeConfigStepsAroundTakenSlugs() {
        XCTAssertEqual(ShortcutConfig.slug(for: "Claude-Work"), "claude-work", "precondition: the name folds to a taken slug")
        let model = WizardModel(takenSlugs: ["claude-work", "claude-work-2"])
        model.selectTarget(target)
        model.name = "Claude-Work"

        let config = model.makeConfig()
        XCTAssertEqual(model.slug, "claude-work-3")
        XCTAssertEqual(config.slug, "claude-work-3")
        XCTAssertEqual(config.bundleIdentifier, ShortcutConfig.bundleIdentifier(forSlug: "claude-work-3"))
        XCTAssertNil(config.dataPath, "the default data folder stays nil until the builder resolves it from the final slug")
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        XCTAssertEqual(config.resolvingDefaultDataPath(home: home).dataPath, ShortcutConfig.defaultDataPath(forSlug: "claude-work-3", home: home))
    }

    func testAFreeSlugIsKeptAsIs() {
        let model = WizardModel(takenSlugs: ["claude-home"])
        model.name = "Claude Work"
        XCTAssertEqual(model.slug, ShortcutConfig.slug(for: "Claude Work"))
    }

    func testSearchDistinguishesAnEmptyFilterFromNoMatches() {
        let apps = [
            InstalledApp(url: URL(fileURLWithPath: "/Applications/Claude.app"), name: "Claude", bundleIdentifier: "com.anthropic.claudefordesktop", version: "1.0"),
            InstalledApp(url: URL(fileURLWithPath: "/Applications/Slack.app"), name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", version: nil),
        ]
        XCTAssertEqual(WizardModel.filteredApps(apps, query: ""), apps)
        XCTAssertFalse(WizardModel.showsNoMatches(apps: apps, query: ""), "an empty filter is not a no-match state")
        XCTAssertEqual(WizardModel.filteredApps(apps, query: "sla").map(\.name), ["Slack"])
        XCTAssertFalse(WizardModel.showsNoMatches(apps: apps, query: "sla"))
        XCTAssertEqual(WizardModel.filteredApps(apps, query: "zzz"), [])
        XCTAssertTrue(WizardModel.showsNoMatches(apps: apps, query: "zzz"))
        XCTAssertFalse(WizardModel.showsNoMatches(apps: [], query: ""), "no apps and no filter (scan still running) is not a search result")
    }

    func testReviewStepBuildsPreview() {
        let model = WizardModel(prefillTarget: target)
        model.next() // data
        model.next() // review
        XCTAssertEqual(model.step, .review)
        XCTAssertTrue(model.isLastStep)
        XCTAssertNotNil(model.preview)
        XCTAssertNil(model.previewError)
        XCTAssertEqual(model.preview?.launchMode, .systemLaunch)
        XCTAssertEqual(model.preview?.executablePath, target.appending(path: "Contents/MacOS/Target").path)
    }

    func testBackStopsAtFirstStep() {
        let model = WizardModel()
        model.back()
        XCTAssertEqual(model.step, .kind)
    }

    func testProfileDefaultsArePrefilledAndShownMaskedInThePreview() throws {
        let profile = AppProfile(name: "Target", status: .verified, family: .native,
                                 args: ["--api-key", "hunter2", "--plain"], env: ["API_TOKEN": "leaked", "TARGET_MODE": "work"],
                                 notes: "Profile notes.")
        let model = WizardModel(prefillTarget: target, profileLookup: { $0 == "com.example.target" ? profile : nil })
        XCTAssertEqual(model.profile, profile)
        XCTAssertEqual(model.arguments, ["--api-key", "hunter2", "--plain"])
        XCTAssertEqual(model.environment, ["API_TOKEN": "leaked", "TARGET_MODE": "work"])
        let config = model.makeConfig()
        XCTAssertEqual(config.arguments, ["--api-key", "hunter2", "--plain"])
        XCTAssertEqual(config.environment, ["API_TOKEN": "leaked", "TARGET_MODE": "work"])

        model.next() // data
        model.next() // review
        let preview = try XCTUnwrap(model.preview)
        XCTAssertEqual(preview.arguments, ["--api-key", "••••••", "--plain"])
        XCTAssertEqual(preview.environmentAdditions["API_TOKEN"], SecretMasking.maskedValue)
        XCTAssertEqual(preview.environmentAdditions["TARGET_MODE"], "work")
    }

    func testAnotherTargetReplacesTheProfileDefaults() throws {
        let plain = try writeFakeTarget(named: "Plain", bundleIdentifier: "com.example.plain", version: "1.0", in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plain.appending(path: "Contents/MacOS/Plain").path)
        let profiles = ["com.example.target": AppProfile(name: "Target", status: .partial, args: ["--one"], env: ["ONE": "1"])]
        let model = WizardModel(prefillTarget: target, profileLookup: { profiles[$0] })
        XCTAssertEqual(model.arguments, ["--one"])

        model.selectTarget(plain)
        XCTAssertNil(model.profile)
        XCTAssertEqual(model.arguments, [])
        XCTAssertEqual(model.environment, [:])
        XCTAssertEqual(model.makeConfig().arguments, [])
        XCTAssertEqual(model.makeConfig().environment, [:])

        model.selectTarget(target)
        XCTAssertEqual(model.profile?.name, "Target")
        XCTAssertEqual(model.environment, ["ONE": "1"])

        model.selectTarget(dir.appending(path: "Missing.app"))
        XCTAssertNil(model.inspected)
        XCTAssertNil(model.profile)
        XCTAssertEqual(model.arguments, [])
        XCTAssertEqual(model.environment, [:])
    }
}
