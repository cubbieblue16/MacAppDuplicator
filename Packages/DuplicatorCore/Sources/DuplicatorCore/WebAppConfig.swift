import Foundation

/// User-agent choice for a web app shortcut (spec §5). `safari` keeps WebKit's own user agent.
public enum UserAgentPreset: String, Codable, Sendable {
    case safari, chrome

    /// Fixed desktop Chrome user agent sent for `.chrome`. Sites such as WhatsApp Web gate features on it.
    public static let chromeDesktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

    /// Value for `WKWebView.customUserAgent`; nil keeps the WebKit default.
    public var customUserAgent: String? {
        switch self {
        case .safari: nil
        case .chrome: Self.chromeDesktopUserAgent
        }
    }
}

/// Settings of a `kind == .webApp` shortcut, stored in `MADConfig` under `webApp` (spec §5).
public struct WebAppConfig: Codable, Hashable, Sendable {
    /// Allowed range of `pageZoom`.
    public static let pageZoomRange: ClosedRange<Double> = 0.5...3.0

    /// Start address; `https` with a host (`WebAppURLValidator`).
    public var url: String
    /// Identifier of the shortcut's own `WKWebsiteDataStore`, so logins stay separate per shortcut.
    public var dataStoreID: UUID
    public var userAgent: UserAgentPreset
    /// Regular expression with one capture group matched against the page title; nil uses `BadgeTitleParser.defaultPattern`.
    public var badgeRegex: String?
    /// Extra hosts that load inside the window (lower-cased, no scheme).
    public var extraHosts: [String]
    /// Initial page zoom, clamped to `pageZoomRange`.
    public var pageZoom: Double
    /// Keep running in the menu bar when the window closes (effective only with `ShortcutConfig.menuBarIcon`).
    public var backgroundMode: Bool

    public init(
        url: String,
        dataStoreID: UUID = UUID(),
        userAgent: UserAgentPreset = .safari,
        badgeRegex: String? = nil,
        extraHosts: [String] = [],
        pageZoom: Double = 1.0,
        backgroundMode: Bool = false
    ) {
        self.url = url
        self.dataStoreID = dataStoreID
        self.userAgent = userAgent
        self.badgeRegex = badgeRegex
        self.extraHosts = Self.normalizedHosts(extraHosts)
        self.pageZoom = Self.clampedZoom(pageZoom)
        self.backgroundMode = backgroundMode
    }

    private enum CodingKeys: String, CodingKey {
        case url, dataStoreID, userAgent, badgeRegex, extraHosts, pageZoom, backgroundMode
    }

    /// `url` and `dataStoreID` are required; every other key falls back to its default so older or hand-edited
    /// dictionaries still load. Hosts and zoom pass through the same normalisation as `init(url:...)`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            url: try container.decode(String.self, forKey: .url),
            dataStoreID: try container.decode(UUID.self, forKey: .dataStoreID),
            userAgent: try container.decodeIfPresent(UserAgentPreset.self, forKey: .userAgent) ?? .safari,
            badgeRegex: try container.decodeIfPresent(String.self, forKey: .badgeRegex),
            extraHosts: try container.decodeIfPresent([String].self, forKey: .extraHosts) ?? [],
            pageZoom: try container.decodeIfPresent(Double.self, forKey: .pageZoom) ?? 1.0,
            backgroundMode: try container.decodeIfPresent(Bool.self, forKey: .backgroundMode) ?? false
        )
    }

    /// `value` limited to `pageZoomRange`; a non-finite value becomes 1.0.
    public static func clampedZoom(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, pageZoomRange.lowerBound), pageZoomRange.upperBound)
    }

    /// Trimmed, lower-cased hosts without empty entries or duplicates, in first-seen order.
    public static func normalizedHosts(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for host in hosts {
            let cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !cleaned.isEmpty, seen.insert(cleaned).inserted {
                result.append(cleaned)
            }
        }
        return result
    }
}

/// Why a web address was refused. The description is the inline copy in the wizard and editor.
public enum WebAppURLError: Error, Equatable, LocalizedError {
    case invalidAddress

    public var errorDescription: String? { "Enter an https:// address" }
}

/// Validates the address of a web app (spec §5): `https`, a host, no embedded credentials.
public enum WebAppURLValidator {
    /// The trimmed `string` as a URL, or `WebAppURLError.invalidAddress`.
    public static func validate(_ string: String) throws -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url
        else {
            throw WebAppURLError.invalidAddress
        }
        return url
    }
}
