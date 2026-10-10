import CompatProfiles
import XCTest
@testable import MacAppDuplicator

@MainActor
final class ProfilesModelTests: XCTestCase {
    private var dir: URL!
    private var bundledURL: URL!
    private var cacheURL: URL!
    private let source = URL(string: "https://raw.githubusercontent.com/example/fork/main/profiles.json")!

    override func setUp() async throws {
        dir = try makeAppTemporaryDirectory()
        bundledURL = dir.appending(path: "bundled.json", directoryHint: .notDirectory)
        try makeProfilesJSON(updated: "2026-10-09", apps: ["com.example.target": "partial"]).write(to: bundledURL)
        cacheURL = dir.appending(path: "cache/profiles.json", directoryHint: .notDirectory)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: dir)
    }

    private func makeModel(_ result: Result<Data, ProfilesError> = .failure(.httpStatus(500))) -> (ProfilesModel, StubProfilesFetcher) {
        let fetcher = StubProfilesFetcher(result)
        return (ProfilesModel(bundledURL: bundledURL, cacheURL: cacheURL, fetcher: fetcher), fetcher)
    }

    func testLoadUsesTheSeedUntilACacheIsStrictlyNewer() async throws {
        let (model, _) = makeModel()
        XCTAssertEqual(model.catalogSummary, "No profiles loaded.")

        await model.load()
        XCTAssertEqual(model.catalog.source, .bundled)
        XCTAssertEqual(model.profile(forBundleIdentifier: "com.example.target")?.status, .partial)
        XCTAssertEqual(model.catalogSummary, "1 app, updated 2026-10-09 (bundled)")

        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeProfilesJSON(updated: "2026-10-10", apps: ["com.example.target": "partial", "com.example.cached": "verified"])
            .write(to: cacheURL)
        await model.load()
        XCTAssertEqual(model.catalog.source, .cached)
        XCTAssertEqual(model.profile(forBundleIdentifier: "COM.EXAMPLE.CACHED")?.status, .verified)
        XCTAssertEqual(model.catalogSummary, "2 apps, updated 2026-10-10 (cached)")
    }

    func testCheckForUpdatesCachesANewerDocumentAndSwitchesToIt() async throws {
        let data = try makeProfilesJSON(updated: "2026-10-11", apps: ["com.example.target": "verified"])
        let (model, fetcher) = makeModel(.success(data))
        await model.load()

        let message = await model.checkForUpdates(from: source)

        XCTAssertEqual(message, "Downloaded profiles from 2026-10-11.")
        XCTAssertEqual(model.statusMessage, message)
        XCTAssertFalse(model.isChecking)
        XCTAssertEqual(fetcher.requestedURLs, [source])
        XCTAssertEqual(model.catalog.source, .cached)
        XCTAssertEqual(model.profile(forBundleIdentifier: "com.example.target")?.status, .verified)
        XCTAssertEqual(try Data(contentsOf: cacheURL), data)
    }

    func testCheckForUpdatesReportsUpToDateAndWritesNothing() async throws {
        let data = try makeProfilesJSON(updated: "2026-10-09", apps: [:])
        let (model, _) = makeModel(.success(data))
        await model.load()

        let message = await model.checkForUpdates(from: source)

        XCTAssertEqual(message, "Profiles are up to date (2026-10-09).")
        XCTAssertEqual(model.catalog.source, .bundled)
        XCTAssertEqual(model.catalog.appCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testCheckForUpdatesReportsErrorsAndKeepsTheCatalog() async throws {
        let (model, fetcher) = makeModel(.failure(.httpStatus(404)))
        await model.load()
        let loaded = model.catalog

        let notFound = await model.checkForUpdates(from: source)
        XCTAssertEqual(notFound, "Could not check profile updates: The profiles server answered HTTP 404.")
        XCTAssertEqual(model.catalog, loaded)

        let refused = await model.checkForUpdates(from: nil)
        XCTAssertEqual(refused, "Could not check profile updates: the profiles URL must be an https://raw.githubusercontent.com address.")
        XCTAssertEqual(model.statusMessage, refused)
        XCTAssertEqual(fetcher.requestedURLs, [source], "a refused URL is never fetched")
        XCTAssertEqual(model.catalog, loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testInertModelNeverFetchesOrTouchesTheRealCache() async {
        let model = ProfilesModel.inert()

        let message = await model.checkForUpdates(from: source)

        XCTAssertEqual(message, "Could not check profile updates: Profile updates are disabled while the app hosts the unit tests.")
        XCTAssertEqual(model.catalog, .empty)
        XCTAssertNil(model.bundledURL)
        XCTAssertTrue(model.cacheURL.path.hasPrefix(FileManager.default.temporaryDirectory.path), model.cacheURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.cacheURL.path))
    }
}
