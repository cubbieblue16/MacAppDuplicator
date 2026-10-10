# macOS App Duplicator Phase 4 (Web Shell) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Web App shortcuts: a `WebShell` executable (AppKit + WebKit + UserNotifications) that `BundleWriter` copies into `Contents/MacOS/<Name>` for `kind == .webApp`, driven by `MADConfig.webApp`; presets from `profiles.json` `webApps`; title and `setAppBadge` Dock badge; notifications shim; zoom; background mode with a status item; wizard, editor, delete, diagnostics, known limitations, acceptance doc, README and version 0.4.0 in the main app (spec §3.1, §3.2, §5, §7, §8, §10, §11, §12 phase 4).

**Architecture:** Everything testable without WebKit lives in `DuplicatorCore` (Foundation only): `WebAppConfig`, `UserAgentPreset`, `WebAppURLValidator`, `WebHostPolicy`, `BadgeTitleParser`, `WebShellScripts` (JavaScript shims as Swift string constants) and the `ShortcutConfig.webApp` field with its `MADConfig` plist round-trip. The new `WebShell` executable target (`WebShell/Sources/WebShell`, programmatic AppKit, no nibs or resources) is thin glue over those types: `ShellConfig` reads `MADConfig` from `Bundle.main`, `WebViewCoordinator` applies the host policy and script-message handlers, `BadgeController`, `NotificationBridge` and `StatusItemController` implement decisions 7 to 9, and `LaunchLogger` writes `~/Library/Logs/App Duplicator/<Name>.log`. `Tools/build-app.sh` builds it and an `Embed WebShell` post-build phase copies it next to the Launcher; `ShortcutBuilder` picks it as the bundle executable when `config.kind == .webApp`. The main app gains presets (`ProfilesModel.webAppPresets`), a site-icon fetcher, the wizard's web steps, the editor's `Web App` section, web-data removal on delete (directory removal under `~/Library/WebKit/<shortcut bundle id>/WebsiteDataStore/<uuid>`, because `WKWebsiteDataStore` identifiers are namespaced by the hosting process), Diagnostics rows and four new Known Limitations. `currentEngineVersion` stays `1`: `webApp` decodes to `nil` when absent, so every existing shortcut still loads.

**Tech Stack:** Swift 6 language mode (Xcode 27.0, Swift 6.4), macOS 26+ arm64, SwiftUI + AppKit (app), Foundation + Darwin (Core), AppKit + WebKit + UserNotifications + DuplicatorCore (WebShell), Foundation + DuplicatorCore (`CompatProfiles`), Synchronization (`Mutex`), xcodegen 2.45.3 (`/usr/local/bin/xcodegen`), XCTest.

## Global Constraints

Phase 3 constraints carry over verbatim unless a Phase 4 line below overrides them.

- Target macOS 26+, Apple Silicon only. Root package stays `swift-tools-version: 6.2`, `swiftLanguageModes: [.v6]`, `platforms: [.macOS(.v26)]`. The Xcode targets build `ARCHS = arm64`, `MACOSX_DEPLOYMENT_TARGET = 26.0`, `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`.
- DuplicatorCore imports Foundation, Security and Darwin only (no AppKit). The app may import AppKit and SwiftUI. XCTest only (no swift-testing). No new `try?` in app code except where the plan shows it; no empty `catch`, no `@unchecked Sendable`, no `swiftlint:disable`.
- Never copy, repackage, patch, inject into or re-sign the target app (spec §2). The only files the app writes are: shortcut bundles under the output folder (or a user-chosen export location), data folders under `~/Library/Application Support/App Duplicator/`, the launcher log folder `~/Library/Logs/App Duplicator/` (Open Logs Folder creates it when missing; the launcher writes the log files), the profiles cache `~/Library/Application Support/App Duplicator/profiles.json` (written only by Check Profile Updates), `UserDefaults` of `com.mikekuta.MacAppDuplicator`, and temporary files under `FileManager.default.temporaryDirectory`.
- Secrets never shown or logged unmasked by default: env values whose key matches `SecretMasking.secretKeyPattern` (`(?i)secret|token|key|password|passwd|credential`) are shown as `SecretMasking.maskedValue` (`••••••`) in the editor env table (until the per-row reveal toggle is on), in Diagnostics and in previews (spec §2, §7). The signing identity is referred to by display name only (spec §9); the app never prints certificate hashes.
- Shortcut `Info.plist` keeps the Phase 1 key set; `BundleWriter` still never writes `CFBundleURLTypes`, `CFBundleDocumentTypes`, `UTExportedTypeDeclarations` or `UTImportedTypeDeclarations`. Icons are copied, never symlinked.
- Bundle identifier `com.mikekuta.appduplicator.<slug>`; default data path `~/Library/Application Support/App Duplicator/<slug>`; default output `~/Applications/App Duplicator`; logs `~/Library/Logs/App Duplicator/<shortcut name>.log` (Phase 1 `LaunchLogger`).
- App bundle id `com.mikekuta.MacAppDuplicator`, product name and display name `macOS App Duplicator`, `PRODUCT_MODULE_NAME = MacAppDuplicator`, `LSApplicationCategoryType = public.app-category.utilities`, hardened runtime on, App Sandbox off, no entitlements file, no TCC-gated APIs (spec §9).
- UI copy is verbatim from spec §7 where the spec gives it: sidebar sections `Apps`, `Web Apps`, `Files & Folders`, `Commands`; icon modes `Copied from target`, `Custom file`, `Generated tile`; appearance options `Follow System`, `Light`, `Force dark (Chromium/Electron only, best effort)`; actions `Launch`, `Reveal in Finder`, `Regenerate`, `Duplicate`, `Export…`, `Delete`; toolbar `New`, `Rebuild All`; compat badges `Verified`, `Auto`, `HOME only`, `Unsupported`, `Unknown`; signing option `Ad-hoc`.
- Tests never touch `/Applications`, `~/Applications`, the real output folder, the real `UserDefaults` suite or the two Claude shortcuts; every test writes under `makeTemporaryDirectory()` / `FileManager.default.temporaryDirectory` and uses `UserDefaults(suiteName:)` with a unique suite that it removes in `tearDown`. No test launches a shortcut or a target app.
- Every commit message ends with the line `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Repository `/Users/cubbieblue16/Developer/MacAppDuplicator`, branch `main`. Commit identity `git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com"`.
- Additive-only toward Phase 1: no existing public symbol, test or behaviour is removed or weakened. New Core API goes next to the existing files.
- Build-system conventions: `App/MacAppDuplicator.xcodeproj` is generated and git-ignored; `Tools/build-app.sh` and `Tools/test-app.sh` are the only documented ways to build and test the app. All `xcodebuild` runs use `-derivedDataPath .build/DerivedData` and `-destination 'platform=macOS,arch=arm64'`.
- `CompatProfiles` imports Foundation and DuplicatorCore only. Only the app target, the app test target and `CompatProfilesTests` link it; the Launcher and `madctl` never do, so no shortcut bundle contains networking code.
- Fetched `profiles.json` is untrusted data: it is decoded with `JSONDecoder` only, never executed, never passed to a shell and never used to build a command line; every string is at most 2,048 characters and contains no NUL; counts are capped (500 apps, 200 web apps, 64 arguments and 64 environment entries per app, 64 extra hosts per web app); the file is at most 1,048,576 bytes; `schemaVersion` must be `1`; `newWindowCommand` is stored but inert until Phase 6; `webApps` entries are decoded and validated by `CompatProfiles` and surfaced as presets in the Phase 4 wizard. Profile `env` may not set `DYLD_*`, `LD_*`, `MAD_*`, `XRE_*`, `NODE_OPTIONS`, `ELECTRON_RUN_AS_NODE`, `JAVA_TOOL_OPTIONS`, `_JAVA_OPTIONS`, `JDK_JAVA_OPTIONS`, `HOME` or `CFFIXED_USER_HOME`, and profile `args` may not start (one or two dashes, any case) with the debugger, code-loading, sandbox or data-folder switches in `ProfilesDocument.refusedArgumentPattern` (Task 1). That deny-list is defence in depth; the main control is that profile values are copied only when a shortcut is created, shown (masked) on the wizard Review step and stay editable.
- Profile `env` and `args` are shown masked wherever they appear: env values whose key matches `SecretMasking.isSecretKey` show `SecretMasking.maskedValue`, and argument lists pass through `SecretMasking.maskArguments`. Diagnostics, the export notice, the wizard Review step and the Launcher log mask argv the same way.
- No network in tests and no test touches the real profiles cache: the app test host builds its `ProfilesModel` with `DisabledProfilesFetcher` and a cache path under `FileManager.default.temporaryDirectory`; package tests inject a mock `ProfilesFetching`. Tests never touch `/Applications` (writes), `~/Applications`, `UserDefaults.standard`, the real profiles cache or the network.
- Seed statuses: Claude (`com.anthropic.claudefordesktop`) is `verified`, the only entry with a real launch test on Mike's Mac; Terminal (`com.apple.Terminal`) is `partial` with notes `Apple platform binary, System Launch only.`; every other seed entry is `partial`. An entry becomes `verified` only through `docs/acceptance/profile-promotion.md` (spec §8).
- Compat badge copy is exact: `Verified`, `Auto`, `HOME only`, `Unsupported`, `Unknown` (spec §7).
- Profiles URL constant (`ProfilesConstants.defaultURLString`, the default of the Settings profiles URL): `https://raw.githubusercontent.com/cubbieblue16/MacAppDuplicator/main/Packages/CompatProfiles/Resources/profiles.json`. It answers HTTP 404 until the repository is public; that is expected and handled as an error message.
- Profile fetches: HTTPS only; host `raw.githubusercontent.com` only (port 443 or none, no user info) for the request and for every redirect; response capped at 1,048,576 bytes; ephemeral `URLSession` with no cookie storage and no URL cache; request timeout 20 s, resource timeout 60 s. A fetch happens only when the user chooses Check Profile Updates (spec §2).
- Export moves an item already at the chosen destination to the Trash (never deletes it) and puts it back if the export fails; the export sweep removes only `.<name>.mad-export-<UUID>` staging folders that a crashed export left in the destination folder.

Phase 4 additions and overrides:

- `ShortcutConfig.currentEngineVersion` stays `1` in Phase 4. `ShortcutConfig.webApp: WebAppConfig?` decodes to `nil` when the `MADConfig` `webApp` key is absent; the `Info.plist` key set written by `BundleWriter` is unchanged for `.app` shortcuts, and the web variant writes the same key set with `LSEnvironment == config.environment`. No existing shortcut is marked as needing a rebuild.
- Phase 4 enables shortcut kind `.webApp` (wizard option `Web App`, subtitle `Any website as its own app`). `.file`, `.folder` and `.cli` stay disabled with the hint `Coming in a later phase`. The menu bar icon (`ShortcutConfig.menuBarIcon`) becomes live for web apps in this phase and stays inert for `.app` until Phase 6 (the editor says so inline). The new-window command field stays inert.
- Web app config invariants, enforced by the wizard and the builder: `targetPath == ""`, `targetBundleIdentifier == ""`, `launchMode == .dockShortcut`, `dataMode == .disabled`, `dataPath == nil`; `iconMode` meanings for web apps are `.copied` = `Fetched from site`, `.custom`, `.generated`. `WebAppConfig` has exactly the fields `url, dataStoreID, userAgent, badgeRegex, extraHosts, pageZoom, backgroundMode` and the `MADConfig` `webApp` dictionary uses exactly those keys (`dataStoreID` as `uuidString`). `pageZoom` is clamped to `0.5…3.0`, default `1.0`. `backgroundMode` is effective only when `menuBarIcon` is true.
- `WebAppURLValidator` accepts only `https` URLs with a host; `http://`, `ftp://` and host-less input are rejected with the copy `Enter an https:// address`.
- `WebHostPolicy`: `https`/`http` main-frame navigations whose host equals, or is a subdomain of, the base host or any extra host (case-insensitive) load in place; `about:blank`, `data:`, `blob:` and `javascript:` main-frame loads are allowed; every other main-frame navigation and every non-http(s) scheme opens with `NSWorkspace.shared.open` and is cancelled. Subframes are never redirected. Popup windows share the `WKWebViewConfiguration` passed to `createWebView`, are exempt from the policy and close on `webViewDidClose`.
- Page-controlled strings are never interpolated into JavaScript. The native side validates the notification `id` with `UUID(uuidString:)` and drops the message when invalid; the only JavaScript the shell evaluates with a dynamic value is `window.__madNotificationClicked("<uuid>")` built from the validated `uuidString` via `WebShellScripts.notificationClickedScript(id:)`.
- `BadgeTitleParser.defaultPattern == #"\((\d+)\)"#`; an invalid custom pattern falls back to the default and the shell logs it. The badge shows the last value from either the title parser or the `madBadge` message (count omitted or `0` clears); `NSApp.dockTile.badgeLabel` and the status item title show the same count.
- Runtime state the shell persists lives only in the shortcut's own `UserDefaults.standard` (one suite per shortcut bundle id): live zoom under `MADPageZoom` (wins over `pageZoom` when present) and the window frame under autosave name `MADMainWindow`. The shell never writes into its own bundle.
- Background mode: `windowShouldClose` with `webApp.backgroundMode && menuBarIcon` hides the window and switches to `.accessory`; otherwise the window closes and the app terminates. Status item menu items are `Show <Name>` and `Quit <Name>`. `Show`, Dock reopen and a notification click bring the app back to `.regular` and front the window.
- The shell logs with `LaunchLogger(name: config.name)` to `~/Library/Logs/App Duplicator/<Name>.log`: start, policy redirects (URL host only, never path, query, fragment or credentials), badge changes, notification deliveries and errors. Missing or invalid `MADConfig.webApp` shows an `NSAlert` and exits with code 2. A failed page load shows an inline error view with `Retry`; the window stays open.
- `WebShell` imports AppKit, WebKit, UserNotifications and DuplicatorCore only. The main app does not import WebKit: web-data removal deletes `~/Library/WebKit/<shortcut bundle id>/WebsiteDataStore/<uuid>` (case-insensitive uuid match) only after the bundle id passes the namespace check `com.mikekuta.appduplicator.` + `[a-z0-9-]+`. Delete aborts when the user chose to remove web data and the removal fails.
- Renaming a web app in the editor keeps its slug, bundle id and data store id so logins are not orphaned; the editor's Save keeps `AppIcon.icns` byte-for-byte unless the icon mode or custom file changed. Export and delete of web shortcuts never call `TargetResolver` (there is no target). `CompatBadge.isShown(for:)` is false for web apps.
- Seed `Packages/CompatProfiles/Resources/profiles.json` gains the `whatsapp`, `teams` and `outlook` presets exactly as decision 11 lists them and `updated` becomes `2026-10-10`. `userAgent` string `"chrome"` maps to `UserAgentPreset.chrome`; anything else or `nil` maps to `.safari`.
- Site-icon fetch (`URLSessionWebIconFetcher`): GET the page with a 1 MiB cap and 15 s timeout, prefer the largest `apple-touch-icon`, then `rel="icon"` by `sizes`, resolve relative hrefs, fall back to `/favicon.ico`; nil on any failure, and the wizard then uses the one-letter generated tile with the copy `Could not get the site icon; using a generated tile.`. App tests inject a fake fetcher; no network in tests.
- UI copy is exact: kind option `Web App` / `Any website as its own app`; target step title `Choose a website`, field `Website URL`, validation `Enter an https:// address`; options step `Web App Options` with `User agent` (`Safari`, `Chrome`), `Badge pattern` (placeholder `\((\d+)\)`), `Also open in app`, `Keep running in the menu bar when the window closes` (disabled hint `Turn on the menu bar icon first`), `Menu bar icon`; icon fetch status `Fetching the site icon…`; editor section `Web App` with the same fields plus read-only `Zoom`, a `Web data` row with the data store id and `Remove Web Data…`; delete second step `Also remove web data (logins, cookies, cache)?` default keep. Known Limitations new ids `web-no-passkeys`, `web-zoom-storage`, `web-notification-permission`, `web-popup-policy` (24 entries after this phase).
- Version: `MARKETING_VERSION: "0.4.0"`, `CURRENT_PROJECT_VERSION: "3"` in `App/project.yml`. README gains `## Phase 4 web apps`. Acceptance doc `docs/acceptance/phase4-webshell.md`.
- Tests never touch `~/Library/WebKit`, the real `~/Library/Logs/App Duplicator`, the real output folder or the network. `Tests/Integration/WebShellLaunchTests.swift` redirects `HOME` and `CFFIXED_USER_HOME` to a temporary directory for the launched shell, points it at `https://example.invalid` and asserts process identity (`proc_pidpath` == bundle executable; `bundleIdentifier` == shortcut id when `NSRunningApplication` reports one), never page content. The main-app smoke never signs in to a real account.
- Parall is never decompiled or copied; everything here is built from the public spec and this repository's own engineering.

---

## Inputs and conventions

- `$REPO` = `/Users/cubbieblue16/Developer/MacAppDuplicator`. All commands run from `$REPO`. The shell's cwd does not persist between tool calls; prefix every command with `cd "$REPO" &&`.
- Starting point: branch `main` at `761401a` ("AppState export test: replace a previous export, not a plain app"), clean tree, no remote. Baselines: `DuplicatorCoreTests` 115 tests, `CompatProfilesTests` 36 tests, `MacAppDuplicatorTests` 188 tests; `IntegrationTests` count is printed by `swift test --filter IntegrationTests` before Task 2 adds `WebShellLaunchTests`.
- Spec: `docs/superpowers/specs/2026-10-09-macos-app-duplicator-design.md`. Binding interface contract: `.superpowers/sdd/p4/skeleton.md` (decisions 1 to 16) and `.superpowers/sdd/p4/task-1-interfaces.md` (names Task 1 produces, repeated in each task's **Interfaces** block).
- Test commands (expected counts per step): Core `cd "$REPO" && swift test --filter DuplicatorCoreTests 2>&1 | grep -E 'Executed|error:' | tail -3`; Profiles `swift test --filter CompatProfilesTests`; Integration `swift test --filter IntegrationTests`; app, one class `cd "$REPO" && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/<ClassName> 2>&1 | tail -4`; app, everything `cd "$REPO" && Tools/test-app.sh 2>&1 | tail -4` prints `** TEST SUCCEEDED **`. `Tools/test-app.sh` regenerates the Xcode project with xcodegen on every run, so new files under `App/Sources` and `App/Tests` need no `project.yml` edit; the `Embed WebShell` phase and the version bump do.
- Task order and models: 1 (Core, sonnet) → 2 (WebShell window/navigation/embedding, opus) → 3 (WebShell badge/notifications/background, opus) → 4 (presets/icon/builder, sonnet) → 5 (wizard, sonnet) → 6 (editor/delete/diagnostics/docs/version, sonnet). 2 and 3 depend on 1; 4 on 1 and 2; 5 on 4; 6 on 5.
- `swift test --filter` takes the dot form `--filter <Target>.<ClassName>` (for example `--filter DuplicatorCoreTests.WebAppConfigTests`). The slash form `<Target>/<ClassName>` matches nothing on Swift 6.4, runs 0 tests and still exits 0. Any test step whose output shows `Executed 0 tests` has NOT passed; fix the filter and rerun.
- Commit identity `git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com"`; every commit ends with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

### Task 1: Core web types and the BundleWriter executable variant

**Files:**
- Create: `Packages/DuplicatorCore/Sources/DuplicatorCore/WebAppConfig.swift` (`UserAgentPreset`, `WebAppConfig`, `WebAppURLError`, `WebAppURLValidator`)
- Create: `Packages/DuplicatorCore/Sources/DuplicatorCore/WebHostPolicy.swift`
- Create: `Packages/DuplicatorCore/Sources/DuplicatorCore/BadgeTitleParser.swift`
- Create: `Packages/DuplicatorCore/Sources/DuplicatorCore/WebShellScripts.swift`
- Modify: `Packages/DuplicatorCore/Sources/DuplicatorCore/ShortcutConfig.swift` (read lines 1-148; edits at 34-35, 55-56, 75-76, 79-82, 85, 105-106; `plistDictionary()` at 110 and `init(plistDictionary:)` at 121 need no change because they go through the synthesized `Codable`)
- Modify: `Packages/DuplicatorCore/Sources/DuplicatorCore/BundleWriter.swift` (read lines 1-104; replace lines 25-84, i.e. from the doc comment of the five-argument `write` through the end of `infoDictionary`)
- Test: `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/WebAppConfigTests.swift`
- Test: `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/WebHostPolicyTests.swift`
- Test: `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/BadgeTitleParserTests.swift`
- Test: `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/WebShellScriptsTests.swift` (imports `JavaScriptCore`, a system framework; no `Package.swift` change)
- Test: `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/BundleWriterWebAppTests.swift`

No `Package.swift` edit: the `DuplicatorCore` and `DuplicatorCoreTests` targets already glob their directories. Existing helpers used by the tests (confirmed in `TestSupport.swift`): `XCTestCase.makeTemporaryDirectory()` and `FixtureBundle` (with `AppInspector` for the key-set comparison). `DuplicatorCore` stays Foundation-only; the only new framework import is `JavaScriptCore` inside the test file.

**Interfaces:**
- Consumes: `ShortcutKind.webApp` (`Enums.swift`), `ShortcutConfig.fileSystemName(for:)`, `ShortcutConfig.plistDictionary()`, `LauncherError.configCorrupt(String)`, `BundleWriter.moveIntoPlace` (private, unchanged).
- Produces (used by Tasks 2-6):
  - `public enum UserAgentPreset: String, Codable, Sendable { case safari, chrome }` with `static let chromeDesktopUserAgent: String` and `var customUserAgent: String?` (`.safari` is nil).
  - `public struct WebAppConfig: Codable, Hashable, Sendable` with `url`, `dataStoreID`, `userAgent`, `badgeRegex`, `extraHosts`, `pageZoom`, `backgroundMode`; `init(url: String, dataStoreID: UUID = UUID(), userAgent: UserAgentPreset = .safari, badgeRegex: String? = nil, extraHosts: [String] = [], pageZoom: Double = 1.0, backgroundMode: Bool = false)`; `static let pageZoomRange: ClosedRange<Double>`; `static func clampedZoom(_ value: Double) -> Double`; `static func normalizedHosts(_ hosts: [String]) -> [String]`.
  - `public enum WebAppURLError: Error, Equatable, LocalizedError { case invalidAddress }` (description `Enter an https:// address`) and `public enum WebAppURLValidator { public static func validate(_ string: String) throws -> URL }`.
  - `ShortcutConfig.webApp: WebAppConfig?` and the `webApp:` initializer parameter (between `homeSymlinkEntries:` and `engineVersion:`).
  - `public struct WebHostPolicy: Equatable, Sendable`: `init(baseURL: URL, extraHosts: [String])`, `let allowedHosts: [String]`, `func allowsInPlace(_ url: URL) -> Bool`, `static let internalSchemes: Set<String>`, `static func isInternalScheme(_ url: URL) -> Bool`.
  - `public struct BadgeTitleParser: Sendable`: `static let defaultPattern`, `static let maxTitleLength`, `let pattern: String`, `let usedFallbackPattern: Bool`, `init(pattern: String?)`, `func count(in title: String) -> Int?`.
  - `public enum WebShellScripts`: `badgeHandlerName` (`"madBadge"`), `notificationHandlerName` (`"madNotification"`), `notificationClickedFunctionName` (`"__madNotificationClicked"`), `badgeBridge: String`, `notificationShim: String`, `static func notificationClickedScript(id: UUID) -> String`.
  - `BundleWriter.write(config: ShortcutConfig, executable: URL, iconFile: URL?, to directory: URL) throws -> URL`.

**Deviations from the skeleton (all additive; Tasks 2-6 should use them):**
1. `WebAppURLValidator` also rejects URLs with embedded credentials (`https://trusted.com@evil.example`), so the Review step cannot show a misleading host.
2. `WebAppConfig.init` and its decoder normalise: `extraHosts` are trimmed, lower-cased, de-duplicated; `pageZoom` is clamped to `0.5...3.0` (non-finite becomes `1.0`). On decode only `url` and `dataStoreID` are required. The `badgeRegex` key is absent from the plist when nil, so the seven-key set is exact whenever a badge pattern is set.
3. `WebHostPolicy` adds `allowedHosts`, `internalSchemes` and `isInternalScheme(_:)`: `allowsInPlace` is false for `about:`, `data:`, `blob:` and `javascript:` (decision 6's first sentence), and the shell consults `isInternalScheme` for the same-document exception in the main frame.
4. `BadgeTitleParser` exposes `pattern` (the pattern in use) and `usedFallbackPattern` (log this); a pattern with no capture group counts as invalid; titles are cut to 1,024 characters before matching.
5. `WebShellScripts.notificationClickedScript(id:)` takes a `UUID` and emits the id lower-cased (`crypto.randomUUID()` produces lower-case ids, and the shim also compares case-insensitively). Task 3 must call this helper instead of formatting the string itself. The badge bridge posts `{count: n}` for a positive whole number and `{}` for everything else (`clearAppBadge()`, `setAppBadge()`, `0`, negatives, non-numbers), which the native side treats as clear. The notification shim installs once per frame, keeps the newest 100 notification objects (older ones can no longer be click-dispatched) and falls back to a `crypto.getRandomValues` v4 UUID when `crypto.randomUUID` is missing (insecure contexts).
6. The internal `BundleWriter.infoDictionary(config:app:executableName:hasIcon:)` is replaced by one private builder `infoDictionary(config:lsEnvironment:executableName:hasIcon:)`; it had no caller outside `BundleWriter.swift`.

**Verification already done by the planner** (scratchpad copy, not the repo): all code and tests below were compiled with `swiftc` against a copy of `DuplicatorCore` and run with `xcrun xctest` together with the 115 existing Core test files: 171 tests, 0 failures (56 new). Expected counts below come from that run.

---

#### Group A: `WebAppConfig` and `ShortcutConfig.webApp`

- [ ] **Step 1: Write the failing tests**

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/WebAppConfigTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore

final class WebAppConfigTests: XCTestCase {
    private let storeID = UUID(uuidString: "5B0D2C1E-8F3A-4C57-9E11-2A6D4B7C9F10")!

    private func makeWebApp() -> WebAppConfig {
        WebAppConfig(
            url: "https://web.whatsapp.com",
            dataStoreID: storeID,
            userAgent: .chrome,
            badgeRegex: #"\((\d+)\)"#,
            extraHosts: ["whatsapp.com", "whatsapp.net"],
            pageZoom: 1.25,
            backgroundMode: true
        )
    }

    private func makeShortcut(webApp: WebAppConfig?) -> ShortcutConfig {
        ShortcutConfig(
            kind: .webApp,
            name: "WhatsApp",
            slug: "whatsapp",
            bundleIdentifier: "com.mikekuta.appduplicator.whatsapp",
            targetPath: "",
            targetBundleIdentifier: "",
            launchMode: .dockShortcut,
            dataMode: .disabled,
            menuBarIcon: true,
            webApp: webApp
        )
    }

    // MARK: WebAppConfig

    func testInitializerDefaults() {
        let config = WebAppConfig(url: "https://example.com")
        XCTAssertEqual(config.userAgent, .safari)
        XCTAssertNil(config.badgeRegex)
        XCTAssertEqual(config.extraHosts, [])
        XCTAssertEqual(config.pageZoom, 1.0)
        XCTAssertFalse(config.backgroundMode)
        XCTAssertNotEqual(config.dataStoreID, WebAppConfig(url: "https://example.com").dataStoreID)
    }

    func testPageZoomIsClamped() {
        XCTAssertEqual(WebAppConfig(url: "https://a.com", pageZoom: 0.1).pageZoom, 0.5)
        XCTAssertEqual(WebAppConfig(url: "https://a.com", pageZoom: 9).pageZoom, 3.0)
        XCTAssertEqual(WebAppConfig(url: "https://a.com", pageZoom: .nan).pageZoom, 1.0)
        XCTAssertEqual(WebAppConfig(url: "https://a.com", pageZoom: 1.25).pageZoom, 1.25)
        XCTAssertEqual(WebAppConfig.pageZoomRange, 0.5...3.0)
    }

    func testExtraHostsAreTrimmedLowercasedAndDeduplicated() {
        let config = WebAppConfig(url: "https://a.com", extraHosts: [" WhatsApp.NET ", "", "whatsapp.net", "B.com", "   "])
        XCTAssertEqual(config.extraHosts, ["whatsapp.net", "b.com"])
    }

    func testUserAgentPresets() {
        XCTAssertEqual(UserAgentPreset.safari.rawValue, "safari")
        XCTAssertEqual(UserAgentPreset.chrome.rawValue, "chrome")
        XCTAssertNil(UserAgentPreset.safari.customUserAgent)
        let chrome = UserAgentPreset.chrome.customUserAgent
        XCTAssertEqual(chrome, UserAgentPreset.chromeDesktopUserAgent)
        XCTAssertEqual(
            chrome,
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
        )
    }

    // MARK: ShortcutConfig.webApp

    func testWebAppIsNilByDefault() {
        XCTAssertNil(makeShortcut(webApp: nil).webApp)
        let app = ShortcutConfig(name: "N", slug: "n", bundleIdentifier: "b", targetPath: "/A.app", targetBundleIdentifier: "a")
        XCTAssertNil(app.webApp)
    }

    func testPlistRoundTripKeepsTheWebAppConfig() throws {
        let config = makeShortcut(webApp: makeWebApp())
        let decoded = try ShortcutConfig(plistDictionary: config.plistDictionary())
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.webApp, makeWebApp())
        XCTAssertEqual(decoded.webApp?.dataStoreID, storeID)
    }

    func testPlistDictionaryEmitsTheWebAppKeysExactly() throws {
        let dictionary = makeShortcut(webApp: makeWebApp()).plistDictionary()
        let web = try XCTUnwrap(dictionary["webApp"] as? [String: Any])
        XCTAssertEqual(Set(web.keys), ["url", "dataStoreID", "userAgent", "badgeRegex", "extraHosts", "pageZoom", "backgroundMode"])
        XCTAssertEqual(web["url"] as? String, "https://web.whatsapp.com")
        XCTAssertEqual(web["dataStoreID"] as? String, storeID.uuidString)
        XCTAssertEqual(web["userAgent"] as? String, "chrome")
        XCTAssertEqual(web["badgeRegex"] as? String, #"\((\d+)\)"#)
        XCTAssertEqual(web["extraHosts"] as? [String], ["whatsapp.com", "whatsapp.net"])
        XCTAssertEqual(web["pageZoom"] as? Double, 1.25)
        XCTAssertEqual(web["backgroundMode"] as? Bool, true)
        XCTAssertNoThrow(try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0))
    }

    func testNilBadgeRegexIsOmittedAndRoundTrips() throws {
        var web = makeWebApp()
        web.badgeRegex = nil
        let config = makeShortcut(webApp: web)
        let dictionary = config.plistDictionary()
        let stored = try XCTUnwrap(dictionary["webApp"] as? [String: Any])
        XCTAssertNil(stored["badgeRegex"])
        XCTAssertEqual(try ShortcutConfig(plistDictionary: dictionary), config)
    }

    func testAbsentWebAppDecodesToNilAndIsNotEmitted() throws {
        let config = makeShortcut(webApp: nil)
        let dictionary = config.plistDictionary()
        XCTAssertNil(dictionary["webApp"])
        XCTAssertNil(try ShortcutConfig(plistDictionary: dictionary).webApp)
    }

    func testPhase3DictionaryWithoutWebAppStillDecodes() throws {
        let legacy: [String: Any] = [
            "kind": "app", "name": "Claude Work", "slug": "claude-work",
            "bundleIdentifier": "com.mikekuta.appduplicator.claude-work",
            "targetPath": "/Applications/Claude.app", "targetBundleIdentifier": "com.anthropic.claudefordesktop",
            "launchMode": "dockShortcut", "dataMode": "auto",
            "environment": [String: String](), "arguments": [String](),
            "appearance": "system", "eraseOnQuit": false, "menuBarIcon": false, "iconMode": "copied", "engineVersion": 1,
        ]
        let config = try ShortcutConfig(plistDictionary: legacy)
        XCTAssertNil(config.webApp)
        XCTAssertEqual(config.kind, .app)
        XCTAssertEqual(config.engineVersion, 1)
    }

    func testOptionalWebAppKeysFallBackToDefaults() throws {
        var dictionary = makeShortcut(webApp: nil).plistDictionary()
        dictionary["webApp"] = ["url": "https://example.com", "dataStoreID": storeID.uuidString]
        let web = try XCTUnwrap(ShortcutConfig(plistDictionary: dictionary).webApp)
        XCTAssertEqual(web, WebAppConfig(url: "https://example.com", dataStoreID: storeID))
    }

    func testStoredPageZoomIsClampedOnDecode() throws {
        var dictionary = makeShortcut(webApp: nil).plistDictionary()
        dictionary["webApp"] = ["url": "https://example.com", "dataStoreID": storeID.uuidString, "pageZoom": 40.0]
        XCTAssertEqual(try ShortcutConfig(plistDictionary: dictionary).webApp?.pageZoom, 3.0)
    }

    func testCorruptWebAppThrowsConfigCorrupt() {
        var badStore = makeShortcut(webApp: nil).plistDictionary()
        badStore["webApp"] = ["url": "https://example.com", "dataStoreID": "not-a-uuid"]
        var missingURL = makeShortcut(webApp: nil).plistDictionary()
        missingURL["webApp"] = ["dataStoreID": storeID.uuidString]
        var badAgent = makeShortcut(webApp: nil).plistDictionary()
        badAgent["webApp"] = ["url": "https://example.com", "dataStoreID": storeID.uuidString, "userAgent": "netscape"]
        for dictionary in [badStore, missingURL, badAgent] {
            XCTAssertThrowsError(try ShortcutConfig(plistDictionary: dictionary)) { error in
                guard case LauncherError.configCorrupt = error else {
                    return XCTFail("expected configCorrupt, got \(error)")
                }
            }
        }
    }

    // MARK: WebAppURLValidator

    func testValidatorAcceptsHTTPSAddresses() throws {
        XCTAssertEqual(try WebAppURLValidator.validate("https://web.whatsapp.com").absoluteString, "https://web.whatsapp.com")
        XCTAssertEqual(try WebAppURLValidator.validate("  https://outlook.office.com/mail/\n").absoluteString, "https://outlook.office.com/mail/")
        XCTAssertEqual(try WebAppURLValidator.validate("HTTPS://Example.com/Path?x=1").host, "Example.com")
        XCTAssertEqual(try WebAppURLValidator.validate("https://localhost:8443/app").port, 8443)
    }

    func testValidatorRejectsEverythingElse() {
        let rejected = [
            "", "   ", "example.com", "www.example.com/path", "http://example.com", "ftp://example.com",
            "mailto:me@example.com", "javascript:alert(1)", "about:blank", "https://", "https:///path", "https://:443",
            "https://exa mple.com", "https://user:secret@example.com", "https://trusted.com@evil.example",
        ]
        for string in rejected {
            XCTAssertThrowsError(try WebAppURLValidator.validate(string), string) { error in
                XCTAssertEqual(error as? WebAppURLError, .invalidAddress, string)
            }
        }
    }

    func testValidatorErrorCopy() {
        XCTAssertEqual(WebAppURLError.invalidAddress.errorDescription, "Enter an https:// address")
        XCTAssertEqual(WebAppURLError.invalidAddress.localizedDescription, "Enter an https:// address")
    }
}
```

- [ ] **Step 2: Run to see them fail**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.WebAppConfigTests 2>&1 | grep -E "error:" | head -5`
Expected: build errors such as `cannot find 'WebAppConfig' in scope` and `extra argument 'webApp' in call`; no tests run.

- [ ] **Step 3: Implement `WebAppConfig.swift`**

Create `Packages/DuplicatorCore/Sources/DuplicatorCore/WebAppConfig.swift`:

```swift
import Foundation

/// User-agent choice for a web app shortcut (spec §5). `safari` keeps WebKit's own user agent.
public enum UserAgentPreset: String, Codable, Sendable {
    case safari, chrome

    /// Fixed desktop Chrome user agent sent for `.chrome`. Sites such as WhatsApp Web gate features on it.
    public static let chromeDesktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

    /// Value for `WKWebView.customUserAgent`; nil keeps the WebKit default.
    public var customUserAgent: String? {
        switch self {
        case .safari: nil
        case .chrome: Self.chromeDesktopUserAgent
        }
    }
}

/// Settings of a `kind == .webApp` shortcut, stored in `MADConfig` under `webApp` (spec §5).
public struct WebAppConfig: Codable, Hashable, Sendable {
    /// Allowed range of `pageZoom`.
    public static let pageZoomRange: ClosedRange<Double> = 0.5...3.0

    /// Start address; `https` with a host (`WebAppURLValidator`).
    public var url: String
    /// Identifier of the shortcut's own `WKWebsiteDataStore`, so logins stay separate per shortcut.
    public var dataStoreID: UUID
    public var userAgent: UserAgentPreset
    /// Regular expression with one capture group matched against the page title; nil uses `BadgeTitleParser.defaultPattern`.
    public var badgeRegex: String?
    /// Extra hosts that load inside the window (lower-cased, no scheme).
    public var extraHosts: [String]
    /// Initial page zoom, clamped to `pageZoomRange`.
    public var pageZoom: Double
    /// Keep running in the menu bar when the window closes (effective only with `ShortcutConfig.menuBarIcon`).
    public var backgroundMode: Bool

    public init(
        url: String,
        dataStoreID: UUID = UUID(),
        userAgent: UserAgentPreset = .safari,
        badgeRegex: String? = nil,
        extraHosts: [String] = [],
        pageZoom: Double = 1.0,
        backgroundMode: Bool = false
    ) {
        self.url = url
        self.dataStoreID = dataStoreID
        self.userAgent = userAgent
        self.badgeRegex = badgeRegex
        self.extraHosts = Self.normalizedHosts(extraHosts)
        self.pageZoom = Self.clampedZoom(pageZoom)
        self.backgroundMode = backgroundMode
    }

    private enum CodingKeys: String, CodingKey {
        case url, dataStoreID, userAgent, badgeRegex, extraHosts, pageZoom, backgroundMode
    }

    /// `url` and `dataStoreID` are required; every other key falls back to its default so older or hand-edited
    /// dictionaries still load. Hosts and zoom pass through the same normalisation as `init(url:...)`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            url: try container.decode(String.self, forKey: .url),
            dataStoreID: try container.decode(UUID.self, forKey: .dataStoreID),
            userAgent: try container.decodeIfPresent(UserAgentPreset.self, forKey: .userAgent) ?? .safari,
            badgeRegex: try container.decodeIfPresent(String.self, forKey: .badgeRegex),
            extraHosts: try container.decodeIfPresent([String].self, forKey: .extraHosts) ?? [],
            pageZoom: try container.decodeIfPresent(Double.self, forKey: .pageZoom) ?? 1.0,
            backgroundMode: try container.decodeIfPresent(Bool.self, forKey: .backgroundMode) ?? false
        )
    }

    /// `value` limited to `pageZoomRange`; a non-finite value becomes 1.0.
    public static func clampedZoom(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, pageZoomRange.lowerBound), pageZoomRange.upperBound)
    }

    /// Trimmed, lower-cased hosts without empty entries or duplicates, in first-seen order.
    public static func normalizedHosts(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for host in hosts {
            let cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !cleaned.isEmpty, seen.insert(cleaned).inserted {
                result.append(cleaned)
            }
        }
        return result
    }
}

/// Why a web address was refused. The description is the inline copy in the wizard and editor.
public enum WebAppURLError: Error, Equatable, LocalizedError {
    case invalidAddress

    public var errorDescription: String? { "Enter an https:// address" }
}

/// Validates the address of a web app (spec §5): `https`, a host, no embedded credentials.
public enum WebAppURLValidator {
    /// The trimmed `string` as a URL, or `WebAppURLError.invalidAddress`.
    public static func validate(_ string: String) throws -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url
        else {
            throw WebAppURLError.invalidAddress
        }
        return url
    }
}
```

- [ ] **Step 4: Add the `webApp` field to `ShortcutConfig`**

In `Packages/DuplicatorCore/Sources/DuplicatorCore/ShortcutConfig.swift` make these six exact replacements (each `old` string occurs once):

1. Stored property, lines 34-35. Old:
```swift
    public var homeSymlinkEntries: [String]?
    public var engineVersion: Int
```
New:
```swift
    public var homeSymlinkEntries: [String]?
    /// Web app settings; set exactly when `kind == .webApp`, nil otherwise (spec §5).
    public var webApp: WebAppConfig?
    public var engineVersion: Int
```
2. Initializer parameter, lines 55-56. Old:
```swift
        homeSymlinkEntries: [String]? = nil,
        engineVersion: Int = ShortcutConfig.currentEngineVersion
```
New:
```swift
        homeSymlinkEntries: [String]? = nil,
        webApp: WebAppConfig? = nil,
        engineVersion: Int = ShortcutConfig.currentEngineVersion
```
3. Initializer body, lines 75-76. Old:
```swift
        self.homeSymlinkEntries = homeSymlinkEntries
        self.engineVersion = engineVersion
```
New:
```swift
        self.homeSymlinkEntries = homeSymlinkEntries
        self.webApp = webApp
        self.engineVersion = engineVersion
```
4. Coding keys, line 82. Old:
```swift
        case iconMode, customIconPath, homeSymlinkEntries, engineVersion
```
New:
```swift
        case iconMode, customIconPath, homeSymlinkEntries, webApp, engineVersion
```
5. Decoder doc comment, line 85. Old:
```swift
    /// Decodes Phase 1 dictionaries too: `iconMode`, `customIconPath` and `homeSymlinkEntries` are optional on input.
```
New:
```swift
    /// Decodes Phase 1 to 3 dictionaries too: `iconMode`, `customIconPath`, `homeSymlinkEntries` and `webApp` are optional on input.
```
6. Decoder body, lines 105-106. Old:
```swift
        homeSymlinkEntries = try container.decodeIfPresent([String].self, forKey: .homeSymlinkEntries)
        engineVersion = try container.decode(Int.self, forKey: .engineVersion)
```
New:
```swift
        homeSymlinkEntries = try container.decodeIfPresent([String].self, forKey: .homeSymlinkEntries)
        webApp = try container.decodeIfPresent(WebAppConfig.self, forKey: .webApp)
        engineVersion = try container.decode(Int.self, forKey: .engineVersion)
```

`plistDictionary()` and `init(plistDictionary:)` are untouched: `PropertyListEncoder` encodes the new optional with `encodeIfPresent` (absent stays absent) and `UUID` as its `uuidString`, which `testPlistDictionaryEmitsTheWebAppKeysExactly` pins.

- [ ] **Step 5: Run the new tests and the existing config tests**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.WebAppConfigTests 2>&1 | grep -E "Executed|error:" | tail -2`
Expected: `Executed 16 tests, with 0 failures`.
Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.ShortcutConfigTests 2>&1 | grep -E "Executed|error:" | tail -2`
Expected: `Executed 12 tests, with 0 failures` (the existing exact-key-set test still passes because a nil `webApp` is omitted).

- [ ] **Step 6: Commit**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add Packages/DuplicatorCore/Sources/DuplicatorCore/WebAppConfig.swift Packages/DuplicatorCore/Sources/DuplicatorCore/ShortcutConfig.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/WebAppConfigTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Add WebAppConfig and the optional ShortcutConfig.webApp field" -m "WebAppConfig, UserAgentPreset and WebAppURLValidator are new Core types. ShortcutConfig gains an optional webApp that decodes to nil when absent, so every existing shortcut still loads, and round-trips through the MADConfig plist dictionary." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

#### Group B: `WebHostPolicy`

- [ ] **Step 7: Write the failing tests**

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/WebHostPolicyTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore

final class WebHostPolicyTests: XCTestCase {
    private func policy(base: String = "https://web.whatsapp.com", extra: [String] = ["whatsapp.net", "Example.ORG"]) throws -> WebHostPolicy {
        WebHostPolicy(baseURL: try XCTUnwrap(URL(string: base)), extraHosts: extra)
    }

    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string), string)
    }

    func testMatrix() throws {
        let policy = try policy()
        let cases: [(String, Bool)] = [
            ("https://web.whatsapp.com/", true),            // base host
            ("https://web.whatsapp.com/chat?x=1#frag", true),
            ("HTTPS://WEB.WhatsApp.COM/", true),            // case-insensitive
            ("http://web.whatsapp.com/", true),             // http on an allowed host stays in place
            ("https://static.web.whatsapp.com/", true),     // subdomain of base
            ("https://a.b.web.whatsapp.com/", true),        // nested subdomain
            ("https://whatsapp.net/", true),                // extra host
            ("https://media.whatsapp.net/v/t1", true),      // subdomain of an extra host
            ("https://login.example.org/", true),           // extra host stored in mixed case
            ("https://web.whatsapp.com./", true),           // trailing-dot FQDN
            ("https://whatsapp.com/", false),               // parent of the base host is not allowed
            ("https://evilweb.whatsapp.com.attacker.example/", false),
            ("https://notweb.whatsapp.com/", false),        // suffix without the dot boundary
            ("https://attackerwhatsapp.net/", false),
            ("https://google.com/", false),                 // unrelated host
            ("https://example.com/", false),
            ("mailto:me@web.whatsapp.com", false),
            ("tel:+15555550100", false),
            ("about:blank", false),
            ("data:text/html,hi", false),
            ("blob:https://web.whatsapp.com/1234", false),
            ("javascript:void(0)", false),
            ("ftp://web.whatsapp.com/", false),
            ("file:///etc/hosts", false),
            ("whatsapp://send?phone=1", false),
        ]
        for (string, expected) in cases {
            XCTAssertEqual(policy.allowsInPlace(try url(string)), expected, string)
        }
    }

    func testBaseHostWithWWWDoesNotAllowTheBareDomain() throws {
        let policy = try policy(base: "https://www.example.com", extra: [])
        XCTAssertTrue(policy.allowsInPlace(try url("https://www.example.com/")))
        XCTAssertTrue(policy.allowsInPlace(try url("https://m.www.example.com/")))
        XCTAssertFalse(policy.allowsInPlace(try url("https://example.com/")))
    }

    func testAllowedHostsAreNormalizedBaseFirst() throws {
        let policy = try policy(base: "https://Web.WhatsApp.com", extra: [" WhatsApp.NET ", ".example.org", "", "web.whatsapp.com", "whatsapp.net."])
        XCTAssertEqual(policy.allowedHosts, ["web.whatsapp.com", "whatsapp.net", "example.org"])
    }

    func testNoExtraHostsMeansBaseHostOnly() throws {
        let policy = try policy(base: "https://example.com", extra: [])
        XCTAssertTrue(policy.allowsInPlace(try url("https://sub.example.com/")))
        XCTAssertFalse(policy.allowsInPlace(try url("https://example.net/")))
    }

    func testBaseURLWithoutHostAllowsNothingExceptExtraHosts() throws {
        let policy = try policy(base: "about:blank", extra: ["example.org"])
        XCTAssertEqual(policy.allowedHosts, ["example.org"])
        XCTAssertFalse(policy.allowsInPlace(try url("https://example.com/")))
        XCTAssertTrue(policy.allowsInPlace(try url("https://example.org/")))
    }

    func testInternalSchemes() throws {
        XCTAssertEqual(WebHostPolicy.internalSchemes, ["about", "data", "blob", "javascript"])
        for string in ["about:blank", "data:text/html,hi", "blob:https://web.whatsapp.com/1", "javascript:void(0)", "ABOUT:blank"] {
            XCTAssertTrue(WebHostPolicy.isInternalScheme(try url(string)), string)
        }
        for string in ["https://web.whatsapp.com/", "http://example.com/", "mailto:me@example.com", "tel:+15555550100"] {
            XCTAssertFalse(WebHostPolicy.isInternalScheme(try url(string)), string)
        }
    }
}
```

- [ ] **Step 8: Run to see them fail**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.WebHostPolicyTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'WebHostPolicy' in scope`.

- [ ] **Step 9: Implement**

Create `Packages/DuplicatorCore/Sources/DuplicatorCore/WebHostPolicy.swift`:

```swift
import Foundation

/// Decides which main-frame navigations stay inside a web app window (spec §5). Everything else opens in the
/// default browser; the WebShell applies that decision, this type only answers the question.
public struct WebHostPolicy: Equatable, Sendable {
    /// Schemes WebKit uses for same-document and generated content. The shell lets these load in place.
    public static let internalSchemes: Set<String> = ["about", "data", "blob", "javascript"]

    /// Lower-cased hosts that stay in place: the base host first, then the extra hosts.
    public let allowedHosts: [String]

    public init(baseURL: URL, extraHosts: [String]) {
        var hosts: [String] = []
        if let baseHost = Self.normalizedHost(baseURL.host) {
            hosts.append(baseHost)
        }
        for extra in extraHosts {
            if let host = Self.normalizedHost(extra), !hosts.contains(host) {
                hosts.append(host)
            }
        }
        allowedHosts = hosts
    }

    /// True when `url` is `http` or `https` and its host equals, or is a subdomain of, an allowed host.
    public func allowsInPlace(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = Self.normalizedHost(url.host)
        else {
            return false
        }
        return allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// True for `about:`, `data:`, `blob:` and `javascript:` URLs.
    public static func isInternalScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return internalSchemes.contains(scheme)
    }

    /// Lower-cased host without surrounding whitespace, a leading "." or a trailing "."; nil when nothing is left.
    private static func normalizedHost(_ host: String?) -> String? {
        guard var cleaned = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        while cleaned.hasSuffix(".") { cleaned.removeLast() }
        return cleaned.isEmpty ? nil : cleaned
    }
}
```

- [ ] **Step 10: Run to see them pass**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.WebHostPolicyTests 2>&1 | grep -E "Executed|error:" | tail -2`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 11: Commit**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add Packages/DuplicatorCore/Sources/DuplicatorCore/WebHostPolicy.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/WebHostPolicyTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Add WebHostPolicy for web app navigation decisions" -m "Pure Foundation host matching: http and https URLs whose host equals or is a subdomain of the base host or an extra host stay in the window; everything else is for the default browser. The matrix test covers subdomains, look-alike suffixes, schemes and trailing dots." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

#### Group C: `BadgeTitleParser`

- [ ] **Step 12: Write the failing tests**

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/BadgeTitleParserTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore

final class BadgeTitleParserTests: XCTestCase {
    func testDefaultPatternConstant() {
        XCTAssertEqual(BadgeTitleParser.defaultPattern, #"\((\d+)\)"#)
        XCTAssertEqual(BadgeTitleParser(pattern: nil).pattern, BadgeTitleParser.defaultPattern)
    }

    func testDefaultPatternFindsTheCount() {
        let parser = BadgeTitleParser(pattern: nil)
        XCTAssertEqual(parser.count(in: "(3) WhatsApp"), 3)
        XCTAssertEqual(parser.count(in: "Inbox (12) - mail"), 12)
        XCTAssertEqual(parser.count(in: "(7) first (9) second"), 7)
        XCTAssertEqual(parser.count(in: "(0) Teams"), 0)
        XCTAssertEqual(parser.count(in: "(5) Café – naïve ☕"), 5)
        XCTAssertFalse(parser.usedFallbackPattern)
    }

    func testTitlesWithoutAMatchReturnNil() {
        let parser = BadgeTitleParser(pattern: nil)
        XCTAssertNil(parser.count(in: "WhatsApp"))
        XCTAssertNil(parser.count(in: ""))
        XCTAssertNil(parser.count(in: "(three) WhatsApp"))
        XCTAssertNil(parser.count(in: "()"))
        XCTAssertNil(parser.count(in: "(99999999999999999999999) overflow"))
    }

    func testCustomPattern() {
        let parser = BadgeTitleParser(pattern: #"^\[(\d+) unread\]"#)
        XCTAssertEqual(parser.pattern, #"^\[(\d+) unread\]"#)
        XCTAssertFalse(parser.usedFallbackPattern)
        XCTAssertEqual(parser.count(in: "[4 unread] Mail"), 4)
        XCTAssertNil(parser.count(in: "(4) Mail"), "the default pattern no longer applies")
        XCTAssertNil(parser.count(in: "Mail [4 unread]"), "the custom pattern is anchored")
    }

    func testBlankPatternSelectsTheDefaultWithoutCountingAsInvalid() {
        for blank in ["", "   ", "\n"] {
            let parser = BadgeTitleParser(pattern: blank)
            XCTAssertEqual(parser.pattern, BadgeTitleParser.defaultPattern)
            XCTAssertFalse(parser.usedFallbackPattern)
        }
    }

    func testInvalidPatternFallsBackToTheDefault() {
        for invalid in ["(", "[a-", #"(\d+"#, "*abc", #"\"#] {
            let parser = BadgeTitleParser(pattern: invalid)
            XCTAssertEqual(parser.pattern, BadgeTitleParser.defaultPattern, invalid)
            XCTAssertTrue(parser.usedFallbackPattern, invalid)
            XCTAssertEqual(parser.count(in: "(8) Chat"), 8, invalid)
        }
    }

    func testPatternWithoutACaptureGroupFallsBackToTheDefault() {
        let parser = BadgeTitleParser(pattern: #"\d+"#)
        XCTAssertTrue(parser.usedFallbackPattern)
        XCTAssertEqual(parser.pattern, BadgeTitleParser.defaultPattern)
        XCTAssertEqual(parser.count(in: "(2) Chat"), 2)
    }

    func testOnlyTheFirstCaptureGroupCounts() {
        let parser = BadgeTitleParser(pattern: #"(\w+): (\d+)"#)
        XCTAssertNil(parser.count(in: "Inbox: 5"), "first group is the word, which is not a number")
        let numeric = BadgeTitleParser(pattern: #"(\d+) of (\d+)"#)
        XCTAssertEqual(numeric.count(in: "3 of 10"), 3)
    }

    func testLongTitlesAreCutBeforeMatching() {
        let parser = BadgeTitleParser(pattern: nil)
        XCTAssertEqual(parser.count(in: "(6) " + String(repeating: "x", count: 5_000)), 6)
        XCTAssertNil(parser.count(in: String(repeating: "x", count: BadgeTitleParser.maxTitleLength) + " (6)"))
    }
}
```

- [ ] **Step 13: Run to see them fail**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.BadgeTitleParserTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'BadgeTitleParser' in scope`.

- [ ] **Step 14: Implement**

Create `Packages/DuplicatorCore/Sources/DuplicatorCore/BadgeTitleParser.swift`:

```swift
import Foundation

/// Extracts an unread count from a page title such as `(3) Inbox` (spec §5).
public struct BadgeTitleParser: Sendable {
    /// Matches `(3)` and captures the digits.
    public static let defaultPattern = #"\((\d+)\)"#
    /// Titles are cut to this many characters before matching, which bounds the work of a slow pattern.
    public static let maxTitleLength = 1_024

    /// The pattern in use: the supplied one when it compiles and has a capture group, otherwise `defaultPattern`.
    public let pattern: String
    /// True when a non-empty supplied pattern was refused; the shell logs it.
    public let usedFallbackPattern: Bool

    /// - Parameter pattern: regular expression with at least one capture group; nil or blank selects `defaultPattern`.
    public init(pattern: String?) {
        let supplied = pattern?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if supplied.isEmpty {
            self.pattern = Self.defaultPattern
            usedFallbackPattern = false
        } else if Self.isUsable(supplied) {
            self.pattern = supplied
            usedFallbackPattern = false
        } else {
            self.pattern = Self.defaultPattern
            usedFallbackPattern = true
        }
    }

    /// The first capture group of the first match in `title` as an Int; nil when nothing matches, the group is not a
    /// number or the number does not fit an Int. A nil result means "clear the badge".
    public func count(in title: String) -> Int? {
        let bounded = String(title.prefix(Self.maxTitleLength))
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            return nil
        }
        let whole = NSRange(bounded.startIndex..., in: bounded)
        guard let match = regex.firstMatch(in: bounded, range: whole), match.numberOfRanges > 1 else { return nil }
        let group = match.range(at: 1)
        guard group.location != NSNotFound, let range = Range(group, in: bounded) else { return nil }
        return Int(bounded[range])
    }

    private static func isUsable(_ candidate: String) -> Bool {
        do {
            return try NSRegularExpression(pattern: candidate).numberOfCaptureGroups >= 1
        } catch {
            return false
        }
    }
}
```

- [ ] **Step 15: Run to see them pass**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.BadgeTitleParserTests 2>&1 | grep -E "Executed|error:" | tail -2`
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 16: Commit**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add Packages/DuplicatorCore/Sources/DuplicatorCore/BadgeTitleParser.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/BadgeTitleParserTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Add BadgeTitleParser for page-title unread counts" -m "Compiles the configured pattern or the default (3) pattern, falls back to the default for invalid patterns or patterns without a capture group, and returns the first capture group as an Int." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

#### Group D: `WebShellScripts`

- [ ] **Step 17: Write the failing tests**

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/WebShellScriptsTests.swift`. The tests execute the scripts in a bare `JSContext` with stubbed `window.webkit.messageHandlers`, so they check behaviour (posted messages, ids, click dispatch, eviction), not only text:

```swift
import JavaScriptCore
import XCTest
@testable import DuplicatorCore

/// Runs the injected scripts in a bare JavaScriptCore context with stubbed `window.webkit.messageHandlers`, so the
/// tests cover behaviour, not just text. `window` is the global object; `crypto.randomUUID` is deterministic.
final class WebShellScriptsTests: XCTestCase {
    private static let harness = """
    var window = this;
    var navigator = {};
    var posted = { badge: [], notification: [] };
    var counter = 0;
    var crypto = {
      randomUUID: function () {
        counter += 1;
        var tail = ('000000000000' + counter).slice(-12);
        return 'AAAAAAAA-BBBB-4CCC-8DDD-' + tail;
      }
    };
    window.webkit = { messageHandlers: {
      madBadge: { postMessage: function (message) { posted.badge.push(message); } },
      madNotification: { postMessage: function (message) { posted.notification.push(message); } }
    } };
    """

    private func makeContext(harness: String = WebShellScriptsTests.harness) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in
            XCTFail("JavaScript exception: \(exception?.toString() ?? "unknown")")
        }
        context.evaluateScript(harness)
        return context
    }

    private func json(_ context: JSContext, _ expression: String) throws -> String {
        try XCTUnwrap(context.evaluateScript("JSON.stringify(\(expression))")?.toString())
    }

    // MARK: constants

    func testHandlerNamesAndClickScript() throws {
        XCTAssertEqual(WebShellScripts.badgeHandlerName, "madBadge")
        XCTAssertEqual(WebShellScripts.notificationHandlerName, "madNotification")
        XCTAssertEqual(WebShellScripts.notificationClickedFunctionName, "__madNotificationClicked")
        let id = try XCTUnwrap(UUID(uuidString: "5B0D2C1E-8F3A-4C57-9E11-2A6D4B7C9F10"))
        XCTAssertEqual(
            WebShellScripts.notificationClickedScript(id: id),
            #"window.__madNotificationClicked("5b0d2c1e-8f3a-4c57-9e11-2a6d4b7c9f10")"#
        )
    }

    func testScriptsMentionTheirHandlers() {
        XCTAssertTrue(WebShellScripts.badgeBridge.contains("window.webkit.messageHandlers.madBadge"))
        XCTAssertTrue(WebShellScripts.notificationShim.contains("window.webkit.messageHandlers.madNotification"))
        XCTAssertTrue(WebShellScripts.notificationShim.contains("crypto.randomUUID()"))
        XCTAssertTrue(WebShellScripts.notificationShim.contains("window.__madNotificationClicked"))
    }

    // MARK: badge bridge

    func testBadgeBridgePostsCounts() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.badgeBridge)
        context.evaluateScript("navigator.setAppBadge(5)")
        context.evaluateScript("navigator.setAppBadge('7')")
        context.evaluateScript("navigator.setAppBadge(2.9)")
        XCTAssertEqual(try json(context, "posted.badge"), #"[{"count":5},{"count":7},{"count":2}]"#)
    }

    func testBadgeBridgeClears() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.badgeBridge)
        context.evaluateScript("navigator.setAppBadge(0); navigator.setAppBadge(); navigator.setAppBadge(-3); navigator.setAppBadge('x'); navigator.clearAppBadge()")
        XCTAssertEqual(try json(context, "posted.badge"), "[{},{},{},{},{}]")
    }

    func testBadgeBridgeReturnsPromises() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.badgeBridge)
        XCTAssertEqual(context.evaluateScript("typeof navigator.setAppBadge(1).then")?.toString(), "function")
        XCTAssertEqual(context.evaluateScript("typeof navigator.clearAppBadge().then")?.toString(), "function")
    }

    func testBadgeBridgeDoesNothingWithoutTheHandler() throws {
        let context = try makeContext(harness: "var window = this; var navigator = {};")
        context.evaluateScript(WebShellScripts.badgeBridge)
        XCTAssertEqual(context.evaluateScript("typeof navigator.setAppBadge")?.toString(), "undefined")
    }

    // MARK: notification shim

    func testNotificationPostsIdTitleBodyTag() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.notificationShim)
        context.evaluateScript("new Notification('Alice', { body: 'Hello', tag: 'chat-1', icon: 'x.png', data: { secret: 1 } })")
        XCTAssertEqual(
            try json(context, "posted.notification"),
            #"[{"id":"aaaaaaaa-bbbb-4ccc-8ddd-000000000001","title":"Alice","body":"Hello","tag":"chat-1"}]"#
        )
        let keys = try json(context, "Object.keys(posted.notification[0]).sort()")
        XCTAssertEqual(keys, #"["body","id","tag","title"]"#)
        let id = try XCTUnwrap(context.evaluateScript("posted.notification[0].id")?.toString())
        XCTAssertNotNil(UUID(uuidString: id))
    }

    func testNotificationDefaultsForMissingOptions() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.notificationShim)
        context.evaluateScript("new Notification('Only title'); new Notification(42, null)")
        XCTAssertEqual(
            try json(context, "posted.notification.map(function (m) { return [m.title, m.body, m.tag]; })"),
            #"[["Only title","",""],["42","",""]]"#
        )
    }

    func testPermissionIsGranted() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.notificationShim)
        XCTAssertEqual(context.evaluateScript("Notification.permission")?.toString(), "granted")
        context.evaluateScript("var resolved; Notification.requestPermission().then(function (value) { resolved = value; });")
        XCTAssertEqual(context.evaluateScript("resolved")?.toString(), "granted")
        context.evaluateScript("var viaCallback; Notification.requestPermission(function (value) { viaCallback = value; });")
        XCTAssertEqual(context.evaluateScript("viaCallback")?.toString(), "granted")
    }

    func testCloseTrimsTheRegistryAndPostsClose() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.notificationShim)
        context.evaluateScript("var n = new Notification('A'); var closed = 0; n.onclose = function () { closed += 1; }; n.close(); n.close();")
        XCTAssertEqual(
            try json(context, "posted.notification[1]"),
            #"{"id":"aaaaaaaa-bbbb-4ccc-8ddd-000000000001","close":true}"#
        )
        XCTAssertEqual(try json(context, "posted.notification.length"), "2", "the second close() is a no-op")
        XCTAssertEqual(context.evaluateScript("closed")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("window.__madNotificationClicked('aaaaaaaa-bbbb-4ccc-8ddd-000000000001')")?.toBool(), false)
    }

    func testClickDispatchesToOnclickAndListeners() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.notificationShim)
        context.evaluateScript("""
        var log = [];
        var n = new Notification('A');
        n.onclick = function (event) { log.push('onclick:' + event.type + ':' + (event.target === n)); };
        n.addEventListener('click', function () { log.push('listener'); });
        """)
        let script = WebShellScripts.notificationClickedScript(id: try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-000000000001")))
        XCTAssertEqual(context.evaluateScript(script)?.toBool(), true)
        XCTAssertEqual(try json(context, "log"), #"["onclick:click:true","listener"]"#)
        XCTAssertEqual(context.evaluateScript("window.__madNotificationClicked('AAAAAAAA-BBBB-4CCC-8DDD-000000000001')")?.toBool(), true, "ids match case-insensitively")
        XCTAssertEqual(context.evaluateScript("window.__madNotificationClicked('00000000-0000-4000-8000-000000000000')")?.toBool(), false)
        XCTAssertEqual(context.evaluateScript("window.__madNotificationClicked('<script>')")?.toBool(), false)
    }

    func testRemovedListenerDoesNotFire() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.notificationShim)
        context.evaluateScript("var hits = 0; var n = new Notification('A'); var l = function () { hits += 1; }; n.addEventListener('click', l); n.removeEventListener('click', l);")
        context.evaluateScript("window.__madNotificationClicked('aaaaaaaa-bbbb-4ccc-8ddd-000000000001')")
        XCTAssertEqual(context.evaluateScript("hits")?.toInt32(), 0)
    }

    func testRegistryKeepsOnlyTheNewestHundred() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.notificationShim)
        context.evaluateScript("for (var i = 0; i < 101; i++) { new Notification('n' + i); }")
        XCTAssertEqual(context.evaluateScript("window.__madNotificationClicked('aaaaaaaa-bbbb-4ccc-8ddd-000000000001')")?.toBool(), false, "oldest evicted")
        XCTAssertEqual(context.evaluateScript("window.__madNotificationClicked('aaaaaaaa-bbbb-4ccc-8ddd-000000000002')")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("window.__madNotificationClicked('aaaaaaaa-bbbb-4ccc-8ddd-000000000101')")?.toBool(), true)
    }

    func testFallbackIdWhenRandomUUIDIsMissing() throws {
        let harness = Self.harness.replacingOccurrences(
            of: "randomUUID: function",
            with: "getRandomValues: function (array) { for (var i = 0; i < array.length; i++) { array[i] = (i * 37 + 11) % 256; } return array; },\n  notRandomUUID: function"
        )
        let context = try makeContext(harness: harness)
        context.evaluateScript(WebShellScripts.notificationShim)
        context.evaluateScript("new Notification('A')")
        let id = try XCTUnwrap(context.evaluateScript("posted.notification[0].id")?.toString())
        let parsed = try XCTUnwrap(UUID(uuidString: id), id)
        XCTAssertEqual(parsed.uuidString.lowercased(), id)
        XCTAssertEqual(id.dropFirst(14).first, "4", "version nibble")
    }

    func testShimIsInstalledOnce() throws {
        let context = try makeContext()
        context.evaluateScript(WebShellScripts.notificationShim)
        context.evaluateScript("var first = window.Notification;")
        context.evaluateScript(WebShellScripts.notificationShim)
        XCTAssertEqual(context.evaluateScript("window.Notification === first")?.toBool(), true)
    }

    func testShimDoesNothingWithoutTheHandler() throws {
        let context = try makeContext(harness: "var window = this;")
        context.evaluateScript(WebShellScripts.notificationShim)
        XCTAssertEqual(context.evaluateScript("typeof window.Notification")?.toString(), "undefined")
    }
}
```

- [ ] **Step 18: Run to see them fail**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.WebShellScriptsTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'WebShellScripts' in scope`.

- [ ] **Step 19: Implement**

Create `Packages/DuplicatorCore/Sources/DuplicatorCore/WebShellScripts.swift`. The JavaScript lives in raw multi-line string literals (`#"""`), indented four spaces to match the closing delimiter:

```swift
import Foundation

/// JavaScript the WebShell injects at document start in every frame (spec §5). The sources are Swift constants because
/// a shortcut bundle carries no resource files. The page controls every string it posts, so the native side validates
/// each message and never interpolates page text into JavaScript; `notificationClickedScript(id:)` takes a `UUID`
/// for that reason.
public enum WebShellScripts {
    /// `WKScriptMessageHandler` name that receives badge updates.
    public static let badgeHandlerName = "madBadge"
    /// `WKScriptMessageHandler` name that receives notification show and close messages.
    public static let notificationHandlerName = "madNotification"
    /// Global function the shell calls when the user clicks a delivered notification.
    public static let notificationClickedFunctionName = "__madNotificationClicked"

    /// The statement the shell evaluates after a notification click. `id` is lower-cased to match the ids that
    /// `crypto.randomUUID()` produces.
    public static func notificationClickedScript(id: UUID) -> String {
        "window.\(notificationClickedFunctionName)(\"\(id.uuidString.lowercased())\")"
    }

    /// Replaces `navigator.setAppBadge(n)` and `navigator.clearAppBadge()` with posts to `madBadge`:
    /// `{count: n}` for a positive whole number, `{}` (clear) for everything else.
    public static let badgeBridge = #"""
    (function () {
      'use strict';
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.madBadge;
      if (!handler) { return; }
      function post(message) {
        try { handler.postMessage(message); } catch (error) { /* the native side is gone; nothing to report to */ }
      }
      function setAppBadge(contents) {
        var count = Math.floor(Number(contents));
        post(isFinite(count) && count > 0 ? { count: count } : {});
        return Promise.resolve();
      }
      function clearAppBadge() {
        post({});
        return Promise.resolve();
      }
      Object.defineProperty(navigator, 'setAppBadge', { value: setAppBadge, configurable: true, writable: true });
      Object.defineProperty(navigator, 'clearAppBadge', { value: clearAppBadge, configurable: true, writable: true });
    })();
    """#

    /// Replaces `window.Notification` with a shim that posts `{id, title, body, tag}` to `madNotification`
    /// (`{id, close: true}` on `close()`), reports permission `"granted"` and dispatches `click` when the shell calls
    /// `window.__madNotificationClicked(id)`. Ids come from `crypto.randomUUID()`.
    public static let notificationShim = #"""
    (function () {
      'use strict';
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.madNotification;
      if (!handler || window.__madNotificationShim) { return; }
      window.__madNotificationShim = true;

      var MAX_TRACKED = 100;
      var registry = new Map();

      function post(message) {
        try { handler.postMessage(message); } catch (error) { /* the native side is gone; nothing to report to */ }
      }

      function newId() {
        if (typeof crypto.randomUUID === 'function') { return crypto.randomUUID(); }
        var bytes = crypto.getRandomValues(new Uint8Array(16));
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        var hex = Array.prototype.map.call(bytes, function (byte) { return (byte + 256).toString(16).slice(1); }).join('');
        return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' + hex.slice(16, 20) + '-' + hex.slice(20);
      }

      function text(value) {
        return value === undefined || value === null ? '' : String(value);
      }

      class MADNotification {
        constructor(title, options) {
          var settings = options || {};
          this.title = text(title);
          this.body = text(settings.body);
          this.tag = text(settings.tag);
          this.icon = text(settings.icon);
          this.data = settings.data === undefined ? null : settings.data;
          this.silent = settings.silent === true;
          this.onclick = null;
          this.onclose = null;
          this.onerror = null;
          this.onshow = null;
          this._listeners = {};
          this._id = newId().toLowerCase();
          registry.set(this._id, this);
          if (registry.size > MAX_TRACKED) { registry.delete(registry.keys().next().value); }
          post({ id: this._id, title: this.title, body: this.body, tag: this.tag });
        }

        static get permission() { return 'granted'; }

        static requestPermission(callback) {
          if (typeof callback === 'function') { callback('granted'); }
          return Promise.resolve('granted');
        }

        static get maxActions() { return 0; }

        addEventListener(type, listener) {
          if (typeof listener !== 'function') { return; }
          var list = this._listeners[type] || (this._listeners[type] = []);
          if (list.indexOf(listener) === -1) { list.push(listener); }
        }

        removeEventListener(type, listener) {
          var list = this._listeners[type];
          if (!list) { return; }
          var index = list.indexOf(listener);
          if (index !== -1) { list.splice(index, 1); }
        }

        dispatchEvent(event) {
          var handlerProperty = this['on' + event.type];
          if (typeof handlerProperty === 'function') { handlerProperty.call(this, event); }
          var list = (this._listeners[event.type] || []).slice();
          for (var index = 0; index < list.length; index++) { list[index].call(this, event); }
          return true;
        }

        close() {
          if (!registry.delete(this._id)) { return; }
          post({ id: this._id, close: true });
          this.dispatchEvent({ type: 'close', target: this, currentTarget: this, preventDefault: function () {} });
        }
      }

      Object.defineProperty(window, 'Notification', { value: MADNotification, configurable: true, writable: true });

      window.__madNotificationClicked = function (id) {
        var notification = registry.get(String(id).toLowerCase());
        if (!notification) { return false; }
        notification.dispatchEvent({ type: 'click', target: notification, currentTarget: notification, preventDefault: function () {} });
        return true;
      };
    })();
    """#
}
```

- [ ] **Step 20: Run to see them pass**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.WebShellScriptsTests 2>&1 | grep -E "Executed|error:" | tail -2`
Expected: `Executed 16 tests, with 0 failures`.

- [ ] **Step 21: Commit**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add Packages/DuplicatorCore/Sources/DuplicatorCore/WebShellScripts.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/WebShellScriptsTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Add the web shell badge bridge and notification shim scripts" -m "The injected JavaScript is kept as Swift string constants because shortcut bundles carry no resources. The notification shim generates ids with crypto.randomUUID(), keeps a bounded registry and dispatches click through window.__madNotificationClicked. Tests run both scripts in JavaScriptCore with stubbed message handlers." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

#### Group E: `BundleWriter` executable variant

- [ ] **Step 22: Write the failing tests**

Create `Packages/DuplicatorCore/Tests/DuplicatorCoreTests/BundleWriterWebAppTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore

final class BundleWriterWebAppTests: XCTestCase {
    private let fileManager = FileManager.default
    private let storeID = UUID(uuidString: "5B0D2C1E-8F3A-4C57-9E11-2A6D4B7C9F10")!

    private func webConfig(name: String = "WhatsApp", environment: [String: String] = ["LANG": "en_US.UTF-8", "TZ": "UTC"]) -> ShortcutConfig {
        ShortcutConfig(
            kind: .webApp,
            name: name,
            slug: ShortcutConfig.slug(for: name),
            bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: ShortcutConfig.slug(for: name)),
            targetPath: "",
            targetBundleIdentifier: "",
            launchMode: .dockShortcut,
            dataMode: .disabled,
            environment: environment,
            menuBarIcon: true,
            webApp: WebAppConfig(
                url: "https://web.whatsapp.com", dataStoreID: storeID, userAgent: .chrome,
                badgeRegex: #"\((\d+)\)"#, extraHosts: ["whatsapp.net"], pageZoom: 1.25, backgroundMode: true
            )
        )
    }

    private struct Fixture {
        var output: URL
        var executable: URL
        var icon: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = try makeTemporaryDirectory()
        let executable = root.appending(path: "webshell-binary", directoryHint: .notDirectory)
        try Data("webshell".utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: executable.path)
        let icon = root.appending(path: "icon.icns", directoryHint: .notDirectory)
        try Data([7, 7, 7]).write(to: icon)
        return Fixture(output: root.appending(path: "out", directoryHint: .isDirectory), executable: executable, icon: icon)
    }

    private func readPlist(_ bundle: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: bundle.appending(path: "Contents/Info.plist", directoryHint: .notDirectory))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testLayoutCopiesTheExecutableWith755() throws {
        let fixture = try makeFixture()
        let bundle = try BundleWriter().write(config: webConfig(), executable: fixture.executable, iconFile: fixture.icon, to: fixture.output)

        XCTAssertEqual(bundle.path, fixture.output.appending(path: "WhatsApp.app", directoryHint: .isDirectory).path)
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        let executable = contents.appending(path: "MacOS/WhatsApp", directoryHint: .notDirectory)
        XCTAssertEqual(try Data(contentsOf: executable), Data("webshell".utf8))
        XCTAssertEqual(try fileManager.attributesOfItem(atPath: executable.path)[.posixPermissions] as? Int, 0o755)
        XCTAssertEqual(try Data(contentsOf: contents.appending(path: "PkgInfo")), Data("APPL????".utf8))
        let icon = contents.appending(path: "Resources/AppIcon.icns", directoryHint: .notDirectory)
        XCTAssertEqual(try Data(contentsOf: icon), Data([7, 7, 7]))
        XCTAssertThrowsError(try fileManager.destinationOfSymbolicLink(atPath: icon.path), "the icon must be a copy, not a symlink")
        let raw = try Data(contentsOf: contents.appending(path: "Info.plist", directoryHint: .notDirectory))
        XCTAssertEqual(Array(raw.prefix(5)), Array("<?xml".utf8), "Info.plist must be XML format")
    }

    func testInfoPlistValuesAndMADConfig() throws {
        let fixture = try makeFixture()
        let config = webConfig()
        let plist = try readPlist(BundleWriter().write(config: config, executable: fixture.executable, iconFile: fixture.icon, to: fixture.output))

        XCTAssertEqual(plist["CFBundleName"] as? String, "WhatsApp")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "WhatsApp")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.mikekuta.appduplicator.whatsapp")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "WhatsApp")
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "26.0")
        XCTAssertEqual(plist["NSHighResolutionCapable"] as? Bool, true)
        XCTAssertEqual(plist["MADEngineVersion"] as? Int, 1)
        let stored = try XCTUnwrap(plist["MADConfig"] as? [String: Any])
        let decoded = try ShortcutConfig(plistDictionary: stored)
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.webApp?.dataStoreID, storeID)
    }

    func testKeySetMatchesTheAppShortcutWriter() throws {
        let root = try makeTemporaryDirectory()
        var target = FixtureBundle()
        target.info = ["CFBundleIconFile": "AppIcon", "LSEnvironment": ["A": "target"]]
        target.files = ["Resources/AppIcon.icns"]
        let targetBundle = try target.write(in: root)
        let app = try AppInspector().inspect(appAt: targetBundle)
        let fixture = try makeFixture()
        let appConfig = ShortcutConfig(
            name: "Claude Work", slug: "claude-work", bundleIdentifier: "com.mikekuta.appduplicator.claude-work",
            targetPath: "/Applications/Claude.app", targetBundleIdentifier: "com.example.fixture"
        )

        let appBundle = try BundleWriter().write(config: appConfig, app: app, launcherBinary: fixture.executable, iconFile: fixture.icon, to: fixture.output)
        let webBundle = try BundleWriter().write(config: webConfig(), executable: fixture.executable, iconFile: fixture.icon, to: fixture.output)

        XCTAssertEqual(Set(try readPlist(webBundle).keys), Set(try readPlist(appBundle).keys))
        XCTAssertEqual(
            Set(try readPlist(webBundle).keys),
            [
                "CFBundleName", "CFBundleDisplayName", "CFBundleIdentifier", "CFBundleExecutable", "CFBundlePackageType",
                "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion", "NSHighResolutionCapable",
                "LSEnvironment", "MADConfig", "MADEngineVersion", "CFBundleIconFile",
            ]
        )
    }

    func testLSEnvironmentIsExactlyTheConfigEnvironment() throws {
        let fixture = try makeFixture()
        let config = webConfig(environment: ["LANG": "de_DE.UTF-8", "API_TOKEN": "not-a-real-token"])
        let plist = try readPlist(BundleWriter().write(config: config, executable: fixture.executable, iconFile: nil, to: fixture.output))
        XCTAssertEqual(plist["LSEnvironment"] as? [String: String], config.environment)

        let empty = webConfig(name: "Empty Env", environment: [:])
        let emptyPlist = try readPlist(BundleWriter().write(config: empty, executable: fixture.executable, iconFile: nil, to: fixture.output))
        XCTAssertEqual(emptyPlist["LSEnvironment"] as? [String: String], [:])
    }

    func testForbiddenKeysAreNeverWritten() throws {
        let fixture = try makeFixture()
        let keys = try readPlist(BundleWriter().write(config: webConfig(), executable: fixture.executable, iconFile: nil, to: fixture.output)).keys
        for forbidden in BundleWriter.forbiddenInfoPlistKeys {
            XCTAssertFalse(keys.contains(forbidden), "\(forbidden) must not be written")
        }
    }

    func testNilIconWritesNoIcon() throws {
        let fixture = try makeFixture()
        let bundle = try BundleWriter().write(config: webConfig(), executable: fixture.executable, iconFile: nil, to: fixture.output)
        XCTAssertNil(try readPlist(bundle)["CFBundleIconFile"])
        XCTAssertFalse(fileManager.fileExists(atPath: bundle.appending(path: "Contents/Resources/AppIcon.icns").path))
        let missing = fixture.output.appending(path: "no-such.icns", directoryHint: .notDirectory)
        let second = try BundleWriter().write(config: webConfig(name: "Second"), executable: fixture.executable, iconFile: missing, to: fixture.output)
        XCTAssertNil(try readPlist(second)["CFBundleIconFile"], "a missing icon file is skipped, as for app shortcuts")
    }

    func testRewriteReplacesTheBundleAndLeavesNoStaging() throws {
        let fixture = try makeFixture()
        let writer = BundleWriter()
        let first = try writer.write(config: webConfig(), executable: fixture.executable, iconFile: nil, to: fixture.output)
        try Data("webshell-v2".utf8).write(to: fixture.executable)
        let second = try writer.write(config: webConfig(), executable: fixture.executable, iconFile: nil, to: fixture.output)

        XCTAssertEqual(second, first)
        XCTAssertEqual(try Data(contentsOf: second.appending(path: "Contents/MacOS/WhatsApp")), Data("webshell-v2".utf8))
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: fixture.output.path), ["WhatsApp.app"])
    }

    func testMissingExecutableThrowsAndLeavesNothingBehind() throws {
        let fixture = try makeFixture()
        let missing = fixture.executable.deletingLastPathComponent().appending(path: "absent", directoryHint: .notDirectory)
        XCTAssertThrowsError(try BundleWriter().write(config: webConfig(), executable: missing, iconFile: nil, to: fixture.output))
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: fixture.output.path), [])
    }

    func testSlashInNameBecomesDashInTheBundleAndExecutable() throws {
        let fixture = try makeFixture()
        let bundle = try BundleWriter().write(config: webConfig(name: "Work/Chat"), executable: fixture.executable, iconFile: nil, to: fixture.output)
        XCTAssertEqual(bundle.lastPathComponent, "Work-Chat.app")
        XCTAssertTrue(fileManager.fileExists(atPath: bundle.appending(path: "Contents/MacOS/Work-Chat").path))
        let plist = try readPlist(bundle)
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "Work-Chat")
        XCTAssertEqual(plist["CFBundleName"] as? String, "Work/Chat")
    }
}
```

- [ ] **Step 23: Run to see them fail**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.BundleWriterWebAppTests 2>&1 | grep -E "error:" | head -3`
Expected: `extra argument 'executable' in call` or `no exact matches in call to instance method 'write'`.

- [ ] **Step 24: Refactor `BundleWriter` and add the overload**

In `Packages/DuplicatorCore/Sources/DuplicatorCore/BundleWriter.swift`, replace lines 25-84 (from `/// Same as \`write(config:app:launcherBinary:to:)\` with an explicit icon` down to and including the closing brace of `infoDictionary`, i.e. everything before `/// Rename-based replace`) with this block. The staging, copy, `0o755`, icon, PkgInfo and rename steps are the old body moved verbatim into the private `assemble`; the two public `write` overloads differ only in the `LSEnvironment` they pass:

```swift
    /// Same as `write(config:app:launcherBinary:to:)` with an explicit icon: `iconFile` (any `.icns`, or nil for no icon)
    /// is copied to `Contents/Resources/AppIcon.icns` instead of the target's icon. The library app passes the result of
    /// its icon mode (copied / custom / generated) here.
    public func write(config: ShortcutConfig, app: InspectedApp, launcherBinary: URL, iconFile: URL?, to directory: URL) throws -> URL {
        // Target's LSEnvironment merged under the shortcut's environment: shortcut wins.
        let lsEnvironment = app.lsEnvironment.merging(config.environment) { _, shortcut in shortcut }
        return try assemble(config: config, executable: launcherBinary, iconFile: iconFile, lsEnvironment: lsEnvironment, to: directory)
    }

    /// Writes a bundle that has no target app (web app shortcuts, spec §5): `executable` (the WebShell binary) is copied
    /// to `Contents/MacOS/<Name>` with mode 0o755, `iconFile` (an `.icns`, or nil for no icon) to
    /// `Contents/Resources/AppIcon.icns`, and `LSEnvironment` is exactly `config.environment`. The Info.plist key set
    /// is the same as for app shortcuts.
    public func write(config: ShortcutConfig, executable: URL, iconFile: URL?, to directory: URL) throws -> URL {
        try assemble(config: config, executable: executable, iconFile: iconFile, lsEnvironment: config.environment, to: directory)
    }

    /// Builds `<directory>/<Name>.app` in a hidden staging directory and renames it into place.
    private func assemble(config: ShortcutConfig, executable executableSource: URL, iconFile: URL?, lsEnvironment: [String: String], to directory: URL) throws -> URL {
        let bundleName = ShortcutConfig.fileSystemName(for: config.name)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: bundleName + ".app", directoryHint: .isDirectory)
        let staging = directory.appending(path: ".\(bundleName).\(UUID().uuidString).tmp", directoryHint: .isDirectory)
        do {
            let contents = staging.appending(path: "Contents", directoryHint: .isDirectory)
            let macOS = contents.appending(path: "MacOS", directoryHint: .isDirectory)
            let resources = contents.appending(path: "Resources", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

            let executable = macOS.appending(path: bundleName, directoryHint: .notDirectory)
            try Data(contentsOf: executableSource).write(to: executable)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

            var hasIcon = false
            if let icon = iconFile, fileManager.fileExists(atPath: icon.path) {
                // Data(contentsOf:) follows symlinks, so the bundle always gets a regular-file copy.
                try Data(contentsOf: icon).write(to: resources.appending(path: "AppIcon.icns", directoryHint: .notDirectory))
                hasIcon = true
            }

            try Data("APPL????".utf8).write(to: contents.appending(path: "PkgInfo", directoryHint: .notDirectory))
            let info = Self.infoDictionary(config: config, lsEnvironment: lsEnvironment, executableName: bundleName, hasIcon: hasIcon)
            let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plistData.write(to: contents.appending(path: "Info.plist", directoryHint: .notDirectory))

            try moveIntoPlace(staging, destination: destination, directory: directory, bundleName: bundleName)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return destination
    }

    /// The complete shortcut Info.plist (spec §3.2), shared by app and web app shortcuts. Only these keys are ever written.
    private static func infoDictionary(config: ShortcutConfig, lsEnvironment: [String: String], executableName: String, hasIcon: Bool) -> [String: Any] {
        var info: [String: Any] = [
            "CFBundleName": config.name,
            "CFBundleDisplayName": config.name,
            "CFBundleIdentifier": config.bundleIdentifier,
            "CFBundleExecutable": executableName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": String(config.engineVersion),
            "LSMinimumSystemVersion": "26.0",
            "NSHighResolutionCapable": true,
            "LSEnvironment": lsEnvironment,
            ShortcutConfig.infoPlistKey: config.plistDictionary(),
            ShortcutConfig.engineVersionInfoPlistKey: config.engineVersion,
        ]
        if hasIcon {
            info["CFBundleIconFile"] = "AppIcon"
        }
        return info
    }
```

Everything else in the file (header, forbidden keys, the four-argument `write`, `moveIntoPlace`) stays as it is.

- [ ] **Step 25: Run the new and existing writer tests**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.BundleWriterWebAppTests 2>&1 | grep -E "Executed|error:" | tail -2`
Expected: `Executed 9 tests, with 0 failures`.
Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests.BundleWriterTests 2>&1 | grep -E "Executed|error:" | tail -2`
Expected: `Executed 9 tests, with 0 failures` (unchanged app-shortcut behaviour).

- [ ] **Step 26: Run the whole Core suite and check the forbidden constructs**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests 2>&1 | grep -E "Executed|error:" | tail -2`
Expected: `Executed N tests, with 0 failures` where N is the previous Core count plus 56 (the planner's scratch run counted 115 existing test cases plus 56 new = 171; if the repository count differs, the delta must still be exactly 56).
Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && grep -nE 'try\?|@unchecked|swiftlint:disable|nonisolated\(unsafe\)' Packages/DuplicatorCore/Sources/DuplicatorCore/WebAppConfig.swift Packages/DuplicatorCore/Sources/DuplicatorCore/WebHostPolicy.swift Packages/DuplicatorCore/Sources/DuplicatorCore/BadgeTitleParser.swift Packages/DuplicatorCore/Sources/DuplicatorCore/WebShellScripts.swift`
Expected: no output. (`BundleWriter.swift` keeps its pre-existing `try?` staging-cleanup call (moved verbatim into `assemble`) and the untouched ones in `moveIntoPlace`; this task adds none.)
Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift build 2>&1 | grep -E "error:|warning:|Compiling|Build complete" | tail -3`
Expected: `Build complete!` (Launcher and `madctl` still compile against the unchanged `ShortcutConfig` call sites).

- [ ] **Step 27: Commit**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add Packages/DuplicatorCore/Sources/DuplicatorCore/BundleWriter.swift Packages/DuplicatorCore/Tests/DuplicatorCoreTests/BundleWriterWebAppTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "BundleWriter: write bundles from a plain executable for web apps" -m "write(config:executable:iconFile:to:) copies the WebShell binary with mode 0755 and sets LSEnvironment to the shortcut environment. Both overloads now share one private bundle assembler and one Info.plist builder, so the key set is identical for app and web app shortcuts." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

## Progress
- 14:51:37 plan assembled from compiled+tested scratch code (56 new tests pass, 171 total with existing Core tests)

---

### Task 2: WebShell executable — window, navigation, popups, UA, zoom, menus, logging, embedding

Skeleton decisions 2, 3, 5, 6, 10 (hooks for 8 and 9). Consumes Task 1 names verbatim from `task-1-interfaces.md`.

**Files**
- Create: `WebShell/Sources/WebShell/main.swift`
- Create: `WebShell/Sources/WebShell/ShellConfig.swift`
- Create: `WebShell/Sources/WebShell/WebViewCoordinator.swift`
- Create: `WebShell/Sources/WebShell/MainWindowController.swift`
- Create: `WebShell/Sources/WebShell/MainMenu.swift`
- Create: `WebShell/Sources/WebShell/WebShellAppDelegate.swift`
- Create: `Tests/Integration/WebShellLaunchTests.swift`
- Create: `App/Sources/App/EmbeddedWebShell.swift`
- Modify: `Package.swift` (looked at 1-33: products 7-12, targets 16-31)
- Modify: `App/project.yml` (looked at 56-57, 69-93: the `Embed Launcher` postBuildScript; line 94 starts `MacAppDuplicatorTests:`)
- Modify: `Tools/build-app.sh` (looked at 1-6, 26-31: comment line 3, `swift build -c release --product Launcher` line 29)
- Modify: `Tools/test-app.sh` (looked at 14-20: `swift build -c release --product Launcher` line 18)
- Modify: `App/Tests/SmokeTests.swift` (looked at 1-31)
- Read only (patterns mirrored): `Launcher/Sources/Launcher/main.swift`, `Launcher/Sources/Launcher/Alerts.swift`, `App/Sources/App/EmbeddedLauncher.swift`, `Tests/Integration/LaunchIntegrationTests.swift` 1-198, `Packages/DuplicatorCore/Sources/DuplicatorCore/{LaunchLogger,ShortcutConfig,BundleWriter,Signer}.swift`

**SDK citations** (MacOSX.sdk in Xcode 27.0 27A266a; names reach Swift through the ObjC import, the WebKit swiftinterface only adds JS helpers)
- `WKWebsiteDataStore(forIdentifier:)` — `WebKit.framework/Headers/WKWebsiteDataStore.h:109` `+ (WKWebsiteDataStore *)dataStoreForIdentifier:(NSUUID *)identifier API_AVAILABLE(macos(14.0))` (creates the store if absent; raises on the all-zero UUID).
- `pageZoom` — `WKWebView.h:514` `@property (nonatomic) CGFloat pageZoom API_AVAILABLE(macos(11.0))`.
- `title` KVO — `WKWebView.h:174-178` ("WKWebView is key-value observing (KVO) compliant for this property"). `customUserAgent` `WKWebView.h:472`.
- `createWebViewWith` — `WKUIDelegate.h:97` `webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:`; `webViewDidClose:` `WKUIDelegate.h:104`. `WKWindowFeatures.h:64/68` `width`/`height` (`NSNumber?`).
- `WKNavigationDelegate.h:84` `decidePolicyForNavigationAction:decisionHandler:` is `WK_SWIFT_ASYNC(3)` → Swift `webView(_:decidePolicyFor:) async -> WKNavigationActionPolicy` (used so a mistyped completion-handler signature cannot silently fall back to "allow"); `:130` `didFailProvisionalNavigation`; `:136` `didCommit`; `:150` `didFailNavigation`; `:167` `webViewWebContentProcessDidTerminate`.
- `WebKitErrors.h:49` `WebKitErrorFrameLoadInterruptedByPolicyChange = 102` (domain string `WebKitErrorDomain`).
- AppKit: `NSWindow.h:556` `setFrameAutosaveName:` (returns BOOL); `NSApplication.h:372` `windowsMenu`; `NSWorkspace.h:164` `activates`, `:176` `createsNewApplicationInstance`.

**Interfaces**
- Consumes (Core, existing): `LaunchLogger(name: String)` + `log(_:)` (public, `LaunchLogger.swift:12/29` — the internal `init(name:directory:maxBytes:)` is NOT needed; no Core change); `ShortcutConfig.infoPlistKey`; `ShortcutConfig(plistDictionary: [String: Any]) throws` (`ShortcutConfig.swift:121`); `ShortcutConfig.slug(for:)` (:132), `ShortcutConfig.bundleIdentifier(forSlug:)` (:146), `ShortcutConfig.fileSystemName(for:)`; `Signer().sign(bundle: URL, identity: String?) throws`.
- Consumes (Task 1): `ShortcutConfig.webApp: WebAppConfig?` and the `webApp:` init parameter; `WebAppConfig(url:)`, `.url`, `.dataStoreID`, `.userAgent`, `.extraHosts`, `.pageZoom`, `WebAppConfig.clampedZoom(_:)`; `UserAgentPreset.customUserAgent`, `.rawValue`; `WebAppURLValidator.validate(_:) throws -> URL`; `WebHostPolicy(baseURL:extraHosts:)`, `allowsInPlace(_:)`, `WebHostPolicy.isInternalScheme(_:)`; `WebShellScripts.badgeBridge`, `WebShellScripts.notificationShim`; `BundleWriter().write(config:executable:iconFile:to:) throws -> URL`.
- Produces (executable target `WebShell`, product `.build/release/WebShell`):
  - `struct ShellConfig: Sendable { let shortcut: ShortcutConfig; let webApp: WebAppConfig; let baseURL: URL; let policy: WebHostPolicy; static func load(infoDictionary: [String: Any]) throws -> ShellConfig }`; `enum ShellConfigError: Error, Equatable, LocalizedError { case configMissing, configCorrupt(String) }`; `@MainActor func loadShellConfigOrExit(logger: LaunchLogger) -> ShellConfig`; `@MainActor func failAndExit(_ error: Error, logger: LaunchLogger) -> Never` (exit 2).
  - `@MainActor final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate` — `init(shell:logger:)`, `let webView: WKWebView`, `var titleDidChange: ((String) -> Void)?` (Task 3), `func addMessageHandler(_ handler: WKScriptMessageHandler, name: String)` (Task 3), `func loadHome()`, `func load(_ url: URL)`, `var provisionalLoadDidFail: ((Error) -> Void)?`, `var navigationDidCommit: (() -> Void)?`.
  - `@MainActor final class MainWindowController: NSObject, NSWindowDelegate` — `static let frameAutosaveName = "MADMainWindow"`, `init(coordinator:shell:logger:)`, `let window: NSWindow`, `func showWindow()` (Task 3), `func showError(_:)`, `func hideError()`. It is `window.delegate`; Task 3 adds `windowShouldClose(_:)` here.
  - `@MainActor final class PageZoomController: NSObject` — `static let defaultsKey = "MADPageZoom"`, `static let step = 0.1`, `init(defaults: UserDefaults, configZoom: Double, webView: WKWebView)`, `@objc zoomIn(_:)`, `@objc zoomOut(_:)`, `@objc actualSize(_:)`; `@MainActor enum MainMenu { static func build(appName: String, zoom: PageZoomController) -> (main: NSMenu, windows: NSMenu) }`.
  - `@MainActor final class WebShellAppDelegate: NSObject, NSApplicationDelegate` — `init(shell:logger:)`, `let shell: ShellConfig`, `let logger: LaunchLogger`, `private(set) var coordinator: WebViewCoordinator?`, `private(set) var windowController: MainWindowController?`.
- Produces (app): `enum EmbeddedWebShell { static func url() throws -> URL }` with error copy "The embedded WebShell binary is missing from the app bundle. Rebuild with Tools/build-app.sh."

**Deviation:** the main menu is built by `WebShellAppDelegate.applicationWillFinishLaunching` (still inside `app.run()` started by `main.swift`), not in `main.swift` itself: the View menu's zoom items target `PageZoomController`, which needs the web view, and `WKWebView` is created once the app is launching.
**Deviation:** config failures use a shell-local `ShellConfigError` carrying the Launcher's exact copy ("Shortcut is damaged — open macOS App Duplicator and Regenerate. (…)") and every config failure exits 2 (decision 10 / dispatch). The Launcher exits 1 for configMissing/configCorrupt; `LauncherError` is not reused so the shell's exit code is not tied to `LauncherError.exitCode`.
**Deviation (additive):** extra log lines `config name= host= ua= zoom= store=`, `popup host=`, `quit`; and `webViewWebContentProcessDidTerminate` reloads the page (otherwise the window stays blank after a WebContent crash). Policy-cancelled loads (`NSURLErrorCancelled` -999, `WebKitErrorDomain` 102 — produced by every external redirect this shell cancels) do not show the error view.
**Deviation (test isolation):** the integration test launches with `HOME`/`CFFIXED_USER_HOME` = a temp dir (LaunchServices merges `OpenConfiguration.environment` over its own, as `SystemLaunch.swift` relies on). Verified in a scratch binary: `CFFIXED_USER_HOME` redirects both `FileManager.default.homeDirectoryForCurrentUser` and `NSHomeDirectory()`, so the shell's `LaunchLogger` file lands in the temp home and the test asserts it there — real `~/Library/Logs/App Duplicator` is never written.

- [ ] **Step 1: Write the failing integration test and give the integration target Core**

In `Package.swift` replace line 31

```swift
        .testTarget(name: "IntegrationTests", path: "Tests/Integration"),
```

with

```swift
        .testTarget(name: "IntegrationTests", dependencies: ["DuplicatorCore"], path: "Tests/Integration"),
```

Create `Tests/Integration/WebShellLaunchTests.swift`:

```swift
// Gated integration test: launch a web-app shortcut whose executable is the WebShell binary.
//
// Prerequisites (run from the repo root):
//   swift build -c release --product WebShell
//   MAD_INTEGRATION=1 swift test --filter IntegrationTests.WebShellLaunchTests
//
// Without MAD_INTEGRATION=1 the test is skipped. The shortcut points at https://example.invalid (a reserved
// name that never resolves), so the page load fails and the inline error view shows; the test asserts process
// identity and the shell's start log only. A window opens for a few seconds; that is expected. HOME and
// CFFIXED_USER_HOME point at a temp directory so the shell's log, defaults and web data stay out of ~/Library.

import AppKit
import DuplicatorCore
import Foundation
import XCTest

@MainActor
final class WebShellLaunchTests: XCTestCase {
    /// Repo root: three directories above `Tests/Integration/<this file>`.
    private let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var webShell: URL { root.appendingPathComponent(".build/release/WebShell") }

    private let shortcutName = "MAD WebShell Smoke"

    // MARK: - Helpers (same shape as LaunchIntegrationTests)

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mad-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Could not remove \(directory.path): \(error)")
            }
        }
        return directory
    }

    private func resolved(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    private func resolved(_ path: String) -> String {
        resolved(URL(fileURLWithPath: path))
    }

    private func processPath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : ""
    }

    /// PIDs of every running process whose executable resolves to `executable`.
    /// `NSRunningApplication.processIdentifier` stays -1 for an app opened from a
    /// test runner without a GUI session, so the shell's pid is found by path.
    private func pids(runningFrom executable: URL) -> Set<pid_t> {
        let target = resolved(executable)
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        var all = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size + 64)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &all, Int32(all.count * MemoryLayout<pid_t>.size))
        let count = Int(filled) / MemoryLayout<pid_t>.size
        return Set(all.prefix(count).filter { $0 > 0 && resolved(processPath($0)) == target })
    }

    private func terminate(_ app: NSRunningApplication) async throws {
        app.terminate()
        let graceDeadline = Date().addingTimeInterval(3)
        while !app.isTerminated && Date() < graceDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        if !app.isTerminated {
            app.forceTerminate()
        }
        let finalDeadline = Date().addingTimeInterval(5)
        while !app.isTerminated && Date() < finalDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(app.isTerminated, "WebShell shortcut did not terminate")
    }

    /// Kills anything still running from `executable` and waits until the process table is clear.
    private func reapLeftovers(runningFrom executable: URL) async throws {
        for pid in pids(runningFrom: executable) where kill(pid, SIGKILL) != 0 {
            XCTFail("kill(\(pid), SIGKILL) failed with errno \(errno)")
        }
        let deadline = Date().addingTimeInterval(5)
        while !pids(runningFrom: executable).isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Tests

    func testWebAppShortcutLaunchesUnderItsOwnBundleIdentity() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAD_INTEGRATION"] == "1", "Set MAD_INTEGRATION=1")
        guard FileManager.default.isExecutableFile(atPath: webShell.path) else {
            XCTFail("Run: swift build -c release --product WebShell")
            return
        }

        let tmp = try makeTempDirectory()
        let home = tmp.appendingPathComponent("home", isDirectory: true)
        let output = tmp.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let slug = ShortcutConfig.slug(for: shortcutName)
        let config = ShortcutConfig(
            kind: .webApp,
            name: shortcutName,
            slug: slug,
            bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: slug),
            targetPath: "",
            targetBundleIdentifier: "",
            launchMode: .dockShortcut,
            dataMode: .disabled,
            webApp: WebAppConfig(url: "https://example.invalid")
        )
        let bundle = try BundleWriter().write(config: config, executable: webShell, iconFile: nil, to: output)
        try Signer().sign(bundle: bundle, identity: nil)
        let executable = try XCTUnwrap(Bundle(url: bundle)?.executableURL, "Shortcut bundle has no executable")
        let logURL = home.appendingPathComponent(
            "Library/Logs/App Duplicator/\(ShortcutConfig.fileSystemName(for: shortcutName)).log"
        )

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path]
        let app = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)

        // Collect everything while the shell is alive; assert only after it has been terminated so a
        // failed assertion can never leave the process running.
        var launched: Set<pid_t> = []
        var logText = ""
        let expectedConfigLine = "config name=\(shortcutName) host=example.invalid"
        let deadline = Date().addingTimeInterval(10)
        while (launched.isEmpty || !logText.contains(expectedConfigLine)) && Date() < deadline {
            launched = pids(runningFrom: executable)
            if FileManager.default.fileExists(atPath: logURL.path) {
                logText = try String(contentsOf: logURL, encoding: .utf8)
            }
            if launched.isEmpty || !logText.contains(expectedConfigLine) {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        let runningBundleIdentifier = app.bundleIdentifier
        let runningPID = app.processIdentifier
        let launchedPath = launched.first.map(processPath) ?? ""

        try await terminate(app)
        try await reapLeftovers(runningFrom: executable)

        if let runningBundleIdentifier {
            XCTAssertEqual(runningBundleIdentifier, config.bundleIdentifier)
        }
        XCTAssertEqual(launched.count, 1, "Expected exactly one WebShell process: \(launched)")
        XCTAssertEqual(resolved(launchedPath), resolved(executable))
        if runningPID > 0 {
            XCTAssertEqual(launched, [runningPID])
        }
        XCTAssertTrue(logText.contains("start pid="), "Shell log: \(logText)")
        XCTAssertTrue(logText.contains(expectedConfigLine), "Shell log: \(logText)")
        XCTAssertFalse(logText.contains("exit 2"), "Shell rejected its MADConfig: \(logText)")
        XCTAssertTrue(pids(runningFrom: executable).isEmpty, "A WebShell process was left running")
    }
}
```

- [ ] **Step 2: Run the integration test and watch it fail**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && MAD_INTEGRATION=1 swift test --filter IntegrationTests.WebShellLaunchTests`
Expected: FAIL — `error: -[IntegrationTests.WebShellLaunchTests testWebAppShortcutLaunchesUnderItsOwnBundleIdentity] : failed - Run: swift build -c release --product WebShell` and `Executed 1 test, with 1 failure`. (There is no `WebShell` product yet, so `.build/release/WebShell` does not exist.)

- [ ] **Step 3: Add the WebShell product and target**

In `Package.swift` products, after `.executable(name: "Launcher", targets: ["Launcher"]),` (line 10) add:

```swift
        .executable(name: "WebShell", targets: ["WebShell"]),
```

In targets, after `.executableTarget(name: "Launcher", dependencies: ["DuplicatorCore"], path: "Launcher/Sources/Launcher"),` (line 25) add:

```swift
        // Web-app shortcut executable (Phase 4 skeleton decision 2). Programmatic AppKit + WebKit, no resources.
        .executableTarget(name: "WebShell", dependencies: ["DuplicatorCore"], path: "WebShell/Sources/WebShell"),
```

- [ ] **Step 4: Create `WebShell/Sources/WebShell/ShellConfig.swift`**

```swift
import AppKit
import DuplicatorCore
import Foundation

/// Why a web-app shortcut could not start. Copy matches the Launcher's `LauncherError` so users see one message family.
enum ShellConfigError: Error, Equatable, LocalizedError {
    case configMissing
    case configCorrupt(String)

    var errorDescription: String? {
        switch self {
        case .configMissing:
            "Shortcut is damaged — open macOS App Duplicator and Regenerate. (MADConfig is missing.)"
        case .configCorrupt(let detail):
            "Shortcut is damaged — open macOS App Duplicator and Regenerate. (\(detail))"
        }
    }
}

/// The shortcut's `MADConfig`, validated for a web app (skeleton decisions 4 and 10).
struct ShellConfig: Sendable {
    let shortcut: ShortcutConfig
    let webApp: WebAppConfig
    let baseURL: URL
    let policy: WebHostPolicy

    /// Reads `MADConfig` from an Info.plist dictionary (normally `Bundle.main.infoDictionary`).
    static func load(infoDictionary: [String: Any]) throws -> ShellConfig {
        guard let raw = infoDictionary[ShortcutConfig.infoPlistKey] else {
            throw ShellConfigError.configMissing
        }
        guard let dictionary = raw as? [String: Any] else {
            throw ShellConfigError.configCorrupt("MADConfig is not a dictionary")
        }
        let shortcut: ShortcutConfig
        do {
            shortcut = try ShortcutConfig(plistDictionary: dictionary)
        } catch {
            throw ShellConfigError.configCorrupt(String(describing: error))
        }
        guard shortcut.kind == .webApp, let webApp = shortcut.webApp else {
            throw ShellConfigError.configCorrupt("MADConfig has no webApp settings")
        }
        let baseURL: URL
        do {
            baseURL = try WebAppURLValidator.validate(webApp.url)
        } catch {
            throw ShellConfigError.configCorrupt("webApp url is not a valid https:// address")
        }
        return ShellConfig(
            shortcut: shortcut,
            webApp: webApp,
            baseURL: baseURL,
            policy: WebHostPolicy(baseURL: baseURL, extraHosts: webApp.extraHosts)
        )
    }
}

/// Loads the bundle's configuration or shows the failure alert and exits 2.
@MainActor
func loadShellConfigOrExit(logger: LaunchLogger) -> ShellConfig {
    do {
        return try ShellConfig.load(infoDictionary: Bundle.main.infoDictionary ?? [:])
    } catch {
        failAndExit(error, logger: logger)
    }
}

/// Logs the error, shows a critical alert and exits with status 2 (skeleton decision 10). Mirrors the Launcher's `fail`.
@MainActor
func failAndExit(_ error: Error, logger: LaunchLogger) -> Never {
    logger.log("error \(error.localizedDescription)")
    logger.log("exit 2")
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = "Shortcut could not start"
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .critical
    alert.addButton(withTitle: "OK")
    alert.runModal()
    exit(2)
}
```

- [ ] **Step 5: Create `WebShell/Sources/WebShell/WebViewCoordinator.swift`**

```swift
import AppKit
import DuplicatorCore
import WebKit

/// Owns the main web view, its configuration and every popup window (skeleton decisions 5, 6, 8, 10).
@MainActor
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let webView: WKWebView
    /// Called with the page title whenever `webView.title` changes. Reserved for Task 3 (badge parsing);
    /// the window title has its own observation in `MainWindowController`.
    var titleDidChange: ((String) -> Void)?
    /// Called when a main-frame provisional load fails with a user-visible error.
    var provisionalLoadDidFail: ((Error) -> Void)?
    /// Called when a main-frame navigation commits.
    var navigationDidCommit: (() -> Void)?

    private let shell: ShellConfig
    private let logger: LaunchLogger
    private let userContentController: WKUserContentController
    private var popupWindows: [NSWindow] = []
    private var titleObservation: NSKeyValueObservation?

    init(shell: ShellConfig, logger: LaunchLogger) {
        self.shell = shell
        self.logger = logger
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: WebShellScripts.badgeBridge, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: WebShellScripts.notificationShim, injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: shell.webApp.dataStoreID)
        userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.customUserAgent = shell.webApp.userAgent.customUserAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.titleDidChange?(self.webView.title ?? "")
            }
        }
    }

    /// Registers a page-to-native message handler. `WKUserContentController` retains `handler` strongly,
    /// so the handler must not retain this coordinator or its web view.
    func addMessageHandler(_ handler: WKScriptMessageHandler, name: String) {
        userContentController.add(handler, name: name)
    }

    func loadHome() {
        load(shell.baseURL)
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    // MARK: - Navigation policy (skeleton decision 6)

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        if WebHostPolicy.isInternalScheme(url) {
            return .allow
        }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            openExternally(url)
            return .cancel
        }
        guard let targetFrame = navigationAction.targetFrame else {
            // A new-window request (target=_blank, window.open): allow so WebKit asks for a popup.
            return .allow
        }
        if !targetFrame.isMainFrame || webView !== self.webView {
            // Subframes are never redirected; popup windows are exempt so OAuth completes.
            return .allow
        }
        if shell.policy.allowsInPlace(url) {
            return .allow
        }
        openExternally(url)
        return .cancel
    }

    private func openExternally(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" {
            logger.log("redirect host=\(url.host() ?? "")")
        } else {
            logger.log("redirect scheme=\(scheme)")
        }
        if !NSWorkspace.shared.open(url) {
            logger.log("error no application opens scheme=\(scheme)")
        }
    }

    // MARK: - Load results

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        navigationDidCommit?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard !Self.isPolicyCancellation(nsError) else { return }
        logLoadError(nsError)
        guard webView === self.webView else { return }
        provisionalLoadDidFail?(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard !Self.isPolicyCancellation(nsError) else { return }
        logLoadError(nsError)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        logger.log("error web content process terminated")
        webView.reload()
    }

    /// Cancellations caused by this shell (external redirects) or by a newer load are not load failures.
    private static func isPolicyCancellation(_ error: NSError) -> Bool {
        (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == "WebKitErrorDomain" && error.code == 102)
    }

    private func logLoadError(_ error: NSError) {
        let failingURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        logger.log("error load host=\(failingURL?.host() ?? "") domain=\(error.domain) code=\(error.code)")
    }

    // MARK: - Popups (skeleton decision 6)

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let width = max(320, windowFeatures.width.map { CGFloat($0.doubleValue) } ?? 900)
        let height = max(240, windowFeatures.height.map { CGFloat($0.doubleValue) } ?? 700)
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        // WebKit requires the passed configuration: it shares the data store, process pool and user scripts.
        let popup = WKWebView(frame: frame, configuration: configuration)
        popup.customUserAgent = self.webView.customUserAgent
        popup.navigationDelegate = self
        popup.uiDelegate = self
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = shell.shortcut.name
        window.contentView = popup
        window.delegate = self
        window.center()
        popupWindows.append(window)
        logger.log("popup host=\(navigationAction.request.url?.host() ?? "")")
        window.makeKeyAndOrderFront(nil)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let window = popupWindows.first(where: { $0.contentView === webView }) else { return }
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        popupWindows.removeAll { $0 === window }
    }
}
```

- [ ] **Step 6: Create `WebShell/Sources/WebShell/MainWindowController.swift`**

```swift
import AppKit
import DuplicatorCore
import WebKit

/// The shortcut's main window: hosts the web view, mirrors the page title and shows an inline load-error view.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let frameAutosaveName = "MADMainWindow"

    let window: NSWindow
    private let coordinator: WebViewCoordinator
    private let shell: ShellConfig
    private let errorView: NSStackView
    private let errorDetail: NSTextField
    private let retryButton: NSButton
    private var retryURL: URL?
    private var titleObservation: NSKeyValueObservation?

    init(coordinator: WebViewCoordinator, shell: ShellConfig, logger: LaunchLogger) {
        self.coordinator = coordinator
        self.shell = shell
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let headline = NSTextField(labelWithString: "This page could not be loaded")
        headline.font = .boldSystemFont(ofSize: 17)
        errorDetail = NSTextField(wrappingLabelWithString: "")
        errorDetail.alignment = .center
        errorDetail.preferredMaxLayoutWidth = 420
        retryButton = NSButton(title: "Retry", target: nil, action: nil)
        retryButton.keyEquivalent = "\r"
        errorView = NSStackView(views: [headline, errorDetail, retryButton])
        super.init()

        retryButton.target = self
        retryButton.action = #selector(retryLoad(_:))
        errorView.orientation = .vertical
        errorView.alignment = .centerX
        errorView.spacing = 12
        errorView.isHidden = true

        let container = NSView()
        let webView = coordinator.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        errorView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        container.addSubview(errorView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            errorView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            errorView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            errorView.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -48),
        ])

        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = NSSize(width: 480, height: 320)
        window.title = shell.shortcut.name
        window.contentView = container
        window.delegate = self
        window.center()
        if !window.setFrameAutosaveName(Self.frameAutosaveName) {
            logger.log("error frame autosave name \(Self.frameAutosaveName) already in use")
        }

        titleObservation = webView.observe(\.title, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.updateTitle()
            }
        }
        coordinator.provisionalLoadDidFail = { [weak self] error in
            self?.showError(error)
        }
        coordinator.navigationDidCommit = { [weak self] in
            self?.hideError()
        }
    }

    /// Brings the main window to the front (Dock reopen now; the status item in Task 3).
    func showWindow() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func showError(_ error: Error) {
        retryURL = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
        errorDetail.stringValue = error.localizedDescription
        coordinator.webView.isHidden = true
        errorView.isHidden = false
    }

    func hideError() {
        errorView.isHidden = true
        coordinator.webView.isHidden = false
    }

    @objc private func retryLoad(_ sender: Any?) {
        errorDetail.stringValue = "Retrying…"
        coordinator.load(retryURL ?? shell.baseURL)
    }

    private func updateTitle() {
        let pageTitle = coordinator.webView.title ?? ""
        window.title = pageTitle.isEmpty ? shell.shortcut.name : pageTitle
    }
}
```

- [ ] **Step 7: Create `WebShell/Sources/WebShell/MainMenu.swift`**

```swift
import AppKit
import DuplicatorCore
import WebKit

/// Drives `webView.pageZoom` from the View menu and keeps the live value in the shell's own defaults under
/// `MADPageZoom` (skeleton decision 5: the signed bundle's Info.plist is never written). Config `pageZoom` is
/// only the initial value; a stored value wins.
@MainActor
final class PageZoomController: NSObject {
    static let defaultsKey = "MADPageZoom"
    static let step = 0.1

    private let defaults: UserDefaults
    private let webView: WKWebView

    init(defaults: UserDefaults, configZoom: Double, webView: WKWebView) {
        self.defaults = defaults
        self.webView = webView
        super.init()
        let stored = defaults.object(forKey: Self.defaultsKey) as? Double
        webView.pageZoom = CGFloat(WebAppConfig.clampedZoom(stored ?? configZoom))
    }

    @objc func zoomIn(_ sender: Any?) {
        apply(Double(webView.pageZoom) + Self.step)
    }

    @objc func zoomOut(_ sender: Any?) {
        apply(Double(webView.pageZoom) - Self.step)
    }

    @objc func actualSize(_ sender: Any?) {
        apply(1.0)
    }

    private func apply(_ value: Double) {
        let zoom = WebAppConfig.clampedZoom((value * 100).rounded() / 100)
        webView.pageZoom = CGFloat(zoom)
        defaults.set(zoom, forKey: Self.defaultsKey)
    }
}

/// Programmatic main menu (skeleton decision 2). The Edit menu is required for Cmd-C/V/X/A inside WKWebView.
@MainActor
enum MainMenu {
    static func build(appName: String, zoom: PageZoomController) -> (main: NSMenu, windows: NSMenu) {
        let main = NSMenu()

        let app = NSMenu(title: appName)
        app.addItem(withTitle: "About \(appName)",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others",
                                     action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenuItem(app))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pastePlain = edit.addItem(withTitle: "Paste and Match Style",
                                      action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenuItem(edit))

        let view = NSMenu(title: "View")
        let zoomIn = view.addItem(withTitle: "Zoom In", action: #selector(PageZoomController.zoomIn(_:)), keyEquivalent: "=")
        zoomIn.target = zoom
        let zoomOut = view.addItem(withTitle: "Zoom Out", action: #selector(PageZoomController.zoomOut(_:)), keyEquivalent: "-")
        zoomOut.target = zoom
        let actualSize = view.addItem(withTitle: "Actual Size",
                                      action: #selector(PageZoomController.actualSize(_:)), keyEquivalent: "0")
        actualSize.target = zoom
        main.addItem(submenuItem(view))

        let windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(.separator())
        windows.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenuItem(windows))

        return (main, windows)
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
```

- [ ] **Step 8: Create `WebShell/Sources/WebShell/WebShellAppDelegate.swift` and `WebShell/Sources/WebShell/main.swift`**

`WebShellAppDelegate.swift`:

```swift
import AppKit
import DuplicatorCore

/// Application delegate of a web-app shortcut. Task 3 adds the badge, notification and status-item controllers here.
@MainActor
final class WebShellAppDelegate: NSObject, NSApplicationDelegate {
    let shell: ShellConfig
    let logger: LaunchLogger
    private(set) var coordinator: WebViewCoordinator?
    private(set) var windowController: MainWindowController?
    /// Retained here: menu item targets are weak.
    private var zoomController: PageZoomController?

    init(shell: ShellConfig, logger: LaunchLogger) {
        self.shell = shell
        self.logger = logger
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let coordinator = WebViewCoordinator(shell: shell, logger: logger)
        let zoom = PageZoomController(defaults: .standard, configZoom: shell.webApp.pageZoom, webView: coordinator.webView)
        let menus = MainMenu.build(appName: shell.shortcut.name, zoom: zoom)
        NSApp.mainMenu = menus.main
        NSApp.windowsMenu = menus.windows
        self.coordinator = coordinator
        zoomController = zoom
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let coordinator else { return }
        let controller = MainWindowController(coordinator: coordinator, shell: shell, logger: logger)
        windowController = controller
        logger.log(
            "config name=\(shell.shortcut.name) host=\(shell.baseURL.host() ?? "") ua=\(shell.webApp.userAgent.rawValue) "
                + "zoom=\(coordinator.webView.pageZoom) store=\(shell.webApp.dataStoreID.uuidString)"
        )
        // LaunchServices activates a normal launch; not calling NSApp.activate() keeps `activates = false` honest.
        controller.window.makeKeyAndOrderFront(nil)
        coordinator.loadHome()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.showWindow()
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.log("quit")
    }
}
```

`main.swift`:

```swift
import AppKit
import DuplicatorCore

// Entry point of a web-app shortcut (skeleton decision 2). Top-level code runs on the main actor.
// The shell never execs, so the process keeps the shortcut's bundle identity (decision 14).
let shortcutName = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
let logger = LaunchLogger(name: shortcutName)
logger.log("start pid=\(getpid()) bundle=\(Bundle.main.bundlePath)")

let shell = loadShellConfigOrExit(logger: logger)

let app = NSApplication.shared
let appDelegate = WebShellAppDelegate(shell: shell, logger: logger)  // global: NSApplication.delegate is weak
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
```

- [ ] **Step 9: Build, run the integration test green, and confirm nothing else moved**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift build -c release --product WebShell 2>&1 | tail -3`
Expected: `Build of product 'WebShell' complete!` and no `warning:`/`error:` lines for `WebShell/Sources` (check with `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift build -c release --product WebShell 2>&1 | grep -c "WebShell/Sources"` → `0`).

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && MAD_INTEGRATION=1 swift test --filter IntegrationTests.WebShellLaunchTests`
Expected: PASS — `Executed 1 test, with 0 failures`. A "MAD WebShell Smoke" window appears briefly showing "This page could not be loaded" (no network is used: `.invalid` never resolves).

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && pgrep -fl "MAD WebShell Smoke" ; echo "exit=$?"`
Expected: no process lines, `exit=1` (nothing left running).

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter IntegrationTests`
Expected: `Executed 3 tests, with 3 tests skipped and 0 failures` (ungated).

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests`
Expected: `Executed 171 tests, with 0 failures` (Task 1 count; Task 2 adds no Core code).

- [ ] **Step 10: Commit the shell**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add Package.swift WebShell/Sources/WebShell Tests/Integration/WebShellLaunchTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Add the WebShell executable for web-app shortcuts

WebShell is a programmatic AppKit and WebKit app that runs inside each web-app shortcut bundle under the
shortcut's own identity. It reads MADConfig (exit 2 with an alert when the webApp settings are missing or
invalid), opens a WKWebView on its own persistent data store with the configured user agent and user
scripts, keeps in-scope hosts in place and sends everything else to the default browser, lets OAuth popups
share the configuration, persists page zoom per shortcut and remembers the window frame. A gated
integration test launches a generated shortcut and checks its bundle identity and executable path.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 11: Write the failing embed smoke test**

In `App/Tests/SmokeTests.swift`, after `testEmbeddedLauncherIsPresentAndSigned()` (ends line 17) add:

```swift
    func testEmbeddedWebShellIsPresentAndSigned() throws {
        let webShell = try EmbeddedWebShell.url()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: webShell.path))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", webShell.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "embedded WebShell must carry a valid signature")
    }
```

- [ ] **Step 12: Run it and watch it fail**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/SmokeTests`
Expected: FAIL — build error `cannot find 'EmbeddedWebShell' in scope` and `** TEST FAILED **`.

- [ ] **Step 13: Create `App/Sources/App/EmbeddedWebShell.swift`**

```swift
import Foundation

/// The Phase 4 `WebShell` binary copied into `Contents/Resources/WebShell` by the "Embed WebShell" build phase.
enum EmbeddedWebShell {
    enum Error: Swift.Error, LocalizedError {
        case missing

        var errorDescription: String? {
            "The embedded WebShell binary is missing from the app bundle. Rebuild with Tools/build-app.sh."
        }
    }

    /// URL of the embedded web shell; throws when the build phase did not run (for example a bare `swift build`).
    static func url() throws -> URL {
        guard let url = Bundle.main.url(forResource: "WebShell", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw Error.missing
        }
        return url
    }
}
```

- [ ] **Step 14: Embed the binary (project.yml) and build it in both scripts**

`App/project.yml`: append a second item to the same `postBuildScripts:` list, directly after the `Embed Launcher` item's last line (`            fi`, line 92) and before line 94 `MacAppDuplicatorTests:`, at the same indentation as `- name: Embed Launcher`:

```yaml
      - name: Embed WebShell
        shell: /bin/bash
        # Same shape as Embed Launcher: runs on every build so the WebShell build below always runs and a stale
        # binary is never embedded.
        basedOnDependencyAnalysis: false
        inputFiles:
          - "$(SRCROOT)/../.build/release/WebShell"
        outputFiles:
          - "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/WebShell"
        script: |
          set -euo pipefail
          WEBSHELL_SRC="${SRCROOT}/../.build/release/WebShell"
          # Always build: SwiftPM is incremental, and a build started from Xcode must not embed a stale WebShell.
          env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin xcrun swift build -c release --product WebShell --package-path "${SRCROOT}/.."
          DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/WebShell"
          mkdir -p "$(dirname "$DEST")"
          cp -f "$WEBSHELL_SRC" "$DEST"
          chmod 755 "$DEST"
          if [ "${EXPANDED_CODE_SIGN_IDENTITY:--}" = "-" ] || [ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
            codesign --force --sign - "$DEST"
          else
            codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp "$DEST"
          fi
```

`Tools/build-app.sh` line 3 becomes:

```bash
# Without --identity the app and the embedded Launcher and WebShell are ad hoc signed.
```

and after line 29 (`swift build -c release --product Launcher`) add:

```bash
swift build -c release --product WebShell
```

`Tools/test-app.sh`: after line 18 (`swift build -c release --product Launcher`) add:

```bash
swift build -c release --product WebShell
```

- [ ] **Step 15: Run the smoke test green, the full app suite, and a real app build**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/SmokeTests`
Expected: PASS — `Executed 4 tests, with 0 failures` and `** TEST SUCCEEDED **`.

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh`
Expected: `** TEST SUCCEEDED **`, 185 tests (184 before this task + 1), 0 failures.

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/build-app.sh && codesign --verify --strict "$(find App/build -name 'macOS App Duplicator.app' -maxdepth 4 -type d | head -1)/Contents/Resources/WebShell" && echo VERIFIED`
Expected: build succeeds and `VERIFIED` prints (if `build-app.sh` reports its output path elsewhere, verify `Contents/Resources/WebShell` inside the app path it prints).

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && git status --short`
Expected: exactly `App/Sources/App/EmbeddedWebShell.swift`, `App/Tests/SmokeTests.swift`, `App/project.yml`, `Tools/build-app.sh`, `Tools/test-app.sh` (the generated Xcode project is not tracked; if it shows up, stop and report).

- [ ] **Step 16: Commit the embedding**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add App/Sources/App/EmbeddedWebShell.swift App/Tests/SmokeTests.swift App/project.yml Tools/build-app.sh Tools/test-app.sh && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Embed the WebShell binary in the app bundle

The app now builds the WebShell product and copies it into Contents/Resources/WebShell with an
Embed WebShell build phase shaped like Embed Launcher, signed the same way. EmbeddedWebShell locates
it for the shortcut builder, and a smoke test checks that the embedded copy exists and verifies.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

**Reviewer notes**
- Policy logic itself is unit-tested in Core (`WebHostPolicy`, Task 1); the shell's `decidePolicyFor` is glue covered by the integration launch plus Task 6 manual acceptance. External `target=_blank` links open in an in-app popup (decision 6 popup exemption); worth a Known Limitation line in Task 6.
- `madBadge`/`madNotification` handlers do not exist until Task 3: the injected scripts' `postMessage` calls are no-ops until then (Task 1 scripts must guard `window.webkit.messageHandlers.<name>`; confirm in `WebShellScripts`).
- `titleDidChange` is left free for Task 3; the window title uses its own KVO in `MainWindowController`, so the two never overwrite each other.
- Exit code: 2 for every config failure (Launcher uses 1/2/3/4). `failAndExit` duplicates the Launcher's alert copy rather than importing it (Launcher is an executable target).
- `BundleWriter()` is assumed to keep its no-argument init after Task 1 (as today).
- Test residue: LaunchServices registers the temp bundle (same as the Launcher integration tests). If cfprefsd ignores `CFFIXED_USER_HOME`, the window frame autosave may leave `~/Library/Preferences/com.mikekuta.appduplicator.mad-webshell-smoke.plist` (fixed name, one file, the shell's own domain — never the app's or the test runner's `UserDefaults.standard`).

## Resolved by coordinator

- JS alert/confirm/prompt panels and `runOpenPanelWith` are added by Task 3 in `WebViewCoordinator+Dialogs.swift`; Task 2 leaves those four `WKUIDelegate` methods unimplemented.
- `NSRunningApplication.bundleIdentifier` may be nil without a GUI session; the test asserts it only when non-nil, and process identity is carried by the `proc_pidpath` comparison.

---

### Task 3: WebShell features — badge, notifications, background mode + status item, page dialogs

Covers skeleton decisions 7 (badge), 8 (notifications) and 9 (background mode + status item). It also covers the decision 4 rule that `backgroundMode` only counts when `menuBarIcon` is on, the decision 10 log lines for badge changes and notification deliveries, and the coordinator-requested `WKUIDelegate` page dialogs.

Everything lives in Task 2's `WebShell` executable target. The decision logic is in AppKit-free types, tested by a new `WebShellTests` target through `@testable import WebShell`. The AppKit / UserNotifications / WebKit glue is kept thin and is checked by the build, by Task 2's gated launch test, and by the manual pass in Step 33.

Prerequisite: Tasks 1 and 2 are on `main`.

Probe evidence comes from a scratch package under the scratchpad, not the repo. Setup:
- Swift 6.4 (swiftlang-6.4.0.34.1), tools-version 6.2, `swiftLanguageModes [.v6]`, macOS 26 platform.
- A copy of DuplicatorCore, with `LaunchLogger.init(name:directory:maxBytes:)` left `internal` as Task 2 leaves it.
- Stubs of the Task 1 names, and Task 2 stubs shaped like `task-2.md`: `MainWindowController: NSObject, NSWindowDelegate` owning `window`, and `WebViewCoordinator: NSObject, WKUIDelegate` with `titleDidChange` / `addMessageHandler`.
- Every Task 3 file below, exactly as written here, plus the Step 28-29 wiring.

Results:
- `swift build --build-tests` printed `Build complete!` with no warnings.
- `swift build --target WebShell` printed `Build complete!`.
- `swift test` reported `Executed 34 tests, with 0 failures`.
- A marker file written by the stub `main.swift` was never created, so the executable's entry point does not run under test.

**Files**
- Create: `WebShell/Sources/WebShell/WebShellMessages.swift`
- Create: `WebShell/Sources/WebShell/BackgroundModePolicy.swift`
- Create: `WebShell/Sources/WebShell/StatusItemController.swift`
- Create: `WebShell/Sources/WebShell/BadgeController.swift`
- Create: `WebShell/Sources/WebShell/NotificationRouter.swift`
- Create: `WebShell/Sources/WebShell/WebViewCoordinator+Dialogs.swift`
- Create: `WebShell/Sources/WebShell/NotificationBridge.swift`
- Create: `WebShell/Sources/WebShell/WebShellFeatures.swift`
- Create: `WebShell/Tests/WebShellTests/TestSupport.swift`
- Create: `WebShell/Tests/WebShellTests/WebShellMessagesTests.swift`
- Create: `WebShell/Tests/WebShellTests/BackgroundModePolicyTests.swift`
- Create: `WebShell/Tests/WebShellTests/StatusItemTextTests.swift`
- Create: `WebShell/Tests/WebShellTests/BadgeControllerTests.swift`
- Create: `WebShell/Tests/WebShellTests/NotificationRouterTests.swift`
- Create: `WebShell/Tests/WebShellTests/DialogPresentationTests.swift`
- Modify: `Package.swift` (looked at 1-32 at `761401a`). Task 2 adds the `WebShell` executable target; this task adds one test target directly after it.
- Modify: `WebShell/Sources/WebShell/MainWindowController.swift` (Task 2's file as written in `task-2.md` Step 6, plan lines 538-654). Two members go after `func showWindow()`.
- Modify: `WebShell/Sources/WebShell/WebShellAppDelegate.swift` (Task 2's file as written in `task-2.md` Step 8, plan lines 763-849). Touches `applicationDidFinishLaunching(_:)`, `applicationShouldTerminateAfterLastWindowClosed(_:)` and `applicationShouldHandleReopen(_:hasVisibleWindows:)`.
- Read only: `WebShell/Sources/WebShell/WebViewCoordinator.swift` (Task 2, `task-2.md` Step 5, plan lines 350-537).
- Read only: `Packages/DuplicatorCore/Sources/DuplicatorCore/LaunchLogger.swift` lines 1-62:
  - `rotationThreshold` (line 7)
  - `fileURL` (line 9)
  - internal `init(name:directory:maxBytes:)` (line 18)
  - `log(_:)`, which writes `<ISO 8601> <line>` (line 29)
- Read only: `Packages/DuplicatorCore/Sources/DuplicatorCore/ShortcutConfig.swift` lines 15-56: `name` (line 15), `menuBarIcon` (line 28), init (line 37).
- Read only: `Packages/DuplicatorCore/Sources/DuplicatorCore/BundleWriter.swift` lines 69-83 (`CFBundleName = config.name`).
- Read only: `Tests/Integration/LaunchIntegrationTests.swift` lines 46-68 (the `MAD_INTEGRATION` gate and the `addTeardownBlock` do/catch pattern that `TestSupport.swift` mirrors).

**Interfaces**

Consumes from Task 1 (`task-1-interfaces.md`, module DuplicatorCore):
- `BadgeTitleParser` (`init(pattern: String?)`, `pattern`, `usedFallbackPattern`, `count(in:) -> Int?`).
- `WebShellScripts.badgeHandlerName`, `WebShellScripts.notificationHandlerName` and `WebShellScripts.notificationClickedScript(id: UUID) -> String`. The click script is only ever built by this function.
- `WebAppConfig.badgeRegex: String?` and `WebAppConfig.backgroundMode: Bool`.

Consumes from existing DuplicatorCore:
- `ShortcutConfig.name` and `ShortcutConfig.menuBarIcon`.
- `LaunchLogger`, with `log(_:)`, `rotationThreshold` and `fileURL`.
- The internal `LaunchLogger.init(name:directory:maxBytes:)`, used only by `TestSupport.swift` via `@testable import DuplicatorCore`. Task 2 keeps it internal and there is no Core change.

Consumes from Task 2 (names confirmed in `task-2.md`):
- `@MainActor final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate`:
  - `var titleDidChange: ((String) -> Void)?`
  - `func addMessageHandler(_ handler: WKScriptMessageHandler, name: String)` (the handler is retained strongly, so it must not retain the coordinator)
  - `webView.uiDelegate = self`, also set for every popup
  - its init installs `WebShellScripts.badgeBridge` at document start, main frame only
  - its init installs `WebShellScripts.notificationShim` at document start, all frames
- `@MainActor final class MainWindowController: NSObject, NSWindowDelegate`:
  - `let window: NSWindow`, with the controller as `window.delegate`
  - `func showWindow()`, which calls `NSApp.activate()` then `window.makeKeyAndOrderFront(nil)`
- `@MainActor final class WebShellAppDelegate: NSObject, NSApplicationDelegate`:
  - `let shell: ShellConfig` (`shell.shortcut: ShortcutConfig`, `shell.webApp: WebAppConfig`) and `let logger: LaunchLogger`
  - `applicationDidFinishLaunching(_:)` builds `let controller = MainWindowController(...)` and ends with `controller.window.makeKeyAndOrderFront(nil)` then `coordinator.loadHome()`
  - `applicationShouldTerminateAfterLastWindowClosed` returns `true`
  - `applicationShouldHandleReopen` calls `windowController?.showWindow()` and returns `false`
- **Task 2 leaves the four `WKUIDelegate` dialog methods unimplemented** (JS alert, confirm, prompt, and the `<input type=file>` open panel). This task adds them in `WebViewCoordinator+Dialogs.swift`.

SDK spellings were checked in `xcrun --show-sdk-path` (Xcode MacOSX.sdk).

`WKUIDelegate.h` (every completion block is `WK_SWIFT_UI_ACTOR`, so the Swift type is `@escaping @MainActor ...`):

| Line | Selector | Completion |
|---|---|---|
| 120 | `webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:` | `() -> Void` |
| 136 | `webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:` | `(Bool)` |
| 154 | `webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:` | `(String?)` |
| 295 | `webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:` | `([URL]?)` |

Other WebKit and AppKit names:

| Header | Line(s) | Name |
|---|---|---|
| `WKOpenPanelParameters.h` | 39, 43 | `allowsMultipleSelection`, `allowsDirectories` |
| `WKFrameInfo.h` | 54 | `securityOrigin` |
| `WKSecurityOrigin.h` | 49 | `host` |
| `NSAlert.h` | 50 | `NSAlertFirstButtonReturn` |
| `NSAlert.h` | 143 | `accessoryView` |
| `NSAlert.h` | 152 | `runModal` |
| `NSAlert.h` | 173 | `beginSheetModalForWindow:completionHandler:` |
| `NSSavePanel.h` | 196 | `beginSheetModalForWindow:completionHandler:` |
| `NSOpenPanel.h` | 24, 27, 35, 43 | `URLs`, `allowsMultipleSelection`, `canChooseFiles`, `canChooseDirectories` |

UserNotifications calls used:
- `UNUserNotificationCenter.current()`
- `requestAuthorization(options:completionHandler:)`
- `add(_:withCompletionHandler:)`
- `removeDeliveredNotifications(withIdentifiers:)`
- `UNMutableNotificationContent.threadIdentifier`
- `UNNotificationPresentationOptions.banner`
- `UNNotificationDefaultActionIdentifier`

Produces (all `internal` to module WebShell; the tests use `@testable import WebShell`):

Pure logic (unit-tested):
- `enum WebShellMessages`:
  - `NotificationMessage: Equatable { case show(id: UUID, title: String, body: String, tag: String?); case close(id: UUID) }`
  - `maxTextLength = 1_024` and `maxLoggedTitleLength = 120`
  - `badgeCount(fromMessageBody: Any) -> Int?`
  - `notification(fromMessageBody: Any) -> NotificationMessage?`
  - `loggableTitle(_:) -> String`
- `struct BackgroundModePolicy: Equatable, Sendable`:
  - `init(backgroundMode:menuBarIcon:)`
  - `showsStatusItem` and `keepsRunningWhenWindowCloses`
  - `terminatesAfterLastWindowClosed`
- `enum StatusItemText`: `title(forCount:)`, `showItemTitle(appName:)`, `quitItemTitle(appName:)`, `appName(infoDictionary:fallback:)`.
- `struct BadgeState: Equatable`:
  - `private(set) var count`
  - `badgeLabel`
  - `mutating write(_:) -> Bool`
  - `static count(fromTitle:parser:) -> Int`
- `@MainActor protocol NotificationPosting: AnyObject`: `start(onClick:)`, `post(id:title:body:tag:)`, `removeDelivered(id:)`.
- `struct NotificationTargets<Target>`:
  - `init(capacity: Int = 100)`
  - `count`
  - `subscript(id:)`
  - `insert(_:for:)` and `remove(_:)`
- `@MainActor final class NotificationRouter<Target>`:
  - `init(poster:logger:capacity:bringToFront:dispatch:)`
  - `pendingCount`
  - `start()`, `receive(_:from:)` and `click(identifier:)`
- `enum DialogPresentation`:
  - `AlertText`
  - `fallbackTitle` ("This page"), `okButtonTitle`, `cancelButtonTitle` and `textFieldWidth` (240)
  - `alertText(message:host:)`
  - `confirmed(_:) -> Bool`
  - `textInputResult(_:text:)`
  - `openPanelResult(_:urls:)`

Glue (checked by building and manually):
- `@MainActor final class StatusItemController: NSObject`:
  - `iconPointSize = 18`
  - `init(appName:icon:onShow:)`
  - `update(count:)`
  - `static menuBarImage(from:)`
- `@MainActor final class BadgeController: NSObject, WKScriptMessageHandler`:
  - `init(parser:logger:setDockBadge:)`
  - `countDidChange` and `count`
  - `titleDidChange(_:)` and `handleMessageBody(_:)`
- `struct NotificationTarget` (weak `webView`, `frame`, `world`).
- `@MainActor final class NotificationBridge: NSObject, WKScriptMessageHandler`: `init(poster:logger:bringToFront:)`, `router` and `start()`.
- `@MainActor final class UserNotificationPoster: NSObject, NotificationPosting, UNUserNotificationCenterDelegate`: `init(center: UNUserNotificationCenter = .current(), logger:)`.
- `extension WebViewCoordinator`, which adds the four dialog methods.
- `@MainActor final class WebShellFeatures`:
  - `init(webApp:menuBarIcon:appName:logger:poster:showWindow:)`
  - `install(on:)`
  - `windowShouldClose(_:) -> Bool`
  - `terminatesAfterLastWindowClosed`
  - `bringToFront()`
  - `static bringAppToFront(showWindow:)`
- `MainWindowController.shouldClose: (@MainActor (NSWindow) -> Bool)?` and `MainWindowController.windowShouldClose(_:)`.

Log lines (decision 10; a notification's body is never logged):
- `badge <n> from title|page`
- `badge pattern invalid; using default <pattern>`
- `badge message dropped (invalid payload)` (logged once)
- `notification "<title>"`
- `notification message dropped (invalid payload)` (logged once)
- `notification authorization granted|denied`
- `notification click: page no longer holds it`
- `features statusItem=<bool> background=<bool>`
- `window hidden; running in the menu bar`
- `error notification …`

---

- [ ] **Step 0: Confirm the Task 1 and Task 2 names before touching anything.**

Run:
```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && grep -nF -e 'executableTarget(name: "WebShell"' Package.swift; grep -nF -e 'final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate' -e 'var titleDidChange: ((String) -> Void)?' -e 'func addMessageHandler(_ handler: WKScriptMessageHandler, name: String)' -e 'webView.uiDelegate = self' -e 'WebShellScripts.notificationShim' -e 'runJavaScript' -e 'runOpenPanel' WebShell/Sources/WebShell/WebViewCoordinator.swift; grep -nF -e 'final class MainWindowController: NSObject, NSWindowDelegate' -e 'window.delegate = self' -e 'func showWindow()' WebShell/Sources/WebShell/MainWindowController.swift; grep -nF -e 'let shell: ShellConfig' -e 'controller.window.makeKeyAndOrderFront(nil)' -e 'coordinator.loadHome()' -e 'func applicationShouldTerminateAfterLastWindowClosed' -e 'func applicationShouldHandleReopen' WebShell/Sources/WebShell/WebShellAppDelegate.swift; grep -rnF -e 'struct BadgeTitleParser' -e 'func notificationClickedScript(id: UUID)' -e 'backgroundMode: Bool' Packages/DuplicatorCore/Sources/DuplicatorCore/
```

Expected:
- At least one hit for every pattern **except** `runJavaScript` and `runOpenPanel`. Those two must have **no** hits, because Task 2 leaves the dialog methods out.
- `WebShellScripts.notificationShim` appears exactly once in `WebViewCoordinator.swift`.

If any name differs, stop and report to the orchestrator. Do not adapt the names.

---

#### Part A — test target + message validation

- [ ] **Step 1: Add the `WebShellTests` target, the helpers and the failing message tests.**

In `Package.swift`, inside `targets:`, add this line directly after Task 2's `.executableTarget(name: "WebShell", …)` entry:

```swift
        .testTarget(name: "WebShellTests", dependencies: ["WebShell", "DuplicatorCore"], path: "WebShell/Tests/WebShellTests"),
```

Create `WebShell/Tests/WebShellTests/TestSupport.swift`. Logs go to a temporary directory, never to `~/Library/Logs/App Duplicator`. `@testable` reaches the internal `LaunchLogger.init(name:directory:maxBytes:)`.

```swift
@testable import DuplicatorCore
import Foundation
import XCTest

extension XCTestCase {
    /// A fresh directory under the system temporary directory, removed when the test ends.
    func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WebShellTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Could not remove \(directory.path): \(error)")
            }
        }
        return directory
    }

    /// A LaunchLogger that writes into a temporary directory, never `~/Library/Logs/App Duplicator`.
    func makeTemporaryLogger() throws -> LaunchLogger {
        LaunchLogger(name: "WebShellTests", directory: try makeTemporaryDirectory(), maxBytes: LaunchLogger.rotationThreshold)
    }

    /// Logged lines with the leading ISO 8601 timestamp removed.
    func loggedMessages(_ logger: LaunchLogger) throws -> [String] {
        guard FileManager.default.fileExists(atPath: logger.fileURL.path) else { return [] }
        return try String(contentsOf: logger.fileURL, encoding: .utf8)
            .split(separator: "\n")
            .map { line in
                guard let space = line.firstIndex(of: " ") else { return String(line) }
                return String(line[line.index(after: space)...])
            }
    }
}
```

Create `WebShell/Tests/WebShellTests/WebShellMessagesTests.swift`:

```swift
@testable import WebShell
import XCTest

final class WebShellMessagesTests: XCTestCase {
    private let idText = "6f9619ff-8b86-4011-b42d-00c04fc964ff"

    func testBadgeCountAcceptsWholeNumbers() {
        XCTAssertEqual(WebShellMessages.badgeCount(fromMessageBody: ["count": 3]), 3)
        XCTAssertEqual(WebShellMessages.badgeCount(fromMessageBody: ["count": 3.0]), 3)
        XCTAssertEqual(WebShellMessages.badgeCount(fromMessageBody: ["count": 0]), 0)
    }

    func testBadgeCountParsesNumericStrings() {
        XCTAssertEqual(WebShellMessages.badgeCount(fromMessageBody: ["count": "7"]), 7)
        XCTAssertNil(WebShellMessages.badgeCount(fromMessageBody: ["count": "seven"]))
        XCTAssertNil(WebShellMessages.badgeCount(fromMessageBody: ["count": "-2"]))
    }

    func testBadgeCountClearsWhenCountIsAbsent() {
        XCTAssertEqual(WebShellMessages.badgeCount(fromMessageBody: [String: Any]()), 0)
        XCTAssertEqual(WebShellMessages.badgeCount(fromMessageBody: ["count": NSNull()]), 0)
    }

    func testBadgeCountDropsInvalidBodies() {
        XCTAssertNil(WebShellMessages.badgeCount(fromMessageBody: "3"))
        XCTAssertNil(WebShellMessages.badgeCount(fromMessageBody: ["count": -1]))
        XCTAssertNil(WebShellMessages.badgeCount(fromMessageBody: ["count": 2.5]))
        XCTAssertNil(WebShellMessages.badgeCount(fromMessageBody: ["count": true]))
        XCTAssertNil(WebShellMessages.badgeCount(fromMessageBody: ["count": 1e300]))
        XCTAssertNil(WebShellMessages.badgeCount(fromMessageBody: ["count": [1]]))
    }

    func testNotificationAcceptsShimPayload() throws {
        let id = try XCTUnwrap(UUID(uuidString: idText))
        let message = WebShellMessages.notification(fromMessageBody: [
            "id": idText, "title": "New mail", "body": "Lunch?", "tag": "inbox",
        ])
        XCTAssertEqual(message, .show(id: id, title: "New mail", body: "Lunch?", tag: "inbox"))
    }

    func testNotificationDefaultsBodyAndDropsEmptyTag() throws {
        let id = try XCTUnwrap(UUID(uuidString: idText))
        let message = WebShellMessages.notification(fromMessageBody: ["id": idText, "title": "Ping", "tag": ""])
        XCTAssertEqual(message, .show(id: id, title: "Ping", body: "", tag: nil))
    }

    func testNotificationClose() throws {
        let id = try XCTUnwrap(UUID(uuidString: idText))
        XCTAssertEqual(WebShellMessages.notification(fromMessageBody: ["id": idText, "close": true]), .close(id: id))
    }

    func testNotificationDropsInvalidIDs() {
        let bodies: [Any] = [
            ["title": "No id"],
            ["id": "not-a-uuid", "title": "Garbage"],
            ["id": "", "title": "Empty"],
            ["id": 42, "title": "Number"],
            ["id": idText + "-junk", "title": "Trailing junk"],
            ["id": idText, "close": "yes", "title": 5],
            "not a dictionary",
        ]
        for body in bodies {
            XCTAssertNil(WebShellMessages.notification(fromMessageBody: body), "\(body)")
        }
    }

    func testNotificationRequiresStringTitle() {
        XCTAssertNil(WebShellMessages.notification(fromMessageBody: ["id": idText]))
        XCTAssertNil(WebShellMessages.notification(fromMessageBody: ["id": idText, "title": 5]))
    }

    func testNotificationTruncatesLongText() throws {
        let long = String(repeating: "x", count: 5_000)
        let message = WebShellMessages.notification(fromMessageBody: ["id": idText, "title": long, "body": long, "tag": long])
        guard case let .show(_, title, body, tag) = try XCTUnwrap(message) else {
            return XCTFail("expected .show, got \(String(describing: message))")
        }
        XCTAssertEqual(title.count, WebShellMessages.maxTextLength)
        XCTAssertEqual(body.count, WebShellMessages.maxTextLength)
        XCTAssertEqual(tag?.count, WebShellMessages.maxTextLength)
    }

    func testLoggableTitleFlattensControlCharactersAndTruncates() {
        XCTAssertEqual(WebShellMessages.loggableTitle("a\nb\tc\u{2028}d"), "a b c d")
        XCTAssertEqual(WebShellMessages.loggableTitle(String(repeating: "y", count: 500)).count, WebShellMessages.maxLoggedTitleLength)
    }
}
```

- [ ] **Step 2: Run it and watch it fail.**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter WebShellTests.WebShellMessagesTests 2>&1 | grep -oE "error: .*" | sort -u`

Expected: `error: cannot find 'WebShellMessages' in scope` (the build fails).

- [ ] **Step 3: Implement `WebShell/Sources/WebShell/WebShellMessages.swift`.**

```swift
import Foundation

/// Pure validation of the bodies the page posts to the `madBadge` and `madNotification` handlers.
enum WebShellMessages {
    enum NotificationMessage: Equatable {
        case show(id: UUID, title: String, body: String, tag: String?)
        case close(id: UUID)
    }

    static let maxTextLength = 1_024
    static let maxLoggedTitleLength = 120

    /// `{count: n}` gives n; `{}` or `{count: null}` gives 0 (clear); anything else gives nil (drop).
    static func badgeCount(fromMessageBody body: Any) -> Int? {
        guard let dictionary = body as? [String: Any] else { return nil }
        guard let value = dictionary["count"], !(value is NSNull) else { return 0 }
        if let text = value as? String {
            guard let count = Int(text), count >= 0 else { return nil }
            return count
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        guard let count = Int(exactly: number.doubleValue), count >= 0 else { return nil }
        return count
    }

    /// Shim payloads: `{id, title, body, tag}` shows, `{id, close: true}` closes. An id that is not a UUID drops the message.
    static func notification(fromMessageBody body: Any) -> NotificationMessage? {
        guard let dictionary = body as? [String: Any],
              let idText = dictionary["id"] as? String,
              let id = UUID(uuidString: idText) else { return nil }
        if let close = dictionary["close"] as? Bool, close {
            return .close(id: id)
        }
        guard let title = dictionary["title"] as? String else { return nil }
        let text = dictionary["body"] as? String ?? ""
        let tag = (dictionary["tag"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .show(id: id, title: truncated(title), body: truncated(text), tag: tag.map(truncated))
    }

    /// Single-line, length-capped form of a notification title for the launch log (bodies are never logged).
    static func loggableTitle(_ title: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                scalars.append(" ")
            default:
                scalars.append(scalar)
            }
        }
        return String(String(scalars).prefix(maxLoggedTitleLength))
    }

    private static func truncated(_ text: String) -> String {
        String(text.prefix(maxTextLength))
    }
}
```

- [ ] **Step 4: Run it and see it pass.**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter WebShellTests.WebShellMessagesTests 2>&1 | grep -E "error:|Executed" | tail -2`

Expected: `Executed 11 tests, with 0 failures`.

- [ ] **Step 5: Commit.**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add Package.swift WebShell/Tests/WebShellTests/TestSupport.swift WebShell/Tests/WebShellTests/WebShellMessagesTests.swift WebShell/Sources/WebShell/WebShellMessages.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Validate WebShell badge and notification messages" -m "Adds the WebShellTests target and pure validation of madBadge and madNotification bodies. A notification with an id that is not a UUID is dropped, a missing badge count clears the badge, and only a notification's title is ever made loggable." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

#### Part B — background-mode decision + status item

- [ ] **Step 6: Write the failing tests.**

Create `WebShell/Tests/WebShellTests/BackgroundModePolicyTests.swift`:

```swift
@testable import WebShell
import XCTest

final class BackgroundModePolicyTests: XCTestCase {
    func testBackgroundModeNeedsTheMenuBarIcon() {
        let both = BackgroundModePolicy(backgroundMode: true, menuBarIcon: true)
        XCTAssertTrue(both.showsStatusItem)
        XCTAssertTrue(both.keepsRunningWhenWindowCloses)
        XCTAssertFalse(both.terminatesAfterLastWindowClosed)

        let backgroundOnly = BackgroundModePolicy(backgroundMode: true, menuBarIcon: false)
        XCTAssertFalse(backgroundOnly.showsStatusItem)
        XCTAssertFalse(backgroundOnly.keepsRunningWhenWindowCloses)
        XCTAssertTrue(backgroundOnly.terminatesAfterLastWindowClosed)
    }

    func testMenuBarIconAloneShowsTheItemButStillQuitsOnClose() {
        let iconOnly = BackgroundModePolicy(backgroundMode: false, menuBarIcon: true)
        XCTAssertTrue(iconOnly.showsStatusItem)
        XCTAssertFalse(iconOnly.keepsRunningWhenWindowCloses)
        XCTAssertTrue(iconOnly.terminatesAfterLastWindowClosed)

        let neither = BackgroundModePolicy(backgroundMode: false, menuBarIcon: false)
        XCTAssertEqual(neither, BackgroundModePolicy(backgroundMode: true, menuBarIcon: false))
        XCTAssertTrue(neither.terminatesAfterLastWindowClosed)
    }
}
```

Create `WebShell/Tests/WebShellTests/StatusItemTextTests.swift`:

```swift
import AppKit
@testable import WebShell
import XCTest

final class StatusItemTextTests: XCTestCase {
    func testTitleShowsCountOnlyAboveZero() {
        XCTAssertEqual(StatusItemText.title(forCount: 0), "")
        XCTAssertEqual(StatusItemText.title(forCount: -1), "")
        XCTAssertEqual(StatusItemText.title(forCount: 3), "3")
    }

    func testMenuItemTitles() {
        XCTAssertEqual(StatusItemText.showItemTitle(appName: "Gmail"), "Show Gmail")
        XCTAssertEqual(StatusItemText.quitItemTitle(appName: "Gmail"), "Quit Gmail")
    }

    func testAppNameComesFromBundleName() {
        XCTAssertEqual(StatusItemText.appName(infoDictionary: ["CFBundleName": "Gmail"], fallback: "Shell"), "Gmail")
        XCTAssertEqual(StatusItemText.appName(infoDictionary: ["CFBundleName": ""], fallback: "Shell"), "Shell")
        XCTAssertEqual(StatusItemText.appName(infoDictionary: [:], fallback: "Shell"), "Shell")
        XCTAssertEqual(StatusItemText.appName(infoDictionary: nil, fallback: "Shell"), "Shell")
    }

    @MainActor
    func testMenuBarImageIsAResized18PointCopy() {
        let icon = NSImage(size: NSSize(width: 512, height: 512))
        let image = StatusItemController.menuBarImage(from: icon)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertFalse(image.isTemplate)
        XCTAssertEqual(icon.size, NSSize(width: 512, height: 512))
        XCTAssertFalse(image === icon)
    }
}
```

- [ ] **Step 7: Run them and watch them fail.**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter WebShellTests.BackgroundModePolicyTests --filter WebShellTests.StatusItemTextTests 2>&1 | grep -oE "error: .*" | sort -u`

Expected: `error: cannot find 'BackgroundModePolicy' in scope` and `error: cannot find 'StatusItemText' in scope` (plus `StatusItemController` for the image test). The build fails.

- [ ] **Step 8: Implement both files.**

Create `WebShell/Sources/WebShell/BackgroundModePolicy.swift`:

```swift
/// Skeleton decisions 4 and 9: background mode takes effect only together with the menu bar icon.
struct BackgroundModePolicy: Equatable, Sendable {
    let showsStatusItem: Bool
    let keepsRunningWhenWindowCloses: Bool

    init(backgroundMode: Bool, menuBarIcon: Bool) {
        showsStatusItem = menuBarIcon
        keepsRunningWhenWindowCloses = backgroundMode && menuBarIcon
    }

    var terminatesAfterLastWindowClosed: Bool { !keepsRunningWhenWindowCloses }
}
```

Create `WebShell/Sources/WebShell/StatusItemController.swift`. The icon is resized as a copy, because `lockFocus` is deprecated.

```swift
import AppKit

/// Copy for the status item (skeleton decision 9).
enum StatusItemText {
    static func title(forCount count: Int) -> String {
        count > 0 ? String(count) : ""
    }

    static func showItemTitle(appName: String) -> String {
        "Show \(appName)"
    }

    static func quitItemTitle(appName: String) -> String {
        "Quit \(appName)"
    }

    /// `CFBundleName` of the shortcut bundle, or `fallback` when it is missing or empty.
    static func appName(infoDictionary: [String: Any]?, fallback: String) -> String {
        if let name = infoDictionary?["CFBundleName"] as? String, !name.isEmpty {
            return name
        }
        return fallback
    }
}

/// Menu bar item: bundle icon at 18 pt, unread count as the title, Show / Quit menu.
@MainActor
final class StatusItemController: NSObject {
    static let iconPointSize: CGFloat = 18

    private let statusItem: NSStatusItem
    private let onShow: @MainActor () -> Void

    init(appName: String, icon: NSImage, onShow: @escaping @MainActor () -> Void) {
        self.onShow = onShow
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.image = StatusItemController.menuBarImage(from: icon)
            button.imagePosition = .imageLeading
            button.title = StatusItemText.title(forCount: 0)
        }
        let menu = NSMenu()
        let show = NSMenuItem(
            title: StatusItemText.showItemTitle(appName: appName),
            action: #selector(showFromMenu(_:)),
            keyEquivalent: ""
        )
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: StatusItemText.quitItemTitle(appName: appName),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        ))
        statusItem.menu = menu
    }

    func update(count: Int) {
        statusItem.button?.title = StatusItemText.title(forCount: count)
    }

    /// A resized copy of `icon`; the original image is left untouched.
    static func menuBarImage(from icon: NSImage) -> NSImage {
        let side = NSSize(width: iconPointSize, height: iconPointSize)
        let image = icon.copy() as? NSImage ?? NSImage(size: side)
        image.size = side
        image.isTemplate = false
        return image
    }

    @objc private func showFromMenu(_ sender: NSMenuItem) {
        onShow()
    }
}
```

- [ ] **Step 9: Run them and see them pass.**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter WebShellTests.BackgroundModePolicyTests --filter WebShellTests.StatusItemTextTests 2>&1 | grep -E "error:|Executed" | tail -2`

Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 10: Commit.**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add WebShell/Tests/WebShellTests/BackgroundModePolicyTests.swift WebShell/Tests/WebShellTests/StatusItemTextTests.swift WebShell/Sources/WebShell/BackgroundModePolicy.swift WebShell/Sources/WebShell/StatusItemController.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Add the WebShell background-mode policy and status item" -m "Background mode keeps the shell running only when the menu bar icon is also on. The status item shows the bundle icon at 18 points, shows the unread count when it is above zero, and has Show and Quit items named after CFBundleName." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

#### Part C — badge merge

- [ ] **Step 11: Write the failing tests.** Create `WebShell/Tests/WebShellTests/BadgeControllerTests.swift`:

```swift
import DuplicatorCore
@testable import WebShell
import XCTest

final class BadgeStateTests: XCTestCase {
    func testWriteReportsChangesAndClampsNegatives() {
        var state = BadgeState()
        XCTAssertNil(state.badgeLabel)
        XCTAssertTrue(state.write(3))
        XCTAssertEqual(state.badgeLabel, "3")
        XCTAssertFalse(state.write(3))
        XCTAssertTrue(state.write(-5))
        XCTAssertEqual(state.count, 0)
        XCTAssertNil(state.badgeLabel)
        XCTAssertFalse(state.write(0))
    }

    func testTitleWithoutMatchClears() {
        let parser = BadgeTitleParser(pattern: nil)
        XCTAssertEqual(BadgeState.count(fromTitle: "Inbox (4) - Mail", parser: parser), 4)
        XCTAssertEqual(BadgeState.count(fromTitle: "Inbox - Mail", parser: parser), 0)
    }
}

@MainActor
final class BadgeControllerTests: XCTestCase {
    private var labels: [String?] = []
    private var published: [Int] = []

    private func makeController(pattern: String? = nil, logger: LaunchLogger) -> BadgeController {
        let controller = BadgeController(parser: BadgeTitleParser(pattern: pattern), logger: logger) { [weak self] label in
            self?.labels.append(label)
        }
        controller.countDidChange = { [weak self] count in
            self?.published.append(count)
        }
        return controller
    }

    func testLastWriterWinsAcrossTitleAndPage() throws {
        let logger = try makeTemporaryLogger()
        let controller = makeController(logger: logger)
        controller.titleDidChange("Inbox (2)")
        controller.handleMessageBody(["count": 5])
        controller.titleDidChange("Inbox")
        controller.handleMessageBody([String: Any]())
        XCTAssertEqual(labels, ["2", "5", nil])
        XCTAssertEqual(published, [2, 5, 0])
        XCTAssertEqual(controller.count, 0)
        XCTAssertEqual(try loggedMessages(logger), ["badge 2 from title", "badge 5 from page", "badge 0 from title"])
    }

    func testInvalidPatternIsLoggedOnceAtStartup() throws {
        let logger = try makeTemporaryLogger()
        let controller = makeController(pattern: "(", logger: logger)
        controller.titleDidChange("Inbox (6)")
        XCTAssertEqual(labels, ["6"])
        XCTAssertEqual(try loggedMessages(logger), [
            "badge pattern invalid; using default \(BadgeTitleParser.defaultPattern)",
            "badge 6 from title",
        ])
    }

    func testInvalidMessagesAreDroppedAndLoggedOnce() throws {
        let logger = try makeTemporaryLogger()
        let controller = makeController(logger: logger)
        controller.handleMessageBody("garbage")
        controller.handleMessageBody(["count": -3])
        XCTAssertEqual(labels, [])
        XCTAssertEqual(try loggedMessages(logger), ["badge message dropped (invalid payload)"])
    }
}
```

- [ ] **Step 12: Run them and watch them fail.**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter WebShellTests.BadgeStateTests --filter WebShellTests.BadgeControllerTests 2>&1 | grep -oE "error: .*" | sort -u`

Expected: the build fails with `error: cannot find 'BadgeState' in scope` and a `cannot find ... 'BadgeController' in scope` error.

- [ ] **Step 13: Implement `WebShell/Sources/WebShell/BadgeController.swift`.**

```swift
import AppKit
import DuplicatorCore
import WebKit

/// The badge count as last written by either source (page title or the `madBadge` bridge); last writer wins.
struct BadgeState: Equatable {
    private(set) var count = 0

    var badgeLabel: String? { count > 0 ? String(count) : nil }

    /// Stores `newCount` (negative values clamp to 0) and returns true when the stored count changed.
    mutating func write(_ newCount: Int) -> Bool {
        let clamped = max(0, newCount)
        guard clamped != count else { return false }
        count = clamped
        return true
    }

    /// A title without a match clears the badge (skeleton decision 7).
    static func count(fromTitle title: String, parser: BadgeTitleParser) -> Int {
        parser.count(in: title) ?? 0
    }
}

/// `madBadge` handler and title observer: drives the Dock badge and publishes the count to the status item.
@MainActor
final class BadgeController: NSObject, WKScriptMessageHandler {
    private let parser: BadgeTitleParser
    private let logger: LaunchLogger
    private let setDockBadge: @MainActor (String?) -> Void
    private var state = BadgeState()
    private var loggedInvalidMessage = false

    /// Receives the new count whenever it changes.
    var countDidChange: (@MainActor (Int) -> Void)?

    var count: Int { state.count }

    init(parser: BadgeTitleParser, logger: LaunchLogger, setDockBadge: @escaping @MainActor (String?) -> Void) {
        self.parser = parser
        self.logger = logger
        self.setDockBadge = setDockBadge
        super.init()
        if parser.usedFallbackPattern {
            logger.log("badge pattern invalid; using default \(parser.pattern)")
        }
    }

    func titleDidChange(_ title: String) {
        write(BadgeState.count(fromTitle: title, parser: parser), source: "title")
    }

    func handleMessageBody(_ body: Any) {
        guard let count = WebShellMessages.badgeCount(fromMessageBody: body) else {
            if !loggedInvalidMessage {
                loggedInvalidMessage = true
                logger.log("badge message dropped (invalid payload)")
            }
            return
        }
        write(count, source: "page")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WebShellScripts.badgeHandlerName else { return }
        handleMessageBody(message.body)
    }

    private func write(_ newCount: Int, source: String) {
        guard state.write(newCount) else { return }
        setDockBadge(state.badgeLabel)
        countDidChange?(state.count)
        logger.log("badge \(state.count) from \(source)")
    }
}
```

- [ ] **Step 14: Run them and see them pass.**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter WebShellTests.BadgeStateTests --filter WebShellTests.BadgeControllerTests 2>&1 | grep -E "error:|Executed" | tail -2`

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 15: Commit.**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add WebShell/Tests/WebShellTests/BadgeControllerTests.swift WebShell/Sources/WebShell/BadgeController.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Merge title and page badge counts in WebShell" -m "The Dock badge follows whichever source wrote last: the page title through BadgeTitleParser, or madBadge messages. A count of zero clears the label. Each change is logged, an invalid custom pattern is logged once, and changes are published for the status item." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

#### Part D — notification routing

- [ ] **Step 16: Write the failing tests.** Create `WebShell/Tests/WebShellTests/NotificationRouterTests.swift`. A fake poster stands in, so `UNUserNotificationCenter` is never touched.

```swift
import DuplicatorCore
@testable import WebShell
import XCTest

@MainActor
final class FakeNotificationPoster: NotificationPosting {
    struct Posted: Equatable {
        let id: UUID
        let title: String
        let body: String
        let tag: String?
    }

    private(set) var posted: [Posted] = []
    private(set) var removed: [UUID] = []
    private(set) var onClick: (@MainActor (String) -> Void)?

    func start(onClick: @escaping @MainActor (String) -> Void) {
        self.onClick = onClick
    }

    func post(id: UUID, title: String, body: String, tag: String?) {
        posted.append(Posted(id: id, title: title, body: body, tag: tag))
    }

    func removeDelivered(id: UUID) {
        removed.append(id)
    }
}

final class NotificationTargetsTests: XCTestCase {
    func testEvictsOldestBeyondCapacity() {
        let first = UUID(), second = UUID(), third = UUID()
        var targets = NotificationTargets<Int>(capacity: 2)
        targets.insert(1, for: first)
        targets.insert(2, for: second)
        targets.insert(3, for: third)
        XCTAssertEqual(targets.count, 2)
        XCTAssertNil(targets[first])
        XCTAssertEqual(targets[second], 2)
        XCTAssertEqual(targets.remove(third), 3)
        XCTAssertNil(targets.remove(third))
        XCTAssertEqual(targets.count, 1)
    }
}

@MainActor
final class NotificationRouterTests: XCTestCase {
    private var events: [String] = []

    private func makeRouter(poster: FakeNotificationPoster, logger: LaunchLogger) -> NotificationRouter<Int> {
        NotificationRouter<Int>(
            poster: poster,
            logger: logger,
            bringToFront: { [weak self] in self?.events.append("front") },
            dispatch: { [weak self] script, target in self?.events.append("dispatch \(target) \(script)") }
        )
    }

    func testShowPostsAndLogsTitleOnly() throws {
        let logger = try makeTemporaryLogger()
        let poster = FakeNotificationPoster()
        let router = makeRouter(poster: poster, logger: logger)
        let id = UUID()
        router.receive(["id": id.uuidString.lowercased(), "title": "New mail", "body": "secret body", "tag": "inbox"], from: 1)
        XCTAssertEqual(poster.posted, [.init(id: id, title: "New mail", body: "secret body", tag: "inbox")])
        XCTAssertEqual(router.pendingCount, 1)
        let messages = try loggedMessages(logger)
        XCTAssertEqual(messages, ["notification \"New mail\""])
        XCTAssertFalse(messages.contains { $0.contains("secret body") })
    }

    func testInvalidIDIsDroppedAndLoggedOnce() throws {
        let logger = try makeTemporaryLogger()
        let poster = FakeNotificationPoster()
        let router = makeRouter(poster: poster, logger: logger)
        router.receive(["id": "nope", "title": "x"], from: 1)
        router.receive(["title": "y"], from: 1)
        XCTAssertEqual(poster.posted, [])
        XCTAssertEqual(router.pendingCount, 0)
        XCTAssertEqual(try loggedMessages(logger), ["notification message dropped (invalid payload)"])
    }

    func testClickBringsWindowForwardThenDispatchesToOriginTarget() throws {
        let logger = try makeTemporaryLogger()
        let poster = FakeNotificationPoster()
        let router = makeRouter(poster: poster, logger: logger)
        router.start()
        let id = UUID()
        router.receive(["id": id.uuidString.lowercased(), "title": "Ping"], from: 7)
        let onClick = try XCTUnwrap(poster.onClick)
        onClick(id.uuidString)
        XCTAssertEqual(events, ["front", "dispatch 7 \(WebShellScripts.notificationClickedScript(id: id))"])
        XCTAssertEqual(router.pendingCount, 0)
    }

    func testCloseRemovesDeliveredAndForgetsTarget() throws {
        let logger = try makeTemporaryLogger()
        let poster = FakeNotificationPoster()
        let router = makeRouter(poster: poster, logger: logger)
        let id = UUID()
        router.receive(["id": id.uuidString.lowercased(), "title": "Ping"], from: 3)
        router.receive(["id": id.uuidString.lowercased(), "close": true], from: 3)
        XCTAssertEqual(poster.removed, [id])
        router.click(identifier: id.uuidString)
        XCTAssertEqual(events, ["front"])
        XCTAssertEqual(try loggedMessages(logger).last, "notification click: page no longer holds it")
    }

    func testClickWithGarbageIdentifierOnlyBringsWindowForward() throws {
        let logger = try makeTemporaryLogger()
        let router = makeRouter(poster: FakeNotificationPoster(), logger: logger)
        router.click(identifier: "garbage")
        XCTAssertEqual(events, ["front"])
    }
}
```

- [ ] **Step 17: Run them and watch them fail.**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter WebShellTests.NotificationTargetsTests --filter WebShellTests.NotificationRouterTests 2>&1 | grep -oE "error: .*" | sort -u`

Expected: the build fails with `cannot find ...` errors for `NotificationPosting`, `NotificationTargets` and `NotificationRouter`.

- [ ] **Step 18: Implement `WebShell/Sources/WebShell/NotificationRouter.swift`.**

```swift
import DuplicatorCore
import Foundation

/// Delivery side of web notifications. `UserNotificationPoster` wraps `UNUserNotificationCenter`;
/// tests inject a fake because the real center raises outside an app bundle.
@MainActor
protocol NotificationPosting: AnyObject {
    /// Installs the click callback (it receives the delivered request identifier) and requests authorization.
    func start(onClick: @escaping @MainActor (String) -> Void)
    func post(id: UUID, title: String, body: String, tag: String?)
    func removeDelivered(id: UUID)
}

/// Bounded FIFO map from notification id to the frame that created it (mirrors the shim's newest-100 window).
struct NotificationTargets<Target> {
    let capacity: Int
    private var order: [UUID] = []
    private var targets: [UUID: Target] = [:]

    init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    var count: Int { targets.count }

    subscript(id: UUID) -> Target? { targets[id] }

    mutating func insert(_ target: Target, for id: UUID) {
        if targets.updateValue(target, forKey: id) == nil {
            order.append(id)
        }
        while order.count > capacity {
            targets.removeValue(forKey: order.removeFirst())
        }
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> Target? {
        guard let target = targets.removeValue(forKey: id) else { return nil }
        order.removeAll { $0 == id }
        return target
    }
}

/// Validates `madNotification` messages, posts them, and routes clicks back to the originating target.
@MainActor
final class NotificationRouter<Target> {
    private let poster: NotificationPosting
    private let logger: LaunchLogger
    private let bringToFront: @MainActor () -> Void
    private let dispatch: @MainActor (String, Target) -> Void
    private var targets: NotificationTargets<Target>
    private var loggedInvalidMessage = false

    init(
        poster: NotificationPosting,
        logger: LaunchLogger,
        capacity: Int = 100,
        bringToFront: @escaping @MainActor () -> Void,
        dispatch: @escaping @MainActor (String, Target) -> Void
    ) {
        self.poster = poster
        self.logger = logger
        self.bringToFront = bringToFront
        self.dispatch = dispatch
        targets = NotificationTargets(capacity: capacity)
    }

    var pendingCount: Int { targets.count }

    func start() {
        poster.start { [weak self] identifier in
            self?.click(identifier: identifier)
        }
    }

    func receive(_ body: Any, from target: Target) {
        switch WebShellMessages.notification(fromMessageBody: body) {
        case let .show(id, title, text, tag):
            targets.insert(target, for: id)
            poster.post(id: id, title: title, body: text, tag: tag)
            logger.log("notification \"\(WebShellMessages.loggableTitle(title))\"")
        case let .close(id):
            targets.remove(id)
            poster.removeDelivered(id: id)
        case nil:
            if !loggedInvalidMessage {
                loggedInvalidMessage = true
                logger.log("notification message dropped (invalid payload)")
            }
        }
    }

    /// Notification click: bring the window forward first, then tell the page which notification was clicked.
    func click(identifier: String) {
        bringToFront()
        guard let id = UUID(uuidString: identifier), let target = targets.remove(id) else {
            logger.log("notification click: page no longer holds it")
            return
        }
        dispatch(WebShellScripts.notificationClickedScript(id: id), target)
    }
}
```

- [ ] **Step 19: Run them and see them pass.**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter WebShellTests.NotificationTargetsTests --filter WebShellTests.NotificationRouterTests 2>&1 | grep -E "error:|Executed" | tail -2`

Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 20: Commit.**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add WebShell/Tests/WebShellTests/NotificationRouterTests.swift WebShell/Sources/WebShell/NotificationRouter.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Route WebShell notifications and their clicks" -m "Validated madNotification messages are posted through an injectable poster and remembered against the frame that created them, newest 100 kept. A click brings the window forward first, then dispatches the click script built by WebShellScripts.notificationClickedScript. Close removes the delivered notification. Only titles are logged." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

#### Part E — page dialogs (`WKUIDelegate`)

- [ ] **Step 21: Write the failing tests.**

Create `WebShell/Tests/WebShellTests/DialogPresentationTests.swift`. The last test checks the four Objective-C selectors as spelled in `WKUIDelegate.h`. It fails if a Swift signature drifts, for example by dropping `@MainActor` from a completion handler: the method would then no longer satisfy the protocol requirement, and WebKit would never call it.

```swift
import AppKit
import WebKit
@testable import WebShell
import XCTest

final class DialogPresentationTests: XCTestCase {
    func testAlertTextUsesHostAsTitleAndMessageAsInformativeText() {
        XCTAssertEqual(
            DialogPresentation.alertText(message: "Leave this page?", host: "mail.example.com"),
            .init(title: "mail.example.com", informativeText: "Leave this page?")
        )
    }

    func testAlertTextFallsBackWhenHostIsEmpty() {
        XCTAssertEqual(DialogPresentation.alertText(message: "Hi", host: "").title, DialogPresentation.fallbackTitle)
    }

    func testOnlyTheFirstButtonConfirms() {
        XCTAssertTrue(DialogPresentation.confirmed(.alertFirstButtonReturn))
        XCTAssertFalse(DialogPresentation.confirmed(.alertSecondButtonReturn))
        XCTAssertFalse(DialogPresentation.confirmed(.cancel))
        XCTAssertFalse(DialogPresentation.confirmed(.abort))
    }

    func testTextInputReturnsTextOnlyForOK() {
        XCTAssertEqual(DialogPresentation.textInputResult(.alertFirstButtonReturn, text: "Mike"), "Mike")
        XCTAssertNil(DialogPresentation.textInputResult(.alertSecondButtonReturn, text: "Mike"))
    }

    func testOpenPanelReturnsURLsOnlyForOK() {
        let urls = [URL(filePath: "/tmp/upload.txt")]
        XCTAssertEqual(DialogPresentation.openPanelResult(.OK, urls: urls), urls)
        XCTAssertNil(DialogPresentation.openPanelResult(.cancel, urls: urls))
        XCTAssertNil(DialogPresentation.openPanelResult(.abort, urls: urls))
    }

    func testCoordinatorAnswersTheFourDialogSelectors() {
        XCTAssertTrue(WebViewCoordinator.conforms(to: WKUIDelegate.self))
        let selectors = [
            "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:",
            "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:",
        ]
        for selector in selectors {
            XCTAssertTrue(WebViewCoordinator.instancesRespond(to: NSSelectorFromString(selector)), selector)
        }
    }
}
```

- [ ] **Step 22: Run them and watch them fail.**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter WebShellTests.DialogPresentationTests 2>&1 | grep -oE "error: .*" | sort -u`

Expected: `error: cannot find 'DialogPresentation' in scope` (the build fails).

- [ ] **Step 23: Implement `WebShell/Sources/WebShell/WebViewCoordinator+Dialogs.swift`.**

The dialogs are presented on the window of the `webView` passed in. That is the popup's own window when a popup asks, because Task 2 sets `popup.uiDelegate = self`.

```swift
import AppKit
import WebKit

/// Copy and response mapping for page dialogs, kept free of UI so it can be unit-tested.
enum DialogPresentation {
    struct AlertText: Equatable {
        let title: String
        let informativeText: String
    }

    static let fallbackTitle = "This page"
    static let okButtonTitle = "OK"
    static let cancelButtonTitle = "Cancel"
    static let textFieldWidth: CGFloat = 240

    /// The host of the frame that opened the dialog is the alert title; the page's message is the informative text.
    static func alertText(message: String, host: String) -> AlertText {
        AlertText(title: host.isEmpty ? fallbackTitle : host, informativeText: message)
    }

    /// Only the first button (OK) confirms.
    static func confirmed(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertFirstButtonReturn
    }

    /// The typed text for OK, nil for Cancel.
    static func textInputResult(_ response: NSApplication.ModalResponse, text: String) -> String? {
        confirmed(response) ? text : nil
    }

    /// The chosen URLs for OK, nil for Cancel or a panel that failed to display.
    static func openPanelResult(_ response: NSApplication.ModalResponse, urls: [URL]) -> [URL]? {
        response == .OK ? urls : nil
    }
}

/// JavaScript alert / confirm / prompt and `<input type="file">`. Task 2's `WebViewCoordinator` is the web view's
/// `WKUIDelegate` but leaves these four methods unimplemented, so WebKit would otherwise skip the dialogs silently.
extension WebViewCoordinator {
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        let alert = makeAlert(message: message, frame: frame)
        alert.addButton(withTitle: DialogPresentation.okButtonTitle)
        present(alert, in: webView) { _ in
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = makeAlert(message: message, frame: frame)
        alert.addButton(withTitle: DialogPresentation.okButtonTitle)
        alert.addButton(withTitle: DialogPresentation.cancelButtonTitle)
        present(alert, in: webView) { response in
            completionHandler(DialogPresentation.confirmed(response))
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (String?) -> Void
    ) {
        let alert = makeAlert(message: prompt, frame: frame)
        alert.addButton(withTitle: DialogPresentation.okButtonTitle)
        alert.addButton(withTitle: DialogPresentation.cancelButtonTitle)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: DialogPresentation.textFieldWidth, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        present(alert, in: webView) { response in
            completionHandler(DialogPresentation.textInputResult(response, text: field.stringValue))
        }
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        if let window = webView.window {
            panel.beginSheetModal(for: window) { response in
                completionHandler(DialogPresentation.openPanelResult(response, urls: panel.urls))
            }
        } else {
            completionHandler(DialogPresentation.openPanelResult(panel.runModal(), urls: panel.urls))
        }
    }

    private func makeAlert(message: String, frame: WKFrameInfo) -> NSAlert {
        let text = DialogPresentation.alertText(message: message, host: frame.securityOrigin.host)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.informativeText
        return alert
    }

    /// Sheet on the web view's window; app-modal when the web view has no window.
    private func present(
        _ alert: NSAlert,
        in webView: WKWebView,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) {
        if let window = webView.window {
            alert.beginSheetModal(for: window) { response in
                completion(response)
            }
        } else {
            completion(alert.runModal())
        }
    }
}
```

- [ ] **Step 24: Run them and see them pass.**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter WebShellTests.DialogPresentationTests 2>&1 | grep -E "error:|Executed" | tail -2`

Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 25: Commit.**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add WebShell/Tests/WebShellTests/DialogPresentationTests.swift "WebShell/Sources/WebShell/WebViewCoordinator+Dialogs.swift" && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Show JavaScript dialogs and file pickers in WebShell" -m "WebViewCoordinator now implements the four WKUIDelegate dialog methods. Alert, confirm and prompt appear as NSAlert sheets titled with the page host. Only the first button confirms. Prompt seeds a 240-point text field with the default text. File inputs open an NSOpenPanel that honours multiple selection and directories, and Cancel returns nil." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

#### Part F — UserNotifications glue, feature façade, wiring into Task 2

This code needs a real app bundle, `NSApp` and `UNUserNotificationCenter`, so it is not run under xctest. The logic it calls is covered by Parts B-D.

- [ ] **Step 26: Create `WebShell/Sources/WebShell/NotificationBridge.swift`.**

The design rules that keep this code safe under Swift 6:
- The `UNUserNotificationCenterDelegate` methods are `nonisolated`. They call their completion handlers synchronously, then hop to the main actor.
- The authorization and delivery callbacks are `@Sendable` and capture only the `Sendable` `LaunchLogger`.

```swift
import AppKit
import DuplicatorCore
import UserNotifications
import WebKit

/// The frame that created a notification; its click is evaluated back in that frame and content world.
struct NotificationTarget {
    weak var webView: WKWebView?
    let frame: WKFrameInfo
    let world: WKContentWorld
}

/// `madNotification` handler (skeleton decision 8).
@MainActor
final class NotificationBridge: NSObject, WKScriptMessageHandler {
    let router: NotificationRouter<NotificationTarget>

    init(poster: NotificationPosting, logger: LaunchLogger, bringToFront: @escaping @MainActor () -> Void) {
        router = NotificationRouter(poster: poster, logger: logger, bringToFront: bringToFront) { script, target in
            guard let webView = target.webView else {
                logger.log("notification click: web view gone")
                return
            }
            webView.evaluateJavaScript(script, in: target.frame, in: target.world) { result in
                if case let .failure(error) = result {
                    logger.log("error notification click script: \(error.localizedDescription)")
                }
            }
        }
        super.init()
    }

    func start() {
        router.start()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WebShellScripts.notificationHandlerName else { return }
        let target = NotificationTarget(webView: message.webView, frame: message.frameInfo, world: message.world)
        router.receive(message.body, from: target)
    }
}

/// Real delivery through `UNUserNotificationCenter`. Built only inside the shell app, never in tests.
@MainActor
final class UserNotificationPoster: NSObject, NotificationPosting, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private let logger: LaunchLogger
    private var onClick: (@MainActor (String) -> Void)?

    init(center: UNUserNotificationCenter = .current(), logger: LaunchLogger) {
        self.center = center
        self.logger = logger
        super.init()
    }

    func start(onClick: @escaping @MainActor (String) -> Void) {
        self.onClick = onClick
        center.delegate = self
        let logger = self.logger
        center.requestAuthorization(options: [.alert, .badge, .sound]) { @Sendable granted, error in
            if let error {
                logger.log("error notification authorization: \(error.localizedDescription)")
            } else {
                logger.log("notification authorization \(granted ? "granted" : "denied")")
            }
        }
    }

    func post(id: UUID, title: String, body: String, tag: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let tag {
            content.threadIdentifier = tag
        }
        let request = UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil)
        let logger = self.logger
        center.add(request) { @Sendable error in
            if let error {
                logger.log("error notification delivery: \(error.localizedDescription)")
            }
        }
    }

    func removeDelivered(id: UUID) {
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in
                self.onClick?(identifier)
            }
        }
        completionHandler()
    }
}
```

- [ ] **Step 27: Create `WebShell/Sources/WebShell/WebShellFeatures.swift`.**

```swift
import AppKit
import DuplicatorCore

/// Wires the badge, notifications, background mode and the status item into the Task 2 shell.
@MainActor
final class WebShellFeatures {
    let policy: BackgroundModePolicy
    let badge: BadgeController
    let notifications: NotificationBridge
    private let appName: String
    private let logger: LaunchLogger
    private let showWindow: @MainActor () -> Void
    private var statusItem: StatusItemController?

    init(
        webApp: WebAppConfig,
        menuBarIcon: Bool,
        appName: String,
        logger: LaunchLogger,
        poster: NotificationPosting,
        showWindow: @escaping @MainActor () -> Void
    ) {
        policy = BackgroundModePolicy(backgroundMode: webApp.backgroundMode, menuBarIcon: menuBarIcon)
        self.appName = appName
        self.logger = logger
        self.showWindow = showWindow
        badge = BadgeController(parser: BadgeTitleParser(pattern: webApp.badgeRegex), logger: logger) { label in
            NSApp.dockTile.badgeLabel = label
        }
        notifications = NotificationBridge(poster: poster, logger: logger) {
            WebShellFeatures.bringAppToFront(showWindow: showWindow)
        }
    }

    /// Call once from `applicationDidFinishLaunching`, before the first page load.
    func install(on coordinator: WebViewCoordinator) {
        coordinator.addMessageHandler(badge, name: WebShellScripts.badgeHandlerName)
        coordinator.addMessageHandler(notifications, name: WebShellScripts.notificationHandlerName)
        let previous = coordinator.titleDidChange
        let badge = self.badge
        coordinator.titleDidChange = { title in
            previous?(title)
            badge.titleDidChange(title)
        }
        notifications.start()
        if policy.showsStatusItem {
            let showWindow = self.showWindow
            let item = StatusItemController(appName: appName, icon: NSApp.applicationIconImage) {
                WebShellFeatures.bringAppToFront(showWindow: showWindow)
            }
            item.update(count: badge.count)
            badge.countDidChange = { [weak item] count in
                item?.update(count: count)
            }
            statusItem = item
        }
        logger.log("features statusItem=\(policy.showsStatusItem) background=\(policy.keepsRunningWhenWindowCloses)")
    }

    /// Window delegate hook: in background mode hide the window and drop the Dock icon instead of closing.
    func windowShouldClose(_ window: NSWindow) -> Bool {
        guard policy.keepsRunningWhenWindowCloses else { return true }
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        logger.log("window hidden; running in the menu bar")
        return false
    }

    var terminatesAfterLastWindowClosed: Bool { policy.terminatesAfterLastWindowClosed }

    /// Show menu item, Dock click and notification click all land here.
    func bringToFront() {
        WebShellFeatures.bringAppToFront(showWindow: showWindow)
    }

    static func bringAppToFront(showWindow: @MainActor () -> Void) {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
        showWindow()
    }
}
```

- [ ] **Step 28: Add the close hook to `WebShell/Sources/WebShell/MainWindowController.swift`.**

Task 2's class already conforms to `NSWindowDelegate` and sets `window.delegate = self`. Insert these members directly after the closing brace of `func showWindow()`:

```swift

    /// Task 3: background mode hides the window instead of closing it (see WebShellFeatures.windowShouldClose).
    var shouldClose: (@MainActor (NSWindow) -> Bool)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldClose?(sender) ?? true
    }
```

- [ ] **Step 29: Wire the features into `WebShell/Sources/WebShell/WebShellAppDelegate.swift`.**

(a) Add this stored property below `private var zoomController: PageZoomController?`:

```swift
    /// Task 3: badge, notifications, background mode and the status item.
    private var features: WebShellFeatures?
```

(b) In `applicationDidFinishLaunching(_:)`, replace

```swift
        controller.window.makeKeyAndOrderFront(nil)
        coordinator.loadHome()
```

with

```swift
        controller.window.makeKeyAndOrderFront(nil)
        installFeatures(webApp: shell.webApp, shortcut: shell.shortcut, logger: logger, windowController: controller, coordinator: coordinator)
        coordinator.loadHome()
```

This puts the notification-center delegate in place before `applicationDidFinishLaunching` returns, so a click that launched the app is still delivered. It also attaches the badge and notification handlers before the first load.

(c) Replace the two delegate methods:

```swift
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        features?.terminatesAfterLastWindowClosed ?? true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let features {
            features.bringToFront()
        } else {
            windowController?.showWindow()
        }
        return false
    }
```

(d) Add this method at the end of the class:

```swift

    /// Task 3: badge, notifications, background mode and the status item (skeleton decisions 7, 8, 9).
    private func installFeatures(
        webApp: WebAppConfig,
        shortcut: ShortcutConfig,
        logger: LaunchLogger,
        windowController: MainWindowController,
        coordinator: WebViewCoordinator
    ) {
        let features = WebShellFeatures(
            webApp: webApp,
            menuBarIcon: shortcut.menuBarIcon,
            appName: StatusItemText.appName(infoDictionary: Bundle.main.infoDictionary, fallback: shortcut.name),
            logger: logger,
            poster: UserNotificationPoster(logger: logger),
            showWindow: { [weak windowController] in windowController?.showWindow() }
        )
        features.install(on: coordinator)
        windowController.shouldClose = { [weak features] window in features?.windowShouldClose(window) ?? true }
        self.features = features
    }
```

- [ ] **Step 30: Build the shell.**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift build --target WebShell 2>&1 | grep -E "error:|warning:|Build complete" | head -10`

Expected: `Build complete!` and no `error:` or `warning:` lines.

- [ ] **Step 31: Run the WebShell tests and the other package suites.**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter WebShellTests 2>&1 | grep -E "error:|Executed" | tail -2`

Expected: `Executed 34 tests, with 0 failures`.

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test 2>&1 | grep -E "error:|Executed" | tail -2`

Expected: the last `Executed` line ends `with 0 failures`. The gated integration tests count as skipped.

- [ ] **Step 32: Commit.**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add WebShell/Sources/WebShell/NotificationBridge.swift WebShell/Sources/WebShell/WebShellFeatures.swift WebShell/Sources/WebShell/MainWindowController.swift WebShell/Sources/WebShell/WebShellAppDelegate.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Wire badge, notifications and background mode into WebShell" -m "WebShellFeatures installs the madBadge and madNotification handlers, follows title changes, requests notification authorization once at launch, and adds the status item when the menu bar icon is on. With background mode on, closing the window hides it and drops the Dock icon. Show, a Dock or Finder reopen, and a notification click bring the app back as a regular app with its window in front." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 33: Live checks.**

**(a) Launch regression.** This uses Task 2's gated test, which runs with a temp HOME and a reserved `.invalid` host, so there is no network.

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift build -c release --product WebShell 2>&1 | tail -1 && MAD_INTEGRATION=1 swift test --filter IntegrationTests.WebShellLaunchTests 2>&1 | grep -E "error:|Executed" | tail -2`

Expected: `Build of product 'WebShell' complete!`, then `Executed 1 test, with 0 failures`.

Note: with Task 3 in place, the shell requests notification authorization at launch. A one-time permission prompt for "MAD WebShell Smoke" can appear, and macOS keeps a Notifications entry for that test bundle id.

**(b) Manual check, in the Phase 4 acceptance pass.** This happens once Tasks 4 and 5 can build a web shortcut (Task 6 writes `docs/acceptance/phase4-webshell.md`). Use `https://example.com`, never Mike's real web accounts, with `menuBarIcon = true` and `backgroundMode = true`. Confirm:
1. The status item shows the app icon. The shortcut lives in `~/Applications/App Duplicator`, not `/Applications`, so confirm that macOS 27 really displays it.
2. Cmd-W hides the window and drops the Dock icon while the process keeps running.
3. `Show <Name>` restores the window and the Dock icon.
4. Opening the bundle again from Finder restores it too.
5. `Quit <Name>` exits.
6. With `backgroundMode = false`, Cmd-W quits.
7. The log contains `features statusItem=true background=true` and `window hidden; running in the menu bar`.

## Deviations

**Deviation:** test commands use `swift test --filter WebShellTests.<Class>`, not planner-common's `<Target>/<Class>`. On Swift 6.4 the slash form prints `warning: No matching test cases were run`, runs zero tests and still exits 0, so every "expected pass" would pass with nothing tested. Probe: the slash form ran 0 tests; `--filter WebShellTests.BadgeStateTests` ran 2. Other task plans that use the slash form have the same problem.

**Deviation:** skeleton Task 3 says the unit-testable parts go in a `WebShell` type "that the integration test target can `@testable import`". This plan adds a separate `WebShellTests` target instead (`WebShell/Tests/WebShellTests`, depending on `WebShell` and `DuplicatorCore`):
- `IntegrationTests` holds the `MAD_INTEGRATION`-gated end-to-end tests.
- The new unit tests run on every `swift test`.
- `@testable import` of the executable target was proven in the probe. The executable's `main.swift` does not run under test.

**Deviation:** the skeleton file map lists only `BadgeController.swift`, `NotificationBridge.swift` and `StatusItemController.swift` for these features. This plan also adds `WebShellMessages.swift`, `BackgroundModePolicy.swift`, `NotificationRouter.swift`, `WebShellFeatures.swift` and the coordinator-requested `WebViewCoordinator+Dialogs.swift`. The additions are additive. They keep the logic testable without `NSApp`, which is nil under xctest, and without `UNUserNotificationCenter.current()`, which raises outside an app bundle.

**Deviation:** decision 8 calls `UNUserNotificationCenter.current()` directly. Here it sits behind `NotificationPosting`, implemented by `UserNotificationPoster`, so click and close routing can be tested with a fake. Runtime behaviour is unchanged:
- Authorization `[.alert, .badge, .sound]` is requested once at launch.
- Notifications are delivered through the current center.
- The delegate is set before `applicationDidFinishLaunching` returns.

**Deviation:** a click is evaluated in the frame and content world that posted the notification, using `evaluateJavaScript(_:in:in:completionHandler:)`, instead of in the main frame. Task 2 installs the shim in all frames, so an iframe's notification map lives in that iframe. The script text still comes only from `WebShellScripts.notificationClickedScript(id:)`.

**Deviation:** `badgeCount` also accepts a decimal-string count (`{count: "7"}`) from pages that post to `madBadge` directly. Booleans, fractions, negative numbers and out-of-range numbers are dropped.

**Deviation:** `applicationShouldHandleReopen` still returns `false`, as in Task 2, after bringing the app forward. AppKit's default reopen handling is not needed, because the window is already shown.

**Deviation:** when the frame has no host (about:blank or file frames), the dialog title falls back to `This page`. The skeleton has no dialog copy.

---

### Task 4: Presets, icon fetch, builder wiring

Skeleton decisions 11 (presets), 12 (icon), 13 (builder part), 14 (running indicator). Depends on Task 1 (`WebAppConfig`, `UserAgentPreset`, `BadgeTitleParser`, `WebAppURLValidator`, `BundleWriter.write(config:executable:iconFile:to:)`, `ShortcutKind.webApp`) and Task 2 (`EmbeddedWebShell.url()` in `App/Sources/App/EmbeddedWebShell.swift`, used only in Steps 27, 30 and 44).

**Files:**
- Modify `Packages/CompatProfiles/Resources/profiles.json` (last lines 190-200 and line 3 `updated`; the file ends with `"webApps": {}`).
- Modify `Packages/CompatProfiles/Tests/CompatProfilesTests/SeedProfilesTests.swift` (lines 61-72).
- Modify `App/Sources/Model/ProfilesModel.swift` (lines 1-5 imports, 42-44 after `profile(forBundleIdentifier:)`).
- Modify `App/Sources/Services/IconRenderer.swift` (lines 1-3 imports, 29-34 `initials`, 58-62 `writeICNS(generatedFor:)`).
- Modify `App/Sources/Services/IconResolver.swift` (lines 1-3 imports, 18-42).
- Create `App/Sources/Services/WebIconFetcher.swift`.
- Modify `App/Sources/Services/ShortcutBuilder.swift` (lines 8-29 errors, 40-87 init/create/regenerate/duplicate, 231-251 `write`).
- Modify `App/Sources/Model/RunningShortcutMonitor.swift` (lines 9-63) and `App/Sources/Model/ShortcutLibrary.swift` (line 79).
- Modify `App/Sources/Model/ShortcutRecord.swift` (lines 18-19), `App/Sources/Model/LibraryScanner.swift` (lines 66-77), `App/Sources/Views/ShortcutRowView.swift` (lines 45-54).
- Modify `App/Sources/App/AppState.swift` (lines 46-72 only: the stored property, `init`, `builder`; NOT `create(config:)`, which Task 5 owns) and `App/Sources/App/MacAppDuplicatorApp.swift` (lines 25-36).
- Modify tests: `App/Tests/TestSupport/AppTestSupport.swift` (append after line 68), `App/Tests/Services/ShortcutBuilderTests.swift` (lines 1-28 and append), `App/Tests/EndToEnd/ShortcutBuilderEndToEndTests.swift` (line 19), `App/Tests/Services/IconRendererTests.swift` (append), `App/Tests/Model/ProfilesModelTests.swift` (lines 1-5, append), `App/Tests/Model/RunningShortcutMonitorTests.swift` (append), `App/Tests/Model/LibraryScannerTests.swift` (append).
- Create tests: `App/Tests/Services/StubURLProtocol.swift`, `App/Tests/Services/WebIconFetcherTests.swift`, `App/Tests/App/AppStateWebShellTests.swift`.
- No `project.yml` edit: xcodegen regenerates the project from the source folders on every `Tools/test-app.sh` run.

**Interfaces:**
- Consumes (Task 1): `ShortcutKind.webApp`; `ShortcutConfig.webApp: WebAppConfig?` and the `webApp:` initializer parameter; `WebAppConfig` (`url`, `var dataStoreID: UUID`, `init(url:dataStoreID:...)`); `UserAgentPreset`; `WebAppURLValidator.validate(_:)`; `BadgeTitleParser(pattern:)`; `BundleWriter.write(config:executable:iconFile:to:) throws -> URL`. Consumes (Task 2): `EmbeddedWebShell.url() throws -> URL`. Existing: `WebAppPreset` (CompatProfiles), `IconRenderer.generatedTile(initials:size:)`, `IconRenderer.writeICNS(from:to:)`, `Signer().sign(bundle:identity:)`, `LibraryScanner.record(forBundleAt:)`.
- Produces:
  - `ProfilesModel.webAppPresets: [WebAppPreset]` (`@MainActor`, sorted by name, case-insensitive) and `static func userAgentPreset(for preset: WebAppPreset) -> UserAgentPreset` (`"chrome"` in any case is `.chrome`; nil or anything else is `.safari`).
  - `protocol WebIconFetching: Sendable { func fetchIcon(for pageURL: URL) async throws -> Data? }`; `struct URLSessionWebIconFetcher: WebIconFetching` with `init(session: URLSession = URLSessionWebIconFetcher.makeSession())` (so `URLSessionWebIconFetcher()` works), `static let maxBytes = 1_048_576`, `static let requestTimeout: TimeInterval = 15`, `static let userAgent`; `enum WebIconHTMLParser { static func iconURL(inHTML:pageURL:) -> URL? }`.
  - `IconRenderer.writeICNS(fromImageData data: Data, to url: URL) throws`, `IconRenderer.firstLetter(for:) -> String`, `IconRenderer.writeICNS(letterTileFor name: String, to url: URL) throws`.
  - `IconResolver.webAppIconFile(for:webIconData:existingIcon:scratchDirectory:) throws -> URL?`.
  - `ShortcutBuilder.init(launcherBinary: URL, webShellBinary: URL, signingIdentity: String?)`, `let webShellBinary: URL`; `create(config: ShortcutConfig, in directory: URL, webIconData: Data? = nil) throws -> URL`; `regenerate(record: ShortcutRecord, config: ShortcutConfig, webIconData: Data? = nil) throws -> URL`; `duplicate(record:newName:in:takenSlugs:)` unchanged signature; `BuilderError.webAppConfigMissing`.
  - `RunningShortcutMonitor.init(probe:identifierProbe:)`, `runningBundleIdentifiers: Set<String>`, `isRunning(bundleURL:bundleIdentifier:)`.
  - `ShortcutRecord.webAppHost: String?`; `AppState.init(settings:library:launcherBinary:webShellBinary:profiles:)`.
- **Consumed by Task 5:** `create(config:in:webIconData:)` is the single hand-off for fetched icon bytes; the builder (not the wizard) turns `webIconData` into `AppIcon.icns` through `IconRenderer.writeICNS(fromImageData:to:)` when `config.kind == .webApp && config.iconMode == .copied`, and renders the letter tile when the data is nil or undecodable and there is no icon to reuse. `URLSessionWebIconFetcher` has a no-argument `init()`. `ProfilesModel.userAgentPreset(for:)` and `webAppPresets` are as above. `AppState.create(config:webIconData:)` is Task 5's edit (AppState lines 99-111); this task does not touch it.
- **Consumed by Task 6:** `regenerate(record:config:webIconData:)` and `duplicate` of a web app with `iconMode == .copied` reuse the old bundle's `Contents/Resources/AppIcon.icns` when no new bytes are supplied and never fall back to a letter tile while that file exists; `duplicate` gives the copy a fresh `dataStoreID`. The compatibility badge is not touched here (see Open questions 6): Task 6 hides it for web apps in `EditorSections.swift:65`. `ShortcutRecord.targetExists` is true and `targetVersion` nil for web apps, so `ShortcutEditorView.swift:41` (`.disabled(!record.targetExists)`) stays enabled.

**Icon-mode meaning for web apps (binding for Tasks 5 and 6):** `.copied` = "Fetched from site" (the fetched bytes, else the bundle's existing icon, else the letter tile); `.custom` = the user's image file (`customIconPath`); `.generated` = the letter tile (first letter of the name).

**Deviation:** (0) The skeleton's badge hiding for web apps is left to Tasks 5/6, which own the views that call `CompatBadge` (`EditorSections.swift:65`, `WizardSteps.swift:69/231`); no `CompatBadge` helper is added here. (1) The skeleton says the monitor matches `NSRunningApplication.bundleIdentifier == record.config.bundleIdentifier`. It is applied to web app records only (`ShortcutLibrary.isRunning`), so native shortcuts keep today's behaviour (their launcher briefly runs under the shortcut's id before `execve`). (2) The identifier list is read by an injectable main-actor probe (`NSWorkspace.shared.runningApplications` is read on the main actor) instead of per record `runningApplications(withBundleIdentifier:)`, so tests need no running apps. (3) The letter tile for web apps uses the first letter only (skeleton 12), via new `firstLetter(for:)`; native `.generated` keeps two initials. (4) The seed names are `WhatsApp`, `Microsoft Teams`, `Microsoft Outlook` (the skeleton gives keys only). (5) For web apps the builder does not resolve a default data folder (`resolvingDefaultDataPath`), since the shell keeps its data in a `WKWebsiteDataStore`.

- [ ] **Step 1: Failing test for the three seed presets.** In `Packages/CompatProfiles/Tests/CompatProfilesTests/SeedProfilesTests.swift` replace `testSeedCarriesNoLaunchValuesYet` (lines 61-72) with the version below and add the new test after it.

```swift
    func testSeedCarriesNoLaunchValuesYet() throws {
        let document = try seed()
        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertNotNil(document.updated.wholeMatch(of: /^\d{4}-\d{2}-\d{2}$/), "updated is a YYYY-MM-DD date")
        XCTAssertGreaterThanOrEqual(document.updated, "2026-10-09")
        for (identifier, profile) in document.apps {
            XCTAssertEqual(profile.args, [], identifier)
            XCTAssertEqual(profile.env, [:], identifier)
            XCTAssertNil(profile.newWindowCommand, identifier)
        }
    }

    func testSeedShipsThreeWebAppPresets() throws {
        let document = try seed()
        XCTAssertGreaterThanOrEqual(document.updated, "2026-10-10", "the presets bump the seed date so a cached older copy never wins")
        let presets = document.webApps
        XCTAssertEqual(Set(presets.keys), ["whatsapp", "teams", "outlook"])

        let whatsapp = try XCTUnwrap(presets["whatsapp"])
        XCTAssertEqual(whatsapp.name, "WhatsApp")
        XCTAssertEqual(whatsapp.url, "https://web.whatsapp.com")
        XCTAssertEqual(whatsapp.userAgent, "chrome")
        XCTAssertEqual(whatsapp.badgeRegex, #"\((\d+)\)"#)
        XCTAssertEqual(whatsapp.extraHosts, ["whatsapp.com", "whatsapp.net"])

        let teams = try XCTUnwrap(presets["teams"])
        XCTAssertEqual(teams.name, "Microsoft Teams")
        XCTAssertEqual(teams.url, "https://teams.microsoft.com")
        XCTAssertEqual(teams.extraHosts, ["microsoft.com", "microsoftonline.com", "live.com", "office.com", "office.net", "skype.com"])

        let outlook = try XCTUnwrap(presets["outlook"])
        XCTAssertEqual(outlook.name, "Microsoft Outlook")
        XCTAssertEqual(outlook.url, "https://outlook.office.com/mail/")
        XCTAssertEqual(outlook.extraHosts, ["office.com", "office365.com", "microsoft.com", "microsoftonline.com", "live.com", "office.net"])

        for (key, preset) in presets {
            XCTAssertNil(preset.iconURL, "\(key): icons are fetched from the site")
            XCTAssertNoThrow(try WebAppURLValidator.validate(preset.url), key)
        }
        let parser = BadgeTitleParser(pattern: whatsapp.badgeRegex)
        XCTAssertFalse(parser.usedFallbackPattern)
        XCTAssertEqual(parser.count(in: "(3) WhatsApp"), 3)
    }
```

- [ ] **Step 2: Run, expect failure.**
  `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter CompatProfilesTests.SeedProfilesTests`
  Expected: `testSeedShipsThreeWebAppPresets` fails with `XCTAssertGreaterThanOrEqual failed: ("2026-10-09") is less than ("2026-10-10")` and an `XCTAssertEqual failed` on the key set; the other two tests pass.

- [ ] **Step 3: Add the presets to the seed.** In `Packages/CompatProfiles/Resources/profiles.json` change line 3 to `"updated": "2026-10-10",` and replace the last property `"webApps": {}` with:

```json
  "webApps": {
    "whatsapp": {
      "name": "WhatsApp",
      "url": "https://web.whatsapp.com",
      "userAgent": "chrome",
      "badgeRegex": "\\((\\d+)\\)",
      "extraHosts": ["whatsapp.com", "whatsapp.net"],
      "iconURL": null
    },
    "teams": {
      "name": "Microsoft Teams",
      "url": "https://teams.microsoft.com",
      "userAgent": null,
      "badgeRegex": null,
      "extraHosts": ["microsoft.com", "microsoftonline.com", "live.com", "office.com", "office.net", "skype.com"],
      "iconURL": null
    },
    "outlook": {
      "name": "Microsoft Outlook",
      "url": "https://outlook.office.com/mail/",
      "userAgent": null,
      "badgeRegex": null,
      "extraHosts": ["office.com", "office365.com", "microsoft.com", "microsoftonline.com", "live.com", "office.net"],
      "iconURL": null
    }
  }
```
  (keep the closing `}` of the document on its own line after it).

- [ ] **Step 4: Run, expect pass.** `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter CompatProfilesTests` — all CompatProfiles tests pass (the document validator accepts the three entries; the regex compiles and has a capture group).

- [ ] **Step 5: Commit.**
```
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add Packages/CompatProfiles/Resources/profiles.json Packages/CompatProfiles/Tests/CompatProfilesTests/SeedProfilesTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Seed WhatsApp, Teams and Outlook web app presets

The seed date moves to 2026-10-10 so a cached copy from before the presets cannot win over it.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 6: Failing tests for `ProfilesModel.webAppPresets` and `userAgentPreset`.** In `App/Tests/Model/ProfilesModelTests.swift` add `@testable import DuplicatorCore` after `import CompatProfiles` (line 1-2 area, before `@testable import MacAppDuplicator`) and append inside the class:

```swift
    func testWebAppPresetsAreSortedByNameAndEmptyWithoutProfiles() async throws {
        XCTAssertEqual(ProfilesModel.inert().webAppPresets, [])

        let document: [String: Any] = [
            "schemaVersion": 1, "updated": "2026-10-10", "apps": [String: Any](),
            "webApps": [
                "z": ["name": "zulu", "url": "https://z.example.test/"],
                "a": ["name": "Alpha", "url": "https://a.example.test/", "userAgent": "chrome"],
                "m": ["name": "mike", "url": "https://m.example.test/"],
            ] as [String: Any],
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: bundledURL)
        let (model, _) = makeModel()
        await model.load()

        XCTAssertEqual(model.webAppPresets.map(\.name), ["Alpha", "mike", "zulu"])
        XCTAssertEqual(model.webAppPresets.first?.userAgent, "chrome")
    }

    func testUserAgentPresetMapsChromeAndEverythingElseToSafari() {
        func preset(_ userAgent: String?) -> WebAppPreset { WebAppPreset(name: "A", url: "https://a.example.test/", userAgent: userAgent) }
        XCTAssertEqual(ProfilesModel.userAgentPreset(for: preset("chrome")), .chrome)
        XCTAssertEqual(ProfilesModel.userAgentPreset(for: preset("Chrome")), .chrome)
        XCTAssertEqual(ProfilesModel.userAgentPreset(for: preset("safari")), .safari)
        XCTAssertEqual(ProfilesModel.userAgentPreset(for: preset("firefox")), .safari)
        XCTAssertEqual(ProfilesModel.userAgentPreset(for: preset(nil)), .safari)
    }
```

- [ ] **Step 7: Run, expect failure.** `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/ProfilesModelTests` — build error `value of type 'ProfilesModel' has no member 'webAppPresets'` and `type 'ProfilesModel' has no member 'userAgentPreset'`.

- [ ] **Step 8: Implement.** In `App/Sources/Model/ProfilesModel.swift` add `import DuplicatorCore` (line 2, before `import Foundation`) and insert after `profile(forBundleIdentifier:)` (line 44):

```swift
    /// The `webApps` presets of the profiles in use, sorted by name for the wizard's preset grid.
    var webAppPresets: [WebAppPreset] {
        catalog.document.webApps.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `"chrome"` (any case) selects the Chrome desktop user agent; nil or any other value keeps Safari's.
    static func userAgentPreset(for preset: WebAppPreset) -> UserAgentPreset {
        preset.userAgent?.lowercased() == "chrome" ? .chrome : .safari
    }
```

- [ ] **Step 9: Run, expect pass.** Same command as Step 7; `ProfilesModelTests` all pass.

- [ ] **Step 10: Commit.**
```
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add App/Sources/Model/ProfilesModel.swift App/Tests/Model/ProfilesModelTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Expose web app presets and the user agent mapping on ProfilesModel

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 11: Failing tests for the image-data ICNS path.** Append to `App/Tests/Services/IconRendererTests.swift` (the file needs `import AppKit` at the top, above `import XCTest`), inside the class:

```swift
    func testFirstLetter() {
        XCTAssertEqual(IconRenderer.firstLetter(for: "WhatsApp Work"), "W")
        XCTAssertEqual(IconRenderer.firstLetter(for: "  slack"), "S")
        XCTAssertEqual(IconRenderer.firstLetter(for: "élan"), "É")
        XCTAssertEqual(IconRenderer.firstLetter(for: "   "), "?")
    }

    func testLetterTileICNSIsValid() throws {
        let out = dir.appending(path: "letter.icns")
        try IconRenderer.writeICNS(letterTileFor: "Mail Work", to: out)
        XCTAssertEqual(String(decoding: try Data(contentsOf: out).prefix(4), as: UTF8.self), "icns")
    }

    private func transparentPNG(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func isICNS(_ url: URL) throws -> Bool {
        String(decoding: try Data(contentsOf: url).prefix(4), as: UTF8.self) == "icns"
    }

    func testWriteICNSFromPNGDataProducesICNS() throws {
        let out = dir.appending(path: "data.icns")
        try IconRenderer.writeICNS(fromImageData: try transparentPNG(width: 180, height: 180), to: out)
        XCTAssertTrue(try isICNS(out))
    }

    func testWriteICNSFromNonSquareDataIsCentredNotStretched() throws {
        let out = dir.appending(path: "wide.icns")
        try IconRenderer.writeICNS(fromImageData: try transparentPNG(width: 300, height: 100), to: out)
        XCTAssertTrue(try isICNS(out))
    }

    func testWriteICNSFromICOUsesThePayloadImage() throws {
        // A one-image ICO whose payload is a PNG (the format sites ship as /favicon.ico).
        let payload = try transparentPNG(width: 32, height: 32)
        var ico = Data([0, 0, 1, 0, 1, 0])                        // reserved, type 1 (icon), one image
        ico.append(contentsOf: [32, 32, 0, 0, 1, 0, 32, 0])       // width, height, colours, reserved, planes, bit depth
        var size = UInt32(payload.count).littleEndian
        var offset = UInt32(22).littleEndian
        ico.append(Data(bytes: &size, count: 4))
        ico.append(Data(bytes: &offset, count: 4))
        ico.append(payload)
        let out = dir.appending(path: "favicon.icns")
        try IconRenderer.writeICNS(fromImageData: ico, to: out)
        XCTAssertTrue(try isICNS(out))
    }

    func testWriteICNSFromGarbageDataThrowsUnreadableImage() {
        let out = dir.appending(path: "bad.icns")
        XCTAssertThrowsError(try IconRenderer.writeICNS(fromImageData: Data("not an image".utf8), to: out)) { error in
            guard case IconRenderer.RenderError.unreadableImage = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }
```

- [ ] **Step 12: Run, expect failure.** `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/IconRendererTests` — build errors `type 'IconRenderer' has no member 'firstLetter'`, `no member 'writeICNS'` for the `letterTileFor:` and `fromImageData:` labels.

- [ ] **Step 13: Implement.** In `App/Sources/Services/IconRenderer.swift` add `import ImageIO` after `import Foundation` (line 3). Insert after `initials(for:)` (line 34):

```swift
    /// The first letter of the first word, upper-cased; "?" for an empty name. Web app tiles show one letter.
    static func firstLetter(for name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).first.flatMap { $0.first }.map { String($0).uppercased() } ?? "?"
    }
```
  Insert after `writeICNS(generatedFor:to:)` (line 62) and before `writeICNS(fromImageFile:to:)`:

```swift
    /// The letter tile of a web app (first letter of `name`) as an `.icns`.
    static func writeICNS(letterTileFor name: String, to url: URL) throws {
        try writeICNS(from: generatedTile(initials: firstLetter(for: name), size: 1024), to: url)
    }

    /// Converts image bytes (PNG, JPEG or ICO, as fetched from a site) into an `.icns`. ICO files hold several
    /// sizes; the largest frame is used. A non-square image is centred on a transparent square so it is not stretched.
    static func writeICNS(fromImageData data: Data, to url: URL) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw RenderError.unreadableImage("the fetched site icon")
        }
        var largest: CGImage?
        for index in 0..<CGImageSourceGetCount(source) {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            if let current = largest, current.width * current.height >= frame.width * frame.height { continue }
            largest = frame
        }
        guard let largest, let square = squareCanvas(containing: largest, side: 1024) else {
            throw RenderError.unreadableImage("the fetched site icon")
        }
        try writeICNS(from: square, to: url)
    }

    /// `image` scaled to fit, centred, on a transparent `side` x `side` canvas.
    private static func squareCanvas(containing image: CGImage, side: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        let scale = CGFloat(side) / CGFloat(max(image.width, image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        context.draw(image, in: CGRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2, width: width, height: height))
        return context.makeImage()
    }
```

- [ ] **Step 14: Run, expect pass.** Same command as Step 12; all `IconRendererTests` pass (the planner compiled this exact code and the four data tests in a scratch XCTest bundle: 4 of 4 pass, including the handcrafted ICO).

- [ ] **Step 15: Commit.**
```
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add App/Sources/Services/IconRenderer.swift App/Tests/Services/IconRendererTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Write ICNS files from fetched image data and single-letter tiles

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 16: Failing tests for the icon fetcher.** Create `App/Tests/Services/StubURLProtocol.swift` (shared stub, no network) and `App/Tests/Services/WebIconFetcherTests.swift` with exactly this content (13 tests: 6 parser, 7 fetcher; the planner compiled and ran them against the implementation in Step 18).

`App/Tests/Services/StubURLProtocol.swift`:
```swift
import Foundation
import Synchronization

/// A canned HTTP response for `StubURLProtocol`.
struct StubbedResponse: Sendable {
    var status: Int
    var body: Data
    /// Reported as `response.url`, to simulate a redirect that ended somewhere else.
    var finalURL: URL?

    init(status: Int = 200, body: Data = Data(), finalURL: URL? = nil) {
        self.status = status
        self.body = body
        self.finalURL = finalURL
    }

    init(html: String, status: Int = 200, finalURL: URL? = nil) {
        self.init(status: status, body: Data(html.utf8), finalURL: finalURL)
    }
}

/// What a stubbed session was asked for.
struct RecordedRequest: Sendable, Equatable {
    var url: URL
    var timeout: TimeInterval
    var userAgent: String?
}

/// Serves `routes` to any `URLSession` whose configuration lists it in `protocolClasses`; an unrouted URL fails with
/// `URLError.cannotFindHost`. No test using it touches the network. Routes are keyed by absolute URL string and tests
/// use their own host names, so test classes never see each other's entries.
final class StubURLProtocol: URLProtocol {
    static let routes = Mutex<[String: StubbedResponse]>([:])
    static let requests = Mutex<[RecordedRequest]>([])

    /// An ephemeral session that only this protocol serves.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func setRoute(_ url: String, _ response: StubbedResponse) {
        routes.withLock { $0[url] = response }
    }

    static func removeRoutes(_ urls: [String]) {
        routes.withLock { table in urls.forEach { table[$0] = nil } }
    }

    static func requests(forHost host: String) -> [RecordedRequest] {
        requests.withLock { $0.filter { $0.url.host == host } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.requests.withLock {
            $0.append(RecordedRequest(url: url, timeout: request.timeoutInterval, userAgent: request.value(forHTTPHeaderField: "User-Agent")))
        }
        guard let stub = Self.routes.withLock({ $0[url.absoluteString] }),
              let response = HTTPURLResponse(url: stub.finalURL ?? url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
```

`App/Tests/Services/WebIconFetcherTests.swift`:
```swift
import AppKit
import XCTest
@testable import MacAppDuplicator

final class WebIconHTMLParserTests: XCTestCase {
    private let page = URL(string: "https://www.example.test/app/index.html")!

    private func icon(_ html: String) -> String? {
        WebIconHTMLParser.iconURL(inHTML: html, pageURL: page)?.absoluteString
    }

    func testAppleTouchIconBeatsAnyIconRegardlessOfSizeOrOrder() {
        let html = """
        <head><link rel="icon" sizes="512x512" href="/big.png">
        <link rel="apple-touch-icon" sizes="120x120" href="/touch-120.png"></head>
        """
        XCTAssertEqual(icon(html), "https://www.example.test/touch-120.png")
    }

    func testPrecomposedTouchIconCountsAsATouchIcon() {
        XCTAssertEqual(icon(#"<link rel="icon" href="/a.png"><link rel="apple-touch-icon-precomposed" href="/pre.png">"#),
                       "https://www.example.test/pre.png")
    }

    func testLargestSizesWinsWithinAClassAndTheFirstWinsATie() {
        let touch = """
        <link rel="apple-touch-icon" sizes="76x76" href="/76.png">
        <link rel="apple-touch-icon" sizes="180x180" href="/180.png">
        <link rel="apple-touch-icon" sizes="152x152" href="/152.png">
        """
        XCTAssertEqual(icon(touch), "https://www.example.test/180.png")
        let tie = #"<link rel="icon" href="/first.png"><link rel="icon" href="/second.png">"#
        XCTAssertEqual(icon(tie), "https://www.example.test/first.png")
        let sized = #"<link rel="icon" sizes="16x16 32x32 48x48" href="/multi.png"><link rel="icon" sizes="64x64" href="/64.png">"#
        XCTAssertEqual(icon(sized), "https://www.example.test/64.png", "the largest declared size of a link counts, so 64x64 beats 48x48")
    }

    func testRelTokensAndAttributeOrderAndQuoting() {
        XCTAssertEqual(icon(#"<LINK HREF='/single.png' REL='Shortcut Icon'>"#), "https://www.example.test/single.png")
        XCTAssertEqual(icon("<link\n  rel=icon\n  href=/bare.png\n>"), "https://www.example.test/bare.png")
        XCTAssertEqual(icon(#"<link rel="icon" href="/a.png?x=1&amp;y=2">"#), "https://www.example.test/a.png?x=1&y=2")
    }

    func testRelativeAndAbsoluteHrefsResolveAgainstThePage() {
        XCTAssertEqual(icon(#"<link rel="icon" href="icon.png">"#), "https://www.example.test/app/icon.png")
        XCTAssertEqual(icon(#"<link rel="icon" href="../up.png">"#), "https://www.example.test/up.png")
        XCTAssertEqual(icon(#"<link rel="icon" href="//cdn.example.test/proto.png">"#), "https://cdn.example.test/proto.png")
        XCTAssertEqual(icon(#"<link rel="icon" href="https://cdn.example.test/abs.png">"#), "https://cdn.example.test/abs.png")
    }

    func testUnusableLinksAreSkipped() {
        let html = """
        <link rel="mask-icon" href="/mask.svg">
        <link rel="icon" type="image/svg+xml" href="/vector">
        <link rel="icon" href="/vector.SVG">
        <link rel="icon" href="data:image/png;base64,AAAA">
        <link rel="icon" href="javascript:alert(1)">
        <link rel="stylesheet" href="/site.css">
        <link rel="icon">
        <link rel="icon" href="/ok.png">
        """
        XCTAssertEqual(icon(html), "https://www.example.test/ok.png")
        XCTAssertNil(icon("<html><head><title>No icons</title></head></html>"))
        XCTAssertNil(icon(""))
    }
}

final class URLSessionWebIconFetcherTests: XCTestCase {
    private var host: String!
    private var routes: [String] = []
    private var fetcher: URLSessionWebIconFetcher!

    override func setUp() {
        host = "icons-\(UUID().uuidString.prefix(8).lowercased()).test"
        routes = []
        fetcher = URLSessionWebIconFetcher(session: StubURLProtocol.makeSession())
    }

    override func tearDown() {
        StubURLProtocol.removeRoutes(routes)
    }

    private func url(_ path: String) -> URL { URL(string: "https://\(host!)\(path)")! }

    private func route(_ path: String, _ response: StubbedResponse) {
        routes.append(url(path).absoluteString)
        StubURLProtocol.setRoute(url(path).absoluteString, response)
    }

    private func pngData(letter: String, size: Int = 64) throws -> Data {
        let image = IconRenderer.generatedTile(initials: letter, size: size)
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    func testDownloadsTheDeclaredTouchIconAndSendsTheFetchersHeaders() async throws {
        let png = try pngData(letter: "T")
        route("/", StubbedResponse(html: #"<link rel="icon" href="/small.png"><link rel="apple-touch-icon" href="/touch.png">"#))
        route("/touch.png", StubbedResponse(body: png))

        let data = try await fetcher.fetchIcon(for: url("/"))

        XCTAssertEqual(data, png)
        let requests = StubURLProtocol.requests(forHost: host)
        XCTAssertEqual(requests.map(\.url), [url("/"), url("/touch.png")], "the lower-ranked /small.png is never requested")
        XCTAssertTrue(requests.allSatisfy { $0.timeout == 15 })
        XCTAssertTrue(requests.allSatisfy { $0.userAgent == URLSessionWebIconFetcher.userAgent })
    }

    func testRelativeHrefResolvesAgainstThePageAfterARedirect() async throws {
        let png = try pngData(letter: "R")
        let landing = URL(string: "https://landing-\(host!)/inbox/")!
        route("/", StubbedResponse(html: #"<link rel="icon" href="logo.png">"#, finalURL: landing))
        StubURLProtocol.setRoute("https://landing-\(host!)/inbox/logo.png", StubbedResponse(body: png))
        routes.append("https://landing-\(host!)/inbox/logo.png")

        let data = try await fetcher.fetchIcon(for: url("/"))

        XCTAssertEqual(data, png)
    }

    func testFallsBackToFaviconIcoWhenThePageDeclaresNothingOrTheDeclaredIconFails() async throws {
        let ico = try pngData(letter: "F")
        route("/", StubbedResponse(html: "<html><head></head></html>"))
        route("/favicon.ico", StubbedResponse(body: ico))
        let none = try await fetcher.fetchIcon(for: url("/"))
        XCTAssertEqual(none, ico)

        route("/", StubbedResponse(html: #"<link rel="icon" href="/gone.png">"#))
        route("/gone.png", StubbedResponse(status: 404))
        let declaredFails = try await fetcher.fetchIcon(for: url("/"))
        XCTAssertEqual(declaredFails, ico)
    }

    func testNilWhenThePageIsNotSuccessfulOrNothingDecodes() async throws {
        route("/down", StubbedResponse(status: 503, body: Data("<link rel=icon href=/i.png>".utf8)))
        route("/i.png", StubbedResponse(body: try pngData(letter: "X")))
        let serverError = try await fetcher.fetchIcon(for: url("/down"))
        XCTAssertNil(serverError)
        XCTAssertEqual(StubURLProtocol.requests(forHost: host).map(\.url), [url("/down")], "a failed page stops the search")

        route("/junk", StubbedResponse(html: #"<link rel="icon" href="/junk.png">"#))
        route("/junk.png", StubbedResponse(body: Data("not an image".utf8)))
        route("/favicon.ico", StubbedResponse(status: 404))
        let undecodable = try await fetcher.fetchIcon(for: url("/junk"))
        XCTAssertNil(undecodable)
    }

    func testAnUnreachableIconCandidateMovesOnAndAnUnreachablePageThrows() async throws {
        let png = try pngData(letter: "U")
        route("/", StubbedResponse(html: #"<link rel="icon" href="https://unrouted-\#(host!)/x.png">"#))
        route("/favicon.ico", StubbedResponse(body: png))
        let data = try await fetcher.fetchIcon(for: url("/"))
        XCTAssertEqual(data, png)

        do {
            _ = try await fetcher.fetchIcon(for: URL(string: "https://nothing-\(host!)/")!)
            XCTFail("an unreachable page should throw")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotFindHost)
        }
    }

    func testOnlyHTTPSAndHTTPPagesAreFetched() async throws {
        let ftp = try await fetcher.fetchIcon(for: URL(string: "ftp://\(host!)/")!)
        let file = try await fetcher.fetchIcon(for: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertNil(ftp)
        XCTAssertNil(file)
        XCTAssertTrue(StubURLProtocol.requests(forHost: host).isEmpty)
    }

    func testThePageIsCutAtOneMebibyteAndAnOversizedIconIsRefused() async throws {
        let late = #"<link rel="icon" href="/late.png">"#
        route("/", StubbedResponse(html: String(repeating: " ", count: URLSessionWebIconFetcher.maxBytes) + late))
        route("/late.png", StubbedResponse(body: try pngData(letter: "L")))
        route("/favicon.ico", StubbedResponse(status: 404))
        let ignored = try await fetcher.fetchIcon(for: url("/"))
        XCTAssertNil(ignored, "a link after the first MiB is not read")
        XCTAssertFalse(StubURLProtocol.requests(forHost: host).contains { $0.url == url("/late.png") })

        route("/huge", StubbedResponse(html: #"<link rel="icon" href="/huge.png">"#))
        var huge = try pngData(letter: "H")
        huge.append(Data(count: URLSessionWebIconFetcher.maxBytes))
        route("/huge.png", StubbedResponse(body: huge))
        let refused = try await fetcher.fetchIcon(for: url("/huge"))
        XCTAssertNil(refused, "an icon over 1 MiB is refused, not truncated")
    }
}
```

- [ ] **Step 17: Run, expect failure.** `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/WebIconHTMLParserTests -only-testing:MacAppDuplicatorTests/URLSessionWebIconFetcherTests` — build errors `cannot find 'WebIconHTMLParser' in scope` and `cannot find type 'URLSessionWebIconFetcher' in scope`. (If the second test class has a different name in the file, use the class names `grep -n "final class" App/Tests/Services/WebIconFetcherTests.swift` prints.)

- [ ] **Step 18: Implement.** Create `App/Sources/Services/WebIconFetcher.swift` with exactly:

```swift
import CoreGraphics
import Foundation
import ImageIO
import os

/// Finds the icon of a web page for a Web App shortcut (spec §7). Best effort: nil means "no usable icon", and the
/// caller falls back to the generated letter tile.
protocol WebIconFetching: Sendable {
    /// - Returns: PNG, ICO or JPEG bytes that ImageIO can decode, or nil when the page has no usable icon.
    func fetchIcon(for pageURL: URL) async throws -> Data?
}

/// Picks the icon address out of a page's HTML. Pure and offline so the precedence rules are tested without a network.
enum WebIconHTMLParser {
    /// `apple-touch-icon` links beat `icon` links; within a class the largest `sizes` wins and the first one in the
    /// document breaks ties. SVG icons are skipped (ImageIO cannot decode them), as are non-http(s) and `data:` hrefs.
    /// Relative hrefs are resolved against `pageURL`. Nil when the page declares no usable icon.
    static func iconURL(inHTML html: String, pageURL: URL) -> URL? {
        var best: (rank: Int, area: Int, url: URL)?
        for tag in linkTags(in: html) {
            let attributes = attributes(in: tag)
            guard let rel = attributes["rel"], let href = attributes["href"] else { continue }
            let tokens = Set(rel.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            let rank: Int
            if !tokens.isDisjoint(with: ["apple-touch-icon", "apple-touch-icon-precomposed"]) {
                rank = 2
            } else if tokens.contains("icon") {
                rank = 1
            } else {
                continue
            }
            if attributes["type"]?.lowercased().contains("svg") == true { continue }
            guard let url = resolve(href, against: pageURL), url.path.lowercased().hasSuffix(".svg") == false else { continue }
            let area = area(ofSizes: attributes["sizes"])
            if let current = best, (current.rank, current.area) >= (rank, area) { continue }
            best = (rank, area, url)
        }
        return best?.url
    }

    private static let linkTagPattern = regex(#"<link\b[^>]*>"#, options: [.caseInsensitive])
    private static let attributePattern = regex(#"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
    private static let sizePattern = regex(#"(\d+)\s*[xX]\s*(\d+)"#)

    /// The patterns above are constants; a failure here is a programming error caught by the first test run.
    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid built-in pattern \(pattern): \(error)")
        }
    }

    private static func linkTags(in html: String) -> [String] {
        let range = NSRange(html.startIndex..., in: html)
        return linkTagPattern.matches(in: html, range: range).compactMap { Range($0.range, in: html).map { String(html[$0]) } }
    }

    /// Lower-cased attribute names mapped to their values; the first occurrence of a name wins.
    private static func attributes(in tag: String) -> [String: String] {
        var result: [String: String] = [:]
        let range = NSRange(tag.startIndex..., in: tag)
        for match in attributePattern.matches(in: tag, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let name = tag[nameRange].lowercased()
            let value = (2...4).lazy.compactMap { Range(match.range(at: $0), in: tag) }.first.map { String(tag[$0]) } ?? ""
            if result[name] == nil { result[name] = value }
        }
        return result
    }

    /// The largest `WxH` in a `sizes` value; `any` counts as very large; no value counts as 0.
    private static func area(ofSizes sizes: String?) -> Int {
        guard let sizes = sizes?.lowercased() else { return 0 }
        if sizes.split(whereSeparator: \.isWhitespace).contains("any") { return Int.max }
        let range = NSRange(sizes.startIndex..., in: sizes)
        return sizePattern.matches(in: sizes, range: range).compactMap { match -> Int? in
            guard let w = Range(match.range(at: 1), in: sizes).flatMap({ Int(sizes[$0]) }),
                  let h = Range(match.range(at: 2), in: sizes).flatMap({ Int(sizes[$0]) }) else { return nil }
            return w * h
        }.max() ?? 0
    }

    private static func resolve(_ href: String, against pageURL: URL) -> URL? {
        let cleaned = href.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "&amp;", with: "&")
        guard !cleaned.isEmpty, let url = URL(string: cleaned, relativeTo: pageURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }
}

/// Downloads a page's icon with an injected `URLSession`. Reads at most 1 MiB of the page and of the icon, gives each
/// request 15 seconds, and never throws for an HTTP error status: those mean "no icon" (nil).
struct URLSessionWebIconFetcher: WebIconFetching {
    static let maxBytes = 1_048_576
    static let requestTimeout: TimeInterval = 15
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static let logger = Logger(subsystem: "com.mikekuta.MacAppDuplicator", category: "WebIconFetcher")

    let session: URLSession

    init(session: URLSession = URLSessionWebIconFetcher.makeSession()) {
        self.session = session
    }

    /// An ephemeral session (no cookies, no cache) with the fetcher's timeouts.
    static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    func fetchIcon(for pageURL: URL) async throws -> Data? {
        guard let scheme = pageURL.scheme?.lowercased(), scheme == "https" || scheme == "http", pageURL.host != nil else { return nil }
        guard let page = try await get(pageURL, oversize: .truncate) else { return nil }
        // Redirects (for example web.whatsapp.com → another host) change what relative hrefs mean.
        let baseURL = page.finalURL
        let html = String(decoding: page.data, as: UTF8.self)
        var candidates: [URL] = []
        if let declared = WebIconHTMLParser.iconURL(inHTML: html, pageURL: baseURL) { candidates.append(declared) }
        if let favicon = URL(string: "/favicon.ico", relativeTo: baseURL)?.absoluteURL, !candidates.contains(favicon) {
            candidates.append(favicon)
        }
        for candidate in candidates {
            do {
                if let icon = try await get(candidate, oversize: .reject), Self.isDecodableImage(icon.data) { return icon.data }
            } catch let error as URLError {
                // The icon is optional; a candidate that cannot be reached just moves on to the next one.
                Self.logger.info("Icon candidate unreachable (\(error.code.rawValue, privacy: .public))")
            }
        }
        return nil
    }

    private struct Fetched {
        var data: Data
        var finalURL: URL
    }

    private enum Oversize {
        /// A page is cut at the cap: the icon links sit in `<head>`, far before 1 MiB.
        case truncate
        /// An icon over the cap is refused outright (a truncated image would decode as a partial picture).
        case reject
    }

    /// GET `url`. Nil for a non-2xx status, and for a body over the cap when `oversize` is `.reject`.
    private func get(_ url: URL, oversize: Oversize) async throws -> Fetched? {
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,image/*;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        var data = Data()
        for try await byte in bytes {
            if data.count >= Self.maxBytes {
                switch oversize {
                case .truncate: return Fetched(data: data, finalURL: http.url ?? url)
                case .reject: return nil
                }
            }
            data.append(byte)
        }
        return Fetched(data: data, finalURL: http.url ?? url)
    }

    static func isDecodableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}
```

- [ ] **Step 19: Run, expect pass.** Same command as Step 17 — 13 tests pass.

- [ ] **Step 20: Commit.**
```
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add App/Sources/Services/WebIconFetcher.swift App/Tests/Services/WebIconFetcherTests.swift App/Tests/Services/StubURLProtocol.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Fetch a site's touch icon or favicon for web app shortcuts

The page's link tags are ranked (touch icon over plain icon, largest declared size first) with /favicon.ico as the fallback. Oversized responses are cut off and undecodable ones are skipped.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 21: Failing tests for the web icon resolver.** Append to `App/Tests/Services/IconResolverTests.swift` inside the class (confirm the file's existing temp-dir property name with `sed -n 1,25p App/Tests/Services/IconResolverTests.swift` and use it; the code below calls it `dir`; add `import AppKit` at the top if missing):

```swift
    private func webConfig(mode: IconMode) -> ShortcutConfig {
        var config = makeWebConfig(name: "Chat Work", url: "https://chat.example.test/")
        config.iconMode = mode
        return config
    }

    private func png() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testWebCopiedWithFetchedBytesWritesFetchedICNS() throws {
        let url = try XCTUnwrap(IconResolver.webAppIconFile(for: webConfig(mode: .copied), webIconData: try png(), existingIcon: nil, scratchDirectory: dir))
        XCTAssertEqual(url.lastPathComponent, "web-fetched-icon.icns")
        XCTAssertEqual(String(decoding: try Data(contentsOf: url).prefix(4), as: UTF8.self), "icns")
    }

    func testWebCopiedWithUndecodableBytesFallsBackToLetterTile() throws {
        let url = try XCTUnwrap(IconResolver.webAppIconFile(for: webConfig(mode: .copied), webIconData: Data("<html>".utf8), existingIcon: nil, scratchDirectory: dir))
        XCTAssertEqual(url.lastPathComponent, "web-letter-icon.icns")
    }

    func testWebCopiedWithoutBytesKeepsTheExistingIcon() throws {
        let existing = dir.appending(path: "old.icns")
        try Data("keep me".utf8).write(to: existing)
        let url = try XCTUnwrap(IconResolver.webAppIconFile(for: webConfig(mode: .copied), webIconData: nil, existingIcon: existing, scratchDirectory: dir))
        XCTAssertEqual(try Data(contentsOf: url), Data("keep me".utf8))
        XCTAssertNotEqual(url, existing, "the icon is copied into scratch so replacing the old bundle cannot delete it")
    }

    func testWebCopiedWithNothingGetsLetterTile() throws {
        let url = try XCTUnwrap(IconResolver.webAppIconFile(for: webConfig(mode: .copied), webIconData: nil, existingIcon: nil, scratchDirectory: dir))
        XCTAssertEqual(url.lastPathComponent, "web-letter-icon.icns")
    }

    func testWebGeneratedIgnoresFetchedBytesAndCustomRequiresTheFile() throws {
        let tile = try XCTUnwrap(IconResolver.webAppIconFile(for: webConfig(mode: .generated), webIconData: try png(), existingIcon: nil, scratchDirectory: dir))
        XCTAssertEqual(tile.lastPathComponent, "web-letter-icon.icns")

        var custom = webConfig(mode: .custom)
        custom.customIconPath = dir.appending(path: "missing.png").path
        XCTAssertThrowsError(try IconResolver.webAppIconFile(for: custom, webIconData: nil, existingIcon: nil, scratchDirectory: dir)) { error in
            guard case IconResolver.IconError.customFileMissing = error else { return XCTFail("\(error)") }
        }
    }
```

- [ ] **Step 22: Test-support helper.** Append to `App/Tests/TestSupport/AppTestSupport.swift` (after `makeConfig`, line 63):

```swift
/// A web app shortcut config: `kind == .webApp`, no target. `iconMode` is `.copied` (the fetched or kept site icon).
func makeWebConfig(name: String = "Chat Work", url: String = "https://chat.example.test/", dataStoreID: UUID = UUID()) -> ShortcutConfig {
    let slug = ShortcutConfig.slug(for: name)
    var config = ShortcutConfig(
        kind: .webApp, name: name, slug: slug, bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: slug),
        targetPath: "", targetBundleIdentifier: "", webApp: WebAppConfig(url: url, dataStoreID: dataStoreID)
    )
    config.iconMode = .copied
    return config
}
```

- [ ] **Step 23: Run, expect failure.** `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/IconResolverTests` — `type 'IconResolver' has no member 'webAppIconFile'`.

- [ ] **Step 24: Implement.** In `App/Sources/Services/IconResolver.swift` add `import os` after `import Foundation` and, inside the enum after the `IconError` declaration (line 16), add the logger and the new function (insert the function after `iconFile`, i.e. after line 42):

```swift
    private static let logger = Logger(subsystem: "com.mikekuta.MacAppDuplicator", category: "IconResolver")
```
```swift
    /// The icon file for a web app, always inside `scratchDirectory` (BundleWriter replaces the old bundle, so an
    /// existing icon is copied out first).
    /// - `.copied`: `webIconData` converted to `.icns` when present and decodable; else a copy of `existingIcon`
    ///   (regenerate / duplicate without a new fetch); else the first-letter tile.
    /// - `.custom`: `customIconPath` converted; a missing file throws `customFileMissing`.
    /// - `.generated`: the first-letter tile.
    static func webAppIconFile(for config: ShortcutConfig, webIconData: Data?, existingIcon: URL?, scratchDirectory: URL) throws -> URL? {
        let fileManager = FileManager.default
        switch config.iconMode {
        case .custom:
            guard let path = config.customIconPath, fileManager.fileExists(atPath: path) else {
                throw IconError.customFileMissing(config.customIconPath ?? "")
            }
            let out = scratchDirectory.appending(path: "web-custom-icon.icns")
            do { try IconRenderer.writeICNS(fromImageFile: URL(fileURLWithPath: path), to: out) } catch {
                throw IconError.renderFailed(error.localizedDescription)
            }
            return out
        case .generated:
            return try letterTile(for: config, scratchDirectory: scratchDirectory)
        case .copied:
            if let webIconData {
                let out = scratchDirectory.appending(path: "web-fetched-icon.icns")
                do {
                    try IconRenderer.writeICNS(fromImageData: webIconData, to: out)
                    return out
                } catch IconRenderer.RenderError.unreadableImage {
                    logger.info("The fetched site icon could not be decoded; using the letter tile instead")
                } catch {
                    throw IconError.renderFailed(error.localizedDescription)
                }
            } else if let existingIcon, fileManager.fileExists(atPath: existingIcon.path) {
                let out = scratchDirectory.appending(path: "web-kept-icon.icns")
                do { try fileManager.copyItem(at: existingIcon, to: out) } catch {
                    throw IconError.renderFailed(error.localizedDescription)
                }
                return out
            }
            return try letterTile(for: config, scratchDirectory: scratchDirectory)
        }
    }

    private static func letterTile(for config: ShortcutConfig, scratchDirectory: URL) throws -> URL {
        let out = scratchDirectory.appending(path: "web-letter-icon.icns")
        do { try IconRenderer.writeICNS(letterTileFor: config.name, to: out) } catch {
            throw IconError.renderFailed(error.localizedDescription)
        }
        return out
    }
```

- [ ] **Step 25: Run, expect pass.** Same command as Step 23.

- [ ] **Step 26: Commit.**
```
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add App/Sources/Services/IconResolver.swift App/Tests/Services/IconResolverTests.swift App/Tests/TestSupport/AppTestSupport.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Resolve web app icons from fetched bytes, a kept icon or a letter tile

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 27: Failing builder tests.** In `App/Tests/Services/ShortcutBuilderTests.swift` add `import AppKit` (line 1), a `webShell` property, and change setUp. Replace lines 7-19 area as follows: add `private var webShell: URL!` after `launcher`; after the launcher copy line (line 18) add:

```swift
        webShell = dir.appending(path: "WebShell")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: webShell)
        builder = ShortcutBuilder(launcherBinary: launcher, webShellBinary: webShell, signingIdentity: nil)
```
  and delete the old `builder = ShortcutBuilder(launcherBinary: launcher, signingIdentity: nil)` line. (The launcher stand-in is `/bin/echo`, the web shell stand-in `/bin/ls`; their sizes differ, which the tests use to tell which one was copied.) Append inside the class:

```swift
    private func pngData() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func fileSize(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    }

    func testCreateWebAppCopiesWebShellSignsAndRoundTripsConfig() throws {
        XCTAssertNotEqual(try fileSize(launcher), try fileSize(webShell), "stand-ins must be distinguishable")
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let config = makeWebConfig(name: "Chat Work", url: "https://chat.example.test/")
        let bundle = try builder.create(config: config, in: out, webIconData: try pngData())

        XCTAssertEqual(bundle.lastPathComponent, "Chat Work.app")
        let record = try LibraryScanner.record(forBundleAt: bundle)
        XCTAssertEqual(record.config.kind, .webApp)
        XCTAssertEqual(record.config.webApp?.url, "https://chat.example.test/")
        XCTAssertEqual(record.config.webApp?.dataStoreID, config.webApp?.dataStoreID)
        let executable = bundle.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        let name = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: executable.path).first)
        XCTAssertEqual(try fileSize(executable.appending(path: name)), try fileSize(webShell))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Resources/AppIcon.icns").path))
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", bundle.path]
        try verify.run()
        verify.waitUntilExit()
        XCTAssertEqual(verify.terminationStatus, 0)
    }

    func testCreateWebAppWithoutBytesOrWithGarbageGetsALetterTile() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let none = try builder.create(config: makeWebConfig(name: "One Work"), in: out)
        let garbage = try builder.create(config: makeWebConfig(name: "Two Work"), in: out, webIconData: Data("nope".utf8))
        for bundle in [none, garbage] {
            let icon = try Data(contentsOf: bundle.appending(path: "Contents/Resources/AppIcon.icns"))
            XCTAssertEqual(String(decoding: icon.prefix(4), as: UTF8.self), "icns")
        }
    }

    func testRegenerateWebAppWithoutNewBytesKeepsTheIconBytes() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: makeWebConfig(name: "Chat Work"), in: out, webIconData: try pngData())
        let before = try Data(contentsOf: bundle.appending(path: "Contents/Resources/AppIcon.icns"))
        let record = try LibraryScanner.record(forBundleAt: bundle)
        var edited = record.config
        edited.webApp?.pageZoom = 1.5

        let rewritten = try builder.regenerate(record: record, config: edited)

        XCTAssertEqual(try Data(contentsOf: rewritten.appending(path: "Contents/Resources/AppIcon.icns")), before)
        XCTAssertEqual(try LibraryScanner.record(forBundleAt: rewritten).config.webApp?.pageZoom, 1.5)
    }

    func testDuplicateWebAppGetsFreshDataStoreAndKeepsUrlAndIcon() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: makeWebConfig(name: "Chat Work"), in: out, webIconData: try pngData())
        let original = try LibraryScanner.record(forBundleAt: bundle)

        let copy = try builder.duplicate(record: original, newName: "Chat Home", in: out, takenSlugs: [original.config.slug])

        let copied = try LibraryScanner.record(forBundleAt: copy)
        XCTAssertNotEqual(copied.config.webApp?.dataStoreID, original.config.webApp?.dataStoreID)
        XCTAssertEqual(copied.config.webApp?.url, original.config.webApp?.url)
        XCTAssertNotEqual(copied.config.bundleIdentifier, original.config.bundleIdentifier)
        XCTAssertEqual(try Data(contentsOf: copy.appending(path: "Contents/Resources/AppIcon.icns")),
                       try Data(contentsOf: bundle.appending(path: "Contents/Resources/AppIcon.icns")))
    }

    func testWebAppKindWithoutWebAppSettingsIsRefused() throws {
        var config = makeWebConfig()
        config.webApp = nil
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        XCTAssertThrowsError(try builder.create(config: config, in: out)) { error in
            guard case ShortcutBuilder.BuilderError.webAppConfigMissing = error else { return XCTFail("\(error)") }
        }
    }
```
  In `App/Tests/EndToEnd/ShortcutBuilderEndToEndTests.swift` line 19 change to `builder = ShortcutBuilder(launcherBinary: try EmbeddedLauncher.url(), webShellBinary: try EmbeddedWebShell.url(), signingIdentity: nil)` (`EmbeddedWebShell` is Task 2's resolver, same shape as `EmbeddedLauncher`).

- [ ] **Step 28: Run, expect failure.** `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/ShortcutBuilderTests` — `extra argument 'webShellBinary' in call`, `extra argument 'webIconData' in call`, `type 'ShortcutBuilder.BuilderError' has no member 'webAppConfigMissing'`.

- [ ] **Step 29: Implement in `App/Sources/Services/ShortcutBuilder.swift`.**

  (a) Error case: after `case targetIsShortcut(String)` (line 16) add `case webAppConfigMissing`, and in `errorDescription` after the `targetIsShortcut` line (26) add `case .webAppConfigMissing: "The shortcut has no web app settings."`.

  (b) Replace lines 42-52 (stored properties and init):

```swift
    let launcherBinary: URL
    /// The embedded `WebShell` executable web app bundles run (Task 2).
    let webShellBinary: URL
    /// Codesign identity display name, or nil for ad hoc.
    let signingIdentity: String?
    // FileManager is not Sendable, so it is not a stored property of this Sendable struct (Rebuild All runs the
    // builder in a detached task). Nothing ever set it; every use reads the shared instance.
    var fileManager: FileManager { .default }

    init(launcherBinary: URL, webShellBinary: URL, signingIdentity: String?) {
        self.launcherBinary = launcherBinary
        self.webShellBinary = webShellBinary
        self.signingIdentity = signingIdentity
    }
```

  (c) Replace `create` (lines 54-60), `regenerate` (62-74) and the last two lines of `duplicate` (line 85-86):

```swift
    /// Writes `<name>.app` into `directory`. Throws `alreadyExists` rather than replacing a bundle it did not make.
    /// `webIconData` is the site icon fetched by the wizard (PNG, JPEG or ICO bytes); it is only used for a `.webApp`
    /// shortcut whose `iconMode` is `.copied`, and a missing or undecodable image gives the first-letter tile.
    func create(config: ShortcutConfig, in directory: URL, webIconData: Data? = nil) throws -> URL {
        try createBundle(config: config, in: directory, webIconData: webIconData, existingIcon: nil)
    }

    private func createBundle(config: ShortcutConfig, in directory: URL, webIconData: Data?, existingIcon: URL?) throws -> URL {
        let destination = directory.appending(path: "\(ShortcutConfig.fileSystemName(for: config.name)).app", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: destination.path) { throw BuilderError.alreadyExists(destination) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try write(config: config, in: directory, webIconData: webIconData, existingIcon: existingIcon)
    }

    /// The `AppIcon.icns` inside a shortcut bundle, or nil when it has none.
    private static func bundledIcon(of bundleURL: URL) -> URL? {
        let icon = bundleURL.appending(path: "Contents/Resources/AppIcon.icns", directoryHint: .notDirectory)
        return FileManager.default.fileExists(atPath: icon.path) ? icon : nil
    }

    /// Rewrites an existing shortcut in place with `config` (same folder; the name may change the bundle file name).
    /// A web app without new `webIconData` keeps the icon already in its bundle.
    func regenerate(record: ShortcutRecord, config: ShortcutConfig, webIconData: Data? = nil) throws -> URL {
        let directory = record.bundleURL.deletingLastPathComponent()
        let newURL = directory.appending(path: "\(ShortcutConfig.fileSystemName(for: config.name)).app", directoryHint: .isDirectory)
        if newURL.standardizedFileURL != record.bundleURL.standardizedFileURL, fileManager.fileExists(atPath: newURL.path) {
            throw BuilderError.alreadyExists(newURL)
        }
        let written = try write(config: config, in: directory, webIconData: webIconData, existingIcon: Self.bundledIcon(of: record.bundleURL))
        if written.standardizedFileURL != record.bundleURL.standardizedFileURL {
            try fileManager.removeItem(at: record.bundleURL)
        }
        return written
    }
```
  and in `duplicate` replace `config.dataPath = nil` / `return try create(config: config, in: directory)` with:

```swift
        config.dataPath = nil
        // A duplicate web app is a separate logins container: same address and look, new website data store.
        config.webApp?.dataStoreID = UUID()
        return try createBundle(config: config, in: directory, webIconData: nil, existingIcon: Self.bundledIcon(of: record.bundleURL))
```

  (d) Replace the private `write` (line 236-251) with:

```swift
    private func write(config: ShortcutConfig, in directory: URL, webIconData: Data?, existingIcon: URL?) throws -> URL {
        if config.kind == .webApp {
            return try writeWebApp(config: config, in: directory, webIconData: webIconData, existingIcon: existingIcon)
        }
        var config = config.resolvingDefaultDataPath(home: fileManager.homeDirectoryForCurrentUser)
        config.engineVersion = ShortcutConfig.currentEngineVersion
        let targetURL = URL(fileURLWithPath: config.targetPath)
        guard fileManager.fileExists(atPath: targetURL.path) else { throw BuilderError.targetMissing(config.targetPath) }
        // Final review M5: a shortcut target chains launchers, and a self-target makes the launcher exec itself again.
        guard !TargetGuard.isShortcutBundle(at: targetURL) else { throw BuilderError.targetIsShortcut(config.targetPath) }
        let app = try AppInspector().inspect(appAt: targetURL)
        let scratch = try makeScratch()
        defer { removeScratch(scratch) }
        let icon = try IconResolver.iconFile(for: config, app: app, scratchDirectory: scratch)
        let bundle = try BundleWriter(fileManager: fileManager).write(config: config, app: app, launcherBinary: launcherBinary, iconFile: icon, to: directory)
        try Signer().sign(bundle: bundle, identity: signingIdentity)
        return bundle
    }

    /// A web app bundle: the embedded web shell as its executable, no target app and no data-folder resolution.
    private func writeWebApp(config: ShortcutConfig, in directory: URL, webIconData: Data?, existingIcon: URL?) throws -> URL {
        guard config.webApp != nil else { throw BuilderError.webAppConfigMissing }
        var config = config
        config.engineVersion = ShortcutConfig.currentEngineVersion
        let scratch = try makeScratch()
        defer { removeScratch(scratch) }
        let icon = try IconResolver.webAppIconFile(for: config, webIconData: webIconData, existingIcon: existingIcon, scratchDirectory: scratch)
        let bundle = try BundleWriter(fileManager: fileManager).write(config: config, executable: webShellBinary, iconFile: icon, to: directory)
        try Signer().sign(bundle: bundle, identity: signingIdentity)
        return bundle
    }

    private func makeScratch() throws -> URL {
        let scratch = fileManager.temporaryDirectory.appending(path: "mad-build-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch
    }

    /// Best-effort removal of a build scratch folder; a failure is only logged.
    private func removeScratch(_ scratch: URL) {
        do {
            try fileManager.removeItem(at: scratch)
        } catch {
            Self.logger.warning("Could not remove build scratch folder \(scratch.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
```
  (The native path's old `defer { try? ... }` is replaced by the logged helper; behaviour is otherwise unchanged.)

- [ ] **Step 30: Run, expect pass.** `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/ShortcutBuilderTests` — every old test plus the five new ones pass. Then `Tools/test-app.sh -only-testing:MacAppDuplicatorTests/ShortcutBuilderEndToEndTests` (needs Task 2's `EmbeddedWebShell` and the embedded WebShell build phase; if it does not exist yet, this one command waits for Task 2).

- [ ] **Step 31: Commit.**
```
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add App/Sources/Services/ShortcutBuilder.swift App/Tests/Services/ShortcutBuilderTests.swift App/Tests/EndToEnd/ShortcutBuilderEndToEndTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Build, regenerate and duplicate web app shortcuts

Web apps run the embedded web shell. Regenerate and duplicate reuse the icon already in the bundle unless new bytes are supplied, and a duplicate gets its own website data store.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 32: Failing tests for web app running detection.** A web app is the web shell itself, so it is found by its bundle identifier among `NSWorkspace` running applications, not by the launcher's environment marker. Append to `App/Tests/Model/RunningShortcutMonitorTests.swift` inside `RunningShortcutMonitorTests`:

```swift
    @MainActor
    func testRunningIdentifiersComeFromTheInjectedProbeAndMatchCaseInsensitively() async {
        let monitor = RunningShortcutMonitor(probe: { [] }, identifierProbe: { ["com.mikekuta.appduplicator.chat-work"] })
        await monitor.refresh()

        XCTAssertTrue(monitor.isRunning(bundleURL: URL(fileURLWithPath: "/x/Chat Work.app"), bundleIdentifier: "com.mikekuta.AppDuplicator.Chat-Work"))
        XCTAssertFalse(monitor.isRunning(bundleURL: URL(fileURLWithPath: "/x/Other.app"), bundleIdentifier: "com.mikekuta.appduplicator.other"))
        XCTAssertFalse(monitor.isRunning(bundleURL: URL(fileURLWithPath: "/x/Chat Work.app")), "without an identifier only the path probe counts")
    }

    @MainActor
    func testLibraryUsesIdentifiersOnlyForWebApps() async throws {
        let (defaults, suite) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let web = makeWebConfig(name: "Chat Work")
        let monitor = RunningShortcutMonitor(probe: { [] }, identifierProbe: { [web.bundleIdentifier.lowercased()] })
        let library = ShortcutLibrary(settings: AppSettings(defaults: defaults, defaultSigningIdentity: "Ad-hoc"), monitor: monitor)
        await monitor.refresh()

        func record(_ config: ShortcutConfig) -> ShortcutRecord {
            ShortcutRecord(bundleURL: URL(fileURLWithPath: "/x/\(config.name).app"), config: config, engineVersion: ShortcutConfig.currentEngineVersion,
                           iconURL: nil, targetVersion: nil, targetExists: true, modifiedDate: .distantPast)
        }
        var native = makeConfig(name: "Native Work")
        native.bundleIdentifier = web.bundleIdentifier
        XCTAssertTrue(library.isRunning(record(web)))
        XCTAssertFalse(library.isRunning(record(native)), "a native shortcut is only running when its launcher marker says so")
    }
```

- [ ] **Step 33: Run, expect failure.** `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/RunningShortcutMonitorTests` — `extra argument 'identifierProbe' in call`, `extra argument 'bundleIdentifier' in call`.

- [ ] **Step 34: Implement.** In `App/Sources/Model/RunningShortcutMonitor.swift`: after line 11 (`runningBundlePaths`) add `private(set) var runningBundleIdentifiers: Set<String> = []` and a stored `private let identifierProbe: (@MainActor () -> Set<String>)?`. Replace the init (lines 21-23):

```swift
    init(
        probe: @escaping @Sendable () -> Set<String> = { RunningShortcutMonitor.liveRunningBundlePaths() },
        identifierProbe: (@MainActor () -> Set<String>)? = nil
    ) {
        self.probe = probe
        self.identifierProbe = identifierProbe
    }
```
  In `refresh()` replace line 51 (`runningBundlePaths = paths`) with:

```swift
        runningBundlePaths = paths
        runningBundleIdentifiers = identifierProbe?() ?? Self.liveRunningBundleIdentifiers()
```
  Add after `isRunning(bundleURL:)` (line 63):

```swift
    /// A web app is the web shell itself, so it shows up in `NSWorkspace` under its own bundle identifier.
    func isRunning(bundleURL: URL, bundleIdentifier: String?) -> Bool {
        if isRunning(bundleURL: bundleURL) { return true }
        guard let bundleIdentifier else { return false }
        return runningBundleIdentifiers.contains(bundleIdentifier.lowercased())
    }

    /// Lower-cased bundle identifiers of the running applications.
    static func liveRunningBundleIdentifiers() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
    }
```
  In `App/Sources/Model/ShortcutLibrary.swift` line 79 replace with:

```swift
    func isRunning(_ record: ShortcutRecord) -> Bool {
        monitor.isRunning(bundleURL: record.bundleURL, bundleIdentifier: record.config.kind == .webApp ? record.config.bundleIdentifier : nil)
    }
```

- [ ] **Step 35: Run, expect pass.** Same command as Step 33, then `Tools/test-app.sh -only-testing:MacAppDuplicatorTests/ShortcutLibraryTests` (the existing `isRunning` callers are unchanged for native records).

- [ ] **Step 36: Commit.**
```
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add App/Sources/Model/RunningShortcutMonitor.swift App/Sources/Model/ShortcutLibrary.swift App/Tests/Model/RunningShortcutMonitorTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Detect running web apps by bundle identifier

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 37: Failing tests for scanning a web app.** Append to `App/Tests/Model/LibraryScannerTests.swift` inside the class:

```swift
    func testScanListsWebAppWithoutReadingATarget() throws {
        let config = makeWebConfig(name: "Chat Work", url: "https://chat.example.test/inbox")
        _ = try writeShortcutBundle(named: "Chat Work", in: root, config: config)

        let result = LibraryScanner().scan(folders: [root])

        let record = try XCTUnwrap(result.records.first)
        XCTAssertEqual(result.warnings, [])
        XCTAssertTrue(record.targetExists, "a web app has no target to be missing")
        XCTAssertNil(record.targetVersion)
        XCTAssertEqual(record.webAppHost, "chat.example.test")
        XCTAssertNil(ShortcutRecord(bundleURL: root, config: makeConfig(), engineVersion: 1, iconURL: nil, targetVersion: nil, targetExists: true, modifiedDate: .distantPast).webAppHost)
    }
```

- [ ] **Step 38: Run, expect failure.** `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/LibraryScannerTests` — `value of type 'ShortcutRecord' has no member 'webAppHost'` (and, once that compiles, `targetExists` is false because the empty target path does not exist).

- [ ] **Step 39: Implement.** In `App/Sources/Model/ShortcutRecord.swift` add after `needsRebuild`:

```swift
    /// The host of a web app's address (`chat.example.test`), shown under its name in the sidebar; nil for a native shortcut.
    var webAppHost: String? {
        guard config.kind == .webApp, let address = config.webApp?.url else { return nil }
        return URL(string: address)?.host(percentEncoded: false)
    }
```
  In `App/Sources/Model/LibraryScanner.swift` replace lines 66-77 (from `let targetURL = ...` through the closing brace of the `if targetExists` block) with:

```swift
        // A web app has no target app: it is never "missing" and has no version to read.
        let isWebApp = config.kind == .webApp
        let targetURL = URL(fileURLWithPath: config.targetPath)
        let targetExists = isWebApp || fileManager.fileExists(atPath: targetURL.path)
        // Read the target's Info.plist directly: `Bundle(url:)` caches one instance per path for the process lifetime,
        // so a target updated while this app runs would keep reporting its old version. An unreadable plist means
        // "version unknown", which is what nil expresses.
        var targetVersion: String?
        let targetInfoURL = targetURL.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        if targetExists, !isWebApp,
           let targetInfoData = fileManager.contents(atPath: targetInfoURL.path),
           let targetInfo = (try? PropertyListSerialization.propertyList(from: targetInfoData, format: nil)) as? [String: Any] {
            targetVersion = targetInfo["CFBundleShortVersionString"] as? String
        }
```
  (the existing `try?` on the plist read is pre-existing code kept as is; only the `isWebApp` lines are new.) In `App/Sources/Views/ShortcutRowView.swift` replace the `subtitle` body (lines 46-55) with:

```swift
    @ViewBuilder
    private var subtitle: some View {
        if record.config.kind == .webApp {
            Text(record.webAppHost ?? "Web App").foregroundStyle(.secondary)
        } else if record.targetExists {
            let targetName = URL(fileURLWithPath: record.config.targetPath).deletingPathExtension().lastPathComponent
            Text([targetName, record.targetVersion].compactMap { $0 }.joined(separator: " "))
                .foregroundStyle(.secondary)
        } else {
            Text("Target missing").foregroundStyle(.red)
        }
    }
```

- [ ] **Step 40: Run, expect pass.** Same command as Step 38; then `Tools/test-app.sh -only-testing:MacAppDuplicatorTests/ShortcutLibraryTests` (library scan paths use the same scanner).

- [ ] **Step 41: Commit.**
```
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add App/Sources/Model/ShortcutRecord.swift App/Sources/Model/LibraryScanner.swift App/Sources/Views/ShortcutRowView.swift App/Tests/Model/LibraryScannerTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "List web apps in the library without a target app

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 42: Failing test for the app wiring.** Create `App/Tests/App/AppStateWebShellTests.swift`:

```swift
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
```

- [ ] **Step 43: Run, expect failure.** `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/AppStateWebShellTests` — `extra argument 'webShellBinary' in call`. (Until Step 44 the whole app target also fails to build because `ShortcutBuilder.init` changed in Step 29: that is the expected red state.)

- [ ] **Step 44: Implement.** In `App/Sources/App/AppState.swift` find the `launcherBinary` stored property (`grep -n "launcherBinary" App/Sources/App/AppState.swift`) and add below it `private let webShellBinary: URL`. Replace the init (lines 62-68) and `builder` (70-72):

```swift
    /// `webShellBinary` nil means "next to the launcher in Resources" (where the Embed Web Shell build phase puts it).
    init(settings: AppSettings, library: ShortcutLibrary, launcherBinary: URL, webShellBinary: URL? = nil, profiles: ProfilesModel? = nil) {
        self.settings = settings
        self.library = library
        self.launcherBinary = launcherBinary
        self.webShellBinary = webShellBinary ?? launcherBinary.deletingLastPathComponent().appending(path: "WebShell", directoryHint: .notDirectory)
        // Main-actor types are never default argument values; nil means the inert model (no profiles, no network).
        self.profiles = profiles ?? .inert()
    }

    var builder: ShortcutBuilder {
        ShortcutBuilder(launcherBinary: launcherBinary, webShellBinary: webShellBinary, signingIdentity: settings.signerIdentity)
    }
```
  Do NOT touch `AppState.create`: Task 5 owns `create(config:webIconData:)`. In `App/Sources/App/MacAppDuplicatorApp.swift` replace lines 25-36 with:

```swift
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
```

- [ ] **Step 45: Run, expect pass; then the whole suite.** `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/AppStateWebShellTests` then `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh` (full app suite green) and `cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test` (Core, CompatProfiles, Integration still green). Also `cd /Users/cubbieblue16/Developer/MacAppDuplicator && grep -rn "ShortcutBuilder(" App --include='*.swift'` must list only call sites that pass `webShellBinary:`.

- [ ] **Step 46: Commit.**
```
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add App/Sources/App/AppState.swift App/Sources/App/MacAppDuplicatorApp.swift App/Tests/App/AppStateWebShellTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Hand the embedded web shell to the shortcut builder

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

## Resolved by coordinator

- Builder, `IconResolver`, monitor, scanner, row view and `AppState` code in this plan is uncompiled; the implementer compiles and fixes small type errors as part of each step's green run.
- `export`/`delete` for web apps (empty `targetPath`) and hiding `CompatBadge` for `.webApp` are owned by Task 6.
- `EmbeddedWebShell.url()` comes from Task 2 (`App/Sources/App/EmbeddedWebShell.swift`).
- Live confirmation that a running web app appears in `NSWorkspace` by bundle id is part of the Phase 4 acceptance doc (Task 6), not a unit test.

---

### Task 5: Wizard for web apps

**Files:**
- Modify: `App/Sources/Views/Wizard/WizardModel.swift` (whole file, lines 1-177, replaced in Step 3; every existing member and behaviour is kept)
- Modify: `App/Sources/Views/Wizard/WizardSteps.swift` (lines 9-16 kind options; lines 95-155 `IdentityStep`; lines 219-298 `ReviewStep`)
- Modify: `App/Sources/Views/Wizard/NewShortcutWizard.swift` (lines 19, 21-29, 62-64, 73)
- Modify: `App/Sources/App/AppState.swift` (lines 99-111, `create(config:)` gains a defaulted `webIconData` parameter and forwards it)
- Create: `App/Sources/Views/Wizard/WebAppPresetGrid.swift` (grid, plus `WebTargetStep` that hosts the grid and the `Website URL` field)
- Create: `App/Sources/Views/Wizard/WebAppOptionsStep.swift`
- Test: `App/Tests/Wizard/WebWizardModelTests.swift` (new; `WizardModelTests.swift` is untouched and must keep passing)

**Interfaces:**
- Consumes (Task 1, `DuplicatorCore`, exact names from `.superpowers/sdd/p4/task-1-interfaces.md`): `WebAppConfig(url:dataStoreID:userAgent:badgeRegex:extraHosts:pageZoom:backgroundMode:)` (its init trims, lower-cases and de-duplicates `extraHosts` in first-seen order and clamps zoom), `UserAgentPreset` (`.safari`, `.chrome`), `WebAppURLValidator.validate(_:) throws -> URL` (trims whitespace; requires `https`, a host, no user info), `WebAppURLError.invalidAddress` (description `Enter an https:// address`), `ShortcutConfig.webApp` and the `webApp:` initializer parameter (between `homeSymlinkEntries:` and `engineVersion:`), `ShortcutKind.webApp`.
- Consumes (Task 4, planned in parallel; **assumptions**, stated here so the executor checks them against the final `task-4.md` before Step 3):
  - **A1** `CompatProfiles.WebAppPreset` is `Equatable, Sendable` with `name: String, url: String, userAgent: String?, badgeRegex: String?, extraHosts: [String], iconURL: String?` and `init(name:url:userAgent: = nil, badgeRegex: = nil, extraHosts: = [], iconURL: = nil)` (Task 1 of Phase 4 planning, `ProfilesDocument.swift`).
  - **A2** `ProfilesModel.webAppPresets: [WebAppPreset]` and `ProfilesModel.userAgentPreset(for: WebAppPreset) -> UserAgentPreset` (both `@MainActor`, on the model `AppState.profiles`).
  - **A3** `protocol WebIconFetching: Sendable { func fetchIcon(for pageURL: URL) async throws -> Data? }` and `struct URLSessionWebIconFetcher: WebIconFetching` with a no-argument `init()`.
  - **A4** `IconRenderer.writeICNS(fromImageData:to:)` exists (used by Task 4's builder, not by this task).
  - **A5** `ShortcutBuilder.create(config: ShortcutConfig, in directory: URL, webIconData: Data? = nil) throws -> URL`: the builder, not the wizard, turns `webIconData` into `AppIcon.icns` (via A4) when `config.kind == .webApp && config.iconMode == .copied`, and renders the letter tile when the data is nil or undecodable. The config has no field that can carry image bytes, so the wizard hands them over as a call argument. If Task 4 ended with a different hand-off (for example the builder fetches by itself), only Step 7's `AppState.create` forward and Step 8's `create()` line change; the model API (`webIconPayload`) stays.
- Produces (used by Task 6 and the app target):
  - `WizardModel.Step` gains `case webOptions`; `WizardModel.steps: [Step]` (app: `kind, target, identity, data, review`; web app: `kind, target, identity, webOptions, review`), `stepNumber: Int` (1-based position in `steps`).
  - `WizardModel.init(prefillTarget: URL? = nil, takenSlugs: Set<String> = [], profileLookup: ... = { _ in nil }, webAppPresets: [WebAppPreset] = [], webDataStoreID: UUID = UUID(), iconFetcher: any WebIconFetching = URLSessionWebIconFetcher(), userAgentResolver: @escaping @MainActor (WebAppPreset) -> UserAgentPreset = { _ in .safari })`.
  - Web state: `webURL: String`, `selectedPreset: WebAppPreset?` (`private(set)`), `highlightedPreset: WebAppPreset?`, `userAgent: UserAgentPreset`, `badgeRegex: String`, `extraHostsText: String`, `backgroundMode: Bool`, `menuBarIcon: Bool` (`private(set)`, set with `setMenuBarIcon(_:)`), `webIconData: Data?` (`private(set)`), `webIconFetchState: WebIconFetchState` (`private(set)`), `iconFetchTask: Task<Void, Never>?` (`private(set)`), `webAppPresets`, `webDataStoreID`.
  - `WebIconFetchState: Equatable { case idle, fetching, fetched, unavailable(String) }`.
  - `func applyPreset(_:)`, `func setMenuBarIcon(_:)`, `func fetchWebIcon() async`, `var validatedWebURL: URL?`, `var webURLError: String?`, `var webIconStatusText: String?`, `var webIconPayload: Data?`, `var iconDescription: String`, `var webReviewRows: [ReviewRow]`, `struct ReviewRow: Equatable { label, value }`, `static func parseExtraHosts(_:) -> [String]`, `static func presetHost(_:) -> String`, `static func userAgentLabel(_:) -> String`.
  - `AppState.create(config:webIconData:)`; views `WebAppPresetGrid`, `WebTargetStep`, `WebAppOptionsStep`.

**Decisions (state of record):**
1. **Data step is hidden for web apps**, not shown with a note. The `.data` step is replaced in the web flow by `.webOptions` (`Web App Options`), and that step carries the one-line note `Web apps keep their data in a private web data store`. A web app's data lives in the `WKWebsiteDataStore` named by `dataStoreID`; none of the Data step's controls (mode, folder) apply, so showing them would be misleading. `makeConfig()` pins `dataMode = .disabled`, `dataPath = nil`.
2. **Step order for web apps** is kind, target (presets + URL), identity (name + icon), web options, review. The icon fetch starts on entering identity because only the URL is needed.
3. **`dataStoreID` is generated once per wizard session** (`webDataStoreID`, a stored `let`). `makeConfig()` runs for the Review preview and again for Create; a fresh UUID per call would show a Data store id that differs from the one written.
4. **"Slug free" needs no extra gate**: `WizardModel.slug` already steps around `takenSlugs` (`-2`, `-3`, ...), so a duplicate name can never block Next. The identity gate is the same as for apps: non-empty name, and a chosen file in Custom mode.
5. **Icon invariant:** for a web app, `iconMode == .copied` means "Fetched from site". `makeConfig()` therefore emits `.generated` when the mode is `.copied` but no fetched data exists (fetch never ran, returned nil, or threw), so a config never claims a fetched icon it does not have. A user-chosen `.custom` is never overridden by a fetch result.
6. **Review for web apps has no launch plan.** `LaunchPlanPreview.make` resolves a target app, which a web app does not have; `refreshPreview()` leaves `preview` and `previewError` nil for web, and the Create gate for web is `!isCreating && webIconFetchState != .fetching` (Create waits for an in-flight icon fetch, so the icon is not lost).
7. `backgroundMode` is stored only while `menuBarIcon` is on: `setMenuBarIcon(false)` clears it and `makeConfig()` writes `backgroundMode && menuBarIcon`.

- [ ] **Step 1: Write the failing tests**

Create `App/Tests/Wizard/WebWizardModelTests.swift`. The fake fetcher and its recorder are `private` to this file (Task 4's tests have their own mock; distinct names avoid a clash in the shared test module). The recorder wraps `Mutex` in a `final class ... : Sendable` because `Mutex` is `~Copyable`.

```swift
import CompatProfiles
import Synchronization
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

/// A scripted icon fetcher: each call consumes the next outcome (the last one repeats) and records the page URL.
private final class FetchScript: Sendable {
    enum Outcome: Sendable {
        case data(Data)
        case nothing
        case failure
    }

    private struct State {
        var outcomes: [Outcome]
        var urls: [URL] = []
    }

    private let state: Mutex<State>

    init(_ outcomes: [Outcome]) {
        state = Mutex(State(outcomes: outcomes))
    }

    func next(for url: URL) -> Outcome {
        state.withLock { current in
            current.urls.append(url)
            return current.outcomes.count > 1 ? current.outcomes.removeFirst() : (current.outcomes.first ?? .nothing)
        }
    }

    var urls: [URL] { state.withLock { $0.urls } }
}

private struct FetchFailure: Error, LocalizedError {
    var errorDescription: String? { "The connection was lost." }
}

private struct WizardFakeIconFetcher: WebIconFetching {
    let script: FetchScript

    func fetchIcon(for pageURL: URL) async throws -> Data? {
        switch script.next(for: pageURL) {
        case .data(let data): return data
        case .nothing: return nil
        case .failure: throw FetchFailure()
        }
    }
}

@MainActor
final class WebWizardModelTests: XCTestCase {
    private let storeID = UUID()
    private let iconBytes = Data([0x89, 0x50, 0x4E, 0x47])
    private let whatsapp = WebAppPreset(name: "WhatsApp", url: "https://web.whatsapp.com", userAgent: "chrome",
                                        badgeRegex: #"\((\d+)\)"#, extraHosts: ["whatsapp.com", "whatsapp.net"])
    private let teams = WebAppPreset(name: "Teams", url: "https://teams.microsoft.com", extraHosts: ["microsoft.com"])

    private func makeModel(_ outcomes: [FetchScript.Outcome] = [.nothing], takenSlugs: Set<String> = []) -> (model: WizardModel, script: FetchScript) {
        let script = FetchScript(outcomes)
        let model = WizardModel(takenSlugs: takenSlugs, webAppPresets: [whatsapp, teams], webDataStoreID: storeID,
                                iconFetcher: WizardFakeIconFetcher(script: script),
                                userAgentResolver: { $0.userAgent == "chrome" ? .chrome : .safari })
        model.kind = .webApp
        return (model, script)
    }

    // MARK: step flow

    func testWebFlowSkipsTheDataStepAndUsesTheOptionsStep() async {
        let (model, script) = makeModel([.data(iconBytes)])
        XCTAssertEqual(model.steps, [.kind, .target, .identity, .webOptions, .review])
        XCTAssertEqual(model.stepNumber, 1)
        XCTAssertTrue(model.canAdvance, "the kind step accepts Web App")

        model.next()
        XCTAssertEqual(model.step, .target)
        XCTAssertFalse(model.canAdvance)
        model.webURL = "https://example.com"
        XCTAssertTrue(model.canAdvance)

        model.next()
        XCTAssertEqual(model.step, .identity)
        XCTAssertEqual(model.stepNumber, 3)
        await model.iconFetchTask?.value
        XCTAssertEqual(script.urls.map(\.absoluteString), ["https://example.com"])
        XCTAssertFalse(model.canAdvance, "the name is still empty")
        model.name = "Example"

        model.next()
        XCTAssertEqual(model.step, .webOptions)
        XCTAssertEqual(model.stepNumber, 4)
        XCTAssertTrue(model.canAdvance)

        model.next()
        XCTAssertEqual(model.step, .review)
        XCTAssertNil(model.preview, "a web app has no launch plan")
        XCTAssertNil(model.previewError)
        XCTAssertTrue(model.canAdvance)

        model.back()
        XCTAssertEqual(model.step, .webOptions)
        model.back()
        XCTAssertEqual(model.step, .identity)
    }

    func testTheApplicationFlowStillUsesTheDataStep() {
        let model = WizardModel()
        XCTAssertEqual(model.steps, [.kind, .target, .identity, .data, .review])
        model.kind = .folder
        XCTAssertFalse(model.canAdvance, "the other kinds stay disabled")
    }

    // MARK: presets

    func testApplyingAPresetFillsTheWebFieldsAndTheName() {
        let (model, _) = makeModel()
        model.applyPreset(whatsapp)
        XCTAssertEqual(model.webURL, "https://web.whatsapp.com")
        XCTAssertEqual(model.userAgent, .chrome)
        XCTAssertEqual(model.badgeRegex, #"\((\d+)\)"#)
        XCTAssertEqual(model.extraHostsText, "whatsapp.com\nwhatsapp.net")
        XCTAssertEqual(model.name, "WhatsApp")
        XCTAssertEqual(model.selectedPreset, whatsapp)
        XCTAssertEqual(model.highlightedPreset, whatsapp)

        model.applyPreset(teams)
        XCTAssertEqual(model.webURL, "https://teams.microsoft.com")
        XCTAssertEqual(model.userAgent, .safari, "a preset without a user agent resets to Safari")
        XCTAssertEqual(model.badgeRegex, "")
        XCTAssertEqual(model.extraHostsText, "microsoft.com")
        XCTAssertEqual(model.name, "Teams", "a name the model filled in itself follows the preset")
    }

    func testApplyingAPresetKeepsAnameTheUserTyped() {
        let (model, _) = makeModel()
        model.name = "Family Chat"
        model.applyPreset(whatsapp)
        XCTAssertEqual(model.name, "Family Chat")
        XCTAssertEqual(model.webURL, "https://web.whatsapp.com")
    }

    func testEditingTheURLDropsTheHighlightButKeepsTheAppliedOptions() {
        let (model, _) = makeModel()
        model.applyPreset(whatsapp)
        model.webURL = "https://web.whatsapp.com/other"
        XCTAssertNil(model.highlightedPreset)
        XCTAssertEqual(model.selectedPreset, whatsapp)
        XCTAssertEqual(model.userAgent, .chrome)
        model.webURL = "  https://web.whatsapp.com "
        XCTAssertEqual(model.highlightedPreset, whatsapp, "surrounding spaces do not matter")
    }

    func testPresetHostIsTheDisplayedHost() {
        XCTAssertEqual(WizardModel.presetHost(whatsapp), "web.whatsapp.com")
        XCTAssertEqual(WizardModel.presetHost(WebAppPreset(name: "Broken", url: "not a url")), "not a url")
    }

    // MARK: URL validation

    func testTheTargetStepGatesOnAValidHTTPSAddress() {
        let (model, _) = makeModel()
        model.step = .target
        for bad in ["", "   ", "example.com", "http://example.com", "https://", "ftp://example.com", "https://trusted.com@evil.example"] {
            model.webURL = bad
            XCTAssertFalse(model.canAdvance, "'\(bad)' must not advance")
            XCTAssertNil(model.validatedWebURL, "'\(bad)' must not validate")
        }
        model.webURL = " https://example.com/app "
        XCTAssertTrue(model.canAdvance)
        XCTAssertEqual(model.validatedWebURL?.absoluteString, "https://example.com/app")
    }

    func testTheInlineErrorAppearsOnlyForANonEmptyInvalidAddress() {
        let (model, _) = makeModel()
        XCTAssertNil(model.webURLError, "nothing typed yet")
        model.webURL = "   "
        XCTAssertNil(model.webURLError)
        model.webURL = "example.com"
        XCTAssertEqual(model.webURLError, "Enter an https:// address")
        model.webURL = "https://example.com"
        XCTAssertNil(model.webURLError)
    }

    // MARK: extra hosts

    func testExtraHostsParseOnePerLineWithTheSchemeAndPathStripped() {
        let text = "https://WhatsApp.com/chat\n  whatsapp.net  \n\nhttp://whatsapp.com\n   \n"
        XCTAssertEqual(WizardModel.parseExtraHosts(text), ["WhatsApp.com", "whatsapp.net", "whatsapp.com"])
        XCTAssertEqual(WizardModel.parseExtraHosts(""), [])
        XCTAssertEqual(WizardModel.parseExtraHosts("cdn.example.com?x=1\r\napi.example.com#top"), ["cdn.example.com", "api.example.com"])
    }

    func testMakeConfigLowerCasesAndDeduplicatesTheExtraHosts() {
        let (model, _) = makeModel()
        model.webURL = "https://example.com"
        model.name = "Example"
        model.extraHostsText = "https://WhatsApp.com/chat\n  whatsapp.net  \n\nhttp://whatsapp.com\n"
        XCTAssertEqual(model.makeConfig().webApp?.extraHosts, ["whatsapp.com", "whatsapp.net"])
    }

    // MARK: makeConfig

    func testMakeConfigProducesTheWebAppShape() {
        let (model, _) = makeModel()
        model.applyPreset(whatsapp)
        model.setMenuBarIcon(true)
        model.backgroundMode = true
        model.iconMode = .generated

        let config = model.makeConfig()
        XCTAssertEqual(config.kind, .webApp)
        XCTAssertEqual(config.name, "WhatsApp")
        XCTAssertEqual(config.slug, "whatsapp")
        XCTAssertEqual(config.bundleIdentifier, ShortcutConfig.bundleIdentifier(forSlug: "whatsapp"))
        XCTAssertEqual(config.targetPath, "")
        XCTAssertEqual(config.targetBundleIdentifier, "")
        XCTAssertEqual(config.launchMode, .dockShortcut)
        XCTAssertEqual(config.dataMode, .disabled)
        XCTAssertNil(config.dataPath)
        XCTAssertEqual(config.environment, [:])
        XCTAssertEqual(config.arguments, [])
        XCTAssertTrue(config.menuBarIcon)
        XCTAssertEqual(config.iconMode, .generated)
        XCTAssertNil(config.customIconPath)
        XCTAssertEqual(config.webApp, WebAppConfig(url: "https://web.whatsapp.com", dataStoreID: storeID, userAgent: .chrome,
                                                   badgeRegex: #"\((\d+)\)"#, extraHosts: ["whatsapp.com", "whatsapp.net"],
                                                   pageZoom: 1.0, backgroundMode: true))
    }

    func testTheDataStoreIdentifierIsStableAcrossCalls() {
        let (model, _) = makeModel()
        model.webURL = "https://example.com"
        model.name = "Example"
        XCTAssertEqual(model.makeConfig().webApp?.dataStoreID, storeID)
        XCTAssertEqual(model.makeConfig().webApp?.dataStoreID, model.makeConfig().webApp?.dataStoreID)
        let other = WizardModel()
        XCTAssertNotEqual(other.webDataStoreID, WizardModel().webDataStoreID, "each wizard session gets its own store")
    }

    func testABlankBadgePatternIsStoredAsNil() {
        let (model, _) = makeModel()
        model.webURL = "https://example.com"
        model.name = "Example"
        model.badgeRegex = "  \n"
        XCTAssertNil(model.makeConfig().webApp?.badgeRegex)
        model.badgeRegex = #"  \[(\d+)\]  "#
        XCTAssertEqual(model.makeConfig().webApp?.badgeRegex, #"\[(\d+)\]"#)
    }

    func testBackgroundModeNeedsTheMenuBarIcon() {
        let (model, _) = makeModel()
        model.webURL = "https://example.com"
        model.name = "Example"
        model.backgroundMode = true
        XCTAssertFalse(model.makeConfig().menuBarIcon)
        XCTAssertEqual(model.makeConfig().webApp?.backgroundMode, false, "background mode is not stored without the menu bar icon")

        model.setMenuBarIcon(true)
        model.backgroundMode = true
        XCTAssertEqual(model.makeConfig().webApp?.backgroundMode, true)

        model.setMenuBarIcon(false)
        XCTAssertFalse(model.backgroundMode, "turning the icon off clears background mode")
        XCTAssertEqual(model.makeConfig().webApp?.backgroundMode, false)
    }

    func testTheSlugStepsAroundTakenSlugsForWebApps() {
        let (model, _) = makeModel(takenSlugs: ["whatsapp"])
        model.applyPreset(whatsapp)
        let config = model.makeConfig()
        XCTAssertEqual(config.slug, "whatsapp-2")
        XCTAssertEqual(config.bundleIdentifier, ShortcutConfig.bundleIdentifier(forSlug: "whatsapp-2"))
        XCTAssertEqual(config.name, "WhatsApp")
    }

    // MARK: icon fetch

    func testAFetchedIconIsKeptAndLabelledFetchedFromSite() async {
        let (model, script) = makeModel([.data(iconBytes)])
        model.webURL = "https://example.com"
        model.name = "Example"
        XCTAssertEqual(model.iconMode, .copied)
        await model.fetchWebIcon()

        XCTAssertEqual(script.urls.map(\.absoluteString), ["https://example.com"])
        XCTAssertEqual(model.webIconFetchState, .fetched)
        XCTAssertEqual(model.webIconData, iconBytes)
        XCTAssertEqual(model.iconMode, .copied)
        XCTAssertEqual(model.makeConfig().iconMode, .copied)
        XCTAssertEqual(model.webIconPayload, iconBytes)
        XCTAssertEqual(model.iconDescription, "Fetched from site")
        XCTAssertNil(model.webIconStatusText)
    }

    func testANilResultFallsBackToAGeneratedTile() async {
        let (model, _) = makeModel([.nothing])
        model.webURL = "https://example.com"
        model.name = "Example"
        await model.fetchWebIcon()

        XCTAssertEqual(model.webIconFetchState, .unavailable("No icon found on the site."))
        XCTAssertNil(model.webIconData)
        XCTAssertEqual(model.iconMode, .generated)
        XCTAssertEqual(model.makeConfig().iconMode, .generated)
        XCTAssertNil(model.webIconPayload)
        XCTAssertEqual(model.iconDescription, "Generated tile")
        XCTAssertEqual(model.webIconStatusText, "Could not get the site icon; using a generated tile.")
    }

    func testAThrowingFetcherFallsBackToAGeneratedTile() async {
        let (model, _) = makeModel([.failure])
        model.webURL = "https://example.com"
        model.name = "Example"
        await model.fetchWebIcon()

        XCTAssertEqual(model.webIconFetchState, .unavailable("The connection was lost."))
        XCTAssertEqual(model.iconMode, .generated)
        XCTAssertNil(model.webIconData)
        XCTAssertEqual(model.makeConfig().iconMode, .generated)
    }

    func testAnEmptyDataResultCountsAsNoIcon() async {
        let (model, _) = makeModel([.data(Data())])
        model.webURL = "https://example.com"
        await model.fetchWebIcon()
        XCTAssertEqual(model.webIconFetchState, .unavailable("No icon found on the site."))
        XCTAssertEqual(model.iconMode, .generated)
    }

    func testACustomIconChoiceSurvivesAnyFetchResult() async {
        let (model, _) = makeModel([.nothing, .data(iconBytes)])
        model.webURL = "https://example.com"
        model.name = "Example"
        model.iconMode = .custom
        model.customIconPath = "/tmp/chosen-icon.png"

        await model.fetchWebIcon()
        XCTAssertEqual(model.iconMode, .custom)
        await model.fetchWebIcon()
        XCTAssertEqual(model.iconMode, .custom)
        XCTAssertEqual(model.webIconData, iconBytes)
        XCTAssertNil(model.webIconPayload, "only Fetched from site hands the bytes to the builder")
        let config = model.makeConfig()
        XCTAssertEqual(config.iconMode, .custom)
        XCTAssertEqual(config.customIconPath, "/tmp/chosen-icon.png")
    }

    func testACopiedModeWithoutFetchedDataIsWrittenAsGenerated() {
        let (model, _) = makeModel()
        model.webURL = "https://example.com"
        model.name = "Example"
        XCTAssertEqual(model.iconMode, .copied)
        XCTAssertNil(model.webIconData)
        XCTAssertEqual(model.makeConfig().iconMode, .generated, "a config never claims a fetched icon it does not have")
    }

    func testALaterSuccessfulFetchRestoresFetchedFromSite() async {
        let (model, _) = makeModel([.failure, .data(iconBytes)])
        model.webURL = "https://example.com"
        model.name = "Example"
        await model.fetchWebIcon()
        XCTAssertEqual(model.iconMode, .generated)

        model.webURL = "https://example.org"
        await model.fetchWebIcon()
        XCTAssertEqual(model.webIconFetchState, .fetched)
        XCTAssertEqual(model.iconMode, .copied)
        XCTAssertEqual(model.makeConfig().iconMode, .copied)
    }

    func testLeavingTheIdentityStepCancelsThePendingFetch() async {
        let (model, script) = makeModel([.data(iconBytes)])
        model.webURL = "https://example.com"
        model.step = .target
        model.next()
        XCTAssertEqual(model.step, .identity)
        let task = model.iconFetchTask
        XCTAssertNotNil(task)

        model.back()
        XCTAssertEqual(model.step, .target)
        XCTAssertNil(model.iconFetchTask)
        await task?.value
        XCTAssertEqual(script.urls, [], "a cancelled fetch never reaches the fetcher")
        XCTAssertEqual(model.webIconFetchState, .idle)
    }

    func testReenteringIdentityForTheSameAddressDoesNotFetchAgain() async {
        let (model, script) = makeModel([.data(iconBytes)])
        model.webURL = "https://example.com"
        model.name = "Example"
        model.step = .target
        model.next()
        await model.iconFetchTask?.value
        model.next() // webOptions
        model.back() // identity
        model.back() // target
        model.next() // identity again
        await model.iconFetchTask?.value
        XCTAssertEqual(script.urls.count, 1)
    }

    // MARK: review

    func testTheReviewRowsDescribeTheWebApp() {
        let (model, _) = makeModel()
        model.applyPreset(whatsapp)
        model.setMenuBarIcon(true)
        model.backgroundMode = true
        model.iconMode = .generated
        XCTAssertEqual(model.webReviewRows, [
            .init("Name", "WhatsApp"),
            .init("URL", "https://web.whatsapp.com"),
            .init("User agent", "Chrome"),
            .init("Data store id", storeID.uuidString),
            .init("Menu bar", "On, keeps running when the window closes"),
            .init("Icon", "Generated tile"),
        ])
        model.setMenuBarIcon(false)
        model.userAgent = .safari
        XCTAssertEqual(model.webReviewRows[2], .init("User agent", "Safari"))
        XCTAssertEqual(model.webReviewRows[4], .init("Menu bar", "Off"))
        model.setMenuBarIcon(true)
        XCTAssertEqual(model.webReviewRows[4], .init("Menu bar", "On"))
    }

    func testTheApplicationIconDescriptionsAreUnchanged() {
        let model = WizardModel()
        XCTAssertEqual(model.iconDescription, "Copied from target")
        model.iconMode = .generated
        XCTAssertEqual(model.iconDescription, "Generated tile")
        model.iconMode = .custom
        XCTAssertEqual(model.iconDescription, "Custom file")
        model.customIconPath = "/tmp/dir/icon.png"
        XCTAssertEqual(model.iconDescription, "Custom: icon.png")
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/WebWizardModelTests 2>&1 | grep -E 'error:|TEST (SUCCEEDED|FAILED)' | head -8`
Expected: `** TEST FAILED **` with compile errors such as `extra arguments at positions #3, #4, #5, #6 in call` (new `WizardModel.init` parameters), `value of type 'WizardModel' has no member 'steps'`, `type 'WizardModel.Step' has no member 'webOptions'`.

- [ ] **Step 3: Implement the model**

Replace the whole of `App/Sources/Views/Wizard/WizardModel.swift` with the file below. Everything from the old file is preserved; additions are the `Step.webOptions` case, `steps`/`stepNumber`, the "Web App" sections, and the web branches in `canAdvance`, `next()`, `back()`, `makeConfig()`, `refreshPreview()`.

```swift
import CompatProfiles
import DuplicatorCore
import Foundation
import Observation

/// Where the web app icon fetch stands (the identity step shows it). `unavailable` carries the reason for the log and
/// the tests; the user sees `WizardModel.webIconStatusText`.
enum WebIconFetchState: Equatable {
    case idle
    case fetching
    case fetched
    case unavailable(String)
}

/// State for the New Shortcut sheet. Pure model: no AppKit, so it is unit-testable.
@MainActor
@Observable
final class WizardModel {
    enum Step: Int, CaseIterable {
        case kind, target, identity, data, webOptions, review
    }

    /// One label/value line of the web app Review step.
    struct ReviewRow: Equatable {
        let label: String
        let value: String

        init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    var step: Step = .kind
    var kind: ShortcutKind = .app
    private(set) var targetURL: URL?
    private(set) var inspected: InspectedApp?
    private(set) var inspectError: String?
    var name = ""
    var iconMode: IconMode = .copied
    var customIconPath: String?
    var dataMode: DataMode = .auto
    var dataPath: String?
    var launchMode: LaunchMode = .dockShortcut
    /// The compatibility profile for the selected target, if the profiles in use have one (spec §8).
    private(set) var profile: AppProfile?
    /// The profile's `args` and `env`, copied into the new shortcut by `makeConfig()` as editable defaults; replaced
    /// whenever the target changes.
    private(set) var arguments: [String] = []
    private(set) var environment: [String: String] = [:]
    private(set) var preview: LaunchPlanPreview?
    private(set) var previewError: String?
    var isCreating = false
    var createError: String?

    // MARK: Web App state (kind == .webApp)

    /// The address field, exactly as typed; `validatedWebURL` trims and checks it.
    var webURL = ""
    /// The last preset applied; `highlightedPreset` is it only while `webURL` still matches the preset's address.
    private(set) var selectedPreset: WebAppPreset?
    var userAgent: UserAgentPreset = .safari
    /// Empty means "use the default pattern" (stored as nil).
    var badgeRegex = ""
    /// One host per line; `parseExtraHosts(_:)` strips schemes and paths.
    var extraHostsText = ""
    /// Only meaningful while `menuBarIcon` is on (`setMenuBarIcon(_:)` clears it, `makeConfig()` gates on it).
    var backgroundMode = false
    private(set) var menuBarIcon = false
    private(set) var webIconData: Data?
    private(set) var webIconFetchState: WebIconFetchState = .idle
    /// The icon fetch started by entering the identity step; tests await it.
    private(set) var iconFetchTask: Task<Void, Never>?
    let webAppPresets: [WebAppPreset]
    /// One `WKWebsiteDataStore` identifier per wizard session, so the Review row and the created shortcut agree.
    let webDataStoreID: UUID

    /// The last name this model filled in itself. A name still equal to it was not typed by the user, so picking
    /// another target may replace it.
    private var suggestedName = ""

    /// True while `launchMode` is System Launch only because a protected target forced it, so a later unprotected
    /// target can restore the default.
    private var launchModeWasForced = false

    /// True while `iconMode` is Generated tile only because the icon fetch found nothing, so a later successful fetch
    /// may restore Fetched from site (and a user's own pick is never overridden).
    private var iconModeWasFallback = false

    /// Bumped whenever a fetch starts or is cancelled; a fetch that finishes under an older number is stale.
    private var iconFetchGeneration = 0

    /// The address the last settled fetch was for, so re-entering the identity step does not fetch it again.
    private var fetchedURL: URL?

    /// Looks up the profile for a target bundle identifier; the sheet passes `AppState.profile(forBundleIdentifier:)`.
    private let profileLookup: @MainActor (String) -> AppProfile?

    /// Slugs the library already uses (`SlugAllocator.takenSlugs(in:)`); `slug` steps around them (final review M6).
    private let takenSlugs: Set<String>

    private let iconFetcher: any WebIconFetching

    /// Maps a preset's `userAgent` string to a preset value; the sheet passes `ProfilesModel.userAgentPreset(for:)`.
    private let userAgentResolver: @MainActor (WebAppPreset) -> UserAgentPreset

    init(prefillTarget: URL? = nil,
         takenSlugs: Set<String> = [],
         profileLookup: @escaping @MainActor (String) -> AppProfile? = { _ in nil },
         webAppPresets: [WebAppPreset] = [],
         webDataStoreID: UUID = UUID(),
         iconFetcher: any WebIconFetching = URLSessionWebIconFetcher(),
         userAgentResolver: @escaping @MainActor (WebAppPreset) -> UserAgentPreset = { _ in .safari }) {
        self.profileLookup = profileLookup
        self.takenSlugs = takenSlugs
        self.webAppPresets = webAppPresets
        self.webDataStoreID = webDataStoreID
        self.iconFetcher = iconFetcher
        self.userAgentResolver = userAgentResolver
        if let prefillTarget {
            selectTarget(prefillTarget)
            if inspected != nil { step = .identity }
        }
    }

    var isLastStep: Bool { step == .review }

    /// The steps this kind of shortcut goes through. A web app has no Data step (its data lives in a private web data
    /// store); Web App Options takes that slot.
    var steps: [Step] {
        kind == .webApp ? [.kind, .target, .identity, .webOptions, .review] : [.kind, .target, .identity, .data, .review]
    }

    /// 1-based position of `step` in `steps`, for the "Step N of M" header.
    var stepNumber: Int {
        (steps.firstIndex(of: step) ?? 0) + 1
    }

    /// The slug the new shortcut gets: the name's slug, or its first free `-2`, `-3`, … variant. Its bundle id and
    /// default data folder follow it.
    var slug: String {
        SlugAllocator.uniqueSlug(proposed: ShortcutConfig.slug(for: name.trimmingCharacters(in: .whitespaces)), taken: takenSlugs)
    }

    /// The installed apps the target step shows for `query`: all of them while it is empty, else the names that
    /// contain it (case-insensitive).
    static func filteredApps(_ apps: [InstalledApp], query: String) -> [InstalledApp] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// True when a non-empty search hides every app, so the step shows "No matches" instead of an empty grid. An
    /// empty query with no apps (the scan is still running, or found nothing) is not a search result.
    static func showsNoMatches(apps: [InstalledApp], query: String) -> Bool {
        !query.isEmpty && filteredApps(apps, query: query).isEmpty
    }

    /// Dock Shortcut cannot exec a protected binary (spec §4.1); the picker is locked to System Launch.
    /// Same rule as the editor's (`InspectedApp.requiresSystemLaunch`).
    var requiresSystemLaunch: Bool {
        inspected?.requiresSystemLaunch ?? false
    }

    var canAdvance: Bool {
        switch step {
        case .kind: kind == .app || kind == .webApp
        case .target: kind == .webApp ? validatedWebURL != nil : inspected != nil
        case .identity: !name.trimmingCharacters(in: .whitespaces).isEmpty && (iconMode != .custom || customIconPath != nil)
        case .data, .webOptions: true
        case .review:
            // A web app has no launch plan to wait for; it waits for an in-flight icon fetch instead.
            kind == .webApp ? (!isCreating && webIconFetchState != .fetching) : (preview != nil && !isCreating)
        }
    }

    func selectTarget(_ url: URL) {
        // Final review M5: a shortcut is never a target; it would chain launchers, or exec itself if it is this one.
        guard !TargetGuard.isShortcutBundle(at: url) else {
            targetURL = nil
            inspected = nil
            inspectError = TargetGuard.refusalMessage(forAppAt: url)
            profile = nil
            arguments = []
            environment = [:]
            return
        }
        targetURL = url
        do {
            let app = try AppInspector().inspect(appAt: url)
            inspected = app
            inspectError = nil
            profile = profileLookup(app.bundleIdentifier)
            arguments = profile?.args ?? []
            environment = profile?.env ?? [:]
            if name.isEmpty || name == suggestedName {
                name = "\(app.name) Copy"
                suggestedName = name
            }
            if requiresSystemLaunch {
                launchMode = .systemLaunch
                launchModeWasForced = true
            } else if launchModeWasForced {
                launchMode = .dockShortcut
                launchModeWasForced = false
            }
        } catch {
            inspected = nil
            inspectError = error.localizedDescription
            profile = nil
            arguments = []
            environment = [:]
        }
    }

    func next() {
        guard canAdvance, let i = steps.firstIndex(of: step), i + 1 < steps.count else { return }
        step = steps[i + 1]
        if step == .identity, kind == .webApp { startIconFetch() }
        if step == .review { refreshPreview() }
    }

    func back() {
        guard let i = steps.firstIndex(of: step), i > 0 else { return }
        if step == .identity { cancelIconFetch() }
        step = steps[i - 1]
    }

    func makeConfig() -> ShortcutConfig {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let finalSlug = slug
        if kind == .webApp { return makeWebConfig(name: trimmed, slug: finalSlug) }
        return ShortcutConfig(
            kind: kind,
            name: trimmed,
            slug: finalSlug,
            bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: finalSlug),
            targetPath: targetURL?.path ?? "",
            targetBundleIdentifier: inspected?.bundleIdentifier ?? "",
            launchMode: requiresSystemLaunch ? .systemLaunch : launchMode,
            dataMode: dataMode,
            dataPath: dataPath,
            environment: environment,
            arguments: arguments,
            iconMode: iconMode,
            customIconPath: iconMode == .custom ? customIconPath : nil
        )
    }

    /// Previews the plan the shortcut will actually run. `makeConfig()` leaves a default data folder as nil and
    /// `ShortcutBuilder` resolves it at write time; the planner would otherwise report "data separation skipped".
    /// A web app has no target to plan, so its preview stays nil and the Review step lists `webReviewRows` instead.
    func refreshPreview() {
        if kind == .webApp {
            preview = nil
            previewError = nil
            return
        }
        let config = makeConfig().resolvingDefaultDataPath(home: FileManager.default.homeDirectoryForCurrentUser)
        do {
            preview = try LaunchPlanPreview.make(config: config, bundleURL: nil)
            previewError = nil
        } catch {
            preview = nil
            previewError = error.localizedDescription
        }
    }

    // MARK: Web App

    /// The address as `WebAppURLValidator` accepts it (https, a host, no user info), nil while it does not validate.
    var validatedWebURL: URL? {
        do {
            return try WebAppURLValidator.validate(webURL)
        } catch {
            return nil
        }
    }

    /// The inline message under the address field: nil while it is empty (nothing typed yet) or valid.
    var webURLError: String? {
        guard !webURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, validatedWebURL == nil else { return nil }
        return WebAppURLError.invalidAddress.localizedDescription
    }

    /// The applied preset while the address field still holds the preset's address.
    var highlightedPreset: WebAppPreset? {
        guard let selectedPreset, selectedPreset.url == webURL.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return selectedPreset
    }

    /// Fills the address, user agent, badge pattern and extra hosts from `preset`, and the name when the user has not
    /// typed one. Every field stays editable afterwards.
    func applyPreset(_ preset: WebAppPreset) {
        selectedPreset = preset
        webURL = preset.url
        userAgent = userAgentResolver(preset)
        badgeRegex = preset.badgeRegex ?? ""
        extraHostsText = preset.extraHosts.joined(separator: "\n")
        if name.isEmpty || name == suggestedName {
            name = preset.name
            suggestedName = name
        }
    }

    func setMenuBarIcon(_ isOn: Bool) {
        menuBarIcon = isOn
        if !isOn { backgroundMode = false }
    }

    /// One host per non-empty line with any scheme, path, query or fragment removed. `WebAppConfig.init` then trims,
    /// lower-cases and de-duplicates.
    static func parseExtraHosts(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var host = line.trimmingCharacters(in: .whitespaces)
            if let separator = host.range(of: "://") { host = String(host[separator.upperBound...]) }
            if let end = host.firstIndex(where: { "/?#".contains($0) }) { host = String(host[..<end]) }
            return host.isEmpty ? nil : host
        }
    }

    /// The host a preset tile shows under its name; the raw string when it has no host.
    static func presetHost(_ preset: WebAppPreset) -> String {
        URL(string: preset.url)?.host() ?? preset.url
    }

    static func userAgentLabel(_ preset: UserAgentPreset) -> String {
        switch preset {
        case .safari: "Safari"
        case .chrome: "Chrome"
        }
    }

    /// What the icon row says. For a web app Copied means "Fetched from site".
    var iconDescription: String {
        switch iconMode {
        case .copied: kind == .webApp ? "Fetched from site" : "Copied from target"
        case .custom: customIconPath.map { "Custom: \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Custom file"
        case .generated: "Generated tile"
        }
    }

    /// The one-line status under the identity step's icon preview; nil when there is nothing to say.
    var webIconStatusText: String? {
        switch webIconFetchState {
        case .idle, .fetched: nil
        case .fetching: "Fetching the site icon…"
        case .unavailable: "Could not get the site icon; using a generated tile."
        }
    }

    /// The fetched icon bytes the builder turns into `AppIcon.icns`: only while the mode is Fetched from site.
    var webIconPayload: Data? {
        kind == .webApp && iconMode == .copied ? webIconData : nil
    }

    /// The Review step lines for a web app (it has no target, compatibility, profile or launch plan).
    var webReviewRows: [ReviewRow] {
        let menuBar = !menuBarIcon ? "Off" : (backgroundMode ? "On, keeps running when the window closes" : "On")
        return [
            ReviewRow("Name", name.trimmingCharacters(in: .whitespaces)),
            ReviewRow("URL", validatedWebURL?.absoluteString ?? webURL),
            ReviewRow("User agent", Self.userAgentLabel(userAgent)),
            ReviewRow("Data store id", webDataStoreID.uuidString),
            ReviewRow("Menu bar", menuBar),
            ReviewRow("Icon", iconDescription),
        ]
    }

    /// Fetches the site's icon for `validatedWebURL`. Fetched data keeps (or restores) Fetched from site; nil, empty
    /// data or a thrown error falls back to Generated tile, unless the user picked Custom file.
    func fetchWebIcon() async {
        guard !Task.isCancelled, kind == .webApp, let url = validatedWebURL else { return }
        iconFetchGeneration += 1
        let generation = iconFetchGeneration
        webIconData = nil
        fetchedURL = nil
        webIconFetchState = .fetching
        do {
            let data = try await iconFetcher.fetchIcon(for: url)
            guard generation == iconFetchGeneration else { return }
            if let data, !data.isEmpty {
                settleFetch(for: url, data: data)
            } else {
                settleFetch(for: url, unavailable: "No icon found on the site.")
            }
        } catch {
            guard generation == iconFetchGeneration else { return }
            settleFetch(for: url, unavailable: error.localizedDescription)
        }
    }

    private func settleFetch(for url: URL, data: Data) {
        webIconData = data
        webIconFetchState = .fetched
        fetchedURL = url
        if iconModeWasFallback, iconMode == .generated {
            iconMode = .copied
        }
        iconModeWasFallback = false
    }

    private func settleFetch(for url: URL, unavailable reason: String) {
        webIconData = nil
        webIconFetchState = .unavailable(reason)
        fetchedURL = url
        if iconMode == .copied {
            iconMode = .generated
            iconModeWasFallback = true
        }
    }

    private func startIconFetch() {
        guard let url = validatedWebURL else { return }
        if fetchedURL == url, webIconFetchState != .fetching, webIconFetchState != .idle { return }
        iconFetchTask?.cancel()
        iconFetchTask = Task { await self.fetchWebIcon() }
    }

    private func cancelIconFetch() {
        iconFetchGeneration += 1
        iconFetchTask?.cancel()
        iconFetchTask = nil
        if webIconFetchState == .fetching { webIconFetchState = .idle }
    }

    private func makeWebConfig(name: String, slug: String) -> ShortcutConfig {
        let badge = badgeRegex.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = validatedWebURL?.absoluteString ?? webURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // Copied means Fetched from site; without fetched bytes the honest mode is the generated tile.
        let effectiveIconMode: IconMode = iconMode == .copied && webIconData == nil ? .generated : iconMode
        return ShortcutConfig(
            kind: .webApp,
            name: name,
            slug: slug,
            bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: slug),
            targetPath: "",
            targetBundleIdentifier: "",
            launchMode: .dockShortcut,
            dataMode: .disabled,
            dataPath: nil,
            menuBarIcon: menuBarIcon,
            iconMode: effectiveIconMode,
            customIconPath: effectiveIconMode == .custom ? customIconPath : nil,
            webApp: WebAppConfig(
                url: address,
                dataStoreID: webDataStoreID,
                userAgent: userAgent,
                badgeRegex: badge.isEmpty ? nil : badge,
                extraHosts: Self.parseExtraHosts(extraHostsText),
                backgroundMode: backgroundMode && menuBarIcon
            )
        )
    }
}
```

Notes for the executor: `Task { await self.fetchWebIcon() }` inherits the main actor from the `@MainActor` class, so no `Sendable` capture issue arises. `startIconFetch()` skips a repeat fetch only when the previous fetch settled (`fetched` or `unavailable`) for the same address.

- [ ] **Step 4: Run the new tests and the existing wizard tests**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/WebWizardModelTests -only-testing:MacAppDuplicatorTests/WizardModelTests 2>&1 | grep -E "Test Suite '(WebWizardModelTests|WizardModelTests)' (passed|failed)|error:|TEST (SUCCEEDED|FAILED)"`
Expected: `Test Suite 'WebWizardModelTests' passed` (26 tests), `Test Suite 'WizardModelTests' passed` (16 tests, unchanged) and `** TEST SUCCEEDED **`. At this point the app target still builds because the views only use members that still exist (`Step.allCases.count` in `NewShortcutWizard` now counts 6 until Step 8; the switch in `NewShortcutWizard.body` is not exhaustive over `.webOptions`, so if Xcode reports `switch must be exhaustive`, do Step 8's switch edit first, then rerun this step).

- [ ] **Step 5: Commit the model**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add App/Sources/Views/Wizard/WizardModel.swift App/Tests/Wizard/WebWizardModelTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Wizard model: web app state, presets, URL gating, icon fetch and config" -m "WizardModel learns the Web App kind: a web step list that swaps Data for Web App Options, preset application, https address validation, extra host parsing, a stable data store id, an injected icon fetcher with a generated-tile fallback, and makeConfig output of kind webApp. Tests cover the model only." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```
(If Step 4 required the Step 8 switch edit to compile, commit `NewShortcutWizard.swift` with this commit as well and say so in the message body.)

- [ ] **Step 6: Add the preset grid, the web target step and the options step**

Create `App/Sources/Views/Wizard/WebAppPresetGrid.swift`:

```swift
import CompatProfiles
import SwiftUI

/// Preset tiles for the web target step: name over host, same Button-based tile as `InstalledAppsGrid` (a VoiceOver
/// button, Space from keyboard focus, Return handled explicitly because macOS gives it to the default button).
struct WebAppPresetGrid: View {
    let presets: [WebAppPreset]
    let selection: WebAppPreset?
    let onSelect: (WebAppPreset) -> Void

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(presets.enumerated()), id: \.offset) { _, preset in
                    let host = WizardModel.presetHost(preset)
                    Button {
                        onSelect(preset)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "globe").font(.title2).frame(height: 28)
                            Text(preset.name).font(.callout).lineLimit(1)
                            Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .frame(width: 132, height: 72)
                        .padding(6)
                        .background(selection == preset ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onKeyPress(.return) {
                        onSelect(preset)
                        return .handled
                    }
                    .accessibilityLabel("\(preset.name), \(host)")
                    .accessibilityAddTraits(selection == preset ? [.isButton, .isSelected] : [.isButton])
                }
            }
            .padding(4)
        }
    }
}

/// The target step for a web app: presets (name and host) and the `Website URL` field with inline validation.
struct WebTargetStep: View {
    @Bindable var model: WizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a website").font(.title3)
            if !model.webAppPresets.isEmpty {
                WebAppPresetGrid(presets: model.webAppPresets, selection: model.highlightedPreset) { model.applyPreset($0) }
                    .frame(minHeight: 120)
            }
            TextField("Website URL", text: $model.webURL, prompt: Text(verbatim: "https://example.com"))
                .textFieldStyle(.roundedBorder)
            if let error = model.webURLError {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption)
            }
            Spacer(minLength: 0)
        }
    }
}
```

Create `App/Sources/Views/Wizard/WebAppOptionsStep.swift`:

```swift
import DuplicatorCore
import SwiftUI

/// Wizard step `Web App Options` (replaces the Data step for web apps). Copy is verbatim from the Phase 4 skeleton,
/// decision 16.
struct WebAppOptionsStep: View {
    @Bindable var model: WizardModel

    var body: some View {
        Form {
            Text("Web App Options").font(.title3)
            Picker("User agent", selection: $model.userAgent) {
                Text("Safari").tag(UserAgentPreset.safari)
                Text("Chrome").tag(UserAgentPreset.chrome)
            }
            TextField("Badge pattern", text: $model.badgeRegex, prompt: Text(verbatim: #"\((\d+)\)"#))
            LabeledContent("Also open in app") {
                VStack(alignment: .leading, spacing: 4) {
                    TextEditor(text: $model.extraHostsText)
                        .font(.body.monospaced())
                        .frame(height: 72)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    Text("One host per line, for example whatsapp.com").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Menu bar icon", isOn: Binding(get: { model.menuBarIcon }, set: { model.setMenuBarIcon($0) }))
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Keep running in the menu bar when the window closes", isOn: $model.backgroundMode)
                    .disabled(!model.menuBarIcon)
                    .help(model.menuBarIcon ? "" : "Turn on the menu bar icon first")
                if !model.menuBarIcon {
                    Text("Turn on the menu bar icon first").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Web apps keep their data in a private web data store").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.columns)
    }
}
```

- [ ] **Step 7: Enable the kind, adapt the identity and review steps, forward the icon bytes**

In `App/Sources/Views/Wizard/WizardSteps.swift`, replace line 12:

```swift
        Option(kind: .webApp, title: "Web App", subtitle: "Coming in a later phase", enabled: false, symbol: "globe"),
```
with:
```swift
        Option(kind: .webApp, title: "Web App", subtitle: "Any website as its own app", enabled: true, symbol: "globe"),
```

Replace the whole `IdentityStep` (lines 95-155) with:

```swift
struct IdentityStep: View {
    @Bindable var model: WizardModel

    var body: some View {
        Form {
            Text("Name and icon").font(.title3)
            TextField("Name", text: $model.name)
                .help("This becomes the Dock title and the bundle name")
            Picker("Icon", selection: $model.iconMode) {
                Text(model.kind == .webApp ? "Fetched from site" : "Copied from target").tag(IconMode.copied)
                Text("Custom file").tag(IconMode.custom)
                Text("Generated tile").tag(IconMode.generated)
            }
            if model.iconMode == .custom {
                LabeledContent("Icon file") {
                    HStack {
                        Text(model.customIconPath ?? "No file chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Browse…") { chooseIcon() }
                    }
                }
            }
            LabeledContent("Preview") { preview.frame(width: 96, height: 96) }
            if model.kind == .webApp, let status = model.webIconStatusText {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if model.kind != .webApp {
                Picker("Launch mode", selection: $model.launchMode) {
                    Text("Dock Shortcut").tag(LaunchMode.dockShortcut)
                    Text("System Launch").tag(LaunchMode.systemLaunch)
                }
                .disabled(model.requiresSystemLaunch)
                .help(model.requiresSystemLaunch ? "This app is protected by launch constraints; System Launch is required" : "")
            }
        }
        .formStyle(.columns)
    }

    @ViewBuilder
    private var preview: some View {
        switch model.iconMode {
        case .copied:
            if model.kind == .webApp {
                if let data = model.webIconData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else if model.webIconFetchState == .fetching {
                    ProgressView()
                } else {
                    generatedTile
                }
            } else if let url = model.inspected?.iconFileURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable()
            } else if let target = model.targetURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: target.path)).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        case .custom:
            if let path = model.customIconPath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.secondary)
            }
        case .generated:
            generatedTile
        }
    }

    private var generatedTile: some View {
        Image(decorative: IconRenderer.generatedTile(initials: IconRenderer.initials(for: model.name), size: 192), scale: 2)
            .resizable()
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.icns, .png, .jpeg, .tiff]
        if panel.runModal() == .OK, let url = panel.url { model.customIconPath = url.path }
    }
}
```

In `ReviewStep` (lines 219-298) make three edits. (a) Replace the `Grid` block (lines 228-236):

```swift
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("Name", model.name)
                    row("Target", model.targetURL?.path ?? "")
                    row("Compatibility", CompatBadge.badge(for: model.inspected, profile: model.profile).label)
                    row("Profile", model.profile.map { "\($0.name) · \(ProfileSummary.statusLabel($0.status))" } ?? "None")
                    row("Launch mode", model.requiresSystemLaunch || model.launchMode == .systemLaunch ? "System Launch" : "Dock Shortcut")
                    row("Data", dataDescription)
                    row("Icon", iconDescription)
                }
```
with:
```swift
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    if model.kind == .webApp {
                        ForEach(model.webReviewRows, id: \.label) { row($0.label, $0.value) }
                    } else {
                        row("Name", model.name)
                        row("Target", model.targetURL?.path ?? "")
                        row("Compatibility", CompatBadge.badge(for: model.inspected, profile: model.profile).label)
                        row("Profile", model.profile.map { "\($0.name) · \(ProfileSummary.statusLabel($0.status))" } ?? "None")
                        row("Launch mode", model.requiresSystemLaunch || model.launchMode == .systemLaunch ? "System Launch" : "Dock Shortcut")
                        row("Data", dataDescription)
                        row("Icon", model.iconDescription)
                    }
                }
                if model.kind == .webApp, let status = model.webIconStatusText {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
```
(b) Change line 240 `if let profile = model.profile {` to `if model.kind != .webApp, let profile = model.profile {`. (c) Delete the private `iconDescription` property (lines 277-283); `model.iconDescription` returns the same three strings for apps (the unchanged-strings test in Step 1 covers this).

In `App/Sources/App/AppState.swift` replace lines 99-105 (`func create` signature through the builder call):

```swift
    func create(config: ShortcutConfig) async -> URL? {
        var config = config
        if config.homeSymlinkEntries == nil, settings.homeSymlinkEntries != HomeTreeBuilder.defaultSymlinkEntries {
            config.homeSymlinkEntries = settings.homeSymlinkEntries
        }
        do {
            let url = try builder.create(config: config, in: settings.outputFolder)
```
with:
```swift
    func create(config: ShortcutConfig, webIconData: Data? = nil) async -> URL? {
        var config = config
        if config.homeSymlinkEntries == nil, settings.homeSymlinkEntries != HomeTreeBuilder.defaultSymlinkEntries {
            config.homeSymlinkEntries = settings.homeSymlinkEntries
        }
        do {
            let url = try builder.create(config: config, in: settings.outputFolder, webIconData: webIconData)
```
and extend the doc comment above it with: `/// For a web app, \`webIconData\` is the icon fetched in the wizard (\`WizardModel.webIconPayload\`); the builder turns it into AppIcon.icns.` (Assumption A5; if Task 4 chose another hand-off, apply it here instead.)

- [ ] **Step 8: Wire the wizard sheet**

In `App/Sources/Views/Wizard/NewShortcutWizard.swift`:

1. Line 19: replace `Text("Step \(model.step.rawValue + 1) of \(WizardModel.Step.allCases.count)")` with `Text("Step \(model.stepNumber) of \(model.steps.count)")` (keep `.font(.caption).foregroundStyle(.secondary)`).
2. Replace the `switch model.step` block (lines 22-28) with:
```swift
                switch model.step {
                case .kind: KindStep(model: model)
                case .target:
                    if model.kind == .webApp { WebTargetStep(model: model) } else { TargetStep(model: model) }
                case .identity: IdentityStep(model: model)
                case .data: DataStep(model: model)
                case .webOptions: WebAppOptionsStep(model: model)
                case .review: ReviewStep(model: model)
                }
```
3. Replace the `WizardModel(...)` construction in `onAppear` (lines 62-64) with:
```swift
            model = WizardModel(prefillTarget: appState.wizardPrefillTarget,
                                takenSlugs: SlugAllocator.takenSlugs(in: appState.library.records),
                                profileLookup: { [appState] in appState.profile(forBundleIdentifier: $0) },
                                webAppPresets: appState.profiles.webAppPresets,
                                userAgentResolver: { [appState] in appState.profiles.userAgentPreset(for: $0) })
```
4. In `create()` replace `let url = await appState.create(config: model.makeConfig())` with `let url = await appState.create(config: model.makeConfig(), webIconData: model.webIconPayload)`.

- [ ] **Step 9: Build and run the whole app test suite**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh 2>&1 | tail -4`
Expected: `** TEST SUCCEEDED **`. Then count: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh 2>&1 | grep -cE "Test Case '.*' passed"` must equal the pre-task count (from Task 4's final run) plus 26. Also confirm the forbidden constructs are absent from the new code: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && grep -nE 'try\?|catch *\{ *\}|@unchecked Sendable|swiftlint:disable|nonisolated\(unsafe\)' App/Sources/Views/Wizard/WizardModel.swift App/Sources/Views/Wizard/WebAppPresetGrid.swift App/Sources/Views/Wizard/WebAppOptionsStep.swift App/Tests/Wizard/WebWizardModelTests.swift` prints nothing.

- [ ] **Step 10: Commit the views and wiring**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add App/Sources/Views/Wizard/WebAppPresetGrid.swift App/Sources/Views/Wizard/WebAppOptionsStep.swift App/Sources/Views/Wizard/WizardSteps.swift App/Sources/Views/Wizard/NewShortcutWizard.swift App/Sources/App/AppState.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Wizard: enable Web App with preset grid, URL step, options step and web review" -m "The Web App kind is now selectable (Any website as its own app). Its target step shows preset tiles and a Website URL field with inline validation, the Data step is replaced by Web App Options, identity offers Fetched from site with a generated-tile fallback, and Review lists URL, user agent, data store id and menu bar state. AppState.create forwards the fetched icon bytes to the builder." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

## Deviations

- **Deviation (step list):** the skeleton says only "data step skipped for web apps"; this plan adds `Step.webOptions` and a computed `steps`/`stepNumber` so the options step has a real slot and the sheet header counts correctly (`Step 4 of 5`). `Step.allCases` now has six cases; the only user (`NewShortcutWizard` header) moves to `steps`.
- **Deviation (icon hand-off):** fetched bytes travel as `AppState.create(config:webIconData:)` -> `ShortcutBuilder.create(config:in:webIconData:)` (assumption A5) because `WebAppConfig`/`ShortcutConfig` have no field for image bytes and the skeleton does not name the hand-off.
- **Additive copy not in skeleton decision 16:** `Choose a website` (target heading), `One host per line, for example whatsapp.com`, `Web apps keep their data in a private web data store`, `Fetching the site icon…`, `Could not get the site icon; using a generated tile.`. All other copy is verbatim.
- `ReviewStep` no longer owns `iconDescription`; `WizardModel.iconDescription` returns the identical app strings (tested).

## Resolved by coordinator

- Task 4's final plan binds `ShortcutBuilder.create(config:in:webIconData: Data? = nil)`; Step 7 and Step 8 stand as written.
- Task 4's `regenerate`/`duplicate` reuse the bundle's existing `AppIcon.icns` for `iconMode == .copied` when no new bytes are supplied; Task 6's editor Save passes none.
- `WebAppPreset.iconURL` stays unused in this phase (seed leaves it null).
- Badge pattern validation in the wizard is out of scope; invalid patterns fall back at runtime and the shell logs `usedFallbackPattern`.

---

### Task 6: Editor, delete, diagnostics, limitations, docs, version

Skeleton decisions 15 and 16 (editor, delete, docs parts). Everything here is app-target code (`App/`), the docs and the version bump. The wizard (Task 5), the builder/scanner (Task 4) and the shell (Tasks 2 and 3) are not touched.

**Files:**

Create:
- `App/Sources/Services/WebDataRemover.swift` (`WebDataRemoving`, `WebKitWebDataRemover`, `WebDataRemovalError`)
- `App/Sources/Services/WebEditorPolicy.swift` (pure editor rules: URL check, hosts, icon modes, save normalisation)
- `App/Sources/Views/WebAppSection.swift` (`WebAppSection`, `HostsEditor`)
- `App/Tests/TestSupport/WebTestSupport.swift` (`makeWebShortcutConfig`, `FakeWebDataRemover`, `RunningPaths`, `makeWebTestAppState`)
- `App/Tests/Services/WebDataRemoverTests.swift`
- `App/Tests/Services/WebEditorPolicyTests.swift`
- `App/Tests/App/AppStateWebTests.swift`
- `docs/acceptance/phase4-webshell.md`

Modify (line ranges read while planning):
- `App/Sources/App/AppState.swift` (1-277: add `webDataRemover` after `rebuildProgress`, `removeWebData(for:)`, `delete(_:removeData:removeWebData:)` at 150-166, web note in `dataFolderDeletionOption` at 207-214)
- `App/Sources/Services/DeleteConfirmation.swift` (1-14: `DeleteRequest`, `webData(shortcutName:)`)
- `App/Sources/Views/DeleteShortcutSheet.swift` (1-71: web second step, `DeleteRequest` closure)
- `App/Sources/Views/ShortcutEditorView.swift` (1-159: web layout, Save/Revert, `save()`, delete closure)
- `App/Sources/Views/EditorSections.swift` (`IdentitySection` 6-40 only; `AdvancedSection` stays as is: web apps never show it)
- `App/Sources/Views/DiagnosticsView.swift` (1-215: `DiagnosticsModel.web`, web branch of `make`, `reportText`, view rows)
- `App/Sources/App/KnownLimitations.swift` (1-117: doc comment, four entries appended after `export-replaces`)
- `App/Tests/Services/DeleteConfirmationTests.swift`, `App/Tests/App/DiagnosticsModelTests.swift`, `App/Tests/App/KnownLimitationsTests.swift` (new test methods)
- `README.md` (line 54, line 78, new section before `## Core API used by the app`)
- `App/project.yml` (56-57)

**Interfaces:**

Consumes (Task 1, exact names from `task-1-interfaces.md`): `ShortcutKind.webApp`, `ShortcutConfig.webApp: WebAppConfig?` and the `webApp:` initializer parameter, `WebAppConfig` (`url`, `dataStoreID`, `userAgent`, `badgeRegex`, `extraHosts`, `pageZoom`, `backgroundMode`, `normalizedHosts(_:)`), `UserAgentPreset` (`.safari`, `.chrome`), `WebAppURLValidator.validate(_:) throws -> URL`, `WebAppURLError.invalidAddress` (`Enter an https:// address`), `BadgeTitleParser(pattern:)` with `.pattern` and `.usedFallbackPattern`.

Consumes (Task 4, assumptions this plan states so Task 4's reviewer can check them):
- **A1** `AppState.init(settings:library:launcherBinary:webShellBinary:profiles:)` (skeleton decision 13: the builder gets `webShellBinary`). The only place this plan constructs `AppState` for web tests is `makeWebTestAppState` in `WebTestSupport.swift`; if Task 4 spelled the initializer differently, that one function changes.
- **A2** `ShortcutBuilder.regenerate(record:config:)` for a web app with `iconMode == .copied` reuses the existing bundle's `Contents/Resources/AppIcon.icns` byte for byte when no new image bytes are supplied (coordinator note from Task 5's final plan). The editor Save path therefore passes no icon data, and Step 22 asserts the bytes are unchanged.
- **A3** `LibraryScanner.record(forBundleAt:fileManager:)` returns a record for a web-app bundle (`targetExists == true`).
- `RunningShortcutMonitor` matches web apps by bundle identifier (decision 14); this task only asks `library.isRunning(record)`.

Produces:
- `protocol WebDataRemoving: Sendable { func removeWebData(identifier: UUID, bundleIdentifier: String) async throws }`
- `struct WebKitWebDataRemover: WebDataRemoving` with `init(webKitRoot: URL = ~/Library/WebKit)`, `static func isShellBundleIdentifier(_:) -> Bool`
- `enum WebDataRemovalError: LocalizedError, Equatable { case invalidBundleIdentifier(String), shortcutRunning(String) }`
- `AppState.webDataRemover: any WebDataRemoving` (`@ObservationIgnored var`), `AppState.removeWebData(for record: ShortcutRecord) async -> Bool`, `AppState.delete(_ record:, removeData:, removeWebData:) async -> [URL]` (new parameter defaults to `false`; every existing call stays valid)
- `struct DeleteRequest: Equatable { var removeDataFolder: Bool; var removeWebData: Bool; static let keepAll }`, `DeleteConfirmation.webData(shortcutName:)`; `DeleteShortcutSheet.onDelete` becomes `(DeleteRequest) async -> Void`
- `enum WebEditorPolicy` (`validatedURL`, `parsedHosts`, `badgePattern`, `iconModes`, `zoomLabel`, `saveConfig`)
- `DiagnosticsModel.web: DiagnosticsModel.WebDetails?`
- Four `KnownLimitations` ids (`web-no-passkeys`, `web-zoom-storage`, `web-notification-permission`, `web-popup-policy`); app version `0.4.0` (build `3`).

Wizard note for siblings: Task 5 names the wizard's new state `webAppPresets`, `webDataStoreID` and the model `WizardModel`. This task does not touch the wizard.

**Deviations from the skeleton** (each is also marked where it applies):

1. **Deviation (decision 15): web data is removed by deleting WebKit's store directory, not by `WKWebsiteDataStore.remove(forIdentifier:)`, and `removeWebData` takes the shortcut's bundle identifier.** The SDK header declares `remove(forIdentifier:)` main-actor only for macOS 14+ with the rule "WKWebView using the data store must be released before removal". On this Mac the store for an identifier lives at `~/Library/WebKit/<hosting process bundle id>/WebsiteDataStore/<lowercase uuid>` (I found `com.test.madprobe.A` and `.B` directories from an earlier probe, each holding Cookies, NetworkCache and LocalStorage). The shell runs under the shortcut's own bundle id (`com.mikekuta.appduplicator.<slug>`), so a call from the main app resolves to the main app's bundle id and cannot reach the shell's store. `WebKitWebDataRemover` therefore removes `<webKitRoot>/<shortcut bundle id>/WebsiteDataStore/<uuid>` (matched case-insensitively), after checking the bundle id is in the shell namespace (`com.mikekuta.appduplicator.` plus lowercase letters, digits, hyphens), so a corrupted config cannot point it at another app's folder. The type keeps the name `WebKitWebDataRemover` and the protocol keeps `removeWebData(identifier:...)`. I could not verify `remove(forIdentifier:)` on an unknown identifier: a scratch WebKit probe hung and segfaulted twice inside the sandbox, so I stopped (two honest attempts). The directory remover does not depend on that behaviour; unknown ids are a defined no-op and are tested against a fresh `UUID()` (Step 2). Live confirmation is acceptance Step 8.
2. **A web app's rename keeps its slug and bundle identifier** (Step 19, `WebEditorPolicy.saveConfig`). WebKit keys the store directory by the shell's bundle id, so the existing rename path (new slug, new bundle id) would orphan the logins. The bundle file name still follows the name.
3. **Delete aborts when web-data removal fails, and removal is refused while the shortcut runs.** Otherwise the shortcut (and the record needed to retry) would already be in the Trash. The first is covered by Step 7's tests; the sheet dismisses and the existing alert shows the error.
4. The editor hides Target / Profile / Launch / Advanced for a web app (none applies), and offers `Fetched from site` as an icon choice only while the saved mode is `.copied`, because the editor cannot refetch an icon.
5. Diagnostics shows the URL with query, fragment and credentials removed, because the report is meant to be pasted into tickets.
6. Skeleton decision 15 says the main app imports WebKit; with Deviation 1 it does not.
7. **Export and delete skip the target check through one guard, not three call-site edits** (Sub-task G). `ShortcutBuilder.export`, `ShortcutBuilder.delete` and the Diagnostics preview all reach `TargetResolver` through `resolvedPath(for:)`; a `config.kind == .webApp` guard returns `nil` there. Existing code already tolerated an empty `targetPath` by accident, so Steps 39-41 pin the behaviour with tests (temp-dir export and delete of a web bundle, and a stray bundle identifier that must not resolve).
8. **`CompatBadge.isShown(for:)` returns `kind != .webApp`** and the three view guards are located by text with an asserted single match, because Task 5 shifts the line numbers in `WizardSteps.swift`.
9. **The Diagnostics web branch bypasses the resolver and the launch-plan preview**: a web app has no target, arguments or environment, so those rows are omitted and replaced by the web rows (Sub-task E).
10. **Known Limitations grows from 20 to 24 entries** (four web entries, Sub-task F); README and acceptance step 11 state 24.

---

## Sub-task A: Test support and the web data remover

- [ ] **Step 1: Create the shared web test support**

Create `App/Tests/TestSupport/WebTestSupport.swift`:

```swift
import DuplicatorCore
import Foundation
import Synchronization
@testable import MacAppDuplicator

/// A web-app config the way the wizard builds one (skeleton decision 4): empty target, Dock Shortcut, data disabled.
func makeWebShortcutConfig(
    name: String = "Chat", url: String = "https://chat.example.com/", dataStoreID: UUID = UUID(),
    menuBarIcon: Bool = false, backgroundMode: Bool = false
) -> ShortcutConfig {
    let slug = ShortcutConfig.slug(for: name)
    return ShortcutConfig(
        kind: .webApp, name: name, slug: slug, bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: slug),
        targetPath: "", targetBundleIdentifier: "", launchMode: .dockShortcut, dataMode: .disabled,
        menuBarIcon: menuBarIcon, iconMode: .copied,
        webApp: WebAppConfig(url: url, dataStoreID: dataStoreID, backgroundMode: backgroundMode)
    )
}

struct FakeRemovalError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Records every removal request and optionally fails; never touches `~/Library/WebKit`.
final class FakeWebDataRemover: WebDataRemoving, Sendable {
    struct Call: Equatable, Sendable {
        let identifier: UUID
        let bundleIdentifier: String
    }

    private let recorded = Mutex<[Call]>([])
    private let failureMessage: String?

    init(failureMessage: String? = nil) {
        self.failureMessage = failureMessage
    }

    var calls: [Call] { recorded.withLock { $0 } }

    func removeWebData(identifier: UUID, bundleIdentifier: String) async throws {
        recorded.withLock { $0.append(Call(identifier: identifier, bundleIdentifier: bundleIdentifier)) }
        if let failureMessage { throw FakeRemovalError(message: failureMessage) }
    }
}

/// The standardized bundle paths a stub `RunningShortcutMonitor` probe reports as running.
final class RunningPaths: Sendable {
    private let storage = Mutex<Set<String>>([])

    func set(_ paths: Set<String>) { storage.withLock { $0 = paths } }
    var paths: Set<String> { storage.withLock { $0 } }
}

/// The one place the web tests construct an `AppState` (assumption A1: Task 4 adds `webShellBinary:`).
@MainActor
func makeWebTestAppState(
    settings: AppSettings, library: ShortcutLibrary, launcher: URL, webShell: URL, remover: any WebDataRemoving
) -> AppState {
    let state = AppState(settings: settings, library: library, launcherBinary: launcher, webShellBinary: webShell)
    state.webDataRemover = remover
    return state
}
```

- [ ] **Step 2: Write the failing remover tests**

Create `App/Tests/Services/WebDataRemoverTests.swift`:

```swift
import XCTest
@testable import MacAppDuplicator

final class WebDataRemoverTests: XCTestCase {
    private var root: URL!
    private let bundleID = "com.mikekuta.appduplicator.chat"

    override func setUpWithError() throws {
        root = try makeAppTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    /// Lays out `<root>/<bundle>/WebsiteDataStore/<name>/{Cookies/Cookies.binarycookies, NetworkCache/entry}` the way WebKit does.
    @discardableResult
    private func makeStore(named name: String, bundle: String) throws -> URL {
        let store = root.appending(path: "\(bundle)/WebsiteDataStore/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: store.appending(path: "Cookies"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.appending(path: "NetworkCache"), withIntermediateDirectories: true)
        try Data([1]).write(to: store.appending(path: "Cookies/Cookies.binarycookies"))
        try Data([2]).write(to: store.appending(path: "NetworkCache/entry"))
        return store
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testRemovesTheStoreAndEverythingInItButNothingElse() async throws {
        let id = UUID()
        let store = try makeStore(named: id.uuidString.lowercased(), bundle: bundleID)
        let otherStoreSameApp = try makeStore(named: UUID().uuidString.lowercased(), bundle: bundleID)
        let sameIDOtherApp = try makeStore(named: id.uuidString.lowercased(), bundle: "com.mikekuta.appduplicator.mail")

        try await WebKitWebDataRemover(webKitRoot: root).removeWebData(identifier: id, bundleIdentifier: bundleID)

        XCTAssertFalse(exists(store), "the store directory goes, cookies and cache with it")
        XCTAssertTrue(exists(otherStoreSameApp), "another store of the same web app stays")
        XCTAssertTrue(exists(sameIDOtherApp), "the same id under another web app's bundle id stays")
    }

    func testMatchesTheStoreNameCaseInsensitively() async throws {
        let id = UUID()
        let store = try makeStore(named: id.uuidString.uppercased(), bundle: bundleID)

        try await WebKitWebDataRemover(webKitRoot: root).removeWebData(identifier: id, bundleIdentifier: bundleID)

        XCTAssertFalse(exists(store))
    }

    /// The contract the plan relies on instead of `WKWebsiteDataStore.remove(forIdentifier:)` on an unknown identifier:
    /// a fresh random id is a no-op that neither throws nor creates anything.
    func testAFreshRandomIdentifierIsANoOp() async throws {
        let remover = WebKitWebDataRemover(webKitRoot: root)
        try await remover.removeWebData(identifier: UUID(), bundleIdentifier: bundleID)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [], "nothing is created")

        let kept = try makeStore(named: UUID().uuidString.lowercased(), bundle: bundleID)
        try await remover.removeWebData(identifier: UUID(), bundleIdentifier: bundleID)
        XCTAssertTrue(exists(kept), "an unknown id leaves the known stores alone")
    }

    func testRefusesABundleIdentifierOutsideTheShellNamespace() async throws {
        let id = UUID()
        let victim = try makeStore(named: id.uuidString.lowercased(), bundle: "com.apple.Safari")
        let remover = WebKitWebDataRemover(webKitRoot: root)

        for bad in ["com.apple.Safari", "", "com.mikekuta.appduplicator.", "com.mikekuta.appduplicator.Chat",
                    "com.mikekuta.appduplicator.../x", "com.mikekuta.appduplicator.a/b", "com.mikekuta.appduplicator.chat extra"] {
            do {
                try await remover.removeWebData(identifier: id, bundleIdentifier: bad)
                XCTFail("\(bad) must be refused")
            } catch {
                XCTAssertEqual(error as? WebDataRemovalError, .invalidBundleIdentifier(bad))
            }
        }
        XCTAssertTrue(exists(victim))
    }

    func testShellBundleIdentifierRule() {
        XCTAssertTrue(WebKitWebDataRemover.isShellBundleIdentifier("com.mikekuta.appduplicator.chat-2"))
        XCTAssertFalse(WebKitWebDataRemover.isShellBundleIdentifier("com.mikekuta.appduplicator.caf\u{00E9}"))
        XCTAssertFalse(WebKitWebDataRemover.isShellBundleIdentifier("com.example.chat"))
    }

    func testErrorCopyNamesTheProblem() {
        XCTAssertEqual(
            WebDataRemovalError.shortcutRunning("Chat").errorDescription,
            "Quit “Chat” before removing its web data."
        )
        XCTAssertEqual(
            WebDataRemovalError.invalidBundleIdentifier("com.apple.Safari").errorDescription,
            "“com.apple.Safari” is not a web app bundle identifier, so no web data was removed."
        )
    }
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/WebDataRemoverTests`
Expected: the build fails with `cannot find 'WebKitWebDataRemover' in scope` and `cannot find type 'WebDataRemoving' in scope` (from `WebTestSupport.swift`), and `cannot find 'WebDataRemovalError' in scope`. If `AppState(... webShellBinary:)` errors before those, Task 4 is not merged: stop and ask the orchestrator for the real initializer (assumption A1).

- [ ] **Step 4: Implement the remover**

Create `App/Sources/Services/WebDataRemover.swift`:

```swift
import DuplicatorCore
import Foundation

/// Why web data was not removed.
enum WebDataRemovalError: LocalizedError, Equatable {
    /// The bundle identifier is not one App Duplicator gives a shortcut (`ShortcutConfig.bundleIdentifierPrefix` plus a slug).
    case invalidBundleIdentifier(String)
    /// The web app is running; WebKit keeps its store open until the web view is released.
    case shortcutRunning(String)

    var errorDescription: String? {
        switch self {
        case .invalidBundleIdentifier(let identifier):
            "“\(identifier)” is not a web app bundle identifier, so no web data was removed."
        case .shortcutRunning(let name):
            "Quit “\(name)” before removing its web data."
        }
    }
}

/// Removes the logins, cookies and cache a web app keeps in its `WKWebsiteDataStore(forIdentifier:)`.
protocol WebDataRemoving: Sendable {
    /// `bundleIdentifier` is the web app shortcut's own bundle identifier: WebKit files the store under the hosting
    /// process's bundle identifier, which for a web app is the shortcut's, never this app's. An identifier with no
    /// store is not an error.
    func removeWebData(identifier: UUID, bundleIdentifier: String) async throws
}

/// Deletes `<webKitRoot>/<bundle id>/WebsiteDataStore/<store id>`, the one directory WebKit keeps per identified store
/// (Cookies, NetworkCache, LocalStorage and the rest). Calling `WKWebsiteDataStore.remove(forIdentifier:)` from this
/// app would resolve to this app's own bundle identifier and miss the shell's store (Task 6 Deviation 1).
struct WebKitWebDataRemover: WebDataRemoving {
    let webKitRoot: URL

    init(webKitRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/WebKit", directoryHint: .isDirectory)) {
        self.webKitRoot = webKitRoot
    }

    /// True for `com.mikekuta.appduplicator.` followed by a slug: lowercase ASCII letters, digits and hyphens.
    static func isShellBundleIdentifier(_ identifier: String) -> Bool {
        let prefix = ShortcutConfig.bundleIdentifierPrefix
        guard identifier.hasPrefix(prefix) else { return false }
        let slug = identifier.dropFirst(prefix.count)
        return !slug.isEmpty && slug.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    func removeWebData(identifier: UUID, bundleIdentifier: String) async throws {
        guard Self.isShellBundleIdentifier(bundleIdentifier) else {
            throw WebDataRemovalError.invalidBundleIdentifier(bundleIdentifier)
        }
        let root = webKitRoot
        let storeName = identifier.uuidString.lowercased()
        try await Task.detached(priority: .userInitiated) {
            try Self.removeStore(named: storeName, bundleIdentifier: bundleIdentifier, in: root)
        }.value
    }

    private static func removeStore(named storeName: String, bundleIdentifier: String, in root: URL) throws {
        let fileManager = FileManager.default
        let stores = root.appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "WebsiteDataStore", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: stores.path) else { return }
        for entry in try fileManager.contentsOfDirectory(at: stores, includingPropertiesForKeys: nil)
        where entry.lastPathComponent.lowercased() == storeName {
            try fileManager.removeItem(at: entry)
        }
    }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/WebDataRemoverTests`
Expected: `Executed 6 tests, with 0 failures` and `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add App/Sources/Services/WebDataRemover.swift App/Tests/TestSupport/WebTestSupport.swift App/Tests/Services/WebDataRemoverTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Add the web data remover that deletes a web app's WebKit store

The shell keeps its identified data store under its own bundle identifier, so the remover takes that identifier and deletes the store directory after checking the identifier belongs to a shortcut.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

## Sub-task B: AppState removal and delete wiring

- [ ] **Step 7: Write the failing AppState tests**

Create `App/Tests/App/AppStateWebTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

@MainActor
final class AppStateWebTests: XCTestCase {
    private var dir: URL!
    private var out: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var settings: AppSettings!
    private var running: RunningPaths!
    private var library: ShortcutLibrary!
    private var remover: FakeWebDataRemover!
    private var state: AppState!
    private var launcher: URL!
    private var webShell: URL!

    override func setUp() async throws {
        dir = try makeAppTemporaryDirectory()
        out = dir.appending(path: "out", directoryHint: .isDirectory)
        (defaults, suite) = makeTestDefaults()
        settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        settings.outputFolder = out
        running = RunningPaths()
        let runningPaths = running!
        library = ShortcutLibrary(settings: settings, monitor: RunningShortcutMonitor(probe: { runningPaths.paths }))
        launcher = dir.appending(path: "Launcher")
        webShell = dir.appending(path: "WebShell")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: launcher)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: webShell)
        useRemover(FakeWebDataRemover())
    }

    override func tearDown() async throws {
        library.stop()
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: dir)
    }

    private func useRemover(_ newRemover: FakeWebDataRemover) {
        remover = newRemover
        state = makeWebTestAppState(settings: settings, library: library, launcher: launcher, webShell: webShell, remover: newRemover)
    }

    /// Writes a web-app bundle into the output folder, rescans and returns its record.
    private func makeWebRecord(name: String = "Chat", dataStoreID: UUID = UUID()) async throws -> ShortcutRecord {
        let bundle = try writeShortcutBundle(named: name, in: out, config: makeWebShortcutConfig(name: name, dataStoreID: dataStoreID))
        await library.rescan()
        return try XCTUnwrap(library.record(for: bundle))
    }

    func testRemoveWebDataPassesTheStoreIdAndTheShortcutBundleIdentifier() async throws {
        let id = UUID()
        let record = try await makeWebRecord(dataStoreID: id)

        let removed = await state.removeWebData(for: record)

        XCTAssertTrue(removed)
        XCTAssertEqual(remover.calls, [FakeWebDataRemover.Call(identifier: id, bundleIdentifier: "com.mikekuta.appduplicator.chat")])
        XCTAssertNil(state.pendingError)
    }

    func testRemoveWebDataFailureSurfacesAnAlert() async throws {
        useRemover(FakeWebDataRemover(failureMessage: "The disk is on fire."))
        let record = try await makeWebRecord()

        let removed = await state.removeWebData(for: record)

        XCTAssertFalse(removed)
        XCTAssertEqual(state.pendingError?.context, "Could not remove web data")
        XCTAssertEqual(state.pendingError?.message, "The disk is on fire.")
    }

    func testRemoveWebDataIsRefusedWhileTheWebAppRuns() async throws {
        let record = try await makeWebRecord()
        running.set([record.bundleURL.standardizedFileURL.path])
        await library.monitor.refresh()

        let removed = await state.removeWebData(for: record)

        XCTAssertFalse(removed)
        XCTAssertTrue(remover.calls.isEmpty, "a running web app keeps its store open, so nothing is removed")
        XCTAssertEqual(state.pendingError?.message, "Quit “Chat” before removing its web data.")
    }

    func testRemoveWebDataIgnoresAShortcutThatIsNotAWebApp() async throws {
        let bundle = try writeShortcutBundle(named: "Plain", in: out, config: makeConfig(name: "Plain"))
        await library.rescan()
        let record = try XCTUnwrap(library.record(for: bundle))

        let removed = await state.removeWebData(for: record)

        XCTAssertFalse(removed)
        XCTAssertTrue(remover.calls.isEmpty)
        XCTAssertNil(state.pendingError)
    }

    func testDeleteKeepsWebDataByDefault() async throws {
        let record = try await makeWebRecord()

        let trashed = await state.delete(record, removeData: false)

        XCTAssertEqual(trashed.count, 1)
        XCTAssertTrue(remover.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.bundleURL.path))
    }

    func testDeleteRemovesWebDataBeforeTrashingWhenAsked() async throws {
        let id = UUID()
        let record = try await makeWebRecord(dataStoreID: id)

        let trashed = await state.delete(record, removeData: false, removeWebData: true)

        XCTAssertEqual(trashed.count, 1)
        XCTAssertEqual(remover.calls.map(\.identifier), [id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.bundleURL.path))
        XCTAssertNil(state.pendingError)
    }

    func testDeleteStopsAndKeepsTheShortcutWhenWebDataRemovalFails() async throws {
        useRemover(FakeWebDataRemover(failureMessage: "Permission denied."))
        let record = try await makeWebRecord()

        let trashed = await state.delete(record, removeData: false, removeWebData: true)

        XCTAssertTrue(trashed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.bundleURL.path), "the shortcut stays so the user can retry")
        XCTAssertEqual(state.pendingError?.context, "Could not remove web data")
    }

    func testDataFolderDeletionIsUnavailableForAWebApp() async throws {
        let record = try await makeWebRecord()
        XCTAssertEqual(
            state.dataFolderDeletionOption(for: record),
            .unavailable(note: "A web app keeps its logins and cookies in web data, not in a data folder.")
        )
    }
}
```

- [ ] **Step 8: Run to see them fail**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/AppStateWebTests`
Expected: compile errors `value of type 'AppState' has no member 'webDataRemover'`, `has no member 'removeWebData'`, `extra argument 'removeWebData' in call`.

- [ ] **Step 9: Implement the AppState changes**

In `App/Sources/App/AppState.swift`, after the `var rebuildProgress: RebuildProgress?` line add:

```swift
    /// Removes a web app's WebKit store (Task 6). A property rather than an initializer argument so tests swap in a
    /// fake without a second initializer; the default deletes real files under `~/Library/WebKit`.
    @ObservationIgnored var webDataRemover: any WebDataRemoving = WebKitWebDataRemover()
```

Replace the whole `delete(_:removeData:)` method (doc comment included) with:

```swift
    /// Moves the shortcut (and, with `removeData`, its data folder) to the Trash. With `removesWebData` a web app's
    /// logins, cookies and cache are removed first; when that fails nothing is trashed, so the shortcut stays and the
    /// error alert explains why. Delete is offered only from the selected shortcut's editor, and a selection made by an
    /// earlier duplicate or rename must not survive into the next detail view, so the selection is always cleared.
    /// Returns the Trash locations (empty on failure).
    @discardableResult
    func delete(_ record: ShortcutRecord, removeData: Bool, removeWebData removesWebData: Bool = false) async -> [URL] {
        if removesWebData, !(await self.removeWebData(for: record)) { return [] }
        do {
            let trashed = try builder.delete(
                record: record, removeData: removeData,
                libraryFolders: settings.allLibraryFolders, otherRecordDataPaths: dataPathsInUse(excluding: record.bundleURL),
                shortcutBundles: library.records.map(\.bundleURL)
            )
            selection = nil
            await library.rescan()
            return trashed
        } catch {
            present(error, context: "Could not delete shortcut")
            return []
        }
    }

    /// Removes a web app's logins, cookies and cache (editor `Remove Web Data…` and the delete sheet's second step).
    /// Refused while the web app runs, because WebKit keeps the store open until the web view is released. Returns
    /// false (and sets `pendingError`) on failure; false without an alert for a shortcut that is not a web app.
    @discardableResult
    func removeWebData(for record: ShortcutRecord) async -> Bool {
        guard record.config.kind == .webApp, let web = record.config.webApp else { return false }
        guard !library.isRunning(record) else {
            present(WebDataRemovalError.shortcutRunning(record.name), context: "Could not remove web data")
            return false
        }
        do {
            try await webDataRemover.removeWebData(identifier: web.dataStoreID, bundleIdentifier: record.config.bundleIdentifier)
            return true
        } catch {
            present(error, context: "Could not remove web data")
            return false
        }
    }
```

In `dataFolderDeletionOption(for:)`, insert before `guard record.config.dataMode != .disabled else {`:

```swift
        if record.config.kind == .webApp {
            return .unavailable(note: "A web app keeps its logins and cookies in web data, not in a data folder.")
        }
```

- [ ] **Step 10: Run to see them pass**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/AppStateWebTests -only-testing:MacAppDuplicatorTests/AppStateTests`
Expected: `0 failures` for both classes (AppStateTests proves the existing `delete(_:removeData:)` callers still compile and behave).

- [ ] **Step 11: Commit**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add App/Sources/App/AppState.swift App/Tests/App/AppStateWebTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Add AppState.removeWebData and optional web data removal on delete

Removal is refused while the web app runs and aborts the delete when it fails, so the shortcut is never trashed without its web data when the user asked for both.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

## Sub-task C: Delete confirmation second step for web apps

- [ ] **Step 12: Write the failing confirmation tests**

Append these two methods inside `DeleteConfirmationTests` in `App/Tests/Services/DeleteConfirmationTests.swift` (before the final `}`):

```swift

    func testWebDataConfirmationNamesTheShortcutAndWhatGoes() {
        let confirmation = DeleteConfirmation.webData(shortcutName: "Chat")
        XCTAssertEqual(confirmation.title, "Also remove web data (logins, cookies, cache)?")
        XCTAssertEqual(
            confirmation.message,
            "Removing it signs “Chat” out of every site and deletes its cookies, cache and local storage from this Mac. Keeping it leaves them in place, so putting the shortcut back from the Trash brings the logins back."
        )
    }

    func testDeleteRequestKeepsEverythingByDefault() {
        XCTAssertEqual(DeleteRequest.keepAll, DeleteRequest(removeDataFolder: false, removeWebData: false))
        XCTAssertNotEqual(DeleteRequest.keepAll, DeleteRequest(removeDataFolder: false, removeWebData: true))
    }
```

- [ ] **Step 13: Run to see them fail**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/DeleteConfirmationTests`
Expected: `type 'DeleteConfirmation' has no member 'webData'` and `cannot find 'DeleteRequest' in scope`.

- [ ] **Step 14: Implement the confirmation, the request type, and wire the sheet and the editor call site**

In `App/Sources/Services/DeleteConfirmation.swift` replace the whole file with:

```swift
import Foundation

/// The second step before something irreversible goes with a shortcut: a data folder outside the data root (re-review
/// Minor 1, final review M24) or a web app's web data (Phase 4). The delete sheet asks again, naming what goes.
struct DeleteConfirmation: Equatable {
    let title: String
    let message: String

    private init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    /// Nil unless `removeData` is on and `option` offers a folder outside the data root.
    init?(shortcutName: String, option: DataFolderDeletionOption, removeData: Bool) {
        guard removeData, case .available(folder: let folder, outsideDataRoot: true) = option else { return nil }
        self.init(
            title: "Also move “\(folder.lastPathComponent)” to the Trash?",
            message: "The data folder of “\(shortcutName)” is \(folder.path), outside ~/Library/Application Support/App Duplicator. Everything in it is moved to the Trash with the shortcut."
        )
    }

    /// Asked for every web app on Delete; the default answer keeps the web data.
    static func webData(shortcutName: String) -> DeleteConfirmation {
        DeleteConfirmation(
            title: "Also remove web data (logins, cookies, cache)?",
            message: "Removing it signs “\(shortcutName)” out of every site and deletes its cookies, cache and local storage from this Mac. Keeping it leaves them in place, so putting the shortcut back from the Trash brings the logins back."
        )
    }
}

/// What the delete sheet asks `AppState.delete` to do besides trashing the bundle.
struct DeleteRequest: Equatable {
    var removeDataFolder: Bool
    var removeWebData: Bool

    /// Trash the shortcut and keep both the data folder and the web data.
    static let keepAll = DeleteRequest(removeDataFolder: false, removeWebData: false)
}
```

Replace `App/Sources/Views/DeleteShortcutSheet.swift` with:

```swift
import DuplicatorCore
import SwiftUI

/// Confirms a delete. The data-folder toggle appears only for a folder `AppState.dataFolderDeletionOption` approved
/// (final review I1): never for Disabled mode, a missing folder, or a folder `DataPathGuard` refuses. Trashing a
/// folder outside the data root takes a second, destructive confirmation that names it (re-review Minor 1, final
/// review M24). A web app has no data folder; its second step asks whether to remove its web data too, and the
/// default button keeps it.
struct DeleteShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss
    let record: ShortcutRecord
    let dataFolder: DataFolderDeletionOption
    let onDelete: (DeleteRequest) async -> Void
    @State private var removeData = false
    @State private var pendingConfirmation: DeleteConfirmation?

    private var isWebApp: Bool { record.config.kind == .webApp }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete “\(record.name)”?").font(.headline)
            Text(isWebApp ? "The web app is moved to the Trash." : "The shortcut is moved to the Trash. The target app is never touched.")
            switch dataFolder {
            case .unavailable(let note):
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .available(let folder, let outsideDataRoot):
                Toggle("Also move the data folder to the Trash", isOn: $removeData)
                Text(folder.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                if outsideDataRoot {
                    Label("This folder is outside ~/Library/Application Support/App Duplicator: \(folder.path)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    if isWebApp {
                        pendingConfirmation = DeleteConfirmation.webData(shortcutName: record.name)
                        return
                    }
                    let removesData = removeData && isDataFolderAvailable
                    if let confirmation = DeleteConfirmation(shortcutName: record.name, option: dataFolder, removeData: removesData) {
                        pendingConfirmation = confirmation
                    } else {
                        delete(DeleteRequest(removeDataFolder: removesData, removeWebData: false))
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .confirmationDialog(
            pendingConfirmation?.title ?? "",
            isPresented: Binding(get: { pendingConfirmation != nil }, set: { if !$0 { pendingConfirmation = nil } }),
            titleVisibility: .visible,
            presenting: pendingConfirmation
        ) { _ in
            if isWebApp {
                Button("Keep Web Data") { delete(.keepAll) }.keyboardShortcut(.defaultAction)
                Button("Remove Web Data", role: .destructive) { delete(DeleteRequest(removeDataFolder: false, removeWebData: true)) }
            } else {
                Button("Move to Trash", role: .destructive) { delete(DeleteRequest(removeDataFolder: true, removeWebData: false)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private var isDataFolderAvailable: Bool {
        if case .available = dataFolder { true } else { false }
    }

    private func delete(_ request: DeleteRequest) {
        Task {
            await onDelete(request)
            dismiss()
        }
    }
}
```

In `App/Sources/Views/ShortcutEditorView.swift` (the `.sheet(isPresented: $isDeletePresented)` block, lines 109-113) replace

```swift
            DeleteShortcutSheet(record: record, dataFolder: appState.dataFolderDeletionOption(for: record)) { removeData in
                await appState.delete(record, removeData: removeData)
            }
```

with

```swift
            DeleteShortcutSheet(record: record, dataFolder: appState.dataFolderDeletionOption(for: record)) { request in
                await appState.delete(record, removeData: request.removeDataFolder, removeWebData: request.removeWebData)
            }
```

Confirm no other caller: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && grep -rn "DeleteShortcutSheet(" App` must print exactly the one line in `ShortcutEditorView.swift`.

- [ ] **Step 15: Run to see them pass**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/DeleteConfirmationTests -only-testing:MacAppDuplicatorTests/AppStateTests`
Expected: `0 failures`; the app target compiles with the new sheet (this is the compile check for the view code).

- [ ] **Step 16: Commit**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add App/Sources/Services/DeleteConfirmation.swift App/Sources/Views/DeleteShortcutSheet.swift App/Sources/Views/ShortcutEditorView.swift App/Tests/Services/DeleteConfirmationTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Ask whether to remove web data when deleting a web app

The delete sheet's second step defaults to keeping the web data, so a shortcut put back from the Trash still has its logins.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

## Sub-task D: Web app editor

- [ ] **Step 17: Write the failing editor policy tests**

Create `App/Tests/Services/WebEditorPolicyTests.swift`:

```swift
import DuplicatorCore
import XCTest
@testable import MacAppDuplicator

final class WebEditorPolicyTests: XCTestCase {
    func testValidatedURLAcceptsAnHTTPSAddress() throws {
        XCTAssertEqual(try WebEditorPolicy.validatedURL("https://chat.example.com/app?x=1").get(), "https://chat.example.com/app?x=1")
    }

    func testValidatedURLRefusesAnythingElseWithTheSharedCopy() {
        for bad in ["", "not a url", "http://chat.example.com", "https://user@evil.example", "ftp://chat.example.com"] {
            switch WebEditorPolicy.validatedURL(bad) {
            case .success(let url): XCTFail("\(bad) must be refused, got \(url)")
            case .failure(let error):
                XCTAssertEqual(error, .invalidAddress)
                XCTAssertEqual(error.localizedDescription, "Enter an https:// address")
            }
        }
    }

    func testParsedHostsDropsBlankLinesTrimsLowercasesAndDeduplicates() {
        let hosts = WebEditorPolicy.parsedHosts(from: "Login.Example.com\n\n   cdn.example.com  \nlogin.example.com\n")
        XCTAssertEqual(Set(hosts), ["login.example.com", "cdn.example.com"])
        XCTAssertEqual(hosts.count, 2)
        XCTAssertEqual(WebEditorPolicy.parsedHosts(from: " \n \n"), [])
    }

    func testBadgePatternMapsBlankToNil() {
        XCTAssertNil(WebEditorPolicy.badgePattern(from: ""))
        XCTAssertNil(WebEditorPolicy.badgePattern(from: "  \n"))
        XCTAssertEqual(WebEditorPolicy.badgePattern(from: " \\((\\d+)\\) "), "\\((\\d+)\\)")
    }

    func testBadgeWarningFiresOnlyWhenTheParserFallsBack() {
        XCTAssertNil(WebEditorPolicy.badgeWarning(for: ""))
        XCTAssertNil(WebEditorPolicy.badgeWarning(for: "\\((\\d+)\\)"))
        XCTAssertNil(WebEditorPolicy.badgeWarning(for: "^(\\d+) new$"))
        for bad in ["(", "no capture group", "[a-z"] {
            XCTAssertEqual(
                WebEditorPolicy.badgeWarning(for: bad),
                "That pattern is not valid or has no capture group, so the default \(BadgeTitleParser.defaultPattern) is used.",
                bad
            )
        }
    }

    func testFetchedIconIsOfferedOnlyWhileTheSavedModeIsFetched() {
        XCTAssertEqual(WebEditorPolicy.iconModes(saved: .copied), [.copied, .custom, .generated])
        XCTAssertEqual(WebEditorPolicy.iconModes(saved: .custom), [.custom, .generated])
        XCTAssertEqual(WebEditorPolicy.iconModes(saved: .generated), [.custom, .generated])
        XCTAssertEqual(WebEditorPolicy.iconLabel(.copied), "Fetched from site")
        XCTAssertEqual(WebEditorPolicy.iconLabel(.custom), "Custom file")
        XCTAssertEqual(WebEditorPolicy.iconLabel(.generated), "Generated tile")
    }

    func testZoomLabelIsAWholePercent() {
        XCTAssertEqual(WebEditorPolicy.zoomLabel(1.0), "100%")
        XCTAssertEqual(WebEditorPolicy.zoomLabel(1.25), "125%")
        XCTAssertEqual(WebEditorPolicy.zoomLabel(0.5), "50%")
        XCTAssertEqual(WebEditorPolicy.zoomLabel(1.15), "115%")
    }

    func testRemoveWebDataMessageSaysTheShortcutStays() {
        XCTAssertEqual(
            WebEditorPolicy.removeWebDataMessage(shortcutName: "Chat"),
            "This signs “Chat” out of every site and deletes its cookies, cache and local storage from this Mac. The shortcut stays, and this cannot be undone."
        )
    }

    // MARK: saveConfig

    func testRenameKeepsTheSlugAndBundleIdentifierSoTheStoreIsNotOrphaned() {
        let saved = makeWebShortcutConfig(name: "Chat")
        var draft = saved
        draft.name = "  Chat Work "
        draft.slug = "chat-work"
        draft.bundleIdentifier = "com.mikekuta.appduplicator.chat-work"

        let config = WebEditorPolicy.saveConfig(draft: draft, saved: saved)

        XCTAssertEqual(config.name, "Chat Work")
        XCTAssertEqual(config.slug, "chat")
        XCTAssertEqual(config.bundleIdentifier, "com.mikekuta.appduplicator.chat")
    }

    func testSavePinsTheStoreIdentifierAndTheRememberedZoom() {
        let saved = makeWebShortcutConfig(name: "Chat")
        var draft = saved
        draft.webApp?.dataStoreID = UUID()
        draft.webApp?.pageZoom = 2.0

        let config = WebEditorPolicy.saveConfig(draft: draft, saved: saved)

        XCTAssertEqual(config.webApp?.dataStoreID, saved.webApp?.dataStoreID)
        XCTAssertEqual(config.webApp?.pageZoom, saved.webApp?.pageZoom)
    }

    func testSaveKeepsTheEditedWebFieldsAndNormalizesHosts() {
        let saved = makeWebShortcutConfig(name: "Chat")
        var draft = saved
        draft.webApp?.userAgent = .chrome
        draft.webApp?.badgeRegex = "^(\\d+) new$"
        draft.webApp?.extraHosts = [" Login.Example.com ", "login.example.com"]
        draft.webApp?.url = "https://chat.example.com/next"

        let web = WebEditorPolicy.saveConfig(draft: draft, saved: saved).webApp

        XCTAssertEqual(web?.userAgent, .chrome)
        XCTAssertEqual(web?.badgeRegex, "^(\\d+) new$")
        XCTAssertEqual(web?.extraHosts, ["login.example.com"])
        XCTAssertEqual(web?.url, "https://chat.example.com/next")
    }

    func testBackgroundModeNeedsTheMenuBarIcon() {
        let saved = makeWebShortcutConfig(name: "Chat", menuBarIcon: true, backgroundMode: true)

        var iconOff = saved
        iconOff.menuBarIcon = false
        let cleared = WebEditorPolicy.saveConfig(draft: iconOff, saved: saved)
        XCTAssertFalse(cleared.menuBarIcon)
        XCTAssertEqual(cleared.webApp?.backgroundMode, false, "background mode cannot outlive the menu bar icon")

        let kept = WebEditorPolicy.saveConfig(draft: saved, saved: saved)
        XCTAssertEqual(kept.webApp?.backgroundMode, true)
    }

    func testSaveOfAnUnchangedWebConfigChangesNothingButTheEngineIndependentFields() {
        let saved = makeWebShortcutConfig(name: "Chat", menuBarIcon: true, backgroundMode: true)
        XCTAssertEqual(WebEditorPolicy.saveConfig(draft: saved, saved: saved), saved)
    }
}
```

- [ ] **Step 18: Run to see them fail**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/WebEditorPolicyTests`
Expected: `cannot find 'WebEditorPolicy' in scope`.

- [ ] **Step 19: Implement the policy**

Create `App/Sources/Services/WebEditorPolicy.swift`:

```swift
import DuplicatorCore
import Foundation

/// The editor rules for a web app, kept out of the views so they are unit-tested (Phase 4 skeleton decision 16).
enum WebEditorPolicy {
    /// The address to store (`absoluteString` of the validated URL), or the validator's refusal.
    static func validatedURL(_ text: String) -> Result<String, WebAppURLError> {
        do {
            return .success(try WebAppURLValidator.validate(text).absoluteString)
        } catch let error as WebAppURLError {
            return .failure(error)
        } catch {
            return .failure(.invalidAddress)
        }
    }

    /// One host per line; blank lines dropped; trimmed, lower-cased and de-duplicated by `WebAppConfig.normalizedHosts`.
    static func parsedHosts(from text: String) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return WebAppConfig.normalizedHosts(lines)
    }

    /// A blank field means "use the default pattern", stored as nil.
    static func badgePattern(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Non-nil when the typed pattern would not be used: the shell falls back to the default (`BadgeTitleParser`).
    static func badgeWarning(for text: String) -> String? {
        guard let pattern = badgePattern(from: text), BadgeTitleParser(pattern: pattern).usedFallbackPattern else { return nil }
        return "That pattern is not valid or has no capture group, so the default \(BadgeTitleParser.defaultPattern) is used."
    }

    /// `Fetched from site` is the `.copied` mode, which only a wizard-built icon has: the editor cannot fetch a site icon,
    /// so it is offered only while it is already the saved mode (Task 6 Deviation 4).
    static func iconModes(saved: IconMode) -> [IconMode] {
        saved == .copied ? [.copied, .custom, .generated] : [.custom, .generated]
    }

    static func iconLabel(_ mode: IconMode) -> String {
        switch mode {
        case .copied: "Fetched from site"
        case .custom: "Custom file"
        case .generated: "Generated tile"
        }
    }

    static func zoomLabel(_ zoom: Double) -> String {
        "\(Int((zoom * 100).rounded()))%"
    }

    static func removeWebDataMessage(shortcutName: String) -> String {
        "This signs “\(shortcutName)” out of every site and deletes its cookies, cache and local storage from this Mac. The shortcut stays, and this cannot be undone."
    }

    /// The config Save writes for a web app. It trims the name, keeps the saved slug and bundle identifier (a rename
    /// must not move the shell to a new bundle id, because WebKit files its store under that id), pins the store
    /// identifier and the remembered zoom (neither is editable), normalizes the extra hosts, and drops background mode
    /// when the menu bar icon is off. The editor passes no icon data with it, so `iconMode == .copied` keeps the
    /// bundle's existing `AppIcon.icns` (Task 4's `regenerate`).
    static func saveConfig(draft: ShortcutConfig, saved: ShortcutConfig) -> ShortcutConfig {
        var config = draft
        config.name = draft.name.trimmingCharacters(in: .whitespaces)
        config.slug = saved.slug
        config.bundleIdentifier = saved.bundleIdentifier
        if var web = draft.webApp {
            if let savedWeb = saved.webApp {
                web.dataStoreID = savedWeb.dataStoreID
                web.pageZoom = savedWeb.pageZoom
            }
            web.extraHosts = WebAppConfig.normalizedHosts(web.extraHosts)
            if !config.menuBarIcon { web.backgroundMode = false }
            config.webApp = web
        }
        return config
    }
}
```

- [ ] **Step 20: Run to see them pass**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/WebEditorPolicyTests`
Expected: `Executed 13 tests, with 0 failures`. If `testValidatedURLRefusesAnythingElseWithTheSharedCopy` fails on one input, the Task 1 validator accepts that input: do not loosen the test, report it as an open question (the skeleton says only `https://` addresses pass).

- [ ] **Step 21: Commit**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add App/Sources/Services/WebEditorPolicy.swift App/Tests/Services/WebEditorPolicyTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Add the web app editor rules

Address and host parsing, the icon choices a web app offers, and the config Save writes (rename keeps the bundle identifier, the store id and zoom are pinned, background mode follows the menu bar icon).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 22: Write the coordinator's icon-preservation tests (and rename test)**

Append these members inside `AppStateWebTests` in `App/Tests/App/AppStateWebTests.swift` (before the final `}`):

```swift

    // MARK: Editor Save (coordinator constraint: Save passes no icon data, the fetched icon stays)

    private var iconBytes: Data { Data([1, 2, 3]) }

    private func iconFile(in bundle: URL) -> URL { bundle.appending(path: "Contents/Resources/AppIcon.icns") }

    /// What `ShortcutEditorView.save()` hands `AppState.save` for a web app after the draft is edited.
    private func editorSaveConfig(of record: ShortcutRecord, _ edit: (inout ShortcutConfig) -> Void) -> ShortcutConfig {
        var draft = record.config
        edit(&draft)
        return WebEditorPolicy.saveConfig(draft: draft, saved: record.config)
    }

    func testEditorSaveKeepsTheFetchedIconBytes() async throws {
        let record = try await makeWebRecord()
        XCTAssertEqual(record.config.iconMode, .copied)
        XCTAssertEqual(try Data(contentsOf: iconFile(in: record.bundleURL)), iconBytes, "precondition: the bundle holds the fetched icon")
        let config = editorSaveConfig(of: record) {
            $0.webApp?.userAgent = .chrome
            $0.webApp?.extraHosts = ["login.example.com"]
        }

        let saved = await state.save(record: record, config: config)

        XCTAssertTrue(saved, state.pendingError?.message ?? "")
        let after = try XCTUnwrap(library.record(for: record.bundleURL))
        XCTAssertEqual(after.config.webApp?.userAgent, .chrome)
        XCTAssertEqual(after.config.webApp?.extraHosts, ["login.example.com"])
        XCTAssertEqual(after.config.iconMode, .copied)
        XCTAssertEqual(try Data(contentsOf: iconFile(in: after.bundleURL)), iconBytes, "Save without new icon data must keep AppIcon.icns byte for byte")
    }

    func testEditorRenameKeepsTheBundleIdentifierTheStoreAndTheIconBytes() async throws {
        let id = UUID()
        let record = try await makeWebRecord(dataStoreID: id)
        let config = editorSaveConfig(of: record) { $0.name = "  Chat Work " }

        let saved = await state.save(record: record, config: config)

        XCTAssertTrue(saved, state.pendingError?.message ?? "")
        let renamedBundle = out.appending(path: "Chat Work.app", directoryHint: .isDirectory)
        let after = try XCTUnwrap(library.record(for: renamedBundle))
        XCTAssertEqual(after.config.name, "Chat Work")
        XCTAssertEqual(after.config.slug, "chat")
        XCTAssertEqual(after.config.bundleIdentifier, "com.mikekuta.appduplicator.chat", "the bundle id keys WebKit's store, so a rename must keep it")
        XCTAssertEqual(after.config.webApp?.dataStoreID, id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.bundleURL.path), "the old bundle is replaced")
        XCTAssertEqual(try Data(contentsOf: iconFile(in: renamedBundle)), iconBytes)
    }

    func testEditorSaveNeverTouchesWebData() async throws {
        let record = try await makeWebRecord()
        let config = editorSaveConfig(of: record) { $0.webApp?.userAgent = .chrome }

        _ = await state.save(record: record, config: config)

        XCTAssertTrue(remover.calls.isEmpty, "Save keeps the logins; only Remove Web Data and Delete remove them")
    }
```

- [ ] **Step 23: Run them**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/AppStateWebTests`
Expected: `Executed 11 tests, with 0 failures`. These exercise Task 4's `regenerate` (assumptions A1 and A2). If `testEditorSaveKeepsTheFetchedIconBytes` fails with changed or missing icon bytes, assumption A2 does not hold: stop and report it to the orchestrator (do not work around it by passing icon data from the editor).

- [ ] **Step 24: Create the web app editor section**

Create `App/Sources/Views/WebAppSection.swift`:

```swift
import DuplicatorCore
import SwiftUI

/// The editor's section for a web app (skeleton decision 16): address, user agent, badge pattern, extra hosts, the
/// live menu bar options, the remembered zoom (read-only) and the web data row. It edits the draft only; Save writes
/// it through `WebEditorPolicy.saveConfig`.
struct WebAppSection: View {
    @Environment(AppState.self) private var appState
    @Binding var draft: ShortcutConfig
    /// The saved record: Remove Web Data acts on its store, never on an unsaved draft.
    let record: ShortcutRecord
    /// False while the address field holds something that is not an https address; the editor disables Save then.
    @Binding var urlIsValid: Bool

    @State private var urlText: String
    @State private var urlMessage: String?
    @State private var badgeText: String
    @State private var isRemoveConfirmationPresented = false
    @State private var isRemoving = false
    @State private var didRemove = false

    init(draft: Binding<ShortcutConfig>, record: ShortcutRecord, urlIsValid: Binding<Bool>) {
        _draft = draft
        self.record = record
        _urlIsValid = urlIsValid
        _urlText = State(initialValue: draft.wrappedValue.webApp?.url ?? "")
        _badgeText = State(initialValue: draft.wrappedValue.webApp?.badgeRegex ?? "")
    }

    var body: some View {
        Section("Web App") {
            if let web = Binding($draft.webApp) {
                TextField("Website URL", text: $urlText, prompt: Text("https://example.com"))
                    .onChange(of: urlText) { _, text in applyURL(text) }
                if let urlMessage {
                    Label(urlMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                Picker("User agent", selection: web.userAgent) {
                    Text("Safari").tag(UserAgentPreset.safari)
                    Text("Chrome").tag(UserAgentPreset.chrome)
                }
                TextField("Badge pattern", text: $badgeText, prompt: Text(BadgeTitleParser.defaultPattern))
                    .font(.body.monospaced())
                    .onChange(of: badgeText) { _, text in
                        let pattern = WebEditorPolicy.badgePattern(from: text)
                        if draft.webApp?.badgeRegex != pattern { draft.webApp?.badgeRegex = pattern }
                    }
                if let warning = WebEditorPolicy.badgeWarning(for: badgeText) {
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                } else {
                    caption("The first capture group of this pattern is read from the page title as the unread count. Leave blank for the default.")
                }
                LabeledContent("Also open in app") { HostsEditor(hosts: web.extraHosts) }
                caption("One host per line. Links to these hosts, and their subdomains, open inside the web app instead of your browser.")

                Toggle("Menu bar icon", isOn: $draft.menuBarIcon)
                    .onChange(of: draft.menuBarIcon) { _, isOn in
                        if !isOn, draft.webApp?.backgroundMode == true { draft.webApp?.backgroundMode = false }
                    }
                caption("Active for web apps: the icon appears the next time the web app starts.")
                Toggle("Keep running in the menu bar when the window closes", isOn: web.backgroundMode)
                    .disabled(!draft.menuBarIcon)
                if !draft.menuBarIcon { caption("Turn on the menu bar icon first") }

                LabeledContent("Zoom") {
                    Text(WebEditorPolicy.zoomLabel(web.wrappedValue.pageZoom)).foregroundStyle(.secondary)
                }
                caption("Read-only. The web app remembers the zoom you set inside it.")

                LabeledContent("Web data") {
                    Text(web.wrappedValue.dataStoreID.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                }
                HStack {
                    Button("Remove Web Data…") { isRemoveConfirmationPresented = true }.disabled(isRemoving)
                    if didRemove { Label("Web data removed", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
                }
                caption("Logins, cookies, cache and local storage for this web app. Save never changes them.")
            }
        }
        .onChange(of: draft.webApp?.url) { _, newURL in
            // The draft changed from outside (Save adopting the written config): show it unless the field already says it.
            guard let newURL else { return }
            switch WebEditorPolicy.validatedURL(urlText) {
            case .success(let current) where current == newURL: break
            default:
                urlText = newURL
                urlMessage = nil
                urlIsValid = true
            }
        }
        .onChange(of: draft.webApp?.badgeRegex) { _, newPattern in
            if WebEditorPolicy.badgePattern(from: badgeText) != newPattern { badgeText = newPattern ?? "" }
        }
        .confirmationDialog(
            "Remove web data for “\(record.name)”?",
            isPresented: $isRemoveConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Remove Web Data", role: .destructive) { removeWebData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(WebEditorPolicy.removeWebDataMessage(shortcutName: record.name))
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func applyURL(_ text: String) {
        switch WebEditorPolicy.validatedURL(text) {
        case .success(let url):
            urlMessage = nil
            urlIsValid = true
            if draft.webApp?.url != url { draft.webApp?.url = url }
        case .failure(let error):
            urlMessage = error.localizedDescription
            urlIsValid = false
        }
    }

    private func removeWebData() {
        isRemoving = true
        didRemove = false
        Task {
            didRemove = await appState.removeWebData(for: record)
            isRemoving = false
        }
    }
}

/// One host per line, blank lines dropped. Same local-text pattern as `ArgumentsEditor`: the typed text is kept so Return
/// can open a new line, and rebuilt from `hosts` only when they change from outside (Revert).
struct HostsEditor: View {
    @Binding var hosts: [String]
    @State private var text: String

    init(hosts: Binding<[String]>) {
        _hosts = hosts
        _text = State(initialValue: hosts.wrappedValue.joined(separator: "\n"))
    }

    var body: some View {
        TextEditor(text: $text)
            .font(.body.monospaced())
            .frame(minHeight: 60)
            .help("One host per line, for example accounts.example.com")
            .onChange(of: text) { _, newText in
                let parsed = WebEditorPolicy.parsedHosts(from: newText)
                if parsed != hosts { hosts = parsed }
            }
            .onChange(of: hosts) { _, newHosts in
                if WebEditorPolicy.parsedHosts(from: text) != newHosts { text = newHosts.joined(separator: "\n") }
            }
    }
}
```

- [ ] **Step 25: Offer the web icon choices in `IdentitySection`**

In `App/Sources/Views/EditorSections.swift` (`IdentitySection`, lines 15-19) replace

```swift
            Picker("Icon", selection: $draft.iconMode) {
                Text("Copied from target").tag(IconMode.copied)
                Text("Custom file").tag(IconMode.custom)
                Text("Generated tile").tag(IconMode.generated)
            }
```

with

```swift
            Picker("Icon", selection: $draft.iconMode) {
                if draft.kind == .webApp {
                    // "Fetched from site" only while it is the saved mode: the editor cannot refetch an icon.
                    ForEach(WebEditorPolicy.iconModes(saved: record.config.iconMode), id: \.self) { mode in
                        Text(WebEditorPolicy.iconLabel(mode)).tag(mode)
                    }
                } else {
                    Text("Copied from target").tag(IconMode.copied)
                    Text("Custom file").tag(IconMode.custom)
                    Text("Generated tile").tag(IconMode.generated)
                }
            }
```

`AdvancedSection` stays as is: web apps never show it, so its `Menu bar icon ... Coming in Phase 6` hint and the `Stored now; takes effect in Phase 6` caption remain for `.app` shortcuts only.

- [ ] **Step 26: Wire the web layout, Save and Revert into `ShortcutEditorView`**

In `App/Sources/Views/ShortcutEditorView.swift` make these replacements.

1. After `@State private var isDiagnosticsPresented = false` add:

```swift
    /// False while the web address field holds something that is not an https address (Save is disabled then).
    @State private var webURLIsValid = true
    /// Bumped by Revert so the web section rebuilds its local text fields from the restored draft.
    @State private var revertCount = 0
```

2. After `private var hasChanges: Bool { draft != record.config }` add:

```swift

    private var isWebApp: Bool { record.config.kind == .webApp }
```

3. Replace the four sections after `IdentitySection(...)`

```swift
            TargetSection(draft: $draft, inspected: inspected, profile: profile)
            ProfileSection(bundleIdentifier: draft.targetBundleIdentifier, profile: profile, detectedFamily: inspected?.family)
            LaunchSection(draft: $draft, record: record, inspected: inspected)
            AdvancedSection(draft: $draft)
```

with

```swift
            if isWebApp {
                // A web app has no target, profile, launch mode or data folder; its options live in one section.
                WebAppSection(draft: $draft, record: record, urlIsValid: $webURLIsValid).id(revertCount)
            } else {
                TargetSection(draft: $draft, inspected: inspected, profile: profile)
                ProfileSection(bundleIdentifier: draft.targetBundleIdentifier, profile: profile, detectedFamily: inspected?.family)
                LaunchSection(draft: $draft, record: record, inspected: inspected)
                AdvancedSection(draft: $draft)
            }
```

4. Replace the Revert and Save buttons

```swift
                Button("Revert") { draft = record.config }.disabled(!hasChanges || isSaving)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges || isSaving || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
```

with

```swift
                Button("Revert") {
                    draft = record.config
                    webURLIsValid = true
                    revertCount += 1
                }
                .disabled(!(hasChanges || !webURLIsValid) || isSaving)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges || isSaving || !webURLIsValid || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
```

5. In the `.task(id: draft.targetPath) {` closure insert as its first statement (before the comment line):

```swift
            guard !isWebApp else {
                inspected = nil
                return
            }
```

6. In `save()` replace

```swift
        var config = draft
        config.name = config.name.trimmingCharacters(in: .whitespaces)
        if config.name != record.config.name {
            // Final review M6: a rename steps around the slugs the other shortcuts use (this one's own stays free).
            config.slug = SlugAllocator.uniqueSlug(proposed: ShortcutConfig.slug(for: config.name),
                                                   taken: SlugAllocator.takenSlugs(in: appState.library.records, excluding: record.bundleURL))
            config.bundleIdentifier = ShortcutConfig.bundleIdentifier(forSlug: config.slug)
        }
```

with

```swift
        var config = draft
        if isWebApp {
            // The slug and bundle identifier stay on a rename (WebKit files the logins under the bundle id), and no icon
            // data is passed, so `regenerate` keeps the bundle's AppIcon.icns for `.copied` (Task 6 Deviation 2, A2).
            config = WebEditorPolicy.saveConfig(draft: draft, saved: record.config)
        } else {
            config.name = config.name.trimmingCharacters(in: .whitespaces)
            if config.name != record.config.name {
                // Final review M6: a rename steps around the slugs the other shortcuts use (this one's own stays free).
                config.slug = SlugAllocator.uniqueSlug(proposed: ShortcutConfig.slug(for: config.name),
                                                       taken: SlugAllocator.takenSlugs(in: appState.library.records, excluding: record.bundleURL))
                config.bundleIdentifier = ShortcutConfig.bundleIdentifier(forSlug: config.slug)
            }
        }
```

- [ ] **Step 27: Compile and run the editor-adjacent tests**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/WebEditorPolicyTests -only-testing:MacAppDuplicatorTests/AppStateWebTests -only-testing:MacAppDuplicatorTests/AppStateTests`
Expected: `0 failures`; the app target compiles with `WebAppSection`, `HostsEditor` and the editor wiring (`Tools/test-app.sh` builds the whole app target, so a view compile error fails here). The views have no unit tests; their logic lives in `WebEditorPolicy` and `AppState`, and acceptance Steps 7 and 8 exercise them.

- [ ] **Step 28: Commit**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add App/Sources/Views/WebAppSection.swift App/Sources/Views/EditorSections.swift App/Sources/Views/ShortcutEditorView.swift App/Tests/App/AppStateWebTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Edit web apps in the shortcut editor

A Web App section edits the address, user agent, badge pattern, extra hosts and menu bar options, shows the zoom and web data id read-only, and offers Remove Web Data. Save keeps the bundle identifier and the fetched icon.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Sub-task E: Diagnostics for web apps

`DiagnosticsModel.make` resolves a target and previews a launch plan; both are meaningless for a web app (`targetPath` is `""`, there is no launcher plan), so today a web record would show `Launch plan error: ... not found`. This sub-task gives web records their own model and report. The non-web output is unchanged byte for byte (the existing tests in `DiagnosticsModelTests` stay as they are).

- [ ] **Step 29: Write the failing diagnostics tests**

Append inside `final class DiagnosticsModelTests` in `App/Tests/App/DiagnosticsModelTests.swift` (before the final `}`):

```swift
    // MARK: Phase 4 web apps

    func testWebAppModelShowsTheRedactedAddressAndNoTargetPlan() throws {
        let storeID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        var config = makeWebShortcutConfig(
            name: "Chat Inbox", url: "https://chat.example.com/inbox?token=abc#top", dataStoreID: storeID,
            menuBarIcon: true, backgroundMode: true)
        config.webApp?.userAgent = .chrome
        config.webApp?.extraHosts = ["login.example.com"]
        let bundle = try writeShortcutBundle(named: "Chat Inbox", in: dir, config: config)
        let record = try LibraryScanner.record(forBundleAt: bundle, fileManager: .default)
        let logs = dir.appending(path: "logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "started\nbadge=3\n".write(to: logs.appending(path: "Chat Inbox.log"), atomically: true, encoding: .utf8)

        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: logs))

        XCTAssertNil(model.planError, "a web app has no launch plan to fail")
        XCTAssertEqual(model.launchMode, "Web Shell")
        XCTAssertNil(model.resolvedTargetPath)
        XCTAssertEqual(model.logLines, ["started", "badge=3"])
        let web = try XCTUnwrap(model.web)
        XCTAssertEqual(web.url, "https://chat.example.com/inbox", "query and fragment are dropped: the report gets pasted into tickets")
        XCTAssertEqual(web.userAgent, "Chrome")
        XCTAssertEqual(web.dataStoreID, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(web.backgroundMode, "On")
        XCTAssertEqual(web.menuBarIcon, "On")
        XCTAssertEqual(web.badgePattern, "\(BadgeTitleParser.defaultPattern) (default)")
        XCTAssertEqual(web.extraHosts, ["login.example.com"])
        XCTAssertEqual(web.zoom, "100%")

        let report = model.reportText
        XCTAssertTrue(report.contains("URL: https://chat.example.com/inbox\n"))
        XCTAssertTrue(report.contains("User agent: Chrome"))
        XCTAssertTrue(report.contains("Data store id: 11111111-2222-3333-4444-555555555555"))
        XCTAssertTrue(report.contains("Also open in app: login.example.com"))
        XCTAssertTrue(report.contains("Recent log (last 2 lines):\nstarted\nbadge=3"))
        XCTAssertFalse(report.contains("token=abc"), "the address query must not reach the report")
        XCTAssertFalse(report.contains("Target:"))
        XCTAssertFalse(report.contains("Arguments:"))
        XCTAssertFalse(report.contains("Launch plan error"))
    }

    func testWebAppBadgePatternTextSaysWhichPatternIsInUse() throws {
        var config = makeWebShortcutConfig(name: "Chat Badge")
        config.webApp?.badgeRegex = #"\[(\d+)\]"#
        let good = try LibraryScanner.record(forBundleAt: writeShortcutBundle(named: "Chat Badge", in: dir, config: config), fileManager: .default)
        XCTAssertEqual(DiagnosticsModel.make(record: good, logReader: LogReader(folder: dir)).web?.badgePattern, #"\[(\d+)\]"#)

        // Written to a second folder so both bundles can be called "Chat Badge".
        let other = dir.appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        config.webApp?.badgeRegex = "("
        let bad = try LibraryScanner.record(forBundleAt: writeShortcutBundle(named: "Chat Badge", in: other, config: config), fileManager: .default)
        XCTAssertEqual(
            DiagnosticsModel.make(record: bad, logReader: LogReader(folder: dir)).web?.badgePattern,
            "\(BadgeTitleParser.defaultPattern) (the saved pattern is invalid; the default is used)")
    }

    func testRedactedURLDropsCredentialsQueryAndFragment() {
        XCTAssertEqual(
            DiagnosticsModel.redactedURL("https://user:secret@chat.example.com:8443/inbox/?token=abc#top"),
            "https://chat.example.com:8443/inbox/")
        XCTAssertEqual(DiagnosticsModel.redactedURL("https://chat.example.com"), "https://chat.example.com")
        XCTAssertEqual(DiagnosticsModel.redactedURL("not a url"), "(unreadable address)")
    }

    func testWebAppWithoutSettingsReportsAPlanErrorInsteadOfCrashing() throws {
        var config = makeWebShortcutConfig(name: "Chat Broken")
        config.webApp = nil
        let record = ShortcutRecord(
            bundleURL: dir.appending(path: "Chat Broken.app"), config: config, engineVersion: ShortcutConfig.currentEngineVersion,
            iconURL: nil, targetVersion: nil, targetExists: true, modifiedDate: Date())
        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: dir))
        XCTAssertNil(model.web)
        XCTAssertEqual(model.planError, "This web app has no web address saved. Regenerate the shortcut or recreate it.")
        XCTAssertTrue(model.reportText.contains("Launch plan error: This web app has no web address saved."))
    }
```

- [ ] **Step 30: Run to see them fail**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/DiagnosticsModelTests`
Expected: build failure, `value of type 'DiagnosticsModel' has no member 'web'` and `type 'DiagnosticsModel' has no member 'redactedURL'`.

- [ ] **Step 31: Implement the web model, report and rows**

All edits are in `App/Sources/Views/DiagnosticsView.swift`.

(a) Add `import Foundation` is not needed (SwiftUI imports it). Add the nested type and the new stored property. Replace the line `    let planError: String?` (line 24, the last stored property) with:

```swift
    let planError: String?
    /// Set for a web app: the facts the report shows instead of a target and a launch plan (nil for every other kind).
    /// The last stored property, with a default, so the two existing memberwise calls below stay as they are.
    var web: WebDetails?

    /// What a web app's Diagnostics shows. Every value is display text, so the view and the report share it.
    struct WebDetails: Equatable {
        /// The saved address with credentials, query and fragment removed (`redactedURL`).
        let url: String
        let userAgent: String
        /// `WebAppConfig.dataStoreID.uuidString`: the WebKit store name under `~/Library/WebKit/<bundle id>/WebsiteDataStore`.
        let dataStoreID: String
        /// `On` only when background mode is saved and the menu bar icon is on (the shell ignores it otherwise).
        let backgroundMode: String
        let menuBarIcon: String
        let badgePattern: String
        let extraHosts: [String]
        let zoom: String
    }
```

(b) Insert the web branch at the top of `make`. Replace these two lines (the start of the function body):

```swift
        let logLines = logReader.tail(name: record.name).map(SecretMasking.maskLogLine)
        let profile = profileCatalog.profile(forBundleIdentifier: record.config.targetBundleIdentifier)
```

with:

```swift
        let logLines = logReader.tail(name: record.name).map(SecretMasking.maskLogLine)
        if record.config.kind == .webApp {
            return makeWeb(record: record, logLines: logLines)
        }
        let profile = profileCatalog.profile(forBundleIdentifier: record.config.targetBundleIdentifier)
```

(c) Add these members directly after `make` (before `private static func failed`):

```swift
    /// A web app has no target, profile or launch plan; the model carries its web settings instead.
    private static func makeWeb(record: ShortcutRecord, logLines: [String]) -> DiagnosticsModel {
        let config = record.config
        var model = DiagnosticsModel(
            shortcutName: record.name,
            bundlePath: record.bundleURL.path,
            engineVersion: record.engineVersion,
            profileMatch: "Not applicable (web app)",
            profileRows: [],
            storedTargetPath: "",
            resolvedTargetPath: nil,
            executablePath: "",
            launchMode: "Web Shell",
            arguments: [],
            environment: [],
            warnings: [],
            logLines: logLines,
            planError: config.webApp == nil ? "This web app has no web address saved. Regenerate the shortcut or recreate it." : nil
        )
        if let web = config.webApp {
            model.web = WebDetails(
                url: redactedURL(web.url),
                userAgent: web.userAgent == .chrome ? "Chrome" : "Safari",
                dataStoreID: web.dataStoreID.uuidString,
                backgroundMode: web.backgroundMode && config.menuBarIcon ? "On" : (web.backgroundMode ? "Off (needs the menu bar icon)" : "Off"),
                menuBarIcon: config.menuBarIcon ? "On" : "Off",
                badgePattern: badgePatternText(web.badgeRegex),
                extraHosts: web.extraHosts,
                zoom: WebEditorPolicy.zoomLabel(web.pageZoom)
            )
        }
        return model
    }

    /// `address` without credentials, query and fragment: the report is meant to be pasted into tickets (Deviation 5).
    static func redactedURL(_ address: String) -> String {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme != nil, components.host != nil else { return "(unreadable address)" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "(unreadable address)"
    }

    /// The pattern the shell really matches titles with, and why when it is not the saved one.
    static func badgePatternText(_ configured: String?) -> String {
        let parser = BadgeTitleParser(pattern: configured)
        guard configured != nil else { return "\(parser.pattern) (default)" }
        return parser.usedFallbackPattern ? "\(parser.pattern) (the saved pattern is invalid; the default is used)" : parser.pattern
    }
```

(d) Replace the whole `var reportText: String { ... }` property with the version below. The non-web path is the old body moved into the `else`, with identical lines in identical order.

```swift
    var reportText: String {
        var lines: [String] = []
        lines.append("App Duplicator diagnostics — \(shortcutName)")
        lines.append("Bundle: \(bundlePath)")
        lines.append("Engine version: \(engineVersion) (current \(ShortcutConfig.currentEngineVersion))")
        if let web {
            lines.append("Kind: Web app")
            lines.append("URL: \(web.url)")
            lines.append("User agent: \(web.userAgent)")
            lines.append("Data store id: \(web.dataStoreID)")
            lines.append("Background: \(web.backgroundMode)")
            lines.append("Menu bar icon: \(web.menuBarIcon)")
            lines.append("Badge pattern: \(web.badgePattern)")
            lines.append("Also open in app: \(web.extraHosts.isEmpty ? "none" : web.extraHosts.joined(separator: ", "))")
            lines.append("Zoom: \(web.zoom)")
        } else {
            lines.append("Profile: \(profileMatch)")
            lines.append(contentsOf: profileRows.map { "  \($0.label): \($0.value)" })
            lines.append("Target: \(resolvedTargetPath ?? "not found")")
            if storedPathDiffers {
                lines.append("Stored target path: \(storedTargetPath)")
            }
        }
        if let planError {
            lines.append("Launch plan error: \(planError)")
        } else if web == nil {
            lines.append("Executable: \(executablePath)")
            lines.append("Launch mode: \(launchMode)")
            lines.append("")
            lines.append("Arguments:")
            lines.append(contentsOf: arguments.map { "  \($0)" })
            lines.append("")
            lines.append("Environment:")
            lines.append(contentsOf: environment.map { "  \($0.key)=\($0.value)" })
            if !warnings.isEmpty {
                lines.append("")
                lines.append("Warnings:")
                lines.append(contentsOf: warnings.map { "  \($0)" })
            }
        }
        lines.append("")
        lines.append("Recent log (last \(logLines.count) lines):")
        lines.append(contentsOf: logLines)
        return lines.joined(separator: "\n")
    }
```

(e) The view. Replace the `section("Shortcut") { ... }` block (from `section("Shortcut") {` through its closing `}` just above `if !model.profileRows.isEmpty {`) with:

```swift
                        section("Shortcut") {
                            row("Bundle", model.bundlePath)
                            row("Engine", "\(model.engineVersion) (current \(ShortcutConfig.currentEngineVersion))")
                            if let web = model.web {
                                row("Kind", "Web app")
                                row("URL", web.url)
                                row("User agent", web.userAgent)
                                row("Data store", web.dataStoreID)
                                row("Background", web.backgroundMode)
                                row("Menu bar icon", web.menuBarIcon)
                                row("Badge pattern", web.badgePattern)
                                row("Also open", web.extraHosts.isEmpty ? "None" : web.extraHosts.joined(separator: ", "))
                                row("Zoom", web.zoom)
                            } else {
                                row("Profile", model.profileMatch)
                                row("Target", model.resolvedTargetPath ?? "Not found")
                                if model.storedPathDiffers {
                                    row("Stored path", model.storedTargetPath)
                                }
                            }
                            if let error = model.planError {
                                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
                            } else if model.web == nil {
                                row("Executable", model.executablePath)
                                row("Launch mode", model.launchMode)
                            }
                        }
```

and change the guard on the Arguments / Environment / Warnings group from `if model.planError == nil {` to `if model.planError == nil, model.web == nil {`.

`row` labels are right-aligned in a 90 pt column, so change `.frame(width: 90, alignment: .trailing)` in `row` to `.frame(width: 100, alignment: .trailing)` (`Menu bar icon` and `Badge pattern` need the room).


- [ ] **Step 32: Run to see them pass**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/DiagnosticsModelTests`
Expected: `0 failures`, including every pre-existing `DiagnosticsModelTests` test (the non-web report is unchanged).

- [ ] **Step 33: Commit**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add App/Sources/Views/DiagnosticsView.swift App/Tests/App/DiagnosticsModelTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Show web app facts in Diagnostics

A web app has no target or launch plan, so Diagnostics lists its address (credentials, query and fragment removed), user agent, web data id, background and menu bar state, badge pattern, extra hosts and zoom, and the shell's log tail.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Sub-task F: Four web Known Limitations

- [ ] **Step 34: Write the failing limitation tests**

In `App/Tests/App/KnownLimitationsTests.swift` replace the two-line comment above `testCoversEverySpecSection11Topic`:

```swift
    /// Spec §11 is "documented in-app and README": one entry per §11 bullet, each stating that bullet's point.
    /// The web-shell bullet (no passkeys) waits for the web shell phase.
```

with:

```swift
    /// Spec §11 is "documented in-app and README": one entry per §11 bullet, each stating that bullet's point.
    /// The web-shell bullet (no passkeys) is `web-no-passkeys`, asserted in `testPhase4WebEntriesStateTheirPoint`.
```

Append before the final `}` of the class:

```swift
    /// Phase 4 (web apps): the four web limits are present with their prescribed ids and titles, the earlier 20 are
    /// kept (24 in all), ids stay unique, and each entry states its point.
    func testPhase4WebEntriesStateTheirPoint() throws {
        let ids = KnownLimitations.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate known-limitation ids")
        XCTAssertEqual(ids.count, 24, "20 earlier entries plus the four web entries")
        let topics: [(id: String, title: String, mentions: [String])] = [
            ("web-no-passkeys", "Web apps do not support passkeys", ["passkey", "WebAuthn"]),
            ("web-zoom-storage", "Web app zoom is remembered outside the shortcut", ["MADPageZoom", "sealed", "preferences"]),
            ("web-notification-permission", "Web notifications are always allowed, but macOS decides whether they appear",
             ["System Settings", "granted", "reload"]),
            ("web-popup-policy", "Web apps open other sites in your browser", ["Also open in app", "pop-up", "mailto:"]),
        ]
        let byID = Dictionary(KnownLimitations.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for topic in topics {
            let entry = try XCTUnwrap(byID[topic.id], "no entry \(topic.id)")
            XCTAssertEqual(entry.title, topic.title)
            for phrase in topic.mentions {
                XCTAssertTrue("\(entry.title) \(entry.detail)".contains(phrase), "\(topic.id) does not mention \"\(phrase)\"")
            }
        }
    }
```

- [ ] **Step 35: Run to see it fail**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/KnownLimitationsTests`
Expected: `testPhase4WebEntriesStateTheirPoint` fails with `XCTAssertEqual failed: ("20") is not equal to ("24")` and `no entry web-no-passkeys`; the other tests in the class pass.

- [ ] **Step 36: Add the entries**

In `App/Sources/App/KnownLimitations.swift` replace the last three lines of the doc comment above `enum KnownLimitations`:

```swift
/// profiles, manual updates from one host, sandboxed badges, numbered slugs, export's Trash replacement). The web-shell
/// bullet (no passkeys) arrives with the web shell phase. Shown in the Known Limitations window and linked from the
/// wizard's compatibility line.
```

with:

```swift
/// profiles, manual updates from one host, sandboxed badges, numbered slugs, export's Trash replacement). Phase 4 adds
/// the four web app limits (passkeys, zoom storage, notification permission, pop-up and off-site links). Shown in the
/// Known Limitations window and linked from the wizard's compatibility line.
```

Then replace the last entry's closing and the array end. The file currently ends:

```swift
            detail: "When the export destination already holds a bundle with the same name, App Duplicator moves that bundle to the Trash and writes the exported copy in its place; nothing is deleted outright. If you exported over the wrong bundle, put it back from the Trash."
        ),
    ]
}
```

Replace it with:

```swift
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
            detail: "A web app tells every site that notification permission is granted, so sites never show their own permission prompt. Whether a banner actually appears is up to macOS: the first notification asks for permission for that shortcut, and you change it later in System Settings > Notifications. A site that checked permission before you allowed it in System Settings keeps its answer until you reload the page."
        ),
        KnownLimitation(
            id: "web-popup-policy",
            title: "Web apps open other sites in your browser",
            detail: "A web app keeps links to its own site and to the hosts listed under Also open in app inside the window. A link to any other site opens in your default browser instead, and so do mailto: and other non-web links. Pop-up windows a site opens itself (for example a sign-in window) stay inside the web app so the sign-in can finish. If a site's sign-in or links jump out to the browser, add the hosts it uses to Also open in app."
        ),
    ]
}
```

- [ ] **Step 37: Run to see them pass**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/KnownLimitationsTests`
Expected: `0 failures` (24 entries; the Phase 2 and Phase 3 tests still pass).

- [ ] **Step 38: Commit**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add App/Sources/App/KnownLimitations.swift App/Tests/App/KnownLimitationsTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Document the four web app limitations

Adds no passkeys, zoom kept in the shell's preferences, notification permission decided by macOS, and the off-site link and pop-up policy to Help > Known Limitations (24 entries).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Sub-task G: Web apps skip the target resolver; no compatibility badge for web apps

Coordinator items from Task 4's final plan. What the walk of the code found (line numbers as read while planning, before Tasks 4 and 5 merge):

- `ShortcutBuilder.export` (`ShortcutBuilder.swift:152-155`), `ShortcutBuilder.delete` (`:164-185`, resolver call at `:173`) and `AppState.exportCopy` (`AppState.swift:179-190`, resolver call at `:182`) all reach `TargetResolver` through one function: `TargetResolver.resolvedPath(for config:)` in `App/Sources/Services/TargetResolver+ResolvedPath.swift:19`.
- Today that function already returns nil for a web config, but only by accident: its two-argument overload starts with `guard !targetBundleIdentifier.isEmpty else { return nil }`, and a web config has an empty bundle id (decision 4). A web config that somehow carries a bundle id (a hand-edited plist) would make `export` run a Launch Services lookup and refuse destinations near whatever app that id names.
- `delete` only reaches the resolver when `removeData && dataMode != .disabled`; a web config is `dataMode == .disabled`, so delete never calls it. `exportCopy` already ignores empty `targetPath` values (`where targetPath.hasPrefix("/")`, `:98` and `:105`), so `otherTargetPaths` holding the web records' `""` is safe.
- So the whole short-circuit is one guard in `resolvedPath(for:)`. All three call sites stay as they are and are covered by it. The tests below pin the behaviour so a later change cannot regress it.

- [ ] **Step 39: Write the failing tests**

(a) Create `App/Tests/Services/ShortcutBuilderWebTests.swift`:

```swift
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

/// Web apps have no target app: export and delete must work from the bundle alone (coordinator item from Task 4).
final class ShortcutBuilderWebTests: XCTestCase {
    private var dir: URL!
    private var builder: ShortcutBuilder!

    override func setUpWithError() throws {
        dir = try makeAppTemporaryDirectory()
        let launcher = dir.appending(path: "Launcher")
        let webShell = dir.appending(path: "WebShell")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: launcher)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: webShell)
        builder = ShortcutBuilder(launcherBinary: launcher, webShellBinary: webShell, signingIdentity: nil)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    /// A scanned web-app record whose bundle sits in `folder` (Task 4 assumption A3: the scanner accepts it).
    private func webRecord(name: String = "Chat", in folder: URL, targetBundleIdentifier: String = "") throws -> ShortcutRecord {
        var config = makeWebShortcutConfig(name: name)
        config.targetBundleIdentifier = targetBundleIdentifier
        let bundle = try writeShortcutBundle(named: name, in: folder, config: config)
        return try LibraryScanner.record(forBundleAt: bundle)
    }

    func testResolvedPathIsNilForAWebAppEvenWithAStrayBundleIdentifier() {
        var web = makeWebShortcutConfig()
        XCTAssertNil(TargetResolver().resolvedPath(for: web))
        // A hand-edited plist could leave a bundle id behind; Finder is installed on every Mac, so a Launch Services
        // lookup would find it. A web app has no target to find.
        web.targetBundleIdentifier = "com.apple.finder"
        XCTAssertNil(TargetResolver().resolvedPath(for: web))

        var app = makeConfig(name: "Finder Copy", targetPath: "/nonexistent/Finder.app")
        app.targetBundleIdentifier = "com.apple.finder"
        XCTAssertNotNil(TargetResolver().resolvedPath(for: app), "app shortcuts keep resolving through Launch Services")
    }

    func testExportCopiesAWebBundleWithoutATarget() throws {
        let record = try webRecord(in: dir)
        let destination = dir.appending(path: "Chat Export.app")

        let exported = try builder.export(record: record, to: destination, otherTargetPaths: ["", "/Applications/Other.app"])

        XCTAssertEqual(exported, destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appending(path: "Contents/Info.plist").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.bundleURL.path), "export copies; the original stays")
    }

    func testExportOfAWebBundleStillRefusesItsOwnBundle() throws {
        let record = try webRecord(in: dir)
        XCTAssertThrowsError(try builder.export(record: record, to: record.bundleURL.appending(path: "Contents/Inner.app"))) { error in
            guard case ShortcutBuilder.BuilderError.exportOverlapsShortcut = error else { return XCTFail("\(error)") }
        }
    }

    func testDeleteTrashesAWebBundleWhetherOrNotDataRemovalIsAsked() throws {
        let keep = try webRecord(name: "Chat Keep", in: dir)
        let trashedKeep = try builder.delete(record: keep, removeData: false)
        addTeardownBlock { for url in trashedKeep { try FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(trashedKeep.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keep.bundleURL.path))

        // A web app has no data folder (dataMode .disabled, dataPath nil): asking for it trashes the bundle only and the
        // data-path guard is never consulted, so no target lookup happens either.
        let remove = try webRecord(name: "Chat Remove", in: dir)
        let trashedRemove = try builder.delete(record: remove, removeData: true)
        addTeardownBlock { for url in trashedRemove { try FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(trashedRemove.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remove.bundleURL.path))
    }
}
```

(b) Append inside `final class CompatBadgeTests` in `App/Tests/Services/CompatBadgeTests.swift` (before the final `}`):

```swift
    /// A web app has no target app, so there is nothing to badge (skeleton decision 14).
    func testBadgeIsShownOnlyForShortcutsThatHaveATarget() {
        XCTAssertTrue(CompatBadge.isShown(for: .app))
        XCTAssertFalse(CompatBadge.isShown(for: .webApp))
    }
```

(c) Append inside `final class AppStateWebTests` (before the final `}`), the AppState side of export:

```swift
    func testExportCopyOfAWebAppNeedsNoTargetAndIgnoresOtherWebRecordsEmptyTargets() async throws {
        let record = try await makeWebRecord(name: "Chat")
        _ = try await makeWebRecord(name: "Chat Other")
        let destination = dir.appending(path: "Chat Export.app")

        let outcome = await state.exportCopy(record, to: destination)

        XCTAssertEqual(outcome?.exportedURL, destination)
        XCTAssertNil(state.pendingError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appending(path: "Contents/Info.plist").path))
    }
```

- [ ] **Step 40: Run to see them fail**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/ShortcutBuilderWebTests -only-testing:MacAppDuplicatorTests/CompatBadgeTests -only-testing:MacAppDuplicatorTests/AppStateWebTests`
Expected: build failure `type 'CompatBadge' has no member 'isShown'`. After Step 41(a) alone, `testResolvedPathIsNilForAWebAppEvenWithAStrayBundleIdentifier` is the test that fails without the resolver guard (`XCTAssertNil failed: "/System/Library/CoreServices/Finder.app"`); the export, delete and AppState tests pass either way, because they pin behaviour that already holds by accident (see the walk above).

- [ ] **Step 41: Implement the short-circuit and the pure helper**

(a) In `App/Sources/Services/TargetResolver+ResolvedPath.swift` replace the final function:

```swift
    func resolvedPath(for config: ShortcutConfig) -> String? {
        resolvedPath(targetPath: config.targetPath, targetBundleIdentifier: config.targetBundleIdentifier)
    }
```

with:

```swift
    func resolvedPath(for config: ShortcutConfig) -> String? {
        // A web app has no target app (its targetPath and targetBundleIdentifier are empty): export, delete and the
        // data-path guard must never go looking for one, whatever a hand-edited plist left in the bundle id.
        guard config.kind != .webApp else { return nil }
        return resolvedPath(targetPath: config.targetPath, targetBundleIdentifier: config.targetBundleIdentifier)
    }
```

(b) In `App/Sources/Services/CompatBadge.swift` add inside `enum CompatBadge`, directly after `var label: String { rawValue }`:

```swift

    /// Whether a shortcut of `kind` shows a compatibility badge. A web app has no target app to rate (skeleton
    /// decision 14); every kind that runs another app keeps its badge.
    static func isShown(for kind: ShortcutKind) -> Bool { kind != .webApp }
```

- [ ] **Step 42: Guard the three call sites**

Task 5's wizard rewrite shifts the `WizardSteps.swift` line numbers, so find each site by text, not by line. Run `cd /Users/cubbieblue16/Developer/MacAppDuplicator && grep -n "CompatBadge" App/Sources/Views/EditorSections.swift App/Sources/Views/Wizard/WizardSteps.swift`. Expected, before the edit: one hit in `EditorSections.swift` (about line 65) and two in `WizardSteps.swift` (about lines 69 and 231, or 240-ish after Task 5). Apply all three edits with this script (it asserts each pattern occurs exactly once, so a changed layout stops it instead of editing the wrong place):

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && python3 - <<'EOF'
import re

def patch(path, old, new):
    text = open(path).read()
    assert text.count(old) == 1, f"{path}: expected exactly one match for {old!r}, found {text.count(old)}"
    open(path, "w").write(text.replace(old, new))

# 1. Editor: TargetSection's Compatibility row (never reached for a web app because the editor hides TargetSection, Step 26).
patch("App/Sources/Views/EditorSections.swift",
"""            LabeledContent("Compatibility") {
                Text(CompatBadge.badge(for: inspected, profile: profile).label)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
""",
"""            if CompatBadge.isShown(for: draft.kind) {
                LabeledContent("Compatibility") {
                    Text(CompatBadge.badge(for: inspected, profile: profile).label)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
""")

# 2. Wizard target step: the "<App> <version> · <badge>" line.
patch("App/Sources/Views/Wizard/WizardSteps.swift",
"            if let app = model.inspected {\n                Text(\"\\(app.name) \\(app.version) · \\(CompatBadge.badge(for: app, profile: model.profile).label)\")",
"            if let app = model.inspected, CompatBadge.isShown(for: model.kind) {\n                Text(\"\\(app.name) \\(app.version) · \\(CompatBadge.badge(for: app, profile: model.profile).label)\")")

# 3. Wizard review: the Compatibility row (after Task 5 it already sits in the non-web branch; the guard keeps it so).
review = 'row("Compatibility", CompatBadge.badge(for: model.inspected, profile: model.profile).label)'
path = "App/Sources/Views/Wizard/WizardSteps.swift"
text = open(path).read()
assert text.count(review) == 1, f"{path}: expected one Compatibility row, found {text.count(review)}"
indent = re.search(r"^( *)" + re.escape(review), text, re.M).group(1)
guarded = f"{indent}if CompatBadge.isShown(for: model.kind) {{\n{indent}    {review}\n{indent}}}"
text = text.replace(indent + review, guarded)
open(path, "w").write(text)
EOF
grep -n "CompatBadge" App/Sources/Views/EditorSections.swift App/Sources/Views/Wizard/WizardSteps.swift
```

Expected from the final `grep`: `EditorSections.swift` shows `CompatBadge.isShown(for: draft.kind)` plus the `CompatBadge.badge(` line; `WizardSteps.swift` shows `CompatBadge.isShown(for: model.kind)` twice (target step, review) beside the two `CompatBadge.badge(` lines. If the script's assertion trips, Task 5 has changed the text; read the call site, apply the same `isShown` guard by hand and keep the rule: a web model or draft never renders a compatibility line.

**Deviation:** skeleton decision 14 says "`CompatBadge` is not shown for web apps" without saying where. This task adds the pure helper `CompatBadge.isShown(for: ShortcutKind)` (`kind != .webApp`, so a future file or folder kind keeps its badge) and guards the three call sites. The editor's `TargetSection` is already hidden for web apps by Step 26 and Task 5's web review/target steps already omit the line, so these guards are the safety net the coordinator asked for; their behaviour is verified by acceptance Step 7, not by a unit test.

- [ ] **Step 43: Run to see them pass**

Run: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh -only-testing:MacAppDuplicatorTests/ShortcutBuilderWebTests -only-testing:MacAppDuplicatorTests/CompatBadgeTests -only-testing:MacAppDuplicatorTests/AppStateWebTests -only-testing:MacAppDuplicatorTests/ShortcutBuilderTests`
Expected: `0 failures`; the app target compiles with the three guards (the views have no unit tests, so a compile error there fails this run).

- [ ] **Step 44: Commit**

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add App/Sources/Services/TargetResolver+ResolvedPath.swift App/Sources/Services/CompatBadge.swift App/Sources/Views/EditorSections.swift App/Sources/Views/Wizard/WizardSteps.swift App/Tests/Services/ShortcutBuilderWebTests.swift App/Tests/Services/CompatBadgeTests.swift App/Tests/App/AppStateWebTests.swift && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Skip the target lookup and the compatibility badge for web apps

Web apps have no target app, so the target resolver returns nothing for them and export and delete work from the bundle alone. The compatibility badge is hidden for web apps in the editor and the wizard.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Sub-task H: Acceptance doc, README, version, full run

- [ ] **Step 45: Write the acceptance checklist**

Create `docs/acceptance/phase4-webshell.md` with exactly this content:

````markdown
# Phase 4 acceptance: web apps

Manual gate. Automated coverage is `Tools/test-app.sh` (MacAppDuplicatorTests), `swift test --filter DuplicatorCoreTests`, `swift test --filter CompatProfilesTests` and `swift test --filter IntegrationTests`. The steps below need a person at the Mac. Steps 3, 4 and 5 need Mike: they sign in to a real WhatsApp account and need a second device to send messages. Tick each box as it passes and fill in the Record table.

## Preconditions

- The Mac is online. The bundled profiles carry the `whatsapp` web app preset (`https://web.whatsapp.com`, Chrome user agent), so no profile download is needed.
- Default settings: quit App Duplicator and run `defaults delete com.mikekuta.MacAppDuplicator` (an error saying the domain does not exist is fine).
- No earlier acceptance run left files behind: `ls ~/Applications/App\ Duplicator | grep -i "Acceptance Chat"` prints nothing, and `ls ~/Library/WebKit | grep acceptance-chat` prints nothing.
- Run every command from the repository root.

## Step 1: Build

```bash
Tools/build-app.sh --configuration Release
```

- [ ] **1.1** The command prints `<repo>/.build/DerivedData/Build/Products/Release/macOS App Duplicator.app`. Open it with `open "<path>"` (the name contains spaces). Expected: the library window opens and the app menu's About panel shows `Version 0.4.0 (3)`.

## Step 2: Create a web app

- [ ] **2.1** Press ⌘N. Expected: the kind step offers `Web App` with the subtitle `Any website as its own app`, enabled. Choose it and click Next.
- [ ] **2.2** Expected: the heading `Choose a website`, preset tiles including `WhatsApp`, `Teams` and `Outlook`, and an empty `Website URL` field. Click the `WhatsApp` tile. Expected: the field shows `https://web.whatsapp.com`. Type `ftp://example.com` into the field instead. Expected: the note `Enter an https:// address` and Next is disabled. Click the `WhatsApp` tile again and click Next.
- [ ] **2.3** Identity: set the name to `Acceptance Chat`. Expected: the icon choice defaults to `Fetched from site` (a generated letter tile appears with a note if the fetch failed). Next.
- [ ] **2.4** `Web App Options`: expected `User agent` shows `Chrome`, `Also open in app` lists `whatsapp.com` and `whatsapp.net`, `Menu bar icon` is off and `Keep running in the menu bar when the window closes` is disabled with the hint `Turn on the menu bar icon first`. Leave everything as is and click Next.
- [ ] **2.5** Review. Expected: rows for the name, the address, the user agent and the web data id, and no `Compatibility`, `Profile` or `Launch plan` line. Create. Expected: `Acceptance Chat` appears in the library and its bundle is `~/Applications/App Duplicator/Acceptance Chat.app`.
- [ ] **2.6** `plutil -extract CFBundleIdentifier raw -o - ~/Applications/App\ Duplicator/Acceptance\ Chat.app/Contents/Info.plist` prints `com.mikekuta.appduplicator.acceptance-chat`. Note the web data id shown in the editor's `Web data` row (Step 7) as `<UUID>`; the WebKit folder name is the same id in lowercase.

## Step 3: Login persists across relaunches (Mike)

- [ ] **3.1** In the library, click Launch on `Acceptance Chat`. Expected: a window opens on WhatsApp Web with a QR code, and the Dock shows the `Acceptance Chat` icon.
- [ ] **3.2** Scan the QR code with the phone and wait for the chat list. Expected: signed in.
- [ ] **3.3** Quit with ⌘Q. Launch it again. Expected: the chat list appears without a QR code (the login survived).
- [ ] **3.4** Quit it, restart App Duplicator, launch again. Expected: still signed in. `ls ~/Library/WebKit/com.mikekuta.appduplicator.acceptance-chat/WebsiteDataStore` lists one folder, named with `<UUID>` in lowercase.

## Step 4: Dock badge (Mike)

- [ ] **4.1** With `Acceptance Chat` running and a second window or app in front, send two messages from another device to this WhatsApp account. Expected: the page title shows `(2)` and the Dock icon shows the badge `2`.
- [ ] **4.2** Open the unread chats. Expected: the badge disappears.
- [ ] **4.3** `grep -c badge ~/Library/Logs/App\ Duplicator/Acceptance\ Chat.log` prints a number greater than 0.

## Step 5: Notification click (Mike)

- [ ] **5.1** Send a message while `Acceptance Chat` is in the background. On the first notification macOS asks whether `Acceptance Chat` may send notifications; choose Allow. Expected: a banner titled with the sender's name.
- [ ] **5.2** Switch to another app, send another message and click the banner. Expected: `Acceptance Chat` comes to the front with its window.

## Step 6: Menu bar icon and background mode

- [ ] **6.1** Quit `Acceptance Chat`. In its editor (Step 7 describes the section) switch `Menu bar icon` on, then `Keep running in the menu bar when the window closes` on, and Save. Launch it again.
- [ ] **6.2** Expected: an icon appears in the menu bar. Close the window with ⌘W. Expected: the window closes, the Dock icon disappears and the menu bar icon stays.
- [ ] **6.3** Click the menu bar icon and choose `Show Acceptance Chat`. Expected: the window returns and so does the Dock icon.
- [ ] **6.4** Close the window again, then click the menu bar icon and choose `Quit Acceptance Chat`. Expected: the app quits and the menu bar icon is gone.
- [ ] **6.5** In the editor, switch `Menu bar icon` off. Expected: `Keep running in the menu bar when the window closes` turns off and is disabled with the hint `Turn on the menu bar icon first`. Save.

## Step 7: Editor

Select `Acceptance Chat` in the library.

- [ ] **7.1** Expected: the editor shows Identity and a `Web App` section; there is no Target, Profile, Launch or Advanced section, no `Compatibility` row, and `Launch`, `Reveal in Finder`, `Regenerate`, `Duplicate`, `Export` and `Delete` are enabled. The `Web App` section shows `Website URL`, `User agent`, `Badge pattern`, `Also open in app`, `Menu bar icon`, `Keep running in the menu bar when the window closes`, a read-only `Zoom` of `100%`, and a `Web data` row with `<UUID>` and the button `Remove Web Data…`.
- [ ] **7.2** Record the icon fingerprint: `shasum -a 256 ~/Applications/App\ Duplicator/Acceptance\ Chat.app/Contents/Resources/AppIcon.icns`. Call the printed hash `<ICON>`.
- [ ] **7.3** Change `User agent` to `Safari`, add the line `login.example.com` under `Also open in app`, and click Save. Expected: Save succeeds and the sidebar row stays `Acceptance Chat`.
- [ ] **7.4** Expected after the Save: the `shasum` command from 7.2 prints `<ICON>` again (the fetched icon was kept), the `plutil` command from 2.6 still prints `com.mikekuta.appduplicator.acceptance-chat`, and `Web data` still shows `<UUID>`.
- [ ] **7.5** Rename the shortcut to `Acceptance Chat 2` in Identity and Save. Expected: the bundle is now `Acceptance Chat 2.app`, the bundle identifier is still `com.mikekuta.appduplicator.acceptance-chat`, `Web data` still shows `<UUID>`, and launching it is still signed in to WhatsApp. Rename it back to `Acceptance Chat` and Save.
- [ ] **7.6** Type `ftp://example.com` into `Website URL`. Expected: the message `Enter an https:// address` and Save is disabled. Click Revert. Expected: the original address returns and Save is disabled again.
- [ ] **7.7** Type `(` into `Badge pattern`. Expected: a note that the pattern is not valid and the default `\((\d+)\)` is used. Click Revert.

## Step 8: Remove Web Data

Quit `Acceptance Chat` first if it is running. Replace `<ID>` below with `com.mikekuta.appduplicator.acceptance-chat`.

- [ ] **8.1** Launch `Acceptance Chat` (still signed in), keep it running, and click `Remove Web Data…` in the editor, then `Remove Web Data` in the confirmation. Expected: an alert titled `Could not remove web data` with the text `Quit “Acceptance Chat” before removing its web data.` and nothing is removed. Quit `Acceptance Chat`.
- [ ] **8.2** Before: run `ls ~/Library/WebKit/<ID>/WebsiteDataStore` (one folder named `<UUID>` in lowercase) and `ls ~/Library/Caches/<ID>`. Note both.
- [ ] **8.3** Click `Remove Web Data…`, read the confirmation (it says this signs the shortcut out of every site and cannot be undone), and click `Remove Web Data`. Expected: no alert.
- [ ] **8.4** After: `ls ~/Library/WebKit/<ID>/WebsiteDataStore` no longer lists the `<UUID>` folder (it may report no such directory or print nothing). `ls ~/Library/Caches/<ID>` shows the web cache is gone or empty. The shortcut is still in the library and `Web data` still shows `<UUID>`.
- [ ] **8.5** Launch `Acceptance Chat`. Expected: WhatsApp shows a QR code again (signed out). Quit it. If it is still signed in after 8.3, or 8.4 shows the folder, the web data store location assumed in Deviation 1 of the Phase 4 plan is wrong: stop and report it instead of ticking the box.

## Step 9: Duplicate and Delete

- [ ] **9.1** Duplicate `Acceptance Chat` as `Acceptance Chat Copy`. Expected: the copy's `Web data` shows a different id from the original, and its Web App section keeps the same address and options. Launch the copy briefly, expecting a QR code (it has its own logins), then quit it.
- [ ] **9.2** Delete `Acceptance Chat Copy`. Expected: after the usual confirmation a second question `Also remove web data (logins, cookies, cache)?` with the buttons `Keep Web Data` (the default), `Remove Web Data` and `Cancel`. Click `Cancel`. Expected: nothing was deleted.
- [ ] **9.3** Delete it again and choose `Keep Web Data`. Expected: the shortcut is in the Trash and `ls ~/Library/WebKit/com.mikekuta.appduplicator.acceptance-chat-copy/WebsiteDataStore` still lists a folder.
- [ ] **9.4** Put `Acceptance Chat Copy.app` back into `~/Applications/App Duplicator` from the Trash, wait for it to appear in the library, and delete it again, this time choosing `Remove Web Data`. Expected: the shortcut is in the Trash and the folder from 9.3 is gone. If the delete fails, the shortcut is not trashed and an alert shows why.
- [ ] **9.5** Empty nothing: the Trash holds the two `Acceptance Chat Copy.app` bundles until Teardown.

## Step 10: Diagnostics

- [ ] **10.1** Change the address of `Acceptance Chat` to `https://web.whatsapp.com/?token=mad-secret-4471#x` and Save. Open `Diagnostics…`. Expected: rows `Kind` (`Web app`), `URL` (`https://web.whatsapp.com/`), `User agent` (`Safari`), `Data store` (`<UUID>`), `Background` (`Off`), `Menu bar icon` (`Off`), `Badge pattern` (`\((\d+)\) (default)`), `Also open` (`whatsapp.com, whatsapp.net, login.example.com`), `Zoom` (`100%`), and a log section ending with the lines Step 3 and Step 4 produced. There are no `Target`, `Executable`, `Arguments` or `Environment` entries.
- [ ] **10.2** Click `Copy Report`, then run `pbpaste | grep -c 'mad-secret-4471'`. Expected: `0`. Done. Restore the address to `https://web.whatsapp.com` and Save.

## Step 11: Known Limitations

- [ ] **11.1** Help → Known Limitations. Expected: 24 entries. The last four are `Web apps do not support passkeys`, `Web app zoom is remembered outside the shortcut`, `Web notifications are always allowed, but macOS decides whether they appear` and `Web apps open other sites in your browser`.

## Step 12: Zoom is kept outside the bundle

- [ ] **12.1** Launch `Acceptance Chat`, press ⌘+ three times, quit, launch again. Expected: the page is still zoomed. The editor's `Zoom` still reads `100%`.
- [ ] **12.2** `defaults read com.mikekuta.appduplicator.acceptance-chat MADPageZoom` prints a number above 1. Press ⌘0 in the app, quit, and run the command again. Expected: `1`.

## Teardown

Move only the test items to the Trash (nothing here is deleted outright):

- `~/Applications/App Duplicator/Acceptance Chat.app` (delete it from the library, choose `Remove Web Data`).
- `~/Library/Preferences/com.mikekuta.appduplicator.acceptance-chat.plist`: `mv ~/Library/Preferences/com.mikekuta.appduplicator.acceptance-chat.plist ~/.Trash/` (the preferences daemon may need `killall cfprefsd` before the zoom value disappears).
- `~/Library/Logs/App Duplicator/Acceptance Chat.log` and `Acceptance Chat Copy.log`.
- Empty any leftover `Acceptance Chat Copy.app` bundles from the Trash yourself.

## Record

| Step | Date | Result | Notes |
|---|---|---|---|
| 1 | | | |
| 2 | | | |
| 3 | | | |
| 4 | | | |
| 5 | | | |
| 6 | | | |
| 7 | | | |
| 8 | | | |
| 9 | | | |
| 10 | | | |
| 11 | | | |
| 12 | | | |
````

Step 12 ("zoom outside the bundle") and the 24-entry check back the two Known Limitations that describe behaviour the main app cannot test. If Task 2 stores zoom elsewhere, 12.2 is the line to fix.

- [ ] **Step 46: README and version**

(a) `README.md`, line 54 — replace `- Web shell: no passkeys.` with:

```markdown
- Web apps: no passkeys; see Phase 4 web apps below.
```

(b) `README.md`, line 52 (the Phase 2 editor bullet) — replace `` `Erase data on quit` and `Menu bar icon` show their stored values but stay disabled until Phase 6. `` with:

```markdown
`Erase data on quit` and `Menu bar icon` show their stored values but stay disabled for application shortcuts until Phase 6; a web app's `Menu bar icon` is live (see Phase 4 web apps).
```

(c) `README.md`, line 78 — replace `Help → Known Limitations (20 entries since Phase 3; the six profile entries are listed under Phase 3 profiles).` with:

```markdown
Help → Known Limitations (24 entries since Phase 4; the six profile entries are listed under Phase 3 profiles and the four web entries under Phase 4 web apps).
```

(d) Insert this section immediately before `## Core API used by the app` (line 118):

```markdown
## Phase 4 web apps

A web app is a Dock shortcut for a website: App Duplicator builds a bundle whose executable is a small embedded browser (WebKit) that opens one address in its own window, with its own bundle identifier, Dock icon and private website data store. Create one with ⌘N → `Web App`: pick a preset (WhatsApp, Teams, Outlook) or type an https address, then set the user agent, the badge pattern, the extra hosts that stay in the app, the menu bar icon and background mode.
- Logins, cookies and cache live in a WebKit data store named by the id shown in the editor's `Web data` row, under `~/Library/WebKit/<shortcut bundle identifier>/WebsiteDataStore`. A duplicate gets a new id, so it has its own logins. The editor's `Remove Web Data…` and the second question when you delete a web app remove that store; the shortcut must be quit first.
- The page title's unread count (default pattern `(3)`) and the site's own app-badge calls drive the Dock badge; notifications use macOS banners and a click fronts the window.
- With `Menu bar icon` and `Keep running in the menu bar when the window closes` on, closing the window leaves the app running in the menu bar. For a web app the Menu bar icon is live in this phase; for application shortcuts it stays inert until Phase 6.
- A rename keeps a web app's bundle identifier, so its logins survive. Editing never refetches the site icon; the icon stays as created unless you pick another.
- Diagnostics shows the address (query and credentials removed), user agent, web data id, background and menu bar state, badge pattern, extra hosts, zoom and the shell's log tail.
- Limits: no passkeys, zoom kept in the shell's own preferences, notification permission decided by macOS, and other sites open in your browser (four new Known Limitations entries).

Acceptance checklist: `docs/acceptance/phase4-webshell.md`.

```

(e) `App/project.yml`, lines 56-57 — change

```yaml
        CURRENT_PROJECT_VERSION: "2"
        MARKETING_VERSION: "0.3.0"
```

to

```yaml
        CURRENT_PROJECT_VERSION: "3"
        MARKETING_VERSION: "0.4.0"
```

Check nothing else pins the old version: `cd /Users/cubbieblue16/Developer/MacAppDuplicator && grep -rn '0\.3\.0' --include='*.swift' --include='*.yml' --include='*.md' --include='*.plist' --include='*.sh' App Tools Packages README.md docs/acceptance | grep -v phase3-profiles`
Expected: no output. (`docs/acceptance/phase3-profiles.md` still says `Version 0.3.0 (2)` as a record of that phase; leave it.)

- [ ] **Step 47: Full verification run and final commit**

Run, in order:

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && Tools/test-app.sh
cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter DuplicatorCoreTests
cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter CompatProfilesTests
cd /Users/cubbieblue16/Developer/MacAppDuplicator && swift test --filter IntegrationTests
```

Expected: every run ends with `0 failures`. `Tools/test-app.sh` regenerates the Xcode project, so it picks up `0.4.0 (3)`; confirm with `cd /Users/cubbieblue16/Developer/MacAppDuplicator && grep -n "MARKETING_VERSION\|CURRENT_PROJECT_VERSION" App/project.yml`.

```bash
cd /Users/cubbieblue16/Developer/MacAppDuplicator && git add README.md App/project.yml docs/acceptance/phase4-webshell.md && git -c user.name="Cubbieblue16" -c user.email="152761714+cubbieblue16@users.noreply.github.com" commit -m "Document Phase 4 web apps and bump the version to 0.4.0

Adds the Phase 4 acceptance checklist, a README section for web apps, the new Known Limitations count, and version 0.4.0 (build 3).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

## Resolved by coordinator

1. WebKit store layout: accepted as planned. Acceptance Step 8 is the live check; `WebKitWebDataRemover` is the only component that changes if the layout differs.
2. Task 4 signatures confirmed: `AppState.init(settings:library:launcherBinary:webShellBinary: URL? = nil, profiles: ProfilesModel? = nil)` and `ShortcutBuilder.init(launcherBinary:webShellBinary:signingIdentity:)`. `makeWebTestAppState` may omit `profiles:`. `LibraryScanner` returns a record for any bundle whose Info.plist carries `MADConfig`, including web bundles.
3. Icon preservation: Task 4's `regenerate` and `duplicate` copy `AppIcon.icns` byte-for-byte without decoding; the `[1, 2, 3]` test bytes stand.
4. Helper names: no collision. Task 5's test support defines `WizardFakeIconFetcher` only; none of `makeWebShortcutConfig`, `FakeWebDataRemover`, `RunningPaths`, `makeWebTestAppState` appear in Task 5.
5. Editor refetch: accepted (Deviation 4). No refetch in the editor.
6. Validator: Task 1 `WebAppURLValidator` rejects `ftp://` and `http://` with `Enter an https:// address`. Acceptance 2.2 and 7.6 stand.
7. Wizard labels confirmed against Task 5: `Web App`, `Choose a website`, `Web App Options`, `Fetched from site`, preset tile names from `profiles.json`.
8. Commit trailer: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` on every commit. Ignore any other attribution reminder.
9. Text-anchored guards stand. If a guard assertion fails during execution, apply the guard by hand at the matching line and note it in the task report.
10. A web bundle with `webApp == nil`: `ShortcutBuilder.create` throws `BuilderError.webAppConfigMissing`, so the app never writes one. A hand-edited bundle shows the non-web editor layout; no special handling. Acceptable.
11. Zoom key confirmed: Task 2 persists zoom in the shell's own `UserDefaults` under `MADPageZoom`. `web-zoom-storage` and acceptance Step 12 wording stand.

---
