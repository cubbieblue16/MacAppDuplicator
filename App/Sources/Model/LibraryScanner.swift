import DuplicatorCore
import Foundation

struct ScanResult: Sendable {
    var records: [ShortcutRecord] = []
    var warnings: [String] = []
}

/// Finds shortcut bundles: depth-1 `.app` directories whose Info.plist carries `MADConfig` (spec §7).
struct LibraryScanner: Sendable {
    enum ScanError: Error, LocalizedError {
        case notAShortcut(URL)
        case unreadableInfoPlist(URL)

        var errorDescription: String? {
            switch self {
            case .notAShortcut(let url): "\(url.lastPathComponent) has no \(ShortcutConfig.infoPlistKey) entry."
            case .unreadableInfoPlist(let url): "\(url.lastPathComponent) has no readable Info.plist."
            }
        }
    }

    func scan(folders: [URL]) -> ScanResult {
        // FileManager is not Sendable, so it is not a stored property of this Sendable struct.
        let fileManager = FileManager.default
        var result = ScanResult()
        var seen = Set<String>()
        for folder in folders {
            let folderPath = folder.standardizedFileURL.path
            guard seen.insert(folderPath).inserted else { continue }
            guard let entries = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
                continue // a missing or unreadable library folder is not a warning (spec: user-added folders may be on unmounted volumes)
            }
            for entry in entries where entry.pathExtension == "app" {
                do {
                    result.records.append(try Self.record(forBundleAt: entry, fileManager: fileManager))
                } catch ScanError.notAShortcut {
                    continue // an ordinary app in the folder
                } catch {
                    result.warnings.append("\(entry.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        result.records.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result
    }

    /// Reads one bundle. Throws `ScanError.notAShortcut` for apps without `MADConfig`, `ScanError.unreadableInfoPlist`
    /// when Info.plist is missing or malformed, and whatever `ShortcutConfig(plistDictionary:)` throws when the
    /// config no longer decodes.
    static func record(forBundleAt bundleURL: URL, fileManager: FileManager = .default) throws -> ShortcutRecord {
        let infoURL = bundleURL.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        guard let data = fileManager.contents(atPath: infoURL.path),
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ScanError.unreadableInfoPlist(bundleURL)
        }
        guard let rawConfig = info[ShortcutConfig.infoPlistKey] as? [String: Any] else {
            throw ScanError.notAShortcut(bundleURL)
        }
        let config = try ShortcutConfig(plistDictionary: rawConfig)
        let engineVersion = info[ShortcutConfig.engineVersionInfoPlistKey] as? Int ?? 0

        let iconURL = bundleURL.appending(path: "Contents/Resources/AppIcon.icns", directoryHint: .notDirectory)
        let hasIcon = fileManager.fileExists(atPath: iconURL.path)

        // A web app has no target app: it is never "missing" and has no version to read. A launcher's target is the
        // item it opens or the program it runs (Phase 5); it has no version either.
        let targetURL = URL(fileURLWithPath: config.targetPath)
        let targetExists: Bool
        switch config.kind {
        case .webApp: targetExists = true
        case .file, .folder: targetExists = config.file.map { fileManager.fileExists(atPath: $0.path) } ?? false
        case .cli: targetExists = config.cli.map { fileManager.fileExists(atPath: $0.executablePath) } ?? false
        case .app: targetExists = fileManager.fileExists(atPath: targetURL.path)
        }
        // Read the target's Info.plist directly: `Bundle(url:)` caches one instance per path for the process lifetime,
        // so a target updated while this app runs would keep reporting its old version. An unreadable plist means
        // "version unknown", which is what nil expresses.
        var targetVersion: String?
        let targetInfoURL = targetURL.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        if targetExists, config.kind == .app,
           let targetInfoData = fileManager.contents(atPath: targetInfoURL.path),
           let targetInfo = (try? PropertyListSerialization.propertyList(from: targetInfoData, format: nil)) as? [String: Any] {
            targetVersion = targetInfo["CFBundleShortVersionString"] as? String
        }

        let modified = (try? fileManager.attributesOfItem(atPath: infoURL.path)[.modificationDate] as? Date) ?? .distantPast

        return ShortcutRecord(
            bundleURL: bundleURL, config: config, engineVersion: engineVersion,
            iconURL: hasIcon ? iconURL : nil, targetVersion: targetVersion, targetExists: targetExists, modifiedDate: modified
        )
    }
}
