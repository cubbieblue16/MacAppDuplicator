import DuplicatorCore
import Foundation

/// What the editor's icon preview draws (final review M4): the draft's icon, not only the one saved in the bundle.
/// The saved `AppIcon.icns` is shown while the draft's icon inputs still match the saved config, because it is exactly
/// what Save would write again; any change to those inputs previews from the draft instead.
enum IconPreviewSource: Equatable, Sendable {
    /// Draw the image file at this URL (`.icns`, `.png`, `.jpeg` or `.tiff`).
    case file(URL)
    /// Draw `IconRenderer.generatedTile(initials:size:)` for these initials.
    case generated(initials: String)
    /// Nothing to draw: custom mode without a file, or a target with no icon file (or not inspected yet).
    case placeholder

    /// - Parameters:
    ///   - draft: the editor's unsaved config.
    ///   - saved: the config the bundle was last written with (`ShortcutRecord.config`).
    ///   - savedIconURL: the bundle's `AppIcon.icns` (`ShortcutRecord.iconURL`), nil when it has none.
    ///   - targetIconURL: `InspectedApp.iconFileURL` of the draft's target, nil while it is inspected or when it has none.
    static func resolve(draft: ShortcutConfig, saved: ShortcutConfig, savedIconURL: URL?, targetIconURL: URL?) -> IconPreviewSource {
        if let savedIconURL, iconInputsMatch(draft, saved) { return .file(savedIconURL) }
        switch draft.iconMode {
        case .copied:
            guard let targetIconURL else { return .placeholder }
            return .file(targetIconURL)
        case .custom:
            guard let path = draft.customIconPath, !path.isEmpty else { return .placeholder }
            return .file(URL(fileURLWithPath: path))
        case .generated:
            return .generated(initials: IconRenderer.initials(for: draft.name))
        }
    }

    /// True when Save would render the icon the bundle already has: the same mode and the same input for that mode
    /// (the target for `.copied`, the file for `.custom`, the initials for `.generated`).
    private static func iconInputsMatch(_ draft: ShortcutConfig, _ saved: ShortcutConfig) -> Bool {
        guard draft.iconMode == saved.iconMode else { return false }
        switch draft.iconMode {
        case .copied: return draft.targetPath == saved.targetPath
        case .custom: return draft.customIconPath == saved.customIconPath
        case .generated: return IconRenderer.initials(for: draft.name) == IconRenderer.initials(for: saved.name)
        }
    }
}
