import Darwin
import Foundation

/// Reads other processes' environments through `sysctl(KERN_PROCARGS2)`. Used by the library app to show the
/// running indicator: after LaunchServices check-in a shortcut's process reports the target's bundle, so the only
/// durable marker is `MAD_SHORTCUT_BUNDLE` in its environment (spec §4.4, §7). Only same-user, unrestricted processes
/// are readable; everything else is skipped.
public enum ProcessEnvironment {
    /// The environment of `pid`, or nil when the kernel refuses (foreign user, exited, restricted) or the buffer is malformed.
    /// Entries after the environment block (the loader's `executable_path=` and similar) are included; they never
    /// collide with `MAD_*` keys.
    public static func environment(ofProcess pid: pid_t) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        buffer.removeSubrange(size...)

        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = MemoryLayout<Int32>.size

        func nextString() -> String? {
            guard index < buffer.count else { return nil }
            var end = index
            while end < buffer.count, buffer[end] != 0 { end += 1 }
            let string = String(decoding: buffer[index..<end], as: UTF8.self)
            index = end + 1
            return string
        }

        // Layout: argc, executable path, NUL padding, argv[0..<argc], then "KEY=VALUE" strings.
        guard nextString() != nil else { return nil }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        for _ in 0..<max(argc, 0) {
            guard nextString() != nil else { return nil }
        }

        var environment: [String: String] = [:]
        while let entry = nextString() {
            guard !entry.isEmpty, let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            // First occurrence wins, matching how libc resolves duplicate names.
            if environment[key] == nil {
                environment[key] = String(entry[entry.index(after: equals)...])
            }
        }
        return environment
    }

    /// Every live process id, via `proc_listpids(PROC_ALL_PIDS)`. Zero entries are dropped.
    public static func allProcessIDs() -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        // Leave headroom for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size + 64)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    /// One scan over all readable processes: pid → value of `key` for every process that has it.
    public static func values(forEnvironmentKey key: String) -> [pid_t: String] {
        var result: [pid_t: String] = [:]
        for pid in allProcessIDs() {
            if let value = environment(ofProcess: pid)?[key] {
                result[pid] = value
            }
        }
        return result
    }

    /// Processes whose environment has `key == value`, ascending by pid.
    public static func processIDs(whereEnvironment key: String, equals value: String) -> [pid_t] {
        values(forEnvironmentKey: key).filter { $0.value == value }.map(\.key).sorted()
    }
}
