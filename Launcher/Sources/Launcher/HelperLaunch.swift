import Darwin
import DuplicatorCore
import Foundation

/// The parent side of the helper (spec §3.4 step 5, §4.6). In Dock Shortcut mode `main.swift` calls it just before
/// `execve`, so the helper watches this pid turn into the target. A failed spawn is logged and the launch goes on without
/// a helper: the target still starts; only the menu bar icon and erase-on-quit are missing for this run.
enum HelperLaunch {
    static func spawnIfNeeded(
        config shortcutConfig: ShortcutConfig,
        plan launchPlan: LaunchPlan,
        bundlePath: String,
        executableURL: URL?,
        baseEnvironment: [String: String],
        log launchLog: LaunchLogger
    ) {
        guard HelperPlan.isNeeded(for: shortcutConfig) else {
            return
        }
        guard let executableURL else {
            launchLog.log(HelperLogLine.spawnFailed("the shortcut bundle has no executable"))
            return
        }
        guard let startTime = ProcessStartTime.of(getpid()) else {
            launchLog.log(HelperLogLine.spawnFailed("the Launcher cannot read its own start time"))
            return
        }
        let helperArguments = HelperArguments(
            parentPID: getpid(),
            startTime: startTime,
            bundlePath: bundlePath,
            dataPath: HelperPlan.eraseDataPath(for: shortcutConfig)
        )
        let result = spawnDetached(
            executable: executableURL,
            arguments: helperArguments.arguments,
            environment: HelperEnvironment.helperEnvironment(shortcut: launchPlan.environment, base: baseEnvironment),
            workingDirectory: nil,
            isolatedStandardStreams: true
        )
        switch result {
        case .success(let pid):
            launchLog.log(HelperLogLine.spawned(pid: pid))
        case .failure(let error):
            launchLog.log(HelperLogLine.spawnFailed(error.localizedDescription))
        }
    }
}
