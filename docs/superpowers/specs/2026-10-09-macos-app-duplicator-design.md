# macOS App Duplicator — Design

Date: 2026-10-09
Status: approved by Mike (sections 1–5 reviewed in session)
Target: macOS 26+, Apple Silicon only. Distribution: personal use (Developer ID signed) and open-source GitHub releases (notarized DMG). Not Mac App Store.

## 1. Goal

Run multiple independent instances of the same installed macOS app side by side, each with its own Dock identity (name + icon), its own data (account, profile, settings) where the target app supports it, and its own launch configuration (env, args, appearance). Also turn websites into standalone web-app shortcuts, and create launchers for files, folders and command-line tools.

The product is a from-scratch, black-box re-implementation of the public functionality of Parall (parall.app). No Parall code, assets or bundle contents are used or inspected.

Primary acceptance test: two shortcuts for Claude Desktop (`/Applications/Claude.app`, Electron, not sandboxed) run at the same time, signed in to two different accounts, each with its own Dock icon, each with its own `claude_desktop_config.json`.

## 2. Non-negotiable principles

- Never copy, repackage, patch, inject into or re-sign the target app. A shortcut only reads the target bundle and launches its original executable. Target keeps its developer signature, entitlements, Keychain groups, sandbox and updater.
- Shortcut bundles are self-describing. All configuration lives in the shortcut's own `Info.plist` under the `MADConfig` key. No database. Deleting a shortcut is deleting a folder.
- Shortcut and data are separate. Deleting a shortcut never deletes its data folder unless the user explicitly asks.
- Offline by default. The only network action is the user-triggered "Check Profile Updates" (and web-app shortcuts loading their own site).
- No daemons, no telemetry, no background agents installed by the main app.
- Standard macOS launch mechanisms only: `execve`, `posix_spawn`, LaunchServices/`NSWorkspace`. No private APIs.
- Secrets never logged: env values whose key matches `(?i)secret|token|key|password|passwd|credential` are masked in logs, diagnostics and previews.

## 3. Architecture

Repository `~/Developer/MacAppDuplicator` (never inside iCloud Drive). One Xcode workspace plus SwiftPM packages.

```
MacAppDuplicator/
  Packages/
    DuplicatorCore/        pure Swift (Foundation only). Models, Info.plist (de)serialization,
                           AppInspector (family detection), DataSeparationPlanner, HomeTreeBuilder,
                           ArgvBuilder, BundleWriter, Signer, Library scanner. Unit-tested.
    CompatProfiles/        profiles.json + loader/validator + remote refresh client.
  Launcher/                Swift executable copied into every App / File / Folder / CLI shortcut as
                           Contents/MacOS/<Name>. Roles: main and --helper.
  WebShell/                AppKit app template copied into Web App shortcuts (WKWebView).
  App/                     SwiftUI library app "macOS App Duplicator". Embeds built Launcher and
                           WebShell as resources.
  Tools/                   icon pipeline (SVG -> PNG set -> .icns / Assets), notarize + DMG scripts.
  Tests/                   unit (Core, Profiles) + integration (generate -> launch -> verify).
  docs/superpowers/specs/  design docs; docs/superpowers/plans/ implementation plans.
```

### 3.1 Components and interfaces

| Component | Does | Depends on |
|---|---|---|
| `ShortcutConfig` (Core) | Codable model of one shortcut: `kind` (app / webApp / file / folder / cli), identity, target, launch mode, data mode + path, env, args, appearance, menu bar options, eraseOnQuit, engine version. Round-trips to/from the `MADConfig` plist dict. | Foundation |
| `AppInspector` (Core) | Given an `.app` URL returns `InspectedApp`: bundle id, name, version, executable URL, `AppFamily`, `isSandboxed`, icon file URL. Detection rules in §4.2. | Foundation, `codesign`-free (reads embedded entitlements via `SecStaticCode` or parses `Contents/_CodeSignature` fallback: use `SecStaticCodeCreateWithPath` + `SecCodeCopySigningInformation`). |
| `CompatProfiles` | Loads bundled `profiles.json`, optional cached remote copy (`~/Library/Application Support/App Duplicator/profiles.json`), validates schema, returns `Profile?` for a bundle id and web-app presets. | Core |
| `DataSeparationPlanner` (Core) | `(InspectedApp, Profile?, ShortcutConfig) -> LaunchPlan` = resolved mode, extra args, extra env, directories to create, warnings. Pure function. | Core |
| `HomeTreeBuilder` (Core) | Materialises a HOME-override tree at a path (idempotent, only when directory is empty). | FileManager |
| `BundleWriter` (Core) | Writes a shortcut bundle from a `ShortcutConfig` + template binaries + icon. Atomic: writes to temp dir next to destination, then renames. | Core, Signer |
| `Signer` (Core) | Runs `/usr/bin/codesign` with chosen identity (`Developer ID Application: …` or `-`), `--force --options runtime --timestamp=none` for ad-hoc, with timestamp for Developer ID. Never prints identity private material; identity selected by name only. | Process |
| `ShortcutLibrary` (App) | Actor. Scans library folders, parses `MADConfig`, watches for changes, exposes `[ShortcutRecord]` with running state. | Core, `NSRunningApplication` |
| `Launcher` | Reads own `MADConfig`, resolves target, prepares data, forks helper if needed, `execve`s target. Helper role: status item, process watch, erase-on-quit. | Core (linked statically), AppKit (helper role only) |
| `WebShell` | WKWebView app driven by `MADConfig`. | AppKit, WebKit, UserNotifications |

### 3.2 Shortcut bundle layout

```
<Name>.app/
  Contents/
    Info.plist           CFBundleName, CFBundleDisplayName, CFBundleIdentifier
                         (com.mikekuta.appduplicator.<slug>), CFBundleExecutable (<Name>),
                         CFBundleIconFile (AppIcon), LSMinimumSystemVersion 26.0,
                         LSApplicationCategoryType copied from target, NSHighResolutionCapable,
                         LSUIElement false, MADConfig { … }, MADEngineVersion
    MacOS/<Name>         copy of Launcher (app/file/folder/cli) or WebShell executable (webApp)
    Resources/AppIcon.icns   custom icon file, OR symlink to target's .icns ("linked icon" mode)
    Resources/<WebShell resources>  (webApp only)
    PkgInfo              APPL????
    _CodeSignature/      produced by Signer
```

Linked icon = symlink to the target's icon file inside the target bundle, so the Dock icon follows target updates without regeneration. If the target's icon file name changes after an update the symlink dangles; "Rebuild All" repairs it.

### 3.3 Data flow — creating an App shortcut

1. User picks target `.app` (open panel, drag-drop, or installed-apps grid).
2. `AppInspector` → `InspectedApp`. `CompatProfiles` → `Profile?`. UI shows family, sandbox and compat badges.
3. User edits `ShortcutConfig` in the editor (defaults pre-filled from planner).
4. `BundleWriter` emits bundle to the output folder (default `~/Applications/App Duplicator/`, Spotlight-indexed). `Signer` signs it. Library refreshes.

### 3.4 Data flow — launching

1. LaunchServices starts `Contents/MacOS/<Name>` from the shortcut bundle. The process's LS identity is the shortcut.
2. Launcher reads `MADConfig` from `Bundle.main`.
3. Target resolution: stored path if it still exists and its bundle id matches; else `LSCopyApplicationURLsForBundleIdentifier` first hit; else error alert + exit 2.
4. `DataSeparationPlanner` runs again at launch time (target version may have changed) to produce argv + env + directories. Directories created, HOME tree materialised if mode is HOME override.
5. If menu bar icon or erase-on-quit is enabled: `fork()`; child `setsid()`s and re-executes the same Launcher binary with `--helper <parentPid> <bundlePath>`.
6. Parent `execve(targetExecutable, argv, envp)`. On failure: alert + exit 3. The process image is now the target, still owned by the shortcut's Dock tile.

System Launch mode replaces steps 5–6 with `NSWorkspace.shared.openApplication(at:configuration:)` using `arguments`, `environment`, `createsNewApplicationInstance = true`; Launcher waits for the callback then exits (or stays as helper).

## 4. Launcher engine

### 4.1 Launch modes

- **Dock Shortcut** (default): exec in place. Shortcut owns the Dock tile. Target's `Bundle.main` is still its own bundle (derived from executable path), so resources, helper apps, Keychain access groups and self-updaters behave normally.
- **System Launch**: `NSWorkspace` launch with env/args; target owns the Dock tile. For apps whose single-instance guard rejects the exec path or that must be launched through LaunchServices.

### 4.2 App family detection (`AppInspector`)

Checked in order; first match wins. Paths relative to `Contents/`.

| Family | Evidence |
|---|---|
| `todesktop` | `Resources/app.asar` present AND `Resources/todesktop-runtime-config.json` or `Info.plist` key `ToDesktopVersion` |
| `electron` | `Frameworks/Electron Framework.framework` |
| `chromium` | not `electron`, and `Frameworks/<X> Framework.framework/Versions/Current/Helpers/<X> Helper (GPU).app` exists together with `.../Libraries/libEGL.dylib` (any `<X>`); covers Chrome, Chromium, Brave, Edge, Vivaldi, Opera, Arc, Comet and other Chromium forks without a name list |
| `firefox` | `Resources/omni.ja` AND `MacOS/XUL` or `Resources/application.ini` |
| `eclipse` | `Eclipse/eclipse.ini` or `Eclipse/configuration/config.ini` or `Info.plist` `Eclipse` key |
| `native` | none of the above |

`isSandboxed` = entitlement `com.apple.security.app-sandbox == true`.

### 4.3 Data separation modes

**Auto** (default) — planner picks by family; profile overrides win:

| Family | Args added | Notes |
|---|---|---|
| chromium, electron, todesktop | `--user-data-dir=<path>` | Chromium single-instance lock is per user-data-dir, so instances are independent. Electron apps: same flag (Electron forwards it to `app.getPath("userData")`). |
| firefox | `--profile <path>`, `--no-remote` | `--no-remote` prevents handing the launch to the running instance. Optional "use existing profile" lists entries from `~/Library/Application Support/Firefox/profiles.ini`. |
| eclipse | `-data <path>/workspace`, `-configuration <path>/configuration` | Workspace + configuration both redirected. User `-vmargs` untouched. |
| native, not sandboxed | falls back to HOME override at `<path>` | shows warning "untested app; HOME override applied" |
| native, sandboxed | Disabled | shows warning "sandboxed app; its container cannot be moved. Multiple instances may share data." |

Chromium-family "use existing Chrome profile" = `--profile-directory=<Dir>` added on top of a user-data-dir that points at the real Chrome data folder, only when the user explicitly chooses "share original data".

**HOME override** — `HOME=<path>` in env. On first launch, when `<path>` is empty, `HomeTreeBuilder` creates:

```
<path>/
  Library/{Application Support,Preferences,Caches,Containers,Group Containers,Saved Application State,
           WebKit,HTTPStorages,Cookies,Logs,Keychains}     real empty directories; the login Keychain
                                                           itself stays the real one (documented)
  Desktop Documents Downloads Movies Music Pictures Public  -> symlinks to real HOME equivalents
  .ssh .gitconfig .zshrc .zshenv .zprofile .zsh .oh-my-zsh .bashrc .bash_profile .profile
  .config .docker .npmrc .nvm .cargo .rustup .local .gnupg  -> symlinks to real HOME equivalents
                                                           (only those that exist; list editable in Settings)
```

If `<path>` is not empty on first use, a subfolder named after the real user (`NSUserName()`) is created and used instead. Nothing is ever created inside the real HOME. Removing a symlink later gives that instance a private copy; documented in-app with a "Show hidden files" hint.

**Disabled** — no separation. Used for "just another Dock icon" cases and System Launch of apps that manage their own profiles.

**Erase on quit** — helper removes the data directory's contents after the target exits and recreates the empty directory. Allowed only when the data path is inside `~/Library/Application Support/App Duplicator/` or the user confirmed a custom path in a destructive-styled alert.

### 4.4 Env and args

Final argv = `[targetExecutable] + plannerArgs + profileArgs + userArgs`. Final env = inherited env + plannerEnv + profileEnv + userEnv (later wins). Launcher-internal variables are stripped before exec. `MAD_SHORTCUT_BUNDLE=<path>` and `MAD_SHORTCUT_NAME=<name>` are added so target-side scripts can detect the instance.

### 4.5 Appearance and language

- Appearance **Follow System**: nothing. **Dark**: append `-AppleInterfaceStyle Dark` to argv (NSUserDefaults argument domain; honoured by AppKit and by Electron's `nativeTheme`). **Light**: append `-NSRequiresAquaSystemAppearance YES`. Verified by integration test against TextEdit; apps with their own theme engine may ignore it (documented).
- Language override: appends `-AppleLanguages (<code>)` and `-AppleLocale <code>` to argv. Unlike Parall this does reach the target app because the flags are target-process user-defaults arguments. Documented as "works for apps that read system locale".

### 4.6 Helper role

`Launcher --helper <parentPid> <bundlePath>`:
- `NSApplication` with `.accessory` activation policy; no Dock tile.
- `NSStatusItem` with the shortcut icon (template-rendered 18 pt). Menu: **Show** (activate pid via `NSRunningApplication(processIdentifier:)`), **New Window** (runs profile's `newWindowCommand` if any, e.g. `open -na <bundle> --args --user-data-dir=<path>`; hidden otherwise), optional unread badge (webApp only), **Quit <Name>** (SIGTERM to pid, then SIGKILL after 10 s if still alive).
- Watches parent with `kqueue` `EVFILT_PROC NOTE_EXIT`; on exit performs erase-on-quit if enabled, then exits. Also exits if the parent pid is reused by another process (checks `proc_pidinfo` start time captured at fork).
- Forked only when menu bar icon or erase-on-quit is enabled. Otherwise the shortcut is a pure exec with zero residual process.

### 4.7 Error handling

| Failure | Behaviour |
|---|---|
| `MADConfig` missing/corrupt | `NSAlert` "Shortcut is damaged — open macOS App Duplicator and Regenerate", exit 1 |
| Target not found | `NSAlert` with stored path + bundle id, button "Locate…" (opens main app with `mad://locate?bundle=…`), exit 2 |
| Data path not writable | `NSAlert`, exit 4 |
| `execve` fails | `NSAlert` with `strerror(errno)`, exit 3 |
| Helper crash | never affects the target; target keeps running |

All launcher events append to `~/Library/Logs/App Duplicator/<Name>.log` (rotated at 1 MB). Env values masked per §2.

## 5. Web App shell

Template bundle copied per Web App shortcut, configured by `MADConfig.webApp`:

- `WKWebView` with `WKWebsiteDataStore(forIdentifier: UUID)`. The UUID is the shortcut's "data storage" and is stored in config; recreating a shortcut with the same UUID restores logins. "Remove web data" in the main app calls `WKWebsiteDataStore.remove(forIdentifier:)`.
- Single `NSWindow`, frame autosaved per bundle id, title mirrors page title. Same-origin (and configured extra hosts) navigate in place; everything else opens in the default browser. `createWebViewWith` popups open in a child window sharing the data store so OAuth flows complete.
- Dock badge: regex over page title (`\((\d+)\)` default, profile may override) plus `navigator.setAppBadge` bridged through a `WKScriptMessageHandler`.
- Notifications: injected JS shim replaces `window.Notification`, forwards to `UNUserNotificationCenter`; click activates the window and posts the `click` event back.
- Zoom: `Cmd -`, `Cmd =`, `Cmd 0`, persisted in config via `pageZoom`.
- Background mode: closing the window hides it, switches to `.accessory`, status item restores. Requires menu bar icon enabled.
- Optional status item with unread count.
- User agent: Safari default; "Chrome" preset for sites that block Safari UA (WhatsApp Web).
- Presets (from `profiles.json` `webApps`): WhatsApp (`https://web.whatsapp.com`, Chrome UA), Microsoft Teams (`https://teams.microsoft.com`), Outlook (`https://outlook.office.com/mail/`). Preset carries URL, UA, badge regex, extra hosts, icon URL.
- Icon: at creation the app fetches `apple-touch-icon` → `favicon` → falls back to a generated letter tile; user may replace.
- Passkeys are not supported in the shell (WebKit WebAuthn needs the hosting app's entitlement and associated domains). Documented.

## 6. File, folder and CLI launchers

Same Launcher binary, `MADConfig.kind`:

- `file` / `folder`: `NSWorkspace.shared.open(url)` or open with a chosen app (`openApplication(at:… , urls:)`), then exit. Default icon = `NSWorkspace.shared.icon(forFile:)` rendered to `.icns`.
- `cli`: executable path, args, working directory, env, optional HOME override (reuses `HomeTreeBuilder`), terminal choice:
  - `Terminal.app`: AppleScript `do script` with the command.
  - `iTerm2`: AppleScript `create window with default profile command`.
  - `Ghostty`: `ghostty -e <cmd>` via `posix_spawn`.
  - `none`: `posix_spawn` detached, no window.
  Commands are built as argv arrays; when a shell string is unavoidable (AppleScript terminals) every element is single-quote-escaped.

## 7. Main app

SwiftUI, macOS 26, `NavigationSplitView`.

- **Sidebar**: sections Apps / Web Apps / Files & Folders / Commands. Rows: icon, name, target version, running indicator (`NSRunningApplication` matched by bundle URL). Source `ShortcutLibrary` scanning `~/Applications/App Duplicator/` plus user-added folders (persisted), `DispatchSource` watcher.
- **Editor** (detail): Identity (name, slug/bundle id auto, icon: Linked / Custom file / Generated tile), Target (picker, family, sandbox, compat badge, version), Launch (mode, data mode, path, existing-profile picker, erase on quit), Advanced (env table with masked-value toggle, args list, appearance, language, menu bar icon + new-window command), Actions (Launch, Reveal in Finder, Regenerate, Duplicate, Export…, Delete). Delete asks about the data folder in a second step, default keep.
- **New wizard** sheet: kind → target → identity → data → review → create. Drag an `.app` onto the window to prefill.
- **Toolbar**: New, Rebuild All (regenerates every shortcut whose `MADEngineVersion` is older than the app's engine), Check Profile Updates.
- **Settings**: output folder, signing identity (`security find-identity -v -p codesigning`, default first "Developer ID Application", "Ad-hoc" option; names only), HOME symlink list editor, profiles URL (default raw `profiles.json` on `main` of the GitHub repo), Open Logs.
- **Diagnostics** per shortcut: resolved target path, effective argv/env preview (masked), last 200 log lines.
- **Compat badge**: Verified (profile tested) / Auto (family detected, untested) / HOME only / Unsupported (profile marks single-instance) / Unknown.
- **Export**: copies the bundle to a chosen location and shows the receiver-side `xattr -dr com.apple.quarantine <path>` snippet (only needed after network transfer).
- App bundle id `com.mikekuta.MacAppDuplicator`, display name "macOS App Duplicator". Sparkle deferred; releases via GitHub Releases + notarized DMG.

### 7.1 App icon

Original design, produced in-repo by `Tools/make-icons.sh` (SVG → PNG sizes via `rsvg-convert` or `qlmanage`/`sips` fallback → `iconutil` → `.icns` + `AppIcon.appiconset`).

Concept "Replicator": macOS 26 squircle. Background: deep indigo to electric violet vertical gradient (`#1B1540` → `#4A2DB8`). Foreground: two app tiles (rounded squares) stacked diagonally — back tile semi-transparent violet glass, front tile frosted white glass with a 1.5 pt cyan rim light (`#5EF0FF`) and soft inner highlight; a thin cyan "scan" ring arcs behind both tiles suggesting duplication in progress. No text. Reads at 16 pt as "two overlapping squares".

## 8. Compatibility profiles

`profiles.json` schema (versioned):

```json
{
  "schemaVersion": 1,
  "updated": "2026-10-09",
  "apps": {
    "com.anthropic.claudefordesktop": {
      "name": "Claude",
      "status": "verified",
      "family": "electron",
      "args": [],
      "env": {},
      "newWindowCommand": null,
      "notes": "Each instance has its own claude_desktop_config.json inside the data folder."
    }
  },
  "webApps": { "whatsapp": { "name": "WhatsApp", "url": "https://web.whatsapp.com", "userAgent": "chrome", "badgeRegex": "\\((\\d+)\\)", "extraHosts": ["whatsapp.com"], "iconURL": "..." } }
}
```

`status` ∈ `verified | partial | unsupported`. Bundled copy ships with the app; "Check Profile Updates" fetches the raw file from the GitHub repo `main`, validates schema and `schemaVersion`, and stores it as the cached copy. Cached copy wins over bundled when newer. Seed list: Claude, Chrome, Brave, Edge, Firefox, VS Code, Cursor, Slack, Discord, Obsidian, Plex, Spotify, Signal, Telegram, Ghostty, iTerm2, Terminal (partial), Xcode — each marked `verified` only after a real launch test on Mike's Mac.

## 9. Security and signing

- Shortcuts are signed with the selected Developer ID Application identity (hardened runtime, timestamp) or ad-hoc. Locally created bundles carry no quarantine attribute, so Gatekeeper does not block them. Exported bundles sent over the network need the receiver-side quarantine removal shown in the Export sheet.
- The main app is Developer ID signed, hardened runtime, notarized (`notarytool`), shipped as DMG. Keychain-stored notarization credentials are referenced by profile name only.
- No shell string interpolation in the launcher; `execve`/`posix_spawn` take argv arrays.
- The launcher verifies the target is a directory ending in `.app` containing `Contents/Info.plist` and an executable at the declared path before exec.
- Logs and diagnostics mask env values per §2. The signing identity is referred to by display name only.
- The app requests no TCC permissions. Permission prompts (camera, mic, App Management for self-updating targets like Viber) come from the target and are explained in-app.

## 10. Testing

- **Unit (Core, Profiles):** family detection against fixture bundle trees created in a temp dir (electron, chromium, firefox, eclipse, todesktop, native, sandboxed); `ShortcutConfig` plist round-trip; `DataSeparationPlanner` argv/env for every family × mode; `HomeTreeBuilder` idempotence, non-empty-dir subfolder rule, no writes outside target path; `profiles.json` schema validation; secret masking.
- **Integration (Tests/Integration, runs locally, not in CI):** build Launcher → generate a shortcut for `/System/Applications/TextEdit.app` with Disabled mode → launch → assert `NSRunningApplication.bundleURL` equals the shortcut bundle and the pid's executable is TextEdit's → terminate. Appearance and language: assert the generated argv contains the expected `-AppleInterfaceStyle` / `-AppleLanguages` arguments (the target's effective appearance is not observable from outside).
- **Acceptance (manual, Phase 1 gate):** two Claude Desktop shortcuts, distinct data paths, both running, two accounts, two Dock icons, `ps -o args` shows distinct `--user-data-dir`, each has its own `claude_desktop_config.json`.
- **Web shell smoke:** WhatsApp preset loads, login persists across relaunch with the same UUID, badge updates.

## 11. Known limitations (documented in-app and README)

- Dock Shortcut mode: if the target redraws its Dock tile (download progress), macOS swaps in the target's icon until restart.
- Launch order: with Disabled data mode, launching the shortcut while the original app runs may hand off to the running instance. Use separate data or two shortcuts.
- OAuth callbacks go to whichever instance registered the URL scheme last.
- Push-notification clicks may front the wrong instance.
- HOME override does not create a separate Keychain or macOS user.
- Sandboxed native apps outside the supported families stay in their system container.
- Web shell: no passkeys.

## 12. Phases

Each phase gets its own implementation plan under `docs/superpowers/plans/`.

1. **Engine:** `DuplicatorCore`, `Launcher` (main role, Dock Shortcut + System Launch, Auto/HOME/Disabled, env/args, appearance), `madctl` CLI generator for testing. Gate: Claude Desktop acceptance test.
2. **Library app:** SwiftUI app, library scan, editor, wizard, `BundleWriter` + `Signer` integration, icon modes, app icon pipeline, Settings.
3. **Profiles:** `CompatProfiles`, bundled seed, remote refresh, compat badges, diagnostics, Rebuild All.
4. **Web shell:** WebShell template, presets, badges, notifications, zoom, background mode.
5. **Launchers:** file / folder / CLI kinds, terminal integrations, HOME override for CLI.
6. **Helper:** menu bar icon, New Window, erase-on-quit, language override.
7. **Release:** notarization + DMG scripts, README, GitHub repo public, first tagged release.
