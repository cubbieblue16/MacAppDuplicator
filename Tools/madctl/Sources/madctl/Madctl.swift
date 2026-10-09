import ArgumentParser

@main struct Madctl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "madctl",
        abstract: "macOS App Duplicator command-line generator.",
        subcommands: [InspectCommand.self, PlanCommand.self, NewCommand.self]
    )
}
