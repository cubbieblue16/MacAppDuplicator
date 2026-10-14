import Foundation

/// Decides which main-frame navigations stay inside a web app window (spec §5). Everything else opens in the
/// default browser; the WebShell applies that decision, this type only answers the question.
public struct WebHostPolicy: Equatable, Sendable {
    /// Schemes WebKit uses for same-document and generated content. The shell lets these load in place.
    public static let internalSchemes: Set<String> = ["about", "data", "blob", "javascript"]

    /// Lower-cased hosts that stay in place: the base host first, then the extra hosts.
    public let allowedHosts: [String]

    public init(baseURL: URL, extraHosts: [String]) {
        var hosts: [String] = []
        if let baseHost = Self.normalizedHost(baseURL.host) {
            hosts.append(baseHost)
        }
        for extra in extraHosts {
            if let host = Self.normalizedHost(extra), !hosts.contains(host) {
                hosts.append(host)
            }
        }
        allowedHosts = hosts
    }

    /// True when `url` is `https` and its host equals, or is a subdomain of, an allowed host. Plain `http` never
    /// stays in place: a network attacker could rewrite it, and the page would then run with the web app's
    /// window, data store and native bridges.
    public func allowsInPlace(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = Self.normalizedHost(url.host)
        else {
            return false
        }
        return allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// True for `about:`, `data:`, `blob:` and `javascript:` URLs.
    public static func isInternalScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return internalSchemes.contains(scheme)
    }

    /// Lower-cased host without surrounding whitespace, a leading "." or a trailing "."; nil when nothing is left.
    private static func normalizedHost(_ host: String?) -> String? {
        guard var cleaned = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        while cleaned.hasSuffix(".") { cleaned.removeLast() }
        return cleaned.isEmpty ? nil : cleaned
    }
}
