import Foundation

/// Writes a shortcut bundle (spec §3.2). The bundle is named `<Name>.app` because the Dock tile title is the
/// bundle's file name (spec §4.1). Writing is atomic: the bundle is assembled in a hidden temporary directory next
/// to the destination and renamed into place.
public struct BundleWriter {
    /// Keys `BundleWriter` must never write: the shortcut must not steal URL schemes or document types (spec §3.2).
    public static let forbiddenInfoPlistKeys = [
        "CFBundleURLTypes", "CFBundleDocumentTypes", "UTExportedTypeDeclarations", "UTImportedTypeDeclarations",
    ]

    let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Writes `<directory>/<Name>.app`, replacing an existing bundle of that name, and returns its URL.
    /// `launcherBinary` is copied to `Contents/MacOS/<Name>`; the target's icon file is copied (never symlinked)
    /// to `Contents/Resources/AppIcon.icns`.
    public func write(config: ShortcutConfig, app: InspectedApp, launcherBinary: URL, to directory: URL) throws -> URL {
        try write(config: config, app: app, launcherBinary: launcherBinary, iconFile: app.iconFileURL, to: directory)
    }

    /// Same as `write(config:app:launcherBinary:to:)` with an explicit icon: `iconFile` (any `.icns`, or nil for no icon)
    /// is copied to `Contents/Resources/AppIcon.icns` instead of the target's icon. The library app passes the result of
    /// its icon mode (copied / custom / generated) here.
    public func write(config: ShortcutConfig, app: InspectedApp, launcherBinary: URL, iconFile: URL?, to directory: URL) throws -> URL {
        // Target's LSEnvironment merged under the shortcut's environment: shortcut wins.
        let lsEnvironment = app.lsEnvironment.merging(config.environment) { _, shortcut in shortcut }
        return try assemble(config: config, executable: launcherBinary, iconFile: iconFile, lsEnvironment: lsEnvironment, to: directory)
    }

    /// Writes a bundle that has no target app (web app shortcuts, spec §5): `executable` (the WebShell binary) is copied
    /// to `Contents/MacOS/<Name>` with mode 0o755, `iconFile` (an `.icns`, or nil for no icon) to
    /// `Contents/Resources/AppIcon.icns`, and `LSEnvironment` is exactly `config.environment`. The Info.plist key set
    /// is the same as for app shortcuts.
    public func write(config: ShortcutConfig, executable: URL, iconFile: URL?, to directory: URL) throws -> URL {
        try assemble(config: config, executable: executable, iconFile: iconFile, lsEnvironment: config.environment, to: directory)
    }

    /// Builds `<directory>/<Name>.app` in a hidden staging directory and renames it into place.
    private func assemble(config: ShortcutConfig, executable executableSource: URL, iconFile: URL?, lsEnvironment: [String: String], to directory: URL) throws -> URL {
        let bundleName = ShortcutConfig.fileSystemName(for: config.name)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: bundleName + ".app", directoryHint: .isDirectory)
        let staging = directory.appending(path: ".\(bundleName).\(UUID().uuidString).tmp", directoryHint: .isDirectory)
        do {
            let contents = staging.appending(path: "Contents", directoryHint: .isDirectory)
            let macOS = contents.appending(path: "MacOS", directoryHint: .isDirectory)
            let resources = contents.appending(path: "Resources", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

            let executable = macOS.appending(path: bundleName, directoryHint: .notDirectory)
            try Data(contentsOf: executableSource).write(to: executable)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

            var hasIcon = false
            if let icon = iconFile, fileManager.fileExists(atPath: icon.path) {
                // Data(contentsOf:) follows symlinks, so the bundle always gets a regular-file copy.
                try Data(contentsOf: icon).write(to: resources.appending(path: "AppIcon.icns", directoryHint: .notDirectory))
                hasIcon = true
            }

            try Data("APPL????".utf8).write(to: contents.appending(path: "PkgInfo", directoryHint: .notDirectory))
            let info = Self.infoDictionary(config: config, lsEnvironment: lsEnvironment, executableName: bundleName, hasIcon: hasIcon)
            let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plistData.write(to: contents.appending(path: "Info.plist", directoryHint: .notDirectory))

            try moveIntoPlace(staging, destination: destination, directory: directory, bundleName: bundleName)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return destination
    }

    /// The complete shortcut Info.plist (spec §3.2), shared by app and web app shortcuts. Only these keys are ever written.
    private static func infoDictionary(config: ShortcutConfig, lsEnvironment: [String: String], executableName: String, hasIcon: Bool) -> [String: Any] {
        var info: [String: Any] = [
            "CFBundleName": config.name,
            "CFBundleDisplayName": config.name,
            "CFBundleIdentifier": config.bundleIdentifier,
            "CFBundleExecutable": executableName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": String(config.engineVersion),
            "LSMinimumSystemVersion": "26.0",
            "NSHighResolutionCapable": true,
            "LSEnvironment": lsEnvironment,
            ShortcutConfig.infoPlistKey: config.plistDictionary(),
            ShortcutConfig.engineVersionInfoPlistKey: config.engineVersion,
        ]
        if hasIcon {
            info["CFBundleIconFile"] = "AppIcon"
        }
        return info
    }

    /// Rename-based replace: old bundle aside, new bundle in, old bundle deleted; rolls back if the move fails.
    private func moveIntoPlace(_ staging: URL, destination: URL, directory: URL, bundleName: String) throws {
        guard (try? fileManager.attributesOfItem(atPath: destination.path)) != nil else {
            try fileManager.moveItem(at: staging, to: destination)
            return
        }
        let backup = directory.appending(path: ".\(bundleName).\(UUID().uuidString).old", directoryHint: .isDirectory)
        try fileManager.moveItem(at: destination, to: backup)
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.moveItem(at: backup, to: destination)
            throw error
        }
        try? fileManager.removeItem(at: backup)
    }
}
