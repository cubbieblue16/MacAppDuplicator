import DuplicatorCore
import Foundation

/// A save held back because its shortcut was not created by this App Duplicator (security review C3). Saving rewrites
/// the bundle and signs it with the user's identity, so a received or planted config would run as the user's own
/// from then on; `ForeignShortcutApprovalSheet` shows everything it would run, and nothing is written until the user
/// chooses Trust and Rebuild (`AppState.approveForeignShortcut`).
struct ForeignShortcutApproval: Identifiable {
    let id = UUID()
    /// The shortcut as scanned, foreign provenance included.
    let record: ShortcutRecord
    /// The config the save would write: the editor's draft, or the bundle's own config for Regenerate.
    let config: ShortcutConfig
    /// How the bundle on disk is signed now.
    let signature: CodeSignature

    /// Why the scanner marked the shortcut foreign.
    var reason: String {
        record.foreignReason ?? "not created by this App Duplicator"
    }

    var kindDescription: String {
        switch config.kind {
        case .app: return "App"
        case .webApp: return "Web App"
        case .file: return "File"
        case .folder: return "Folder"
        case .cli: return "Command"
        }
    }

    /// What the shortcut opens or runs: the target app, the web address, the file or folder (and the app that opens
    /// it), or the command's executable.
    var targetDescription: String {
        switch config.kind {
        case .app:
            return config.targetPath
        case .webApp:
            return config.webApp?.url ?? config.targetPath
        case .file, .folder:
            let path = config.file?.path ?? config.targetPath
            guard let opener = config.file?.openerAppPath else { return path }
            return "\(path), opened with \(opener)"
        case .cli:
            return config.cli?.executablePath ?? config.targetPath
        }
    }

    /// Every argument in launch order, unmasked: a command's own arguments first, then `arguments`.
    var argumentLines: [String] {
        (config.cli?.arguments ?? []) + config.arguments
    }

    /// Every environment variable as `NAME=value`, sorted by name. Values are never masked here: a planted secret
    /// or `DYLD_INSERT_LIBRARIES` must be visible before it is signed as the user's own.
    var environmentLines: [String] {
        config.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    var dataPathDescription: String {
        config.dataPath ?? "Default"
    }

    var eraseOnQuitDescription: String {
        config.eraseOnQuit ? "On" : "Off"
    }

    /// The signer line: the certificate's display name, or why there is none.
    var signerDescription: String {
        switch signature {
        case .identity(let name): return name
        case .adHoc: return "Ad hoc (no signing identity)"
        case .unknown: return "Unsigned, or the signature could not be read"
        }
    }
}

// MARK: - Review rows (S2)

extension ForeignShortcutApproval {
    /// One labelled block of the review: what the sheets render for a config field (or a few related ones).
    struct ReviewRow: Identifiable, Equatable {
        /// Unique within `reviewRows`.
        let label: String
        /// The value, unmasked and untruncated; an empty list means the field is unset and is shown as "None".
        let lines: [String]
        /// True when the value is what a fresh shortcut of this kind would have, so a long list may leave it out.
        let isDefault: Bool
        /// The stored config keys this row shows, nested ones prefixed (`cli.workingDirectory`, `webApp.userAgent`).
        let configKeys: [String]

        var id: String { label }
    }

    /// Rows `LegacyTrustReviewSheet` lists for every shortcut; its other rows appear only when they hold a set value.
    static let alwaysListedLabels: [String] = ["Name", "Kind", "Target"]

    /// Every field of the config that is going to be signed, in review order. The only source of what the sheets show.
    var reviewRows: [ReviewRow] {
        Self.rowSpecs.compactMap { $0.row(for: self) }
    }

    /// `reviewRows` for a list of many shortcuts: the always-listed rows, then any row that holds a set value.
    var legacyReviewRows: [ReviewRow] {
        reviewRows.filter { Self.alwaysListedLabels.contains($0.label) || !$0.isDefault }
    }

    /// Config keys the rows show; the coverage test compares it with every key `DuplicatorCore` can store.
    static let reviewedConfigKeys: Set<String> = Set(rowSpecs.flatMap(\.configKeys))

    /// Config keys the sheets deliberately do not show, each with the reason.
    static let unreviewedConfigKeys: [String: String] = [
        "engineVersion": "Rewritten by the rebuild itself to the current engine version; it selects no behavior of its own.",
    ]

    private struct RowSpec {
        let label: String
        let configKeys: [String]
        /// The row's lines and default flag, or nil when the row does not apply to this config.
        let value: (ForeignShortcutApproval) -> (lines: [String], isDefault: Bool)?

        func row(for approval: ForeignShortcutApproval) -> ReviewRow? {
            guard let result = value(approval) else { return nil }
            return ReviewRow(label: label, lines: result.lines, isDefault: result.isDefault, configKeys: configKeys)
        }
    }

    private static func on(_ flag: Bool) -> String { flag ? "On" : "Off" }

    /// A set-or-nil text field: no lines when unset.
    private static func optional(_ text: String?) -> (lines: [String], isDefault: Bool) {
        guard let text, !text.isEmpty else { return ([], true) }
        return ([text], false)
    }

    private static var rowSpecs: [RowSpec] {
        [
            RowSpec(label: "Name", configKeys: ["name"]) { ([$0.config.name], false) },
            RowSpec(label: "Kind", configKeys: ["kind"]) { ([$0.kindDescription], false) },
            RowSpec(label: "Target", configKeys: ["targetPath", "webApp.url", "file.path", "file.openerAppPath", "cli.executablePath"]) {
                ([$0.targetDescription], false)
            },
            // Only a web, file or command shortcut can store a path that `targetDescription` does not show.
            RowSpec(label: "Stored target path", configKeys: ["targetPath"]) { approval in
                let path = approval.config.targetPath
                guard approval.config.kind != .app, !path.isEmpty, path != approval.targetDescription else { return nil }
                return ([path], false)
            },
            RowSpec(label: "Target bundle identifier", configKeys: ["targetBundleIdentifier"]) { optional($0.config.targetBundleIdentifier) },
            RowSpec(label: "Bundle identifier", configKeys: ["bundleIdentifier"]) {
                ([$0.config.bundleIdentifier], $0.config.bundleIdentifier == ShortcutConfig.bundleIdentifier(forSlug: $0.config.slug))
            },
            RowSpec(label: "Slug", configKeys: ["slug"]) {
                ([$0.config.slug], $0.config.slug == ShortcutConfig.slug(for: $0.config.name))
            },
            RowSpec(label: "Launch mode", configKeys: ["launchMode"]) { ([$0.config.launchMode.rawValue], $0.config.launchMode == .dockShortcut) },
            RowSpec(label: "Data mode", configKeys: ["dataMode"]) {
                // A web app has no data folder to separate, so `disabled` is what it is built with.
                ([$0.config.dataMode.rawValue], $0.config.dataMode == ($0.config.kind == .webApp ? .disabled : .auto))
            },
            RowSpec(label: "Arguments", configKeys: ["cli.arguments", "arguments"]) { ($0.argumentLines, $0.argumentLines.isEmpty) },
            RowSpec(label: "Environment", configKeys: ["environment"]) { ($0.environmentLines, $0.config.environment.isEmpty) },
            RowSpec(label: "Data path", configKeys: ["dataPath"]) { ([$0.dataPathDescription], $0.config.dataPath == nil) },
            RowSpec(label: "Erase on quit", configKeys: ["eraseOnQuit"]) { ([$0.eraseOnQuitDescription], !$0.config.eraseOnQuit) },
            RowSpec(label: "Menu bar icon", configKeys: ["menuBarIcon"]) { ([on($0.config.menuBarIcon)], !$0.config.menuBarIcon) },
            RowSpec(label: "New Window command", configKeys: ["newWindowCommand"]) { $0.newWindowCommandValue },
            RowSpec(label: "Appearance", configKeys: ["appearance"]) { ([$0.config.appearance.rawValue], $0.config.appearance == .system) },
            RowSpec(label: "Language", configKeys: ["languageCode"]) {
                guard let code = $0.config.languageCode else { return (["Default"], true) }
                return ([code], false)
            },
            RowSpec(label: "Icon", configKeys: ["iconMode"]) { ([$0.config.iconMode.rawValue], $0.config.iconMode == .copied) },
            RowSpec(label: "Custom icon path", configKeys: ["customIconPath"]) { optional($0.config.customIconPath) },
            RowSpec(label: "Home symlinks", configKeys: ["homeSymlinkEntries"]) {
                // nil keeps the built-in list; an empty list is a different, explicit choice.
                guard let entries = $0.config.homeSymlinkEntries else { return (["Default"], true) }
                return (entries.isEmpty ? ["None (an empty list)"] : entries, false)
            },
            RowSpec(label: "Working directory", configKeys: ["cli.workingDirectory"]) { approval in
                approval.config.cli.map { optional($0.workingDirectory) }
            },
            RowSpec(label: "Terminal", configKeys: ["cli.terminal"]) { approval in
                approval.config.cli.map { ([$0.terminal.rawValue], $0.terminal == .terminal) }
            },
            RowSpec(label: "Home override", configKeys: ["cli.homeOverride"]) { approval in
                approval.config.cli.map { ([on($0.homeOverride)], !$0.homeOverride) }
            },
            RowSpec(label: "User agent", configKeys: ["webApp.userAgent"]) { approval in
                approval.config.webApp.map { ([$0.userAgent.rawValue], $0.userAgent == .safari) }
            },
            RowSpec(label: "Extra hosts", configKeys: ["webApp.extraHosts"]) { approval in
                approval.config.webApp.map { ($0.extraHosts, $0.extraHosts.isEmpty) }
            },
            RowSpec(label: "Badge pattern", configKeys: ["webApp.badgeRegex"]) { approval in
                approval.config.webApp.map { optional($0.badgeRegex) }
            },
            RowSpec(label: "Page zoom", configKeys: ["webApp.pageZoom"]) { approval in
                approval.config.webApp.map { (["\($0.pageZoom)"], $0.pageZoom == 1.0) }
            },
            RowSpec(label: "Keep running in menu bar", configKeys: ["webApp.backgroundMode"]) { approval in
                approval.config.webApp.map { ([on($0.backgroundMode)], !$0.backgroundMode) }
            },
            // The identifier of the web app's own logins container: sharing one with another shortcut shares its logins.
            RowSpec(label: "Website data store", configKeys: ["webApp.dataStoreID"]) { approval in
                approval.config.webApp.map { ([$0.dataStoreID.uuidString], false) }
            },
        ]
    }

    /// The New Window template as stored, then, when `HelperPlan` can render it, the argv the menu item would run.
    /// Rendering is pure string work (`NewWindowCommandBuilder` resolves nothing on disk and runs nothing); it uses the
    /// stored target path, where a launch uses the one `TargetResolver` finds at that time.
    private var newWindowCommandValue: (lines: [String], isDefault: Bool)? {
        guard let template = config.newWindowCommand, !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ([], true)
        }
        var lines = [template]
        if let argv = HelperPlan.newWindowArguments(for: config, targetPath: config.targetPath) {
            lines += argv.enumerated().map { "argv[\($0.offset)] = \($0.element)" }
        }
        return (lines, false)
    }
}
