import DuplicatorCore
import Foundation

/// Copy for the export sheet (spec §7): how the exported copy is signed, what the recipient does with it, and a warning
/// when environment values or arguments that look secret travel with it.
enum ExportInstructions {
    /// POSIX single quoting: the whole path inside `'…'`, each embedded `'` written as `'\''`. sh, bash and zsh expand
    /// nothing inside single quotes, so spaces, `"`, `$` and backticks stay literal.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// What the recipient does with the copy (security review C3). A received shortcut is never run by stripping its
    /// quarantine flag: the recipient's own App Duplicator lists it as Not created here, shows everything it would run,
    /// and rebuilds it under the recipient's identity only after Trust and Rebuild.
    static let recipientSteps = "On the other Mac, move the shortcut into an App Duplicator shortcuts folder and open App Duplicator. "
        + "It lists the shortcut as Not created here: select it, choose Regenerate, review every value and choose Trust and Rebuild. "
        + "Gatekeeper blocks the shortcut until then by design, so do not remove its quarantine flag."

    static func signingSentence(for signature: CodeSignature) -> String {
        switch signature {
        case .adHoc:
            return "The exported shortcut is ad-hoc signed, so it carries no developer identity."
        case .identity(let name):
            return "The exported shortcut is signed with \(name)."
        case .unknown:
            return "The exported shortcut's signature could not be read."
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
