import XCTest
@testable import DuplicatorCore

final class LauncherActionPlannerTests: XCTestCase {
    private static let installed: @Sendable (TerminalChoice) -> URL? = { choice in
        switch choice {
        case .none:
            return nil
        case .terminal:
            return URL(filePath: "/System/Applications/Utilities/Terminal.app", directoryHint: .isDirectory)
        case .iterm2:
            return URL(filePath: "/Applications/iTerm.app", directoryHint: .isDirectory)
        case .ghostty:
            return URL(filePath: "/Applications/Ghostty.app", directoryHint: .isDirectory)
        }
    }

    private static let nothingInstalled: @Sendable (TerminalChoice) -> URL? = { _ in nil }

    private func makeConfig(
        kind: ShortcutKind,
        file: FileConfig? = nil,
        cli: CLIConfig? = nil,
        environment: [String: String] = [:]
    ) -> ShortcutConfig {
        ShortcutConfig(
            kind: kind,
            name: "Projects",
            slug: "projects",
            bundleIdentifier: "com.mikekuta.appduplicator.projects",
            targetPath: "",
            targetBundleIdentifier: "",
            dataMode: .disabled,
            environment: environment,
            file: file,
            cli: cli
        )
    }

    private func makePlanner(
        realHome: URL,
        locator: @escaping @Sendable (TerminalChoice) -> URL? = LauncherActionPlannerTests.installed
    ) -> LauncherActionPlanner {
        LauncherActionPlanner(realHome: realHome, terminalLocator: locator)
    }

    private func assertLauncherError(
        _ expression: @autoclosure () throws -> LauncherAction,
        file: StaticString = #filePath,
        line: UInt = #line,
        matches: (LauncherError) -> Bool
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let launcherError = error as? LauncherError else {
                return XCTFail("expected LauncherError, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(matches(launcherError), "unexpected error: \(launcherError)", file: file, line: line)
        }
    }

    // MARK: File and folder shortcuts

    func testFileShortcutOpensThePathWithTheDefaultHandler() throws {
        let root = try makeTemporaryDirectory()
        let report = root.appending(path: "Report.pdf")
        try Data("pdf".utf8).write(to: report)
        let config = makeConfig(kind: .file, file: FileConfig(path: report.path))

        let action = try makePlanner(realHome: root).plan(config: config, baseEnvironment: [:], shortcutBundleURL: nil)

        XCTAssertEqual(action, .open(items: [URL(filePath: report.path, directoryHint: .checkFileSystem)], openerApp: nil))
    }

    func testFolderShortcutStripsTheTrailingSlashAndKeepsTheOpener() throws {
        let root = try makeTemporaryDirectory()
        let folder = root.appending(path: "Projects", directoryHint: .isDirectory)
        let opener = root.appending(path: "Opener.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: opener, withIntermediateDirectories: true)
        let config = makeConfig(kind: .folder, file: FileConfig(path: folder.path + "/", openerAppPath: opener.path))

        let action = try makePlanner(realHome: root).plan(config: config, baseEnvironment: [:], shortcutBundleURL: nil)

        XCTAssertEqual(
            action,
            .open(
                items: [URL(filePath: folder.path, directoryHint: .checkFileSystem)],
                openerApp: URL(filePath: opener.path, directoryHint: .isDirectory)
            )
        )
    }

    func testMissingFileOrOpenerThrowsFileNotFound() throws {
        let root = try makeTemporaryDirectory()
        let missing = root.appending(path: "Missing.txt").path
        let planner = makePlanner(realHome: root)
        assertLauncherError(
            try planner.plan(config: makeConfig(kind: .file, file: FileConfig(path: missing)), baseEnvironment: [:], shortcutBundleURL: nil)
        ) { error in
            if case .fileNotFound(let path) = error { return path == missing }
            return false
        }

        let missingOpener = root.appending(path: "Nope.app").path
        let config = makeConfig(kind: .folder, file: FileConfig(path: root.path, openerAppPath: missingOpener))
        assertLauncherError(try planner.plan(config: config, baseEnvironment: [:], shortcutBundleURL: nil)) { error in
            if case .fileNotFound(let path) = error { return path == missingOpener }
            return false
        }
    }

    func testMissingSubConfigThrowsLauncherConfigMissing() throws {
        let planner = makePlanner(realHome: try makeTemporaryDirectory())
        for kind in [ShortcutKind.file, ShortcutKind.folder, ShortcutKind.cli] {
            assertLauncherError(try planner.plan(config: makeConfig(kind: kind), baseEnvironment: [:], shortcutBundleURL: nil)) { error in
                if case .launcherConfigMissing(let reported) = error { return reported == kind }
                return false
            }
        }
    }

    func testAppAndWebAppAreNotLauncherKinds() throws {
        let planner = makePlanner(realHome: try makeTemporaryDirectory())
        for kind in [ShortcutKind.app, ShortcutKind.webApp] {
            assertLauncherError(try planner.plan(config: makeConfig(kind: kind), baseEnvironment: [:], shortcutBundleURL: nil)) { error in
                if case .configCorrupt(let detail) = error { return detail == "\(kind.rawValue) is not a launcher kind" }
                return false
            }
        }
    }

    // MARK: Command shortcuts

    func testDetachedCommandGetsTheShortcutEnvironment() throws {
        let root = try makeTemporaryDirectory()
        let cli = CLIConfig(executablePath: "/bin/sh", arguments: ["-c", "env"], workingDirectory: root.path, terminal: TerminalChoice.none)
        let config = makeConfig(kind: .cli, cli: cli, environment: ["PATH": "/opt/bin", "API_TOKEN": "secret"])
        let base = ["PATH": "/usr/bin", "LANG": "en_US.UTF-8", "MAD_TARGET": "stale", "MAD_SHORTCUT_NAME": "Stale"]

        let action = try makePlanner(realHome: root).plan(
            config: config,
            baseEnvironment: base,
            shortcutBundleURL: URL(filePath: "/Applications/Projects.app", directoryHint: .isDirectory)
        )

        XCTAssertEqual(
            action,
            .spawn(
                executable: URL(filePath: "/bin/sh", directoryHint: .notDirectory),
                arguments: ["-c", "env"],
                environment: [
                    "PATH": "/opt/bin",
                    "LANG": "en_US.UTF-8",
                    "API_TOKEN": "secret",
                    "MAD_SHORTCUT_NAME": "Projects",
                    "MAD_SHORTCUT_BUNDLE": "/Applications/Projects.app",
                ],
                workingDirectory: URL(filePath: root.path, directoryHint: .isDirectory),
                terminal: TerminalChoice.none
            )
        )
    }

    func testTildeWorkingDirectoryIsExpandedAndNilBundleIsLeftOut() throws {
        let cli = CLIConfig(executablePath: "/bin/ls", workingDirectory: "~", terminal: TerminalChoice.none)

        let action = try makePlanner(realHome: try makeTemporaryDirectory())
            .plan(config: makeConfig(kind: .cli, cli: cli), baseEnvironment: [:], shortcutBundleURL: nil)

        XCTAssertEqual(
            action,
            .spawn(
                executable: URL(filePath: "/bin/ls", directoryHint: .notDirectory),
                arguments: [],
                environment: ["MAD_SHORTCUT_NAME": "Projects"],
                workingDirectory: URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory),
                terminal: TerminalChoice.none
            )
        )
    }

    func testMissingOrUnusableExecutableThrowsFileNotFound() throws {
        let root = try makeTemporaryDirectory()
        let script = root.appending(path: "tool.sh")
        try Data("echo hi\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
        let planner = makePlanner(realHome: root)

        for path in [root.appending(path: "missing-tool").path, script.path, root.path] {
            let config = makeConfig(kind: .cli, cli: CLIConfig(executablePath: path, terminal: TerminalChoice.none))
            assertLauncherError(try planner.plan(config: config, baseEnvironment: [:], shortcutBundleURL: nil)) { error in
                if case .fileNotFound(let reported) = error { return reported == path }
                return false
            }
        }
    }

    func testMissingWorkingDirectoryThrowsFileNotFound() throws {
        let root = try makeTemporaryDirectory()
        let missing = root.appending(path: "gone").path
        let config = makeConfig(kind: .cli, cli: CLIConfig(executablePath: "/bin/ls", workingDirectory: missing, terminal: TerminalChoice.none))

        assertLauncherError(try makePlanner(realHome: root).plan(config: config, baseEnvironment: [:], shortcutBundleURL: nil)) { error in
            if case .fileNotFound(let path) = error { return path == missing }
            return false
        }
    }

    func testTerminalChoiceRunsOsascriptAndTheScriptChangesDirectory() throws {
        let root = try makeTemporaryDirectory()
        let cli = CLIConfig(executablePath: "/usr/bin/top", arguments: ["-o", "cpu"], workingDirectory: root.path, terminal: .terminal)

        let action = try makePlanner(realHome: root).plan(config: makeConfig(kind: .cli, cli: cli), baseEnvironment: [:], shortcutBundleURL: nil)

        XCTAssertEqual(
            action,
            .spawn(
                executable: URL(filePath: "/usr/bin/osascript", directoryHint: .notDirectory),
                arguments: ["-e", TerminalCommandBuilder.terminalScript(
                    command: "/usr/bin/env 'MAD_SHORTCUT_NAME=Projects' '/usr/bin/top' '-o' 'cpu'",
                    workingDirectory: root.path
                )],
                environment: ["MAD_SHORTCUT_NAME": "Projects"],
                workingDirectory: nil,
                terminal: .terminal
            )
        )
    }

    func testGhosttyRunsItsBinaryAndKeepsTheWorkingDirectory() throws {
        let root = try makeTemporaryDirectory()
        let cli = CLIConfig(executablePath: "/bin/ls", arguments: ["-la"], workingDirectory: root.path, terminal: .ghostty)

        let action = try makePlanner(realHome: root).plan(config: makeConfig(kind: .cli, cli: cli), baseEnvironment: [:], shortcutBundleURL: nil)

        XCTAssertEqual(
            action,
            .spawn(
                executable: URL(filePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty", directoryHint: .notDirectory),
                arguments: ["-e", "/bin/ls", "-la"],
                environment: ["MAD_SHORTCUT_NAME": "Projects"],
                workingDirectory: URL(filePath: root.path, directoryHint: .isDirectory),
                terminal: .ghostty
            )
        )
    }

    func testTerminalScriptCarriesTheWholeShortcutEnvironment() throws {
        let realHome = try makeTemporaryDirectory()
        let cli = CLIConfig(executablePath: "/usr/bin/top", terminal: .iterm2, homeOverride: true)
        let config = makeConfig(kind: .cli, cli: cli, environment: ["API_MODE": "fast mode"])
        let bundle = URL(filePath: "/Applications/Projects.app", directoryHint: .isDirectory)

        let action = try makePlanner(realHome: realHome).plan(config: config, baseEnvironment: ["PATH": "/usr/bin"], shortcutBundleURL: bundle)

        guard case .spawn(_, let arguments, let environment, _, _) = action else {
            return XCTFail("expected spawn, got \(action)")
        }
        let home = try XCTUnwrap(environment["HOME"])
        let command = "/usr/bin/env " + TerminalCommandBuilder.shellQuoted([
            "API_MODE=fast mode", "CFFIXED_USER_HOME=\(home)", "HOME=\(home)",
            "MAD_SHORTCUT_BUNDLE=/Applications/Projects.app", "MAD_SHORTCUT_NAME=Projects", "/usr/bin/top",
        ])
        XCTAssertEqual(arguments, ["-e", TerminalCommandBuilder.iTermScript(command: command, workingDirectory: nil)])
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["MAD_SHORTCUT_NAME"], "Projects")
        XCTAssertEqual(environment["API_MODE"], "fast mode")
    }

    func testUninstalledTerminalDoesNotCreateTheHomeFolder() throws {
        let realHome = try makeTemporaryDirectory()
        let planner = makePlanner(realHome: realHome, locator: LauncherActionPlannerTests.nothingInstalled)
        let config = makeConfig(kind: .cli, cli: CLIConfig(executablePath: "/usr/bin/top", terminal: .terminal, homeOverride: true))

        assertLauncherError(try planner.plan(config: config, baseEnvironment: [:], shortcutBundleURL: nil)) { error in
            if case .terminalNotFound(let choice) = error { return choice == .terminal }
            return false
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ShortcutConfig.defaultDataPath(forSlug: "projects", home: realHome)))
    }

    func testUninstalledTerminalThrowsTerminalNotFound() throws {
        let planner = makePlanner(realHome: try makeTemporaryDirectory(), locator: LauncherActionPlannerTests.nothingInstalled)
        let config = makeConfig(kind: .cli, cli: CLIConfig(executablePath: "/usr/bin/top", terminal: .iterm2))

        assertLauncherError(try planner.plan(config: config, baseEnvironment: [:], shortcutBundleURL: nil)) { error in
            if case .terminalNotFound(let choice) = error { return choice == .iterm2 }
            return false
        }
    }

    // MARK: HOME override (spec §4.3)

    func testHomeOverrideBuildsTheShortcutHomeTree() throws {
        let realHome = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: realHome.appending(path: "Documents"), withIntermediateDirectories: true)
        let cli = CLIConfig(executablePath: "/bin/ls", terminal: TerminalChoice.none, homeOverride: true)

        let action = try makePlanner(realHome: realHome).plan(config: makeConfig(kind: .cli, cli: cli), baseEnvironment: [:], shortcutBundleURL: nil)

        guard case .spawn(_, _, let environment, _, _) = action else {
            return XCTFail("expected spawn, got \(action)")
        }
        let home = URL(filePath: ShortcutConfig.defaultDataPath(forSlug: "projects", home: realHome)).standardizedFileURL.path
        XCTAssertEqual(environment["HOME"], home)
        XCTAssertEqual(environment["CFFIXED_USER_HOME"], home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/" + HomeTreeBuilder.markerFileName))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: home + "/Documents"),
            realHome.appending(path: "Documents").path
        )
    }

    func testHomeOverrideUsesAUserSubfolderWhenTheDataFolderIsNotEmpty() throws {
        let realHome = try makeTemporaryDirectory()
        let dataPath = URL(filePath: ShortcutConfig.defaultDataPath(forSlug: "projects", home: realHome), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dataPath, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: dataPath.appending(path: "notes.txt"))
        let cli = CLIConfig(executablePath: "/bin/ls", terminal: TerminalChoice.none, homeOverride: true)

        let action = try makePlanner(realHome: realHome).plan(config: makeConfig(kind: .cli, cli: cli), baseEnvironment: [:], shortcutBundleURL: nil)

        guard case .spawn(_, _, let environment, _, _) = action else {
            return XCTFail("expected spawn, got \(action)")
        }
        XCTAssertEqual(environment["HOME"], dataPath.standardizedFileURL.appending(path: NSUserName()).path)
    }

    func testHomeOverrideFailureThrowsDataPathNotWritable() throws {
        let realHome = try makeTemporaryDirectory()
        try Data().write(to: realHome.appending(path: "Library"))
        let cli = CLIConfig(executablePath: "/bin/ls", terminal: TerminalChoice.none, homeOverride: true)
        let expected = ShortcutConfig.defaultDataPath(forSlug: "projects", home: realHome)

        assertLauncherError(
            try makePlanner(realHome: realHome).plan(config: makeConfig(kind: .cli, cli: cli), baseEnvironment: [:], shortcutBundleURL: nil)
        ) { error in
            if case .dataPathNotWritable(let path) = error { return path == expected }
            return false
        }
    }

    func testShortcutEnvironmentWinsOverTheHomeOverride() throws {
        let realHome = try makeTemporaryDirectory()
        let cli = CLIConfig(executablePath: "/bin/ls", terminal: TerminalChoice.none, homeOverride: true)
        let config = makeConfig(kind: .cli, cli: cli, environment: ["HOME": "/Users/test/custom"])

        let action = try makePlanner(realHome: realHome).plan(config: config, baseEnvironment: ["HOME": "/Users/real"], shortcutBundleURL: nil)

        guard case .spawn(_, _, let environment, _, _) = action else {
            return XCTFail("expected spawn, got \(action)")
        }
        XCTAssertEqual(environment["HOME"], "/Users/test/custom")
        XCTAssertEqual(
            environment["CFFIXED_USER_HOME"],
            URL(filePath: ShortcutConfig.defaultDataPath(forSlug: "projects", home: realHome)).standardizedFileURL.path
        )
    }

    // MARK: LaunchPreparer.prepareShortcut

    func testPrepareShortcutSendsLauncherKindsToThePlanner() throws {
        let root = try makeTemporaryDirectory()
        let config = makeConfig(kind: .folder, file: FileConfig(path: root.path))

        let prepared = try LaunchPreparer(realHome: root).prepareShortcut(
            infoDictionary: [ShortcutConfig.infoPlistKey: config.plistDictionary()],
            shortcutBundleURL: URL(filePath: "/Applications/Projects.app", directoryHint: .isDirectory),
            baseEnvironment: [:],
            realHome: root,
            terminalLocator: LauncherActionPlannerTests.installed
        )

        guard case .launcher(let action, let decoded) = prepared else {
            return XCTFail("expected launcher, got \(prepared)")
        }
        XCTAssertEqual(action, .open(items: [URL(filePath: root.path, directoryHint: .checkFileSystem)], openerApp: nil))
        XCTAssertEqual(decoded, config)
    }

    func testPrepareShortcutKeepsTheAppPathUnchanged() throws {
        let root = try makeTemporaryDirectory()
        let target = try FixtureBundle(name: "Target").writeSigned(in: root)
        let config = ShortcutConfig(
            name: "Target Work",
            slug: "target-work",
            bundleIdentifier: "com.mikekuta.appduplicator.target-work",
            targetPath: target.path,
            targetBundleIdentifier: "com.example.fixture",
            dataMode: .disabled
        )
        let info: [String: Any] = [ShortcutConfig.infoPlistKey: config.plistDictionary()]
        let bundleURL = URL(filePath: "/Applications/Target Work.app", directoryHint: .isDirectory)
        let preparer = LaunchPreparer(realHome: root)

        let prepared = try preparer.prepareShortcut(
            infoDictionary: info,
            shortcutBundleURL: bundleURL,
            baseEnvironment: ["PATH": "/usr/bin"],
            realHome: root,
            terminalLocator: LauncherActionPlannerTests.nothingInstalled
        )

        guard case .app(let launch) = prepared else {
            return XCTFail("expected app, got \(prepared)")
        }
        XCTAssertEqual(launch, try preparer.prepare(infoDictionary: info, shortcutBundleURL: bundleURL, baseEnvironment: ["PATH": "/usr/bin"]))
    }

    func testPrepareShortcutRejectsWebAppBundles() throws {
        let root = try makeTemporaryDirectory()
        var config = makeConfig(kind: .webApp)
        config.webApp = WebAppConfig(url: "https://mail.example.com")

        XCTAssertThrowsError(
            try LaunchPreparer(realHome: root).prepareShortcut(
                infoDictionary: [ShortcutConfig.infoPlistKey: config.plistDictionary()],
                shortcutBundleURL: URL(filePath: "/Applications/Mail.app", directoryHint: .isDirectory),
                baseEnvironment: [:],
                realHome: root,
                terminalLocator: LauncherActionPlannerTests.installed
            )
        ) { error in
            guard case LauncherError.configCorrupt(let detail) = error else {
                return XCTFail("expected configCorrupt, got \(error)")
            }
            XCTAssertEqual(detail, "web app bundles are run by WebShell")
        }
    }

    func testPrepareShortcutWithoutMADConfigThrowsConfigMissing() throws {
        let root = try makeTemporaryDirectory()

        XCTAssertThrowsError(
            try LaunchPreparer(realHome: root).prepareShortcut(
                infoDictionary: [:],
                shortcutBundleURL: URL(filePath: "/Applications/X.app", directoryHint: .isDirectory),
                baseEnvironment: [:],
                realHome: root,
                terminalLocator: LauncherActionPlannerTests.installed
            )
        ) { error in
            guard case LauncherError.configMissing = error else {
                return XCTFail("expected configMissing, got \(error)")
            }
        }
    }
}
