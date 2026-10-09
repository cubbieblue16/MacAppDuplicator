import DuplicatorCore
import Foundation
import Observation

/// User preferences (spec §7 Settings). Backed by UserDefaults; every property writes through on set.
@MainActor
@Observable
final class AppSettings {
    static let adHocIdentityName = "Ad-hoc"

    private enum Key {
        static let outputFolder = "outputFolderPath"
        static let libraryFolders = "libraryFolderPaths"
        static let signingIdentity = "signingIdentity"
        static let homeSymlinkEntries = "homeSymlinkEntries"
    }

    static func defaultOutputFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Applications/App Duplicator", directoryHint: .isDirectory)
    }

    private let defaults: UserDefaults

    var outputFolder: URL {
        didSet { defaults.set(outputFolder.path, forKey: Key.outputFolder) }
    }
    /// User-added folders scanned in addition to `outputFolder`.
    var libraryFolders: [URL] {
        didSet { defaults.set(libraryFolders.map(\.path), forKey: Key.libraryFolders) }
    }
    /// Display name of the codesigning identity, or `adHocIdentityName`.
    var signingIdentity: String {
        didSet { defaults.set(signingIdentity, forKey: Key.signingIdentity) }
    }
    /// Symlink list applied to new HOME-override shortcuts (spec §4.3). Stored per shortcut at creation time.
    var homeSymlinkEntries: [String] {
        didSet { defaults.set(homeSymlinkEntries, forKey: Key.homeSymlinkEntries) }
    }

    /// `Signer` argument: nil for ad hoc.
    var signerIdentity: String? {
        signingIdentity == Self.adHocIdentityName ? nil : signingIdentity
    }

    /// Output folder first, then user folders, without duplicates.
    var allLibraryFolders: [URL] {
        var seen = Set<String>()
        return ([outputFolder] + libraryFolders).filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    init(defaults: UserDefaults = .standard, defaultSigningIdentity: String) {
        self.defaults = defaults
        outputFolder = defaults.string(forKey: Key.outputFolder).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultOutputFolder()
        libraryFolders = (defaults.stringArray(forKey: Key.libraryFolders) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        signingIdentity = defaults.string(forKey: Key.signingIdentity) ?? defaultSigningIdentity
        homeSymlinkEntries = defaults.stringArray(forKey: Key.homeSymlinkEntries) ?? HomeTreeBuilder.defaultSymlinkEntries
    }
}
