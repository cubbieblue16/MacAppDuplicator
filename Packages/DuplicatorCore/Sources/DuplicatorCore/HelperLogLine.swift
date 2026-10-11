import Foundation

/// Every helper line in the shortcut's launcher log (spec §4.6, §4.7), including the two the launcher writes when it starts
/// the helper (`spawned`, `spawnFailed`). Paths are logged as they are, like the
/// launcher's own `start` and `target` lines; the New Window argv goes through `SecretMasking.maskArguments`, like the
/// launcher's `argv` line.
public enum HelperLogLine {
    public static let execObserved = "helper exec observed"
    public static let watchedProcessGone = "helper watched process already gone"
    public static let pidReused = "helper watched pid was reused"
    public static let dataPathMismatch = "helper erase skipped: the data path does not match MADConfig"
    public static let ownPathUnreadable = "helper erase skipped: the helper cannot read its own executable path"
    public static let exiting = "helper exit"

    public static func spawned(pid: pid_t) -> String {
        "helper spawned pid=\(pid)"
    }

    /// The launch goes on without a helper.
    public static func spawnFailed(_ reason: String) -> String {
        "helper spawn failed: \(reason)"
    }

    public static func start(helperPID: pid_t, watchedPID: pid_t, bundlePath: String, dataPath: String?) -> String {
        "helper start pid=\(helperPID) watch=\(watchedPID) bundle=\(bundlePath) data=\(dataPath ?? HelperArguments.noDataPath)"
    }

    public static func malformed(argumentCount: Int) -> String {
        "helper malformed argv argc=\(argumentCount)"
    }

    public static func watchFailed(_ reason: String) -> String {
        "helper watch failed: \(reason)"
    }

    /// `status=` is what a shell reports (the exit code, or 128 + the signal number), or `unavailable` when the kernel
    /// gave no status.
    public static func targetExited(waitStatus: Int32?) -> String {
        "helper target exited status=\(statusText(waitStatus))"
    }

    public static func launcherFailed(waitStatus: Int32?) -> String {
        "helper launcher exited before exec status=\(statusText(waitStatus))"
    }

    public static func erased(path: String, removed: Int, failed: Int) -> String {
        failed == 0 ? "helper erase \(path) removed=\(removed)" : "helper erase \(path) removed=\(removed) failed=\(failed)"
    }

    public static func eraseSkipped(_ reason: String) -> String {
        "helper erase skipped: \(reason)"
    }

    public static func newWindow(argv: [String]) -> String {
        "helper new window argv \(SecretMasking.maskArguments(argv).joined(separator: " "))"
    }

    public static func newWindowFailed(_ reason: String) -> String {
        "helper new window failed: \(reason)"
    }

    public static func quit(signal: Int32) -> String {
        "helper quit signal=\(signal)"
    }

    public static func showFailed(_ reason: String) -> String {
        "helper show failed: \(reason)"
    }

    /// Another process runs the shortcut's launcher binary: another copy's helper, a launch in progress or a System Launch
    /// launcher. That copy may still be using the data folder, so nothing is erased.
    public static func otherCopiesRunning(pids: [pid_t]) -> String {
        eraseSkipped("another copy of this shortcut is still running (pid \(pids.map { String($0) }.joined(separator: ",")))")
    }

    /// A `waitpid` status in shell form. (`WIFEXITED` and friends are C macros that Swift does not import.)
    static func statusText(_ waitStatus: Int32?) -> String {
        guard let waitStatus else { return "unavailable" }
        let signal = waitStatus & 0x7f
        return String(signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal)
    }
}
