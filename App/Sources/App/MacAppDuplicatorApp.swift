import SwiftUI

@main
struct MacAppDuplicatorApp: App {
    @State private var appState: AppState

    init() {
        let settings = AppSettings(defaultSigningIdentity: SigningIdentities.defaultIdentity(from: SigningIdentities.load()))
        let library = ShortcutLibrary(settings: settings)
        // `EmbeddedLauncher.url()` throws only when the Embed Launcher build phase did not run. Keep the expected path
        // so the window still opens, and say up front why every write will fail.
        let launcherBinary: URL
        var launcherError: Error?
        do {
            launcherBinary = try EmbeddedLauncher.url()
        } catch {
            launcherBinary = Bundle.main.bundleURL.appending(path: "Contents/Resources/Launcher", directoryHint: .notDirectory)
            launcherError = error
        }
        let state = AppState(settings: settings, library: library, launcherBinary: launcherBinary)
        if let launcherError { state.present(launcherError, context: "Could not find the launcher") }
        _appState = State(initialValue: state)
    }

    var body: some Scene {
        WindowGroup("App Duplicator") {
            ContentView()
                .environment(appState)
                .frame(minWidth: 820, minHeight: 520)
                .task {
                    // As the unit-test host the app must not scan or watch the real library folders.
                    if !Self.isTestHost { appState.library.start() }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Shortcut…") { appState.isWizardPresented = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .help) {
                KnownLimitationsMenuItem()
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }

        Window("Known Limitations", id: "known-limitations") {
            KnownLimitationsView()
                .frame(minWidth: 520, minHeight: 420)
        }
    }

    /// xcodebuild sets this for the process that hosts the test bundle.
    private static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

/// Help menu item. `openWindow` is read inside a view in the menu content (the documented pattern for window actions)
/// rather than through an `@Environment` property on the `App` struct.
private struct KnownLimitationsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Known Limitations") { openWindow(id: "known-limitations") }
    }
}
