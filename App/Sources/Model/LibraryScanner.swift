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

    /// Reads one bundle. Throws `ScanError.notAShortcut` for apps without `MADConfig`, `LauncherError.configCorrupt`
    /// for shortcuts whose config no longer decodes.
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

        let targetURL = URL(fileURLWithPath: config.targetPath)
        let targetExists = fileManager.fileExists(atPath: targetURL.path)
        var targetVersion: String?
        if targetExists, let bundle = Bundle(url: targetURL) {
            targetVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        }

        let modified = (try? fileManager.attributesOfItem(atPath: infoURL.path)[.modificationDate] as? Date) ?? .distantPast

        return ShortcutRecord(
            bundleURL: bundleURL, config: config, engineVersion: engineVersion,
            iconURL: hasIcon ? iconURL : nil, targetVersion: targetVersion, targetExists: targetExists, modifiedDate: modified
        )
    }
}
