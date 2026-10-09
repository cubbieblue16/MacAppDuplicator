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
    private(set) var preview: LaunchPlanPreview?
    private(set) var previewError: String?
    var isCreating = false

    /// The last name this model filled in itself. A name still equal to it was not typed by the user, so picking
    /// another target may replace it.
    private var suggestedName = ""

    init(prefillTarget: URL? = nil) {
        if let prefillTarget {
            selectTarget(prefillTarget)
            if inspected != nil { step = .identity }
        }
    }

    var isLastStep: Bool { step == .review }

    /// Dock Shortcut cannot exec a protected binary (spec §4.4); the picker is locked to System Launch.
    var requiresSystemLaunch: Bool {
        guard let inspected else { return false }
        return inspected.hasLaunchConstraints || inspected.isPlatformBinary
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
            if name.isEmpty || name == suggestedName {
                name = "\(app.name) Copy"
                suggestedName = name
            }
            if requiresSystemLaunch { launchMode = .systemLaunch }
        } catch {
            inspected = nil
            inspectError = error.localizedDescription
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
            iconMode: iconMode,
            customIconPath: iconMode == .custom ? customIconPath : nil
        )
    }

    /// Previews the plan the shortcut will actually run. `makeConfig()` leaves a default data folder as nil and
    /// `ShortcutBuilder` resolves it at write time; the planner would otherwise report "data separation skipped".
    func refreshPreview() {
        var config = makeConfig()
        if config.dataMode != .disabled, config.dataPath == nil {
            config.dataPath = ShortcutConfig.defaultDataPath(forSlug: config.slug, home: FileManager.default.homeDirectoryForCurrentUser)
        }
        do {
            preview = try LaunchPlanPreview.make(config: config, bundleURL: nil)
            previewError = nil
        } catch {
            preview = nil
            previewError = error.localizedDescription
        }
    }
}
