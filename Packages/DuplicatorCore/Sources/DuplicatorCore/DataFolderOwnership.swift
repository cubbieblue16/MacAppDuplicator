import Darwin
import Foundation

/// Why an existing data folder cannot be reused.
public enum DataFolderError: Error, Equatable, LocalizedError {
    case notADirectory(String)
    case notOwnedByCurrentUser(String)
    case writableByOthers(String)

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let path): "\(path) is not a folder."
        case .notOwnedByCurrentUser(let path): "\(path) belongs to another user, so it cannot be used as a data folder."
        case .writableByOthers(let path): "\(path) can be changed by other users (group or other write permission), so it cannot be used as a data folder."
        }
    }
}

/// Ownership of a shortcut data folder: who may reuse an existing one (owner and mode, R4) and the marker that proves
/// App Duplicator created it for one shortcut, which erase-on-quit requires (C4).
public enum DataFolderOwnership {
    /// Holds the owning shortcut's bundle identifier; written when the Launcher creates or adopts the folder.
    public static let markerFileName = ".mad-data-owner"

    /// An existing folder is reusable only when the current user owns it and neither group nor others can write to it.
    /// A planted or world-writable folder (`/Users/Shared/x` at mode 0777 made by another account) is refused.
    public static func verifyUsable(_ folder: URL, userID: uid_t = getuid()) throws {
        var info = stat()
        guard stat(folder.path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw DataFolderError.notADirectory(folder.path) }
        guard info.st_uid == userID else { throw DataFolderError.notOwnedByCurrentUser(folder.path) }
        guard info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { throw DataFolderError.writableByOthers(folder.path) }
    }

    /// Reuses `folder` when it exists (after `verifyUsable`) or creates it at mode 0700. Missing parents are created with
    /// default permissions; only the data folder itself is private.
    public static func createOrVerify(_ folder: URL, fileManager: FileManager = .default) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            try verifyUsable(folder)
            return
        }
        try fileManager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try verifyUsable(folder)
    }

    /// The bundle identifier in `folder`'s marker, or nil when there is no regular marker file owned by the current user.
    public static func owner(of folder: URL, userID: uid_t = getuid()) -> String? {
        let marker = folder.appending(path: markerFileName, directoryHint: .notDirectory)
        var info = stat()
        guard lstat(marker.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == userID,
              let data = try? Data(contentsOf: marker), data.count <= 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when `folder` may be claimed for a shortcut now: it is new or empty (a `.DS_Store` aside), inside App
    /// Duplicator's data root, a HOME tree App Duplicator built, or already carries a marker. Anything else is a folder
    /// App Duplicator did not make, and claiming it on launch would let a hand-edited config arm erase-on-quit on it.
    public static func canClaim(_ folder: URL, home: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) else { return true }
        guard isDirectory.boolValue else { return false }
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? ["?"]
        if names.allSatisfy({ $0 == ".DS_Store" }) { return true }
        if names.contains(markerFileName) || names.contains(HomeTreeBuilder.markerFileName) { return true }
        let root = home.appending(path: DataPathRules.dataRootComponents.joined(separator: "/"), directoryHint: .isDirectory).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let candidate = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return candidate.count > root.count && Array(candidate.prefix(root.count)) == root
    }

    /// Writes the marker naming `bundleIdentifier` unless one is already there (an existing marker is never rewritten,
    /// so a folder claimed by another shortcut stays that shortcut's).
    public static func claim(_ folder: URL, bundleIdentifier: String) throws {
        guard owner(of: folder) == nil else { return }
        let marker = folder.appending(path: markerFileName, directoryHint: .notDirectory)
        try Data(bundleIdentifier.utf8).write(to: marker, options: .atomic)
    }

    /// `EraseOnQuitPolicy`'s marker rule: the marker must exist and name exactly `bundleIdentifier`.
    static func refusal(for folder: URL, bundleIdentifier: String) -> EraseOnQuitRefusal? {
        guard let found = owner(of: folder) else { return .ownerMarkerMissing }
        return found == bundleIdentifier ? nil : .ownerMarkerMismatch
    }
}
