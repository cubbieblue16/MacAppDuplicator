import AppKit
import os
import XCTest
@testable import MacAppDuplicator

final class WebIconHTMLParserTests: XCTestCase {
    private let page = URL(string: "https://www.example.test/app/index.html")!

    private func icon(_ html: String) -> String? {
        WebIconHTMLParser.iconURL(inHTML: html, pageURL: page)?.absoluteString
    }

    func testAppleTouchIconBeatsAnyIconRegardlessOfSizeOrOrder() {
        let html = """
        <head><link rel="icon" sizes="512x512" href="/big.png">
        <link rel="apple-touch-icon" sizes="120x120" href="/touch-120.png"></head>
        """
        XCTAssertEqual(icon(html), "https://www.example.test/touch-120.png")
    }

    func testPrecomposedTouchIconCountsAsATouchIcon() {
        XCTAssertEqual(icon(#"<link rel="icon" href="/a.png"><link rel="apple-touch-icon-precomposed" href="/pre.png">"#),
                       "https://www.example.test/pre.png")
    }

    func testLargestSizesWinsWithinAClassAndTheFirstWinsATie() {
        let touch = """
        <link rel="apple-touch-icon" sizes="76x76" href="/76.png">
        <link rel="apple-touch-icon" sizes="180x180" href="/180.png">
        <link rel="apple-touch-icon" sizes="152x152" href="/152.png">
        """
        XCTAssertEqual(icon(touch), "https://www.example.test/180.png")
        let tie = #"<link rel="icon" href="/first.png"><link rel="icon" href="/second.png">"#
        XCTAssertEqual(icon(tie), "https://www.example.test/first.png")
        let sized = #"<link rel="icon" sizes="16x16 32x32 48x48" href="/multi.png"><link rel="icon" sizes="64x64" href="/64.png">"#
        XCTAssertEqual(icon(sized), "https://www.example.test/64.png", "the largest declared size of a link counts, so 64x64 beats 48x48")
    }

    func testRelTokensAndAttributeOrderAndQuoting() {
        XCTAssertEqual(icon(#"<LINK HREF='/single.png' REL='Shortcut Icon'>"#), "https://www.example.test/single.png")
        XCTAssertEqual(icon("<link\n  rel=icon\n  href=/bare.png\n>"), "https://www.example.test/bare.png")
        XCTAssertEqual(icon(#"<link rel="icon" href="/a.png?x=1&amp;y=2">"#), "https://www.example.test/a.png?x=1&y=2")
    }

    func testRelativeAndAbsoluteHrefsResolveAgainstThePage() {
        XCTAssertEqual(icon(#"<link rel="icon" href="icon.png">"#), "https://www.example.test/app/icon.png")
        XCTAssertEqual(icon(#"<link rel="icon" href="../up.png">"#), "https://www.example.test/up.png")
        XCTAssertEqual(icon(#"<link rel="icon" href="//cdn.example.test/proto.png">"#), "https://cdn.example.test/proto.png")
        XCTAssertEqual(icon(#"<link rel="icon" href="https://cdn.example.test/abs.png">"#), "https://cdn.example.test/abs.png")
    }

    func testIconAddressesOnLoopbackAndPrivateHostsAreNotFetchable() throws {
        func fetchable(_ address: String, pageHost: String? = "www.example.test") throws -> Bool {
            WebIconHTMLParser.isFetchableIconURL(try XCTUnwrap(URL(string: address)), pageHost: pageHost)
        }
        XCTAssertTrue(try fetchable("https://cdn.example.test/icon.png"))
        XCTAssertTrue(try fetchable("http://8.8.8.8/icon.png"))
        XCTAssertTrue(try fetchable("http://172.32.0.1/icon.png"))
        XCTAssertFalse(try fetchable("http://localhost/icon.png"))
        XCTAssertFalse(try fetchable("http://127.0.0.1:8080/icon.png"))
        XCTAssertFalse(try fetchable("http://[::1]/icon.png"))
        XCTAssertFalse(try fetchable("http://10.1.2.3/icon.png"))
        XCTAssertFalse(try fetchable("http://172.16.0.1/icon.png"))
        XCTAssertFalse(try fetchable("http://172.31.255.1/icon.png"))
        XCTAssertFalse(try fetchable("http://192.168.1.1/icon.png"))
        XCTAssertFalse(try fetchable("https://printer.local/icon.png"))
        XCTAssertFalse(try fetchable("ftp://cdn.example.test/icon.png"))
        XCTAssertTrue(try fetchable("http://192.168.1.1/icon.png", pageHost: "192.168.1.1"), "the page's own host is the user's choice")
    }

    func testAlternateIPSpellingsAreRecognisedAsLoopbackOrPrivate() throws {
        func blocked(_ host: String) -> Bool { WebIconHTMLParser.isLoopbackOrPrivate(host: host) }
        for host in ["127.1", "127.0.1", "0x7f000001", "0x7f.0.0.1", "2130706433", "017700000001", "0177.0.0.1", "10.1", "0xa000001",
                     "3232235777", "0", "0.0.0.0", "0.1.2.3", "100.64.0.1", "100.127.255.254", "169.254.169.254", "224.0.0.1", "255.255.255.255",
                     "[::1]", "::1", "::", "::ffff:127.0.0.1", "[::ffff:127.0.0.1]", "::ffff:7f00:1", "::ffff:10.0.0.1", "::ffff:192.168.1.1",
                     "::127.0.0.1", "64:ff9b::7f00:1", "fe80::1", "fe80::1%en0", "febf::1", "fc00::1", "fd12:3456::1", "ff02::1",
                     "localhost.", "LOCALHOST", "printer.local."] {
            XCTAssertTrue(blocked(host), "\(host) must count as loopback or private")
        }
        for host in ["8.8.8.8", "1.1.1.1", "100.63.255.255", "100.128.0.1", "172.15.0.1", "172.32.0.1", "169.253.0.1", "223.255.255.255",
                     "::ffff:8.8.8.8", "2001:4860:4860::8888", "2606:4700::1111", "fec0::1", "64:ff9b::808:808",
                     "cdn.example.test", "10.example.test", "127.example.test", "0x7f.example.test"] {
            XCTAssertFalse(blocked(host), "\(host) is a public address or a name")
        }
        XCTAssertFalse(WebIconHTMLParser.isFetchableIconURL(try XCTUnwrap(URL(string: "http://127.1/i.png")), pageHost: "www.example.test"))
        XCTAssertFalse(WebIconHTMLParser.isFetchableIconURL(try XCTUnwrap(URL(string: "http://[::ffff:127.0.0.1]/i.png")), pageHost: "www.example.test"))
        XCTAssertFalse(WebIconHTMLParser.isFetchableIconURL(try XCTUnwrap(URL(string: "http://2130706433/i.png")), pageHost: "www.example.test"))
    }

    func testRedirectsAreCheckedLikeDeclaredIcons() throws {
        func allowed(_ target: String, from original: String) throws -> Bool {
            WebIconHTMLParser.isRedirectAllowed(to: try XCTUnwrap(URL(string: target)), from: URL(string: original))
        }
        XCTAssertTrue(try allowed("https://cdn.example.test/i.png", from: "https://www.example.test/"))
        XCTAssertFalse(try allowed("http://192.168.1.1/", from: "https://attacker.example/i.png"))
        XCTAssertFalse(try allowed("http://169.254.169.254/latest/meta-data/", from: "https://attacker.example/i.png"))
        XCTAssertFalse(try allowed("http://localhost:8080/", from: "https://attacker.example/i.png"))
        XCTAssertFalse(try allowed("http://[::ffff:127.0.0.1]/", from: "https://attacker.example/i.png"))
        XCTAssertFalse(try allowed("ftp://cdn.example.test/i.png", from: "https://www.example.test/"))
        XCTAssertTrue(try allowed("http://192.168.1.1/other", from: "http://192.168.1.1/"), "a redirect within the user's own host is fine")
        XCTAssertFalse(try allowed("http://192.168.1.2/", from: "http://192.168.1.1/"), "a different private host is not")
    }

    func testTheRedirectGuardCancelsUnfetchableRedirectsAndFollowsOthers() throws {
        let session = URLSessionWebIconFetcher.makeSession()
        defer { session.invalidateAndCancel() }
        let original = try XCTUnwrap(URL(string: "https://www.example.test/favicon.ico"))
        let task = session.dataTask(with: URLRequest(url: original))
        let response = try XCTUnwrap(HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil))
        func decision(for target: String) throws -> URLRequest? {
            let next = URLRequest(url: try XCTUnwrap(URL(string: target)))
            let answer = OSAllocatedUnfairLock<URLRequest??>(initialState: nil)
            RedirectGuard.shared.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next) { decided in
                answer.withLock { $0 = .some(decided) }
            }
            return try XCTUnwrap(answer.withLock { $0 }, "the guard must answer synchronously")
        }
        XCTAssertEqual(try decision(for: "https://cdn.example.test/favicon.ico")?.url?.host, "cdn.example.test")
        XCTAssertNil(try decision(for: "http://169.254.169.254/latest/meta-data/"))
        XCTAssertNil(try decision(for: "http://127.1/"))
    }

    func testUnusableLinksAreSkipped() {
        let html = """
        <link rel="mask-icon" href="/mask.svg">
        <link rel="icon" type="image/svg+xml" href="/vector">
        <link rel="icon" href="/vector.SVG">
        <link rel="icon" href="data:image/png;base64,AAAA">
        <link rel="icon" href="javascript:alert(1)">
        <link rel="stylesheet" href="/site.css">
        <link rel="icon">
        <link rel="icon" href="/ok.png">
        """
        XCTAssertEqual(icon(html), "https://www.example.test/ok.png")
        XCTAssertNil(icon("<html><head><title>No icons</title></head></html>"))
        XCTAssertNil(icon(""))
    }
}

final class URLSessionWebIconFetcherTests: XCTestCase {
    private var host: String!
    private var routes: [String] = []
    private var fetcher: URLSessionWebIconFetcher!

    override func setUp() {
        host = "icons-\(UUID().uuidString.prefix(8).lowercased()).test"
        routes = []
        fetcher = URLSessionWebIconFetcher(session: StubURLProtocol.makeSession())
    }

    override func tearDown() {
        StubURLProtocol.removeRoutes(routes)
    }

    private func url(_ path: String) -> URL { URL(string: "https://\(host!)\(path)")! }

    private func route(_ path: String, _ response: StubbedResponse) {
        routes.append(url(path).absoluteString)
        StubURLProtocol.setRoute(url(path).absoluteString, response)
    }

    private func pngData(letter: String, size: Int = 64) throws -> Data {
        let image = IconRenderer.generatedTile(initials: letter, size: size)
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    func testDownloadsTheDeclaredTouchIconAndSendsTheFetchersHeaders() async throws {
        let png = try pngData(letter: "T")
        route("/", StubbedResponse(html: #"<link rel="icon" href="/small.png"><link rel="apple-touch-icon" href="/touch.png">"#))
        route("/touch.png", StubbedResponse(body: png))

        let data = try await fetcher.fetchIcon(for: url("/"))

        XCTAssertEqual(data, png)
        let requests = StubURLProtocol.requests(forHost: host)
        XCTAssertEqual(requests.map(\.url), [url("/"), url("/touch.png")], "the lower-ranked /small.png is never requested")
        XCTAssertTrue(requests.allSatisfy { $0.timeout == 15 })
        XCTAssertTrue(requests.allSatisfy { $0.userAgent == URLSessionWebIconFetcher.userAgent })
    }

    func testRelativeHrefResolvesAgainstThePageAfterARedirect() async throws {
        let png = try pngData(letter: "R")
        let landing = URL(string: "https://landing-\(host!)/inbox/")!
        route("/", StubbedResponse(html: #"<link rel="icon" href="logo.png">"#, finalURL: landing))
        StubURLProtocol.setRoute("https://landing-\(host!)/inbox/logo.png", StubbedResponse(body: png))
        routes.append("https://landing-\(host!)/inbox/logo.png")

        let data = try await fetcher.fetchIcon(for: url("/"))

        XCTAssertEqual(data, png)
    }

    func testFallsBackToFaviconIcoWhenThePageDeclaresNothingOrTheDeclaredIconFails() async throws {
        let ico = try pngData(letter: "F")
        route("/", StubbedResponse(html: "<html><head></head></html>"))
        route("/favicon.ico", StubbedResponse(body: ico))
        let none = try await fetcher.fetchIcon(for: url("/"))
        XCTAssertEqual(none, ico)

        route("/", StubbedResponse(html: #"<link rel="icon" href="/gone.png">"#))
        route("/gone.png", StubbedResponse(status: 404))
        let declaredFails = try await fetcher.fetchIcon(for: url("/"))
        XCTAssertEqual(declaredFails, ico)
    }

    func testNilWhenThePageIsNotSuccessfulOrNothingDecodes() async throws {
        route("/down", StubbedResponse(status: 503, body: Data("<link rel=icon href=/i.png>".utf8)))
        route("/i.png", StubbedResponse(body: try pngData(letter: "X")))
        let serverError = try await fetcher.fetchIcon(for: url("/down"))
        XCTAssertNil(serverError)
        XCTAssertEqual(StubURLProtocol.requests(forHost: host).map(\.url), [url("/down")], "a failed page stops the search")

        route("/junk", StubbedResponse(html: #"<link rel="icon" href="/junk.png">"#))
        route("/junk.png", StubbedResponse(body: Data("not an image".utf8)))
        route("/favicon.ico", StubbedResponse(status: 404))
        let undecodable = try await fetcher.fetchIcon(for: url("/junk"))
        XCTAssertNil(undecodable)
    }

    func testAnUnreachableIconCandidateMovesOnAndAnUnreachablePageThrows() async throws {
        let png = try pngData(letter: "U")
        route("/", StubbedResponse(html: #"<link rel="icon" href="https://unrouted-\#(host!)/x.png">"#))
        route("/favicon.ico", StubbedResponse(body: png))
        let data = try await fetcher.fetchIcon(for: url("/"))
        XCTAssertEqual(data, png)

        do {
            _ = try await fetcher.fetchIcon(for: URL(string: "https://nothing-\(host!)/")!)
            XCTFail("an unreachable page should throw")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotFindHost)
        }
    }

    func testOnlyHTTPSAndHTTPPagesAreFetched() async throws {
        let ftp = try await fetcher.fetchIcon(for: URL(string: "ftp://\(host!)/")!)
        let file = try await fetcher.fetchIcon(for: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertNil(ftp)
        XCTAssertNil(file)
        XCTAssertTrue(StubURLProtocol.requests(forHost: host).isEmpty)
    }

    func testThePageIsCutAtOneMebibyteAndAnOversizedIconIsRefused() async throws {
        let late = #"<link rel="icon" href="/late.png">"#
        route("/", StubbedResponse(html: String(repeating: " ", count: URLSessionWebIconFetcher.maxBytes) + late))
        route("/late.png", StubbedResponse(body: try pngData(letter: "L")))
        route("/favicon.ico", StubbedResponse(status: 404))
        let ignored = try await fetcher.fetchIcon(for: url("/"))
        XCTAssertNil(ignored, "a link after the first MiB is not read")
        XCTAssertFalse(StubURLProtocol.requests(forHost: host).contains { $0.url == url("/late.png") })

        route("/huge", StubbedResponse(html: #"<link rel="icon" href="/huge.png">"#))
        var huge = try pngData(letter: "H")
        huge.append(Data(count: URLSessionWebIconFetcher.maxBytes))
        route("/huge.png", StubbedResponse(body: huge))
        let refused = try await fetcher.fetchIcon(for: url("/huge"))
        XCTAssertNil(refused, "an icon over 1 MiB is refused, not truncated")
    }
}
