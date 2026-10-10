import Synchronization
import XCTest
@testable import CompatProfiles

/// A `ProfilesFetching` that returns a canned result and records every URL it was asked for; never touches the network.
final class MockFetcher: ProfilesFetching, Sendable {
    let result: Result<Data, ProfilesError>
    private let calls = Mutex<[URL]>([])

    init(_ result: Result<Data, ProfilesError>) {
        self.result = result
    }

    var requestedURLs: [URL] { calls.withLock { $0 } }

    func fetch(from url: URL) async throws -> Data {
        calls.withLock { $0.append(url) }
        return try result.get()
    }
}

final class ProfilesUpdaterTests: XCTestCase {
    private let source = URL(string: ProfilesConstants.defaultURLString)!

    private func catalog(updated: String) -> ProfileCatalog {
        ProfileCatalog(document: ProfilesDocument(updated: updated), source: .bundled)
    }

    private func assertUpdateThrows(_ updater: ProfilesUpdater, from url: URL, expected: ProfilesError,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let result = try await updater.update(from: url, current: catalog(updated: "2026-10-09"))
            XCTFail("expected \(expected), got \(result)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ProfilesError, expected, file: file, line: line)
        }
    }

    func testRefusesAnInsecureURLWithoutFetching() async throws {
        let fetcher = MockFetcher(.success(try makeProfilesData(updated: "2026-10-10")))
        let cacheURL = try makeTemporaryDirectory().appending(path: "profiles.json")
        let updater = ProfilesUpdater(fetcher: fetcher, cacheURL: cacheURL)

        for raw in ["http://raw.githubusercontent.com/cubbieblue16/MacAppDuplicator/main/profiles.json",
                    "https://example.com/profiles.json"] {
            await assertUpdateThrows(updater, from: try XCTUnwrap(URL(string: raw)), expected: .insecureURL(raw))
        }

        XCTAssertEqual(fetcher.requestedURLs, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testWritesANewerDocumentAndReturnsTheCachedCatalog() async throws {
        let data = try makeProfilesData(updated: "2026-10-10", apps: ["com.example.app": appEntry(name: "Fetched")])
        let fetcher = MockFetcher(.success(data))
        let cacheURL = try makeTemporaryDirectory().appending(path: "Application Support/App Duplicator/profiles.json")

        let result = try await ProfilesUpdater(fetcher: fetcher, cacheURL: cacheURL)
            .update(from: source, current: catalog(updated: "2026-10-09"))

        guard case .updated(let updated) = result else { return XCTFail("expected .updated, got \(result)") }
        XCTAssertEqual(updated.source, .cached)
        XCTAssertEqual(updated.updated, "2026-10-10")
        XCTAssertEqual(updated.profile(forBundleIdentifier: "com.example.app")?.name, "Fetched")
        XCTAssertEqual(fetcher.requestedURLs, [source])
        XCTAssertEqual(try Data(contentsOf: cacheURL), data, "the validated bytes are cached unchanged")
        XCTAssertEqual(ProfileCatalog.load(bundledURL: nil, cacheURL: cacheURL), updated)
    }

    func testSameDayOrOlderIsUpToDateAndWritesNothing() async throws {
        let cacheURL = try makeTemporaryDirectory().appending(path: "profiles.json")
        for fetched in ["2026-10-09", "2026-10-08"] {
            let updater = ProfilesUpdater(fetcher: MockFetcher(.success(try makeProfilesData(updated: fetched))),
                                          cacheURL: cacheURL)

            let result = try await updater.update(from: source, current: catalog(updated: "2026-10-09"))

            XCTAssertEqual(result, .upToDate(current: "2026-10-09", fetched: fetched))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testInvalidDownloadThrowsAndLeavesTheCacheAlone() async throws {
        let cacheURL = try makeTemporaryDirectory().appending(path: "profiles.json")
        let previous = try makeProfilesData(updated: "2026-10-01")
        try previous.write(to: cacheURL)
        let refusedEnvironment = appEntry(extra: ["env": ["DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib"]])
        let downloads: [(Data, ProfilesError)] = [
            (try makeProfilesData(schemaVersion: 2, updated: "2026-10-10"), .unsupportedSchemaVersion(2)),
            (try makeProfilesData(updated: "2026-10-10", apps: ["com.example.app": refusedEnvironment]),
             .invalidField("apps.com.example.app.env.DYLD_INSERT_LIBRARIES")),
            (Data(repeating: UInt8(ascii: " "), count: ProfilesDocument.maxBytes + 1), .tooLarge(ProfilesDocument.maxBytes + 1)),
        ]

        for (data, expected) in downloads {
            await assertUpdateThrows(ProfilesUpdater(fetcher: MockFetcher(.success(data)), cacheURL: cacheURL),
                                     from: source, expected: expected)
        }

        XCTAssertEqual(try Data(contentsOf: cacheURL), previous)
    }

    func testFetchErrorsPropagateAndWriteNothing() async throws {
        let cacheURL = try makeTemporaryDirectory().appending(path: "profiles.json")
        for error in [ProfilesError.httpStatus(404), .fetchFailed("The Internet connection appears to be offline.")] {
            await assertUpdateThrows(ProfilesUpdater(fetcher: MockFetcher(.failure(error)), cacheURL: cacheURL),
                                     from: source, expected: error)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }
}
