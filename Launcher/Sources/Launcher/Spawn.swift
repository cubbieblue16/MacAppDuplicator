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

/// Bytes of standard error `spawnAndWait` keeps; anything after them is read and dropped.
let spawnAndWaitStandardErrorLimit = 65_536

/// Runs a short-lived helper and waits for it (spec §6): `osascript`, which opens Terminal.app or iTerm2 for a command
/// shortcut and exits once the command is typed in. Waiting is what makes an AppleScript failure visible, such as a
/// denied Automation permission (-1743). Unlike `spawnDetached` the child stays in the Launcher's session. Its standard
/// error goes to a pipe that is read to end of file, keeping the first `spawnAndWaitStandardErrorLimit` bytes and
/// draining the rest so the child never blocks on a full pipe; standard input and output are inherited. `environment`
/// and `workingDirectory` work as in `spawnDetached`. Every `strdup` copy and pipe descriptor is released on all paths.
/// - Returns: the exit status (`128 + signal number` when a signal ended the child) and the captured standard error, or
///   `LauncherError.spawnFailed` when `pipe`, `posix_spawn*` or `waitpid` fails.
func spawnAndWait(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    workingDirectory: URL?
) -> Result<(status: Int32, stderr: String), LauncherError> {
    let path = executable.path
    let argv = [path] + arguments
    let envp = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    var cEnvp: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) } + [nil]
    defer {
        cArgv.forEach { free($0) }
        cEnvp.forEach { free($0) }
    }

    var descriptors: [Int32] = [-1, -1]
    guard pipe(&descriptors) == 0 else {
        return .failure(.spawnFailed(errno: errno, path: path))
    }
    var readEnd = descriptors[0]
    var writeEnd = descriptors[1]
    defer {
        if readEnd >= 0 { close(readEnd) }
        if writeEnd >= 0 { close(writeEnd) }
    }

    var fileActions: posix_spawn_file_actions_t?
    var code = posix_spawn_file_actions_init(&fileActions)
    guard code == 0 else {
        return .failure(.spawnFailed(errno: code, path: path))
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    // The child keeps only the pipe's write end, as its standard error.
    code = posix_spawn_file_actions_addclose(&fileActions, readEnd)
    if code == 0 {
        code = posix_spawn_file_actions_adddup2(&fileActions, writeEnd, STDERR_FILENO)
    }
    if code == 0, writeEnd != STDERR_FILENO {
        code = posix_spawn_file_actions_addclose(&fileActions, writeEnd)
    }
    if code == 0, let workingDirectory {
        code = posix_spawn_file_actions_addchdir(&fileActions, workingDirectory.path)
    }
    guard code == 0 else {
        return .failure(.spawnFailed(errno: code, path: path))
    }

    var pid: pid_t = 0
    code = posix_spawn(&pid, path, &fileActions, nil, &cArgv, &cEnvp)
    guard code == 0 else {
        return .failure(.spawnFailed(errno: code, path: path))
    }
    // The parent's copy of the write end must go before reading, or the read never reaches end of file.
    close(writeEnd)
    writeEnd = -1
    let standardError = readToEnd(readEnd, limit: spawnAndWaitStandardErrorLimit)
    // Closed before waiting, so a child still writing after a read error gets EPIPE instead of blocking forever.
    close(readEnd)
    readEnd = -1

    var waitStatus: Int32 = 0
    while waitpid(pid, &waitStatus, 0) == -1 {
        guard errno == EINTR else {
            return .failure(.spawnFailed(errno: errno, path: path))
        }
    }
    return .success((status: exitStatus(fromWaitStatus: waitStatus), stderr: standardError))
}

/// A `waitpid` status as a shell would report it: the exit code, or `128 + signal number` when a signal ended the
/// process. (`WIFEXITED` and friends are C macros that Swift does not import.)
func exitStatus(fromWaitStatus waitStatus: Int32) -> Int32 {
    let signal = waitStatus & 0x7f
    return signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal
}

/// Reads `descriptor` until end of file or a read error other than `EINTR`, keeping the first `limit` bytes.
private func readToEnd(_ descriptor: Int32, limit: Int) -> String {
    var kept: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        if count > 0 {
            if kept.count < limit {
                kept.append(contentsOf: buffer[0..<min(count, limit - kept.count)])
            }
        } else if count == 0 || errno != EINTR {
            break
        }
    }
    return String(decoding: kept, as: UTF8.self)
}
