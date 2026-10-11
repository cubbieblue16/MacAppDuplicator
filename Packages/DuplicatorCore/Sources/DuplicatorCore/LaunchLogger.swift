import Darwin
import Foundation

/// Appends launcher and helper events to `~/Library/Logs/App Duplicator/<Name>.log`, rotating at 1 MB (spec §4.7).
/// Logging never fails the launch: every file-system error is ignored. Each line is one `write(2)` on an `O_APPEND`
/// descriptor, so the launcher, its helper and concurrent threads never overwrite each other's lines.
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

    /// Logs `argv <arguments>` on one line, secret values masked per `SecretMasking.maskArguments`.
    public func log(arguments: [String]) {
        log("argv \(SecretMasking.maskArguments(arguments).joined(separator: " "))")
    }

    private func append(_ data: Data) {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return // Logging never fails the launch.
            }
        }
        var info = stat()
        if stat(fileURL.path, &info) == 0, info.st_size > 0, Int(info.st_size) + data.count > maxBytes {
            // One step that replaces any previous `.log.1`; if it fails the file keeps growing.
            _ = rename(fileURL.path, rotatedFileURL.path)
        }
        let descriptor = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            return
        }
        defer { close(descriptor) }
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}
