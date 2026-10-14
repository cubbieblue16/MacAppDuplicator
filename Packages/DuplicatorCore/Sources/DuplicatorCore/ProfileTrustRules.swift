import Foundation

/// The rules a remote compatibility profile must pass before its arguments, environment or New Window command are
/// copied into a shortcut. They live in DuplicatorCore so the profile validator (CompatProfiles) and the wizard (App)
/// enforce one definition.
public enum ProfileTrustRules {
    /// Argument prefixes a profile may not use, with one or two leading dashes in any case (Chromium accepts both):
    /// debugger and remote-control switches, code loaders (`--load-extension`, `--renderer-cmd-prefix`, `-vmargs`,
    /// `-javaagent`), sandbox and web-security switches, and the profile and data-folder switches the planner owns
    /// (`--user-data-dir`, `--profile-directory`, Firefox `-profile` and `-P`, Eclipse `-data` and `-configuration`).
    public static let refusedArgumentPattern =
        #"(?i)\A--?(?:inspect|remote-debugging|remote-allow-origins|load-extension|disable-extensions-except|disable-web-security|no-sandbox|renderer-cmd-prefix|utility-cmd-prefix|gpu-launcher|browser-subprocess-path|user-data-dir|profile|configuration|data\z|p\z|vm|javaagent)"#

    /// `true` when `value` matches the ICU regular expression `pattern` anywhere.
    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
