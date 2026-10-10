import AppKit
import Foundation
import os

/// The one "open logs folder" action, shared by Settings and Diagnostics. The launcher creates
/// `~/Library/Logs/App Duplicator` on its first log line, so the folder can be missing; it is created here (an allowed
/// write, plan GC-15) so the Finder window opens either way.
enum LogFolderOpener {
    private static let logger = Logger(subsystem: "com.mikekuta.MacAppDuplicator", category: "LogFolderOpener")

    /// The log folder, created if missing; its parent when it cannot be created.
    static func folderToOpen(reader: LogReader = LogReader(), fileManager: FileManager = .default) -> URL {
        let folder = reader.logFolder()
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            logger.error("Could not create the log folder \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return folder.deletingLastPathComponent()
        }
    }

    @MainActor
    static func open(reader: LogReader = LogReader()) {
        NSWorkspace.shared.open(folderToOpen(reader: reader))
    }
}
