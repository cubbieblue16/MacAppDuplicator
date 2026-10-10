import DuplicatorCore
import XCTest
@testable import MacAppDuplicator

final class WebEditorPolicyTests: XCTestCase {
    func testValidatedURLAcceptsAnHTTPSAddress() throws {
        XCTAssertEqual(try WebEditorPolicy.validatedURL("https://chat.example.com/app?x=1").get(), "https://chat.example.com/app?x=1")
    }

    func testValidatedURLRefusesAnythingElseWithTheSharedCopy() {
        for bad in ["", "not a url", "http://chat.example.com", "https://user@evil.example", "ftp://chat.example.com"] {
            switch WebEditorPolicy.validatedURL(bad) {
            case .success(let url): XCTFail("\(bad) must be refused, got \(url)")
            case .failure(let error):
                XCTAssertEqual(error, .invalidAddress)
                XCTAssertEqual(error.localizedDescription, "Enter an https:// address")
            }
        }
    }

    func testParsedHostsDropsBlankLinesTrimsLowercasesAndDeduplicates() {
        let hosts = WebEditorPolicy.parsedHosts(from: "Login.Example.com\n\n   cdn.example.com  \nlogin.example.com\n")
        XCTAssertEqual(Set(hosts), ["login.example.com", "cdn.example.com"])
        XCTAssertEqual(hosts.count, 2)
        XCTAssertEqual(WebEditorPolicy.parsedHosts(from: " \n \n"), [])
    }

    func testBadgePatternMapsBlankToNil() {
        XCTAssertNil(WebEditorPolicy.badgePattern(from: ""))
        XCTAssertNil(WebEditorPolicy.badgePattern(from: "  \n"))
        XCTAssertEqual(WebEditorPolicy.badgePattern(from: " \\((\\d+)\\) "), "\\((\\d+)\\)")
    }

    func testBadgeWarningFiresOnlyWhenTheParserFallsBack() {
        XCTAssertNil(WebEditorPolicy.badgeWarning(for: ""))
        XCTAssertNil(WebEditorPolicy.badgeWarning(for: "\\((\\d+)\\)"))
        XCTAssertNil(WebEditorPolicy.badgeWarning(for: "^(\\d+) new$"))
        for bad in ["(", "no capture group", "[a-z"] {
            XCTAssertEqual(
                WebEditorPolicy.badgeWarning(for: bad),
                "That pattern is not valid or has no capture group, so the default \(BadgeTitleParser.defaultPattern) is used.",
                bad
            )
        }
    }

    func testFetchedIconIsOfferedOnlyWhileTheSavedModeIsFetched() {
        XCTAssertEqual(WebEditorPolicy.iconModes(saved: .copied), [.copied, .custom, .generated])
        XCTAssertEqual(WebEditorPolicy.iconModes(saved: .custom), [.custom, .generated])
        XCTAssertEqual(WebEditorPolicy.iconModes(saved: .generated), [.custom, .generated])
        XCTAssertEqual(WebEditorPolicy.iconLabel(.copied), "Fetched from site")
        XCTAssertEqual(WebEditorPolicy.iconLabel(.custom), "Custom file")
        XCTAssertEqual(WebEditorPolicy.iconLabel(.generated), "Generated tile")
    }

    func testZoomLabelIsAWholePercent() {
        XCTAssertEqual(WebEditorPolicy.zoomLabel(1.0), "100%")
        XCTAssertEqual(WebEditorPolicy.zoomLabel(1.25), "125%")
        XCTAssertEqual(WebEditorPolicy.zoomLabel(0.5), "50%")
        XCTAssertEqual(WebEditorPolicy.zoomLabel(1.15), "115%")
    }

    func testRemoveWebDataMessageSaysTheShortcutStays() {
        XCTAssertEqual(
            WebEditorPolicy.removeWebDataMessage(shortcutName: "Chat"),
            "This signs “Chat” out of every site and deletes its cookies, cache and local storage from this Mac. The shortcut stays, and this cannot be undone."
        )
    }

    // MARK: saveConfig

    func testRenameKeepsTheSlugAndBundleIdentifierSoTheStoreIsNotOrphaned() {
        let saved = makeWebShortcutConfig(name: "Chat")
        var draft = saved
        draft.name = "  Chat Work "
        draft.slug = "chat-work"
        draft.bundleIdentifier = "com.mikekuta.appduplicator.chat-work"

        let config = WebEditorPolicy.saveConfig(draft: draft, saved: saved)

        XCTAssertEqual(config.name, "Chat Work")
        XCTAssertEqual(config.slug, "chat")
        XCTAssertEqual(config.bundleIdentifier, "com.mikekuta.appduplicator.chat")
    }

    func testSavePinsTheStoreIdentifierAndTheRememberedZoom() {
        let saved = makeWebShortcutConfig(name: "Chat")
        var draft = saved
        draft.webApp?.dataStoreID = UUID()
        draft.webApp?.pageZoom = 2.0

        let config = WebEditorPolicy.saveConfig(draft: draft, saved: saved)

        XCTAssertEqual(config.webApp?.dataStoreID, saved.webApp?.dataStoreID)
        XCTAssertEqual(config.webApp?.pageZoom, saved.webApp?.pageZoom)
    }

    func testSaveKeepsTheEditedWebFieldsAndNormalizesHosts() {
        let saved = makeWebShortcutConfig(name: "Chat")
        var draft = saved
        draft.webApp?.userAgent = .chrome
        draft.webApp?.badgeRegex = "^(\\d+) new$"
        draft.webApp?.extraHosts = [" Login.Example.com ", "login.example.com"]
        draft.webApp?.url = "https://chat.example.com/next"

        let web = WebEditorPolicy.saveConfig(draft: draft, saved: saved).webApp

        XCTAssertEqual(web?.userAgent, .chrome)
        XCTAssertEqual(web?.badgeRegex, "^(\\d+) new$")
        XCTAssertEqual(web?.extraHosts, ["login.example.com"])
        XCTAssertEqual(web?.url, "https://chat.example.com/next")
    }

    func testBackgroundModeNeedsTheMenuBarIcon() {
        let saved = makeWebShortcutConfig(name: "Chat", menuBarIcon: true, backgroundMode: true)

        var iconOff = saved
        iconOff.menuBarIcon = false
        let cleared = WebEditorPolicy.saveConfig(draft: iconOff, saved: saved)
        XCTAssertFalse(cleared.menuBarIcon)
        XCTAssertEqual(cleared.webApp?.backgroundMode, false, "background mode cannot outlive the menu bar icon")

        let kept = WebEditorPolicy.saveConfig(draft: saved, saved: saved)
        XCTAssertEqual(kept.webApp?.backgroundMode, true)
    }

    func testSaveOfAnUnchangedWebConfigChangesNothingButTheEngineIndependentFields() {
        let saved = makeWebShortcutConfig(name: "Chat", menuBarIcon: true, backgroundMode: true)
        XCTAssertEqual(WebEditorPolicy.saveConfig(draft: saved, saved: saved), saved)
    }
}
