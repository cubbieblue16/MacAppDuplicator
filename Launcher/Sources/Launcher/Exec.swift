import Darwin
import DuplicatorCore

/// Replaces this process with the target via `execve`. `plan.environment` is the complete environment
/// for the target and is passed whole as `envp`.
/// - Returns: `errno`, and only when `execve` returned (that is, failed). On success the process image is
///   replaced, so nothing is freed here; on failure the process exits right after the alert.
func execTarget(_ plan: LaunchPlan) -> Int32 {
    let path = plan.executableURL.path
    let argv = [path] + plan.arguments
    let envp = plan.environment.map { "\($0.key)=\($0.value)" }.sorted()
    var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    var cEnvp: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) } + [nil]
    _ = Darwin.execve(path, &cArgv, &cEnvp)
    return errno
}
