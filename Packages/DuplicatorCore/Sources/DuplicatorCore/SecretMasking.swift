import Foundation

/// Masks secret environment values in logs, diagnostics and previews (spec §2).
public enum SecretMasking {
    /// Replacement for every masked value.
    public static let maskedValue = "••••••"
    /// Spec §2 regex, matched against the variable name.
    public static let secretKeyPattern = "(?i)secret|token|key|password|passwd|credential"

    public static func isSecretKey(_ key: String) -> Bool {
        key.range(of: secretKeyPattern, options: .regularExpression) != nil
    }

    /// Same keys; values of secret-looking keys replaced with `maskedValue`.
    public static func mask(_ env: [String: String]) -> [String: String] {
        var masked = env
        for key in env.keys where isSecretKey(key) {
            masked[key] = maskedValue
        }
        return masked
    }

    /// Argument list with secret values replaced by `maskedValue`, for the launcher log, Diagnostics and previews.
    /// An argument's name is its text after any leading dashes and before the first `=`. `--api-key=v` and
    /// `API_TOKEN=v` keep their name and lose their value when the name matches `secretKeyPattern`; a secret flag
    /// without `=` (`--token v`) hides the argument after it unless that one starts with `-`. Everything else passes
    /// through. Over-masking is accepted: `--use-mock-keychain value` hides `value`.
    public static func maskArguments(_ arguments: [String]) -> [String] {
        var masked: [String] = []
        masked.reserveCapacity(arguments.count)
        var nextIsSecret = false
        for argument in arguments {
            let isFlag = argument.hasPrefix("-")
            if nextIsSecret, !isFlag {
                masked.append(maskedValue)
                nextIsSecret = false
                continue
            }
            let name = argument.drop { $0 == "-" }
            if let equals = name.firstIndex(of: "=") {
                nextIsSecret = false
                masked.append(isSecretKey(String(name[..<equals])) ? String(argument[...equals]) + maskedValue : argument)
            } else {
                nextIsSecret = isFlag && isSecretKey(String(name))
                masked.append(argument)
            }
        }
        return masked
    }

    /// `maskArguments` applied to the space-separated words of one launcher log line. Diagnostics uses it for log
    /// files written before the launcher masked argv. Best effort: a secret value that contains a space is hidden only
    /// up to its first space.
    public static func maskLogLine(_ line: String) -> String {
        maskArguments(line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)).joined(separator: " ")
    }
}
