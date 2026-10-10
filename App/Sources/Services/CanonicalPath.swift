import Foundation

/// An absolute path in the form used to compare locations: standardized (`.` and `..` removed), with symlinks resolved
/// by `realpath(3)` along its longest existing prefix (so `/var/…` and `/private/var/…` match, and a link to a
/// protected folder is seen as that folder). Components compare case- and Unicode-normalization-insensitively,
/// matching the default APFS volume; on a case-sensitive volume this can only make a guard refuse more, never less.
struct CanonicalPath {
    /// The resolved path, used for display and for the file operation that follows the check.
    let path: String
    private let folded: [String]

    /// `path` must be absolute; a relative path is resolved against the working directory like any file URL.
    init(_ path: String) {
        let resolved = Self.resolve(URL(fileURLWithPath: path).standardizedFileURL.path)
        self.path = resolved
        folded = resolved.split(separator: "/").map { $0.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil) }
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// Number of components below `/` (0 for `/` itself).
    var depth: Int { folded.count }

    func isSame(as other: CanonicalPath) -> Bool { folded == other.folded }

    /// Strictly inside `other`.
    func isInside(_ other: CanonicalPath) -> Bool {
        folded.count > other.folded.count && Array(folded.prefix(other.folded.count)) == other.folded
    }

    /// Equal to, inside, or containing `other`.
    func overlaps(_ other: CanonicalPath) -> Bool { isSame(as: other) || isInside(other) || other.isInside(self) }

    func appending(_ relativePath: String) -> CanonicalPath { CanonicalPath(path + "/" + relativePath) }

    private static func resolve(_ standardized: String) -> String {
        var prefix = standardized
        var missing: [String] = []
        while true {
            if let resolved = realpath(prefix, nil) {
                defer { free(resolved) }
                var path = String(cString: resolved)
                for component in missing.reversed() { path = (path as NSString).appendingPathComponent(component) }
                return path
            }
            let parent = (prefix as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != prefix else { return standardized }
            missing.append((prefix as NSString).lastPathComponent)
            prefix = parent
        }
    }
}
