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
    case overlapsShortcut(String)
    case targetAppData(String)
    case protectedSubtree(String)
    case needsOwnerMarker(String)

    var errorDescription: String? {
        switch self {
        case .empty: "No data folder is set."
        case .relative(let path): "The data folder must be an absolute path, not “\(path)”."
        case .protectedLocation(let path): "\(path) is a system, volume or home folder, not a shortcut data folder."
        case .dataRoot(let path): "\(path) holds the data of every shortcut; use a folder inside it."
        case .overlapsTarget(let path): "\(path) is, contains or is inside the target app."
        case .overlapsLibraryFolder(let path): "\(path) is or contains a shortcut library folder."
        case .usedByAnotherShortcut(let path): "\(path) is, contains or is inside another shortcut's data folder."
        case .overlapsShortcut(let path): "\(path) is, contains or is inside a shortcut bundle."
        case .protectedSubtree(let name): "\(name) is a synced, system or personal folder (iCloud Drive, cloud storage, app containers, other apps' data, or a top-level folder in Documents, Desktop or Downloads), not a shortcut data folder."
        case .needsOwnerMarker(let path): "\(path) already exists and App Duplicator did not create it (it has no \(DataFolderOwnership.markerFileName) marker); pick a new or empty folder."
        case .targetAppData(let path): "\(path) is or is inside the target app's own data in ~/Library (a folder named after the app or its bundle identifier); App Duplicator never uses or trashes it."
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
    ///   - resolvedTargetPath: where `TargetResolver` finds the target now; checked like `targetPath` (re-review Minor 4).
    ///   - targetBundleIdentifier: with the target's file names, marks `~/Library/<folder>/<name or bundle id>` as the
    ///     target's own data (re-review Minor 1).
    ///   - shortcutBundles: every scanned shortcut bundle; a folder that is, contains or is inside one is refused
    ///     (re-review Minor 2).
    /// - Returns: the resolved folder (symlinks followed) on success; act on this URL, not on `dataPath`. After the
    ///   Phase 2 checks it also refuses shallow folders: every direct child of home, and anything at depth 2 or less
    ///   outside home (`/Users/Shared`, `/opt/homebrew`, `/Volumes/<volume>`).
    static func validate(
        dataPath: String, targetPath: String, outputFolder: URL, libraryFolders: [URL], otherRecordDataPaths: [String], home: URL,
        resolvedTargetPath: String? = nil, targetBundleIdentifier: String? = nil, shortcutBundles: [URL] = []
    ) -> Result<URL, DataPathGuardError> {
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

        let dataRoot = CanonicalPath(ShortcutConfig.dataRoot(home: home).path)
        if candidate.isSame(as: dataRoot) { return .failure(.dataRoot(shown)) }

        if targetPath.hasPrefix("/"), candidate.overlaps(CanonicalPath(targetPath)) { return .failure(.overlapsTarget(shown)) }

        for folder in [outputFolder] + libraryFolders {
            let scanned = CanonicalPath(folder.path)
            if candidate.isSame(as: scanned) || scanned.isInside(candidate) { return .failure(.overlapsLibraryFolder(shown)) }
        }

        for other in otherRecordDataPaths where other.hasPrefix("/") {
            if candidate.overlaps(CanonicalPath(other)) { return .failure(.usedByAnotherShortcut(shown)) }
        }

        // Phase 3 widening (re-review Minors 1, 2 and 4) runs after every Phase 2 check, so those keep their messages.
        if let resolvedTargetPath, resolvedTargetPath.hasPrefix("/"), candidate.overlaps(CanonicalPath(resolvedTargetPath)) {
            return .failure(.overlapsTarget(shown))
        }
        if shortcutBundles.contains(where: { candidate.overlaps(CanonicalPath($0.path)) }) { return .failure(.overlapsShortcut(shown)) }
        // `~/Library/<folder>/<target name or bundle id>` is the target's own data. A folder inside the data root is
        // always App Duplicator's, even for a shortcut of App Duplicator itself.
        if !candidate.isInside(dataRoot), candidate.isInside(library), let owner = candidate.foldedComponent(at: library.depth + 1),
           targetDataFolderNames(targetPath: targetPath, resolvedTargetPath: resolvedTargetPath, targetBundleIdentifier: targetBundleIdentifier).contains(owner) {
            return .failure(.targetAppData(shown))
        }
        // A folder this shallow is a shared location (`~/Developer`, `~/.ssh`, `/Users/Shared`, `/opt/homebrew`,
        // `/Volumes/<volume>`, …), never one shortcut's own folder.
        let isShallow = candidate.isInside(homePath) ? candidate.depth == homePath.depth + 1 : candidate.depth <= 2
        if isShallow { return .failure(.protectedLocation(shown)) }

        // The shared location rules (`DataPathRules`, also run by madctl and the helper before it erases): synced and
        // container subtrees, other apps' Application Support, and top-level children of Documents, Desktop and Downloads.
        // Outside home the checks above are the whole story.
        if candidate.isInside(homePath) {
            let components = candidate.path.split(separator: "/").map(String.init)
            let homeComponents = homePath.path.split(separator: "/").map(String.init)
            if case .protectedSubtree(let name)? = DataPathRules.refusal(components, home: homeComponents) {
                return .failure(.protectedSubtree(name))
            }
            // `~/Documents/<x>/<y>` is the user's own space: an existing folder there is a data folder only when App
            // Duplicator marked it. A folder that does not exist yet is created and marked at the first launch.
            if DataPathRules.needsOwnerMarker(components, home: homeComponents),
               FileManager.default.fileExists(atPath: candidate.path), DataFolderOwnership.owner(of: candidate.url) == nil {
                return .failure(.needsOwnerMarker(shown))
            }
        }

        return .success(candidate.url)
    }

    /// The folded names the target's own data folders go by in `~/Library/<folder>/`: its file name without `.app`
    /// (stored and resolved) and its bundle identifier.
    private static func targetDataFolderNames(targetPath: String, resolvedTargetPath: String?, targetBundleIdentifier: String?) -> Set<String> {
        let fileNames = [targetPath, resolvedTargetPath ?? ""].filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        return Set((fileNames + [targetBundleIdentifier ?? ""]).filter { !$0.isEmpty }.map(CanonicalPath.fold))
    }
}
