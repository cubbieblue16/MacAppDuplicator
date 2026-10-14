import AppKit
import DuplicatorCore
import os

/// System Launch mode: asks LaunchServices to start the target as its own application instance. Without a helper the
/// Launcher then exits 0; with one (spec §4.6: menu bar icon or erase-on-quit) this process stays as the target's helper.
/// Any launch failure goes through `fail`, which exits 3.
@MainActor
func launchViaSystem(prepared: PreparedLaunch, logger: LaunchLogger) -> Never {
    let plan = prepared.plan
    let bundlePath = prepared.app.bundleURL.path

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = plan.arguments
    // LaunchServices merges these over its own environment, so only the differences are sent.
    configuration.environment = plan.environmentAdditions(relativeTo: ProcessInfo.processInfo.environment)
    configuration.createsNewApplicationInstance = true
    configuration.activates = true

    let done = DispatchSemaphore(value: 0)
    let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
    let targetPID = OSAllocatedUnfairLock<pid_t?>(initialState: nil)
    // `@Sendable`: the handler's queue is not documented, and it touches only the two locks and the semaphore.
    NSWorkspace.shared.openApplication(at: prepared.app.bundleURL, configuration: configuration) { @Sendable application, error in
        failure.withLock { $0 = error?.localizedDescription }
        targetPID.withLock { $0 = application?.processIdentifier }
        done.signal()
    }

    // The completion handler's queue is not documented, so the main thread must not block on the semaphore.
    // Pump the run loop while polling it, with a 30 s deadline.
    let deadline = Date(timeIntervalSinceNow: 30)
    var completed = false
    while !completed, Date() < deadline {
        completed = done.wait(timeout: .now()) == .success
        if !completed {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    guard completed else {
        logger.log("system launch failed: timed out after 30 s")
        fail(LauncherError.execFailed(errno: ETIMEDOUT, path: bundlePath), logger: logger)
    }
    if let message = failure.withLock({ $0 }) {
        logger.log("system launch failed: \(message)")
        fail(LauncherError.execFailed(errno: EIO, path: bundlePath), logger: logger)
    }
    logger.log("system launch ok")
    guard HelperPlan.isNeeded(for: prepared.config) else {
        exit(0)
    }
    let launchedPID = targetPID.withLock { $0 }
    runSystemLaunchHelper(prepared: prepared, targetPID: launchedPID, logger: logger)
}

/// Spec §4.6 in System Launch mode: this process becomes the helper of the pid LaunchServices returned. The target was
/// never this process, so no exec is awaited (`requiresExec` false), and its start time is read now. LaunchServices
/// started this process as the shortcut, so it always becomes an `.accessory` application through
/// `HelperMenuBarRunner`, with a status item only when the menu bar icon is on. A missing pid or a target already gone
/// ends the helper after one line. Never returns.
@MainActor
private func runSystemLaunchHelper(prepared: PreparedLaunch, targetPID: pid_t?, logger: LaunchLogger) -> Never {
    guard let pid = targetPID, pid > 0 else {
        logger.log(HelperLogLine.watchFailed("LaunchServices returned no process id for the target"))
        logger.log(HelperLogLine.exiting)
        exit(0)
    }
    guard let startTime = ProcessStartTime.of(pid) else {
        logger.log(HelperLogLine.watchedProcessGone)
        logger.log(HelperLogLine.exiting)
        exit(0)
    }
    let erasePath = HelperPlan.eraseDataPath(for: prepared.config)
    logger.log(HelperLogLine.start(helperPID: getpid(), watchedPID: pid, bundlePath: Bundle.main.bundlePath, dataPath: erasePath))
    let session = HelperSession(
        watchedPID: pid,
        startTime: startTime,
        requiresExec: false,
        erasePath: erasePath,
        bundleIdentifier: prepared.config.bundleIdentifier,
        home: FileManager.default.homeDirectoryForCurrentUser,
        log: logger
    )
    HelperMenuBarRunner.run(session, settings: HelperMenuBarSettings(
        config: prepared.config,
        bundleURL: Bundle.main.bundleURL,
        targetPath: prepared.app.bundleURL.path,
        targetEnvironment: prepared.plan.environment
    ))
}
