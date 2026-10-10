import AppKit
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

    func testFirstLetter() {
        XCTAssertEqual(IconRenderer.firstLetter(for: "WhatsApp Work"), "W")
        XCTAssertEqual(IconRenderer.firstLetter(for: "  slack"), "S")
        XCTAssertEqual(IconRenderer.firstLetter(for: "élan"), "É")
        XCTAssertEqual(IconRenderer.firstLetter(for: "   "), "?")
    }

    func testLetterTileICNSIsValid() throws {
        let out = dir.appending(path: "letter.icns")
        try IconRenderer.writeICNS(letterTileFor: "Mail Work", to: out)
        XCTAssertEqual(String(decoding: try Data(contentsOf: out).prefix(4), as: UTF8.self), "icns")
    }

    private func transparentPNG(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func isICNS(_ url: URL) throws -> Bool {
        String(decoding: try Data(contentsOf: url).prefix(4), as: UTF8.self) == "icns"
    }

    func testWriteICNSFromPNGDataProducesICNS() throws {
        let out = dir.appending(path: "data.icns")
        try IconRenderer.writeICNS(fromImageData: try transparentPNG(width: 180, height: 180), to: out)
        XCTAssertTrue(try isICNS(out))
    }

    func testWriteICNSFromNonSquareDataIsCentredNotStretched() throws {
        let out = dir.appending(path: "wide.icns")
        try IconRenderer.writeICNS(fromImageData: try transparentPNG(width: 300, height: 100), to: out)
        XCTAssertTrue(try isICNS(out))
    }

    func testWriteICNSFromICOUsesThePayloadImage() throws {
        // A one-image ICO whose payload is a PNG (the format sites ship as /favicon.ico).
        let payload = try transparentPNG(width: 32, height: 32)
        var ico = Data([0, 0, 1, 0, 1, 0])                        // reserved, type 1 (icon), one image
        ico.append(contentsOf: [32, 32, 0, 0, 1, 0, 32, 0])       // width, height, colours, reserved, planes, bit depth
        var size = UInt32(payload.count).littleEndian
        var offset = UInt32(22).littleEndian
        ico.append(Data(bytes: &size, count: 4))
        ico.append(Data(bytes: &offset, count: 4))
        ico.append(payload)
        let out = dir.appending(path: "favicon.icns")
        try IconRenderer.writeICNS(fromImageData: ico, to: out)
        XCTAssertTrue(try isICNS(out))
    }

    func testWriteICNSFromGarbageDataThrowsUnreadableImage() {
        let out = dir.appending(path: "bad.icns")
        XCTAssertThrowsError(try IconRenderer.writeICNS(fromImageData: Data("not an image".utf8), to: out)) { error in
            guard case IconRenderer.RenderError.unreadableImage = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }
}
