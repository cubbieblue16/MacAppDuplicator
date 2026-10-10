import DuplicatorCore
import Foundation
import os

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

    private static let logger = Logger(subsystem: "com.mikekuta.MacAppDuplicator", category: "IconResolver")

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
            // Fixed scratch names: the scratch directory is already per build, and a slug from a hand-edited config
            // (for example one containing "../") must never steer where the file is written.
            let out = scratchDirectory.appending(path: "custom-icon.icns")
            do { try IconRenderer.writeICNS(fromImageFile: URL(fileURLWithPath: path), to: out) } catch {
                throw IconError.renderFailed(error.localizedDescription)
            }
            return out
        case .generated:
            let out = scratchDirectory.appending(path: "generated-icon.icns")
            do { try IconRenderer.writeICNS(generatedFor: config.name, to: out) } catch {
                throw IconError.renderFailed(error.localizedDescription)
            }
            return out
        }
    }

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
}
