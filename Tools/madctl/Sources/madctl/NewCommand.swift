import ArgumentParser
import DuplicatorCore
import Foundation

struct NewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "new", abstract: "Write and sign a shortcut bundle.")

    @Argument(help: "Path to the target .app.") var appPath: String
    @OptionGroup var options: ShortcutOptions
    @Option(help: "Output directory (created if missing). Default: ~/Applications/App Duplicator.") var out: String?
    @Option(help: "Launcher binary. Default: Launcher next to madctl.") var launcher: String?
    @Option(help: "Signing identity; ad-hoc when omitted.") var identity: String?

    func validate() throws {
        guard options.name != nil else { throw ValidationError("new requires --name") }
    }

    func run() throws {
        let outputDirectory: URL
        if let out {
            outputDirectory = URL(filePath: out, directoryHint: .isDirectory)
        } else {
            outputDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Applications/App Duplicator", directoryHint: .isDirectory)
        }
        let launcherURL: URL
        if let launcher {
            launcherURL = URL(filePath: launcher)
        } else {
            // Bundle.main.executableURL is optional; fall back to argv[0], resolved against the working directory.
            let selfURL = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
            launcherURL = selfURL.deletingLastPathComponent().appending(path: "Launcher")
        }

        do {
            let app = try inspectApp(at: appPath)
            let config = try makeConfig(app: app, options: options)

            for warning in app.warnings { printError("warning: \(warning)") }
            let plan = DataSeparationPlanner().plan(app: app, config: config, baseEnvironment: ProcessInfo.processInfo.environment)
            for warning in plan.warnings { printError("warning: \(warning)") }

            guard FileManager.default.isExecutableFile(atPath: launcherURL.path) else {
                printError("launcher not found: \(launcherURL.path)")
                throw ExitCode(1)
            }

            let bundle = try BundleWriter().write(config: config, app: app, launcherBinary: launcherURL, to: outputDirectory)
            try Signer().sign(bundle: bundle, identity: identity)
            print(bundle.path)
        } catch let exit as ExitCode {
            throw exit
        } catch let validation as ValidationError {
            throw validation
        } catch {
            throw runtimeFailure(error)
        }
    }
}
