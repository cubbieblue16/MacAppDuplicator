import ArgumentParser
import DuplicatorCore

struct InspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Show what madctl detects about an app.")

    @Argument(help: "Path to the target .app.") var appPath: String

    func run() throws {
        let app: InspectedApp
        do {
            app = try inspectApp(at: appPath)
        } catch {
            throw runtimeFailure(error)
        }
        print("name: \(app.name)")
        print("bundle-id: \(app.bundleIdentifier)")
        print("version: \(app.version)")
        print("family: \(app.family.rawValue)")
        print("sandboxed: \(app.isSandboxed)")
        print("platform-binary: \(app.isPlatformBinary)")
        print("launch-constraints: \(app.hasLaunchConstraints)")
        print("executable: \(app.executableURL.path)")
        print("icon: \(app.iconFileURL?.path ?? "none")")
        for warning in app.warnings {
            print("warning: \(warning)")
        }
    }
}
