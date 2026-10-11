import Foundation

struct KnownLimitation: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
}

/// Spec §11 ("documented in-app and README"): one entry per §11 bullet, plus the app-specific limits that the README's
/// list also carries (single instance, login items, updates). Phase 3 adds the profile limits (advisory badges, partial
/// profiles, manual updates from one host, sandboxed badges, numbered slugs, export's Trash replacement). Phase 4 adds
/// the four web app limits (passkeys, zoom storage, notification permission, pop-up and off-site links). Phase 5 adds
/// the five launcher limits (terminal AppleScript, terminal shell history, no running state for files or commands,
/// Ghostty path). Phase 6 adds the six helper limits (running until the helper exits, erase confirmation and refusals,
/// AppleLanguages, colour menu bar icon, New Window command, System Launch helper). Shown in the Known Limitations
/// window and linked from the wizard's compatibility line.
enum KnownLimitations {
    static let all: [KnownLimitation] = [
        KnownLimitation(
            id: "launch-constraints",
            title: "Apple apps and launch-constrained binaries cannot use Dock Shortcut",
            detail: "macOS refuses to run Apple's own apps, and third-party apps that opt into launch constraints, from any process that is not their own bundle. App Duplicator detects this and switches the shortcut to System Launch, which starts a new instance through Launch Services. The Dock then shows the target's own icon and name instead of the shortcut's."
        ),
        KnownLimitation(
            id: "dock-redraw",
            title: "The Dock tile keeps the shortcut's icon until the target draws on it or relaunches itself",
            detail: "In Dock Shortcut mode the Dock keeps the shortcut's name and icon for the life of the process, because it does not redraw a tile when the target checks in with Launch Services; lsappinfo, Activity Monitor and NSRunningApplication report the target app. Any drawing or badge the target puts on its Dock tile (download progress, an unread count) lands on the shortcut's tile and replaces the custom icon until you quit and relaunch the shortcut. Apps that relaunch themselves (for example after an update) come back under their own identity. How the copy appears in Cmd-Tab is untested."
        ),
        KnownLimitation(
            id: "dock-title",
            title: "The Dock title is always the shortcut's bundle file name",
            detail: "The name under the Dock tile comes from the shortcut bundle's file name, so renaming the shortcut is the only way to change it. The alternatives all fail: a display name set through Launch Services (LSDisplayName) is overwritten when the target checks in, hardened-runtime apps ignore CFProcessPath and Electron helpers crash on it, and mirror bundles fail strict code-signature checks."
        ),
        KnownLimitation(
            id: "sandboxed-apps",
            title: "Sandboxed apps ignore the HOME override",
            detail: "The App Sandbox fixes an app's container at ~/Library/Containers/<bundle id>, so two copies of a sandboxed app always share data. Shortcuts for sandboxed apps still work for a second Dock icon, but their data stays shared."
        ),
        KnownLimitation(
            id: "preferences",
            title: "Preferences are shared in every data mode",
            detail: "Settings an app stores through CFPreferences (NSUserDefaults) go to ~/Library/Preferences/<bundle id>.plist in your real home folder whatever the data mode, so they are shared by the original app and all its shortcuts. Profile data for Chromium, Electron and Firefox apps is still separate, because those apps keep it under their user-data directory."
        ),
        KnownLimitation(
            id: "keychain",
            title: "Separate data is not a separate Keychain or macOS user",
            detail: "The HOME override changes where an app keeps its files, not who it runs as. Every copy runs as your macOS user with your login Keychain, so passwords and tokens an app saves in the Keychain under a fixed name are shared by the original app and its shortcuts."
        ),
        KnownLimitation(
            id: "launch-order",
            title: "With data separation Disabled, a shortcut may open the running original",
            detail: "In Disabled data mode a shortcut uses the same data as the original app. Launching the shortcut while the original is running may hand off to the running instance instead of starting a second copy. Use a separate data mode, or launch both copies from two shortcuts."
        ),
        KnownLimitation(
            id: "single-instance",
            title: "Some apps refuse to run twice",
            detail: "Apps that enforce a single instance with a lock file or a distributed notification exit immediately when a copy is already running, or hand the request to the existing instance. Nothing outside the app can change that."
        ),
        KnownLimitation(
            id: "login-items",
            title: "Login items and helpers belong to the original app",
            detail: "Background helpers, login items and launch agents registered by the target run once, for the original bundle identifier. A shortcut does not get its own copy of them."
        ),
        KnownLimitation(
            id: "updates",
            title: "The target app updates itself as usual; the shortcut does not",
            detail: "Shortcuts point at the installed app, so an update to the app is picked up on the next launch. A shortcut built by an older App Duplicator engine version shows Needs rebuild in the sidebar; use Rebuild All to refresh it."
        ),
        KnownLimitation(
            id: "notifications",
            title: "Notifications are attributed to the original app",
            detail: "Notification Center keys on the running process's bundle identifier, which after the hand-over is the target's. Both copies share one notification settings entry, and clicking a notification may bring the wrong copy forward."
        ),
        KnownLimitation(
            id: "oauth-callbacks",
            title: "Browser sign-in returns to the copy that registered last",
            detail: "Apps that sign in through your web browser (OAuth) receive the result through their URL scheme. macOS delivers it to whichever running instance registered that scheme last, which may not be the copy that started the sign-in. Sign in while only one copy is running."
        ),
        KnownLimitation(
            id: "file-associations",
            title: "Shortcuts do not register file types or URL schemes",
            detail: "Shortcut bundles declare no document types or URL schemes, so Launch Services never makes a shortcut the default handler for anything. Once a copy is running, macOS treats it as the target app: links for the target's URL schemes go to whichever running instance registered the scheme last, and a document you open may land in a shortcut's copy rather than the original."
        ),
        KnownLimitation(
            id: "electron-dark-mode",
            title: "Forcing dark mode only works for Chromium-based apps",
            detail: "Force dark (Chromium/Electron only, best effort) adds Chromium's --force-dark-mode flag, which Chromium, Electron and ToDesktop apps honour; an app with its own theme setting may still override it. The option is unavailable for other apps, which follow the system appearance. Light works for every app through -NSRequiresAquaSystemAppearance YES."
        ),
        KnownLimitation(
            id: "profiles-advisory",
            title: "Compatibility profiles are advisory",
            detail: "A profile suggests launch arguments, environment variables and a status for one app. A Verified badge means the profile was checked on one Mac with the app version available then; it is not a guarantee that it works with your version or setup. App Duplicator still inspects the app and builds the launch plan itself, and every value a profile fills in can be changed in the wizard or the editor."
        ),
        KnownLimitation(
            id: "profiles-partial",
            title: "Partial profiles need manual review",
            detail: "A partial profile has not been through the full check (a second account, a separate data folder and two Dock icons), so its arguments and environment may be incomplete. The badge ignores a partial profile and shows Auto, HOME only or Unknown as if there were none. Check the filled-in values and confirm that the copy keeps its own data before you rely on it."
        ),
        KnownLimitation(
            id: "profile-updates",
            title: "Check Profile Updates is manual and fetches from one host",
            detail: "Profiles change only when you choose Check Profile Updates; it never runs automatically and nothing checks in the background. It downloads only from an https address on raw.githubusercontent.com, any other host is refused, and a failed or invalid download leaves the cached profiles untouched. Between checks the app uses the cached copy only when its updated date is later than the profiles bundled with the app."
        ),
        KnownLimitation(
            id: "sandboxed-badge",
            title: "Sandboxed native apps cannot be separated",
            detail: "A sandboxed native app keeps its data in its App Sandbox container whatever the HOME override says, so App Duplicator cannot give a copy its own data. Without a profile its badge is Unknown, never HOME only, and a profile can mark it Unsupported. A shortcut can still give such an app a second Dock icon when the app allows a second instance, but both copies share one set of data."
        ),
        KnownLimitation(
            id: "slug-suffix",
            title: "Shortcuts whose names match get a numbered slug",
            detail: "Each shortcut's bundle identifier and default data folder are built from a slug of its name. When another shortcut already uses that slug, App Duplicator appends -2, -3 and so on, so shortcuts whose names match never share a bundle identifier or a default data folder."
        ),
        KnownLimitation(
            id: "export-replaces",
            title: "Export replaces an existing shortcut by moving it to the Trash",
            detail: "When the export destination already holds a bundle with the same name, App Duplicator moves that bundle to the Trash and writes the exported copy in its place; nothing is deleted outright. If you exported over the wrong bundle, put it back from the Trash."
        ),
        KnownLimitation(
            id: "web-no-passkeys",
            title: "Web apps do not support passkeys",
            detail: "A web app shows its site in an embedded web view that App Duplicator builds into the shortcut. That view cannot sign in with a passkey or a security key (WebAuthn), so a site that offers only a passkey cannot be used in a web app. Use a password and a one-time code where the site allows it, or open the site in your browser."
        ),
        KnownLimitation(
            id: "web-zoom-storage",
            title: "Web app zoom is remembered outside the shortcut",
            detail: "A web app's bundle is sealed by its code signature, so the zoom you set with Command-Plus, Command-Minus and Command-0 is not written into the shortcut. The web app keeps it in its own preferences under the key MADPageZoom, for that shortcut only. The Zoom value in the editor is the starting zoom saved in the shortcut, and the remembered level wins over it. Deleting the shortcut's preferences file resets the zoom to the starting value."
        ),
        KnownLimitation(
            id: "web-notification-permission",
            title: "Web notifications are always allowed, but macOS decides whether they appear",
            detail: "A web app tells every site that notification permission is granted, so sites never show their own permission prompt. Notifications are accepted only from the sites the web app keeps in its window (the app's own host and the hosts listed under Also open in app); a notification from any other site or frame is dropped. Whether a banner actually appears is up to macOS: the first notification asks for permission for that shortcut, and you change it later in System Settings > Notifications. A site that checked permission before you allowed it in System Settings keeps its answer until you reload the page."
        ),
        KnownLimitation(
            id: "web-popup-policy",
            title: "Web apps open other sites in your browser",
            detail: "A web app keeps links to its own site and to the hosts listed under Also open in app inside the window. A link to any other site opens in your default browser instead, and so do mailto: and other non-web links. A window a site opens itself as a pop-up (for example a sign-in window) stays inside the web app so the sign-in can finish. If a site's sign-in or links jump out to the browser, add the hosts it uses to Also open in app."
        ),
        KnownLimitation(
            id: "cli-terminal-applescript",
            title: "Commands in Terminal or iTerm2 need Automation permission",
            detail: "A command shortcut that runs in Terminal or iTerm2 drives that app through AppleScript, so macOS asks once to let the shortcut control it, and the command does not start until you allow it. If you clicked Don't Allow, the shortcut reports that it could not start and names the fix: turn the shortcut on in System Settings > Privacy & Security > Automation, or run tccutil reset AppleEvents <bundle id> so macOS asks again."
        ),
        KnownLimitation(
            id: "cli-terminal-history",
            title: "Terminal and iTerm2 keep the command in shell history",
            detail: "A command shortcut that runs in Terminal or iTerm2 types the whole command, including the environment values it sets inline, into the terminal session, so it shows in the window and lands in the shell's history file. For a command that carries a password, token or key, choose No terminal (run in background) or Ghostty, or have the command read the secret from a file instead."
        ),
        KnownLimitation(
            id: "file-no-running-state",
            title: "File and folder shortcuts do not show a running state",
            detail: "A file or folder shortcut hands the item to Finder or its opener app and quits, so its Dock icon never shows a running indicator."
        ),
        KnownLimitation(
            id: "cli-no-running-state",
            title: "Command shortcuts do not track the command",
            detail: "A command shortcut starts the command in a terminal or in the background and quits, so its Dock icon does not show whether the command is still running."
        ),
        KnownLimitation(
            id: "cli-ghostty-path",
            title: "Ghostty commands start in Ghostty's own environment",
            detail: "A command sent to Ghostty runs with the PATH and shell setup of the Ghostty window it opens, not the shortcut's environment, so a program that is not on that PATH needs its full path."
        ),
        KnownLimitation(
            id: "helper-running-until-exit",
            title: "A shortcut with a helper stays running until the helper exits",
            detail: "With the menu bar icon or Erase on quit turned on, a small helper process watches the app for the shortcut. The sidebar's running indicator stays on until that helper exits: a moment after the app quits, or once the erase has finished when Erase on quit is on."
        ),
        KnownLimitation(
            id: "erase-custom-folder-confirm",
            title: "Erase on quit asks before emptying a folder outside App Duplicator's data folder",
            detail: "Erase on quit permanently deletes everything inside the shortcut's data folder each time the app quits; nothing goes to the Trash. A folder inside ~/Library/Application Support/App Duplicator/ needs no confirmation, any other folder needs you to confirm a warning first, and your home folder, folders outside it and top-level folders such as Desktop, Documents and Downloads are always refused. The erase runs only when the helper sees the app quit while no other copy of the shortcut is running, so a second copy, a logout, a restart or a helper quit from Activity Monitor can leave the data in place until the next time the app quits."
        ),
        KnownLimitation(
            id: "language-applelanguages",
            title: "The language setting works only in apps that honour AppleLanguages",
            detail: "A shortcut's language reaches the app as the -AppleLanguages and -AppleLocale launch arguments. An app that chooses its language another way, such as its own language setting, keeps its usual language, and an app without a translation for the chosen language falls back to one it has. A blank language follows the system language."
        ),
        KnownLimitation(
            id: "helper-colour-icon",
            title: "The menu bar icon is the shortcut's icon in full colour",
            detail: "The menu bar icon shows the shortcut's own icon in colour, as web app shortcuts do, instead of a monochrome template image, so it does not adapt to a light or dark menu bar the way system icons do."
        ),
        KnownLimitation(
            id: "new-window-template",
            title: "New Window needs a command",
            detail: "The menu bar icon's New Window item appears only when the shortcut has a New Window command: a command line run each time you choose the item, in which {target}, {bundleId} and {dataPath} stand for the app's path, its bundle identifier and the shortcut's data folder. The wizard copies the command from the app's compatibility profile when the profile includes one; otherwise, and for shortcuts made before this version, enter it in the editor's Advanced section. A command that uses {dataPath} is hidden while data separation is off."
        ),
        KnownLimitation(
            id: "system-launch-helper",
            title: "With System Launch, the shortcut itself stays open as the helper",
            detail: "In System Launch mode the menu bar icon and Erase on quit are run by the shortcut's own process, which stays open in the background with no Dock icon for as long as the app runs, and Activity Monitor lists it beside the app. Opening the shortcut again while the app runs brings the app forward instead of starting another copy. Quitting the shortcut's process from Activity Monitor removes the menu bar icon and skips the erase, but leaves the app running."
        ),
    ]
}
