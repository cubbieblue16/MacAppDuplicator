import DuplicatorCore
import XCTest
@testable import MacAppDuplicator

final class LauncherEditorPolicyTests: XCTestCase {
    private func launcher(kind: ShortcutKind, name: String = "Notes", file: FileConfig? = nil, cli: CLIConfig? = nil) -> ShortcutConfig {
        ShortcutConfig(
            kind: kind, name: name, slug: "notes", bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: "notes"),
            targetPath: "", targetBundleIdentifier: "", launchMode: .dockShortcut, dataMode: .disabled, dataPath: nil,
            iconMode: .copied, customIconPath: nil, file: file, cli: cli
        )
    }

    func testLauncherKinds() {
        XCTAssertTrue(LauncherEditorPolicy.isLauncherKind(.file))
        XCTAssertTrue(LauncherEditorPolicy.isLauncherKind(.folder))
        XCTAssertTrue(LauncherEditorPolicy.isLauncherKind(.cli))
        XCTAssertFalse(LauncherEditorPolicy.isLauncherKind(.app))
        XCTAssertFalse(LauncherEditorPolicy.isLauncherKind(.webApp))
    }

    func testFileSaveKeepsSlugAndEnforcesInvariants() {
        let saved = launcher(kind: .file, file: FileConfig(path: "/Users/me/Notes.txt", openerAppPath: nil))
        var draft = saved
        draft.name = "  Renamed Notes  "
        draft.slug = "renamed-notes"
        draft.bundleIdentifier = "com.example.other"
        draft.targetPath = "/Applications/Stray.app"
        draft.dataMode = .homeOverride
        draft.dataPath = "/tmp/stray"
        draft.file = FileConfig(path: "/Users/me/Docs/../Notes.txt", openerAppPath: "")
        draft.cli = CLIConfig(executablePath: "/bin/echo", arguments: [], workingDirectory: nil, terminal: .none, homeOverride: false)

        let config = LauncherEditorPolicy.saveConfig(draft: draft, saved: saved)
        XCTAssertEqual(config.name, "Renamed Notes")
        XCTAssertEqual(config.slug, saved.slug)
        XCTAssertEqual(config.bundleIdentifier, saved.bundleIdentifier)
        XCTAssertEqual(config.targetPath, "")
        XCTAssertEqual(config.targetBundleIdentifier, "")
        XCTAssertEqual(config.launchMode, .dockShortcut)
        XCTAssertEqual(config.dataMode, .disabled)
        XCTAssertNil(config.dataPath)
        XCTAssertNil(config.cli)
        XCTAssertNil(config.webApp)
        XCTAssertEqual(config.file, FileConfig(path: FileConfig.normalizedPath("/Users/me/Docs/../Notes.txt"), openerAppPath: nil))
    }

    func testCommandSaveTrimsFields() {
        let saved = launcher(kind: .cli, name: "Tool", cli: CLIConfig(executablePath: "/bin/echo", arguments: [], workingDirectory: nil, terminal: .terminal, homeOverride: false))
        var draft = saved
        draft.cli = CLIConfig(executablePath: "  /bin/echo ", arguments: [" --name ", "", "two words"], workingDirectory: "   ", terminal: .iterm2, homeOverride: true)
        draft.file = FileConfig(path: "/tmp/stray", openerAppPath: nil)

        let config = LauncherEditorPolicy.saveConfig(draft: draft, saved: saved)
        XCTAssertEqual(config.cli, CLIConfig(executablePath: "/bin/echo", arguments: ["--name", "two words"], workingDirectory: nil, terminal: .iterm2, homeOverride: true))
        XCTAssertNil(config.file)
        XCTAssertEqual(config.dataMode, .disabled)
    }

    func testValidationMessages() {
        XCTAssertEqual(LauncherEditorPolicy.validationMessage(for: launcher(kind: .file)), "Choose the file or folder this shortcut opens.")
        XCTAssertEqual(
            LauncherEditorPolicy.validationMessage(for: launcher(kind: .folder, file: FileConfig(path: "Projects", openerAppPath: nil))),
            "Use a full path that starts with /."
        )
        XCTAssertNil(LauncherEditorPolicy.validationMessage(for: launcher(kind: .folder, file: FileConfig(path: "/Users/me/Projects", openerAppPath: nil))))
        let emptyCommand = CLIConfig(executablePath: "  ", arguments: [], workingDirectory: nil, terminal: .none, homeOverride: false)
        XCTAssertEqual(LauncherEditorPolicy.validationMessage(for: launcher(kind: .cli, cli: emptyCommand)), "Enter the program to run.")
        let relative = CLIConfig(executablePath: "tool", arguments: [], workingDirectory: nil, terminal: .none, homeOverride: false)
        XCTAssertEqual(LauncherEditorPolicy.validationMessage(for: launcher(kind: .cli, cli: relative)), "Use a full path that starts with /.")
        XCTAssertNil(LauncherEditorPolicy.validationMessage(for: launcher(kind: .app)))
    }

    func testLabelsSubtitlesAndCommandHome() {
        XCTAssertEqual(LauncherEditorPolicy.iconLabel(.copied, kind: .file), "Copied from item")
        XCTAssertEqual(LauncherEditorPolicy.iconLabel(.copied, kind: .cli), "Copied from executable")
        XCTAssertEqual(LauncherEditorPolicy.iconLabel(.copied, kind: .app), "Copied from target")
        XCTAssertEqual(LauncherEditorPolicy.iconLabel(.generated, kind: .folder), "Generated tile")
        XCTAssertEqual(LauncherEditorPolicy.subtitle(for: launcher(kind: .file, file: FileConfig(path: "/Users/me/Report.pdf", openerAppPath: nil))), "Report.pdf")
        let tool = CLIConfig(executablePath: "/opt/bin/tool", arguments: ["--token", "x"], workingDirectory: nil, terminal: .none, homeOverride: false)
        XCTAssertEqual(LauncherEditorPolicy.subtitle(for: launcher(kind: .cli, cli: tool)), "tool")

        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        XCTAssertNil(LauncherEditorPolicy.commandHomePath(for: launcher(kind: .cli, cli: tool), home: home))
        var own = tool
        own.homeOverride = true
        XCTAssertEqual(
            LauncherEditorPolicy.commandHomePath(for: launcher(kind: .cli, cli: own), home: home),
            ShortcutConfig.defaultDataPath(forSlug: "notes", home: home)
        )
        XCTAssertNil(LauncherEditorPolicy.commandHomePath(for: launcher(kind: .file, file: FileConfig(path: "/a", openerAppPath: nil)), home: home))
    }
}
