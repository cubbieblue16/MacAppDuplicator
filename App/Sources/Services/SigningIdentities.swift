import Foundation

/// Lists codesigning identities by display name via `security find-identity -v -p codesigning` (spec §7 Settings).
enum SigningIdentities {
    /// Keeps unique names, in order; drops lines with a trailing status such as `(CSSMERR_TP_CERT_REVOKED)`.
    static func parse(_ output: String) -> [String] {
        // A local, not a stored static: `Regex` is not Sendable, so a static `let` is rejected under Swift 6.
        let line = /^\s*\d+\)\s+[0-9A-Fa-f]{40}\s+"(.+)"\s*$/
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
            guard let match = raw.wholeMatch(of: line) else { return nil }
            let name = String(match.1)
            return seen.insert(name).inserted ? name : nil
        }
    }

    static func load() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-identity", "-v", "-p", "codesigning"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// First "Developer ID Application" identity, otherwise ad hoc.
    static func defaultIdentity(from identities: [String]) -> String {
        identities.first { $0.hasPrefix("Developer ID Application") } ?? AppSettings.adHocIdentityName
    }
}
