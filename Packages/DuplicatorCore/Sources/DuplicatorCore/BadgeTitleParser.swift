import Foundation

/// Extracts an unread count from a page title such as `(3) Inbox` (spec §5).
public struct BadgeTitleParser: Sendable {
    /// Matches `(3)` and captures the digits.
    public static let defaultPattern = #"\((\d+)\)"#
    /// Titles are cut to this many characters before matching, which bounds the work of a slow pattern.
    public static let maxTitleLength = 1_024

    /// The pattern in use: the supplied one when it compiles and has a capture group, otherwise `defaultPattern`.
    public let pattern: String
    /// True when a non-empty supplied pattern was refused; the shell logs it.
    public let usedFallbackPattern: Bool

    /// - Parameter pattern: regular expression with at least one capture group; nil or blank selects `defaultPattern`.
    public init(pattern: String?) {
        let supplied = pattern?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if supplied.isEmpty {
            self.pattern = Self.defaultPattern
            usedFallbackPattern = false
        } else if Self.isUsable(supplied) {
            self.pattern = supplied
            usedFallbackPattern = false
        } else {
            self.pattern = Self.defaultPattern
            usedFallbackPattern = true
        }
    }

    /// The first capture group of the first match in `title` as an Int; nil when nothing matches, the group is not a
    /// number or the number does not fit an Int. A nil result means "clear the badge".
    public func count(in title: String) -> Int? {
        let bounded = String(title.prefix(Self.maxTitleLength))
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            return nil
        }
        let whole = NSRange(bounded.startIndex..., in: bounded)
        guard let match = regex.firstMatch(in: bounded, range: whole), match.numberOfRanges > 1 else { return nil }
        let group = match.range(at: 1)
        guard group.location != NSNotFound, let range = Range(group, in: bounded) else { return nil }
        return Int(bounded[range])
    }

    private static func isUsable(_ candidate: String) -> Bool {
        do {
            return try NSRegularExpression(pattern: candidate).numberOfCaptureGroups >= 1
        } catch {
            return false
        }
    }
}
