import Darwin
import Foundation

/// What `ProcessWatcher` saw happen to the watched process.
public enum ProcessWatchEvent: Equatable, Sendable {
    /// The process called `execve`: the launcher became the target.
    case exec
    /// The process exited. `waitStatus` is the `waitpid`-style status when the kernel reported one (`NOTE_EXITSTATUS`).
    case exit(waitStatus: Int32?)
}

public enum ProcessWatcherError: Error, Equatable {
    /// No process has the pid (`ESRCH`), or the pid is 0 or below.
    case processGone
    case kqueueFailed(errno: Int32)
    case registrationFailed(errno: Int32)
    case waitFailed(errno: Int32)
}

/// A kqueue `EVFILT_PROC` watch on one process for `NOTE_EXEC` and `NOTE_EXIT` (spec §4.6). The watcher owns its kqueue;
/// `fileDescriptor` is readable while an event is pending, so a `DispatchSource` read source can call `wait(timeout: 0)`.
/// Not `Sendable`: exactly one owner calls `wait`.
public final class ProcessWatcher {
    public let pid: pid_t
    public let fileDescriptor: Int32
    /// True when the kernel accepted `NOTE_EXITSTATUS` (allowed for a child or a process this user may signal), so
    /// `.exit` carries the status.
    public let reportsExitStatus: Bool

    public init(pid: pid_t) throws {
        guard pid > 0 else {
            throw ProcessWatcherError.processGone
        }
        let queue = kqueue()
        guard queue >= 0 else {
            throw ProcessWatcherError.kqueueFailed(errno: errno)
        }
        let flags = UInt32(truncatingIfNeeded: NOTE_EXIT) | UInt32(truncatingIfNeeded: NOTE_EXEC)
        var reportsExitStatus = true
        var result = ProcessWatcher.register(pid: pid, fflags: flags | UInt32(truncatingIfNeeded: NOTE_EXITSTATUS), on: queue)
        if result == EACCES {
            reportsExitStatus = false
            result = ProcessWatcher.register(pid: pid, fflags: flags, on: queue)
        }
        guard result == 0 else {
            close(queue)
            throw result == ESRCH ? ProcessWatcherError.processGone : ProcessWatcherError.registrationFailed(errno: result)
        }
        self.pid = pid
        fileDescriptor = queue
        self.reportsExitStatus = reportsExitStatus
    }

    deinit {
        close(fileDescriptor)
    }

    /// Waits up to `timeout` seconds (`nil` blocks, `0` polls; finite values only) and returns what happened, `.exec`
    /// before `.exit` when one wake-up carries both. An empty array means the timeout passed.
    public func wait(timeout: TimeInterval?) throws -> [ProcessWatchEvent] {
        var events: [kevent] = Array(repeating: kevent(), count: 4)
        let capacity = Int32(events.count)
        var count: Int32
        repeat {
            if let timeout {
                let seconds = max(0, timeout)
                let whole = seconds.rounded(.down)
                var limit = timespec(tv_sec: Int(whole), tv_nsec: Int((seconds - whole) * 1_000_000_000))
                count = kevent(fileDescriptor, nil, 0, &events, capacity, &limit)
            } else {
                count = kevent(fileDescriptor, nil, 0, &events, capacity, nil)
            }
        } while count < 0 && errno == EINTR
        guard count >= 0 else {
            throw ProcessWatcherError.waitFailed(errno: errno)
        }
        var result: [ProcessWatchEvent] = []
        for event in events.prefix(Int(count)) {
            if event.flags & UInt16(truncatingIfNeeded: EV_ERROR) != 0 {
                throw ProcessWatcherError.waitFailed(errno: Int32(truncatingIfNeeded: event.data))
            }
            if event.fflags & UInt32(truncatingIfNeeded: NOTE_EXEC) != 0 {
                result.append(.exec)
            }
            if event.fflags & UInt32(truncatingIfNeeded: NOTE_EXIT) != 0 {
                result.append(.exit(waitStatus: reportsExitStatus ? Int32(truncatingIfNeeded: event.data) : nil))
            }
        }
        return result
    }

    /// The kernel's path of `pid`'s executable (`proc_pidpath`), or nil when no process has that pid.
    public static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Every live process whose kernel executable path is exactly `path`, in ascending pid order. Zombies have no path and
    /// never match. The helper uses it to find other copies of its own shortcut before it erases (Task 5).
    public static func pids(runningFrom path: String) -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else {
            return []
        }
        var all = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size + 64)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &all, Int32(all.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else {
            return []
        }
        return all.prefix(Int(filled) / MemoryLayout<pid_t>.size)
            .filter { $0 > 0 && executablePath(of: $0) == path }
            .sorted()
    }

    /// Adds the `EVFILT_PROC` filter for `pid` to `queue`: 0 on success, otherwise the errno.
    private static func register(pid: pid_t, fflags: UInt32, on queue: Int32) -> Int32 {
        var change = kevent(
            ident: UInt(pid),
            filter: Int16(truncatingIfNeeded: EVFILT_PROC),
            flags: UInt16(truncatingIfNeeded: EV_ADD | EV_CLEAR),
            fflags: fflags,
            data: 0,
            udata: nil
        )
        while kevent(queue, &change, 1, nil, 0, nil) < 0 {
            guard errno == EINTR else {
                return errno
            }
        }
        return 0
    }
}
