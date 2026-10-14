import Foundation

/// One shortcut's configuration (spec §3.1). Stored in the shortcut's own Info.plist under `MADConfig` (spec §2).
public struct ShortcutConfig: Codable, Hashable, Sendable {
    /// Engine version written by this build; mirrored at Info.plist top level as `MADEngineVersion`.
    public static let currentEngineVersion = 1
    /// Info.plist key that holds `plistDictionary()`.
    public static let infoPlistKey = "MADConfig"
    /// Info.plist key that mirrors `engineVersion` at top level.
    public static let engineVersionInfoPlistKey = "MADEngineVersion"
    /// Info.plist key holding the per-install token of the App Duplicator install that wrote the bundle. A bundle
    /// carrying `MADConfig` is only data; this key lets the library app tell its own bundles from received or planted
    /// ones before it regenerates and signs anything (security C3).
    public static let installTokenInfoPlistKey = "MADInstallToken"
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
    /// Template for the helper's New Window menu item (spec §4.6), copied from the compatibility profile when the wizard
    /// selects a target; nil or blank hides the item. `NewWindowCommandBuilder` renders it; it never reaches a shell.
    public var newWindowCommand: String?
    /// Icon source for the shortcut bundle (spec §7). Default `.copied`.
    public var iconMode: IconMode
    /// Image file converted to the bundle icon when `iconMode == .custom` (PNG, JPEG, TIFF or ICNS).
    public var customIconPath: String?
    /// HOME-override symlink list override; nil means `HomeTreeBuilder.defaultSymlinkEntries` (spec §4.3, §7 Settings).
    public var homeSymlinkEntries: [String]?
    /// Web app settings; set exactly when `kind == .webApp`, nil otherwise (spec §5).
    public var webApp: WebAppConfig?
    /// File or folder settings; set exactly when `kind` is `.file` or `.folder`, nil otherwise (spec §6).
    public var file: FileConfig?
    /// Command settings; set exactly when `kind == .cli`, nil otherwise (spec §6).
    public var cli: CLIConfig?
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
        newWindowCommand: String? = nil,
        iconMode: IconMode = .copied,
        customIconPath: String? = nil,
        homeSymlinkEntries: [String]? = nil,
        webApp: WebAppConfig? = nil,
        file: FileConfig? = nil,
        cli: CLIConfig? = nil,
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
        self.newWindowCommand = newWindowCommand
        self.iconMode = iconMode
        self.customIconPath = customIconPath
        self.homeSymlinkEntries = homeSymlinkEntries
        self.webApp = webApp
        self.file = file
        self.cli = cli
        self.engineVersion = engineVersion
    }

    private enum CodingKeys: String, CodingKey {
        case kind, name, slug, bundleIdentifier, targetPath, targetBundleIdentifier, launchMode, dataMode, dataPath
        case environment, arguments, appearance, languageCode, eraseOnQuit, menuBarIcon, newWindowCommand
        case iconMode, customIconPath, homeSymlinkEntries, webApp, file, cli, engineVersion
    }

    /// Decodes Phase 1 to 5 dictionaries too: `newWindowCommand`, `iconMode`, `customIconPath`, `homeSymlinkEntries`,
    /// `webApp`, `file` and `cli` are optional on input.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(ShortcutKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        slug = try container.decode(String.self, forKey: .slug)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        targetPath = try container.decode(String.self, forKey: .targetPath)
        targetBundleIdentifier = try container.decode(String.self, forKey: .targetBundleIdentifier)
        launchMode = try container.decode(LaunchMode.self, forKey: .launchMode)
        dataMode = try container.decode(DataMode.self, forKey: .dataMode)
        dataPath = try container.decodeIfPresent(String.self, forKey: .dataPath)
        environment = try container.decode([String: String].self, forKey: .environment)
        arguments = try container.decode([String].self, forKey: .arguments)
        appearance = try container.decode(Appearance.self, forKey: .appearance)
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
        eraseOnQuit = try container.decode(Bool.self, forKey: .eraseOnQuit)
        menuBarIcon = try container.decode(Bool.self, forKey: .menuBarIcon)
        newWindowCommand = try container.decodeIfPresent(String.self, forKey: .newWindowCommand)
        iconMode = try container.decodeIfPresent(IconMode.self, forKey: .iconMode) ?? .copied
        customIconPath = try container.decodeIfPresent(String.self, forKey: .customIconPath)
        homeSymlinkEntries = try container.decodeIfPresent([String].self, forKey: .homeSymlinkEntries)
        webApp = try container.decodeIfPresent(WebAppConfig.self, forKey: .webApp)
        file = try container.decodeIfPresent(FileConfig.self, forKey: .file)
        cli = try container.decodeIfPresent(CLIConfig.self, forKey: .cli)
        // A command shortcut's environment is written into the terminal command, so it gets the same check as `cli`.
        if cli != nil, let problem = CLIConfig.environmentControlCharacterProblem(environment) {
            throw DecodingError.dataCorruptedError(forKey: .environment, in: container, debugDescription: problem)
        }
        engineVersion = try container.decode(Int.self, forKey: .engineVersion)
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

    /// Decodes a `MADConfig` dictionary. Any problem is reported as `LauncherError.configCorrupt` (spec §4.7), including
    /// a slug that `isValidSlug` refuses (`"invalid slug"`).
    public init(plistDictionary: [String: Any]) throws {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plistDictionary, format: .binary, options: 0)
            self = try PropertyListDecoder().decode(ShortcutConfig.self, from: data)
        } catch {
            throw LauncherError.configCorrupt(String(describing: error))
        }
        // The slug names folders under the data root, so a hand-edited one must not be able to point outside it.
        guard Self.isValidSlug(slug) else {
            throw LauncherError.configCorrupt("invalid slug")
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

    /// True when `slug` is non-empty and holds only lowercase ASCII letters, digits and "-" (`^[a-z0-9-]+$`), which is
    /// what `slug(for:)` produces. `defaultDataPath(forSlug:home:)` builds a folder path from it, so a "/", "." or any
    /// other character could lead outside the data root.
    public static func isValidSlug(_ slug: String) -> Bool {
        !slug.isEmpty && slug.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "-")
        }
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
