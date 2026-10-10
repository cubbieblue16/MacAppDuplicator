import DuplicatorCore
import Foundation

/// Copy for the export sheet (spec §7): how the exported copy is signed, the quarantine-removal command for the other
/// Mac, and a warning when environment values or arguments that look secret travel with it.
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

    /// One line naming the environment keys that match `SecretMasking.isSecretKey` and the arguments that
    /// `SecretMasking.maskArguments` hides (never their values), or nil when there are none: the exported Info.plist
    /// carries every environment value and argument in plain text. Without secret arguments the wording is the
    /// environment-only sentence.
    static func secretNotice(for environment: [String: String], arguments: [String] = []) -> String? {
        let keys = environment.keys.filter { SecretMasking.isSecretKey($0) }.sorted()
        let argumentNames = secretArgumentNames(in: arguments)
        guard !argumentNames.isEmpty else {
            guard !keys.isEmpty else { return nil }
            return "Environment values travel in plain text inside the exported shortcut, including \(keys.joined(separator: ", "))."
        }
        let names = (keys + argumentNames).joined(separator: ", ")
        return "Environment values and arguments travel in plain text inside the exported shortcut, including \(names)."
    }

    /// Names of the arguments `SecretMasking.maskArguments` hides, in order and without repeats: the text before `=`
    /// for `--name=value` and `NAME=value`, the flag before it for a value passed as its own argument.
    static func secretArgumentNames(in arguments: [String]) -> [String] {
        var names: [String] = []
        var previous: String?
        for (argument, shown) in zip(arguments, SecretMasking.maskArguments(arguments)) {
            defer { previous = argument }
            guard shown != argument else { continue }
            let name = shown == SecretMasking.maskedValue ? (previous ?? "") : String(argument.prefix { $0 != "=" })
            if !name.isEmpty, !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }
}
