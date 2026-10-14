import CompatProfiles
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
        static let profilesURL = "profilesURLString"
        static let installToken = ShortcutConfig.installTokenInfoPlistKey
    }

    static func defaultOutputFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Applications/App Duplicator", directoryHint: .isDirectory)
    }

    private let defaults: UserDefaults

    /// Stamped into every bundle this install writes (`MADInstallToken`) so the library can tell its own bundles from
    /// received or planted ones before it regenerates and signs anything (security C3). Not a secret: it only
    /// distinguishes this install's bundles. 32 random bytes as hex, generated once and kept for the install's life.
    let installToken: String

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
    /// Settings → Profiles. Stored only when it differs from `ProfilesConstants.defaultURLString`, so a later default
    /// reaches users who never changed it.
    var profilesURLString: String {
        didSet {
            if profilesURLString == ProfilesConstants.defaultURLString {
                defaults.removeObject(forKey: Key.profilesURL)
            } else {
                defaults.set(profilesURLString, forKey: Key.profilesURL)
            }
        }
    }

    /// `Signer` argument: nil for ad hoc.
    var signerIdentity: String? {
        signingIdentity == Self.adHocIdentityName ? nil : signingIdentity
    }

    /// The signature a bundle signed with the configured identity reads back as (`CodeSignature.of`): the identity's
    /// display name, or ad hoc. A bundle without an install token is only trusted when it matches (security C3).
    var expectedSignature: CodeSignature {
        signerIdentity.map(CodeSignature.identity) ?? .adHoc
    }

    /// What the library scanner trusts as this install's own bundles (security C3).
    var scanTrust: ScanTrust {
        ScanTrust(installToken: installToken, expectedSignature: expectedSignature)
    }

    /// `profilesURLString` without surrounding whitespace, when it is an allowed profiles address; nil otherwise.
    var profilesURL: URL? {
        let trimmed = profilesURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ProfilesFetchPolicy.isAllowedSource(url) else { return nil }
        return url
    }

    /// Output folder first, then user folders, without duplicates.
    var allLibraryFolders: [URL] {
        var seen = Set<String>()
        return ([outputFolder] + libraryFolders).filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    init(defaults: UserDefaults = .standard, defaultSigningIdentity: String) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: Key.installToken), Self.isWellFormedInstallToken(stored) {
            installToken = stored
        } else {
            installToken = Self.makeInstallToken()
            defaults.set(installToken, forKey: Key.installToken)
        }
        outputFolder = defaults.string(forKey: Key.outputFolder).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultOutputFolder()
        libraryFolders = (defaults.stringArray(forKey: Key.libraryFolders) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        signingIdentity = defaults.string(forKey: Key.signingIdentity) ?? defaultSigningIdentity
        homeSymlinkEntries = defaults.stringArray(forKey: Key.homeSymlinkEntries) ?? HomeTreeBuilder.defaultSymlinkEntries
        profilesURLString = defaults.string(forKey: Key.profilesURL) ?? ProfilesConstants.defaultURLString
    }

    /// 32 bytes from the system's cryptographically secure generator, as 64 lowercase hex digits.
    nonisolated static func makeInstallToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    /// A stored token is reused only when it looks like one `makeInstallToken` made; anything else is replaced.
    nonisolated static func isWellFormedInstallToken(_ token: String) -> Bool {
        token.count == 64 && token.allSatisfy { $0.isHexDigit && !$0.isUppercase }
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
