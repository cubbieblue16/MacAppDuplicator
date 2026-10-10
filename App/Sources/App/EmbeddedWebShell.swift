import Foundation

/// The Phase 4 `WebShell` binary copied into `Contents/Resources/WebShell` by the "Embed WebShell" build phase.
enum EmbeddedWebShell {
    enum Error: Swift.Error, LocalizedError {
        case missing

        var errorDescription: String? {
            "The embedded WebShell binary is missing from the app bundle. Rebuild with Tools/build-app.sh."
        }
    }

    /// URL of the embedded web shell; throws when the build phase did not run (for example a bare `swift build`).
    static func url() throws -> URL {
        guard let url = Bundle.main.url(forResource: "WebShell", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw Error.missing
        }
        return url
    }
}
