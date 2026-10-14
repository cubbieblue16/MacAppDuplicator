import ArgumentParser
import DuplicatorCore
import Foundation

func inspectApp(at path: String) throws -> InspectedApp {
    try AppInspector().inspect(appAt: URL(filePath: path, directoryHint: .isDirectory))
}

func makeConfig(app: InspectedApp, options: ShortcutOptions) throws -> ShortcutConfig {
    let name = options.name ?? app.name
    let slug = ShortcutConfig.slug(for: name)

    var environment: [String: String] = [:]
    for entry in options.env {
        guard let separator = entry.firstIndex(of: "="), separator != entry.startIndex else {
            throw ValidationError("--env expects K=V: \(entry)")
        }
        environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
    }

    if let language = options.language, !LanguageCode.isValid(language) {
        throw ValidationError("--language expects a code like en, fr or pt-BR: \(language)")
    }
    if let message = NewWindowCommandBuilder.validationMessage(for: options.newWindowCommand) {
        throw ValidationError("--new-window-command: \(message)")
    }

    let dataMode = options.dataMode.dataMode
    if options.eraseOnQuit, dataMode == .disabled {
        throw ValidationError("--erase-on-quit needs --data-mode auto or home")
    }
    let dataPath: String?
    if let explicit = options.dataPath {
        // The same location rules the app applies when a data folder is picked and the helper applies before it erases.
        if let refusal = DataPathRules.refusal(
            forPath: explicit, home: FileManager.default.homeDirectoryForCurrentUser, allowOutsideHome: !options.eraseOnQuit
        ) {
            let consequence = options.eraseOnQuit ? "--erase-on-quit would empty it" : "it is not a shortcut data folder"
            throw ValidationError("--data-path \(explicit) is refused (\(refusal.logReason)); \(consequence).")
        }
        dataPath = explicit
    } else if dataMode == .auto || dataMode == .homeOverride {
        dataPath = ShortcutConfig.defaultDataPath(forSlug: slug, home: FileManager.default.homeDirectoryForCurrentUser)
    } else {
        dataPath = nil
    }

    return ShortcutConfig(
        kind: .app,
        name: name,
        slug: slug,
        bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: slug),
        targetPath: app.bundleURL.path,
        targetBundleIdentifier: app.bundleIdentifier,
        launchMode: options.mode.launchMode,
        dataMode: dataMode,
        dataPath: dataPath,
        environment: environment,
        arguments: options.arg,
        appearance: options.appearance.appearance,
        languageCode: options.language,
        eraseOnQuit: options.eraseOnQuit,
        menuBarIcon: options.menuBarIcon,
        newWindowCommand: options.newWindowCommand
    )
}
