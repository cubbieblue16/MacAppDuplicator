import DuplicatorCore
import XCTest
@testable import MacAppDuplicator

final class HelperEditorPolicyTests: XCTestCase {
    private var dir: URL!
    private var home: URL!

    override func setUpWithError() throws {
        dir = try makeAppTemporaryDirectory()
        home = dir.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    /// Creates `relativePath` and its parents under the test home and returns its path.
    private func makeFolder(_ relativePath: String) throws -> String {
        let url = home.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// `<test home>/Library/Application Support/App Duplicator`.
    private var dataRoot: String {
        ShortcutConfig.dataRoot(home: home).path
    }

    /// The application shortcut "Target Work" with the given data settings and every helper option off.
    private func appConfig(dataMode: DataMode = .auto, dataPath: String? = nil) -> ShortcutConfig {
        var config = makeConfig(targetPath: "/Applications/Target.app")
        config.dataMode = dataMode
        config.dataPath = dataPath
        config.menuBarIcon = false
        config.eraseOnQuit = false
        config.newWindowCommand = nil
        config.languageCode = nil
        return config
    }

    func testHelperControlsShowForApplicationShortcutsOnly() {
        XCTAssertTrue(HelperEditorPolicy.helperControlsVisible(kind: .app))
        for kind in [ShortcutKind.webApp, .file, .folder, .cli] {
            XCTAssertFalse(HelperEditorPolicy.helperControlsVisible(kind: kind), kind.rawValue)
        }
    }

    func testOnlyFoldersInsideTheDataRootSkipTheConfirmation() throws {
        let work = dataRoot + "/target-work"
        XCTAssertTrue(HelperEditorPolicy.canEnableEraseWithoutConfirm(dataPath: work, home: home), "a default folder before the first launch")
        let created = try makeFolder("Library/Application Support/App Duplicator/target-work")
        XCTAssertTrue(HelperEditorPolicy.canEnableEraseWithoutConfirm(dataPath: created, home: home))
        XCTAssertFalse(HelperEditorPolicy.canEnableEraseWithoutConfirm(dataPath: dataRoot, home: home), "the data root itself")
        let custom = try makeFolder("Projects/data")
        XCTAssertFalse(HelperEditorPolicy.canEnableEraseWithoutConfirm(dataPath: custom, home: home))
        XCTAssertFalse(HelperEditorPolicy.canEnableEraseWithoutConfirm(dataPath: "Library/Application Support/App Duplicator/target-work", home: home))
    }

    func testEraseCheckAllowsAsksOrRefuses() throws {
        let work = try makeFolder("Library/Application Support/App Duplicator/target-work")
        let custom = try makeFolder("Projects/data")
        let documents = try makeFolder("Documents")
        let stuff = try makeFolder("Stuff")
        let caches = try makeFolder("Library/Caches")
        let outside = dir.appending(path: "outside/data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = home.appending(path: "Projects/link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: work)

        func check(_ path: String?, _ mode: DataMode = .homeOverride) -> HelperEditorPolicy.EraseCheck {
            HelperEditorPolicy.eraseCheck(dataPath: path, dataMode: mode, home: home)
        }
        func refused(_ reason: String) -> HelperEditorPolicy.EraseCheck {
            .refused("Erase on quit never empties this folder: \(reason).")
        }

        XCTAssertEqual(check(work, .auto), .allowed)
        XCTAssertEqual(check(dataRoot + "/not-created-yet", .auto), .allowed, "a missing folder is checked again at quit")
        XCTAssertEqual(check(custom), .needsConfirmation(dataPath: custom))
        XCTAssertEqual(check(home.path), refused("the folder is the home folder"))
        XCTAssertEqual(check(documents), refused("the folder is ~/Documents"))
        XCTAssertEqual(check(stuff), refused("the folder is directly inside the home folder"))
        XCTAssertEqual(check(caches), refused("the folder is directly inside ~/Library"))
        XCTAssertEqual(check(dataRoot), refused("the folder is the App Duplicator data root"))
        XCTAssertEqual(check(outside.path), refused("the folder is outside the home folder"))
        XCTAssertEqual(check(link), refused("the path is a symbolic link"))
        XCTAssertEqual(check("Projects/data"), refused("the path is not a normalised absolute path"))
        XCTAssertEqual(check(custom, .disabled), .refused(HelperEditorPolicy.disabledDataMessage))
        XCTAssertEqual(check(nil), .refused(HelperEditorPolicy.disabledDataMessage))
        XCTAssertEqual(check(""), .refused(HelperEditorPolicy.disabledDataMessage))
    }

    func testEraseCheckForAConfigUsesItsEffectiveDataFolder() throws {
        XCTAssertEqual(HelperEditorPolicy.eraseCheck(for: appConfig(), home: home), .allowed, "Auto without a stored folder uses the default folder")
        let custom = try makeFolder("Projects/data")
        XCTAssertEqual(
            HelperEditorPolicy.eraseCheck(for: appConfig(dataMode: .homeOverride, dataPath: custom), home: home),
            .needsConfirmation(dataPath: custom)
        )
        XCTAssertEqual(HelperEditorPolicy.eraseCheck(for: appConfig(dataMode: .disabled), home: home), .refused(HelperEditorPolicy.disabledDataMessage))
        XCTAssertEqual(
            HelperEditorPolicy.eraseCheck(for: appConfig(dataMode: .disabled, dataPath: custom), home: home),
            .refused(HelperEditorPolicy.disabledDataMessage),
            "a folder kept from before Data was disabled"
        )
        XCTAssertEqual(
            HelperEditorPolicy.eraseConfirmationMessage(name: "Target Work", dataPath: custom),
            "Every time Target Work quits, everything inside \(custom) is deleted permanently. It is not moved to the Trash. This folder is outside App Duplicator's data folder."
        )
    }

    func testValidationMessagesForLanguageAndNewWindow() {
        XCTAssertEqual(HelperEditorPolicy.languageValidation("french"), LanguageCode.invalidMessage)
        XCTAssertEqual(HelperEditorPolicy.languageValidation("en_US"), LanguageCode.invalidMessage)
        XCTAssertNil(HelperEditorPolicy.languageValidation("pt-BR"))
        XCTAssertNil(HelperEditorPolicy.languageValidation(" fr "))
        XCTAssertNil(HelperEditorPolicy.languageValidation(nil))
        XCTAssertNil(HelperEditorPolicy.languageValidation("  "))

        let control = "The New Window command may not contain control characters."
        XCTAssertEqual(HelperEditorPolicy.newWindowValidation("open\n-na {target}"), control)
        XCTAssertEqual(HelperEditorPolicy.newWindowValidation("open\u{7F} -na {target}"), control)
        XCTAssertNil(HelperEditorPolicy.newWindowValidation("open\t-na {target}"))
        XCTAssertNil(HelperEditorPolicy.newWindowValidation(nil))
        XCTAssertEqual(
            HelperEditorPolicy.newWindowValidation(String(repeating: "a", count: 2_049)),
            "The New Window command is longer than 2048 characters."
        )

        var draft = appConfig()
        draft.languageCode = "french"
        draft.newWindowCommand = "open\n-na {target}"
        XCTAssertEqual(HelperEditorPolicy.validationMessage(for: draft), LanguageCode.invalidMessage, "the language message comes first")
        draft.languageCode = "fr"
        XCTAssertEqual(HelperEditorPolicy.validationMessage(for: draft), control)
        draft.newWindowCommand = "open -na {target}"
        XCTAssertNil(HelperEditorPolicy.validationMessage(for: draft))

        var web = makeWebConfig()
        web.languageCode = "french"
        web.newWindowCommand = "open\n"
        XCTAssertNil(HelperEditorPolicy.validationMessage(for: web), "hidden fields never block Save")
    }

    func testSaveConfigTrimsTheTextFieldsAndDropsAnInertErase() {
        var draft = appConfig(dataMode: .disabled)
        draft.languageCode = " fr "
        draft.newWindowCommand = "  open -na {target}  "
        draft.eraseOnQuit = true
        let saved = HelperEditorPolicy.saveConfig(draft: draft)
        XCTAssertEqual(saved.languageCode, "fr")
        XCTAssertEqual(saved.newWindowCommand, "open -na {target}")
        XCTAssertFalse(saved.eraseOnQuit, "erase never runs while data separation is disabled")

        var blank = appConfig()
        blank.languageCode = "   "
        blank.newWindowCommand = "   "
        blank.eraseOnQuit = true
        let savedBlank = HelperEditorPolicy.saveConfig(draft: blank)
        XCTAssertNil(savedBlank.languageCode)
        XCTAssertNil(savedBlank.newWindowCommand)
        XCTAssertTrue(savedBlank.eraseOnQuit)

        var web = makeWebConfig()
        web.languageCode = " fr "
        web.eraseOnQuit = true
        XCTAssertEqual(HelperEditorPolicy.saveConfig(draft: web), web)
    }

    func testNewWindowNoteSaysWhyTheItemIsHidden() {
        var config = appConfig()
        XCTAssertNil(HelperEditorPolicy.newWindowNote(for: config, home: home))
        config.menuBarIcon = true
        XCTAssertEqual(HelperEditorPolicy.newWindowNote(for: config, home: home), "New Window is hidden until you enter a command.")
        config.newWindowCommand = "  "
        XCTAssertEqual(HelperEditorPolicy.newWindowNote(for: config, home: home), "New Window is hidden until you enter a command.")
        config.newWindowCommand = "open -na {target}"
        XCTAssertNil(HelperEditorPolicy.newWindowNote(for: config, home: home))
        config.menuBarIcon = false
        XCTAssertEqual(HelperEditorPolicy.newWindowNote(for: config, home: home), "New Window appears only while Menu bar icon is on.")

        var dataTemplate = appConfig(dataMode: .disabled)
        dataTemplate.menuBarIcon = true
        dataTemplate.newWindowCommand = "/usr/bin/touch {dataPath}/marker"
        XCTAssertEqual(
            HelperEditorPolicy.newWindowNote(for: dataTemplate, home: home),
            "New Window stays hidden: the command uses {dataPath} and the shortcut has no data folder."
        )
        dataTemplate.dataMode = .auto
        XCTAssertNil(HelperEditorPolicy.newWindowNote(for: dataTemplate, home: home), "Auto fills in the default folder")

        var web = makeWebConfig()
        web.menuBarIcon = true
        XCTAssertNil(HelperEditorPolicy.newWindowNote(for: web, home: home))
    }

    func testHelperLineListsWhatTheHelperDoes() {
        var config = appConfig()
        XCTAssertNil(HelperEditorPolicy.helperLine(for: config, home: home))
        config.newWindowCommand = "open -na {target}"
        XCTAssertNil(HelperEditorPolicy.helperLine(for: config, home: home), "a New Window command alone starts no helper")
        config.menuBarIcon = true
        XCTAssertEqual(HelperEditorPolicy.helperLine(for: config, home: home), "Menu bar icon · New Window")
        config.eraseOnQuit = true
        XCTAssertEqual(HelperEditorPolicy.helperLine(for: config, home: home), "Menu bar icon · New Window · Erase on quit")
        config.menuBarIcon = false
        XCTAssertEqual(HelperEditorPolicy.helperLine(for: config, home: home), "Erase on quit")
        config.dataMode = .disabled
        XCTAssertNil(HelperEditorPolicy.helperLine(for: config, home: home))

        var iconOnly = appConfig()
        iconOnly.menuBarIcon = true
        XCTAssertEqual(HelperEditorPolicy.helperLine(for: iconOnly, home: home), "Menu bar icon")

        var web = makeWebConfig()
        web.menuBarIcon = true
        web.eraseOnQuit = true
        XCTAssertNil(HelperEditorPolicy.helperLine(for: web, home: home))
    }

    func testNewWindowTextShowsTheMaskedCommandOrWhyItIsHidden() {
        var config = appConfig()
        XCTAssertEqual(HelperEditorPolicy.newWindowText(for: config, home: home), "None")
        config.newWindowCommand = "   "
        XCTAssertEqual(HelperEditorPolicy.newWindowText(for: config, home: home), "None")
        config.newWindowCommand = "open -na {target} --args --api-key hunter2"
        config.menuBarIcon = true
        let command = "/usr/bin/env open -na /Applications/Target.app --args --api-key \(SecretMasking.maskedValue)"
        XCTAssertEqual(HelperEditorPolicy.newWindowText(for: config, home: home), command)
        config.menuBarIcon = false
        XCTAssertEqual(HelperEditorPolicy.newWindowText(for: config, home: home), command + " (hidden: the menu bar icon is off)")

        var dataTemplate = appConfig()
        dataTemplate.menuBarIcon = true
        dataTemplate.newWindowCommand = "/usr/bin/touch {dataPath}/marker"
        let defaultPath = ShortcutConfig.defaultDataPath(forSlug: dataTemplate.slug, home: home)
        XCTAssertEqual(HelperEditorPolicy.newWindowText(for: dataTemplate, home: home), "/usr/bin/touch \(defaultPath)/marker")
        dataTemplate.dataMode = .disabled
        XCTAssertEqual(
            HelperEditorPolicy.newWindowText(for: dataTemplate, home: home),
            "Hidden (the command uses {dataPath} and the shortcut has no data folder)"
        )

        var web = makeWebConfig()
        web.newWindowCommand = "open -na {target}"
        XCTAssertEqual(HelperEditorPolicy.newWindowText(for: web, home: home), "None")
    }

    func testEraseTextSaysWhatHappensAtQuit() throws {
        var config = appConfig()
        XCTAssertEqual(HelperEditorPolicy.eraseText(for: config, home: home), "Off")
        config.eraseOnQuit = true
        let defaultPath = ShortcutConfig.defaultDataPath(forSlug: config.slug, home: home)
        XCTAssertEqual(HelperEditorPolicy.eraseText(for: config, home: home), "On: \(defaultPath)", "the first launch creates the default folder")
        let custom = try makeFolder("Projects/data")
        config.dataMode = .homeOverride
        config.dataPath = custom
        XCTAssertEqual(HelperEditorPolicy.eraseText(for: config, home: home), "On: \(custom)")
        config.dataPath = home.path
        XCTAssertEqual(HelperEditorPolicy.eraseText(for: config, home: home), "On, but the folder is never erased: the folder is the home folder")
        config.dataMode = .disabled
        XCTAssertEqual(HelperEditorPolicy.eraseText(for: config, home: home), "Off (no data folder to erase)")
    }

    func testLanguageTextAndDiagnosticsRows() {
        XCTAssertEqual(HelperEditorPolicy.languageText(nil), "System")
        XCTAssertEqual(HelperEditorPolicy.languageText("  "), "System")
        XCTAssertEqual(HelperEditorPolicy.languageText(" fr "), "fr")
        XCTAssertEqual(HelperEditorPolicy.languageText("french"), "french (not a valid language code)")

        XCTAssertEqual(HelperEditorPolicy.diagnosticsRows(for: appConfig(), home: home), [
            ProfileSummary.Row(label: "Menu bar icon", value: "Off"),
            ProfileSummary.Row(label: "Erase on quit", value: "Off"),
            ProfileSummary.Row(label: "New Window command", value: "None"),
            ProfileSummary.Row(label: "Language", value: "System"),
        ])
        XCTAssertEqual(HelperEditorPolicy.diagnosticsRows(for: makeWebConfig(), home: home), [])
        XCTAssertEqual(HelperEditorPolicy.diagnosticsRows(for: makeConfig(kind: .cli), home: home), [])
    }
}
