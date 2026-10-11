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
