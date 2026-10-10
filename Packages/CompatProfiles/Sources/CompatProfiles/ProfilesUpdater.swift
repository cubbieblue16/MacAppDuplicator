import Foundation

/// What Check Profile Updates found.
public enum ProfilesUpdateResult: Equatable, Sendable {
    /// A strictly newer document was downloaded, validated and cached; use this catalog from now on.
    case updated(ProfileCatalog)
    /// The download was valid but not newer than the profiles in use; nothing was written.
    case upToDate(current: String, fetched: String)
}

/// Downloads `profiles.json`, validates it as untrusted input and caches it only when it is strictly newer than the
/// profiles in use (spec §8). Nothing is written unless the download is valid and newer, and the bytes written are
/// exactly the bytes that were validated.
public struct ProfilesUpdater: Sendable {
    public let fetcher: any ProfilesFetching
    public let cacheURL: URL

    public init(fetcher: any ProfilesFetching, cacheURL: URL) {
        self.fetcher = fetcher
        self.cacheURL = cacheURL
    }

    public func update(from url: URL, current: ProfileCatalog) async throws -> ProfilesUpdateResult {
        guard ProfilesFetchPolicy.isAllowedSource(url) else { throw ProfilesError.insecureURL(url.absoluteString) }
        let data = try await fetcher.fetch(from: url)
        let document = try ProfilesDocument.decodeValidated(from: data)
        guard ProfileCatalog.isNewer(document.updated, than: current.updated) else {
            return .upToDate(current: current.updated, fetched: document.updated)
        }
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
        return .updated(ProfileCatalog(document: document, source: .cached))
    }
}
