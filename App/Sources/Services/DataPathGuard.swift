import DuplicatorCore
import Foundation

/// Why a folder cannot be a shortcut's data folder, or be moved to the Trash as one.
enum DataPathGuardError: Error, Equatable, LocalizedError {
    case empty
    case relative(String)
    case protectedLocation(String)
    case dataRoot(String)
    case overlapsTarget(String)
    case overlapsLibraryFolder(String)
    case usedByAnotherShortcut(String)

    var errorDescription: String? {
        switch self {
        case .empty: "No data folder is set."
        case .relative(let path): "The data folder must be an absolute path, not “\(path)”."
        case .protectedLocation(let path): "\(path) is a system or home folder, not a shortcut data folder."
        case .dataRoot(let path): "\(path) holds the data of every shortcut; use a folder inside it."
        case .overlapsTarget(let path): "\(path) is, contains or is inside the target app."
        case .overlapsLibraryFolder(let path): "\(path) is or contains a shortcut library folder."
        case .usedByAnotherShortcut(let path): "\(path) is, contains or is inside another shortcut's data folder."
        }
    }
}

/// The one check for a shortcut data folder, run before a data folder is moved to the Trash and when the user picks
/// one (final review I1; spec §4.3 keeps destructive data operations to the shortcut's own folder). Paths are
/// compared as `CanonicalPath`s, so a symlink is judged by the folder it points to.
enum DataPathGuard {
    /// Folders directly inside home that are never a data folder.
    static let protectedHomeFolders = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Library"]

    /// - Parameters:
    ///   - targetPath: the shortcut's target app; empty skips the target check.
    ///   - outputFolder, libraryFolders: every folder the library scans.
    ///   - otherRecordDataPaths: the data folders of every other shortcut.
    /// - Returns: the resolved folder (symlinks followed) on success; act on this URL, not on `dataPath`.
    static func validate(dataPath: String, targetPath: String, outputFolder: URL, libraryFolders: [URL], otherRecordDataPaths: [String], home: URL) -> Result<URL, DataPathGuardError> {
        guard !dataPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.empty) }
        guard dataPath.hasPrefix("/") else { return .failure(.relative(dataPath)) }
        let candidate = CanonicalPath(dataPath)
        let shown = candidate.path

        let homePath = CanonicalPath(home.path)
        let library = homePath.appending("Library")
        let isProtected = candidate.depth <= 1
            || candidate.isSame(as: homePath) || homePath.isInside(candidate)
            || candidate.isSame(as: library) || (candidate.isInside(library) && candidate.depth == library.depth + 1)
            || protectedHomeFolders.contains { candidate.isSame(as: homePath.appending($0)) }
        if isProtected { return .failure(.protectedLocation(shown)) }

        if candidate.isSame(as: CanonicalPath(ShortcutConfig.dataRoot(home: home).path)) { return .failure(.dataRoot(shown)) }

        if targetPath.hasPrefix("/"), candidate.overlaps(CanonicalPath(targetPath)) { return .failure(.overlapsTarget(shown)) }

        for folder in [outputFolder] + libraryFolders {
            let scanned = CanonicalPath(folder.path)
            if candidate.isSame(as: scanned) || scanned.isInside(candidate) { return .failure(.overlapsLibraryFolder(shown)) }
        }

        for other in otherRecordDataPaths where other.hasPrefix("/") {
            if candidate.overlaps(CanonicalPath(other)) { return .failure(.usedByAnotherShortcut(shown)) }
        }

        return .success(candidate.url)
    }
}
