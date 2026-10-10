import DuplicatorCore
import Foundation
import Observation
import os

/// What `ShortcutLibrary` needs from a scanner. `LibraryScanner` is the real one; tests inject a gated stub (final review M7).
protocol ShortcutScanning: Sendable {
    func scan(folders: [URL]) -> ScanResult
}

extension LibraryScanner: ShortcutScanning {}

/// The in-memory library: scan results for all library folders, a folder watcher, and the running monitor (spec §7).
@MainActor
@Observable
final class ShortcutLibrary {
    private(set) var records: [ShortcutRecord] = []
    private(set) var warnings: [String] = []
    private(set) var isScanning = false
    /// Bumped by every `rescan()`; only the scan holding the current value may publish (final review M7).
    @ObservationIgnored private var scanGeneration: UInt64 = 0

    let settings: AppSettings
    let monitor: RunningShortcutMonitor
    private let scanner: any ShortcutScanning
    /// Internal (not private) so tests can check that a restart replaces the watcher instead of adding one.
    private(set) var watcher: FolderWatcher?

    private static let logger = Logger(subsystem: "com.mikekuta.MacAppDuplicator", category: "ShortcutLibrary")

    init(settings: AppSettings, scanner: any ShortcutScanning = LibraryScanner(), monitor: RunningShortcutMonitor? = nil) {
        self.settings = settings
        self.scanner = scanner
        self.monitor = monitor ?? RunningShortcutMonitor()
    }

    /// Watches the current library folders and rescans. The scene calls it at launch and again whenever
    /// `settings.allLibraryFolders` changes (final review I4); the previous watcher is always stopped first, so a
    /// removed folder stops being watched, a new one starts, and no folder is ever watched twice.
    func start() {
        watcher?.stop()
        do {
            try FileManager.default.createDirectory(at: settings.outputFolder, withIntermediateDirectories: true)
        } catch {
            // Not fatal: the scan skips a missing folder and the watcher skips a folder it cannot open.
            Self.logger.error("Could not create the output folder \(self.settings.outputFolder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        let watcher = FolderWatcher(folders: settings.allLibraryFolders) { [weak self] in
            Task { await self?.rescan() }
        }
        watcher.start()
        self.watcher = watcher
        monitor.start()
        Task { await rescan() }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        monitor.stop()
    }

    func rescan() async {
        // Rescans overlap (FolderWatcher, Refresh, Settings changes) and can finish out of order. Each takes a
        // generation: a stale result is dropped, and only the newest scan clears `isScanning` (final review M7).
        scanGeneration &+= 1
        let generation = scanGeneration
        isScanning = true
        let folders = settings.allLibraryFolders
        let scanner = scanner
        let result = await Task.detached(priority: .userInitiated) { scanner.scan(folders: folders) }.value
        guard generation == scanGeneration else { return }
        records = result.records
        warnings = result.warnings
        await monitor.refresh()
        if generation == scanGeneration { isScanning = false }
    }

    func isRunning(_ record: ShortcutRecord) -> Bool { monitor.isRunning(bundleURL: record.bundleURL) }
    func records(ofKind kind: ShortcutKind) -> [ShortcutRecord] { records.filter { $0.config.kind == kind } }
    func record(for bundleURL: URL) -> ShortcutRecord? {
        let path = bundleURL.standardizedFileURL.path
        return records.first { $0.bundleURL.standardizedFileURL.path == path }
    }
    var recordsNeedingRebuild: [ShortcutRecord] { records.filter(\.needsRebuild) }
}
