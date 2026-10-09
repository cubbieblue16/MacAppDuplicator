import Foundation

/// The Phase 1 `Launcher` binary copied into `Contents/Resources/Launcher` by the "Embed Launcher" build phase.
enum EmbeddedLauncher {
    enum Error: Swift.Error, LocalizedError {
        case missing
        var errorDescription: String? {
            "The embedded Launcher binary is missing from the app bundle. Rebuild with Tools/build-app.sh."
        }
    }

    /// URL of the embedded launcher; throws when the build phase did not run (for example a bare `swift build`).
    static func url() throws -> URL {
        guard let url = Bundle.main.url(forResource: "Launcher", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw Error.missing
        }
        return url
    }
}
