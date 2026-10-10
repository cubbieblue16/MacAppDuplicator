import Foundation

/// Fixed locations for compatibility profiles.
public enum ProfilesConstants {
    /// The default profiles URL (Settings → Profiles). It answers HTTP 404 until the repository is public; Check
    /// Profile Updates then reports the status and changes nothing.
    public static let defaultURLString =
        "https://raw.githubusercontent.com/cubbieblue16/MacAppDuplicator/main/Packages/CompatProfiles/Resources/profiles.json"

    /// `<home>/Library/Application Support/App Duplicator/profiles.json`, the cached remote copy. Only Check Profile
    /// Updates writes it.
    public static func defaultCacheURL(home: URL) -> URL {
        home.appending(path: "Library/Application Support/App Duplicator/profiles.json", directoryHint: .notDirectory)
    }
}
