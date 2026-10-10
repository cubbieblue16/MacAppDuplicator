import Foundation

/// Where the active profiles came from; shown in Settings and Diagnostics.
public enum ProfileSource: String, Sendable {
    case bundled, cached
}

/// The profiles the app uses: the bundled seed, or the cached remote copy when it is strictly newer (spec §8).
public struct ProfileCatalog: Equatable, Sendable {
    public var document: ProfilesDocument
    public var source: ProfileSource

    public init(document: ProfilesDocument, source: ProfileSource) {
        self.document = document
        self.source = source
    }

    /// No profiles at all; used until `load` finishes and when even the bundled seed is missing or invalid.
    public static let empty = ProfileCatalog(document: ProfilesDocument(updated: ""), source: .bundled)

    /// The document's `updated` date (`YYYY-MM-DD`; empty for `empty`).
    public var updated: String { document.updated }

    /// Number of app profiles.
    public var appCount: Int { document.apps.count }

    /// The profile for `bundleIdentifier`. Bundle identifiers are case-insensitive, so the lookup is too.
    public func profile(forBundleIdentifier bundleIdentifier: String) -> AppProfile? {
        if let exact = document.apps[bundleIdentifier] { return exact }
        let folded = bundleIdentifier.lowercased()
        return document.apps.first { $0.key.lowercased() == folded }?.value
    }

    /// Reads the bundled seed and the cached copy and returns the one to use; never throws. A missing, oversized or
    /// invalid source is skipped, and the cache wins only when its `updated` date is strictly later than the seed's.
    public static func load(bundledURL: URL?, cacheURL: URL) -> ProfileCatalog {
        let bundled = bundledURL.flatMap(readDocument(at:)).map { ProfileCatalog(document: $0, source: .bundled) }
        let cached = readDocument(at: cacheURL).map { ProfileCatalog(document: $0, source: .cached) }
        switch (bundled, cached) {
        case let (bundled?, cached?):
            return isNewer(cached.updated, than: bundled.updated) ? cached : bundled
        case let (bundled?, nil):
            return bundled
        case let (nil, cached?):
            return cached
        case (nil, nil):
            return .empty
        }
    }

    /// Whether `candidate` is a strictly later date than `current`. Both are validated `YYYY-MM-DD` strings (or empty
    /// for the empty catalog), so string order is date order.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate > current
    }

    /// The validated document at `url`, or nil when the file is missing, larger than `ProfilesDocument.maxBytes`,
    /// unreadable or invalid. A bad cache must never stop the app from using the bundled seed.
    static func readDocument(at url: URL) -> ProfilesDocument? {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= ProfilesDocument.maxBytes else { return nil }
            return try ProfilesDocument.decodeValidated(from: Data(contentsOf: url))
        } catch {
            return nil
        }
    }
}
