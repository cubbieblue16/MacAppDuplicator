import AppKit
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
