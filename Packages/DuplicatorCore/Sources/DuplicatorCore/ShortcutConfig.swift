import Foundation

/// One shortcut's configuration (spec §3.1). Stored in the shortcut's own Info.plist under `MADConfig` (spec §2).
public struct ShortcutConfig: Codable, Equatable, Sendable {
    /// Engine version written by this build; mirrored at Info.plist top level as `MADEngineVersion`.
    public static let currentEngineVersion = 1
    /// Info.plist key that holds `plistDictionary()`.
    public static let infoPlistKey = "MADConfig"
    /// Info.plist key that mirrors `engineVersion` at top level.
    public static let engineVersionInfoPlistKey = "MADEngineVersion"
    /// Prefix of every shortcut bundle identifier (spec §3.2).
    public static let bundleIdentifierPrefix = "com.mikekuta.appduplicator."

    public var kind: ShortcutKind
    public var name: String
    public var slug: String
    public var bundleIdentifier: String
    public var targetPath: String
    public var targetBundleIdentifier: String
    public var launchMode: LaunchMode
    public var dataMode: DataMode
    public var dataPath: String?
    public var environment: [String: String]
    public var arguments: [String]
    public var appearance: Appearance
    public var languageCode: String?
    public var eraseOnQuit: Bool
    public var menuBarIcon: Bool
    public var engineVersion: Int

    public init(
        kind: ShortcutKind = .app,
        name: String,
        slug: String,
        bundleIdentifier: String,
        targetPath: String,
        targetBundleIdentifier: String,
        launchMode: LaunchMode = .dockShortcut,
        dataMode: DataMode = .auto,
        dataPath: String? = nil,
        environment: [String: String] = [:],
        arguments: [String] = [],
        appearance: Appearance = .system,
        languageCode: String? = nil,
        eraseOnQuit: Bool = false,
        menuBarIcon: Bool = false,
        engineVersion: Int = ShortcutConfig.currentEngineVersion
    ) {
        self.kind = kind
        self.name = name
        self.slug = slug
        self.bundleIdentifier = bundleIdentifier
        self.targetPath = targetPath
        self.targetBundleIdentifier = targetBundleIdentifier
        self.launchMode = launchMode
        self.dataMode = dataMode
        self.dataPath = dataPath
        self.environment = environment
        self.arguments = arguments
        self.appearance = appearance
        self.languageCode = languageCode
        self.eraseOnQuit = eraseOnQuit
        self.menuBarIcon = menuBarIcon
        self.engineVersion = engineVersion
    }

    /// The `MADConfig` dictionary. Optional fields that are nil are omitted (property lists have no null).
    public func plistDictionary() -> [String: Any] {
        guard let data = try? PropertyListEncoder().encode(self),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any]
        else {
            preconditionFailure("ShortcutConfig holds only property-list types and always encodes to a dictionary")
        }
        return dictionary
    }

    /// Decodes a `MADConfig` dictionary. Any problem is reported as `LauncherError.configCorrupt` (spec §4.7).
    public init(plistDictionary: [String: Any]) throws {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plistDictionary, format: .binary, options: 0)
            self = try PropertyListDecoder().decode(ShortcutConfig.self, from: data)
        } catch {
            throw LauncherError.configCorrupt(String(describing: error))
        }
    }

    /// Slug for a display name: lowercased, ASCII letters and digits kept, every other run of characters
    /// collapsed to one "-", leading and trailing "-" trimmed; "shortcut" when nothing is left.
    public static func slug(for name: String) -> String {
        var slug = ""
        for character in name.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "shortcut" : slug
    }

    /// `com.mikekuta.appduplicator.<slug>` (spec §3.2).
    public static func bundleIdentifier(forSlug slug: String) -> String {
        bundleIdentifierPrefix + slug
    }

    /// Default data folder: `<home>/Library/Application Support/App Duplicator/<slug>`.
    public static func defaultDataPath(forSlug slug: String, home: URL) -> String {
        home.appending(path: "Library/Application Support/App Duplicator", directoryHint: .isDirectory)
            .appending(path: slug, directoryHint: .isDirectory)
            .path
    }

    /// File-system form of a display name, used for `<Name>.app`, `MacOS/<Name>` and `<Name>.log`:
    /// "/" and ":" become "-", surrounding whitespace is trimmed; "Shortcut" when nothing is left.
    public static func fileSystemName(for name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Shortcut" : cleaned
    }
}
