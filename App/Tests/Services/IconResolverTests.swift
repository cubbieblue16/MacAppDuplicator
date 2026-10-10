import AppKit
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class IconResolverTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try makeAppTemporaryDirectory() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    private func app(iconFile: URL?) -> InspectedApp {
        InspectedApp(
            bundleURL: dir.appending(path: "T.app"), bundleIdentifier: "com.example.t", name: "T", version: "1",
            executableURL: dir.appending(path: "T.app/Contents/MacOS/T"), family: .native, isSandboxed: false,
            iconFileURL: iconFile, isPlatformBinary: false, hasLaunchConstraints: false, lsEnvironment: [:], warnings: []
        )
    }

    func testCopiedUsesTargetIconOrNil() throws {
        let icon = dir.appending(path: "t.icns")
        try Data([1]).write(to: icon)
        var config = makeConfig()
        config.iconMode = .copied
        XCTAssertEqual(try IconResolver.iconFile(for: config, app: app(iconFile: icon), scratchDirectory: dir), icon)
        XCTAssertNil(try IconResolver.iconFile(for: config, app: app(iconFile: nil), scratchDirectory: dir))
    }

    func testCustomConvertsIntoScratchAndFailsWhenMissing() throws {
        let custom = dir.appending(path: "custom.icns")
        try Data("icns-fake".utf8).write(to: custom)
        var config = makeConfig()
        config.iconMode = .custom
        config.customIconPath = custom.path
        let result = try XCTUnwrap(try IconResolver.iconFile(for: config, app: app(iconFile: nil), scratchDirectory: dir))
        XCTAssertEqual(result.pathExtension, "icns")
        XCTAssertTrue(result.path.hasPrefix(dir.path))
        XCTAssertNotEqual(result, custom)

        config.customIconPath = dir.appending(path: "nope.png").path
        XCTAssertThrowsError(try IconResolver.iconFile(for: config, app: app(iconFile: nil), scratchDirectory: dir)) { error in
            guard case IconResolver.IconError.customFileMissing = error else { return XCTFail("\(error)") }
        }
    }

    /// Final review M12: a hand-edited slug such as `../../escaped` must not steer scratch files out of the scratch folder.
    func testScratchNamesAreFixedAndIgnoreTheSlug() throws {
        let scratch = dir.appending(path: "nested/scratch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let source = dir.appending(path: "source.icns")
        try Data("icns-fake".utf8).write(to: source)
        var config = makeConfig(name: "Claude Work")
        config.slug = "../../escaped"

        config.iconMode = .custom
        config.customIconPath = source.path
        let custom = try XCTUnwrap(try IconResolver.iconFile(for: config, app: app(iconFile: nil), scratchDirectory: scratch))
        XCTAssertEqual(custom.deletingLastPathComponent().standardizedFileURL.path, scratch.standardizedFileURL.path)
        XCTAssertEqual(custom.lastPathComponent, "custom-icon.icns")

        config.iconMode = .generated
        let generated = try XCTUnwrap(try IconResolver.iconFile(for: config, app: app(iconFile: nil), scratchDirectory: scratch))
        XCTAssertEqual(generated.deletingLastPathComponent().standardizedFileURL.path, scratch.standardizedFileURL.path)
        XCTAssertEqual(generated.lastPathComponent, "generated-icon.icns")

        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: scratch.path)), ["custom-icon.icns", "generated-icon.icns"])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["nested", "source.icns"])
    }

    func testGeneratedRendersTile() throws {
        var config = makeConfig(name: "Claude Work")
        config.iconMode = .generated
        let result = try XCTUnwrap(try IconResolver.iconFile(for: config, app: app(iconFile: nil), scratchDirectory: dir))
        XCTAssertEqual(String(decoding: try Data(contentsOf: result).prefix(4), as: UTF8.self), "icns")
    }

    private func webConfig(mode: IconMode) -> ShortcutConfig {
        var config = makeWebConfig(name: "Chat Work", url: "https://chat.example.test/")
        config.iconMode = mode
        return config
    }

    private func png() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testWebCopiedWithFetchedBytesWritesFetchedICNS() throws {
        let url = try XCTUnwrap(IconResolver.webAppIconFile(for: webConfig(mode: .copied), webIconData: try png(), existingIcon: nil, scratchDirectory: dir))
        XCTAssertEqual(url.lastPathComponent, "web-fetched-icon.icns")
        XCTAssertEqual(String(decoding: try Data(contentsOf: url).prefix(4), as: UTF8.self), "icns")
    }

    func testWebCopiedWithUndecodableBytesFallsBackToLetterTile() throws {
        let url = try XCTUnwrap(IconResolver.webAppIconFile(for: webConfig(mode: .copied), webIconData: Data("<html>".utf8), existingIcon: nil, scratchDirectory: dir))
        XCTAssertEqual(url.lastPathComponent, "web-letter-icon.icns")
    }

    func testWebCopiedWithoutBytesKeepsTheExistingIcon() throws {
        let existing = dir.appending(path: "old.icns")
        try Data("keep me".utf8).write(to: existing)
        let url = try XCTUnwrap(IconResolver.webAppIconFile(for: webConfig(mode: .copied), webIconData: nil, existingIcon: existing, scratchDirectory: dir))
        XCTAssertEqual(try Data(contentsOf: url), Data("keep me".utf8))
        XCTAssertNotEqual(url, existing, "the icon is copied into scratch so replacing the old bundle cannot delete it")
    }

    func testWebCopiedWithNothingGetsLetterTile() throws {
        let url = try XCTUnwrap(IconResolver.webAppIconFile(for: webConfig(mode: .copied), webIconData: nil, existingIcon: nil, scratchDirectory: dir))
        XCTAssertEqual(url.lastPathComponent, "web-letter-icon.icns")
    }

    func testWebGeneratedIgnoresFetchedBytesAndCustomRequiresTheFile() throws {
        let tile = try XCTUnwrap(IconResolver.webAppIconFile(for: webConfig(mode: .generated), webIconData: try png(), existingIcon: nil, scratchDirectory: dir))
        XCTAssertEqual(tile.lastPathComponent, "web-letter-icon.icns")

        var custom = webConfig(mode: .custom)
        custom.customIconPath = dir.appending(path: "missing.png").path
        XCTAssertThrowsError(try IconResolver.webAppIconFile(for: custom, webIconData: nil, existingIcon: nil, scratchDirectory: dir)) { error in
            guard case IconResolver.IconError.customFileMissing = error else { return XCTFail("\(error)") }
        }
    }
}
