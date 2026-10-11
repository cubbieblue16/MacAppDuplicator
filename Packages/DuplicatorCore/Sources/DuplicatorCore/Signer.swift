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
    /// Entitlements for a command shortcut that opens Terminal.app or iTerm2 through `osascript` (spec §6): the hardened
    /// runtime that identity signing turns on (`--options runtime`) refuses Apple Events without this entitlement.
    public static let appleEventsEntitlements = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.security.automation.apple-events</key>
            <true/>
        </dict>
        </plist>

        """

    public init() {}

    /// Ad-hoc (`identity == nil`): `--force --sign -`; `entitlements` is ignored.
    /// Identity: `--force --sign <identity> --options runtime --timestamp`, plus `--entitlements <path>` when
    /// `entitlements` is set. The bundle path is always last.
    public static func arguments(bundle: URL, identity: String?, entitlements: URL? = nil) -> [String] {
        guard let identity else {
            return ["--force", "--sign", "-", bundle.path]
        }
        var arguments = ["--force", "--sign", identity, "--options", "runtime", "--timestamp"]
        if let entitlements {
            arguments += ["--entitlements", entitlements.path]
        }
        return arguments + [bundle.path]
    }

    /// - Parameter needsAppleEvents: with an identity, signs with `appleEventsEntitlements`, written to a temporary file
    ///   for the `codesign` run. Ignored for ad-hoc signing, which has no hardened runtime and needs no entitlement.
    public func sign(bundle: URL, identity: String?, needsAppleEvents: Bool = false) throws {
        guard let identity, needsAppleEvents else {
            return try runCodesign(arguments: Self.arguments(bundle: bundle, identity: identity))
        }
        try Self.withAppleEventsEntitlementsFile { entitlements in
            try runCodesign(arguments: Self.arguments(bundle: bundle, identity: identity, entitlements: entitlements))
        }
    }

    /// Writes `appleEventsEntitlements` to a new file in the temporary directory, runs `body` with its URL, then removes
    /// the file, also when `body` throws. `body`'s error wins over a removal error.
    static func withAppleEventsEntitlementsFile(_ body: (URL) throws -> Void) throws {
        let fileManager = FileManager.default
        let entitlements = fileManager.temporaryDirectory
            .appending(path: "mad-entitlements-\(UUID().uuidString).plist", directoryHint: .notDirectory)
        try Data(appleEventsEntitlements.utf8).write(to: entitlements)
        let outcome = Result { try body(entitlements) }
        let removal = Result { try fileManager.removeItem(at: entitlements) }
        try outcome.get()
        try removal.get()
    }

    private func runCodesign(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/codesign")
        process.arguments = arguments
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
