import CompatProfiles
import DuplicatorCore
import Foundation
import Observation

/// State for the New Shortcut sheet. Pure model: no AppKit, so it is unit-testable.
@MainActor
@Observable
final class WizardModel {
    enum Step: Int, CaseIterable {
        case kind, target, identity, data, review
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

    /// The last name this model filled in itself. A name still equal to it was not typed by the user, so picking
    /// another target may replace it.
    private var suggestedName = ""

    /// True while `launchMode` is System Launch only because a protected target forced it, so a later unprotected
    /// target can restore the default.
    private var launchModeWasForced = false

    /// Looks up the profile for a target bundle identifier; the sheet passes `AppState.profile(forBundleIdentifier:)`.
    private let profileLookup: @MainActor (String) -> AppProfile?

    init(prefillTarget: URL? = nil, profileLookup: @escaping @MainActor (String) -> AppProfile? = { _ in nil }) {
        self.profileLookup = profileLookup
        if let prefillTarget {
            selectTarget(prefillTarget)
            if inspected != nil { step = .identity }
        }
    }

    var isLastStep: Bool { step == .review }

    /// Dock Shortcut cannot exec a protected binary (spec §4.1); the picker is locked to System Launch.
    /// Same rule as the editor's (`InspectedApp.requiresSystemLaunch`).
    var requiresSystemLaunch: Bool {
        inspected?.requiresSystemLaunch ?? false
    }

    var canAdvance: Bool {
        switch step {
        case .kind: kind == .app
        case .target: inspected != nil
        case .identity: !name.trimmingCharacters(in: .whitespaces).isEmpty && (iconMode != .custom || customIconPath != nil)
        case .data: true
        case .review: preview != nil && !isCreating
        }
    }

    func selectTarget(_ url: URL) {
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
        guard canAdvance, let i = Step.allCases.firstIndex(of: step), i + 1 < Step.allCases.count else { return }
        step = Step.allCases[i + 1]
        if step == .review { refreshPreview() }
    }

    func back() {
        guard let i = Step.allCases.firstIndex(of: step), i > 0 else { return }
        step = Step.allCases[i - 1]
    }

    func makeConfig() -> ShortcutConfig {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let slug = ShortcutConfig.slug(for: trimmed)
        return ShortcutConfig(
            kind: kind,
            name: trimmed,
            slug: slug,
            bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: slug),
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
    func refreshPreview() {
        let config = makeConfig().resolvingDefaultDataPath(home: FileManager.default.homeDirectoryForCurrentUser)
        do {
            preview = try LaunchPlanPreview.make(config: config, bundleURL: nil)
            previewError = nil
        } catch {
            preview = nil
            previewError = error.localizedDescription
        }
    }
}
