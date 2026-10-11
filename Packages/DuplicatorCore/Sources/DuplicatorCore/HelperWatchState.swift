import Foundation

/// The helper's decisions (spec §4.6) without system calls, so every path is unit-tested. Erase-on-quit may run only
/// after `.targetExited`: the watched launcher exec'd into the target (or the pid was the target from the start, in System
/// Launch mode) and that process then exited.
public struct HelperWatchState: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Nothing to do yet.
        case keepWatching
        /// The target quit; erase-on-quit may run.
        case targetExited(waitStatus: Int32?)
        /// The launcher exited without exec'ing, so the target never ran; never erase.
        case launcherFailed(waitStatus: Int32?)
        /// Another process has the pid now; never erase or signal.
        case pidReused
        /// The process was gone before the watch started; never erase.
        case watchedProcessGone
    }

    /// True once the watched process is known to be the target.
    public private(set) var execObserved: Bool

    /// `requiresExec` is false when the watched pid already is the target (System Launch). Otherwise an exec that happened
    /// before the kqueue registration shows as a parent executable path that differs from the helper's own: the helper
    /// runs the launcher binary its parent started from. Read both paths with `ProcessWatcher.executablePath(of:)` after
    /// the registration.
    public init(requiresExec: Bool, parentExecutablePath: String?, ownExecutablePath: String?) {
        if !requiresExec {
            execObserved = true
        } else if let parentExecutablePath, let ownExecutablePath {
            execObserved = parentExecutablePath != ownExecutablePath
        } else {
            execObserved = false
        }
    }

    /// The decision right after the registration, from the start time the launcher passed.
    public static func startupDecision(for comparison: ProcessStartTime.Comparison) -> Decision {
        switch comparison {
        case .same: .keepWatching
        case .different: .pidReused
        case .gone: .watchedProcessGone
        }
    }

    /// Folds one event in. `startTime` is a comparison read right after the event. It decides only for `.exec`: `.different`
    /// means the pid was reused, while `.gone` means the target exec'd and already exited, so the exec still counts. Exit
    /// events ignore it because the pid is free by then.
    public mutating func apply(_ event: ProcessWatchEvent, startTime: ProcessStartTime.Comparison) -> Decision {
        switch event {
        case .exec:
            if startTime == .different {
                return .pidReused
            }
            execObserved = true
            return .keepWatching
        case .exit(let waitStatus):
            return execObserved ? .targetExited(waitStatus: waitStatus) : .launcherFailed(waitStatus: waitStatus)
        }
    }
}
