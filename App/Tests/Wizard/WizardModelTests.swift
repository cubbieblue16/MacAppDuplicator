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
}
