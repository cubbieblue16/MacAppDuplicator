import DuplicatorCore
import Foundation

/// Reads the launcher's per-shortcut log (`~/Library/Logs/App Duplicator/<name>.log`) for Diagnostics (spec §7).
enum LogReader {
    static func logFolder() -> URL {
        LaunchLogger(name: "placeholder").fileURL.deletingLastPathComponent()
    }

    /// The last `lines` lines of the shortcut's log; empty when there is no log yet.
    static func tail(name: String, lines: Int = 200) -> [String] {
        let url = LaunchLogger(name: name).fileURL
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let all = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        return Array(all.suffix(lines))
    }
}
