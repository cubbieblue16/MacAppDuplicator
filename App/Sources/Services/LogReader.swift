import DuplicatorCore
import Foundation

/// Reads the launcher's per-shortcut log (`~/Library/Logs/App Duplicator/<name>.log`) for Diagnostics (spec §7).
/// A `folder` override redirects reads (tests); nil keeps the launcher's real log folder.
struct LogReader: Sendable {
    private let folder: URL?

    init(folder: URL? = nil) {
        self.folder = folder
    }

    func logFolder() -> URL {
        folder ?? LaunchLogger(name: "placeholder").fileURL.deletingLastPathComponent()
    }

    /// The last `lines` lines of the shortcut's log; empty when there is no log yet.
    func tail(name: String, lines: Int = 200) -> [String] {
        let url = folder.map { $0.appending(path: ShortcutConfig.fileSystemName(for: name) + ".log", directoryHint: .notDirectory) }
            ?? LaunchLogger(name: name).fileURL
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let all = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        return Array(all.suffix(lines))
    }

    static func logFolder() -> URL {
        LogReader().logFolder()
    }

    static func tail(name: String, lines: Int = 200) -> [String] {
        LogReader().tail(name: name, lines: lines)
    }
}
