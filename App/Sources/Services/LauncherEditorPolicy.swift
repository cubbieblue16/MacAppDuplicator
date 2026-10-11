import DuplicatorCore
import Foundation

/// The editor rules for file, folder and command shortcuts, kept out of the views so they are unit-tested (mirrors
/// `WebEditorPolicy`).
nonisolated enum LauncherEditorPolicy {
    static func isLauncherKind(_ kind: ShortcutKind) -> Bool {
        kind == .file || kind == .folder || kind == .cli
    }

    /// The config Save writes for a launcher. It trims the name and keeps the saved slug and bundle identifier (a
    /// command's own HOME is filed under the slug), re-applies the launcher invariants (no target, Dock Shortcut,
    /// data Disabled), keeps only the sub-config of the kind, and cleans the fields: a normalized item path, a blank
    /// opener as nil, a trimmed executable, a blank working directory as nil, trimmed arguments without empty ones.
    static func saveConfig(draft: ShortcutConfig, saved: ShortcutConfig) -> ShortcutConfig {
        var config = draft
        config.name = draft.name.trimmingCharacters(in: .whitespaces)
        config.slug = saved.slug
        config.bundleIdentifier = saved.bundleIdentifier
        config.targetPath = ""
        config.targetBundleIdentifier = ""
        config.launchMode = .dockShortcut
        config.dataMode = .disabled
        config.dataPath = nil
        config.webApp = nil
        switch draft.kind {
        case .file, .folder:
            config.cli = nil
            config.file = draft.file.map { file in
                FileConfig(path: FileConfig.normalizedPath(file.path), openerAppPath: blankToNil(file.openerAppPath).map(FileConfig.normalizedPath))
            }
        case .cli:
            config.file = nil
            config.cli = draft.cli.map { cli in
                CLIConfig(
                    executablePath: cli.executablePath.trimmingCharacters(in: .whitespaces),
                    arguments: cli.arguments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                    workingDirectory: blankToNil(cli.workingDirectory),
                    terminal: cli.terminal,
                    homeOverride: cli.homeOverride
                )
            }
        case .app, .webApp:
            break
        }
        return config
    }

    /// Why Save is not allowed, or nil. Only the shape of the path is checked; a missing item shows as "Item missing".
    static func validationMessage(for config: ShortcutConfig) -> String? {
        switch config.kind {
        case .file, .folder:
            let path = config.file?.path.trimmingCharacters(in: .whitespaces) ?? ""
            if path.isEmpty { return "Choose the file or folder this shortcut opens." }
            return path.hasPrefix("/") ? nil : "Use a full path that starts with /."
        case .cli:
            let path = config.cli?.executablePath.trimmingCharacters(in: .whitespaces) ?? ""
            if path.isEmpty { return "Enter the program to run." }
            return path.hasPrefix("/") ? nil : "Use a full path that starts with /."
        case .app, .webApp:
            return nil
        }
    }

    static func iconLabel(_ mode: IconMode, kind: ShortcutKind) -> String {
        switch mode {
        case .copied:
            switch kind {
            case .file, .folder: "Copied from item"
            case .cli: "Copied from executable"
            case .webApp: "Fetched from site"
            case .app: "Copied from target"
            }
        case .custom: "Custom file"
        case .generated: "Generated tile"
        }
    }

    /// The library row's subtitle: the item's or the executable's last path component.
    static func subtitle(for config: ShortcutConfig) -> String {
        switch config.kind {
        case .file, .folder: config.file.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? ""
        case .cli: config.cli.map { URL(fileURLWithPath: $0.executablePath).lastPathComponent } ?? ""
        case .app, .webApp: ""
        }
    }

    /// A command's own HOME folder when it has one (`cli.homeOverride`), else nil. Also nil for a slug that
    /// `ShortcutConfig.isValidSlug` refuses, so such a slug never becomes a path.
    static func commandHomePath(for config: ShortcutConfig, home: URL) -> String? {
        guard config.kind == .cli, config.cli?.homeOverride == true, ShortcutConfig.isValidSlug(config.slug) else { return nil }
        return ShortcutConfig.defaultDataPath(forSlug: config.slug, home: home)
    }

    private static func blankToNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
