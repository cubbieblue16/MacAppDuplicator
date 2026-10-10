import AppKit
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
    private let launcherBinary: URL

    var selection: URL?
    var isWizardPresented = false
    var wizardPrefillTarget: URL?
    var pendingError: AppError?

    init(settings: AppSettings, library: ShortcutLibrary, launcherBinary: URL) {
        self.settings = settings
        self.library = library
        self.launcherBinary = launcherBinary
    }

    var builder: ShortcutBuilder {
        ShortcutBuilder(launcherBinary: launcherBinary, signingIdentity: settings.signerIdentity)
    }

    var selectedRecord: ShortcutRecord? {
        selection.flatMap { library.record(for: $0) }
    }

    func present(_ error: Error, context: String) {
        pendingError = AppError(context: context, message: error.localizedDescription)
    }

    /// Creates in the output folder, rescans, selects the new bundle. Returns nil (and sets `pendingError`) on failure.
    func create(config: ShortcutConfig) async -> URL? {
        do {
            let url = try builder.create(config: config, in: settings.outputFolder)
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

    /// Rewrites every record whose engine version is stale. Returns how many were rebuilt; stops at the first error.
    func rebuildAll() async -> Int {
        var count = 0
        for record in library.recordsNeedingRebuild {
            do {
                _ = try builder.regenerate(record: record, config: record.config)
                count += 1
            } catch {
                present(error, context: "Could not rebuild \(record.name)")
                break
            }
        }
        await library.rescan()
        return count
    }

    func duplicate(_ record: ShortcutRecord, newName: String) async {
        do {
            let url = try builder.duplicate(record: record, newName: newName, in: record.bundleURL.deletingLastPathComponent())
            await library.rescan()
            select(url)
        } catch {
            present(error, context: "Could not duplicate shortcut")
        }
    }

    func export(_ record: ShortcutRecord, to destination: URL) async -> Bool {
        do {
            _ = try builder.export(record: record, to: destination)
            return true
        } catch {
            present(error, context: "Could not export shortcut")
            return false
        }
    }

    /// Moves the shortcut (and, with `removeData`, its data folder) to the Trash. Delete is offered only from the
    /// selected shortcut's editor, and a selection made by an earlier duplicate or rename must not survive into the
    /// next detail view, so the selection is always cleared. Returns the Trash locations (empty on failure).
    @discardableResult
    func delete(_ record: ShortcutRecord, removeData: Bool) async -> [URL] {
        do {
            let trashed = try builder.delete(
                record: record, removeData: removeData,
                libraryFolders: settings.allLibraryFolders, otherRecordDataPaths: dataPathsInUse(excluding: record.bundleURL)
            )
            selection = nil
            await library.rescan()
            return trashed
        } catch {
            present(error, context: "Could not delete shortcut")
            return []
        }
    }

    /// Checks a data folder the user picked (wizard or editor) with the same guard delete uses. `excluding` is the
    /// bundle being edited, so its own current folder does not count as another shortcut's.
    func validateDataPath(_ path: String, targetPath: String, excluding bundleURL: URL?) -> Result<URL, DataPathGuardError> {
        DataPathGuard.validate(
            dataPath: path, targetPath: targetPath, outputFolder: settings.outputFolder, libraryFolders: settings.allLibraryFolders,
            otherRecordDataPaths: dataPathsInUse(excluding: bundleURL), home: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    /// What the delete sheet offers for `record`'s data folder: only an existing folder that passes `DataPathGuard`.
    func dataFolderDeletionOption(for record: ShortcutRecord) -> DataFolderDeletionOption {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard record.config.dataMode != .disabled else {
            return .unavailable(note: "Data mode is Disabled, so this shortcut has no data folder of its own.")
        }
        guard let path = record.config.effectiveDataPath(home: home) else {
            return .unavailable(note: "This shortcut has no data folder.")
        }
        let folder: URL
        switch validateDataPath(path, targetPath: record.config.targetPath, excluding: record.bundleURL) {
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        let excluded = bundleURL?.standardizedFileURL.path
        return library.records
            .filter { $0.bundleURL.standardizedFileURL.path != excluded }
            .compactMap { $0.config.effectiveDataPath(home: home) }
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
