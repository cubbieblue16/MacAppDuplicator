import XCTest
@testable import DuplicatorCore

final class AppInspectorTests: XCTestCase {
    private func inspect(_ fixture: FixtureBundle) throws -> InspectedApp {
        try AppInspector().inspect(appAt: fixture.write(in: makeTemporaryDirectory()))
    }

    private func family(_ fixture: FixtureBundle) throws -> AppFamily {
        try inspect(fixture).family
    }

    // MARK: Family detection (spec §4.2)

    func testToDesktopByRuntimeConfig() throws {
        XCTAssertEqual(try family(FixtureBundle(files: ["Resources/app.asar", "Resources/todesktop-runtime-config.json"])), .todesktop)
    }

    func testToDesktopByInfoPlistKey() throws {
        XCTAssertEqual(try family(FixtureBundle(info: ["ToDesktopVersion": "1.0.0"], files: ["Resources/app.asar"])), .todesktop)
    }

    func testToDesktopIsCheckedBeforeElectron() throws {
        let fixture = FixtureBundle(
            files: ["Resources/app.asar", "Resources/todesktop-runtime-config.json"],
            directories: ["Frameworks/Electron Framework.framework"]
        )
        XCTAssertEqual(try family(fixture), .todesktop)
    }

    func testAsarAloneIsNotToDesktop() throws {
        XCTAssertEqual(try family(FixtureBundle(files: ["Resources/app.asar"])), .native)
    }

    func testElectronByFramework() throws {
        XCTAssertEqual(try family(FixtureBundle(directories: ["Frameworks/Electron Framework.framework"])), .electron)
    }

    func testElectronIsCheckedBeforeChromiumMarkers() throws {
        let fixture = FixtureBundle(directories: [
            "Frameworks/Electron Framework.framework/Versions/A/Helpers/Claude Helper (GPU).app",
        ])
        XCTAssertEqual(try family(fixture), .electron)
    }

    func testChromiumByGPUHelper() throws {
        let fixture = FixtureBundle(directories: [
            "Frameworks/Google Chrome Framework.framework/Versions/141.0.7390.55/Helpers/Google Chrome Helper (GPU).app",
        ])
        XCTAssertEqual(try family(fixture), .chromium)
    }

    func testChromiumBySwiftShaderOnly() throws {
        let fixture = FixtureBundle(files: [
            "Frameworks/Brave Browser Framework.framework/Versions/141.1.83.112/Libraries/libvk_swiftshader.dylib",
        ])
        XCTAssertEqual(try family(fixture), .chromium)
    }

    func testLibEGLAloneIsNotChromium() throws {
        let fixture = FixtureBundle(files: [
            "Frameworks/Some Framework.framework/Versions/A/Libraries/libEGL.dylib",
        ])
        XCTAssertEqual(try family(fixture), .native)
    }

    func testFirefoxByXUL() throws {
        XCTAssertEqual(try family(FixtureBundle(files: ["Resources/omni.ja", "MacOS/XUL"])), .firefox)
    }

    func testFirefoxByApplicationIni() throws {
        XCTAssertEqual(try family(FixtureBundle(files: ["Resources/omni.ja", "Resources/application.ini"])), .firefox)
    }

    func testOmniJaAloneIsNotFirefox() throws {
        XCTAssertEqual(try family(FixtureBundle(files: ["Resources/omni.ja"])), .native)
    }

    func testEclipseByEclipseIni() throws {
        XCTAssertEqual(try family(FixtureBundle(files: ["Eclipse/eclipse.ini"])), .eclipse)
    }

    func testEclipseByConfigIni() throws {
        XCTAssertEqual(try family(FixtureBundle(files: ["Eclipse/configuration/config.ini"])), .eclipse)
    }

    func testEclipseByInfoPlistKey() throws {
        XCTAssertEqual(try family(FixtureBundle(info: ["Eclipse": ["-keyring"]])), .eclipse)
    }

    func testNoMarkersIsNative() throws {
        XCTAssertEqual(try family(FixtureBundle()), .native)
    }

    // MARK: Identity, icon, LSEnvironment

    func testReportsIdentityPathsAndLSEnvironment() throws {
        let directory = try makeTemporaryDirectory()
        let bundle = try FixtureBundle(
            name: "Target",
            bundleIdentifier: "com.example.target",
            info: [
                "CFBundleDisplayName": "Target Display",
                "CFBundleName": "Target Name",
                "CFBundleShortVersionString": "2.5",
                "CFBundleVersion": "250",
                "LSEnvironment": ["MallocNanoZone": "0", "NUMERIC": 1],
            ]
        ).write(in: directory)
        let app = try AppInspector().inspect(appAt: bundle)
        XCTAssertEqual(app.bundleURL, bundle.standardizedFileURL)
        XCTAssertEqual(app.bundleIdentifier, "com.example.target")
        XCTAssertEqual(app.name, "Target Display")
        XCTAssertEqual(app.version, "2.5")
        XCTAssertEqual(app.executableURL.path, bundle.appending(path: "Contents/MacOS/Target").path)
        XCTAssertEqual(app.lsEnvironment, ["MallocNanoZone": "0"])
        XCTAssertNil(app.iconFileURL)
    }

    func testNameAndVersionFallbacks() throws {
        XCTAssertEqual(try inspect(FixtureBundle(info: ["CFBundleName": "Bundle Name"])).name, "Bundle Name")
        let bare = try inspect(FixtureBundle(name: "Bare"))
        XCTAssertEqual(bare.name, "Bare")
        XCTAssertEqual(bare.version, "")
        XCTAssertEqual(try inspect(FixtureBundle(info: ["CFBundleVersion": "42"])).version, "42")
    }

    func testIconNameWithoutExtensionGetsIcns() throws {
        let app = try inspect(FixtureBundle(info: ["CFBundleIconFile": "AppIcon"], files: ["Resources/AppIcon.icns"]))
        XCTAssertEqual(app.iconFileURL?.lastPathComponent, "AppIcon.icns")
    }

    func testIconNameWithExtensionIsUsedAsIs() throws {
        let app = try inspect(FixtureBundle(info: ["CFBundleIconFile": "electron.icns"], files: ["Resources/electron.icns"]))
        XCTAssertEqual(app.iconFileURL?.lastPathComponent, "electron.icns")
    }

    func testMissingIconFileIsNil() throws {
        XCTAssertNil(try inspect(FixtureBundle(info: ["CFBundleIconFile": "AppIcon"])).iconFileURL)
    }

    // MARK: Bundle validation (spec §9)

    private func assertNotAnAppBundle(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try AppInspector().inspect(appAt: url), file: file, line: line) { error in
            guard case LauncherError.notAnAppBundle(let path) = error else {
                return XCTFail("expected notAnAppBundle, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(path, url.standardizedFileURL.path, file: file, line: line)
        }
    }

    func testRejectsInvalidBundles() throws {
        let directory = try makeTemporaryDirectory()
        let fileManager = FileManager.default

        let wrongExtension = directory.appending(path: "Plain.bundle", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: wrongExtension, withIntermediateDirectories: true)
        assertNotAnAppBundle(wrongExtension)

        let regularFile = directory.appending(path: "File.app", directoryHint: .notDirectory)
        try Data().write(to: regularFile)
        assertNotAnAppBundle(regularFile)

        let noInfoPlist = directory.appending(path: "NoInfo.app", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: noInfoPlist.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        assertNotAnAppBundle(noInfoPlist)

        let noIdentifier = try FixtureBundle(name: "NoIdentifier", bundleIdentifier: "").write(in: directory)
        assertNotAnAppBundle(noIdentifier)

        let noExecutableName = try FixtureBundle(name: "NoExecutableName", info: ["CFBundleExecutable": ""]).write(in: directory)
        assertNotAnAppBundle(noExecutableName)

        let missingExecutable = try FixtureBundle(name: "MissingExecutable").write(in: directory)
        try fileManager.removeItem(at: missingExecutable.appending(path: "Contents/MacOS/MissingExecutable"))
        assertNotAnAppBundle(missingExecutable)

        let notExecutable = try FixtureBundle(name: "NotExecutable").write(in: directory)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: notExecutable.appending(path: "Contents/MacOS/NotExecutable").path)
        assertNotAnAppBundle(notExecutable)

        let executableIsDirectory = try FixtureBundle(name: "DirectoryExecutable").write(in: directory)
        let executablePath = executableIsDirectory.appending(path: "Contents/MacOS/DirectoryExecutable")
        try fileManager.removeItem(at: executablePath)
        try fileManager.createDirectory(at: executablePath, withIntermediateDirectories: true)
        assertNotAnAppBundle(executableIsDirectory)
    }

    // MARK: Code signature (spec §4.1, §4.2)

    func testUnsignedFixtureHasNoSigningFacts() throws {
        let app = try inspect(FixtureBundle())
        XCTAssertFalse(app.isSandboxed)
        XCTAssertFalse(app.isPlatformBinary)
        XCTAssertFalse(app.hasLaunchConstraints)
        XCTAssertEqual(app.warnings, [])
    }

    func testAdHocSignedFixtureIsNotAPlatformBinary() throws {
        let bundle = try FixtureBundle(name: "AdHoc").writeSigned(in: makeTemporaryDirectory())
        let app = try AppInspector().inspect(appAt: bundle)
        XCTAssertFalse(app.isPlatformBinary)
        XCTAssertFalse(app.isSandboxed)
        XCTAssertFalse(app.hasLaunchConstraints)
        XCTAssertEqual(app.warnings, [])
    }

    func testSandboxEntitlementIsDetected() throws {
        let directory = try makeTemporaryDirectory()
        let entitlements = try writePropertyList(["com.apple.security.app-sandbox": true], named: "sandbox.entitlements", in: directory)
        let bundle = try FixtureBundle(name: "Sandboxed").writeSigned(in: directory, extraCodesignArguments: ["--entitlements", entitlements.path])
        let app = try AppInspector().inspect(appAt: bundle)
        XCTAssertTrue(app.isSandboxed)
        XCTAssertFalse(app.isPlatformBinary)
    }

    func testLaunchConstraintIsDetected() throws {
        let directory = try makeTemporaryDirectory()
        let constraint = try writePropertyList(["signing-identifier": "lc_self"], named: "constraint.plist", in: directory)
        let bundle = try FixtureBundle(name: "Constrained").writeSigned(in: directory, extraCodesignArguments: ["--launch-constraint-self", constraint.path])
        let app = try AppInspector().inspect(appAt: bundle)
        XCTAssertTrue(app.hasLaunchConstraints)
        XCTAssertFalse(app.isPlatformBinary)
        XCTAssertFalse(app.isSandboxed)
    }

    func testUnreadableSignatureIsAWarningNotAFailure() {
        let facts = AppInspector.signingFacts(bundleURL: URL(filePath: "/nonexistent/Missing.app", directoryHint: .isDirectory))
        XCTAssertFalse(facts.isSandboxed)
        XCTAssertEqual(facts.warnings.count, 1)
        XCTAssertTrue(facts.warnings[0].hasPrefix("Could not read the code signature of Missing.app (OSStatus "))
        XCTAssertTrue(facts.warnings[0].hasSuffix("); treated as not sandboxed."))
    }

    // MARK: Real apps (skipped when absent)

    func testTextEditIsASandboxedPlatformBinary() throws {
        let path = "/System/Applications/TextEdit.app"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "TextEdit is not installed")
        let app = try AppInspector().inspect(appAt: URL(filePath: path, directoryHint: .isDirectory))
        XCTAssertEqual(app.bundleIdentifier, "com.apple.TextEdit")
        XCTAssertEqual(app.family, .native)
        XCTAssertTrue(app.isSandboxed)
        XCTAssertTrue(app.isPlatformBinary)
        XCTAssertEqual(app.iconFileURL?.lastPathComponent, "AppIcon.icns")
    }

    func testTerminalIsAPlatformBinaryWithoutSandbox() throws {
        let path = "/System/Applications/Utilities/Terminal.app"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "Terminal is not installed")
        let app = try AppInspector().inspect(appAt: URL(filePath: path, directoryHint: .isDirectory))
        XCTAssertEqual(app.family, .native)
        XCTAssertFalse(app.isSandboxed)
        XCTAssertTrue(app.isPlatformBinary)
    }

    func testClaudeDesktopIsElectron() throws {
        let path = "/Applications/Claude.app"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "Claude Desktop is not installed")
        let app = try AppInspector().inspect(appAt: URL(filePath: path, directoryHint: .isDirectory))
        XCTAssertEqual(app.bundleIdentifier, "com.anthropic.claudefordesktop")
        XCTAssertEqual(app.family, .electron)
        XCTAssertFalse(app.isSandboxed)
        XCTAssertFalse(app.isPlatformBinary)
        XCTAssertFalse(app.hasLaunchConstraints)
    }
}
