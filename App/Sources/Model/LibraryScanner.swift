import DuplicatorCore
import Foundation

struct ScanResult: Sendable {
    var records: [ShortcutRecord] = []
    var warnings: [String] = []
}

/// What `LibraryScanner` compares each bundle against to decide its provenance (security C3). The default trusts
/// nothing, so every bundle reads as foreign: only a caller that knows what this install writes can vouch for a bundle.
struct ScanTrust: Sendable, Equatable {
    /// This install's `MADInstallToken` (`AppSettings.installToken`).
    var installToken: String?
    /// The signature the configured signing identity produces (`AppSettings.expectedSignature`); nil matches none.
    var expectedSignature: CodeSignature?
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

    func scan(folders: [URL], trust: ScanTrust = ScanTrust()) -> ScanResult {
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
                    result.records.append(try Self.record(forBundleAt: entry, fileManager: fileManager, trust: trust))
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
    /// config no longer decodes. `trust` decides `provenance`; the default trusts nothing.
    static func record(forBundleAt bundleURL: URL, fileManager: FileManager = .default, trust: ScanTrust = ScanTrust()) throws -> ShortcutRecord {
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

        let provenance = Self.provenance(
            infoPlist: info, bundleURL: bundleURL, installToken: trust.installToken, expectedSignature: trust.expectedSignature
        )

        return ShortcutRecord(
            bundleURL: bundleURL, config: config, engineVersion: engineVersion,
            iconURL: hasIcon ? iconURL : nil, targetVersion: targetVersion, targetExists: targetExists, modifiedDate: modified,
            provenance: provenance
        )
    }

    /// The xattr macOS puts on anything downloaded or received (browsers, Mail, Messages, AirDrop, archive tools).
    static let quarantineAttribute = "com.apple.quarantine"

    /// Decides whether this install wrote the bundle (security C3). A bundle carrying `MADConfig` is only data, so the
    /// app must not regenerate and sign one it did not write. In order:
    /// 1. a quarantine flag means downloaded or received, whatever the bundle claims: foreign;
    /// 2. this install's token: own;
    /// 3. any other token: written by a different App Duplicator install, foreign;
    /// 4. no token (bundles written before the token existed, and madctl's): own only when it is signed the way the
    ///    configured identity signs (`expectedSignature`); an unsigned bundle never is.
    /// `signature` reads the bundle's signature; tests inject it to cover a Developer ID signer they cannot sign with.
    static func provenance(
        infoPlist: [String: Any], bundleURL: URL, installToken: String?, expectedSignature: CodeSignature?,
        signature: (URL) -> CodeSignature = { CodeSignature.of(bundleAt: $0) }
    ) -> ShortcutRecord.Provenance {
        if isQuarantined(bundleURL) {
            return .foreign(reason: "downloaded or received (quarantined)")
        }
        if let stamped = infoPlist[ShortcutConfig.installTokenInfoPlistKey] {
            if let installToken, !installToken.isEmpty, stamped as? String == installToken { return .own }
            return .foreign(reason: "built by a different App Duplicator install")
        }
        let actual = signature(bundleURL)
        if actual != .unknown, actual == expectedSignature { return .own }
        switch actual {
        case .identity(let name): return .foreign(reason: "signed by \(name)")
        case .adHoc: return .foreign(reason: "signed ad hoc, not by your signing identity")
        case .unknown: return .foreign(reason: "unsigned")
        }
    }

    /// True when the bundle, or its Info.plist, carries the quarantine flag. Both are checked because Finder copies and
    /// archive tools flag every file, while a non-recursive `xattr -d` clears only the bundle folder. A symlinked entry
    /// is checked both as the link and as the folder it points to.
    static func isQuarantined(_ bundleURL: URL) -> Bool {
        let info = bundleURL.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        return [bundleURL, info].contains { url in
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return false }
                return getxattr(path, quarantineAttribute, nil, 0, 0, 0) >= 0
                    || getxattr(path, quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
            }
        }
    }
}
