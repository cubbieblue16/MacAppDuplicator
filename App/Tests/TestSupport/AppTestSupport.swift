import CompatProfiles
import Foundation
import Synchronization
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

/// A unique temp directory per test; the test removes it in tearDown.
func makeAppTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "mad-app-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes a minimal shortcut bundle (Info.plist with MADConfig + MADEngineVersion, empty MacOS executable, optional icon)
/// the way BundleWriter lays it out, without needing a launcher binary or a real target.
@discardableResult
func writeShortcutBundle(named name: String, in directory: URL, config: ShortcutConfig, engineVersion: Int = ShortcutConfig.currentEngineVersion, withIcon: Bool = true, extraInfo: [String: Any] = [:]) throws -> URL {
    let bundle = directory.appending(path: "\(name).app", directoryHint: .isDirectory)
    let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
    var info: [String: Any] = [
        "CFBundleIdentifier": config.bundleIdentifier,
        "CFBundleName": config.name,
        "CFBundleExecutable": name,
        "CFBundlePackageType": "APPL",
        ShortcutConfig.infoPlistKey: config.plistDictionary(),
        ShortcutConfig.engineVersionInfoPlistKey: engineVersion,
    ]
    for (key, value) in extraInfo { info[key] = value }
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appending(path: "Info.plist"))
    try Data().write(to: contents.appending(path: "MacOS/\(name)"))
    if withIcon {
        try Data([1, 2, 3]).write(to: contents.appending(path: "Resources/AppIcon.icns"))
    }
    return bundle
}

/// A fake target app bundle with a version, so scanner tests can resolve `targetVersion` without a real app.
@discardableResult
func writeFakeTarget(named name: String, bundleIdentifier: String, version: String, in directory: URL) throws -> URL {
    let bundle = directory.appending(path: "\(name).app", directoryHint: .isDirectory)
    let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": bundleIdentifier, "CFBundleName": name, "CFBundleExecutable": name,
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
    try Data().write(to: contents.appending(path: "MacOS/\(name)"))
    return bundle
}

func makeConfig(name: String = "Target Work", targetPath: String = "/Applications/Target.app", targetBundleIdentifier: String = "com.example.target", kind: ShortcutKind = .app) -> ShortcutConfig {
    let slug = ShortcutConfig.slug(for: name)
    return ShortcutConfig(
        kind: kind, name: name, slug: slug, bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: slug),
        targetPath: targetPath, targetBundleIdentifier: targetBundleIdentifier
    )
}

/// A web app shortcut config: `kind == .webApp`, no target. `iconMode` is `.copied` (the fetched or kept site icon).
func makeWebConfig(name: String = "Chat Work", url: String = "https://chat.example.test/", dataStoreID: UUID = UUID()) -> ShortcutConfig {
    let slug = ShortcutConfig.slug(for: name)
    var config = ShortcutConfig(
        kind: .webApp, name: name, slug: slug, bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: slug),
        targetPath: "", targetBundleIdentifier: "", launchMode: .dockShortcut, dataMode: .disabled, dataPath: nil,
        webApp: WebAppConfig(url: url, dataStoreID: dataStoreID)
    )
    config.iconMode = .copied
    return config
}

/// Isolated UserDefaults for one test; call `removePersistentDomain(forName:)` with the suite in tearDown.
func makeTestDefaults() -> (defaults: UserDefaults, suite: String) {
    let suite = "com.mikekuta.MacAppDuplicatorTests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

extension XCTestCase {
    // @MainActor so a MainActor-isolated test class can call it without sending `self` across isolation (Swift 6 region check).
    @MainActor
    func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// A `ProfilesFetching` that returns a canned result and records every URL it was asked for; never touches the network.
final class StubProfilesFetcher: ProfilesFetching, Sendable {
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

/// `profiles.json` bytes (schema 1) dated `updated`, with one minimal entry per `apps` key (bundle identifier → status).
func makeProfilesJSON(updated: String, apps: [String: String]) throws -> Data {
    var entries: [String: Any] = [:]
    for (identifier, status) in apps { entries[identifier] = ["name": identifier, "status": status] as [String: Any] }
    let object: [String: Any] = ["schemaVersion": 1, "updated": updated, "apps": entries]
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
