import Foundation

/// File and folder shortcut settings (spec §6). Set exactly when `ShortcutConfig.kind` is `.file` or `.folder`.
public struct FileConfig: Codable, Hashable, Sendable {
    /// Absolute path of the file or folder the shortcut opens.
    public var path: String
    /// Absolute path of the app that opens `path`; nil opens it with its default handler (`NSWorkspace.open`).
    public var openerAppPath: String?

    public init(path: String, openerAppPath: String? = nil) {
        self.path = path
        self.openerAppPath = openerAppPath
    }

    /// `raw` with a leading `~` expanded, `.` and `..` components removed (lexically, the file system is not
    /// consulted) and trailing `/` stripped. `"/"` stays `"/"`; a relative path only loses its trailing `/`.
    public static func normalizedPath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let standardized = expanded.hasPrefix("/") ? URL(filePath: expanded).standardized.path : expanded
        var path = standardized
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
