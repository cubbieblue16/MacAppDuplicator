import Foundation

/// Appends launcher events to `~/Library/Logs/App Duplicator/<Name>.log`, rotating at 1 MB (spec §4.7).
/// Logging never fails the launch: every file-system error is ignored.
public struct LaunchLogger: Sendable {
    /// Rotation threshold: 1 MB.
    public static let rotationThreshold = 1_048_576

    public let fileURL: URL
    let maxBytes: Int

    public init(name: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/App Duplicator", directoryHint: .isDirectory)
        self.init(name: name, directory: directory, maxBytes: LaunchLogger.rotationThreshold)
    }

    init(name: String, directory: URL, maxBytes: Int) {
        fileURL = directory.appending(path: ShortcutConfig.fileSystemName(for: name) + ".log", directoryHint: .notDirectory)
        self.maxBytes = maxBytes
    }

    /// The rotated file: `<Name>.log.1`.
    public var rotatedFileURL: URL {
        fileURL.deletingLastPathComponent().appending(path: fileURL.lastPathComponent + ".1", directoryHint: .notDirectory)
    }

    /// Appends `<ISO 8601 timestamp> <line>`.
    public func log(_ line: String) {
        append(Data("\(Date.now.ISO8601Format()) \(line)\n".utf8))
    }

    /// Logs one `env KEY=VALUE` line per variable, sorted by key, values masked per spec §2.
    public func log(environment: [String: String]) {
        let masked = SecretMasking.mask(environment)
        for key in masked.keys.sorted() {
            log("env \(key)=\(masked[key] ?? "")")
        }
    }

    private func append(_ data: Data) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let currentSize = ((try? fileManager.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber)?.intValue ?? 0
        if currentSize > 0, currentSize + data.count > maxBytes {
            try? fileManager.removeItem(at: rotatedFileURL)
            try? fileManager.moveItem(at: fileURL, to: rotatedFileURL)
        }
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
