import AppKit
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

/// What the AppKit helper shows and runs, fixed when the helper starts (spec §4.6): an edit to the shortcut reaches the
/// helper at the shortcut's next launch.
struct HelperMenuBarSettings: Sendable {
    /// The shortcut's name, for Show <name>, Quit <name> and the tooltip.
    var name: String
    /// The shortcut bundle, for its icon.
    var bundleURL: URL
    /// False for a System Launch helper that runs only for erase-on-quit.
    var showsStatusItem: Bool
    /// The New Window argv (`argv[0]` absolute), or nil when the item is hidden.
    var newWindowArguments: [String]?
    /// The environment New Window runs with: the target's own, home variables included.
    var targetEnvironment: [String: String]

    init(config: ShortcutConfig, bundleURL: URL, targetPath: String, targetEnvironment: [String: String]) {
        name = config.name
        self.bundleURL = bundleURL
        showsStatusItem = HelperPlan.showsMenuBarIcon(for: config)
        newWindowArguments = HelperPlan.newWindowArguments(for: config, targetPath: targetPath)
        self.targetEnvironment = targetEnvironment
    }
}

/// The AppKit helper (spec §4.6): an `.accessory` `NSApplication` (no Dock tile, no menu bar of its own) that drives the
/// same `HelperWatch` as the erase-only helper from a read source on the watcher's kqueue, so the run loop keeps serving
/// the status item while the watch waits. Every end of the watch goes through `HelperRunner.finish`, erase included.
/// Show and a reopen of the shortcut bring the target forward, New Window runs the shortcut's New Window command, and
/// Quit sends the target `SIGTERM`, then `SIGKILL` after `killDelay` seconds if the same process still runs.
@MainActor
final class HelperMenuBarRunner: NSObject, NSApplicationDelegate {
    /// Seconds between Quit's `SIGTERM` and the `SIGKILL` for a target that is still running (spec §4.6).
    static let killDelay: TimeInterval = 10

    private let watch: HelperWatch
    private let watcher: ProcessWatcher
    private let settings: HelperMenuBarSettings
    private var statusItem: HelperStatusItem?
    private var eventSource: DispatchSourceRead?

    private init(watch: HelperWatch, watcher: ProcessWatcher, settings: HelperMenuBarSettings) {
        self.watch = watch
        self.watcher = watcher
        self.settings = settings
        super.init()
    }

    /// Starts the watch, becomes an `.accessory` application and runs AppKit until the watch ends. A watch that ends
    /// before AppKit starts finishes at once. Never returns.
    static func run(_ session: HelperSession, settings: HelperMenuBarSettings) -> Never {
        let watch = HelperWatch(session: session)
        if let end = watch.start() {
            HelperRunner.finish(end, session: session)
        }
        guard let watcher = watch.watcher else {
            HelperRunner.finish(.watchFailed("the watch did not start"), session: session)
        }
        let runner = HelperMenuBarRunner(watch: watch, watcher: watcher, settings: settings)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        // `NSApplication.delegate` is weak; `withExtendedLifetime` keeps the runner alive while AppKit runs.
        application.delegate = runner
        runner.startEventSource()
        withExtendedLifetime(runner) {
            application.run()
        }
        HelperRunner.finish(.watchFailed("the application run loop stopped"), session: session)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard settings.showsStatusItem else {
            return
        }
        var onNewWindow: (@MainActor () -> Void)?
        if settings.newWindowArguments != nil {
            onNewWindow = { [weak self] in self?.newWindow() }
        }
        statusItem = HelperStatusItem(
            name: settings.name,
            icon: HelperStatusItem.shortcutIcon(bundleURL: settings.bundleURL),
            onShow: { [weak self] in self?.show() },
            onNewWindow: onNewWindow,
            onQuit: { [weak self] in self?.quit() }
        )
    }

    /// Opening the shortcut again while this helper is its running instance shows the target instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return false
    }

    /// The kqueue descriptor is readable while an event is pending; each wake-up polls and folds the events in.
    private func startEventSource() {
        let source = DispatchSource.makeReadSource(fileDescriptor: watcher.fileDescriptor, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.drainEvents() }
        }
        eventSource = source
        source.resume()
    }

    private func drainEvents() {
        let events: [ProcessWatchEvent]
        do {
            events = try watcher.wait(timeout: 0)
        } catch {
            HelperRunner.finish(.watchFailed(String(describing: error)), session: watch.session)
        }
        if let end = watch.handle(events) {
            HelperRunner.finish(end, session: watch.session)
        }
    }

    /// Unhides the target and asks macOS to activate it with all its windows: cooperatively first (this helper yields
    /// its activation), then directly. A target that is gone, a reused pid and a refused activation are logged.
    private func show() {
        let pid = watch.session.watchedPID
        guard watch.session.startTime.compare(toLiveProcess: pid) == .same,
              let target = NSRunningApplication(processIdentifier: pid) else {
            watch.session.log.log(HelperLogLine.showFailed("pid \(pid) is not a running application"))
            return
        }
        _ = target.unhide()
        NSApplication.shared.yieldActivation(to: target)
        if !target.activate(from: NSRunningApplication.current, options: [.activateAllWindows]),
           !target.activate(options: [.activateAllWindows]) {
            watch.session.log.log(HelperLogLine.showFailed("macOS refused to activate pid \(pid)"))
        }
    }

    /// Spec §4.6: `SIGTERM` now, `SIGKILL` after `killDelay` seconds if the same process still runs. The watch sees the
    /// exit and finishes the helper as for any other quit, erase included.
    private func quit() {
        signalTarget(SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.killDelay) { [weak self] in
            MainActor.assumeIsolated { self?.signalTarget(SIGKILL) }
        }
    }

    /// Signals the watched pid only while its start time still matches, so a reused pid is never signalled.
    private func signalTarget(_ signalNumber: Int32) {
        let pid = watch.session.watchedPID
        guard watch.session.startTime.compare(toLiveProcess: pid) == .same else {
            return
        }
        if kill(pid, signalNumber) == 0 {
            watch.session.log.log(HelperLogLine.quit(signal: signalNumber))
        }
    }

    /// Runs the New Window argv detached, with the target's environment and `/dev/null` on its standard streams.
    private func newWindow() {
        guard let argv = settings.newWindowArguments, let program = argv.first else {
            return
        }
        let result = spawnDetached(
            executable: URL(filePath: program),
            arguments: Array(argv.dropFirst()),
            environment: settings.targetEnvironment,
            workingDirectory: nil,
            isolatedStandardStreams: true
        )
        switch result {
        case .success(let pid):
            watch.session.log.log(HelperLogLine.newWindow(argv: argv))
            Self.reap(pid)
        case .failure(let error):
            watch.session.log.log(HelperLogLine.newWindowFailed(error.localizedDescription))
        }
    }

    /// Collects a New Window child's exit status on a background thread, so a short-lived `open` never stays a zombie
    /// of the helper.
    nonisolated private static func reap(_ pid: pid_t) {
        Thread.detachNewThread {
            var status: Int32 = 0
            var result = waitpid(pid, &status, 0)
            while result < 0 && errno == EINTR {
                result = waitpid(pid, &status, 0)
            }
        }
    }
}
