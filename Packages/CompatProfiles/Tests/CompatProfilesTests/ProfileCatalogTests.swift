import XCTest
@testable import CompatProfiles

final class ProfileCatalogTests: XCTestCase {
    private func data(updated: String, name: String) throws -> Data {
        try makeProfilesData(updated: updated, apps: ["com.example.app": appEntry(name: name)])
    }

    func testEmptyCatalog() {
        XCTAssertEqual(ProfileCatalog.empty.updated, "")
        XCTAssertEqual(ProfileCatalog.empty.appCount, 0)
        XCTAssertEqual(ProfileCatalog.empty.source, .bundled)
        XCTAssertNil(ProfileCatalog.empty.profile(forBundleIdentifier: "com.example.app"))
    }

    func testLookupIsCaseInsensitive() {
        let document = ProfilesDocument(updated: "2026-10-09",
                                        apps: ["com.Example.App": AppProfile(name: "Example", status: .verified)])
        let catalog = ProfileCatalog(document: document, source: .bundled)

        XCTAssertEqual(catalog.profile(forBundleIdentifier: "com.Example.App")?.status, .verified)
        XCTAssertEqual(catalog.profile(forBundleIdentifier: "com.example.app")?.status, .verified)
        XCTAssertEqual(catalog.profile(forBundleIdentifier: "COM.EXAMPLE.APP")?.status, .verified)
        XCTAssertNil(catalog.profile(forBundleIdentifier: "com.example.other"))
    }

    func testLoadUsesBundledWhenNoCache() throws {
        let directory = try makeTemporaryDirectory()
        let bundled = try writeFile(data(updated: "2026-10-09", name: "Bundled"), named: "profiles.json", in: directory)

        let catalog = ProfileCatalog.load(bundledURL: bundled, cacheURL: directory.appending(path: "missing/profiles.json"))

        XCTAssertEqual(catalog.source, .bundled)
        XCTAssertEqual(catalog.updated, "2026-10-09")
        XCTAssertEqual(catalog.profile(forBundleIdentifier: "com.example.app")?.name, "Bundled")
    }

    func testLoadPrefersAStrictlyNewerCache() throws {
        let directory = try makeTemporaryDirectory()
        let bundled = try writeFile(data(updated: "2026-10-09", name: "Bundled"), named: "bundled.json", in: directory)
        let cache = try writeFile(data(updated: "2026-10-10", name: "Cached"), named: "cache.json", in: directory)

        let catalog = ProfileCatalog.load(bundledURL: bundled, cacheURL: cache)

        XCTAssertEqual(catalog.source, .cached)
        XCTAssertEqual(catalog.updated, "2026-10-10")
        XCTAssertEqual(catalog.profile(forBundleIdentifier: "com.example.app")?.name, "Cached")
    }

    func testLoadIgnoresAnOlderOrSameDayCache() throws {
        let directory = try makeTemporaryDirectory()
        let bundled = try writeFile(data(updated: "2026-10-09", name: "Bundled"), named: "bundled.json", in: directory)
        for updated in ["2026-10-09", "2026-10-08"] {
            let cache = try writeFile(data(updated: updated, name: "Cached"), named: "cache-\(updated).json", in: directory)

            let catalog = ProfileCatalog.load(bundledURL: bundled, cacheURL: cache)

            XCTAssertEqual(catalog.source, .bundled, updated)
            XCTAssertEqual(catalog.profile(forBundleIdentifier: "com.example.app")?.name, "Bundled", updated)
        }
    }

    func testLoadSkipsInvalidSources() throws {
        let directory = try makeTemporaryDirectory()
        let bundled = try writeFile(data(updated: "2026-10-09", name: "Bundled"), named: "bundled.json", in: directory)
        let broken = try writeFile(Data("{".utf8), named: "broken.json", in: directory)
        let futureSchema = try writeFile(makeProfilesData(schemaVersion: 2, updated: "2027-01-01"), named: "future.json", in: directory)
        let oversized = try writeFile(Data(repeating: UInt8(ascii: " "), count: ProfilesDocument.maxBytes + 1),
                                      named: "big.json", in: directory)
        let cache = try writeFile(data(updated: "2026-10-10", name: "Cached"), named: "cache.json", in: directory)

        XCTAssertEqual(ProfileCatalog.load(bundledURL: bundled, cacheURL: futureSchema).source, .bundled)
        XCTAssertEqual(ProfileCatalog.load(bundledURL: bundled, cacheURL: oversized).source, .bundled)
        XCTAssertEqual(ProfileCatalog.load(bundledURL: broken, cacheURL: cache).source, .cached)
        XCTAssertEqual(ProfileCatalog.load(bundledURL: nil, cacheURL: cache).source, .cached)
        XCTAssertEqual(ProfileCatalog.load(bundledURL: broken, cacheURL: broken), .empty)
        XCTAssertEqual(ProfileCatalog.load(bundledURL: nil, cacheURL: directory.appending(path: "missing.json")), .empty)
    }

    func testIsNewerComparesDates() {
        XCTAssertTrue(ProfileCatalog.isNewer("2026-10-10", than: "2026-10-09"))
        XCTAssertTrue(ProfileCatalog.isNewer("2027-01-01", than: "2026-12-31"))
        XCTAssertTrue(ProfileCatalog.isNewer("2026-10-09", than: ""), "any date beats the empty catalog")
        XCTAssertFalse(ProfileCatalog.isNewer("2026-10-09", than: "2026-10-09"), "the same day is not newer")
        XCTAssertFalse(ProfileCatalog.isNewer("2026-10-08", than: "2026-10-09"))
    }
}
