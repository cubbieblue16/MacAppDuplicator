import Darwin
import Foundation

/// Why `EraseOnQuitPolicy` refused a data folder. The helper logs `logReason` and erases nothing (spec §4.3).
public enum EraseOnQuitRefusal: Error, Equatable {
    case malformedPath
    case missing
    case unreadable(errno: Int32)
    case symbolicLink
    case notDirectory
    case homeUnresolvable
    case outsideHome
    case home
    case homeChild
    case protectedFolder(String)
    case libraryChild
    case dataRoot
    case tooShallow
    case protectedSubtree(String)
    case ownerMarkerMissing
    case ownerMarkerMismatch

    public var logReason: String {
        switch self {
        case .malformedPath: "the path is not a normalised absolute path"
        case .missing: "the folder does not exist"
        case .unreadable(let code): "the path cannot be inspected (errno \(code))"
        case .symbolicLink: "the path is a symbolic link"
        case .notDirectory: "the path is not a folder"
        case .homeUnresolvable: "the home folder cannot be resolved"
        case .outsideHome: "the folder is outside the home folder"
        case .home: "the folder is the home folder"
        case .homeChild: "the folder is directly inside the home folder"
        case .protectedFolder(let name): "the folder is ~/\(name)"
        case .libraryChild: "the folder is directly inside ~/Library"
        case .dataRoot: "the folder is the App Duplicator data root"
        case .tooShallow: "the folder is fewer than four levels below /"
        case .protectedSubtree(let name): "the folder is \(name) or inside it, where other apps and the user keep their files"
        case .ownerMarkerMissing: "the folder has no \(DataFolderOwnership.markerFileName) ownership marker, so App Duplicator did not create it"
        case .ownerMarkerMismatch: "the folder's \(DataFolderOwnership.markerFileName) ownership marker names a different shortcut"
        }
    }
}

/// The hard guard in front of erase-on-quit (spec §4.3). It trusts neither the config nor the caller: the folder must
/// exist, must be a real folder rather than a symbolic link, and, after every symbolic link above it is resolved, must
/// sit at least two levels inside the home folder, away from `~/Library`'s direct children and the App Duplicator data
/// root. Callers erase the URL this returns, never the configured string.
public enum EraseOnQuitPolicy {
    /// Folders directly inside the home folder, named in the refusal (`DataPathRules.protectedFolders`).
    public static var protectedFolders: [String] { DataPathRules.protectedFolders }

    /// - Parameter bundleIdentifier: the shortcut's own bundle identifier; the folder's `.mad-data-owner` marker must name
    ///   exactly it, so a folder App Duplicator did not create for this shortcut is never emptied.
    public static func check(dataPath: String, home: URL, bundleIdentifier: String) -> Result<URL, EraseOnQuitRefusal> {
        let components = dataPath.split(separator: "/").map(String.init)
        guard dataPath.hasPrefix("/"), let name = components.last, !components.contains(where: { $0 == "." || $0 == ".." }) else {
            return .failure(.malformedPath)
        }
        // No trailing slash: `lstat("<link>/")` would follow the link.
        let path = "/" + components.joined(separator: "/")
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let code = errno
            return .failure(code == ENOENT ? .missing : .unreadable(errno: code))
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            break
        case S_IFLNK:
            return .failure(.symbolicLink)
        default:
            return .failure(.notDirectory)
        }
        guard let parent = resolvedComponents("/" + components.dropLast().joined(separator: "/")) else {
            return .failure(.unreadable(errno: errno))
        }
        guard let homeComponents = resolvedComponents(home.path) else {
            return .failure(.homeUnresolvable)
        }
        let resolved = parent + [name]
        if let refusal = checkShape(resolved, home: homeComponents) {
            return .failure(refusal)
        }
        let folder = URL(fileURLWithPath: "/" + resolved.joined(separator: "/"), isDirectory: true)
        if let refusal = DataFolderOwnership.refusal(for: folder, bundleIdentifier: bundleIdentifier) {
            return .failure(refusal)
        }
        return .success(folder)
    }

    /// The location rules on already resolved components; no file-system access. `nil` means the folder may be emptied.
    static func checkShape(_ path: [String], home: [String]) -> EraseOnQuitRefusal? {
        DataPathRules.refusal(path, home: home)
    }

    /// `realpath(3)` split into components, or `nil` with `errno` set.
    private static func resolvedComponents(_ path: String) -> [String]? {
        guard let pointer = realpath(path, nil) else {
            return nil
        }
        defer { free(pointer) }
        return String(cString: pointer).split(separator: "/").map(String.init)
    }
}
