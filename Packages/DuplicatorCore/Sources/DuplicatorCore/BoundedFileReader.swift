import Foundation

/// Reads a file into memory with a hard size cap, so a huge or endless file (a sparse file, a device node a symlink
/// points at) cannot exhaust memory the way `Data(contentsOf:)` can.
public enum BoundedFileReader {
    public struct TooLarge: Error, LocalizedError, Equatable {
        public let path: String
        public let maxBytes: Int

        public var errorDescription: String? {
            "\(path) is larger than \(maxBytes / 1_048_576) MiB."
        }
    }

    /// The cap used for icon sources: far above any real icon, far below a memory problem.
    public static let defaultMaxBytes = 16 * 1_048_576

    /// The contents of `url` (symlinks followed, as `Data(contentsOf:)` does). Throws `TooLarge` when the file is
    /// longer than `maxBytes`; reads at most `maxBytes + 1` bytes either way.
    public static func read(_ url: URL, maxBytes: Int = defaultMaxBytes) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maxBytes {
            guard let chunk = try handle.read(upToCount: min(1_048_576, maxBytes + 1 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maxBytes else { throw TooLarge(path: url.path, maxBytes: maxBytes) }
        return data
    }
}
