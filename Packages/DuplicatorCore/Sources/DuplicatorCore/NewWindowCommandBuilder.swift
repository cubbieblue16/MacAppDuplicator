import Foundation

/// Renders a profile's `newWindowCommand` template into the argv the helper's New Window item runs (spec §4.6).
/// The template is split on whitespace first and each token's placeholders are substituted afterwards, so a target or
/// data path with spaces stays one argument. The result goes to `posix_spawn`; nothing is ever passed to a shell.
public enum NewWindowCommandBuilder {
    /// Longest template accepted, in Unicode scalars (the profiles schema caps every string at 2,048 characters).
    public static let maximumLength = 2_048
    /// Runs a template whose program is not an absolute path: `open` becomes `/usr/bin/env open`.
    public static let envPath = "/usr/bin/env"

    /// The argv to execute, or nil when the template is nil or blank, or uses `{dataPath}` while `dataPath` is nil.
    /// Placeholders: `{target}` (the target app's path), `{bundleId}` (its bundle identifier) and `{dataPath}`. Any other
    /// brace text stays literal, and substituted values are never scanned again. `argv[0]` is always an absolute path.
    public static func argv(template: String?, targetPath: String, targetBundleIdentifier: String, dataPath: String?) -> [String]? {
        guard let template else { return nil }
        let tokens = template.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }
        if dataPath == nil, tokens.contains(where: { $0.contains("{dataPath}") }) { return nil }
        let values: [(name: String, value: String)] = [
            ("target", targetPath), ("bundleId", targetBundleIdentifier), ("dataPath", dataPath ?? ""),
        ]
        let rendered = tokens.map { substitute($0, values: values) }
        guard let program = rendered.first, !program.isEmpty else { return nil }
        return program.hasPrefix("/") ? rendered : [envPath] + rendered
    }

    /// Why a template may not be stored, or nil when it may. nil and blank templates are fine: they hide the menu item.
    public static func validationMessage(for template: String?) -> String? {
        guard let template else { return nil }
        if template.unicodeScalars.count > maximumLength {
            return "The New Window command is longer than \(maximumLength) characters."
        }
        let hasControlCharacter = template.unicodeScalars.contains { scalar in
            (scalar.value < 0x20 && scalar != "\t") || scalar.value == 0x7F
        }
        return hasControlCharacter ? "The New Window command may not contain control characters." : nil
    }

    /// One left-to-right pass: each `{name}` with a known name is replaced by its value; everything else is copied.
    private static func substitute(_ token: String, values: [(name: String, value: String)]) -> String {
        var result = ""
        var rest = Substring(token)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let candidate = rest[open...]
            if let match = values.first(where: { candidate.hasPrefix("{\($0.name)}") }) {
                result += match.value
                rest = candidate.dropFirst(match.name.count + 2)
            } else {
                result += "{"
                rest = candidate.dropFirst()
            }
        }
        return result + rest
    }
}
