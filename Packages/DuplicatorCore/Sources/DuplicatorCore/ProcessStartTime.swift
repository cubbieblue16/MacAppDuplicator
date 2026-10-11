import Foundation

/// When a process started, as `proc_pidinfo(PROC_PIDTBSDINFO)` reports it (`pbi_start_tvsec`, `pbi_start_tvusec`).
/// `execve` keeps it, so the helper can tell the launcher that became the target apart from a later process that reused
/// its pid (spec §4.6).
public struct ProcessStartTime: Hashable, Sendable {
    public var seconds: UInt64
    public var microseconds: UInt64

    public init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }
}

extension ProcessStartTime {
    /// `pid`'s start time from `proc_pidinfo(PROC_PIDTBSDINFO)`, or nil when no process has that pid.
    public static func of(_ pid: pid_t) -> ProcessStartTime? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return ProcessStartTime(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    /// How a recorded start time relates to the process that has the pid now.
    public enum Comparison: Equatable, Sendable {
        /// The same process (`execve` keeps the start time).
        case same
        /// Another process reused the pid.
        case different
        /// No process has the pid.
        case gone
    }

    public func compare(toLiveProcess pid: pid_t) -> Comparison {
        guard let live = ProcessStartTime.of(pid) else {
            return .gone
        }
        return live == self ? .same : .different
    }
}
