import CoreGraphics
import Foundation
import ImageIO
import os

/// Finds the icon of a web page for a Web App shortcut (spec §7). Best effort: nil means "no usable icon", and the
/// caller falls back to the generated letter tile.
protocol WebIconFetching: Sendable {
    /// - Returns: PNG, ICO or JPEG bytes that ImageIO can decode, or nil when the page has no usable icon.
    func fetchIcon(for pageURL: URL) async throws -> Data?
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

    private static func resolve(_ href: String, against pageURL: URL) -> URL? {
        let cleaned = href.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "&amp;", with: "&")
        guard !cleaned.isEmpty, let url = URL(string: cleaned, relativeTo: pageURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }
}

/// Downloads a page's icon with an injected `URLSession`. Reads at most 1 MiB of the page and of the icon, gives each
/// request 15 seconds, and never throws for an HTTP error status: those mean "no icon" (nil).
struct URLSessionWebIconFetcher: WebIconFetching {
    static let maxBytes = 1_048_576
    static let requestTimeout: TimeInterval = 15
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static let logger = Logger(subsystem: "com.mikekuta.MacAppDuplicator", category: "WebIconFetcher")

    let session: URLSession

    init(session: URLSession = URLSessionWebIconFetcher.makeSession()) {
        self.session = session
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
        guard let page = try await get(pageURL, oversize: .truncate) else { return nil }
        // Redirects (for example web.whatsapp.com → another host) change what relative hrefs mean.
        let baseURL = page.finalURL
        let html = String(decoding: page.data, as: UTF8.self)
        var candidates: [URL] = []
        if let declared = WebIconHTMLParser.iconURL(inHTML: html, pageURL: baseURL) { candidates.append(declared) }
        if let favicon = URL(string: "/favicon.ico", relativeTo: baseURL)?.absoluteURL, !candidates.contains(favicon) {
            candidates.append(favicon)
        }
        for candidate in candidates {
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

    /// GET `url`. Nil for a non-2xx status, and for a body over the cap when `oversize` is `.reject`.
    private func get(_ url: URL, oversize: Oversize) async throws -> Fetched? {
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,image/*;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
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
