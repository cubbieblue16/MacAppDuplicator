import Foundation

/// Downloads the raw bytes of a `profiles.json`. Injected everywhere, so tests never touch the network.
public protocol ProfilesFetching: Sendable {
    func fetch(from url: URL) async throws -> Data
}

/// The rules every profile download follows (spec §2, §8, §9): HTTPS to `raw.githubusercontent.com` only, for the
/// request and for every redirect; HTTP 200 only; at most `ProfilesDocument.maxBytes`.
public enum ProfilesFetchPolicy {
    public static let allowedHost = "raw.githubusercontent.com"

    /// Whether `url` may be fetched: scheme `https`, host `raw.githubusercontent.com` (both case-insensitive), port 443
    /// or none, and no user name or password.
    public static func isAllowedSource(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == allowedHost,
              components.user == nil,
              components.password == nil
        else { return false }
        return components.port == nil || components.port == 443
    }

    /// Whether a redirect to `url` may be followed; the same rule as the original request.
    public static func allowsRedirect(to url: URL?) -> Bool {
        guard let url else { return false }
        return isAllowedSource(url)
    }

    /// Checks a response before its body is read. `expectedContentLength` is -1 when the server did not say. A refused
    /// redirect leaves the 3xx response as the final one, which fails here as `httpStatus`.
    public static func checkResponse(statusCode: Int, finalURL: URL?, expectedContentLength: Int64) throws {
        guard statusCode == 200 else { throw ProfilesError.httpStatus(statusCode) }
        guard let finalURL, isAllowedSource(finalURL) else {
            throw ProfilesError.insecureURL(finalURL?.absoluteString ?? "")
        }
        if expectedContentLength > Int64(ProfilesDocument.maxBytes) {
            throw ProfilesError.tooLarge(Int(expectedContentLength))
        }
    }
}

/// The production fetcher: one ephemeral `URLSession` per fetch with no cookie, cache or credential storage, redirects
/// checked against `ProfilesFetchPolicy`, and the body read with a running size cap. It holds no state.
public final class URLSessionProfilesFetcher: NSObject, ProfilesFetching, URLSessionTaskDelegate, Sendable {
    override public init() {
        super.init()
    }

    /// The configuration of every fetch session.
    public static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return configuration
    }

    /// The request for `url`: a GET that never comes from a cache and sends no cookies.
    public static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        return request
    }

    public func fetch(from url: URL) async throws -> Data {
        guard ProfilesFetchPolicy.isAllowedSource(url) else { throw ProfilesError.insecureURL(url.absoluteString) }
        let session = URLSession(configuration: Self.sessionConfiguration())
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, response) = try await session.bytes(for: Self.request(for: url), delegate: self)
            guard let http = response as? HTTPURLResponse else {
                throw ProfilesError.fetchFailed("The profiles server did not send an HTTP response.")
            }
            try ProfilesFetchPolicy.checkResponse(statusCode: http.statusCode, finalURL: http.url,
                                                  expectedContentLength: http.expectedContentLength)
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > ProfilesDocument.maxBytes { throw ProfilesError.tooLarge(data.count) }
            }
            return data
        } catch let error as ProfilesError {
            throw error
        } catch {
            throw ProfilesError.fetchFailed(error.localizedDescription)
        }
    }

    /// Follows a redirect only when its target passes `ProfilesFetchPolicy`; otherwise the 3xx response becomes the
    /// final response and `checkResponse` reports it.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        ProfilesFetchPolicy.allowsRedirect(to: request.url) ? request : nil
    }
}
