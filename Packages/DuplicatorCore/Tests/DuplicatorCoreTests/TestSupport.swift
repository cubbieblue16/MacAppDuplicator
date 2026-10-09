import Foundation
import XCTest

extension XCTestCase {
    /// A new empty directory under the system temporary directory, deleted when the test ends.
    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "DuplicatorCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

/// Exit status and combined stdout + stderr of a finished command.
struct CommandResult {
    var status: Int32
    var output: String
}

/// Runs `path` with `arguments` to completion.
func runCommand(_ path: String, _ arguments: [String]) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(filePath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

struct FixtureError: Error, CustomStringConvertible {
    var description: String
}

/// A minimal `.app` tree for unit tests: Info.plist, an empty executable and optional marker files (spec §4.2).
struct FixtureBundle {
    var name = "Fixture"
    var bundleIdentifier = "com.example.fixture"
    /// Extra Info.plist keys, merged over the generated ones.
    var info: [String: Any] = [:]
    /// Empty files to create, relative to `Contents/`.
    var files: [String] = []
    /// Directories to create, relative to `Contents/`.
    var directories: [String] = []

    /// Writes `<directory>/<name>.app` and returns its URL.
    @discardableResult
    func write(in directory: URL) throws -> URL {
        let fileManager = FileManager.default
        let bundle = directory.appending(path: "\(name).app", directoryHint: .isDirectory)
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: contents.appending(path: "MacOS", directoryHint: .isDirectory), withIntermediateDirectories: true)

        var plist: [String: Any] = [
            "CFBundleExecutable": name,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundlePackageType": "APPL",
        ]
        plist.merge(info) { _, extra in extra }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist", directoryHint: .notDirectory))

        let executable = contents.appending(path: "MacOS/\(name)", directoryHint: .notDirectory)
        try Data().write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        for relativePath in directories {
            try fileManager.createDirectory(at: contents.appending(path: relativePath, directoryHint: .isDirectory), withIntermediateDirectories: true)
        }
        for relativePath in files {
            let file = contents.appending(path: relativePath, directoryHint: .notDirectory)
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        return bundle
    }

    /// Writes the bundle with a copy of `/usr/bin/true` as its executable, then ad-hoc signs it with
    /// `codesign --force --sign - <extraCodesignArguments> <bundle>`. The re-signed copy is not a platform binary.
    @discardableResult
    func writeSigned(in directory: URL, extraCodesignArguments: [String] = []) throws -> URL {
        let bundle = try write(in: directory)
        let executable = bundle.appending(path: "Contents/MacOS/\(name)", directoryHint: .notDirectory)
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: executable)
        let result = try runCommand("/usr/bin/codesign", ["--force", "--sign", "-"] + extraCodesignArguments + [bundle.path])
        guard result.status == 0 else {
            throw FixtureError(description: "codesign failed (\(result.status)): \(result.output)")
        }
        return bundle
    }
}

/// Writes `dictionary` as an XML property list at `<directory>/<fileName>` and returns its URL.
func writePropertyList(_ dictionary: [String: Any], named fileName: String, in directory: URL) throws -> URL {
    let url = directory.appending(path: fileName, directoryHint: .notDirectory)
    try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: url)
    return url
}
