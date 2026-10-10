import CompatProfiles
import SwiftUI

@main
struct MacAppDuplicatorApp: App {
    @State private var appState: AppState

    init() {
        // As the unit-test host the app uses a throwaway defaults suite and never runs `security` (final review M15).
        let isTestHost = Self.isTestHost
        let settings = AppSettings(defaults: LaunchEnvironment.settingsDefaults(isTestHost: isTestHost),
                                   defaultSigningIdentity: AppSettings.adHocIdentityName)
        // As the test host the app never fetches profiles, and its cache path is a temporary file nothing writes.
        let fetcher: any ProfilesFetching = isTestHost ? DisabledProfilesFetcher() : URLSessionProfilesFetcher()
        let profiles = ProfilesModel(bundledURL: Bundle.main.url(forResource: "profiles", withExtension: "json"),
                                     cacheURL: LaunchEnvironment.profilesCacheURL(isTestHost: isTestHost),
                                     fetcher: fetcher)
        if !isTestHost {
            // `security find-identity` runs off the main thread; until it returns, new shortcuts default to ad hoc.
            Task { await settings.loadDefaultSigningIdentity() }
            // The profiles are read off the main thread too; until they load, no target has a profile.
            Task { await profiles.load() }
        }
        let library = ShortcutLibrary(settings: settings)
        // `EmbeddedLauncher.url()` / `EmbeddedWebShell.url()` throw only when the matching build phase did not run. Keep
        // the expected paths so the window still opens, and say up front why every write will fail.
        let launcherBinary: URL
        var launcherError: Error?
        do {
            launcherBinary = try EmbeddedLauncher.url()
        } catch {
            launcherBinary = Bundle.main.bundleURL.appending(path: "Contents/Resources/Launcher", directoryHint: .notDirectory)
            launcherError = error
        }
        let webShellBinary: URL
        var webShellError: Error?
        do {
            webShellBinary = try EmbeddedWebShell.url()
        } catch {
            webShellBinary = Bundle.main.bundleURL.appending(path: "Contents/Resources/WebShell", directoryHint: .notDirectory)
            webShellError = error
        }
        let state = AppState(settings: settings, library: library, launcherBinary: launcherBinary, webShellBinary: webShellBinary, profiles: profiles)
        if let launcherError {
            state.present(launcherError, context: "Could not find the launcher")
        } else if let webShellError {
            state.present(webShellError, context: "Could not find the web shell")
        }
        _appState = State(initialValue: state)
    }

    var body: some Scene {
        WindowGroup("App Duplicator") {
            ContentView()
                .environment(appState)
                .frame(minWidth: 820, minHeight: 720)
                .task {
                    // As the unit-test host the app must not scan or watch the real library folders.
                    if !Self.isTestHost { appState.library.start() }
                }
                .onChange(of: appState.settings.allLibraryFolders) {
                    // A folder added, removed or changed in Settings is watched and scanned at once (final review I4).
                    if !Self.isTestHost { appState.library.start() }
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check Profile Updates") { Task { await appState.checkProfileUpdates() } }
                    .disabled(appState.profiles.isChecking)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Shortcut…") { appState.isWizardPresented = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(before: .toolbar) {
                // The watcher sees bundles added, removed or renamed, not edits inside a bundle (final review M8).
                Button("Refresh") { Task { await appState.library.rescan() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(after: .help) {
                KnownLimitationsMenuItem()
            }
        }
        // Under the unit-test host no window may open or be restored: the main window's frame autosave wrote the
        // real com.mikekuta.MacAppDuplicator defaults domain on every test run (re-review Minor 7).
        .defaultLaunchBehavior(Self.isTestHost ? .suppressed : .automatic)
        .restorationBehavior(Self.isTestHost ? .disabled : .automatic)

        Settings {
            SettingsView()
                .environment(appState)
        }

        Window("Known Limitations", id: "known-limitations") {
            KnownLimitationsView()
                .frame(minWidth: 520, minHeight: 420)
        }
        .defaultLaunchBehavior(Self.isTestHost ? .suppressed : .automatic)
        .restorationBehavior(Self.isTestHost ? .disabled : .automatic)
    }

    /// True for the process that hosts the test bundle (`LaunchEnvironment.isTestHost`).
    private static var isTestHost: Bool {
        LaunchEnvironment.isTestHost()
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
