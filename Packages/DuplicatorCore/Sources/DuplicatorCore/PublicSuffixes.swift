import Foundation

/// A deliberately short public-suffix list for the web app `extraHosts` check. `WebHostPolicy` trusts an extra host
/// and every subdomain of it, so `com` or `co.uk` would trust a whole registry. The full Public Suffix List is not
/// embedded: this set holds only the multi-label suffixes and shared-hosting domains a profile author is likely to
/// name by mistake. Single-label entries are rejected by the two-label rule, not by this list, so a suffix missing
/// here (an obscure ccTLD second level) is the known gap.
public enum PublicSuffixes {
    /// Multi-label suffixes that must never be trusted as a whole.
    public static let suffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.nz", "co.jp", "ne.jp", "or.jp",
        "com.br", "com.cn", "com.mx", "co.za", "com.tr", "co.in", "co.kr", "github.io", "herokuapp.com",
        "azurewebsites.net", "cloudfront.net", "amazonaws.com", "web.app", "firebaseapp.com", "netlify.app",
        "vercel.app", "pages.dev", "workers.dev",
    ]

    /// True when `host` (trimmed, lower-cased, no trailing dot) has at least two labels and is not itself a listed
    /// suffix. `foo.github.io` passes; `github.io`, `co.uk` and `com` do not.
    public static func isAcceptableExtraHost(_ host: String) -> Bool {
        var cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        while cleaned.hasSuffix(".") { cleaned.removeLast() }
        let labels = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        return !suffixes.contains(cleaned)
    }
}
