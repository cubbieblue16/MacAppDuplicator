import DuplicatorCore
import Foundation

/// How far a profile has been tested (spec §8). Only `verified` profiles passed a real launch test on Mike's Mac.
public enum ProfileStatus: String, Codable, Sendable, CaseIterable {
    case verified, partial, unsupported
}

/// One `apps` entry; `ProfilesDocument.apps` keys it by bundle identifier (spec §8).
public struct AppProfile: Decodable, Equatable, Sendable {
    public var name: String
    public var status: ProfileStatus
    /// The family the profile was written for. Nil when the key is absent, null or names a family this build does not know.
    public var family: AppFamily?
    /// Copied into `ShortcutConfig.arguments` when a shortcut is created.
    public var args: [String]
    /// Copied into `ShortcutConfig.environment` when a shortcut is created.
    public var env: [String: String]
    /// Copied into `ShortcutConfig.newWindowCommand` when the wizard creates a shortcut; the helper's New Window menu
    /// item runs it through `NewWindowCommandBuilder`.
    public var newWindowCommand: String?
    public var notes: String?

    public init(name: String, status: ProfileStatus, family: AppFamily? = nil, args: [String] = [],
                env: [String: String] = [:], newWindowCommand: String? = nil, notes: String? = nil) {
        self.name = name
        self.status = status
        self.family = family
        self.args = args
        self.env = env
        self.newWindowCommand = newWindowCommand
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case name, status, family, args, env, newWindowCommand, notes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        let rawStatus = try container.decode(String.self, forKey: .status)
        guard let status = ProfileStatus(rawValue: rawStatus) else {
            throw ProfilesError.invalidField(profilesPath(decoder.codingPath, leaf: "status"))
        }
        self.status = status
        family = try container.decodeIfPresent(String.self, forKey: .family).flatMap(AppFamily.init(rawValue:))
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        newWindowCommand = try container.decodeIfPresent(String.self, forKey: .newWindowCommand)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}

/// One `webApps` entry (spec §8). Decoded and validated in Phase 3; the web shell that uses it is Phase 4.
public struct WebAppPreset: Decodable, Equatable, Sendable {
    public var name: String
    /// An `https` URL with a host.
    public var url: String
    public var userAgent: String?
    /// Compiled by the Phase 4 web shell to read unread counts from the page title.
    public var badgeRegex: String?
    public var extraHosts: [String]
    public var iconURL: String?

    public init(name: String, url: String, userAgent: String? = nil, badgeRegex: String? = nil,
                extraHosts: [String] = [], iconURL: String? = nil) {
        self.name = name
        self.url = url
        self.userAgent = userAgent
        self.badgeRegex = badgeRegex
        self.extraHosts = extraHosts
        self.iconURL = iconURL
    }

    private enum CodingKeys: String, CodingKey {
        case name, url, userAgent, badgeRegex, extraHosts, iconURL
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        userAgent = try container.decodeIfPresent(String.self, forKey: .userAgent)
        badgeRegex = try container.decodeIfPresent(String.self, forKey: .badgeRegex)
        extraHosts = try container.decodeIfPresent([String].self, forKey: .extraHosts) ?? []
        iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL)
    }
}

/// A decoded and validated `profiles.json` (spec §8). Build one from bytes with `decodeValidated(from:)`; unknown
/// keys are ignored so a newer file with extra fields still loads.
public struct ProfilesDocument: Decodable, Equatable, Sendable {
    /// The only `schemaVersion` this build reads.
    public static let supportedSchemaVersion = 1
    /// Largest accepted file, in bytes.
    public static let maxBytes = 1_048_576
    /// Longest accepted string, in Unicode scalars.
    public static let maxStringLength = 2_048
    public static let maxApps = 500
    public static let maxWebApps = 200
    /// Cap for the `args`, `env` and `extraHosts` of one entry.
    public static let maxListEntries = 64

    public var schemaVersion: Int
    /// `YYYY-MM-DD`; a later date wins (`ProfileCatalog.isNewer`).
    public var updated: String
    public var apps: [String: AppProfile]
    public var webApps: [String: WebAppPreset]

    public init(schemaVersion: Int = ProfilesDocument.supportedSchemaVersion, updated: String,
                apps: [String: AppProfile] = [:], webApps: [String: WebAppPreset] = [:]) {
        self.schemaVersion = schemaVersion
        self.updated = updated
        self.apps = apps
        self.webApps = webApps
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, updated, apps, webApps
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        updated = try container.decode(String.self, forKey: .updated)
        apps = try container.decode([String: AppProfile].self, forKey: .apps)
        webApps = try container.decodeIfPresent([String: WebAppPreset].self, forKey: .webApps) ?? [:]
    }

    /// Decodes untrusted bytes and applies every validation rule. The app builds documents only through this.
    public static func decodeValidated(from data: Data) throws -> ProfilesDocument {
        guard data.count <= maxBytes else { throw ProfilesError.tooLarge(data.count) }
        let decoder = JSONDecoder()
        let probe: VersionProbe
        do {
            probe = try decoder.decode(VersionProbe.self, from: data)
        } catch {
            throw ProfilesError.malformed(describe(error))
        }
        guard probe.schemaVersion == supportedSchemaVersion else {
            throw ProfilesError.unsupportedSchemaVersion(probe.schemaVersion)
        }
        let document: ProfilesDocument
        do {
            document = try decoder.decode(ProfilesDocument.self, from: data)
        } catch let error as ProfilesError {
            throw error
        } catch {
            throw ProfilesError.malformed(describe(error))
        }
        try document.validate()
        return document
    }
}

/// Decodes only `schemaVersion`, so a newer schema is reported as such instead of as malformed JSON.
private struct VersionProbe: Decodable {
    var schemaVersion: Int
}

/// A dotted JSON path for error messages. Each component is cut to 100 characters so a hostile key cannot flood the UI.
func profilesPath(_ codingPath: [any CodingKey], leaf: String? = nil) -> String {
    let components = codingPath.map { $0.stringValue } + (leaf.map { [$0] } ?? [])
    guard !components.isEmpty else { return "the top level" }
    return components.map { String($0.prefix(100)) }.joined(separator: ".")
}

extension ProfilesDocument {
    static let bundleIdentifierPattern = #"\A[A-Za-z0-9][A-Za-z0-9._-]{0,254}\z"#
    static let environmentKeyPattern = #"\A[A-Za-z_][A-Za-z0-9_]{0,127}\z"#
    static let webAppKeyPattern = #"\A[a-z0-9][a-z0-9-]{0,63}\z"#
    static let hostnamePattern =
        #"\A(?=.{1,253}\z)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\z"#
    static let datePattern = #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z"#
    /// Environment keys a profile may not set; defined once in DuplicatorCore (see `ProfileTrustRules`).
    static let refusedEnvironmentKeyPattern = ProfileTrustRules.refusedEnvironmentKeyPattern
    /// Argument prefixes a profile may not use; defined once in DuplicatorCore so the wizard shares it.
    static let refusedArgumentPattern = ProfileTrustRules.refusedArgumentPattern

    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    /// `YYYY-MM-DD` with ASCII digits that names a real Gregorian date.
    static func isValidDate(_ value: String) -> Bool {
        guard matches(value, datePattern) else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    /// Refuses strings over `maxStringLength` Unicode scalars, strings containing NUL and, unless allowed, empty strings.
    static func checkString(_ value: String, at path: String, allowEmpty: Bool = true) throws {
        guard value.unicodeScalars.count <= maxStringLength, !value.unicodeScalars.contains("\u{0}"),
              allowEmpty || !value.isEmpty else {
            throw ProfilesError.invalidField(path)
        }
    }

    /// Applies every rule from the Global Constraints. Keys are visited in sorted order so errors are reproducible.
    func validate() throws {
        guard Self.isValidDate(updated) else { throw ProfilesError.invalidUpdatedDate(String(updated.prefix(100))) }
        guard apps.count <= Self.maxApps else { throw ProfilesError.tooMany("apps") }
        guard webApps.count <= Self.maxWebApps else { throw ProfilesError.tooMany("webApps") }
        var seenIdentifiers = Set<String>()
        for (identifier, profile) in apps.sorted(by: { $0.key < $1.key }) {
            let path = "apps." + String(identifier.prefix(100))
            guard Self.matches(identifier, Self.bundleIdentifierPattern) else { throw ProfilesError.invalidField(path) }
            guard seenIdentifiers.insert(identifier.lowercased()).inserted else {
                throw ProfilesError.invalidField("\(path) duplicates another bundle identifier")
            }
            try profile.validate(at: path)
        }
        for (key, preset) in webApps.sorted(by: { $0.key < $1.key }) {
            let path = "webApps." + String(key.prefix(100))
            guard Self.matches(key, Self.webAppKeyPattern) else { throw ProfilesError.invalidField(path) }
            try preset.validate(at: path)
        }
    }

    /// A one-line reason for a decoding failure that names the JSON path but never echoes document values.
    static func describe(_ error: any Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let context) where context.codingPath.isEmpty:
            return "the data is not valid JSON"
        case DecodingError.dataCorrupted(let context):
            return "invalid value at \(profilesPath(context.codingPath))"
        case DecodingError.keyNotFound(let key, let context):
            return "missing key \(profilesPath(context.codingPath, leaf: key.stringValue))"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "wrong or missing value at \(profilesPath(context.codingPath))"
        default:
            return error.localizedDescription
        }
    }
}

extension AppProfile {
    func validate(at path: String) throws {
        try ProfilesDocument.checkString(name, at: "\(path).name", allowEmpty: false)
        guard args.count <= ProfilesDocument.maxListEntries else { throw ProfilesError.tooMany("\(path).args") }
        for (index, argument) in args.enumerated() {
            let argumentPath = "\(path).args[\(index)]"
            try ProfilesDocument.checkString(argument, at: argumentPath)
            guard !ProfilesDocument.matches(argument, ProfilesDocument.refusedArgumentPattern),
                  !ProfileTrustRules.containsControlCharacter(argument) else {
                throw ProfilesError.invalidField(argumentPath)
            }
        }
        guard env.count <= ProfilesDocument.maxListEntries else { throw ProfilesError.tooMany("\(path).env") }
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
            let entryPath = "\(path).env.\(key.prefix(100))"
            guard ProfilesDocument.matches(key, ProfilesDocument.environmentKeyPattern),
                  !ProfilesDocument.matches(key, ProfilesDocument.refusedEnvironmentKeyPattern) else {
                throw ProfilesError.invalidField(entryPath)
            }
            try ProfilesDocument.checkString(value, at: entryPath)
        }
        if let newWindowCommand {
            try ProfilesDocument.checkString(newWindowCommand, at: "\(path).newWindowCommand")
            // Remote documents may only plant a restricted template; users may still type anything in the editor.
            guard NewWindowCommandBuilder.profileValidationMessage(for: newWindowCommand) == nil else {
                throw ProfilesError.invalidField("\(path).newWindowCommand")
            }
        }
        if let notes { try ProfilesDocument.checkString(notes, at: "\(path).notes") }
    }
}

extension WebAppPreset {
    func validate(at path: String) throws {
        try ProfilesDocument.checkString(name, at: "\(path).name", allowEmpty: false)
        try ProfilesDocument.checkString(url, at: "\(path).url")
        guard let components = URLComponents(string: url), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty else {
            throw ProfilesError.invalidField("\(path).url")
        }
        if let userAgent { try ProfilesDocument.checkString(userAgent, at: "\(path).userAgent") }
        if let badgeRegex {
            try ProfilesDocument.checkString(badgeRegex, at: "\(path).badgeRegex")
            do {
                _ = try NSRegularExpression(pattern: badgeRegex)
            } catch {
                throw ProfilesError.invalidField("\(path).badgeRegex")
            }
        }
        guard extraHosts.count <= ProfilesDocument.maxListEntries else { throw ProfilesError.tooMany("\(path).extraHosts") }
        for (index, extraHost) in extraHosts.enumerated()
        where !ProfilesDocument.matches(extraHost, ProfilesDocument.hostnamePattern) {
            throw ProfilesError.invalidField("\(path).extraHosts[\(index)]")
        }
        if let iconURL { try ProfilesDocument.checkString(iconURL, at: "\(path).iconURL") }
    }
}
