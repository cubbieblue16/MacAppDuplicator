import DuplicatorCore
import Foundation
import os

/// Create / regenerate / duplicate / export / delete shortcut bundles (spec §7 actions). Every write goes through
/// `BundleWriter` + `Signer`; the target app is only ever read.
struct ShortcutBuilder {
    enum BuilderError: Error, LocalizedError {
        case alreadyExists(URL)
        case targetMissing(String)
        case exportOverlapsShortcut(URL)
        case exportOverlapsTarget(URL)

        var errorDescription: String? {
            switch self {
            case .alreadyExists(let url): "\(url.lastPathComponent) already exists in \(url.deletingLastPathComponent().path)."
            case .targetMissing(let path): "The target app was not found at \(path)."
            case .exportOverlapsShortcut(let url): "Cannot export to \(url.path): it is, contains or is inside the shortcut itself."
            case .exportOverlapsTarget(let url): "Cannot export to \(url.path): it is, contains or is inside the target app."
            }
        }
    }

    private static let logger = Logger(subsystem: "com.mikekuta.MacAppDuplicator", category: "ShortcutBuilder")

    let launcherBinary: URL
    /// Codesign identity display name, or nil for ad hoc.
    let signingIdentity: String?
    var fileManager: FileManager = .default

    init(launcherBinary: URL, signingIdentity: String?) {
        self.launcherBinary = launcherBinary
        self.signingIdentity = signingIdentity
    }

    /// Writes `<name>.app` into `directory`. Throws `alreadyExists` rather than replacing a bundle it did not make.
    func create(config: ShortcutConfig, in directory: URL) throws -> URL {
        let destination = directory.appending(path: "\(ShortcutConfig.fileSystemName(for: config.name)).app", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: destination.path) { throw BuilderError.alreadyExists(destination) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try write(config: config, in: directory)
    }

    /// Rewrites an existing shortcut in place with `config` (same folder; the name may change the bundle file name).
    func regenerate(record: ShortcutRecord, config: ShortcutConfig) throws -> URL {
        let directory = record.bundleURL.deletingLastPathComponent()
        let newURL = directory.appending(path: "\(ShortcutConfig.fileSystemName(for: config.name)).app", directoryHint: .isDirectory)
        if newURL.standardizedFileURL != record.bundleURL.standardizedFileURL, fileManager.fileExists(atPath: newURL.path) {
            throw BuilderError.alreadyExists(newURL)
        }
        let written = try write(config: config, in: directory)
        if written.standardizedFileURL != record.bundleURL.standardizedFileURL {
            try fileManager.removeItem(at: record.bundleURL)
        }
        return written
    }

    /// A new shortcut with the same target and launch settings, its own slug, bundle id and default data folder.
    func duplicate(record: ShortcutRecord, newName: String, in directory: URL) throws -> URL {
        var config = record.config
        config.name = newName
        config.slug = ShortcutConfig.slug(for: newName)
        config.bundleIdentifier = ShortcutConfig.bundleIdentifier(forSlug: config.slug)
        config.dataPath = nil
        return try create(config: config, in: directory)
    }

    /// Copies the bundle to `destination` (an `.app` path chosen by the user). The copy keeps its signature.
    /// A destination that is, contains or is inside the target or the shortcut itself is refused before any write.
    /// The copy is staged next to the destination and swapped in with `replaceItemAt`, so an existing item there is
    /// removed only once its replacement is in place, and a failed export leaves both the source and it untouched.
    func export(record: ShortcutRecord, to destination: URL) throws -> URL {
        let canonicalDestination = CanonicalPath(destination.path)
        if record.config.targetPath.hasPrefix("/"), canonicalDestination.overlaps(CanonicalPath(record.config.targetPath)) {
            throw BuilderError.exportOverlapsTarget(destination)
        }
        if canonicalDestination.overlaps(CanonicalPath(record.bundleURL.path)) {
            throw BuilderError.exportOverlapsShortcut(destination)
        }
        let staging = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).mad-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.copyItem(at: record.bundleURL, to: staging)
            if fileManager.fileExists(atPath: destination.path) {
                // New metadata only: the export must be byte-for-byte the signed source, not inherit the old item's.
                return try fileManager.replaceItemAt(destination, withItemAt: staging, options: .usingNewMetadataOnly) ?? destination
            }
            try fileManager.moveItem(at: staging, to: destination)
            return destination
        } catch {
            removeStagingCopy(staging)
            throw error
        }
    }

    /// Moves the bundle to the Trash; with `removeData`, also trashes the shortcut's data folder (never the target).
    /// The data folder must pass `DataPathGuard` against `libraryFolders` (the bundle's own folder is always included)
    /// and `otherRecordDataPaths`; a refusal throws before anything is trashed. Returns the Trash location of
    /// everything it trashed, in order (bundle first).
    @discardableResult
    func delete(record: ShortcutRecord, removeData: Bool, libraryFolders: [URL] = [], otherRecordDataPaths: [String] = []) throws -> [URL] {
        var dataFolder: URL?
        let home = fileManager.homeDirectoryForCurrentUser
        if removeData, let dataPath = record.config.effectiveDataPath(home: home) {
            dataFolder = try DataPathGuard.validate(
                dataPath: dataPath, targetPath: record.config.targetPath, outputFolder: record.bundleURL.deletingLastPathComponent(),
                libraryFolders: libraryFolders, otherRecordDataPaths: otherRecordDataPaths, home: home
            ).get()
        }
        var trashed: [URL] = []
        trashed.append(try trash(record.bundleURL))
        if let dataFolder, fileManager.fileExists(atPath: dataFolder.path) {
            trashed.append(try trash(dataFolder))
        }
        return trashed
    }

    /// Best-effort cleanup after a failed export; the export error is what the caller sees.
    private func removeStagingCopy(_ staging: URL) {
        guard fileManager.fileExists(atPath: staging.path) else { return }
        do {
            try fileManager.removeItem(at: staging)
        } catch {
            Self.logger.warning("Could not remove export staging copy \(staging.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func trash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }

    /// A nil `dataPath` means "use the default data folder". It is resolved here, at write time, so the written
    /// `MADConfig` is always explicit (Core skips data separation when `dataPath` is nil and the mode is not disabled).
    ///
    /// Every bundle this build writes carries this build's engine version; `BundleWriter` mirrors it into
    /// `MADEngineVersion`, so rewriting a stale shortcut with its stored config would otherwise leave it stale forever.
    private func write(config: ShortcutConfig, in directory: URL) throws -> URL {
        var config = config.resolvingDefaultDataPath(home: fileManager.homeDirectoryForCurrentUser)
        config.engineVersion = ShortcutConfig.currentEngineVersion
        let targetURL = URL(fileURLWithPath: config.targetPath)
        guard fileManager.fileExists(atPath: targetURL.path) else { throw BuilderError.targetMissing(config.targetPath) }
        let app = try AppInspector().inspect(appAt: targetURL)
        let scratch = fileManager.temporaryDirectory.appending(path: "mad-build-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let icon = try IconResolver.iconFile(for: config, app: app, scratchDirectory: scratch)
        let bundle = try BundleWriter(fileManager: fileManager).write(config: config, app: app, launcherBinary: launcherBinary, iconFile: icon, to: directory)
        try Signer().sign(bundle: bundle, identity: signingIdentity)
        return bundle
    }
}
