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
}
