import os
import XCTest
@testable import DuplicatorCore

final class LaunchPreparerTests: XCTestCase {
    private let fileManager = FileManager.default
    private let baseEnvironment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]

    private struct Fixture {
        var root: URL
        var realHome: URL
        var shortcutBundle: URL
        var targetBundle: URL
    }

    private func makeFixture(target: FixtureBundle = FixtureBundle(name: "Target"), signed: Bool = true) throws -> Fixture {
        let root = try makeTemporaryDirectory()
        let realHome = root.appending(path: "realhome", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: realHome.appending(path: "Documents", directoryHint: .isDirectory), withIntermediateDirectories: true)
        // An empty framework directory cannot be code-signed; unsigned fixtures are still not platform binaries.
        let targetBundle = signed ? try target.writeSigned(in: root) : try target.write(in: root)
        let shortcutBundle = root.appending(path: "Shortcut.app", directoryHint: .isDirectory)
        return Fixture(root: root, realHome: realHome, shortcutBundle: shortcutBundle, targetBundle: targetBundle)
    }

    private func config(
        for fixture: Fixture,
        dataMode: DataMode,
        dataPath: String?,
        targetPath: String? = nil,
        targetBundleIdentifier: String = "com.example.fixture"
    ) -> ShortcutConfig {
        ShortcutConfig(
            name: "Target Work",
            slug: "target-work",
            bundleIdentifier: "com.mikekuta.appduplicator.target-work",
            targetPath: targetPath ?? fixture.targetBundle.path,
            targetBundleIdentifier: targetBundleIdentifier,
            dataMode: dataMode,
            dataPath: dataPath
        )
    }

    private func prepare(_ fixture: Fixture, _ info: [String: Any]) throws -> PreparedLaunch {
        try LaunchPreparer(realHome: fixture.realHome)
            .prepare(infoDictionary: info, shortcutBundleURL: fixture.shortcutBundle, baseEnvironment: baseEnvironment)
    }

    private func assertLauncherError(
        _ expression: @autoclosure () throws -> PreparedLaunch,
        file: StaticString = #filePath,
        line: UInt = #line,
        matches: (LauncherError) -> Bool
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let launcherError = error as? LauncherError else {
                return XCTFail("expected LauncherError, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(matches(launcherError), "unexpected error: \(launcherError)", file: file, line: line)
        }
    }

    func testHomeOverrideBuildsTree() throws {
        let fixture = try makeFixture()
        let home = fixture.root.appending(path: "home", directoryHint: .isDirectory)
        let shortcut = config(for: fixture, dataMode: .homeOverride, dataPath: home.path)

        let prepared = try prepare(fixture, ["MADConfig": shortcut.plistDictionary()])

        let expectedHome = home.standardizedFileURL.path
        XCTAssertEqual(prepared.plan.environment["HOME"], expectedHome)
        XCTAssertEqual(prepared.plan.environment["CFFIXED_USER_HOME"], expectedHome)
        XCTAssertEqual(prepared.config, shortcut)
        XCTAssertEqual(prepared.app.bundleIdentifier, "com.example.fixture")
        XCTAssertTrue(fileManager.fileExists(atPath: home.appending(path: "Library/Application Support").path))
        let link = home.appending(path: "Documents", directoryHint: .notDirectory)
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: link.path), fixture.realHome.appending(path: "Documents").path)
    }

    func testProgressReportsCreateAndDataFolderLines() throws {
        let fixture = try makeFixture()
        let home = fixture.root.appending(path: "home", directoryHint: .isDirectory)
        let shortcut = config(for: fixture, dataMode: .homeOverride, dataPath: home.path)
        let lines = OSAllocatedUnfairLock<[String]>(initialState: [])

        let prepared = try LaunchPreparer(realHome: fixture.realHome, progress: { line in lines.withLock { $0.append(line) } })
            .prepare(infoDictionary: ["MADConfig": shortcut.plistDictionary()], shortcutBundleURL: fixture.shortcutBundle, baseEnvironment: baseEnvironment)

        let collected = lines.withLock { $0 }
        let dataFolderLines = collected.filter { $0.hasPrefix("data folder ") }
        XCTAssertEqual(dataFolderLines.count, 1)
        XCTAssertEqual(dataFolderLines.first.map { String($0.dropFirst("data folder ".count)) }, try XCTUnwrap(prepared.plan.homeOverridePath).path)
        XCTAssertEqual(try XCTUnwrap(prepared.plan.homeOverridePath).standardizedFileURL.path, home.standardizedFileURL.path)
        XCTAssertTrue(collected.contains { $0.hasPrefix("create ") })
    }

    func testMissingConfigThrowsConfigMissing() throws {
        let fixture = try makeFixture()
        assertLauncherError(try prepare(fixture, ["CFBundleName": "Shortcut"])) {
            if case .configMissing = $0 { return true }
            return false
        }
    }

    func testNonDictionaryConfigThrowsConfigCorrupt() throws {
        let fixture = try makeFixture()
        assertLauncherError(try prepare(fixture, ["MADConfig": "not a dictionary"])) {
            if case .configCorrupt = $0 { return true }
            return false
        }
    }

    func testMissingTargetThrowsTargetNotFound() throws {
        let fixture = try makeFixture()
        let shortcut = config(
            for: fixture,
            dataMode: .disabled,
            dataPath: nil,
            targetPath: fixture.root.appending(path: "Nowhere.app").path,
            targetBundleIdentifier: "com.example.not-installed"
        )
        assertLauncherError(try prepare(fixture, ["MADConfig": shortcut.plistDictionary()])) {
            if case .targetNotFound(_, let bundleID) = $0 { return bundleID == "com.example.not-installed" }
            return false
        }
    }

    func testUnwritableDataPathThrowsDataPathNotWritable() throws {
        let electronTarget = FixtureBundle(name: "Target", directories: ["Frameworks/Electron Framework.framework"])
        let fixture = try makeFixture(target: electronTarget, signed: false)
        let blocker = fixture.root.appending(path: "blocker", directoryHint: .notDirectory)
        try Data("file".utf8).write(to: blocker)
        let shortcut = config(for: fixture, dataMode: .auto, dataPath: blocker.appending(path: "data").path)

        XCTAssertEqual(try AppInspector().inspect(appAt: fixture.targetBundle).family, .electron)
        XCTAssertThrowsError(try prepare(fixture, ["MADConfig": shortcut.plistDictionary()])) { error in
            guard let launcherError = error as? LauncherError, case .dataPathNotWritable = launcherError else {
                return XCTFail("expected dataPathNotWritable, got \(error)")
            }
            XCTAssertEqual(launcherError.exitCode, 4)
        }
    }

    func testDisabledDataModeCreatesNoDirectories() throws {
        let fixture = try makeFixture()
        let data = fixture.root.appending(path: "should-not-exist", directoryHint: .isDirectory)
        let shortcut = config(for: fixture, dataMode: .disabled, dataPath: data.path)
        let before = try fileManager.contentsOfDirectory(atPath: fixture.root.path).sorted()

        let prepared = try prepare(fixture, ["MADConfig": shortcut.plistDictionary()])

        XCTAssertTrue(prepared.plan.directoriesToCreate.isEmpty)
        XCTAssertNil(prepared.plan.homeOverridePath)
        XCTAssertFalse(fileManager.fileExists(atPath: data.path))
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: fixture.root.path).sorted(), before)
    }

    func testHomeOverrideUsesConfigSymlinkEntries() throws {
        let fixture = try makeFixture()
        try fileManager.createDirectory(at: fixture.realHome.appending(path: "Desktop", directoryHint: .isDirectory), withIntermediateDirectories: true)
        let home = fixture.root.appending(path: "home", directoryHint: .isDirectory)
        var shortcut = config(for: fixture, dataMode: .homeOverride, dataPath: home.path)
        shortcut.homeSymlinkEntries = ["Desktop"]

        _ = try prepare(fixture, ["MADConfig": shortcut.plistDictionary()])

        let desktop = home.appending(path: "Desktop", directoryHint: .notDirectory)
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: desktop.path), fixture.realHome.appending(path: "Desktop").path)
        XCTAssertFalse(fileManager.fileExists(atPath: home.appending(path: "Documents").path), "Documents is not in the config's list")
    }
}
