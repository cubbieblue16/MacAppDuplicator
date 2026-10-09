import Foundation

extension LauncherError {
    /// Launcher process exit code (spec §4.7).
    public var exitCode: Int32 {
        switch self {
        case .configMissing, .configCorrupt:
            return 1
        case .targetNotFound, .notAnAppBundle:
            return 2
        case .execFailed:
            return 3
        case .dataPathNotWritable:
            return 4
        }
    }
}
