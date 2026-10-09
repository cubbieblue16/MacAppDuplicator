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
- Apple platform binaries (e.g. TextEdit) cannot use Dock Shortcut mode; they launch through System Launch and own their Dock tile.
- Preferences: CFPreferences (`~/Library/Preferences/<bundle id>.plist`) goes to the real home in every data mode, so plist preferences are shared between the original app and all its shortcuts. Profile data separation for Chromium/Electron/Firefox is unaffected because those write under their user-data directory.
- Appearance: no per-app dark override exists outside Chromium/Electron (`--force-dark-mode`, best effort); Light uses `-NSRequiresAquaSystemAppearance YES`.
- Launch order: with Disabled data mode, launching the shortcut while the original app runs may hand off to the running instance. Use separate data or two shortcuts.
- OAuth callbacks go to whichever instance registered the URL scheme last.
- Push-notification clicks may front the wrong instance.
- HOME override does not create a separate Keychain or macOS user.
- Sandboxed native apps outside the supported families stay in their system container.
- Web shell: no passkeys.

## Phase 2 library app

`MacAppDuplicator.app` is a SwiftUI library window over the shortcut bundles in `~/Applications/App Duplicator` (plus any folders added in Settings). There is no database: each shortcut's `Info.plist` `MADConfig` dictionary is the record.

### Build and test

```bash
Tools/build-fixture.sh     # test fixture app, needed by the end-to-end test
Tools/build-app.sh         # regenerates the Xcode project with xcodegen, embeds the release Launcher, prints the .app path
Tools/test-app.sh          # MacAppDuplicatorTests (62 tests)
```

The Xcode project under `App/` is generated from `App/project.yml` and git-ignored. Requirements: macOS 26 or later on Apple silicon, Xcode 26 or later, `xcodegen` (`brew install xcodegen`).

### What the app does

- Sidebar of shortcuts grouped by kind, with target version, running indicator and a `Needs rebuild` badge when the embedded launcher is older than the app's.
- New Shortcut wizard: pick an installed app (grid, search, drag-and-drop or Browse), name and icon (copied, custom file or generated tile), data mode, and a review step with the masked launch plan.
- Editor for every `MADConfig` field: launch mode, data mode and folder, appearance, language, arguments, environment (secret-looking keys masked), icon.
- Actions: Launch, Reveal in Finder, Regenerate, Duplicate, Export (with the quarantine-clearing command), Delete (Trash, optional data folder), Rebuild All.
- Diagnostics sheet: resolved executable, argv, masked environment, warnings and the last 200 log lines, copyable.
- Settings: output and library folders, signing identity (Ad-hoc or any Developer ID in the keychain), HOME-override symlink list.
- Help → Known Limitations.

Acceptance checklist: `docs/acceptance/phase2-library-app.md`.

## Core API used by the app

- `BundleWriter.write(config:app:launcherBinary:to:)`: creates `<Name>.app` in the target directory.
- `Signer.sign(bundle:identity:)` and `Signer.arguments(bundle:identity:)`.
- `ShortcutConfig`: `init`, `plistDictionary()`, `init(plistDictionary:)`, `slug(for:)`, `bundleIdentifier(forSlug:)`, `defaultDataPath(forSlug:home:)`, `fileSystemName(for:)`.
- `AppInspector.inspect(appAt:)` and `InspectedApp` (family, sandbox, platform-binary and launch-constraint flags, icon URL, `warnings`).
- `DataSeparationPlanner.plan(app:config:baseEnvironment:shortcutBundleURL:)` for previews.
- `HomeTreeBuilder`.
- `SecretMasking.mask`.
- The `Launcher` release binary at `.build/release/Launcher`, to embed as a resource.

The Phase 3 insertion point for profiles is the doc comment on `DataSeparationPlanner.plan`.
