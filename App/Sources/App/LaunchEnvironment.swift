import Foundation

/// How the process was launched, for the choices `MacAppDuplicatorApp.init` makes (final review M15).
enum LaunchEnvironment {
    /// The UserDefaults suite the app uses while it hosts the unit tests, so the test host never reads or writes the
    /// real preferences (`UserDefaults.standard`, domain `com.mikekuta.MacAppDuplicator`).
    static let testHostSuiteName = "com.mikekuta.MacAppDuplicator.testhost"

    /// xcodebuild sets `XCTestConfigurationFilePath` for the process that hosts the test bundle.
    static func isTestHost(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    /// `UserDefaults.standard` for a normal launch. Under the test host, the `suiteName` suite, emptied first so each
    /// test run starts from the built-in defaults.
    static func settingsDefaults(isTestHost: Bool, suiteName: String = testHostSuiteName) -> UserDefaults {
        guard isTestHost else { return .standard }
        guard let suite = UserDefaults(suiteName: suiteName) else {
            // `UserDefaults(suiteName:)` is nil only for the main bundle's identifier or NSGlobalDomain.
            preconditionFailure("UserDefaults(suiteName: \"\(suiteName)\") returned nil")
        }
        suite.removePersistentDomain(forName: suiteName)
        return suite
    }
}
