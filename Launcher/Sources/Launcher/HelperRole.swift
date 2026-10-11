import DuplicatorCore
import Foundation

/// The `--helper` role (spec §3.4 step 5, §4.6). `main.swift` calls it before anything else, so it never touches the
/// launcher's globals. It logs through its own `LaunchLogger` (the helper keeps the launcher's HOME, so this is the same
/// `<Name>.log`), re-reads `MADConfig` and arms erase-on-quit only when the data path in argv is the one `MADConfig` names:
/// argv alone can never point the erase at another folder. A malformed argv or an unreadable `MADConfig` exits 1 after
/// one log line; every other path ends in `HelperRunner.finish`. Never returns.
@MainActor
func runHelperRole(arguments argv: [String]) -> Never {
    let helperLog = LaunchLogger(name: Bundle.main.bundleURL.deletingPathExtension().lastPathComponent)
    guard let helperArguments = HelperArguments.parse(argv) else {
        helperLog.log(HelperLogLine.malformed(argumentCount: argv.count))
        exit(1)
    }
    helperLog.log(HelperLogLine.start(
        helperPID: getpid(),
        watchedPID: helperArguments.parentPID,
        bundlePath: helperArguments.bundlePath,
        dataPath: helperArguments.dataPath
    ))
    let helperConfig: ShortcutConfig
    do {
        helperConfig = try readHelperConfig()
    } catch {
        helperLog.log(HelperLogLine.watchFailed(error.localizedDescription))
        helperLog.log(HelperLogLine.exiting)
        exit(1)
    }
    var erasePath: String?
    if let requested = helperArguments.dataPath {
        if requested == HelperPlan.eraseDataPath(for: helperConfig) {
            erasePath = requested
        } else {
            helperLog.log(HelperLogLine.dataPathMismatch)
        }
    }
    let session = HelperSession(
        watchedPID: helperArguments.parentPID,
        startTime: helperArguments.startTime,
        requiresExec: true,
        erasePath: erasePath,
        home: FileManager.default.homeDirectoryForCurrentUser,
        log: helperLog
    )
    // Spec §4.6: AppKit only for the status item. The erase-only helper stays a plain kqueue wait.
    guard HelperPlan.showsMenuBarIcon(for: helperConfig) else {
        HelperRunner.runBlocking(session)
    }
    HelperMenuBarRunner.run(session, settings: HelperMenuBarSettings(
        config: helperConfig,
        bundleURL: URL(filePath: helperArguments.bundlePath, directoryHint: .isDirectory),
        targetPath: resolvedTargetPath(for: helperConfig),
        targetEnvironment: HelperEnvironment.targetEnvironment(helper: ProcessInfo.processInfo.environment)
    ))
}

/// `MADConfig` from this bundle's Info.plist, read the way `LaunchPreparer` reads it.
private func readHelperConfig() throws -> ShortcutConfig {
    guard let rawConfig = Bundle.main.infoDictionary?[ShortcutConfig.infoPlistKey] else {
        throw LauncherError.configMissing
    }
    guard let configDictionary = rawConfig as? [String: Any] else {
        throw LauncherError.configCorrupt("MADConfig is not a dictionary")
    }
    return try ShortcutConfig(plistDictionary: configDictionary)
}

/// The path New Window's `{target}` names: the app `TargetResolver` finds now (the launch resolved it the same way a
/// moment ago), or the stored path when it finds none.
private func resolvedTargetPath(for shortcutConfig: ShortcutConfig) -> String {
    do {
        return try TargetResolver().resolve(config: shortcutConfig).path
    } catch {
        return shortcutConfig.targetPath
    }
}
