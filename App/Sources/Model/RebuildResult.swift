import Foundation

/// One shortcut's line in the Rebuild All results (final review M16).
struct RebuildResult: Identifiable, Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case rebuilt
        /// The error's description, shown under the shortcut's name.
        case failed(String)
    }

    /// The shortcut's bundle URL when Rebuild All started.
    let id: URL
    let name: String
    let outcome: Outcome
}

/// How far Rebuild All has got: `done` of `total` shortcuts finished, failed ones included.
struct RebuildProgress: Equatable, Sendable {
    var done: Int
    var total: Int
}

/// The headline of the Rebuild All results.
enum RebuildSummary {
    /// "Rebuilt 2 of 3 shortcuts; 1 failed.", "Rebuilt 1 of 1 shortcut." or "No shortcuts needed a rebuild."
    static func text(for results: [RebuildResult]) -> String {
        guard !results.isEmpty else { return "No shortcuts needed a rebuild." }
        let failed = results.filter { $0.outcome != .rebuilt }.count
        let noun = results.count == 1 ? "shortcut" : "shortcuts"
        let rebuilt = "Rebuilt \(results.count - failed) of \(results.count) \(noun)"
        return failed == 0 ? "\(rebuilt)." : "\(rebuilt); \(failed) failed."
    }
}
