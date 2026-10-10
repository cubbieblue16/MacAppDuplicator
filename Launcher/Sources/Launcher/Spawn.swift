import Darwin
import DuplicatorCore
import Foundation

/// Starts a command shortcut's process and returns without waiting for it (spec §6). `POSIX_SPAWN_SETSID` puts the
/// child in its own session, so it outlives the Launcher (which exits right after) and is re-parented to launchd.
/// `environment` is the complete environment, passed as sorted `KEY=VALUE` strings like `execTarget`; a non-nil
/// `workingDirectory` becomes the child's current directory. Every `strdup` copy is freed before returning.
/// - Returns: the child's pid, or `LauncherError.spawnFailed` with the `posix_spawn*` error code.
func spawnDetached(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    workingDirectory: URL?
) -> Result<pid_t, LauncherError> {
    let path = executable.path
    let argv = [path] + arguments
    let envp = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    var cEnvp: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) } + [nil]
    defer {
        cArgv.forEach { free($0) }
        cEnvp.forEach { free($0) }
    }

    var attributes: posix_spawnattr_t?
    var code = posix_spawnattr_init(&attributes)
    guard code == 0 else {
        return .failure(.spawnFailed(errno: code, path: path))
    }
    defer { posix_spawnattr_destroy(&attributes) }
    code = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
    guard code == 0 else {
        return .failure(.spawnFailed(errno: code, path: path))
    }

    var fileActions: posix_spawn_file_actions_t?
    code = posix_spawn_file_actions_init(&fileActions)
    guard code == 0 else {
        return .failure(.spawnFailed(errno: code, path: path))
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    if let workingDirectory {
        code = posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory.path)
        guard code == 0 else {
            return .failure(.spawnFailed(errno: code, path: path))
        }
    }

    var pid: pid_t = 0
    code = posix_spawn(&pid, path, &fileActions, &attributes, &cArgv, &cEnvp)
    guard code == 0 else {
        return .failure(.spawnFailed(errno: code, path: path))
    }
    return .success(pid)
}
