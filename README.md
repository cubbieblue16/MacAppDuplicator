# macOS App Duplicator

macOS App Duplicator creates launcher shortcut bundles that run a second copy of a macOS app with its own data directory, Dock icon and settings (Apple Silicon, macOS 26+).

## Phase 1 engine

Phase 1 provides the core library (`DuplicatorCore`), the `Launcher` binary and the `madctl` command-line generator.

### Build and test

```sh
swift build -c release
swift test --filter DuplicatorCoreTests
Tools/build-fixture.sh
MAD_INTEGRATION=1 swift test --filter IntegrationTests
```

### madctl usage

```sh
madctl inspect <app-path>
madctl plan <app-path> [--data-mode auto|home|disabled] [--data-path P] [--mode dock|system] [--env K=V ...] [--arg A ...] [--appearance system|light|dark] [--language CODE] [--name N]
madctl new <app-path> --name N [same flags] [--out DIR] [--launcher PATH] [--identity NAME]
```

Defaults:

- `--data-mode`: `auto`
- `--mode`: `dock`
- `--appearance`: `system`
- `--name`: the target app's name (`plan` only; `new` requires `--name`)
- `--out`: `~/Applications/App Duplicator` (created if missing)
- `--launcher`: the `Launcher` binary beside the `madctl` executable
- `--identity`: optional; the bundle is signed ad hoc when omitted

Launcher events are logged to `~/Library/Logs/App Duplicator/<Name>.log` (rotated at 1 MB, secrets masked).

### Known limitations

- Dock Shortcut mode: the Dock tile keeps the shortcut's name and icon for the life of the process (the Dock does not redraw on LaunchServices check-in), while `lsappinfo`, Activity Monitor and `NSRunningApplication` report the target. Any Dock-tile drawing or badge by the target (download progress, unread count) lands on the shortcut's tile and replaces the custom icon until restart (same limitation Parall documents). Cmd-Tab appearance is untested.
- The Dock tile title can only be the bundle file name: `LSDisplayName` via private LaunchServices items is overwritten at check-in, `CFProcessPath` is ignored by hardened-runtime apps and crashes Electron helpers, and mirror bundles fail strict codesign (§4.1).
- Apple platform binaries (e.g. TextEdit) and third-party apps that opt into launch constraints cannot use Dock Shortcut mode; they launch through System Launch and own their Dock tile.
- Preferences: CFPreferences (`~/Library/Preferences/<bundle id>.plist`) goes to the real home in every data mode, so plist preferences are shared between the original app and all its shortcuts. Profile data separation for Chromium/Electron/Firefox is unaffected because those write under their user-data directory.
- Appearance: no per-app dark override exists outside Chromium/Electron (`--force-dark-mode`, best effort); Light uses `-NSRequiresAquaSystemAppearance YES`.
- Launch order: with Disabled data mode, launching the shortcut while the original app runs may hand off to the running instance. Use separate data or two shortcuts.
- OAuth callbacks go to whichever instance registered the URL scheme last.
- Notifications are attributed to the original app: all copies share one notification settings entry, and clicking a notification may front the wrong instance.
- HOME override does not create a separate Keychain or macOS user.
- Sandboxed native apps outside the supported families stay in their system container.
- Apps that enforce a single instance (lock file or distributed notification) exit, or hand the request to the running copy, when a copy is already running; nothing outside the app can change that.
- Login items, background helpers and launch agents registered by the target run once, for the original bundle identifier; a shortcut gets no copy of them.
- Updates: shortcuts point at the installed app, so a target update is picked up on the next launch. A shortcut built by an older engine version shows `Needs rebuild` in the library app; Rebuild All refreshes it.
- Shortcut bundles declare no document types or URL schemes, so a shortcut is never the default handler for anything. Once a copy is running, macOS treats it as the target app: links for the target's URL schemes go to whichever instance registered the scheme last, and an opened document may land in a shortcut's copy.
- Web apps: no passkeys; see Phase 4 web apps below.

## Phase 2 library app

`macOS App Duplicator.app` is a SwiftUI library window over the shortcut bundles in `~/Applications/App Duplicator` (plus any folders added in Settings). There is no database: each shortcut's `Info.plist` `MADConfig` dictionary is the record.

### Build and test

```bash
Tools/build-fixture.sh     # test fixture app, needed by the end-to-end test
Tools/build-app.sh         # regenerates the Xcode project with xcodegen, embeds the release Launcher, prints the .app path
Tools/test-app.sh          # MacAppDuplicatorTests
```

The Xcode project under `App/` is generated from `App/project.yml` and git-ignored. Requirements: macOS 26 or later on Apple silicon, Xcode 26 or later, `xcodegen` (`brew install xcodegen`; the scripts look for it on `PATH`, then in `/usr/local/bin` and `/opt/homebrew/bin`).

### What the app does

- Sidebar of shortcuts grouped by kind, with target version, running indicator and a `Needs rebuild` badge when the shortcut's `MADEngineVersion` is below the app's engine version (`ShortcutConfig.currentEngineVersion`). The folder watcher picks up bundles added, removed or renamed; after editing a bundle in place, choose View → Refresh (⌘R).
- New Shortcut wizard: pick an installed app (grid of `/Applications` and `~/Applications`, search, drag-and-drop or Browse; apps in `/System/Applications` such as TextEdit need Browse), name and icon (copied, custom file or generated tile), data mode, and a review step with the masked launch plan.
- Editor: name, icon, target app, launch mode, data mode and folder, appearance, language, arguments and environment (secret-looking keys masked). The per-shortcut HOME symlink list is not editable; a new shortcut takes the list from Settings. `Erase data on quit` and `Menu bar icon` show their stored values but stay disabled for application shortcuts until Phase 6; a web app's `Menu bar icon` is live (see Phase 4 web apps).
- Actions: Launch, Reveal in Finder, Regenerate, Duplicate, Export (with the quarantine-clearing command), Delete (Trash, optional data folder), Rebuild All.
- Diagnostics sheet: resolved target path (plus the stored path when it differs), executable, launch mode, argv, masked environment, warnings and the last 200 log lines, copyable.
- Settings: output and library folders (a change rescans the library), signing identity (Ad-hoc or any codesigning identity in the keychain; defaults to the first Developer ID Application identity), the HOME-override symlink list copied into new shortcuts, and Open Logs Folder.
- Help → Known Limitations (29 entries since Phase 5; the six profile entries are listed under Phase 3 profiles, the four web entries under Phase 4 web apps and the five launcher entries under Phase 5 files, folders and commands).

Acceptance checklist: `docs/acceptance/phase2-library-app.md`.

## Phase 3 profiles

Compatibility profiles (`Packages/CompatProfiles`) record, per bundle identifier, a status (`verified`, `partial` or `unsupported`), suggested launch arguments and environment variables, and notes. The New Shortcut wizard fills a new shortcut's arguments and environment from the matching profile, the editor's Profile section shows which profile matched, and Diagnostics lists it.

### What a badge means

The compatibility badge in the New Shortcut wizard is evaluated in this order (`CompatBadge.badge(for:profile:)`):

- `Unsupported`: the profile marks the app unsupported (typically an app that refuses to run twice).
- `Verified`: the profile was checked end to end on one Mac (second account, separate data folder, two Dock icons). It is advisory, not a guarantee for your app version or setup.
- `Unknown`: no app inspected yet, or a sandboxed native app, whose container ignores the HOME override so its data cannot be separated.
- `HOME only`: any other native app; App Duplicator applies the HOME override, untested for this app.
- `Auto`: a Chromium, Electron, ToDesktop, Firefox or Eclipse app without a verified profile; App Duplicator applies its family's data separation, untested for this app.

A `partial` profile still fills in arguments and environment but does not change the badge, so review those values before relying on them. `docs/acceptance/profile-promotion.md` is the procedure that moves a profile from `partial` to `verified`.

### Checking for profile updates

- Profiles change only when you choose Check Profile Updates. Nothing checks automatically or in the background.
- The default profiles URL is the raw `profiles.json` on this repository's `main` branch, so a profile change reaches existing installs once it is on `main`. The URL is a setting, and only `https://raw.githubusercontent.com` addresses are accepted (`ProfilesFetchPolicy.allowedHost`).
- A successful check writes the cache `~/Library/Application Support/App Duplicator/profiles.json`. A failed or invalid download leaves the cache as it was.
- The app uses the cache only when its `updated` date is later than the bundled seed's (`Packages/CompatProfiles/Resources/profiles.json`); otherwise it uses the seed.

### Profile limitations

Also listed in Help → Known Limitations:

- Profiles are advisory: `Verified` means checked on one Mac, not a guarantee.
- `partial` profiles need manual review.
- Check Profile Updates is manual and fetches only from `raw.githubusercontent.com`.
- Sandboxed native apps cannot be separated (`Unknown`, or `Unsupported` when a profile says so).
- Shortcuts whose names give the same slug get `-2`, `-3` and so on appended, so they never share a bundle identifier or default data folder.
- Exporting over an existing bundle moves the old one to the Trash.

Acceptance checklist: `docs/acceptance/phase3-profiles.md`. Promotion procedure: `docs/acceptance/profile-promotion.md`.

## Phase 4 web apps

A web app is a Dock shortcut for a website: App Duplicator builds a bundle whose executable is a small embedded browser (WebKit) that opens one address in its own window, with its own bundle identifier, Dock icon and private website data store. Create one with ⌘N → `Web App`: pick a preset (WhatsApp, Teams, Outlook) or type an https address, then set the user agent, the badge pattern, the extra hosts that stay in the app, the menu bar icon and background mode.
- Logins, cookies and cache live in a WebKit data store named by the id shown in the editor's `Web data` row, under `~/Library/WebKit/<shortcut bundle identifier>/WebsiteDataStore`. A duplicate gets a new id, so it has its own logins. The editor's `Remove Web Data…` and the second question when you delete a web app remove that store; the shortcut must be quit first.
- The page title's unread count (default pattern `(3)`) and the site's own app-badge calls drive the Dock badge; notifications use macOS banners and a click fronts the window.
- With `Menu bar icon` and `Keep running in the menu bar when the window closes` on, closing the window leaves the app running in the menu bar. For a web app the Menu bar icon is live in this phase; for application shortcuts it stays inert until Phase 6.
- A rename keeps a web app's bundle identifier, so its logins survive. Editing never refetches the site icon; the icon stays as created unless you pick another.
- Diagnostics shows the address (query and credentials removed), user agent, web data id, background and menu bar state, badge pattern, extra hosts, zoom and the shell's log tail.
- Limits: no passkeys, zoom kept in the shell's own preferences, notification permission decided by macOS, and other sites open in your browser (four new Known Limitations entries).

Acceptance checklist: `docs/acceptance/phase4-webshell.md`.

## Phase 5 launchers

New Shortcut also makes shortcuts that are not apps:

- **File or Folder** opens a document or folder from the Dock with the shortcut's own name and icon. A folder opens in Finder; a file opens in its default app or in an app you choose under Open with.
- **Command** runs a program or script with one argument per line (spaces and quotes are passed as typed), an optional working directory, and a choice of Terminal, iTerm2, Ghostty or no terminal (run in background). In the background it can get its own HOME under `~/Library/Application Support/App Duplicator/<slug>`, so its dotfiles stay apart from yours.

The default icon is the item's or the program's Finder icon. Diagnostics shows the item, opener, terminal, working directory, own HOME and the masked command line. The library row shows Item missing in red when the item or program is gone. Deleting never touches the item or program; a command's own HOME folder is offered for the Trash only when it has one. Commands in Terminal or iTerm2 ask once for Automation permission and leave the command in that shell's history (see Known Limitations).

Acceptance checklist: docs/acceptance/phase5-launchers.md

## Core API used by the app

- `BundleWriter.write(config:app:launcherBinary:to:)`: creates `<Name>.app` in the target directory.
- `Signer.sign(bundle:identity:)` and `Signer.arguments(bundle:identity:)`.
- `ShortcutConfig`: `init`, `plistDictionary()`, `init(plistDictionary:)`, `slug(for:)`, `bundleIdentifier(forSlug:)`, `defaultDataPath(forSlug:home:)`, `fileSystemName(for:)`.
- `AppInspector.inspect(appAt:)` and `InspectedApp` (family, sandbox, platform-binary and launch-constraint flags, icon URL, `warnings`).
- `DataSeparationPlanner.plan(app:config:baseEnvironment:shortcutBundleURL:)` for previews.
- `HomeTreeBuilder`.
- `SecretMasking.mask`.
- The `Launcher` release binary at `.build/release/Launcher`, to embed as a resource.

Profiles feed `DataSeparationPlanner.plan` through the wizard prefill (`WizardModel(prefillTarget:profileLookup:)`); see "Phase 3 profiles" above.
