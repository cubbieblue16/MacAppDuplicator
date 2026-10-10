import XCTest
@testable import MacAppDuplicator

final class WebDataRemoverTests: XCTestCase {
    private var root: URL!
    private let bundleID = "com.mikekuta.appduplicator.chat"

    override func setUpWithError() throws {
        root = try makeAppTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    /// Lays out `<root>/<bundle>/WebsiteDataStore/<name>/{Cookies/Cookies.binarycookies, NetworkCache/entry}` the way WebKit does.
    @discardableResult
    private func makeStore(named name: String, bundle: String) throws -> URL {
        let store = root.appending(path: "\(bundle)/WebsiteDataStore/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: store.appending(path: "Cookies"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.appending(path: "NetworkCache"), withIntermediateDirectories: true)
        try Data([1]).write(to: store.appending(path: "Cookies/Cookies.binarycookies"))
        try Data([2]).write(to: store.appending(path: "NetworkCache/entry"))
        return store
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testRemovesTheStoreAndEverythingInItButNothingElse() async throws {
        let id = UUID()
        let store = try makeStore(named: id.uuidString.lowercased(), bundle: bundleID)
        let otherStoreSameApp = try makeStore(named: UUID().uuidString.lowercased(), bundle: bundleID)
        let sameIDOtherApp = try makeStore(named: id.uuidString.lowercased(), bundle: "com.mikekuta.appduplicator.mail")

        try await WebKitWebDataRemover(webKitRoot: root).removeWebData(identifier: id, bundleIdentifier: bundleID)

        XCTAssertFalse(exists(store), "the store directory goes, cookies and cache with it")
        XCTAssertTrue(exists(otherStoreSameApp), "another store of the same web app stays")
        XCTAssertTrue(exists(sameIDOtherApp), "the same id under another web app's bundle id stays")
    }

    func testMatchesTheStoreNameCaseInsensitively() async throws {
        let id = UUID()
        let store = try makeStore(named: id.uuidString.uppercased(), bundle: bundleID)

        try await WebKitWebDataRemover(webKitRoot: root).removeWebData(identifier: id, bundleIdentifier: bundleID)

        XCTAssertFalse(exists(store))
    }

    /// The contract the plan relies on instead of `WKWebsiteDataStore.remove(forIdentifier:)` on an unknown identifier:
    /// a fresh random id is a no-op that neither throws nor creates anything.
    func testAFreshRandomIdentifierIsANoOp() async throws {
        let remover = WebKitWebDataRemover(webKitRoot: root)
        try await remover.removeWebData(identifier: UUID(), bundleIdentifier: bundleID)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [], "nothing is created")

        let kept = try makeStore(named: UUID().uuidString.lowercased(), bundle: bundleID)
        try await remover.removeWebData(identifier: UUID(), bundleIdentifier: bundleID)
        XCTAssertTrue(exists(kept), "an unknown id leaves the known stores alone")
    }

    func testRefusesABundleIdentifierOutsideTheShellNamespace() async throws {
        let id = UUID()
        let victim = try makeStore(named: id.uuidString.lowercased(), bundle: "com.apple.Safari")
        let remover = WebKitWebDataRemover(webKitRoot: root)

        for bad in ["com.apple.Safari", "", "com.mikekuta.appduplicator.", "com.mikekuta.appduplicator.Chat",
                    "com.mikekuta.appduplicator.../x", "com.mikekuta.appduplicator.a/b", "com.mikekuta.appduplicator.chat extra"] {
            do {
                try await remover.removeWebData(identifier: id, bundleIdentifier: bad)
                XCTFail("\(bad) must be refused")
            } catch {
                XCTAssertEqual(error as? WebDataRemovalError, .invalidBundleIdentifier(bad))
            }
        }
        XCTAssertTrue(exists(victim))
    }

    func testShellBundleIdentifierRule() {
        XCTAssertTrue(WebKitWebDataRemover.isShellBundleIdentifier("com.mikekuta.appduplicator.chat-2"))
        XCTAssertFalse(WebKitWebDataRemover.isShellBundleIdentifier("com.mikekuta.appduplicator.caf\u{00E9}"))
        XCTAssertFalse(WebKitWebDataRemover.isShellBundleIdentifier("com.example.chat"))
    }

    func testErrorCopyNamesTheProblem() {
        XCTAssertEqual(
            WebDataRemovalError.shortcutRunning("Chat").errorDescription,
            "Quit “Chat” before removing its web data."
        )
        XCTAssertEqual(
            WebDataRemovalError.invalidBundleIdentifier("com.apple.Safari").errorDescription,
            "“com.apple.Safari” is not a web app bundle identifier, so no web data was removed."
        )
    }
}
