import DuplicatorCore
import Foundation
import Observation

/// The in-memory library: scan results for all library folders, a folder watcher, and the running monitor (spec §7).
@MainActor
@Observable
final class ShortcutLibrary {
    private(set) var records: [ShortcutRecord] = []
    private(set) var warnings: [String] = []
    private(set) var isScanning = false

    let settings: AppSettings
    let monitor: RunningShortcutMonitor
    private let scanner: LibraryScanner
    private var watcher: FolderWatcher?
    private var watchedFolders: [URL] = []

    init(settings: AppSettings, scanner: LibraryScanner = LibraryScanner(), monitor: RunningShortcutMonitor? = nil) {
        self.settings = settings
        self.scanner = scanner
        self.monitor = monitor ?? RunningShortcutMonitor()
    }

    /// Starts watching and performs the first scan. Call again after the folder list changes.
    func start() {
        let folders = settings.allLibraryFolders
        if watcher == nil || folders != watchedFolders {
            watcher?.stop()
            watchedFolders = folders
            try? FileManager.default.createDirectory(at: settings.outputFolder, withIntermediateDirectories: true)
            watcher = FolderWatcher(folders: folders) { [weak self] in
                Task { await self?.rescan() }
            }
            watcher?.start()
        }
        monitor.start()
        Task { await rescan() }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        watchedFolders = []
        monitor.stop()
    }

    func rescan() async {
        isScanning = true
        defer { isScanning = false }
        let folders = settings.allLibraryFolders
        let scanner = scanner
        let result = await Task.detached(priority: .userInitiated) { scanner.scan(folders: folders) }.value
        records = result.records
        warnings = result.warnings
        await monitor.refresh()
    }

    func isRunning(_ record: ShortcutRecord) -> Bool { monitor.isRunning(bundleURL: record.bundleURL) }
    func records(ofKind kind: ShortcutKind) -> [ShortcutRecord] { records.filter { $0.config.kind == kind } }
    func record(for bundleURL: URL) -> ShortcutRecord? {
        let path = bundleURL.standardizedFileURL.path
        return records.first { $0.bundleURL.standardizedFileURL.path == path }
    }
    var recordsNeedingRebuild: [ShortcutRecord] { records.filter(\.needsRebuild) }
}
