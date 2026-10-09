import AppKit
import DuplicatorCore

let shortcutName = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
let logger = LaunchLogger(name: shortcutName)
logger.log("start pid=\(getpid()) bundle=\(Bundle.main.bundlePath)")

let base = ProcessInfo.processInfo.environment
let realHome = FileManager.default.homeDirectoryForCurrentUser

let prepared: PreparedLaunch
do {
    prepared = try LaunchPreparer(realHome: realHome).prepare(
        infoDictionary: Bundle.main.infoDictionary ?? [:],
        shortcutBundleURL: Bundle.main.bundleURL,
        baseEnvironment: base
    )
} catch {
    fail(error, logger: logger)
}

let config = prepared.config
let plan = prepared.plan
logger.log("config name=\(config.name) mode=\(config.launchMode) data=\(config.dataMode)")
logger.log("target \(plan.executableURL.path)")
for warning in plan.warnings {
    logger.log("warning \(warning)")
}
logger.log("argv \(plan.arguments.joined(separator: " "))")
logger.log("mode \(plan.launchMode)")
logger.log(environment: plan.environment)

spawnHelperIfNeeded(config: config)

/// Fork point for the helper role (spec §4.6: status item, process watch, erase-on-quit). Phase 6 implements it;
/// until then it intentionally does nothing, and the call site exists so the launch order in spec §3.4 step 5 is fixed.
func spawnHelperIfNeeded(config: ShortcutConfig) {
    _ = config
}

/// Stand-in until Task 5 adds the real System Launch path.
@MainActor
func launchViaSystem(prepared: PreparedLaunch, logger: LaunchLogger) -> Never {
    fail(LauncherError.execFailed(errno: ENOTSUP, path: prepared.plan.executableURL.path), logger: logger)
}

if plan.launchMode == .systemLaunch {
    logger.log("system launch")
    launchViaSystem(prepared: prepared, logger: logger)
}

// Dock Shortcut mode (spec §4.1). LaunchServices started this process as the shortcut bundle, so the Dock draws the tile from the shortcut: title is the bundle file name, icon is `CFBundleIconFile`. After `execve`, the target's `LSApplicationCheckIn` (about 0.5 to 1 s later) re-registers this process under the target's bundle id and path, so `lsappinfo`, Activity Monitor and `NSRunningApplication` report the target. The Dock does not redraw on check-in, so the tile keeps the shortcut's name and icon for the life of the process.
logger.log("exec")
let execErrno = execTarget(plan)
fail(LauncherError.execFailed(errno: execErrno, path: plan.executableURL.path), logger: logger)
