import DuplicatorCore
import Foundation

/// Turns `config.iconMode` into the `.icns` file BundleWriter copies into the shortcut (spec §7).
enum IconResolver {
    enum IconError: Error, LocalizedError {
        case customFileMissing(String)
        case renderFailed(String)

        var errorDescription: String? {
            switch self {
            case .customFileMissing(let path): "The custom icon file was not found: \(path)"
            case .renderFailed(let message): "The icon could not be rendered: \(message)"
            }
        }
    }

    /// - Returns: the target's own icon (`.copied`), a converted copy of `customIconPath` in `scratchDirectory` (`.custom`),
    ///   a generated tile in `scratchDirectory` (`.generated`), or nil when the target has no icon to copy.
    static func iconFile(for config: ShortcutConfig, app: InspectedApp, scratchDirectory: URL) throws -> URL? {
        switch config.iconMode {
        case .copied:
            return app.iconFileURL
        case .custom:
            guard let path = config.customIconPath, FileManager.default.fileExists(atPath: path) else {
                throw IconError.customFileMissing(config.customIconPath ?? "")
            }
            let out = scratchDirectory.appending(path: "\(config.slug)-custom.icns")
            do { try IconRenderer.writeICNS(fromImageFile: URL(fileURLWithPath: path), to: out) } catch {
                throw IconError.renderFailed(error.localizedDescription)
            }
            return out
        case .generated:
            let out = scratchDirectory.appending(path: "\(config.slug)-generated.icns")
            do { try IconRenderer.writeICNS(generatedFor: config.name, to: out) } catch {
                throw IconError.renderFailed(error.localizedDescription)
            }
            return out
        }
    }
}
