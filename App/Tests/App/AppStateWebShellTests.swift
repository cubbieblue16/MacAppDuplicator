import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

@MainActor
final class AppStateWebShellTests: XCTestCase {
    private func makeState(webShellBinary: URL?) -> (AppState, suite: String, defaults: UserDefaults) {
        let (defaults, suite) = makeTestDefaults()
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: "Ad-hoc")
        let state = AppState(
            settings: settings, library: ShortcutLibrary(settings: settings, monitor: RunningShortcutMonitor()),
            launcherBinary: URL(fileURLWithPath: "/x/Contents/Resources/Launcher"), webShellBinary: webShellBinary
        )
        return (state, suite, defaults)
    }

    func testBuilderDefaultsTheWebShellNextToTheLauncher() {
        let (state, suite, defaults) = makeState(webShellBinary: nil)
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(state.builder.webShellBinary.path, "/x/Contents/Resources/WebShell")
        XCTAssertEqual(state.builder.launcherBinary.path, "/x/Contents/Resources/Launcher")
    }

    func testBuilderUsesAnExplicitWebShell() {
        let (state, suite, defaults) = makeState(webShellBinary: URL(fileURLWithPath: "/elsewhere/WebShell"))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(state.builder.webShellBinary.path, "/elsewhere/WebShell")
    }
}
