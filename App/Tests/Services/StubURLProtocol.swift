import Foundation
import Synchronization

/// A canned HTTP response for `StubURLProtocol`.
struct StubbedResponse: Sendable {
    var status: Int
    var body: Data
    /// Reported as `response.url`, to simulate a redirect that ended somewhere else.
    var finalURL: URL?

    init(status: Int = 200, body: Data = Data(), finalURL: URL? = nil) {
        self.status = status
        self.body = body
        self.finalURL = finalURL
    }

    init(html: String, status: Int = 200, finalURL: URL? = nil) {
        self.init(status: status, body: Data(html.utf8), finalURL: finalURL)
    }
}

/// What a stubbed session was asked for.
struct RecordedRequest: Sendable, Equatable {
    var url: URL
    var timeout: TimeInterval
    var userAgent: String?
}

/// Serves `routes` to any `URLSession` whose configuration lists it in `protocolClasses`; an unrouted URL fails with
/// `URLError.cannotFindHost`. No test using it touches the network. Routes are keyed by absolute URL string and tests
/// use their own host names, so test classes never see each other's entries.
final class StubURLProtocol: URLProtocol {
    static let routes = Mutex<[String: StubbedResponse]>([:])
    static let requests = Mutex<[RecordedRequest]>([])

    /// An ephemeral session that only this protocol serves.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func setRoute(_ url: String, _ response: StubbedResponse) {
        routes.withLock { $0[url] = response }
    }

    static func removeRoutes(_ urls: [String]) {
        routes.withLock { table in urls.forEach { table[$0] = nil } }
    }

    static func requests(forHost host: String) -> [RecordedRequest] {
        requests.withLock { $0.filter { $0.url.host == host } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.requests.withLock {
            $0.append(RecordedRequest(url: url, timeout: request.timeoutInterval, userAgent: request.value(forHTTPHeaderField: "User-Agent")))
        }
        guard let stub = Self.routes.withLock({ $0[url.absoluteString] }),
              let response = HTTPURLResponse(url: stub.finalURL ?? url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
