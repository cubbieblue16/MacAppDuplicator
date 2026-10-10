import DuplicatorCore
import Foundation
import os

/// Create / regenerate / duplicate / export / delete shortcut bundles (spec §7 actions). Every write goes through
/// `BundleWriter` + `Signer`; the target app is only ever read.
struct ShortcutBuilder: Sendable {
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

    /// What an export did: where the copy is, and where the item that was already at the destination went.
    struct ExportOutcome: Equatable, Sendable, Identifiable {
        let exportedURL: URL
        /// The Trash location of the item that was at the destination, or nil when there was none.
        let trashedExisting: URL?

        var id: URL { exportedURL }
    }

    private static let logger = Logger(subsystem: "com.mikekuta.MacAppDuplicator", category: "ShortcutBuilder")

    let launcherBinary: URL
    /// Codesign identity display name, or nil for ad hoc.
    let signingIdentity: String?
    // FileManager is not Sendable, so it is not a stored property of this Sendable struct (Rebuild All runs the
    // builder in a detached task). Nothing ever set it; every use reads the shared instance.
    var fileManager: FileManager { .default }

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
    /// A destination that is, contains or is inside the shortcut, the stored target or `resolvedTargetPath` (where
    /// `TargetResolver` finds the target now) is refused before any write (re-review Minor 4). Staging copies a
    /// crashed export left in the destination folder (`isStagingName`) are removed first. The copy is staged next to
    /// the destination; only once staging is complete does an item already at the destination go to the Trash (never
    /// deleted), and it is put back if the final move fails (re-review Minor 5).
    func exportCopy(record: ShortcutRecord, to destination: URL, resolvedTargetPath: String? = nil) throws -> ExportOutcome {
        let canonicalDestination = CanonicalPath(destination.path)
        for targetPath in [record.config.targetPath, resolvedTargetPath ?? ""] where targetPath.hasPrefix("/") {
            if canonicalDestination.overlaps(CanonicalPath(targetPath)) { throw BuilderError.exportOverlapsTarget(destination) }
        }
        if canonicalDestination.overlaps(CanonicalPath(record.bundleURL.path)) {
            throw BuilderError.exportOverlapsShortcut(destination)
        }
        let folder = destination.deletingLastPathComponent()
        sweepStagingCopies(in: folder)
        let staging = folder.appending(path: ".\(destination.lastPathComponent).mad-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.copyItem(at: record.bundleURL, to: staging)
        } catch {
            removeStagingCopy(staging)
            throw error
        }
        var trashedExisting: URL?
        if fileManager.fileExists(atPath: destination.path) {
            do {
                trashedExisting = try trash(destination)
            } catch {
                removeStagingCopy(staging)
                throw error
            }
        }
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            if let trashedExisting { restore(trashedExisting, to: destination) }
            removeStagingCopy(staging)
            throw error
        }
        return ExportOutcome(exportedURL: destination, trashedExisting: trashedExisting)
    }

    /// `exportCopy` checked against the target's current location as well as the stored one; returns where the copy is.
    func export(record: ShortcutRecord, to destination: URL) throws -> URL {
        try exportCopy(record: record, to: destination, resolvedTargetPath: TargetResolver().resolvedPath(for: record.config)).exportedURL
    }

    /// Moves the bundle to the Trash; with `removeData`, also trashes the shortcut's data folder (never the target).
    /// The data folder must pass `DataPathGuard` against `libraryFolders` (the bundle's own folder is always included),
    /// `otherRecordDataPaths`, `shortcutBundles` (the bundle itself is always included), the target's current location
    /// and its own data in `~/Library`; a refusal throws before anything is trashed. Returns the Trash location of
    /// everything it trashed, in order (bundle first).
    @discardableResult
    func delete(
        record: ShortcutRecord, removeData: Bool, libraryFolders: [URL] = [], otherRecordDataPaths: [String] = [], shortcutBundles: [URL] = []
    ) throws -> [URL] {
        var dataFolder: URL?
        let home = fileManager.homeDirectoryForCurrentUser
        if removeData, record.config.dataMode != .disabled, let dataPath = record.config.effectiveDataPath(home: home) {
            dataFolder = try DataPathGuard.validate(
                dataPath: dataPath, targetPath: record.config.targetPath, outputFolder: record.bundleURL.deletingLastPathComponent(),
                libraryFolders: libraryFolders, otherRecordDataPaths: otherRecordDataPaths, home: home,
                resolvedTargetPath: TargetResolver().resolvedPath(for: record.config),
                targetBundleIdentifier: record.config.targetBundleIdentifier, shortcutBundles: [record.bundleURL] + shortcutBundles
            ).get()
        }
        var trashed: [URL] = []
        trashed.append(try trash(record.bundleURL))
        if let dataFolder, fileManager.fileExists(atPath: dataFolder.path) {
            trashed.append(try trash(dataFolder))
        }
        return trashed
    }

    /// Best-effort removal of a staging copy (after a failed export, or a stale one); a failure is only logged.
    private func removeStagingCopy(_ staging: URL) {
        guard fileManager.fileExists(atPath: staging.path) else { return }
        do {
            try fileManager.removeItem(at: staging)
        } catch {
            Self.logger.warning("Could not remove export staging copy \(staging.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes the staging copies a crashed export left in `folder` (`isStagingName`); best effort, never anything else.
    private func sweepStagingCopies(in folder: URL) {
        guard fileManager.fileExists(atPath: folder.path) else { return }
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: folder.path)
        } catch {
            Self.logger.warning("Could not list \(folder.path, privacy: .public) for stale export copies: \(error.localizedDescription, privacy: .public)")
            return
        }
        for name in names where Self.isStagingName(name) {
            removeStagingCopy(folder.appending(path: name, directoryHint: .isDirectory))
        }
    }

    /// `.<name>.mad-export-<UUID>`: the staging copy `exportCopy` makes, a name only it uses.
    static func isStagingName(_ name: String) -> Bool {
        name.wholeMatch(of: #/\..+\.mad-export-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/#) != nil
    }

    /// Best-effort undo after a failed export: puts the item that was at `destination` back from the Trash. A failure
    /// is logged with both locations and the item stays in the Trash; the export error is what the caller sees.
    private func restore(_ trashed: URL, to destination: URL) {
        do {
            try fileManager.moveItem(at: trashed, to: destination)
        } catch {
            Self.logger.warning("Could not put back \(destination.path, privacy: .public) from the Trash (\(trashed.path, privacy: .public)): \(error.localizedDescription, privacy: .public)")
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
