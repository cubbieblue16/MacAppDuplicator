import Foundation

/// Why a `profiles.json` document or a profile update was refused. Every description is a full sentence for the UI.
public enum ProfilesError: Error, Equatable, LocalizedError {
    /// The document is larger than `ProfilesDocument.maxBytes`; carries its byte count.
    case tooLarge(Int)
    /// The bytes are not JSON of the schema-1 shape; carries a short reason that never echoes document values.
    case malformed(String)
    /// `schemaVersion` is not `ProfilesDocument.supportedSchemaVersion`.
    case unsupportedSchemaVersion(Int)
    /// `updated` is not a real `YYYY-MM-DD` date.
    case invalidUpdatedDate(String)
    /// A key or value broke a validation rule; carries its JSON path.
    case invalidField(String)
    /// A collection is over its cap; carries its JSON path.
    case tooMany(String)
    /// A URL is not an allowed `https://raw.githubusercontent.com` address.
    case insecureURL(String)
    /// The server answered with a status other than 200.
    case httpStatus(Int)
    /// The transfer failed; carries the system's description.
    case fetchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let bytes):
            "The profiles file is \(bytes) bytes; the limit is 1,048,576."
        case .malformed(let detail):
            "The profiles file is not valid JSON for schema 1: \(detail)"
        case .unsupportedSchemaVersion(let version):
            "The profiles file uses schema version \(version); this build reads version 1."
        case .invalidUpdatedDate(let value):
            "The profiles file has an invalid updated date “\(value)”; expected YYYY-MM-DD."
        case .invalidField(let path):
            "The profiles file has an invalid value: \(path)."
        case .tooMany(let path):
            "The profiles file has too many entries in \(path)."
        case .insecureURL(let url):
            "\(url) is not an https://raw.githubusercontent.com address."
        case .httpStatus(let code):
            "The profiles server answered HTTP \(code)."
        case .fetchFailed(let message):
            message
        }
    }
}
