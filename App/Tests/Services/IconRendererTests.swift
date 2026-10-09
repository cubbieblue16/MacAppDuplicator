import XCTest
@testable import MacAppDuplicator

final class IconRendererTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try makeAppTemporaryDirectory() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    func testInitials() {
        XCTAssertEqual(IconRenderer.initials(for: "Claude Work"), "CW")
        XCTAssertEqual(IconRenderer.initials(for: "slack"), "S")
        XCTAssertEqual(IconRenderer.initials(for: "Visual Studio Code"), "VS")
        XCTAssertEqual(IconRenderer.initials(for: "   "), "?")
    }

    func testGeneratedTileHasRequestedSizeAndAlpha() {
        let image = IconRenderer.generatedTile(initials: "CW", size: 128)
        XCTAssertEqual(image.width, 128)
        XCTAssertEqual(image.height, 128)
        XCTAssertNotEqual(image.alphaInfo, .none)
    }

    func testWriteICNSGeneratedProducesValidICNS() throws {
        let out = dir.appending(path: "gen.icns")
        try IconRenderer.writeICNS(generatedFor: "Claude Work", to: out)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "icns")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    func testWriteICNSFromICNSFileCopiesBytes() throws {
        let source = dir.appending(path: "src.icns")
        try Data("icns-fake".utf8).write(to: source)
        let out = dir.appending(path: "copy.icns")
        try IconRenderer.writeICNS(fromImageFile: source, to: out)
        XCTAssertEqual(try Data(contentsOf: out), Data("icns-fake".utf8))
    }

    func testWriteICNSFromPNGFileConverts() throws {
        let png = dir.appending(path: "src.png")
        let cg = IconRenderer.generatedTile(initials: "P", size: 256)
        let rep = NSBitmapImageRep(cgImage: cg)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: png)
        let out = dir.appending(path: "conv.icns")
        try IconRenderer.writeICNS(fromImageFile: png, to: out)
        XCTAssertEqual(String(decoding: try Data(contentsOf: out).prefix(4), as: UTF8.self), "icns")
    }
}
