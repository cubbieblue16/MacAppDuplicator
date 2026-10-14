import Foundation

/// A cheap static screen for regular expressions that come from a remote profile (`badgeRegex`), run before the
/// pattern is compiled. NSRegularExpression (ICU) has no time limit, and the badge pattern runs against every title
/// change on the main actor, so a catastrophic pattern would freeze the web shell.
///
/// Rejected: patterns over `maxLength`, a quantifier (`*`, `+`, `?`, `{n,m}`) applied to a group whose body itself
/// holds an unbounded quantifier (`*`, `+`, `{n,}`, so `(.+)+` and `((a+)b)*`), backreferences (`\1` to `\9`, `\k`),
/// lookbehind (`(?<=`, `(?<!`), and the constructs that could hide a group from the scanner (`\Q`, `(?#`, and the
/// free-spacing flag `x`).
///
/// Known gap, deliberately accepted: ReDoS through overlapping alternation inside a repeated group, such as
/// `(a|a)*b`, or `(a|aa)+`, is not detected. The screen is a scanner, not a regex engine.
public enum RegexSafety {
    /// Longest pattern accepted, in characters.
    public static let maxLength = 256

    /// Why `pattern` is not safe to compile, or nil when it passes the screen.
    public static func unsafeReason(pattern: String) -> String? {
        let characters = Array(pattern)
        if characters.count > maxLength { return "The pattern is longer than \(maxLength) characters." }
        // One entry per open group: true once its body holds an unbounded quantifier.
        var groups: [Bool] = []
        // True right after a `)` that closed a group whose body held an unbounded quantifier.
        var justClosedUnbounded = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            var nextClosedUnbounded = false
            switch character {
            case "\\":
                guard index + 1 < characters.count else { break }
                let escaped = characters[index + 1]
                if ("1"..."9").contains(escaped) || escaped == "k" { return "Backreferences are not allowed." }
                if escaped == "Q" { return "Quoted sections (\\Q) are not allowed." }
                index += 1
            case "[":
                index = indexOfClassEnd(characters, from: index)
            case "(":
                if index + 1 < characters.count, characters[index + 1] == "?" {
                    let rest = String(characters[(index + 2)...].prefix(4))
                    if rest.hasPrefix("<=") || rest.hasPrefix("<!") { return "Lookbehind is not allowed." }
                    if rest.hasPrefix("#") { return "Comment groups are not allowed." }
                    if let first = rest.first, first.isLetter || first == "-" {
                        let flags = characters[(index + 2)...].prefix { $0 != ")" && $0 != ":" }
                        if flags.contains("x") { return "Free-spacing mode is not allowed." }
                    }
                    index += 1 // the `?` opens a group type, it is not a quantifier
                }
                groups.append(false)
            case ")":
                let inner = groups.popLast() ?? false
                if inner, let parent = groups.indices.last { groups[parent] = true }
                nextClosedUnbounded = inner
            case "*", "+", "?":
                if justClosedUnbounded { return "A repeated group contains its own repetition (nested quantifiers)." }
                if character != "?", let current = groups.indices.last { groups[current] = true }
            case "{":
                if let quantifier = boundedQuantifier(characters, from: index) {
                    if justClosedUnbounded { return "A repeated group contains its own repetition (nested quantifiers)." }
                    if quantifier.unbounded, let current = groups.indices.last { groups[current] = true }
                    index = quantifier.end
                }
            default:
                break
            }
            justClosedUnbounded = nextClosedUnbounded
            index += 1
        }
        return nil
    }

    /// Index of the `]` that closes the class opened at `start` (nested classes count), or the last index.
    private static func indexOfClassEnd(_ characters: [Character], from start: Int) -> Int {
        var depth = 0
        var index = start
        while index < characters.count {
            switch characters[index] {
            case "\\": index += 1
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index += 1
        }
        return characters.count - 1
    }

    /// Parses `{n}`, `{n,}` or `{n,m}` starting at `start`; nil when the brace is a literal.
    private static func boundedQuantifier(_ characters: [Character], from start: Int) -> (unbounded: Bool, end: Int)? {
        var index = start + 1
        let minimumStart = index
        while index < characters.count, characters[index].isASCII, characters[index].isNumber { index += 1 }
        guard index > minimumStart, index < characters.count else { return nil }
        if characters[index] == "}" { return (false, index) }
        guard characters[index] == "," else { return nil }
        index += 1
        let maximumStart = index
        while index < characters.count, characters[index].isASCII, characters[index].isNumber { index += 1 }
        guard index < characters.count, characters[index] == "}" else { return nil }
        return (index == maximumStart, index)
    }
}
