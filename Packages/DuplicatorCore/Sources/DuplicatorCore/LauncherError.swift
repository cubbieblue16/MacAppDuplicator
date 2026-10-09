import Foundation

/// Every failure the launcher reports (spec §4.7). Exit codes live in `LauncherError+ExitCode.swift`.
public enum LauncherError: Error, LocalizedError {
    case configMissing
    case configCorrupt(String)
    case targetNotFound(path: String, bundleID: String)
    case dataPathNotWritable(String)
    case execFailed(errno: Int32, path: String)
    case notAnAppBundle(String)

    public var errorDescription: String? {
        switch self {
        case .configMissing:
            return "Shortcut is damaged — open macOS App Duplicator and Regenerate. (MADConfig is missing.)"
        case .configCorrupt(let detail):
            return "Shortcut is damaged — open macOS App Duplicator and Regenerate. (\(detail))"
        case .targetNotFound(let path, let bundleID):
            return "The target app was not found.\nStored path: \(path)\nBundle ID: \(bundleID)"
        case .dataPathNotWritable(let path):
            return "The data folder is not writable: \(path)"
        case .execFailed(let code, let path):
            return "Could not start \(path): \(String(cString: strerror(code)))"
        case .notAnAppBundle(let path):
            return "\(path) is not a valid application bundle."
        }
    }
}
