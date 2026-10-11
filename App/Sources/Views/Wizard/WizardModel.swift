import CompatProfiles
import DuplicatorCore
import Foundation
import Observation

/// Where the web app icon fetch stands (the identity step shows it). `unavailable` carries why the fetch failed so tests
/// can assert it; the user only sees the fixed `WizardModel.webIconStatusText`.
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
    /// The profile's `args`, `env` and `newWindowCommand`, copied into the new shortcut by `makeConfig()` as editable
    /// defaults; replaced whenever the target changes. A template `NewWindowCommandBuilder.validationMessage(for:)`
    /// rejects is not copied, so a new shortcut never starts with a command its editor would refuse to save.
    private(set) var arguments: [String] = []
    private(set) var environment: [String: String] = [:]
    private(set) var newWindowCommand: String?
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

    // MARK: Launcher state (Phase 5)

    /// The file or folder a `.file`/`.folder` shortcut opens; `selectItem` sets it and picks the kind.
    var itemPath: String?
    /// The app that opens the item; nil opens it with the app macOS picks.
    var openerAppPath: String?
    /// The program a `.cli` shortcut runs, as typed; `validatedCLIExecutable` is the checked form.
    var cliExecutable = ""
    /// One argument per entry, already trimmed and without empty entries (see `parseArguments`).
    var cliArguments: [String] = []
    var cliWorkingDirectory: String?
    var terminal: TerminalChoice = .terminal
    var cliHomeOverride = false
    private(set) var itemError: String?
    private(set) var openerError: String?
    private var itemIsDirectory = false

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
    /// store); Web App Options takes that slot. A file or folder shortcut has no data at all; a command's Data step only
    /// offers its own HOME.
    var steps: [Step] {
        switch kind {
        case .webApp: [.kind, .target, .identity, .webOptions, .review]
        case .file, .folder: [.kind, .target, .identity, .review]
        case .app, .cli: [.kind, .target, .identity, .data, .review]
        }
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
        case .kind: true
        case .target:
            switch kind {
            case .app: inspected != nil
            case .webApp: validatedWebURL != nil
            case .file, .folder: itemPath != nil
            case .cli: validatedCLIExecutable != nil
            }
        case .identity: !name.trimmingCharacters(in: .whitespaces).isEmpty && (iconMode != .custom || customIconPath != nil)
        case .data, .webOptions: true
        case .review:
            switch kind {
            case .webApp: !isCreating && webIconFetchState != .fetching
            case .app, .file, .folder, .cli: preview != nil && !isCreating
            }
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
            newWindowCommand = nil
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
            if let template = profile?.newWindowCommand, NewWindowCommandBuilder.validationMessage(for: template) == nil {
                newWindowCommand = template
            } else {
                newWindowCommand = nil
            }
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
            newWindowCommand = nil
        }
    }

    func next() {
        guard canAdvance, let i = steps.firstIndex(of: step), i + 1 < steps.count else { return }
        step = steps[i + 1]
        if step == .identity, kind == .webApp { startIconFetch() }
        if step == .identity, isLauncherKind { suggestLauncherName() }
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
        if kind == .file || kind == .folder { return makeFileConfig() }
        if kind == .cli { return makeCLIConfig() }
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
            newWindowCommand: newWindowCommand,
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

    /// One host per non-empty line with any scheme, `user@`, `:port`, path, query or fragment removed. `WebAppConfig.init` then trims,
    /// lower-cases and de-duplicates.
    static func parseExtraHosts(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var host = line.trimmingCharacters(in: .whitespaces)
            if let separator = host.range(of: "://") { host = String(host[separator.upperBound...]) }
            if let end = host.firstIndex(where: { "/?#".contains($0) }) { host = String(host[..<end]) }
            // A host never carries credentials or a port: `user@cdn.example:443` can only ever match as `cdn.example`.
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            if let colon = host.lastIndex(of: ":"), !host.hasSuffix("]"),
               host[host.index(after: colon)...].allSatisfy(\.isNumber) {
                host = String(host[..<colon])
            }
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
        case .copied: copiedIconLabel
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

    // MARK: Launchers (Phase 5)

    /// The terminal picker's order: Terminal first, background last.
    static let terminalChoices: [TerminalChoice] = [.terminal, .iterm2, .ghostty, .none]

    /// The picker label for a terminal choice. Nonisolated so Diagnostics (built off the main actor) could share it.
    nonisolated static func terminalLabel(_ choice: TerminalChoice) -> String {
        switch choice {
        case .terminal: "Terminal"
        case .iterm2: "iTerm2"
        case .ghostty: "Ghostty"
        case .none: "No terminal (run in background)"
        }
    }

    /// One argument per line: each line trimmed, empty lines dropped. Quotes are kept as typed (no shell parsing).
    static func parseArguments(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var isLauncherKind: Bool { kind == .file || kind == .folder || kind == .cli }

    /// What the identity step's Copied option is called for this kind.
    var copiedIconLabel: String {
        switch kind {
        case .webApp: "Fetched from site"
        case .file, .folder: "Copied from item"
        case .cli: "Copied from executable"
        case .app: "Copied from target"
        }
    }

    /// The path whose Finder icon the identity step previews for a launcher kind.
    var launcherIconPath: String? {
        switch kind {
        case .file, .folder: itemPath
        case .cli: validatedCLIExecutable
        case .app, .webApp: nil
        }
    }

    /// Where a command's own HOME would live (`ShortcutConfig.defaultDataPath` for the current slug).
    var commandHomePath: String {
        ShortcutConfig.defaultDataPath(forSlug: slug, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// The kind step's options. "File or Folder" is offered as `.folder`; choosing it keeps the kind an already chosen item decided.
    func chooseKind(_ chosen: ShortcutKind) {
        guard chosen == .file || chosen == .folder else {
            kind = chosen
            return
        }
        kind = itemPath != nil && !itemIsDirectory ? .file : .folder
    }

    /// Picks the item a launcher opens. A folder that is not a package becomes `.folder`; a file or a package (an app, a
    /// document bundle) becomes `.file`. App Duplicator shortcuts are refused: opening one would chain launchers.
    func selectItem(_ url: URL) {
        itemError = nil
        guard !TargetGuard.isShortcutBundle(at: url) else {
            itemPath = nil
            itemError = TargetGuard.refusalMessage(forAppAt: url)
            return
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        } catch {
            itemPath = nil
            itemError = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }
        itemIsDirectory = values.isDirectory == true && values.isPackage != true
        kind = itemIsDirectory ? .folder : .file
        itemPath = FileConfig.normalizedPath(url.path)
    }

    /// The app that opens the item, or nil for the default app. Only `.app` bundles that are not shortcuts are accepted.
    func selectOpener(_ url: URL?) {
        openerError = nil
        guard let url else {
            openerAppPath = nil
            return
        }
        guard url.pathExtension == "app" else {
            openerError = "\(url.lastPathComponent) is not an app."
            return
        }
        guard !TargetGuard.isShortcutBundle(at: url) else {
            openerError = TargetGuard.refusalMessage(forAppAt: url)
            return
        }
        openerAppPath = FileConfig.normalizedPath(url.path)
    }

    /// Why the executable field does not validate, or nil when it does.
    var cliExecutableError: String? {
        let path = Self.expandedPath(cliExecutable)
        if path.isEmpty { return "Choose the program to run." }
        guard path.hasPrefix("/") else { return "Use a full path that starts with /." }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return "Nothing exists at \(path)." }
        guard !isDirectory.boolValue else { return "\(path) is a folder, not a program." }
        guard FileManager.default.isExecutableFile(atPath: path) else { return "\(path) is not executable." }
        return nil
    }

    /// The executable once it is an absolute path to an existing, executable file (trimmed, `~` expanded); nil otherwise.
    var validatedCLIExecutable: String? {
        cliExecutableError == nil ? Self.expandedPath(cliExecutable) : nil
    }

    func makeFileConfig() -> ShortcutConfig {
        let finalSlug = slug
        return ShortcutConfig(
            kind: kind == .folder ? .folder : .file,
            name: name.trimmingCharacters(in: .whitespaces),
            slug: finalSlug,
            bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: finalSlug),
            targetPath: "",
            targetBundleIdentifier: "",
            launchMode: .dockShortcut,
            dataMode: .disabled,
            dataPath: nil,
            iconMode: iconMode,
            customIconPath: iconMode == .custom ? customIconPath : nil,
            file: FileConfig(path: itemPath ?? "", openerAppPath: openerAppPath)
        )
    }

    func makeCLIConfig() -> ShortcutConfig {
        let finalSlug = slug
        return ShortcutConfig(
            kind: .cli,
            name: name.trimmingCharacters(in: .whitespaces),
            slug: finalSlug,
            bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: finalSlug),
            targetPath: "",
            targetBundleIdentifier: "",
            launchMode: .dockShortcut,
            dataMode: .disabled,
            dataPath: nil,
            iconMode: iconMode,
            customIconPath: iconMode == .custom ? customIconPath : nil,
            cli: CLIConfig(
                executablePath: validatedCLIExecutable ?? Self.expandedPath(cliExecutable),
                arguments: cliArguments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                workingDirectory: trimmedWorkingDirectory,
                terminal: terminal,
                homeOverride: cliHomeOverride
            )
        )
    }

    /// The review step's rows for file, folder and command shortcuts. Arguments are masked like the launch plan.
    var launcherReviewRows: [ReviewRow] {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .file, .folder:
            return [
                ReviewRow("Name", trimmedName),
                ReviewRow(kind == .folder ? "Folder" : "File", itemPath ?? "None"),
                ReviewRow("Open with", openerAppPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Default app"),
                ReviewRow("Icon", iconDescription),
            ]
        case .cli:
            let arguments = SecretMasking.maskArguments(cliArguments).map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            return [
                ReviewRow("Name", trimmedName),
                ReviewRow("Executable", validatedCLIExecutable ?? cliExecutable),
                ReviewRow("Arguments", arguments.isEmpty ? "None" : arguments.joined(separator: " ")),
                ReviewRow("Working directory", trimmedWorkingDirectory ?? "Default"),
                ReviewRow("Terminal", Self.terminalLabel(terminal)),
                ReviewRow("HOME", cliHomeOverride ? "Own HOME: \(commandHomePath)" : "Your HOME"),
                ReviewRow("Icon", iconDescription),
            ]
        case .app, .webApp:
            return []
        }
    }

    private var trimmedWorkingDirectory: String? {
        guard let raw = cliWorkingDirectory?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return raw
    }

    private static func expandedPath(_ raw: String) -> String {
        NSString(string: raw.trimmingCharacters(in: .whitespaces)).expandingTildeInPath
    }

    /// Fills the name from the item (without its extension for a file) or the executable, unless the user typed one.
    private func suggestLauncherName() {
        guard let source = kind == .cli ? validatedCLIExecutable : itemPath else { return }
        let url = URL(fileURLWithPath: source)
        let candidate = kind == .file ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        if name.isEmpty || name == suggestedName {
            name = candidate
            suggestedName = name
        }
    }
}
