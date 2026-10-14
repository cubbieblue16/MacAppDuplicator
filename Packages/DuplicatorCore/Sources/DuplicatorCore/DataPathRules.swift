import Foundation

/// The location rules for a shortcut data folder, shared by every place that accepts or erases one: the app's pick-time
/// guard (`DataPathGuard`), madctl's `--data-path`, and the helper's `EraseOnQuitPolicy`. They work on already resolved
/// path components and never touch the file system, so all three apply exactly the same shape rules.
public enum DataPathRules {
    /// Folders directly inside the home folder, named in the refusal. Every other direct child is refused as well.
    public static let protectedFolders = ["Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public"]
    /// `<home>/Library/Application Support/App Duplicator`, the parent of every default data folder
    /// (`ShortcutConfig.defaultDataPath(forSlug:home:)`).
    static let dataRootComponents = ["Library", "Application Support", "App Duplicator"]
    /// The shortest path accepted, counted in components below `/`.
    static let minimumComponentCount = 4
    /// `~/Library` subtrees that belong to the system, to cloud sync or to other apps; nothing inside is a data folder.
    static let protectedLibrarySubtrees = ["Mobile Documents", "CloudStorage", "Containers", "Group Containers"]

    /// The location rules on already resolved components. `nil` means the folder is an acceptable data folder as far as
    /// its location goes; `needsOwnerMarker` says whether it must also carry the ownership marker.
    public static func refusal(_ path: [String], home: [String]) -> EraseOnQuitRefusal? {
        let folded = path.map(fold)
        let foldedHome = home.map(fold)
        guard folded.starts(with: foldedHome) else {
            return .outsideHome
        }
        let relative = Array(folded.dropFirst(foldedHome.count))
        if relative.isEmpty {
            return .home
        }
        if relative.count == 1 {
            if let named = protectedFolders.first(where: { fold($0) == relative[0] }) {
                return .protectedFolder(named)
            }
            return .homeChild
        }
        if relative.count == 2, relative[0] == fold("Library") {
            return .libraryChild
        }
        if relative == dataRootComponents.map(fold) {
            return .dataRoot
        }
        if relative[0] == fold("Library") {
            if let subtree = protectedLibrarySubtrees.first(where: { fold($0) == relative[1] }) {
                return .protectedSubtree("~/Library/\(subtree)")
            }
            // Other apps' data lives in Application Support; only App Duplicator's own data root is open.
            if relative[1] == fold("Application Support"),
               !(relative.starts(with: dataRootComponents.map(fold)) && relative.count > dataRootComponents.count) {
                return .protectedSubtree("~/Library/Application Support")
            }
        }
        // A project folder in Documents, Desktop or Downloads is the user's own; only something deeper is ours.
        if relative.count == 2, let top = ["Documents", "Desktop", "Downloads"].first(where: { fold($0) == relative[0] }) {
            return .protectedSubtree("~/\(top)")
        }
        if path.count < minimumComponentCount {
            return .tooShallow
        }
        return nil
    }

    /// True for a folder that passes `refusal` but sits where the user keeps their own files (`~/Documents/<x>/<y>`):
    /// it counts as a data folder only when it carries the ownership marker.
    public static func needsOwnerMarker(_ path: [String], home: [String]) -> Bool {
        let folded = path.map(fold)
        let foldedHome = home.map(fold)
        guard folded.starts(with: foldedHome) else { return false }
        let relative = folded.dropFirst(foldedHome.count)
        return relative.count >= 3 && relative.first == fold("Documents")
    }

    /// APFS compares names case-insensitively after Unicode normalisation, so the rules do too.
    static func fold(_ component: String) -> String {
        component.precomposedStringWithCanonicalMapping.lowercased()
    }
}
