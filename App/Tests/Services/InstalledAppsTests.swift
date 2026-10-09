import XCTest
@testable import MacAppDuplicator

final class InstalledAppsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try makeAppTemporaryDirectory() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    func testScanListsAppsSkipsShortcutsLocalizedAndNonApps() throws {
        try writeFakeTarget(named: "Zed", bundleIdentifier: "com.example.zed", version: "2.0", in: dir)
        try writeFakeTarget(named: "alpha", bundleIdentifier: "com.example.alpha", version: "1.0", in: dir)
        try writeShortcutBundle(named: "Zed Work", in: dir, config: makeConfig(name: "Zed Work"))
        try FileManager.default.createDirectory(at: dir.appending(path: ".localized"), withIntermediateDirectories: true)
        try Data().write(to: dir.appending(path: "notes.txt"))

        let apps = InstalledApps.scan(folders: [dir, dir.appending(path: "missing")])

        XCTAssertEqual(apps.map(\.name), ["alpha", "Zed"])
        XCTAssertEqual(apps.map(\.bundleIdentifier), ["com.example.alpha", "com.example.zed"])
        XCTAssertEqual(apps.first?.version, "1.0")
    }

    func testDefaultFolders() {
        XCTAssertEqual(InstalledApps.defaultFolders.map(\.path), ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path])
    }
}
