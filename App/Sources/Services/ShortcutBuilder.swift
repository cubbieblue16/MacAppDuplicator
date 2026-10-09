import DuplicatorCore
import Foundation

/// Create / regenerate / duplicate / export / delete shortcut bundles (spec §7 actions). Every write goes through
/// `BundleWriter` + `Signer`; the target app is only ever read.
struct ShortcutBuilder {
    enum BuilderError: Error, LocalizedError {
        case alreadyExists(URL)
        case targetMissing(String)

        var errorDescription: String? {
            switch self {
            case .alreadyExists(let url): "\(url.lastPathComponent) already exists in \(url.deletingLastPathComponent().path)."
            case .targetMissing(let path): "The target app was not found at \(path)."
            }
        }
    }

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
    func export(record: ShortcutRecord, to destination: URL) throws -> URL {
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.copyItem(at: record.bundleURL, to: destination)
        return destination
    }

    /// Moves the bundle to the Trash; with `removeData`, also trashes the shortcut's data folder (never the target).
    /// Returns the Trash location of everything it trashed, in order (bundle first).
    @discardableResult
    func delete(record: ShortcutRecord, removeData: Bool) throws -> [URL] {
        var trashed: [URL] = []
        trashed.append(try trash(record.bundleURL))
        guard removeData else { return trashed }
        let home = fileManager.homeDirectoryForCurrentUser
        let dataPath = record.config.dataPath ?? ShortcutConfig.defaultDataPath(forSlug: record.config.slug, home: home)
        let dataURL = URL(fileURLWithPath: dataPath, isDirectory: true)
        if fileManager.fileExists(atPath: dataURL.path) {
            trashed.append(try trash(dataURL))
        }
        return trashed
    }

    private func trash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }

    /// A nil `dataPath` means "use the default data folder". It is resolved here, at write time, so the written
    /// `MADConfig` is always explicit (Core skips data separation when `dataPath` is nil and the mode is not disabled).
    private func write(config: ShortcutConfig, in directory: URL) throws -> URL {
        var config = config
        if config.dataMode != .disabled, config.dataPath == nil {
            config.dataPath = ShortcutConfig.defaultDataPath(forSlug: config.slug, home: fileManager.homeDirectoryForCurrentUser)
        }
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
