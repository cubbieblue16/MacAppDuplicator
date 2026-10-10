import DuplicatorCore
import Foundation
import Observation

/// User preferences (spec §7 Settings). Backed by UserDefaults; every property writes through on set, except a default
/// identity applied by `applyDefaultSigningIdentity`.
@MainActor
@Observable
final class AppSettings {
    /// Nonisolated so non-UI code (`SigningIdentities.defaultIdentity`) and nonisolated tests can read it;
    /// an immutable String is Sendable, so this is safe from any isolation domain.
    nonisolated static let adHocIdentityName = "Ad-hoc"

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
        didSet { if persistsSigningIdentity { defaults.set(signingIdentity, forKey: Key.signingIdentity) } }
    }
    /// False only while `applyDefaultSigningIdentity` sets a computed default, which must not be stored as a choice.
    @ObservationIgnored private var persistsSigningIdentity = true
    /// Symlink list for the separate HOME of new shortcuts (spec §4.3). `AppState.create` copies it into a new
    /// shortcut's config when it differs from `HomeTreeBuilder.defaultSymlinkEntries`; the launcher uses it when that
    /// shortcut's HOME tree is first built. Existing shortcuts keep the list they were created with.
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

    /// Replaces the launch-time default (`init`'s `defaultSigningIdentity`) once the identities have loaded, unless the
    /// user has chosen one. Like the launch-time default it is not written to UserDefaults, so it is worked out again on
    /// every launch until the user picks an identity (final review M15).
    func applyDefaultSigningIdentity(_ identity: String) {
        guard defaults.string(forKey: Key.signingIdentity) == nil else { return }
        persistsSigningIdentity = false
        defer { persistsSigningIdentity = true }
        signingIdentity = identity
    }

    /// Lists the codesigning identities off the main thread, as Settings does, and applies the first Developer ID
    /// identity as the default (`applyDefaultSigningIdentity`). `load` defaults to `security find-identity`.
    func loadDefaultSigningIdentity(using load: @escaping @Sendable () -> [String] = { SigningIdentities.load() }) async {
        let identities = await Task.detached { load() }.value
        applyDefaultSigningIdentity(SigningIdentities.defaultIdentity(from: identities))
    }
}
