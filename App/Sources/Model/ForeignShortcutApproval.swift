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
