import ArgumentParser
import DuplicatorCore

enum DataModeOption: String, CaseIterable, ExpressibleByArgument {
    case auto, home, disabled

    var dataMode: DataMode {
        switch self {
        case .auto: return .auto
        case .home: return .homeOverride
        case .disabled: return .disabled
        }
    }
}

enum LaunchModeOption: String, CaseIterable, ExpressibleByArgument {
    case dock, system

    var launchMode: LaunchMode {
        switch self {
        case .dock: return .dockShortcut
        case .system: return .systemLaunch
        }
    }
}

enum AppearanceOption: String, CaseIterable, ExpressibleByArgument {
    case system, light, dark

    var appearance: Appearance {
        switch self {
        case .system: return .system
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Flags shared by `plan` and `new`.
struct ShortcutOptions: ParsableArguments {
    @Option(help: "Shortcut name; defaults to the target app's name.") var name: String?
    @Option(name: .customLong("data-mode"), help: "auto, home or disabled.") var dataMode: DataModeOption = .auto
    @Option(name: .customLong("data-path")) var dataPath: String?
    @Option(help: "dock or system.") var mode: LaunchModeOption = .dock
    @Option(name: .customLong("env"), help: "K=V; repeatable.") var env: [String] = []
    @Option(name: .customLong("arg"), help: "Extra argument; repeatable.") var arg: [String] = []
    @Option var appearance: AppearanceOption = .system
    @Option var language: String?
}
