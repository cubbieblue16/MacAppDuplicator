import Foundation

/// One shortcut's line in the Rebuild All results (final review M16).
struct RebuildResult: Identifiable, Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case rebuilt
        /// The error's description, shown under the shortcut's name.
        case failed(String)
        /// Not rebuilt because this App Duplicator did not create it (security review C3); the associated value is
        /// the provenance reason. Such a shortcut is rewritten only after a review in the editor.
        case skipped(String)
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
    /// Skipped shortcuts (C3) are counted apart: "... 1 shortcut skipped: not created by this App Duplicator — open
    /// each to review."
    static func text(for results: [RebuildResult]) -> String {
        guard !results.isEmpty else { return "No shortcuts needed a rebuild." }
        let skipped = results.filter { if case .skipped = $0.outcome { return true } else { return false } }.count
        let attempted = results.count - skipped
        var sentences: [String] = []
        if attempted > 0 {
            let failed = results.filter { if case .failed = $0.outcome { return true } else { return false } }.count
            let noun = attempted == 1 ? "shortcut" : "shortcuts"
            let rebuilt = "Rebuilt \(attempted - failed) of \(attempted) \(noun)"
            sentences.append(failed == 0 ? "\(rebuilt)." : "\(rebuilt); \(failed) failed.")
        }
        if skipped > 0 {
            let noun = skipped == 1 ? "shortcut" : "shortcuts"
            sentences.append("\(skipped) \(noun) skipped: not created by this App Duplicator \u{2014} open each to review.")
        }
        return sentences.joined(separator: " ")
    }
}
