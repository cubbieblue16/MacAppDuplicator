import Foundation

/// `codesign` failed. `message` is codesign's stderr (identities appear by display name only).
public struct SignerError: Error, LocalizedError, Equatable {
    public let status: Int32
    public let message: String

    public init(status: Int32, message: String) {
        self.status = status
        self.message = message
    }

    public var errorDescription: String? {
        "codesign failed with exit code \(status): \(message)"
    }
}

/// Signs shortcut bundles with `/usr/bin/codesign` (spec §3.1, §9). Never uses `--deep`.
public struct Signer {
    public init() {}

    /// Ad-hoc (`identity == nil`): `--force --sign -`.
    /// Identity: `--force --sign <identity> --options runtime --timestamp`.
    public static func arguments(bundle: URL, identity: String?) -> [String] {
        guard let identity else {
            return ["--force", "--sign", "-", bundle.path]
        }
        return ["--force", "--sign", identity, "--options", "runtime", "--timestamp", bundle.path]
    }

    public func sign(bundle: URL, identity: String?) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/codesign")
        process.arguments = Self.arguments(bundle: bundle, identity: identity)
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SignerError(status: process.terminationStatus, message: message)
        }
    }
}
