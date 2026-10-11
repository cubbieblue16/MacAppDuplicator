import Foundation

/// The helper role's argv (spec §3.4 step 5, §4.6):
/// `<launcher> --helper <parentPid> <startSeconds> <startMicroseconds> <bundlePath> <dataPath|->`.
/// The launcher builds it just before `execve`; `main.swift` parses it before it reads `MADConfig` or logs anything.
public struct HelperArguments: Equatable, Sendable {
    public static let flag = "--helper"
    /// Stands for "no data folder to erase".
    public static let noDataPath = "-"

    /// The process to watch: the launcher, which becomes the target when it execs.
    public var parentPID: pid_t
    /// `parentPID`'s start time, read by the launcher itself; a different value later means the pid was reused.
    public var startTime: ProcessStartTime
    /// The shortcut bundle, for the status item icon and the log.
    public var bundlePath: String
    /// The folder erase-on-quit empties, or nil.
    public var dataPath: String?

    public init(parentPID: pid_t, startTime: ProcessStartTime, bundlePath: String, dataPath: String?) {
        self.parentPID = parentPID
        self.startTime = startTime
        self.bundlePath = bundlePath
        self.dataPath = dataPath
    }

    /// argv after argv[0].
    public var arguments: [String] {
        [
            Self.flag, String(parentPID), String(startTime.seconds), String(startTime.microseconds),
            bundlePath, dataPath ?? Self.noDataPath,
        ]
    }

    /// True when `argv[1]` is exactly `--helper`. LaunchServices never passes that, so a normal launch never matches.
    public static func isHelperInvocation(_ argv: [String]) -> Bool {
        argv.count >= 2 && argv[1] == flag
    }

    /// The invocation `argv` (argv[0] included) describes, or nil unless it has exactly the shape `arguments` produces:
    /// a pid above 1, decimal start seconds, start microseconds below 1,000,000, an absolute bundle path and a
    /// non-empty data path (`-` for none).
    public static func parse(_ argv: [String]) -> HelperArguments? {
        guard argv.count == 7, argv[1] == flag,
              let pid = pid_t(argv[2]), pid > 1,
              let seconds = UInt64(argv[3]),
              let microseconds = UInt64(argv[4]), microseconds < 1_000_000,
              argv[5].hasPrefix("/"),
              !argv[6].isEmpty
        else { return nil }
        return HelperArguments(
            parentPID: pid,
            startTime: ProcessStartTime(seconds: seconds, microseconds: microseconds),
            bundlePath: argv[5],
            dataPath: argv[6] == noDataPath ? nil : argv[6]
        )
    }
}
