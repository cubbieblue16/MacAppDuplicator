import AppKit
import DuplicatorCore

let shortcutName = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
let logger = LaunchLogger(name: shortcutName)
logger.log("start pid=\(getpid()) bundle=\(Bundle.main.bundlePath)")

let base = ProcessInfo.processInfo.environment
let realHome = FileManager.default.homeDirectoryForCurrentUser

let shortcut: PreparedShortcut
do {
    shortcut = try LaunchPreparer(realHome: realHome).prepareShortcut(
        infoDictionary: Bundle.main.infoDictionary ?? [:],
        shortcutBundleURL: Bundle.main.bundleURL,
        baseEnvironment: base,
        realHome: realHome,
        terminalLocator: { choice in
            choice.bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        }
    )
} catch {
    fail(error, logger: logger)
}

// File, folder and command shortcuts (spec §6) open or spawn, then exit; every branch below ends in `exit` or `fail`.
// App shortcuts fall through to the unchanged Phase 1 path. Web app bundles never reach here: `prepareShortcut`
// rejects them with `configCorrupt`, because they run WebShell.
let prepared: PreparedLaunch
switch shortcut {
case .app(let launch):
    prepared = launch
case .launcher(let action, let launcherConfig):
    logger.log("kind \(launcherConfig.kind.rawValue)")
    switch action {
    case .open(let items, let openerApp):
        openItems(items, openerApp: openerApp, logger: logger)
    case .spawn(let executable, let arguments, let displayArguments, let environment, let workingDirectory, let terminal):
        logger.log("spawn \(executable.path) argc=\(arguments.count + 1) terminal=\(terminal.rawValue)")
        // Never the raw argv: for Terminal.app and iTerm2 it is an AppleScript holding the whole command and its inline
        // environment in clear text. `displayArguments` is the user's command with secret values masked.
        logger.log(arguments: displayArguments)
        logger.log(environment: environment)
        switch spawnDetached(executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory) {
        case .success(let pid):
            logger.log("spawned pid=\(pid)")
            logger.log("exit 0")
            exit(0)
        case .failure(let error):
            fail(error, logger: logger)
        }
    }
}

let config = prepared.config
let plan = prepared.plan
logger.log("config name=\(config.name) mode=\(config.launchMode) data=\(config.dataMode)")
logger.log("target \(plan.executableURL.path)")
for warning in plan.warnings {
    logger.log("warning \(warning)")
}
logger.log(arguments: plan.arguments)
logger.log("mode \(plan.launchMode)")
logger.log(environment: plan.environment)

spawnHelperIfNeeded(config: config)

/// Fork point for the helper role (spec §4.6: status item, process watch, erase-on-quit). Phase 6 implements it;
/// until then it intentionally does nothing, and the call site exists so the launch order in spec §3.4 step 5 is fixed.
func spawnHelperIfNeeded(config: ShortcutConfig) {
    _ = config
}

if plan.launchMode == .systemLaunch {
    logger.log("system launch")
    launchViaSystem(prepared: prepared, logger: logger)
}

// Dock Shortcut mode (spec §4.1). LaunchServices started this process as the shortcut bundle, so the Dock draws the tile from the shortcut: title is the bundle file name, icon is `CFBundleIconFile`. After `execve`, the target's `LSApplicationCheckIn` (about 0.5 to 1 s later) re-registers this process under the target's bundle id and path, so `lsappinfo`, Activity Monitor and `NSRunningApplication` report the target. The Dock does not redraw on check-in, so the tile keeps the shortcut's name and icon for the life of the process.
logger.log("exec")
let execErrno = execTarget(plan)
fail(LauncherError.execFailed(errno: execErrno, path: plan.executableURL.path), logger: logger)
