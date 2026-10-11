import Foundation

extension LauncherError {
    /// Launcher process exit code (spec §4.7).
    public var exitCode: Int32 {
        switch self {
        case .configMissing, .configCorrupt, .launcherConfigMissing:
            return 1
        case .targetNotFound, .notAnAppBundle, .fileNotFound:
            return 2
        case .execFailed, .spawnFailed, .terminalScriptFailed:
            return 3
        case .dataPathNotWritable:
            return 4
        case .terminalNotFound:
            return 5
        }
    }
}
