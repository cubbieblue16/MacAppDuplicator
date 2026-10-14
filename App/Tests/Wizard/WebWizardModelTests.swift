import CompatProfiles
import Synchronization
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

/// A scripted icon fetcher: each call consumes the next outcome (the last one repeats) and records the page URL.
private final class FetchScript: Sendable {
    enum Outcome: Sendable {
        case data(Data)
        case nothing
        case failure
    }

    private struct State {
        var outcomes: [Outcome]
        var urls: [URL] = []
    }

    private let state: Mutex<State>

    init(_ outcomes: [Outcome]) {
        state = Mutex(State(outcomes: outcomes))
    }

    func next(for url: URL) -> Outcome {
        state.withLock { current in
            current.urls.append(url)
            return current.outcomes.count > 1 ? current.outcomes.removeFirst() : (current.outcomes.first ?? .nothing)
        }
    }

    var urls: [URL] { state.withLock { $0.urls } }
}

private struct FetchFailure: Error, LocalizedError {
    var errorDescription: String? { "The connection was lost." }
}

private struct WizardFakeIconFetcher: WebIconFetching {
    let script: FetchScript

    func fetchIcon(for pageURL: URL) async throws -> Data? {
        switch script.next(for: pageURL) {
        case .data(let data): return data
        case .nothing: return nil
        case .failure: throw FetchFailure()
        }
    }
}

@MainActor
final class WebWizardModelTests: XCTestCase {
    private let storeID = UUID()
    private let iconBytes = Data([0x89, 0x50, 0x4E, 0x47])
    private let whatsapp = WebAppPreset(name: "WhatsApp", url: "https://web.whatsapp.com", userAgent: "chrome",
                                        badgeRegex: #"\((\d+)\)"#, extraHosts: ["whatsapp.com", "whatsapp.net"])
    private let teams = WebAppPreset(name: "Teams", url: "https://teams.microsoft.com", extraHosts: ["microsoft.com"])

    private func makeModel(_ outcomes: [FetchScript.Outcome] = [.nothing], takenSlugs: Set<String> = []) -> (model: WizardModel, script: FetchScript) {
        let script = FetchScript(outcomes)
        let model = WizardModel(takenSlugs: takenSlugs, webAppPresets: [whatsapp, teams], webDataStoreID: storeID,
                                iconFetcher: WizardFakeIconFetcher(script: script),
                                userAgentResolver: { $0.userAgent == "chrome" ? .chrome : .safari })
        model.kind = .webApp
        return (model, script)
    }

    // MARK: step flow

    func testWebFlowSkipsTheDataStepAndUsesTheOptionsStep() async {
        let (model, script) = makeModel([.data(iconBytes)])
        XCTAssertEqual(model.steps, [.kind, .target, .identity, .webOptions, .review])
        XCTAssertEqual(model.stepNumber, 1)
        XCTAssertTrue(model.canAdvance, "the kind step accepts Web App")

        model.next()
        XCTAssertEqual(model.step, .target)
        XCTAssertFalse(model.canAdvance)
        model.webURL = "https://example.com"
        XCTAssertTrue(model.canAdvance)

        model.next()
        XCTAssertEqual(model.step, .identity)
        XCTAssertEqual(model.stepNumber, 3)
        await model.iconFetchTask?.value
        XCTAssertEqual(script.urls.map(\.absoluteString), ["https://example.com"])
        XCTAssertFalse(model.canAdvance, "the name is still empty")
        model.name = "Example"

        model.next()
        XCTAssertEqual(model.step, .webOptions)
        XCTAssertEqual(model.stepNumber, 4)
        XCTAssertTrue(model.canAdvance)

        model.next()
        XCTAssertEqual(model.step, .review)
        XCTAssertNil(model.preview, "a web app has no launch plan")
        XCTAssertNil(model.previewError)
        XCTAssertTrue(model.canAdvance)

        model.back()
        XCTAssertEqual(model.step, .webOptions)
        model.back()
        XCTAssertEqual(model.step, .identity)
    }

    func testTheApplicationFlowStillUsesTheDataStep() {
        let model = WizardModel()
        XCTAssertEqual(model.steps, [.kind, .target, .identity, .data, .review])
        model.kind = .folder
        XCTAssertTrue(model.canAdvance, "Phase 5 enabled the file, folder and command kinds")
        XCTAssertEqual(model.steps, [.kind, .target, .identity, .review], "a file or folder has no Data step")
    }

    // MARK: presets

    func testApplyingAPresetFillsTheWebFieldsAndTheName() {
        let (model, _) = makeModel()
        model.applyPreset(whatsapp)
        XCTAssertEqual(model.webURL, "https://web.whatsapp.com")
        XCTAssertEqual(model.userAgent, .chrome)
        XCTAssertEqual(model.badgeRegex, #"\((\d+)\)"#)
        XCTAssertEqual(model.extraHostsText, "whatsapp.com\nwhatsapp.net")
        XCTAssertEqual(model.name, "WhatsApp")
        XCTAssertEqual(model.selectedPreset, whatsapp)
        XCTAssertEqual(model.highlightedPreset, whatsapp)

        model.applyPreset(teams)
        XCTAssertEqual(model.webURL, "https://teams.microsoft.com")
        XCTAssertEqual(model.userAgent, .safari, "a preset without a user agent resets to Safari")
        XCTAssertEqual(model.badgeRegex, "")
        XCTAssertEqual(model.extraHostsText, "microsoft.com")
        XCTAssertEqual(model.name, "Teams", "a name the model filled in itself follows the preset")
    }

    func testApplyingAPresetKeepsAnameTheUserTyped() {
        let (model, _) = makeModel()
        model.name = "Family Chat"
        model.applyPreset(whatsapp)
        XCTAssertEqual(model.name, "Family Chat")
        XCTAssertEqual(model.webURL, "https://web.whatsapp.com")
    }

    func testEditingTheURLDropsTheHighlightButKeepsTheAppliedOptions() {
        let (model, _) = makeModel()
        model.applyPreset(whatsapp)
        model.webURL = "https://web.whatsapp.com/other"
        XCTAssertNil(model.highlightedPreset)
        XCTAssertEqual(model.selectedPreset, whatsapp)
        XCTAssertEqual(model.userAgent, .chrome)
        model.webURL = "  https://web.whatsapp.com "
        XCTAssertEqual(model.highlightedPreset, whatsapp, "surrounding spaces do not matter")
    }

    func testPresetHostIsTheDisplayedHost() {
        XCTAssertEqual(WizardModel.presetHost(whatsapp), "web.whatsapp.com")
        XCTAssertEqual(WizardModel.presetHost(WebAppPreset(name: "Broken", url: "not a url")), "not a url")
    }

    // MARK: URL validation

    func testTheTargetStepGatesOnAValidHTTPSAddress() {
        let (model, _) = makeModel()
        model.step = .target
        for bad in ["", "   ", "example.com", "http://example.com", "https://", "ftp://example.com", "https://trusted.com@evil.example"] {
            model.webURL = bad
            XCTAssertFalse(model.canAdvance, "'\(bad)' must not advance")
            XCTAssertNil(model.validatedWebURL, "'\(bad)' must not validate")
        }
        model.webURL = " https://example.com/app "
        XCTAssertTrue(model.canAdvance)
        XCTAssertEqual(model.validatedWebURL?.absoluteString, "https://example.com/app")
    }

    func testTheInlineErrorAppearsOnlyForANonEmptyInvalidAddress() {
        let (model, _) = makeModel()
        XCTAssertNil(model.webURLError, "nothing typed yet")
        model.webURL = "   "
        XCTAssertNil(model.webURLError)
        model.webURL = "example.com"
        XCTAssertEqual(model.webURLError, "Enter an https:// address")
        model.webURL = "https://example.com"
        XCTAssertNil(model.webURLError)
    }

    // MARK: extra hosts

    func testExtraHostsParseOnePerLineWithTheSchemeAndPathStripped() {
        let text = "https://WhatsApp.com/chat\n  whatsapp.net  \n\nhttp://whatsapp.com\n   \n"
        XCTAssertEqual(WizardModel.parseExtraHosts(text), ["WhatsApp.com", "whatsapp.net", "whatsapp.com"])
        XCTAssertEqual(WizardModel.parseExtraHosts(""), [])
        XCTAssertEqual(WizardModel.parseExtraHosts("cdn.example.com?x=1\r\napi.example.com#top"), ["cdn.example.com", "api.example.com"])
    }

    func testExtraHostsDropCredentialsAndPorts() {
        XCTAssertEqual(WizardModel.parseExtraHosts("cdn.example:443"), ["cdn.example"])
        XCTAssertEqual(WizardModel.parseExtraHosts("https://user:secret@cdn.example:8443/path"), ["cdn.example"])
        XCTAssertEqual(WizardModel.parseExtraHosts("user@login.example\napi.example:80?x=1"), ["login.example", "api.example"])
        XCTAssertEqual(WizardModel.parseExtraHosts("plain.example"), ["plain.example"])
    }

    func testMakeConfigLowerCasesAndDeduplicatesTheExtraHosts() {
        let (model, _) = makeModel()
        model.webURL = "https://example.com"
        model.name = "Example"
        model.extraHostsText = "https://WhatsApp.com/chat\n  whatsapp.net  \n\nhttp://whatsapp.com\n"
        XCTAssertEqual(model.makeConfig().webApp?.extraHosts, ["whatsapp.com", "whatsapp.net"])
    }

    // MARK: makeConfig

    func testMakeConfigProducesTheWebAppShape() {
        let (model, _) = makeModel()
        model.applyPreset(whatsapp)
        model.setMenuBarIcon(true)
        model.backgroundMode = true
        model.iconMode = .generated

        let config = model.makeConfig()
        XCTAssertEqual(config.kind, .webApp)
        XCTAssertEqual(config.name, "WhatsApp")
        XCTAssertEqual(config.slug, "whatsapp")
        XCTAssertEqual(config.bundleIdentifier, ShortcutConfig.bundleIdentifier(forSlug: "whatsapp"))
        XCTAssertEqual(config.targetPath, "")
        XCTAssertEqual(config.targetBundleIdentifier, "")
        XCTAssertEqual(config.launchMode, .dockShortcut)
        XCTAssertEqual(config.dataMode, .disabled)
        XCTAssertNil(config.dataPath)
        XCTAssertEqual(config.environment, [:])
        XCTAssertEqual(config.arguments, [])
        XCTAssertTrue(config.menuBarIcon)
        XCTAssertEqual(config.iconMode, .generated)
        XCTAssertNil(config.customIconPath)
        XCTAssertEqual(config.webApp, WebAppConfig(url: "https://web.whatsapp.com", dataStoreID: storeID, userAgent: .chrome,
                                                   badgeRegex: #"\((\d+)\)"#, extraHosts: ["whatsapp.com", "whatsapp.net"],
                                                   pageZoom: 1.0, backgroundMode: true))
    }

    func testTheDataStoreIdentifierIsStableAcrossCalls() {
        let (model, _) = makeModel()
        model.webURL = "https://example.com"
        model.name = "Example"
        XCTAssertEqual(model.makeConfig().webApp?.dataStoreID, storeID)
        XCTAssertEqual(model.makeConfig().webApp?.dataStoreID, model.makeConfig().webApp?.dataStoreID)
        let other = WizardModel()
        XCTAssertNotEqual(other.webDataStoreID, WizardModel().webDataStoreID, "each wizard session gets its own store")
    }

    func testABlankBadgePatternIsStoredAsNil() {
        let (model, _) = makeModel()
        model.webURL = "https://example.com"
        model.name = "Example"
        model.badgeRegex = "  \n"
        XCTAssertNil(model.makeConfig().webApp?.badgeRegex)
        model.badgeRegex = #"  \[(\d+)\]  "#
        XCTAssertEqual(model.makeConfig().webApp?.badgeRegex, #"\[(\d+)\]"#)
    }

    func testBackgroundModeNeedsTheMenuBarIcon() {
        let (model, _) = makeModel()
        model.webURL = "https://example.com"
        model.name = "Example"
        model.backgroundMode = true
        XCTAssertFalse(model.makeConfig().menuBarIcon)
        XCTAssertEqual(model.makeConfig().webApp?.backgroundMode, false, "background mode is not stored without the menu bar icon")

        model.setMenuBarIcon(true)
        model.backgroundMode = true
        XCTAssertEqual(model.makeConfig().webApp?.backgroundMode, true)

        model.setMenuBarIcon(false)
        XCTAssertFalse(model.backgroundMode, "turning the icon off clears background mode")
        XCTAssertEqual(model.makeConfig().webApp?.backgroundMode, false)
    }

    func testTheSlugStepsAroundTakenSlugsForWebApps() {
        let (model, _) = makeModel(takenSlugs: ["whatsapp"])
        model.applyPreset(whatsapp)
        let config = model.makeConfig()
        XCTAssertEqual(config.slug, "whatsapp-2")
        XCTAssertEqual(config.bundleIdentifier, ShortcutConfig.bundleIdentifier(forSlug: "whatsapp-2"))
        XCTAssertEqual(config.name, "WhatsApp")
    }

    // MARK: icon fetch

    func testAFetchedIconIsKeptAndLabelledFetchedFromSite() async {
        let (model, script) = makeModel([.data(iconBytes)])
        model.webURL = "https://example.com"
        model.name = "Example"
        XCTAssertEqual(model.iconMode, .copied)
        await model.fetchWebIcon()

        XCTAssertEqual(script.urls.map(\.absoluteString), ["https://example.com"])
        XCTAssertEqual(model.webIconFetchState, .fetched)
        XCTAssertEqual(model.webIconData, iconBytes)
        XCTAssertEqual(model.iconMode, .copied)
        XCTAssertEqual(model.makeConfig().iconMode, .copied)
        XCTAssertEqual(model.webIconPayload, iconBytes)
        XCTAssertEqual(model.iconDescription, "Fetched from site")
        XCTAssertNil(model.webIconStatusText)
    }

    func testANilResultFallsBackToAGeneratedTile() async {
        let (model, _) = makeModel([.nothing])
        model.webURL = "https://example.com"
        model.name = "Example"
        await model.fetchWebIcon()

        XCTAssertEqual(model.webIconFetchState, .unavailable("No icon found on the site."))
        XCTAssertNil(model.webIconData)
        XCTAssertEqual(model.iconMode, .generated)
        XCTAssertEqual(model.makeConfig().iconMode, .generated)
        XCTAssertNil(model.webIconPayload)
        XCTAssertEqual(model.iconDescription, "Generated tile")
        XCTAssertEqual(model.webIconStatusText, "Could not get the site icon; using a generated tile.")
    }

    func testAThrowingFetcherFallsBackToAGeneratedTile() async {
        let (model, _) = makeModel([.failure])
        model.webURL = "https://example.com"
        model.name = "Example"
        await model.fetchWebIcon()

        XCTAssertEqual(model.webIconFetchState, .unavailable("The connection was lost."))
        XCTAssertEqual(model.iconMode, .generated)
        XCTAssertNil(model.webIconData)
        XCTAssertEqual(model.makeConfig().iconMode, .generated)
    }

    func testAnEmptyDataResultCountsAsNoIcon() async {
        let (model, _) = makeModel([.data(Data())])
        model.webURL = "https://example.com"
        await model.fetchWebIcon()
        XCTAssertEqual(model.webIconFetchState, .unavailable("No icon found on the site."))
        XCTAssertEqual(model.iconMode, .generated)
    }

    func testACustomIconChoiceSurvivesAnyFetchResult() async {
        let (model, _) = makeModel([.nothing, .data(iconBytes)])
        model.webURL = "https://example.com"
        model.name = "Example"
        model.iconMode = .custom
        model.customIconPath = "/tmp/chosen-icon.png"

        await model.fetchWebIcon()
        XCTAssertEqual(model.iconMode, .custom)
        await model.fetchWebIcon()
        XCTAssertEqual(model.iconMode, .custom)
        XCTAssertEqual(model.webIconData, iconBytes)
        XCTAssertNil(model.webIconPayload, "only Fetched from site hands the bytes to the builder")
        let config = model.makeConfig()
        XCTAssertEqual(config.iconMode, .custom)
        XCTAssertEqual(config.customIconPath, "/tmp/chosen-icon.png")
    }

    func testACopiedModeWithoutFetchedDataIsWrittenAsGenerated() {
        let (model, _) = makeModel()
        model.webURL = "https://example.com"
        model.name = "Example"
        XCTAssertEqual(model.iconMode, .copied)
        XCTAssertNil(model.webIconData)
        XCTAssertEqual(model.makeConfig().iconMode, .generated, "a config never claims a fetched icon it does not have")
    }

    func testALaterSuccessfulFetchRestoresFetchedFromSite() async {
        let (model, _) = makeModel([.failure, .data(iconBytes)])
        model.webURL = "https://example.com"
        model.name = "Example"
        await model.fetchWebIcon()
        XCTAssertEqual(model.iconMode, .generated)

        model.webURL = "https://example.org"
        await model.fetchWebIcon()
        XCTAssertEqual(model.webIconFetchState, .fetched)
        XCTAssertEqual(model.iconMode, .copied)
        XCTAssertEqual(model.makeConfig().iconMode, .copied)
    }

    func testLeavingTheIdentityStepCancelsThePendingFetch() async {
        let (model, script) = makeModel([.data(iconBytes)])
        model.webURL = "https://example.com"
        model.step = .target
        model.next()
        XCTAssertEqual(model.step, .identity)
        let task = model.iconFetchTask
        XCTAssertNotNil(task)

        model.back()
        XCTAssertEqual(model.step, .target)
        XCTAssertNil(model.iconFetchTask)
        await task?.value
        XCTAssertEqual(script.urls, [], "a cancelled fetch never reaches the fetcher")
        XCTAssertEqual(model.webIconFetchState, .idle)
    }

    func testReenteringIdentityForTheSameAddressDoesNotFetchAgain() async {
        let (model, script) = makeModel([.data(iconBytes)])
        model.webURL = "https://example.com"
        model.name = "Example"
        model.step = .target
        model.next()
        await model.iconFetchTask?.value
        model.next() // webOptions
        model.back() // identity
        model.back() // target
        model.next() // identity again
        await model.iconFetchTask?.value
        XCTAssertEqual(script.urls.count, 1)
    }

    // MARK: review

    func testTheReviewRowsDescribeTheWebApp() {
        let (model, _) = makeModel()
        model.applyPreset(whatsapp)
        model.setMenuBarIcon(true)
        model.backgroundMode = true
        model.iconMode = .generated
        XCTAssertEqual(model.webReviewRows, [
            .init("Name", "WhatsApp"),
            .init("URL", "https://web.whatsapp.com"),
            .init("Also open in app", "whatsapp.com, whatsapp.net"),
            .init("User agent", "Chrome"),
            .init("Data store id", storeID.uuidString),
            .init("Menu bar", "On, keeps running when the window closes"),
            .init("Icon", "Generated tile"),
        ])
        model.setMenuBarIcon(false)
        model.userAgent = .safari
        XCTAssertEqual(model.webReviewRows[3], .init("User agent", "Safari"))
        XCTAssertEqual(model.webReviewRows[5], .init("Menu bar", "Off"))
        model.setMenuBarIcon(true)
        XCTAssertEqual(model.webReviewRows[5], .init("Menu bar", "On"))
    }

    func testTheReviewRowsOmitExtraHostsWhenNoneAndNeverListDroppedRegistries() {
        let (model, _) = makeModel()
        model.applyPreset(whatsapp)
        model.extraHostsText = "com\nco.uk\ngithub.io"
        XCTAssertFalse(model.webReviewRows.contains { $0.label == "Also open in app" })
        model.extraHostsText = "com\nCDN.example.com"
        XCTAssertEqual(model.webReviewRows.first { $0.label == "Also open in app" }, .init("Also open in app", "cdn.example.com"))
    }

    func testTheApplicationIconDescriptionsAreUnchanged() {
        let model = WizardModel()
        XCTAssertEqual(model.iconDescription, "Copied from target")
        model.iconMode = .generated
        XCTAssertEqual(model.iconDescription, "Generated tile")
        model.iconMode = .custom
        XCTAssertEqual(model.iconDescription, "Custom file")
        model.customIconPath = "/tmp/dir/icon.png"
        XCTAssertEqual(model.iconDescription, "Custom: icon.png")
    }
}
