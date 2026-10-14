import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Network
import os

/// Finds the icon of a web page for a Web App shortcut (spec §7). Best effort: nil means "no usable icon", and the
/// caller falls back to the generated letter tile.
protocol WebIconFetching: Sendable {
    /// - Returns: PNG, ICO or JPEG bytes that ImageIO can decode, or nil when the page has no usable icon.
    func fetchIcon(for pageURL: URL) async throws -> Data?
}

/// Resolves a host name to the raw addresses (4-byte IPv4 or 16-byte IPv6, network order) it points at. An empty
/// result means the name did not resolve. Injected so tests never touch DNS.
typealias IconHostResolver = @Sendable (_ host: String) async -> [[UInt8]]

/// The resolver the app uses: `getaddrinfo` on a background queue, so a slow lookup never blocks the main actor.
enum SystemIconHostResolver {
    static let resolve: IconHostResolver = { host in
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: addresses(of: host))
            }
        }
    }

    /// Every IPv4 and IPv6 address `getaddrinfo` returns for `host` (IP literals resolve to themselves).
    static func addresses(of rawHost: String) -> [[UInt8]] {
        var host = rawHost
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0, let first = head else { return [] }
        defer { freeaddrinfo(head) }
        var result: [[UInt8]] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            if let address = current.pointee.ai_addr {
                switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                        result.append(withUnsafeBytes(of: pointer.pointee.sin_addr) { Array($0) })
                    }
                case AF_INET6:
                    address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                        result.append(withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) })
                    }
                default:
                    break
                }
            }
            node = current.pointee.ai_next
        }
        return result
    }
}

/// Picks the icon address out of a page's HTML. Pure and offline so the precedence rules are tested without a network.
enum WebIconHTMLParser {
    /// `apple-touch-icon` links beat `icon` links; within a class the largest `sizes` wins and the first one in the
    /// document breaks ties. SVG icons are skipped (ImageIO cannot decode them), as are non-http(s) and `data:` hrefs.
    /// Relative hrefs are resolved against `pageURL`. Nil when the page declares no usable icon.
    static func iconURL(inHTML html: String, pageURL: URL) -> URL? {
        var best: (rank: Int, area: Int, url: URL)?
        for tag in linkTags(in: html) {
            let attributes = attributes(in: tag)
            guard let rel = attributes["rel"], let href = attributes["href"] else { continue }
            let tokens = Set(rel.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            let rank: Int
            if !tokens.isDisjoint(with: ["apple-touch-icon", "apple-touch-icon-precomposed"]) {
                rank = 2
            } else if tokens.contains("icon") {
                rank = 1
            } else {
                continue
            }
            if attributes["type"]?.lowercased().contains("svg") == true { continue }
            guard let url = resolve(href, against: pageURL), url.path.lowercased().hasSuffix(".svg") == false else { continue }
            let area = area(ofSizes: attributes["sizes"])
            if let current = best, (current.rank, current.area) >= (rank, area) { continue }
            best = (rank, area, url)
        }
        return best?.url
    }

    private static let linkTagPattern = regex(#"<link\b[^>]*>"#, options: [.caseInsensitive])
    private static let attributePattern = regex(#"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
    private static let sizePattern = regex(#"(\d+)\s*[xX]\s*(\d+)"#)

    /// The patterns above are constants; a failure here is a programming error caught by the first test run.
    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid built-in pattern \(pattern): \(error)")
        }
    }

    private static func linkTags(in html: String) -> [String] {
        let range = NSRange(html.startIndex..., in: html)
        return linkTagPattern.matches(in: html, range: range).compactMap { Range($0.range, in: html).map { String(html[$0]) } }
    }

    /// Lower-cased attribute names mapped to their values; the first occurrence of a name wins.
    private static func attributes(in tag: String) -> [String: String] {
        var result: [String: String] = [:]
        let range = NSRange(tag.startIndex..., in: tag)
        for match in attributePattern.matches(in: tag, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let name = tag[nameRange].lowercased()
            let value = (2...4).lazy.compactMap { Range(match.range(at: $0), in: tag) }.first.map { String(tag[$0]) } ?? ""
            if result[name] == nil { result[name] = value }
        }
        return result
    }

    /// The largest `WxH` in a `sizes` value; `any` counts as very large; no value counts as 0.
    private static func area(ofSizes sizes: String?) -> Int {
        guard let sizes = sizes?.lowercased() else { return 0 }
        if sizes.split(whereSeparator: \.isWhitespace).contains("any") { return Int.max }
        let range = NSRange(sizes.startIndex..., in: sizes)
        return sizePattern.matches(in: sizes, range: range).compactMap { match -> Int? in
            guard let w = Range(match.range(at: 1), in: sizes).flatMap({ Int(sizes[$0]) }),
                  let h = Range(match.range(at: 2), in: sizes).flatMap({ Int(sizes[$0]) }) else { return nil }
            return w * h
        }.max() ?? 0
    }

    /// True when an icon the page names may be fetched: http(s), and not a loopback or private-network address unless
    /// it is on the page's own host (the user chose that host). Stops page HTML from steering the app at other machines.
    static func isFetchableIconURL(_ url: URL, pageHost: String?) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
        if let pageHost, host == pageHost.lowercased() { return true }
        return !isLoopbackOrPrivate(host: host)
    }

    /// `isFetchableIconURL(_:pageHost:)` plus name resolution: the host must resolve, and EVERY address it resolves to
    /// must be public. A public-looking name that points at `10.x`, `127.0.0.1` or a link-local address (including the
    /// page's own host: only the literal check has that exemption) is refused. This closes the "attacker.example has
    /// an A record for 169.254.169.254" route that the literal check cannot see. A DNS answer that changes between
    /// this check and the connection (rebinding) is not covered.
    static func isFetchableIconURL(_ url: URL, pageHost: String?, resolver: IconHostResolver) async -> Bool {
        guard isFetchableIconURL(url, pageHost: pageHost),
              let host = url.host(percentEncoded: false), !host.isEmpty else { return false }
        let addresses = await resolver(host)
        return !addresses.isEmpty && addresses.allSatisfy { !isNonPublic($0) }
    }

    /// True when `rawHost` names this machine or a non-public network: `localhost`, `.local`, and any IP literal in a
    /// loopback, private, link-local, carrier-grade NAT, unspecified or multicast range. IP literals are parsed the way
    /// the system resolver does, so legacy spellings (`127.1`, `0x7f000001`, `2130706433`) and IPv4-mapped IPv6
    /// (`::ffff:127.0.0.1`) are recognised, not just the dotted-quad form.
    static func isLoopbackOrPrivate(host rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if host.contains(":") {
            let unscoped = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? host
            guard let address = IPv6Address(unscoped) else { return false }
            return isNonPublic(address.rawValue.map { $0 })
        }
        var legacy = in_addr()
        guard inet_aton(host, &legacy) != 0 else { return false }
        return isNonPublic(withUnsafeBytes(of: legacy.s_addr) { Array($0) })
    }

    /// `bytes` is a 4-byte IPv4 or 16-byte IPv6 address in network order.
    static func isNonPublic(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 {
            switch (bytes[0], bytes[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168): return true
            case (100, 64...127), (172, 16...31): return true
            case (224...255, _): return true
            default: return false
            }
        }
        guard bytes.count == 16 else { return true }
        let leading = bytes[0..<12]
        // IPv4-mapped (::ffff:a.b.c.d), IPv4-compatible (::a.b.c.d, also :: and ::1) and NAT64 (64:ff9b::a.b.c.d) carry an IPv4 address.
        let mapped = leading.elementsEqual([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff])
        let compatible = leading.allSatisfy { $0 == 0 }
        let nat64 = leading.elementsEqual([0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0])
        if mapped || nat64 { return isNonPublic(Array(bytes[12..<16])) }
        if compatible { return true }
        // fc00::/7 unique local, fe80::/10 link local, ff00::/8 multicast.
        return bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) || bytes[0] == 0xff
    }

    /// Whether a redirect from `original` to `target` may be followed: the same rule as for a declared icon, with the
    /// host of the request that started the chain counting as the user's own.
    static func isRedirectAllowed(to target: URL, from original: URL?) -> Bool {
        isFetchableIconURL(target, pageHost: original?.host(percentEncoded: false))
    }

    private static func resolve(_ href: String, against pageURL: URL) -> URL? {
        let cleaned = href.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "&amp;", with: "&")
        guard !cleaned.isEmpty, let url = URL(string: cleaned, relativeTo: pageURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }
}

/// Cancels a redirect to a loopback or private-network address, so a public page or icon address cannot bounce the
/// request to another machine on the user's network. A refused redirect ends the request with the 3xx response, which
/// `get()` treats as "no icon".
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    /// Attached per task (not per session): a session that owns a delegate stays alive until it is invalidated.
    static let shared = RedirectGuard()

    private let resolver: IconHostResolver

    init(resolver: @escaping IconHostResolver = SystemIconHostResolver.resolve) {
        self.resolver = resolver
    }

    /// The literal check answers at once; a name that passes it is resolved first, so the answer is asynchronous.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let originalHost = task.originalRequest?.url?.host(percentEncoded: false)
        guard let target = request.url, WebIconHTMLParser.isRedirectAllowed(to: target, from: task.originalRequest?.url) else {
            completionHandler(nil)
            return
        }
        let resolver = resolver
        Task {
            let allowed = await WebIconHTMLParser.isFetchableIconURL(target, pageHost: originalHost, resolver: resolver)
            completionHandler(allowed ? request : nil)
        }
    }
}

/// Downloads a page's icon with an injected `URLSession`. Reads at most 1 MiB of the page and of the icon, gives each
/// request 15 seconds, and never throws for an HTTP error status: those mean "no icon" (nil), except that a page that
/// answers with an HTTP error is not parsed and `/favicon.ico` on the address the user typed is tried instead.
struct URLSessionWebIconFetcher: WebIconFetching {
    static let maxBytes = 1_048_576
    static let requestTimeout: TimeInterval = 15
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static let logger = Logger(subsystem: "com.mikekuta.MacAppDuplicator", category: "WebIconFetcher")

    let session: URLSession
    /// Resolves candidate icon hosts before they are requested; replaced in tests.
    let resolver: IconHostResolver

    init(session: URLSession = URLSessionWebIconFetcher.makeSession(), resolver: @escaping IconHostResolver = SystemIconHostResolver.resolve) {
        self.session = session
        self.resolver = resolver
    }

    /// An ephemeral session (no cookies, no cache) with the fetcher's timeouts.
    static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    func fetchIcon(for pageURL: URL) async throws -> Data? {
        guard let scheme = pageURL.scheme?.lowercased(), scheme == "https" || scheme == "http", pageURL.host != nil else { return nil }
        var pageStatus: Int?
        let page = try await get(pageURL, oversize: .truncate) { pageStatus = $0 }
        var candidates: [URL] = []
        if let page {
            // Redirects (for example web.whatsapp.com → another host) change what relative hrefs mean.
            let baseURL = page.finalURL
            let html = String(decoding: page.data, as: UTF8.self)
            if let declared = WebIconHTMLParser.iconURL(inHTML: html, pageURL: baseURL),
               await WebIconHTMLParser.isFetchableIconURL(declared, pageHost: baseURL.host(percentEncoded: false), resolver: resolver) {
                candidates.append(declared)
            }
            if let favicon = URL(string: "/favicon.ico", relativeTo: baseURL)?.absoluteURL, !candidates.contains(favicon) {
                candidates.append(favicon)
            }
        } else {
            // Some sites answer the page request with an error yet serve /favicon.ico (web.whatsapp.com answers 400). The
            // error body is not parsed, and no redirect information exists, so the typed address is the base.
            if let pageStatus {
                Self.logger.info("Page answered HTTP \(pageStatus, privacy: .public); trying /favicon.ico")
            }
            if let favicon = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL { candidates.append(favicon) }
        }
        for candidate in candidates {
            // The /favicon.ico candidates were not declared by the page, but they are on the page's host, which may
            // itself resolve to a private address; every candidate is resolved before it is requested.
            guard await WebIconHTMLParser.isFetchableIconURL(
                candidate, pageHost: candidate.host(percentEncoded: false), resolver: resolver
            ) else { continue }
            do {
                if let icon = try await get(candidate, oversize: .reject), Self.isDecodableImage(icon.data) { return icon.data }
            } catch let error as URLError {
                // The icon is optional; a candidate that cannot be reached just moves on to the next one.
                Self.logger.info("Icon candidate unreachable (\(error.code.rawValue, privacy: .public))")
            }
        }
        return nil
    }

    private struct Fetched {
        var data: Data
        var finalURL: URL
    }

    private enum Oversize {
        /// A page is cut at the cap: the icon links sit in `<head>`, far before 1 MiB.
        case truncate
        /// An icon over the cap is refused outright (a truncated image would decode as a partial picture).
        case reject
    }

    /// GET `url`. Nil for a non-2xx status (reported to `onHTTPError`), and for a body over the cap when `oversize` is `.reject`.
    private func get(_ url: URL, oversize: Oversize, onHTTPError: (Int) -> Void = { _ in }) async throws -> Fetched? {
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,image/*;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request, delegate: RedirectGuard.shared)
        guard let http = response as? HTTPURLResponse else { return nil }
        guard (200..<300).contains(http.statusCode) else {
            onHTTPError(http.statusCode)
            return nil
        }
        var data = Data()
        for try await byte in bytes {
            if data.count >= Self.maxBytes {
                switch oversize {
                case .truncate: return Fetched(data: data, finalURL: http.url ?? url)
                case .reject: return nil
                }
            }
            data.append(byte)
        }
        return Fetched(data: data, finalURL: http.url ?? url)
    }

    static func isDecodableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}
