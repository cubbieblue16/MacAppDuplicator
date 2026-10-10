import ArgumentParser
import DuplicatorCore
import Foundation

struct PlanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "plan", abstract: "Preview the launch plan for a shortcut without writing anything.")

    @Argument(help: "Path to the target .app.") var appPath: String
    @OptionGroup var options: ShortcutOptions

    func run() throws {
        let app: InspectedApp
        do {
            app = try inspectApp(at: appPath)
        } catch {
            throw runtimeFailure(error)
        }
        let config = try makeConfig(app: app, options: options)
        let baseEnvironment = ProcessInfo.processInfo.environment
        let plan = DataSeparationPlanner().plan(app: app, config: config, baseEnvironment: baseEnvironment)

        print("mode: \(plan.launchMode.rawValue)")
        print("argv:")
        print("  \(plan.executableURL.path)")
        for argument in SecretMasking.maskArguments(plan.arguments) {
            print("  \(argument)")
        }
        print("env:")
        let additions = SecretMasking.mask(plan.environmentAdditions(relativeTo: baseEnvironment))
        for key in additions.keys.sorted() {
            print("  \(key)=\(additions[key] ?? "")")
        }
        if !plan.warnings.isEmpty {
            print("warnings:")
            for warning in plan.warnings {
                print("  \(warning)")
            }
        }
    }
}
