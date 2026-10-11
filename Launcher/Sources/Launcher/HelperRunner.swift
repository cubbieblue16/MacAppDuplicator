import Darwin
import DuplicatorCore
import Foundation

/// What one helper watches and, when armed, erases (spec §4.3, §4.6).
struct HelperSession: Sendable {
    /// Dock Shortcut mode: the launcher's pid, which then execs into the target. System Launch: the target's pid.
    var watchedPID: pid_t
    /// The start time recorded for `watchedPID` before the watch; any other start time means the pid was reused.
    var startTime: ProcessStartTime
    /// True when the watched process must exec before its exit counts as the target's exit (Dock Shortcut mode).
    var requiresExec: Bool
    /// The data folder to empty after the target quits, already matched against `MADConfig`; nil means no erase.
    var erasePath: String?
    /// The real home folder, for `EraseOnQuitPolicy`.
    var home: URL
    var log: LaunchLogger
}

/// How a watch ended. Only `targetExited` may lead to an erase.
enum HelperWatchEnd: Equatable, Sendable {
    case targetExited(waitStatus: Int32?)
    case launcherFailed(waitStatus: Int32?)
    case pidReused
    case watchedProcessGone
    case watchFailed(String)

    /// The `HelperLogLine` for this end.
    var logLine: String {
        switch self {
        case .targetExited(let waitStatus): HelperLogLine.targetExited(waitStatus: waitStatus)
        case .launcherFailed(let waitStatus): HelperLogLine.launcherFailed(waitStatus: waitStatus)
        case .pidReused: HelperLogLine.pidReused
        case .watchedProcessGone: HelperLogLine.watchedProcessGone
        case .watchFailed(let reason): HelperLogLine.watchFailed(reason)
        }
    }
}

/// Drives one `ProcessWatcher` through `HelperWatchState` in the order the watch needs: register the kqueue first, then
/// compare the start time, then read both executable paths (an exec that raced the registration shows there), then fold
/// each batch of events with a fresh start-time comparison. `run()` blocks (the erase-only helper); the menu bar helper
/// calls `start()` once and then `handle(_:)` from a read source on `watcher.fileDescriptor`. Not Sendable: one owner
/// drives it.
final class HelperWatch {
    let session: HelperSession
    private(set) var watcher: ProcessWatcher?
    private var state: HelperWatchState?

    init(session: HelperSession) {
        self.session = session
    }

    /// Registers the watch. Returns how the watch already ended, or nil when events should be awaited.
    func start() -> HelperWatchEnd? {
        let pid = session.watchedPID
        let newWatcher: ProcessWatcher
        do {
            newWatcher = try ProcessWatcher(pid: pid)
        } catch ProcessWatcherError.processGone {
            return .watchedProcessGone
        } catch {
            return .watchFailed(String(describing: error))
        }
        watcher = newWatcher
        if let end = Self.end(for: HelperWatchState.startupDecision(for: session.startTime.compare(toLiveProcess: pid))) {
            return end
        }
        let newState = HelperWatchState(
            requiresExec: session.requiresExec,
            parentExecutablePath: ProcessWatcher.executablePath(of: pid),
            ownExecutablePath: ProcessWatcher.executablePath(of: getpid())
        )
        state = newState
        if session.requiresExec && newState.execObserved {
            session.log.log(HelperLogLine.execObserved)
        }
        return nil
    }

    /// Folds one batch of events in. Returns how the watch ended, or nil to keep watching.
    func handle(_ events: [ProcessWatchEvent]) -> HelperWatchEnd? {
        guard var current = state else {
            return .watchFailed("an event arrived before the watch started")
        }
        var end: HelperWatchEnd?
        for event in events where end == nil {
            let wasObserved = current.execObserved
            let decision = current.apply(event, startTime: session.startTime.compare(toLiveProcess: session.watchedPID))
            if !wasObserved && current.execObserved {
                session.log.log(HelperLogLine.execObserved)
            }
            end = Self.end(for: decision)
        }
        state = current
        return end
    }

    /// Blocks in `kevent` until the watch ends.
    func run() -> HelperWatchEnd {
        if let end = start() {
            return end
        }
        guard let watcher else {
            return .watchFailed("the watch did not start")
        }
        while true {
            let events: [ProcessWatchEvent]
            do {
                events = try watcher.wait(timeout: nil)
            } catch {
                return .watchFailed(String(describing: error))
            }
            if let end = handle(events) {
                return end
            }
        }
    }

    /// The end a decision means, or nil for `keepWatching`.
    static func end(for decision: HelperWatchState.Decision) -> HelperWatchEnd? {
        switch decision {
        case .keepWatching:
            return nil
        case .targetExited(let waitStatus):
            return .targetExited(waitStatus: waitStatus)
        case .launcherFailed(let waitStatus):
            return .launcherFailed(waitStatus: waitStatus)
        case .pidReused:
            return .pidReused
        case .watchedProcessGone:
            return .watchedProcessGone
        }
    }
}

/// The helper's ending, shared by the erase-only helper (here) and the menu bar helper.
enum HelperRunner {
    /// The erase-only helper: blocks until the watch ends, then finishes. Never creates `NSApplication`, so the helper
    /// never checks in with LaunchServices and shows nowhere.
    static func runBlocking(_ session: HelperSession) -> Never {
        finish(HelperWatch(session: session).run(), session: session)
    }

    /// Logs how the watch ended, erases only when it ended with the target's exit, logs `helper exit` and exits 0. Once
    /// the watch has started the helper always exits 0: nothing waits for its status, and every outcome is in the log.
    static func finish(_ end: HelperWatchEnd, session: HelperSession) -> Never {
        session.log.log(end.logLine)
        if case .targetExited = end {
            eraseIfArmed(session)
        }
        session.log.log(HelperLogLine.exiting)
        exit(0)
    }

    /// Empties the data folder when erase-on-quit is armed, no other copy of this shortcut's binary is running (a second
    /// launch may still be using the folder) and `EraseOnQuitPolicy` accepts the folder. Every outcome is logged.
    static func eraseIfArmed(_ session: HelperSession) {
        guard let erasePath = session.erasePath else {
            return
        }
        guard let ownPath = ProcessWatcher.executablePath(of: getpid()) else {
            session.log.log(HelperLogLine.ownPathUnreadable)
            return
        }
        let others = ProcessWatcher.pids(runningFrom: ownPath).filter { $0 != getpid() }
        guard others.isEmpty else {
            session.log.log(HelperLogLine.otherCopiesRunning(pids: others))
            return
        }
        switch EraseOnQuitPolicy.check(dataPath: erasePath, home: session.home) {
        case .success(let folder):
            let outcome = EraseOnQuitPerformer.erase(at: folder)
            session.log.log(HelperLogLine.erased(path: folder.path, removed: outcome.removed, failed: outcome.failures.count))
        case .failure(let refusal):
            session.log.log(HelperLogLine.eraseSkipped(refusal.logReason))
        }
    }
}
