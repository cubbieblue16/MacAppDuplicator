import Foundation

/// Reads `Contents/Info.plist` of a bundle. Shared by `AppInspector` and `TargetResolver`.
enum InfoPlistReader {
    static func infoPlistURL(ofBundle bundleURL: URL) -> URL {
        bundleURL.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
    }

    /// The parsed Info.plist, or nil when it is missing or not a dictionary.
    static func read(bundleAt bundleURL: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: infoPlistURL(ofBundle: bundleURL)),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any]
        else { return nil }
        return dictionary
    }
}
