import XCTest
@testable import CompatProfiles

/// Shape-only tests: no test here resumes a `URLSession` task, so nothing touches the network.
final class URLSessionProfilesFetcherTests: XCTestCase {
    func testSessionAndRequestKeepNoCookiesCacheOrCredentials() throws {
        let configuration = URLSessionProfilesFetcher.sessionConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 20)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 60)

        let url = try XCTUnwrap(URL(string: ProfilesConstants.defaultURLString))
        let request = URLSessionProfilesFetcher.request(for: url)
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.timeoutInterval, 20)
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testRefusesAnInsecureURLBeforeAnyRequest() async throws {
        let fetcher = URLSessionProfilesFetcher()
        for raw in ["http://raw.githubusercontent.com/cubbieblue16/MacAppDuplicator/main/profiles.json",
                    "https://gist.githubusercontent.com/cubbieblue16/profiles.json",
                    "file:///etc/hosts"] {
            let url = try XCTUnwrap(URL(string: raw))
            do {
                _ = try await fetcher.fetch(from: url)
                XCTFail("expected insecureURL for \(raw)")
            } catch {
                XCTAssertEqual(error as? ProfilesError, .insecureURL(raw))
            }
        }
    }

    func testRedirectsAreFollowedOnlyToTheAllowedHost() async throws {
        let fetcher = URLSessionProfilesFetcher()
        let session = URLSession(configuration: URLSessionProfilesFetcher.sessionConfiguration())
        defer { session.invalidateAndCancel() }
        let original = try XCTUnwrap(URL(string: ProfilesConstants.defaultURLString))
        let task = session.dataTask(with: original) // never resumed, so no request is sent
        let response = try XCTUnwrap(HTTPURLResponse(url: original, statusCode: 301, httpVersion: "HTTP/1.1", headerFields: nil))
        let sameHost = URLRequest(url: try XCTUnwrap(URL(string: "https://raw.githubusercontent.com/cubbieblue16/Renamed/main/profiles.json")))
        let otherHost = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/profiles.json")))
        let plainHTTP = URLRequest(url: try XCTUnwrap(URL(string: "http://raw.githubusercontent.com/cubbieblue16/Renamed/main/profiles.json")))

        let followedSameHost = await fetcher.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: sameHost)
        let followedOtherHost = await fetcher.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: otherHost)
        let followedPlainHTTP = await fetcher.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: plainHTTP)

        XCTAssertEqual(followedSameHost, sameHost)
        XCTAssertNil(followedOtherHost)
        XCTAssertNil(followedPlainHTTP)
    }
}
