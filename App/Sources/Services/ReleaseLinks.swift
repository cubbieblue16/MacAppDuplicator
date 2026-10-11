import Foundation

/// The GitHub addresses behind Help → Check for Updates… (spec §7: Sparkle is deferred; releases are notarized DMGs on
/// GitHub Releases). Nothing here touches the network; the menu item hands the URL to the default browser.
enum ReleaseLinks {
    static let repository: URL = gitHub(path: "/cubbieblue16/MacAppDuplicator")
    static let latestRelease: URL = gitHub(path: "/cubbieblue16/MacAppDuplicator/releases/latest")

    private static func gitHub(path: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = path
        return components.url ?? URL(fileURLWithPath: "/")
    }
}
