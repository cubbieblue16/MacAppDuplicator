import Foundation
import Security

/// What `AppInspector` learned about a target `.app` (spec §3.1, §4.2).
public struct InspectedApp: Equatable, Sendable {
    public var bundleURL: URL
    public var bundleIdentifier: String
    public var name: String
    public var version: String
    public var executableURL: URL
    public var family: AppFamily
    public var isSandboxed: Bool
    public var iconFileURL: URL?
    /// Non-zero `kSecCodeInfoPlatformIdentifier`: an Apple platform binary (spec §4.1).
    public var isPlatformBinary: Bool
    /// The code signature carries launch constraints (spec §4.1).
    public var hasLaunchConstraints: Bool
    /// The target's own `LSEnvironment` (string values only); merged into the shortcut's (spec §3.2).
    public var lsEnvironment: [String: String]
    /// Problems found while inspecting that did not stop inspection (for example an unreadable signature).
    public var warnings: [String]

    public init(
        bundleURL: URL,
        bundleIdentifier: String,
        name: String,
        version: String,
        executableURL: URL,
        family: AppFamily,
        isSandboxed: Bool,
        iconFileURL: URL?,
        isPlatformBinary: Bool = false,
        hasLaunchConstraints: Bool = false,
        lsEnvironment: [String: String] = [:],
        warnings: [String] = []
    ) {
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.version = version
        self.executableURL = executableURL
        self.family = family
        self.isSandboxed = isSandboxed
        self.iconFileURL = iconFileURL
        self.isPlatformBinary = isPlatformBinary
        self.hasLaunchConstraints = hasLaunchConstraints
        self.lsEnvironment = lsEnvironment
        self.warnings = warnings
    }
}

/// Reads a target `.app` without modifying it (spec §2, §4.2, §9).
public struct AppInspector {
    /// Signing-information keys that hold launch-constraint dictionaries. They are undocumented
    /// (no SDK constants) and are returned only when `kSecCSInternalInformation` is requested;
    /// verified on macOS 27 against bundles signed with `codesign --launch-constraint-self/-parent/-responsible`.
    /// `LibraryConstraints` is deliberately not listed: it restricts loaded libraries, not who may launch the app.
    static let launchConstraintKeys = ["LaunchConstraints-self", "LaunchConstraints-parent", "LaunchConstraints-responsible"]

    public init() {}

    /// Validates the bundle (spec §9) and inspects it.
    /// Throws `LauncherError.notAnAppBundle` when `url` is not a directory ending in `.app` with a
    /// `Contents/Info.plist` that names an existing executable `CFBundleExecutable` and a `CFBundleIdentifier`
    /// (target resolution, spec §3.4 step 3, matches on the bundle identifier).
    public func inspect(appAt url: URL) throws -> InspectedApp {
        let fileManager = FileManager.default
        let bundleURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard bundleURL.pathExtension == "app",
              fileManager.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let info = InfoPlistReader.read(bundleAt: bundleURL),
              let executableName = Self.nonEmptyString(info["CFBundleExecutable"]),
              let bundleIdentifier = Self.nonEmptyString(info["CFBundleIdentifier"])
        else { throw LauncherError.notAnAppBundle(bundleURL.path) }

        let contents = bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
        let executableURL = contents.appending(path: "MacOS", directoryHint: .isDirectory)
            .appending(path: executableName, directoryHint: .notDirectory)
        var executableIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: executableURL.path, isDirectory: &executableIsDirectory),
              !executableIsDirectory.boolValue,
              fileManager.isExecutableFile(atPath: executableURL.path)
        else { throw LauncherError.notAnAppBundle(bundleURL.path) }

        let name = Self.nonEmptyString(info["CFBundleDisplayName"])
            ?? Self.nonEmptyString(info["CFBundleName"])
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let version = Self.nonEmptyString(info["CFBundleShortVersionString"])
            ?? Self.nonEmptyString(info["CFBundleVersion"])
            ?? ""
        let lsEnvironment = (info["LSEnvironment"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        let signing = Self.signingFacts(bundleURL: bundleURL)

        return InspectedApp(
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier,
            name: name,
            version: version,
            executableURL: executableURL,
            family: Self.detectFamily(contents: contents, info: info, fileManager: fileManager),
            isSandboxed: signing.isSandboxed,
            iconFileURL: Self.iconFileURL(contents: contents, info: info, fileManager: fileManager),
            isPlatformBinary: signing.isPlatformBinary,
            hasLaunchConstraints: signing.hasLaunchConstraints,
            lsEnvironment: lsEnvironment,
            warnings: signing.warnings
        )
    }

    // MARK: - Family detection (spec §4.2; checked in order, first match wins)

    static func detectFamily(contents: URL, info: [String: Any], fileManager: FileManager) -> AppFamily {
        func exists(_ relativePath: String) -> Bool {
            fileManager.fileExists(atPath: contents.appending(path: relativePath).path)
        }
        if exists("Resources/app.asar"),
           exists("Resources/todesktop-runtime-config.json") || info["ToDesktopVersion"] != nil {
            return .todesktop
        }
        if exists("Frameworks/Electron Framework.framework") {
            return .electron
        }
        if hasChromiumMarker(frameworks: contents.appending(path: "Frameworks", directoryHint: .isDirectory), fileManager: fileManager) {
            return .chromium
        }
        if exists("Resources/omni.ja"), exists("MacOS/XUL") || exists("Resources/application.ini") {
            return .firefox
        }
        if exists("Eclipse/eclipse.ini") || exists("Eclipse/configuration/config.ini") || info["Eclipse"] != nil {
            return .eclipse
        }
        return .native
    }

    /// `Frameworks/*.framework/Versions/*/Helpers/* Helper (GPU).app` or
    /// `Frameworks/*.framework/Versions/*/Libraries/libvk_swiftshader.dylib` (never `libEGL`: Brave does not ship it).
    static func hasChromiumMarker(frameworks: URL, fileManager: FileManager) -> Bool {
        func children(_ directory: URL) -> [String] {
            (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        }
        for framework in children(frameworks) where framework.hasSuffix(".framework") {
            let versions = frameworks.appending(path: framework, directoryHint: .isDirectory)
                .appending(path: "Versions", directoryHint: .isDirectory)
            for version in children(versions) {
                let versionURL = versions.appending(path: version, directoryHint: .isDirectory)
                let helpers = versionURL.appending(path: "Helpers", directoryHint: .isDirectory)
                if children(helpers).contains(where: { $0.hasSuffix(" Helper (GPU).app") }) {
                    return true
                }
                if fileManager.fileExists(atPath: versionURL.appending(path: "Libraries/libvk_swiftshader.dylib").path) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Icon

    /// `CFBundleIconFile` inside `Contents/Resources`, with `.icns` appended when the name has no extension
    /// (TextEdit declares `AppIcon`, Claude declares `electron.icns`). Nil when absent.
    static func iconFileURL(contents: URL, info: [String: Any], fileManager: FileManager) -> URL? {
        guard var fileName = nonEmptyString(info["CFBundleIconFile"]) else { return nil }
        if (fileName as NSString).pathExtension.isEmpty {
            fileName += ".icns"
        }
        let url = contents.appending(path: "Resources", directoryHint: .isDirectory)
            .appending(path: fileName, directoryHint: .notDirectory)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Code signature (Security.framework only; never shells out to codesign)

    struct SigningFacts: Equatable {
        var isSandboxed = false
        var isPlatformBinary = false
        var hasLaunchConstraints = false
        var warnings: [String] = []
    }

    static func signingFacts(bundleURL: URL) -> SigningFacts {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return SigningFacts(warnings: ["Could not read the code signature of \(bundleURL.lastPathComponent) (OSStatus \(createStatus)); treated as not sandboxed."])
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation | kSecCSInternalInformation)
        let infoStatus = SecCodeCopySigningInformation(code, flags, &information)
        guard infoStatus == errSecSuccess, let dictionary = information as? [String: Any] else {
            return SigningFacts(warnings: ["Could not read the code signature of \(bundleURL.lastPathComponent) (OSStatus \(infoStatus)); treated as not sandboxed."])
        }
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let platformIdentifier = (dictionary[kSecCodeInfoPlatformIdentifier as String] as? NSNumber)?.intValue ?? 0
        return SigningFacts(
            isSandboxed: (entitlements?["com.apple.security.app-sandbox"] as? Bool) == true,
            isPlatformBinary: platformIdentifier != 0,
            hasLaunchConstraints: launchConstraintKeys.contains { dictionary[$0] != nil }
        )
    }

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
