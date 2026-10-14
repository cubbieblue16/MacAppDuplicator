import Foundation
import Security

/// How a bundle on disk is signed, read with Security.framework (never by shelling out to `codesign`). The export sheet
/// reads the exported copy itself, because the bundle keeps the signature it was built with even after the signing
/// identity in Settings changes.
enum CodeSignature: Equatable, Sendable {
    case adHoc
    /// Signed with a certificate; the associated value is the leaf certificate's display name (spec §9: never a hash).
    case identity(String)
    /// Unsigned, unreadable or missing.
    case unknown

    static func of(bundleAt url: URL) -> CodeSignature {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            return .unknown
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else {
            return .unknown
        }
        if let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value,
           SecCodeSignatureFlags(rawValue: flags).contains(.adhoc) {
            return .adHoc
        }
        if let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certificates.first,
           let summary = SecCertificateCopySubjectSummary(leaf) as String? {
            return .identity(summary)
        }
        return .unknown
    }

    /// True when the bundle's signature verifies (Security.framework, `SecStaticCodeCheckValidityWithErrors`) and was made
    /// by `expected`. Ad hoc: the signature is internally valid and the bundle is flagged ad hoc (anyone can ad hoc sign,
    /// so this proves only that nothing changed after signing). Identity: valid against the requirement
    /// `anchor apple generic and certificate leaf[subject.CN] = "<name>"`, so a self-made certificate with the same name
    /// fails. `.unknown` never verifies.
    static func verify(bundleAt url: URL, expecting expected: CodeSignature) -> Bool {
        let requirementText: String?
        switch expected {
        case .unknown:
            return false
        case .adHoc:
            requirementText = nil
        case .identity(let name):
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            requirementText = "anchor apple generic and certificate leaf[subject.CN] = \"\(escaped)\""
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            return false
        }
        var requirement: SecRequirement?
        if let requirementText {
            guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
                  requirement != nil else { return false }
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess else { return false }
        if case .adHoc = expected { return of(bundleAt: url) == .adHoc }
        return true
    }
}
