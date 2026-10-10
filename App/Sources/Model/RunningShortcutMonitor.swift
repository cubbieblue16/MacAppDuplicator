import AppKit
import DuplicatorCore
import Observation

/// Which shortcut bundles currently have a live process. After `execve` the target checks in under its own bundle,
/// so NSRunningApplication cannot tell shortcuts apart; the launcher's `MAD_SHORTCUT_BUNDLE` env entry can (spec §7).
@MainActor
@Observable
final class RunningShortcutMonitor {
    /// Standardized paths of shortcut bundles with at least one running process.
    private(set) var runningBundlePaths: Set<String> = []

    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private let probe: @Sendable () -> Set<String>
    /// Bumped by every `refresh()`; only the newest refresh may publish its paths (final review M7).
    @ObservationIgnored private var refreshGeneration: UInt64 = 0

    /// `probe` lists the standardized bundle paths of running shortcuts; it runs detached, off the main actor.
    /// Tests inject a stub. The default is a nonisolated closure, never a main-actor value.
    init(probe: @escaping @Sendable () -> Set<String> = { RunningShortcutMonitor.liveRunningBundlePaths() }) {
        self.probe = probe
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        scheduleRefresh()
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Rescans process environments once. Safe to call while a scheduled refresh is pending: overlapping refreshes
    /// can finish out of order, so only the newest one publishes its paths (final review M7).
    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let probe = probe
        let paths = await Task.detached(priority: .utility) { probe() }.value
        guard generation == refreshGeneration else { return }
        runningBundlePaths = paths
    }

    /// Standardized paths from every process's `MAD_SHORTCUT_BUNDLE` entry (spec §7). Nonisolated because it runs
    /// detached; the body is the expression `refresh()` ran inline before the seam existed.
    nonisolated static func liveRunningBundlePaths() -> Set<String> {
        let key = DataSeparationPlanner.shortcutBundleKey
        return Set(ProcessEnvironment.values(forEnvironmentKey: key).values.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }

    func isRunning(bundleURL: URL) -> Bool {
        runningBundlePaths.contains(bundleURL.standardizedFileURL.path)
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            // LaunchServices check-in happens up to ~1 s after exec; wait so a fresh launch is seen with its final env.
            do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
            await self?.refresh()
        }
    }
}
