import Foundation

/// Materialises the HOME-override tree (spec §4.3).
///
/// The first call on an empty directory builds the tree there. A directory that is not empty on first use gets a
/// subfolder named after the real user (`NSUserName()`), and the tree is built inside it. A marker file makes later
/// calls no-ops. Nothing is written outside `path`; symlinks are created only for entries that exist in the real home.
public struct HomeTreeBuilder {
    /// Entries symlinked from the real home when they exist there (spec §4.3).
    public static let defaultSymlinkEntries: [String] = [
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public",
        ".ssh", ".gitconfig", ".zshrc", ".zshenv", ".zprofile", ".zsh", ".oh-my-zsh",
        ".bashrc", ".bash_profile", ".profile",
        ".config", ".docker", ".npmrc", ".nvm", ".cargo", ".rustup", ".local", ".gnupg",
    ]

    /// Real, empty directories created under `Library/` (spec §4.3).
    public static let libraryDirectories: [String] = [
        "Application Support", "Preferences", "Caches", "Containers", "Group Containers",
        "Saved Application State", "WebKit", "HTTPStorages", "Cookies", "Logs", "Keychains",
    ]

    /// Written last; its presence means the tree is complete.
    public static let markerFileName = ".mad-home-tree"

    let fileManager: FileManager
    let realHome: URL
    let symlinkEntries: [String]

    public init(fileManager: FileManager = .default, realHome: URL, symlinkEntries: [String] = HomeTreeBuilder.defaultSymlinkEntries) {
        self.fileManager = fileManager
        self.realHome = realHome
        self.symlinkEntries = symlinkEntries
    }

    /// Returns the effective HOME: `path`, or `path/<NSUserName()>` when `path` was not empty on first use.
    public func materialize(at path: URL) throws -> URL {
        let root = path.standardizedFileURL
        // An existing folder is reused only when this user owns it and nobody else can write to it (R4): a planted
        // `.mad-home-tree` in another account's folder is not trusted.
        try DataFolderOwnership.createOrVerify(root, fileManager: fileManager)
        if isComplete(root) {
            return root
        }
        let home: URL
        if try isEmpty(root) {
            home = root
        } else {
            home = root.appending(path: NSUserName(), directoryHint: .isDirectory)
            try DataFolderOwnership.verifyUsable(home)
            if isComplete(home) {
                return home
            }
            try DataFolderOwnership.createOrVerify(home, fileManager: fileManager)
        }
        try build(at: home)
        return home
    }

    private func isComplete(_ directory: URL) -> Bool {
        fileManager.fileExists(atPath: directory.appending(path: Self.markerFileName).path)
    }

    private func isEmpty(_ directory: URL) throws -> Bool {
        try fileManager.contentsOfDirectory(atPath: directory.path).allSatisfy { $0 == ".DS_Store" }
    }

    private func build(at home: URL) throws {
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        for name in Self.libraryDirectories {
            try fileManager.createDirectory(at: library.appending(path: name, directoryHint: .isDirectory), withIntermediateDirectories: true)
        }
        for entry in symlinkEntries where Self.isPlainEntryName(entry) {
            let source = realHome.appending(path: entry)
            let destination = home.appending(path: entry)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            // attributesOfItem does not follow a final symlink, so an existing (even dangling) link counts as present.
            guard (try? fileManager.attributesOfItem(atPath: destination.path)) == nil else { continue }
            try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
        }
        try Data().write(to: home.appending(path: Self.markerFileName))
    }

    /// Single path component only, so an entry can never point the tree outside `path`. Public so the app can
    /// validate the Settings list with the same rule.
    public static func isPlainEntryName(_ entry: String) -> Bool {
        !entry.isEmpty && entry != "." && entry != ".." && !entry.contains("/")
    }
}
