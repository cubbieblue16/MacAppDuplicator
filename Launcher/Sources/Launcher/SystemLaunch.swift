import AppKit
import DuplicatorCore
import os

/// System Launch mode: asks LaunchServices to start the target as its own application instance, then exits.
/// Exits 0 after a successful launch; any failure goes through `fail`, which exits 3.
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
    NSWorkspace.shared.openApplication(at: prepared.app.bundleURL, configuration: configuration) { _, error in
        failure.withLock { $0 = error?.localizedDescription }
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
    exit(0)
}
