import Foundation

/// Finds the target app at launch time (spec §3.4 step 3).
public struct TargetResolver {
    public init() {}

    /// The stored path when it still exists and its bundle id matches; else the first LaunchServices hit for the
    /// bundle id; else `LauncherError.targetNotFound`.
    public func resolve(config: ShortcutConfig) throws -> URL {
        let stored = URL(filePath: config.targetPath, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: stored.path),
           let info = InfoPlistReader.read(bundleAt: stored),
           info["CFBundleIdentifier"] as? String == config.targetBundleIdentifier {
            return stored
        }
        if let urls = LSCopyApplicationURLsForBundleIdentifier(config.targetBundleIdentifier as CFString, nil)?
            .takeRetainedValue() as? [URL],
           let first = urls.first {
            return first
        }
        throw LauncherError.targetNotFound(path: config.targetPath, bundleID: config.targetBundleIdentifier)
    }
}
