import DuplicatorCore
import Foundation

struct InstalledApp: Identifiable, Hashable, Sendable {
    var id: URL { url }
    var url: URL
    var name: String
    var bundleIdentifier: String
    var version: String?
}

/// Apps offered by the New Shortcut wizard (spec §7): depth-1 `.app` bundles in `/Applications` and `~/Applications`,
/// excluding shortcuts this app made (they carry `MADConfig`).
enum InstalledApps {
    static let defaultFolders: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
    ]

    static func scan(folders: [URL] = defaultFolders) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        for folder in folders {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for entry in entries where entry.pathExtension == "app" {
                guard let info = infoDictionary(ofAppAt: entry),
                      info[ShortcutConfig.infoPlistKey] == nil,
                      let identifier = info["CFBundleIdentifier"] as? String else { continue }
                let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? entry.deletingPathExtension().lastPathComponent
                apps.append(InstalledApp(url: entry, name: name, bundleIdentifier: identifier, version: info["CFBundleShortVersionString"] as? String))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Reads `Contents/Info.plist` directly: `Bundle(url:)` caches one instance per path for the process lifetime, so an
    /// app updated while this app runs would keep reporting its old name and version. Nil means "not a readable app".
    static func infoDictionary(ofAppAt appURL: URL) -> [String: Any]? {
        let infoURL = appURL.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        guard let data = FileManager.default.contents(atPath: infoURL.path) else { return nil }
        do {
            return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        } catch {
            return nil
        }
    }
}
