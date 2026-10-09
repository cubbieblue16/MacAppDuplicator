import Foundation

struct KnownLimitation: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
}

/// Spec §11. Shown in the Known Limitations window and linked from the wizard's compatibility line.
enum KnownLimitations {
    static let all: [KnownLimitation] = [
        KnownLimitation(
            id: "launch-constraints",
            title: "Apple apps and launch-constrained binaries cannot use Dock Shortcut",
            detail: "macOS refuses to run Apple's own apps, and third-party apps that opt into launch constraints, from any process that is not their own bundle. App Duplicator detects this and switches the shortcut to System Launch, which starts a new instance through Launch Services. The Dock then shows the target's own icon and name instead of the shortcut's."
        ),
        KnownLimitation(
            id: "sandboxed-apps",
            title: "Sandboxed apps ignore the HOME override",
            detail: "The App Sandbox fixes an app's container at ~/Library/Containers/<bundle id>, so two copies of a sandboxed app always share data. Shortcuts for sandboxed apps still work for a second Dock icon, but their data stays shared."
        ),
        KnownLimitation(
            id: "single-instance",
            title: "Some apps refuse to run twice",
            detail: "Apps that enforce a single instance with a lock file or a distributed notification exit immediately when a copy is already running, or hand the request to the existing instance. Nothing outside the app can change that."
        ),
        KnownLimitation(
            id: "dock-redraw",
            title: "The Dock tile keeps the shortcut's icon only until the app relaunches itself",
            detail: "Dock Shortcut relies on the Dock never redrawing a tile after the shortcut hands over to the target. Apps that relaunch themselves (for example after an update) come back under their own identity."
        ),
        KnownLimitation(
            id: "login-items",
            title: "Login items and helpers belong to the original app",
            detail: "Background helpers, login items and launch agents registered by the target run once, for the original bundle identifier. A shortcut does not get its own copy of them."
        ),
        KnownLimitation(
            id: "updates",
            title: "The target app updates itself as usual; the shortcut does not",
            detail: "Shortcuts point at the installed app, so an update to the app is picked up on the next launch. A shortcut built with an older App Duplicator launcher shows Needs rebuild in the sidebar; use Rebuild All to refresh it."
        ),
        KnownLimitation(
            id: "notifications",
            title: "Notifications are attributed to the original app",
            detail: "Notification Center keys on the running process's bundle identifier, which after the hand-over is the target's. Both copies share one notification settings entry."
        ),
        KnownLimitation(
            id: "file-associations",
            title: "Shortcuts do not register file types or URL schemes",
            detail: "Documents and links keep opening in the original app. Shortcuts are deliberately invisible to Launch Services' handler tables so they never hijack the target's associations."
        ),
        KnownLimitation(
            id: "electron-dark-mode",
            title: "Forcing dark mode only works for Chromium-based apps",
            detail: "The Dark appearance option adds Chromium's dark-mode flag, which Electron, Chromium and ToDesktop apps honour. Native apps follow the system appearance; only Light can be forced for them."
        ),
    ]
}
