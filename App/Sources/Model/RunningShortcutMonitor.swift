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

    /// Rescans process environments once. Safe to call while a scheduled refresh is pending.
    func refresh() async {
        let key = DataSeparationPlanner.shortcutBundleKey
        let paths = await Task.detached(priority: .utility) {
            Set(ProcessEnvironment.values(forEnvironmentKey: key).values.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        }.value
        runningBundlePaths = paths
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
