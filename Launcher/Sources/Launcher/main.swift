import AppKit
import DuplicatorCore

// Spec §3.4 step 5, §4.6: the helper role runs before anything below. A helper never logs a launcher `start` line, never
// prepares a launch and never touches the globals below, which stay uninitialised in a helper process.
if HelperArguments.isHelperInvocation(CommandLine.arguments) {
    runHelperRole(arguments: CommandLine.arguments)
}

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
        switch terminal {
        case .terminal, .iterm2:
            // `osascript` opens the terminal, types the command in and exits. Waiting for it is the only way to see a
            // failed script, such as a denied Automation permission (-1743), which would otherwise vanish silently.
            switch spawnAndWait(executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory) {
            case .success(let result) where result.status == 0:
                logger.log("osascript exit 0")
                logger.log("exit 0")
                exit(0)
            case .success(let result):
                // The shortcut bundle's own identifier is the one Automation (TCC) records for this shortcut.
                let bundleIdentifier = Bundle.main.bundleIdentifier ?? launcherConfig.bundleIdentifier
                fail(
                    LauncherError.terminalScriptFailed(
                        status: result.status, stderr: result.stderr, terminal: terminal, bundleIdentifier: bundleIdentifier
                    ),
                    logger: logger
                )
            case .failure(let error):
                fail(error, logger: logger)
            }
        case .none, .ghostty:
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

if plan.launchMode == .systemLaunch {
    logger.log("system launch")
    launchViaSystem(prepared: prepared, logger: logger)
}

// Spec §3.4 step 5: in Dock Shortcut mode the helper starts just before exec, so it watches this pid become the target.
// System Launch never reaches this line (`launchViaSystem` never returns). A failed spawn is logged and the launch goes on.
HelperLaunch.spawnIfNeeded(
    config: config,
    plan: plan,
    bundlePath: Bundle.main.bundlePath,
    executableURL: Bundle.main.executableURL,
    baseEnvironment: base,
    log: logger
)

// Dock Shortcut mode (spec §4.1). LaunchServices started this process as the shortcut bundle, so the Dock draws the tile from the shortcut: title is the bundle file name, icon is `CFBundleIconFile`. After `execve`, the target's `LSApplicationCheckIn` (about 0.5 to 1 s later) re-registers this process under the target's bundle id and path, so `lsappinfo`, Activity Monitor and `NSRunningApplication` report the target. The Dock does not redraw on check-in, so the tile keeps the shortcut's name and icon for the life of the process.
logger.log("exec")
let execErrno = execTarget(plan)
fail(LauncherError.execFailed(errno: execErrno, path: plan.executableURL.path), logger: logger)
