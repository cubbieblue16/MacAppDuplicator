import Foundation

/// What one erase-on-quit pass did.
public struct EraseOnQuitOutcome: Equatable, Sendable {
    /// Direct children removed.
    public var removed: Int
    /// Names of the direct children that could not be removed; `.` when the folder itself could not be listed or recreated.
    public var failures: [String]

    public init(removed: Int = 0, failures: [String] = []) {
        self.removed = removed
        self.failures = failures
    }
}

/// Empties a folder that `EraseOnQuitPolicy.check` accepted (spec §4.3, §4.6). Every direct child, hidden ones included,
/// goes through `FileManager.removeItem(at:)`, which unlinks symbolic links at any depth instead of following them, so the
/// HOME override tree's links into the real home lose only the links. The folder itself stays (it is recreated if it
/// vanished) and nothing above it is touched.
public enum EraseOnQuitPerformer {
    public static func erase(at directory: URL, fileManager: FileManager = .default) -> EraseOnQuitOutcome {
        var outcome = EraseOnQuitOutcome()
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
        } catch {
            outcome.failures.append(".")
            return outcome
        }
        for child in children {
            do {
                try fileManager.removeItem(at: child)
                outcome.removed += 1
            } catch {
                outcome.failures.append(child.lastPathComponent)
            }
        }
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            } catch {
                outcome.failures.append(".")
            }
        }
        return outcome
    }
}
