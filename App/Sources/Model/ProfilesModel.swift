import CompatProfiles
import DuplicatorCore
import Foundation
import Observation

/// The compatibility profiles the app uses (spec §8): the bundled seed, or the cached remote copy when it is strictly
/// newer. Check Profile Updates is the only thing that fetches, and only when the user chooses it (spec §2).
@MainActor
@Observable
final class ProfilesModel {
    private(set) var catalog: ProfileCatalog
    private(set) var isChecking = false
    /// The result of the last Check Profile Updates, shown in Settings → Profiles.
    private(set) var statusMessage: String?
    let bundledURL: URL?
    let cacheURL: URL
    private let fetcher: any ProfilesFetching

    init(catalog: ProfileCatalog = .empty, bundledURL: URL?, cacheURL: URL, fetcher: any ProfilesFetching) {
        self.catalog = catalog
        self.bundledURL = bundledURL
        self.cacheURL = cacheURL
        self.fetcher = fetcher
    }

    /// No profiles, no seed, a cache path under the temporary directory that nothing writes, and a fetcher that always
    /// refuses: the `AppState` default, so tests and previews never read the real cache or the network.
    static func inert() -> ProfilesModel {
        ProfilesModel(bundledURL: nil,
                      cacheURL: FileManager.default.temporaryDirectory
                          .appending(path: "mad-inert-profiles-\(UUID().uuidString).json", directoryHint: .notDirectory),
                      fetcher: DisabledProfilesFetcher())
    }

    /// Reads the seed and the cache off the main actor; keeps a newer catalog that a check installed meanwhile.
    func load() async {
        let bundledURL = bundledURL
        let cacheURL = cacheURL
        let loaded = await Task.detached { ProfileCatalog.load(bundledURL: bundledURL, cacheURL: cacheURL) }.value
        if !ProfileCatalog.isNewer(catalog.updated, than: loaded.updated) { catalog = loaded }
    }

    func profile(forBundleIdentifier bundleIdentifier: String) -> AppProfile? {
        catalog.profile(forBundleIdentifier: bundleIdentifier)
    }

    /// The `webApps` presets of the profiles in use, sorted by name for the wizard's preset grid.
    var webAppPresets: [WebAppPreset] {
        catalog.document.webApps.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `"chrome"` (any case) selects the Chrome desktop user agent; nil or any other value keeps Safari's.
    static func userAgentPreset(for preset: WebAppPreset) -> UserAgentPreset {
        preset.userAgent?.lowercased() == "chrome" ? .chrome : .safari
    }

    /// "18 apps, updated 2026-10-09 (bundled)", or "No profiles loaded."
    var catalogSummary: String {
        guard !catalog.updated.isEmpty else { return "No profiles loaded." }
        let apps = catalog.appCount == 1 ? "1 app" : "\(catalog.appCount) apps"
        return "\(apps), updated \(catalog.updated) (\(catalog.source.rawValue))"
    }

    /// Fetches `url` (nil when the Settings URL is not an allowed address), caches a strictly newer document and
    /// switches to it. Returns the message shown to the user, which is also kept in `statusMessage`.
    @discardableResult
    func checkForUpdates(from url: URL?) async -> String {
        isChecking = true
        defer { isChecking = false }
        let message: String
        if let url {
            do {
                switch try await ProfilesUpdater(fetcher: fetcher, cacheURL: cacheURL).update(from: url, current: catalog) {
                case .updated(let newer):
                    catalog = newer
                    message = "Downloaded profiles from \(newer.updated)."
                case .upToDate(let current, _):
                    message = "Profiles are up to date (\(current))."
                }
            } catch {
                message = "Could not check profile updates: \(error.localizedDescription)"
            }
        } else {
            message = "Could not check profile updates: the profiles URL must be an https://raw.githubusercontent.com address."
        }
        statusMessage = message
        return message
    }
}

/// The fetcher of the unit-test host and of `ProfilesModel.inert()`: it never touches the network.
struct DisabledProfilesFetcher: ProfilesFetching {
    func fetch(from url: URL) async throws -> Data {
        throw ProfilesError.fetchFailed("Profile updates are disabled while the app hosts the unit tests.")
    }
}
