import DuplicatorCore
import Foundation

/// Copy for the export sheet (spec §7): how the exported copy is signed, the quarantine-removal command for the other
/// Mac, and a warning when environment values that look secret travel with it.
enum ExportInstructions {
    /// POSIX single quoting: the whole path inside `'…'`, each embedded `'` written as `'\''`. sh, bash and zsh expand
    /// nothing inside single quotes, so spaces, `"`, `$` and backticks stay literal.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func quarantineCommand(for bundleURL: URL) -> String {
        "xattr -dr com.apple.quarantine \(shellQuoted(bundleURL.path))"
    }

    static func signingSentence(for signature: CodeSignature) -> String {
        let gatekeeper = "On another Mac, Gatekeeper may block it until you remove the quarantine flag:"
        switch signature {
        case .adHoc:
            return "The exported shortcut is ad-hoc signed, so it carries no developer identity. \(gatekeeper)"
        case .identity(let name):
            return "The exported shortcut is signed with \(name). \(gatekeeper)"
        case .unknown:
            return "On another Mac, Gatekeeper may block the exported shortcut until you remove the quarantine flag:"
        }
    }

    /// One line naming the keys that match `SecretMasking.isSecretKey` (never their values), or nil when none do:
    /// the exported Info.plist carries every environment value in plain text.
    static func secretNotice(for environment: [String: String]) -> String? {
        let keys = environment.keys.filter { SecretMasking.isSecretKey($0) }.sorted()
        guard !keys.isEmpty else { return nil }
        return "Environment values travel in plain text inside the exported shortcut, including \(keys.joined(separator: ", "))."
    }
}
