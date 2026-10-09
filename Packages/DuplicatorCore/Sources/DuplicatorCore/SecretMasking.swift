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
}
