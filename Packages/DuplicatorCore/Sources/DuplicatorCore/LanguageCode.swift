import Foundation

/// The accepted shape of the §4.5 language override. `DataSeparationPlanner` passes the code as
/// `-AppleLanguages (<code>) -AppleLocale <code>`; this type only validates what the editor and madctl store.
public enum LanguageCode {
    /// A 2 or 3 letter language, then optional `-` subtags of 2 to 8 letters or digits: `en`, `fr`, `pt-BR`,
    /// `zh-Hant-TW`, `es-419`.
    public static let pattern = #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"#
    /// Shown by the editor under the Language field.
    public static let invalidMessage = "Use a language code like en, fr or pt-BR."

    /// True when the whole of `code` matches `pattern`. The match must cover the entire string, because `$` also matches
    /// in front of a trailing newline.
    public static func isValid(_ code: String) -> Bool {
        guard let match = code.range(of: pattern, options: .regularExpression) else { return false }
        return match == code.startIndex..<code.endIndex
    }

    /// `invalidMessage` when `code`, trimmed, is non-empty and invalid; nil for nil, blank or valid codes (a blank field
    /// means "no override").
    public static func validationMessage(for code: String?) -> String? {
        guard let trimmed = code?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return isValid(trimmed) ? nil : invalidMessage
    }
}
