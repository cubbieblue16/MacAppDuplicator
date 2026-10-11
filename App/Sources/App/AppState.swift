import AppKit
import CompatProfiles
import DuplicatorCore
import Observation

struct AppError: Identifiable {
    let id = UUID()
    var context: String
    var message: String
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case apps = "Apps"
    case webApps = "Web Apps"
    case filesAndFolders = "Files & Folders"
    case commands = "Commands"

    var id: String { rawValue }

    /// `Files & Folders` spans two kinds; every other section maps to one.
    var kinds: [ShortcutKind] {
        switch self {
        case .apps: [.app]
        case .webApps: [.webApp]
        case .filesAndFolders: [.file, .folder]
        case .commands: [.cli]
        }
    }

    @MainActor
    func records(in library: ShortcutLibrary) -> [ShortcutRecord] {
        kinds.flatMap { library.records(ofKind: $0) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Whether the delete sheet may offer to trash a shortcut's data folder (final review I1).
enum DataFolderDeletionOption: Equatable {
    /// No toggle; `note` says why the data folder stays.
    case unavailable(note: String)
    /// `folder` is the resolved folder that passed `DataPathGuard`; `outsideDataRoot` asks the sheet to warn.
    case available(folder: URL, outsideDataRoot: Bool)
}

/// Window-level state and every mutating action (spec §7). Views call these; they never touch ShortcutBuilder directly.
@MainActor
@Observable
final class AppState {
    let settings: AppSettings
    let library: ShortcutLibrary
    let profiles: ProfilesModel
    /// The home folder data paths resolve against; a property so tests run against a temporary home.
    let home: URL
    private let launcherBinary: URL
    private let webShellBinary: URL

    var selection: URL?
    var isWizardPresented = false
    var wizardPrefillTarget: URL?
    var pendingError: AppError?
    /// The last Check Profile Updates result, shown in an alert until it is dismissed.
    var profileUpdateMessage: String?
    /// Rebuild All progress while it runs; nil otherwise.
    var rebuildProgress: RebuildProgress?

    /// Removes a web app's WebKit store (Task 6). A property rather than an initializer argument so tests swap in a
    /// fake without a second initializer; the default deletes real files under `~/Library/WebKit`.
    @ObservationIgnored var webDataRemover: any WebDataRemoving = WebKitWebDataRemover()

    /// `webShellBinary` nil means "next to the launcher in Resources" (where the Embed Web Shell build phase puts it).
    init(settings: AppSettings, library: ShortcutLibrary, launcherBinary: URL, webShellBinary: URL? = nil, profiles: ProfilesModel? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        self.settings = settings
        self.library = library
        self.launcherBinary = launcherBinary
        self.webShellBinary = webShellBinary ?? launcherBinary.deletingLastPathComponent().appending(path: "WebShell", directoryHint: .notDirectory)
        // Main-actor types are never default argument values; nil means the inert model (no profiles, no network).
        self.profiles = profiles ?? .inert()
    }

    var builder: ShortcutBuilder {
        ShortcutBuilder(launcherBinary: launcherBinary, webShellBinary: webShellBinary, signingIdentity: settings.signerIdentity)
    }

    /// The compatibility profile for a target bundle identifier, if the profiles in use have one.
    func profile(forBundleIdentifier bundleIdentifier: String) -> AppProfile? {
        profiles.profile(forBundleIdentifier: bundleIdentifier)
    }

    /// Check Profile Updates from the toolbar or the app menu: fetches from the Settings URL and keeps the result in
    /// `profileUpdateMessage` for the alert.
    @discardableResult
    func checkProfileUpdates() async -> String {
        let message = await profiles.checkForUpdates(from: settings.profilesURL)
        profileUpdateMessage = message
        return message
    }

    var selectedRecord: ShortcutRecord? {
        selection.flatMap { library.record(for: $0) }
    }

    func present(_ error: Error, context: String) {
        pendingError = AppError(context: context, message: error.localizedDescription)
    }

    /// Creates in the output folder, rescans, selects the new bundle. Returns nil (and sets `pendingError`) on failure.
    /// A customized Settings symlink list is stamped into the new config (final review I3); the default list is left
    /// out so the launcher keeps following `HomeTreeBuilder.defaultSymlinkEntries`.
    /// For a web app, `webIconData` is the icon fetched in the wizard (`WizardModel.webIconPayload`); the builder turns
    /// it into AppIcon.icns.
    func create(config: ShortcutConfig, webIconData: Data? = nil) async -> URL? {
        var config = config
        if config.homeSymlinkEntries == nil, settings.homeSymlinkEntries != HomeTreeBuilder.defaultSymlinkEntries {
            config.homeSymlinkEntries = settings.homeSymlinkEntries
        }
        do {
            let url = try builder.create(config: config, in: settings.outputFolder, webIconData: webIconData)
            await library.rescan()
            return select(url)
        } catch {
            present(error, context: "Could not create shortcut")
            return nil
        }
    }

    func save(record: ShortcutRecord, config: ShortcutConfig) async -> Bool {
        do {
            let url = try builder.regenerate(record: record, config: config)
            await library.rescan()
            select(url)
            return true
        } catch {
            present(error, context: "Could not save shortcut")
            return false
        }
    }

    func launch(_ record: ShortcutRecord) async {
        do { try await AppLauncher.launch(record) } catch { present(error, context: "Could not launch shortcut") }
    }

    func reveal(_ record: ShortcutRecord) {
        AppLauncher.revealInFinder(record.bundleURL)
    }

    func regenerate(_ record: ShortcutRecord) async {
        _ = await save(record: record, config: record.config)
    }

    /// Rebuild All (final review M16): rewrites every record whose engine version is stale, one at a time in a
    /// detached task so the main actor stays free, and carries on past a failure. `rebuildProgress` counts the
    /// finished records while it runs. Returns one result per record, in `recordsNeedingRebuild` order; failures are
    /// reported there, never through `pendingError`.
    func rebuildAll() async -> [RebuildResult] {
        let records = library.recordsNeedingRebuild
        let builder = self.builder
        var results: [RebuildResult] = []
        rebuildProgress = RebuildProgress(done: 0, total: records.count)
        for record in records {
            let outcome = await Task.detached(priority: .userInitiated) { () -> RebuildResult.Outcome in
                do {
                    _ = try builder.regenerate(record: record, config: record.config)
                    return .rebuilt
                } catch {
                    return .failed(error.localizedDescription)
                }
            }.value
            results.append(RebuildResult(id: record.bundleURL, name: record.name, outcome: outcome))
            rebuildProgress = RebuildProgress(done: results.count, total: records.count)
        }
        await library.rescan()
        rebuildProgress = nil
        return results
    }

    func duplicate(_ record: ShortcutRecord, newName: String) async {
        do {
            let url = try builder.duplicate(
                record: record, newName: newName, in: record.bundleURL.deletingLastPathComponent(),
                takenSlugs: SlugAllocator.takenSlugs(in: library.records))
            await library.rescan()
            select(url)
        } catch {
            present(error, context: "Could not duplicate shortcut")
        }
    }

    /// Exports a copy of `record` (re-review Minors 4 and 5): checked against the target's current location as well
    /// as the stored one; an item already at `destination` goes to the Trash and comes back if the export fails. The
    /// library is rescanned afterwards. Returns nil and sets `pendingError` on failure.
    func exportCopy(_ record: ShortcutRecord, to destination: URL) async -> ShortcutBuilder.ExportOutcome? {
        // The copy can block on a folder-access prompt or a large bundle, so it runs off the main actor (like Rebuild All).
        let builder = self.builder
        let otherTargetPaths = library.records.map(\.config.targetPath)
        do {
            let outcome = try await Task.detached(priority: .userInitiated) {
                try builder.exportCopy(
                    record: record, to: destination, resolvedTargetPath: TargetResolver().resolvedPath(for: record.config),
                    otherTargetPaths: otherTargetPaths
                )
            }.value
            await library.rescan()
            return outcome
        } catch {
            present(error, context: "Could not export shortcut")
            return nil
        }
    }

    func export(_ record: ShortcutRecord, to destination: URL) async -> Bool {
        await exportCopy(record, to: destination) != nil
    }

    /// Why exporting to `destination` deserves a second look, or nil: a copy directly inside a library folder is
    /// scanned as a second shortcut with the same bundle identifier and data folder (re-review Minor 5).
    func exportWarning(for destination: URL) -> String? {
        let parent = CanonicalPath(destination.deletingLastPathComponent().path)
        guard let folder = settings.allLibraryFolders.first(where: { CanonicalPath($0.path).isSame(as: parent) }) else { return nil }
        return "\(destination.lastPathComponent) would be inside the library folder \(folder.path), so it would appear in the library as a second shortcut with the same bundle identifier and data folder."
    }

    /// Moves the shortcut (and, with `removeData`, its data folder) to the Trash. With `removesWebData` a web app's
    /// logins, cookies and cache are removed first; when that fails nothing is trashed, so the shortcut stays and the
    /// error alert explains why. Delete is offered only from the selected shortcut's editor, and a selection made by an
    /// earlier duplicate or rename must not survive into the next detail view, so the selection is always cleared.
    /// Returns the Trash locations (empty on failure).
    @discardableResult
    func delete(_ record: ShortcutRecord, removeData: Bool, removeWebData removesWebData: Bool = false) async -> [URL] {
        if removesWebData, !(await self.removeWebData(for: record)) { return [] }
        let webDataRemoved = removesWebData && record.config.kind == .webApp && record.config.webApp != nil
        let commandHome = record.config.kind == .cli && removeData ? dataFolderDeletionOption(for: record) : nil
        do {
            var trashed = try builder.delete(
                record: record, removeData: removeData,
                libraryFolders: settings.allLibraryFolders, otherRecordDataPaths: dataPathsInUse(excluding: record.bundleURL),
                shortcutBundles: library.records.map(\.bundleURL)
            )
            if case .available(let folder, _) = commandHome {
                // The shortcut is already in the Trash here, so a failure must not read as "could not delete shortcut".
                do {
                    var resulting: NSURL?
                    try FileManager.default.trashItem(at: folder, resultingItemURL: &resulting)
                    trashed.append((resulting as URL?) ?? folder)
                } catch {
                    pendingError = AppError(
                        context: "Could not remove the command's HOME folder",
                        message: "The shortcut was moved to the Trash, but its HOME folder at \(folder.path) could not be. \(error.localizedDescription)"
                    )
                }
            }
            selection = nil
            await library.rescan()
            return trashed
        } catch {
            if webDataRemoved {
                pendingError = AppError(
                    context: "Could not delete shortcut",
                    message: "The web data was already removed, but the shortcut itself could not be moved to the Trash and is still in the library. \(error.localizedDescription)"
                )
            } else {
                present(error, context: "Could not delete shortcut")
            }
            return []
        }
    }

    /// Removes a web app's logins, cookies and cache (editor `Remove Web Data…` and the delete sheet's second step).
    /// Refused while the web app runs, because WebKit keeps the store open until the web view is released. Returns
    /// false (and sets `pendingError`) on failure; false without an alert for a shortcut that is not a web app; true
    /// for a web app whose configuration has no web section (nothing to remove).
    @discardableResult
    func removeWebData(for record: ShortcutRecord) async -> Bool {
        guard record.config.kind == .webApp else { return false }
        // A web app whose configuration lost its web section has no store to remove; Delete proceeds.
        guard let web = record.config.webApp else { return true }
        guard !library.isRunning(record) else {
            present(WebDataRemovalError.shortcutRunning(record.name), context: "Could not remove web data")
            return false
        }
        do {
            try await webDataRemover.removeWebData(identifier: web.dataStoreID, bundleIdentifier: record.config.bundleIdentifier)
            return true
        } catch {
            present(error, context: "Could not remove web data")
            return false
        }
    }

    /// Checks a data folder the user picked (wizard or editor) with the same guard delete uses. `excluding` is the
    /// bundle being edited, so its own current folder does not count as another shortcut's. Every scanned bundle is
    /// checked, the edited one included; with `targetBundleIdentifier`, so are the target's current location and its
    /// own data folders in `~/Library`.
    func validateDataPath(_ path: String, targetPath: String, excluding bundleURL: URL?, targetBundleIdentifier: String? = nil) -> Result<URL, DataPathGuardError> {
        DataPathGuard.validate(
            dataPath: path, targetPath: targetPath, outputFolder: settings.outputFolder, libraryFolders: settings.allLibraryFolders,
            otherRecordDataPaths: dataPathsInUse(excluding: bundleURL), home: home,
            resolvedTargetPath: targetBundleIdentifier.flatMap { TargetResolver().resolvedPath(targetPath: targetPath, targetBundleIdentifier: $0) },
            targetBundleIdentifier: targetBundleIdentifier, shortcutBundles: library.records.map(\.bundleURL)
        )
    }

    /// What the delete sheet offers for `record`'s data folder: only an existing folder that passes `DataPathGuard`.
    func dataFolderDeletionOption(for record: ShortcutRecord) -> DataFolderDeletionOption {
        if record.config.kind == .webApp {
            return .unavailable(note: "A web app keeps its logins and cookies in web data, not in a data folder.")
        }
        if record.config.kind == .file || record.config.kind == .folder {
            return .unavailable(note: "A file or folder shortcut has no data folder.")
        }
        if record.config.kind == .cli {
            guard let homePath = LauncherEditorPolicy.commandHomePath(for: record.config, home: home) else {
                return .unavailable(note: "This command uses your HOME, so it has no data folder of its own.")
            }
            let folder = URL(fileURLWithPath: homePath, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .unavailable(note: "No HOME folder exists at \(folder.path).")
            }
            let dataRoot = CanonicalPath(ShortcutConfig.dataRoot(home: home).path)
            guard CanonicalPath(folder.path).isInside(dataRoot) else {
                return .unavailable(note: "The HOME folder stays: \(folder.path) is outside App Duplicator's data folder.")
            }
            switch validateDataPath(folder.path, targetPath: record.config.cli?.executablePath ?? "", excluding: record.bundleURL) {
            case .success:
                return .available(folder: folder, outsideDataRoot: false)
            case .failure(let error):
                return .unavailable(note: "The HOME folder stays: \(error.localizedDescription)")
            }
        }
        guard record.config.dataMode != .disabled else {
            return .unavailable(note: "Data mode is Disabled, so this shortcut has no data folder of its own.")
        }
        guard let path = record.config.effectiveDataPath(home: home) else {
            return .unavailable(note: "This shortcut has no data folder.")
        }
        let folder: URL
        switch validateDataPath(path, targetPath: record.config.targetPath, excluding: record.bundleURL, targetBundleIdentifier: record.config.targetBundleIdentifier) {
        case .success(let resolved): folder = resolved
        case .failure(let error): return .unavailable(note: "The data folder stays: \(error.localizedDescription)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .unavailable(note: "No data folder exists at \(folder.path).")
        }
        let dataRoot = CanonicalPath(ShortcutConfig.dataRoot(home: home).path)
        return .available(folder: folder, outsideDataRoot: !CanonicalPath(folder.path).isInside(dataRoot))
    }

    /// The data folder of every scanned shortcut except `bundleURL`.
    private func dataPathsInUse(excluding bundleURL: URL?) -> [String] {
        let excluded = bundleURL?.standardizedFileURL.path
        return library.records
            .filter { $0.bundleURL.standardizedFileURL.path != excluded }
            .compactMap { $0.config.effectiveDataPath(home: home) ?? LauncherEditorPolicy.commandHomePath(for: $0.config, home: home) }
    }

    /// Selects a bundle just written, using the scanned record's URL so the selection matches the sidebar row's tag
    /// (a written URL and a scanned URL can differ in spelling, for example `/var` versus `/private/var`).
    @discardableResult
    private func select(_ written: URL) -> URL {
        let url = library.record(for: written)?.bundleURL ?? written
        selection = url
        return url
    }
}
