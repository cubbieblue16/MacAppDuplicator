import XCTest
@testable import DuplicatorCore

final class WebAppConfigTests: XCTestCase {
    private let storeID = UUID(uuidString: "5B0D2C1E-8F3A-4C57-9E11-2A6D4B7C9F10")!

    private func makeWebApp() -> WebAppConfig {
        WebAppConfig(
            url: "https://web.whatsapp.com",
            dataStoreID: storeID,
            userAgent: .chrome,
            badgeRegex: #"\((\d+)\)"#,
            extraHosts: ["whatsapp.com", "whatsapp.net"],
            pageZoom: 1.25,
            backgroundMode: true
        )
    }

    private func makeShortcut(webApp: WebAppConfig?) -> ShortcutConfig {
        ShortcutConfig(
            kind: .webApp,
            name: "WhatsApp",
            slug: "whatsapp",
            bundleIdentifier: "com.mikekuta.appduplicator.whatsapp",
            targetPath: "",
            targetBundleIdentifier: "",
            launchMode: .dockShortcut,
            dataMode: .disabled,
            menuBarIcon: true,
            webApp: webApp
        )
    }

    // MARK: WebAppConfig

    func testInitializerDefaults() {
        let config = WebAppConfig(url: "https://example.com")
        XCTAssertEqual(config.userAgent, .safari)
        XCTAssertNil(config.badgeRegex)
        XCTAssertEqual(config.extraHosts, [])
        XCTAssertEqual(config.pageZoom, 1.0)
        XCTAssertFalse(config.backgroundMode)
        XCTAssertNotEqual(config.dataStoreID, WebAppConfig(url: "https://example.com").dataStoreID)
    }

    func testPageZoomIsClamped() {
        XCTAssertEqual(WebAppConfig(url: "https://a.com", pageZoom: 0.1).pageZoom, 0.5)
        XCTAssertEqual(WebAppConfig(url: "https://a.com", pageZoom: 9).pageZoom, 3.0)
        XCTAssertEqual(WebAppConfig(url: "https://a.com", pageZoom: .nan).pageZoom, 1.0)
        XCTAssertEqual(WebAppConfig(url: "https://a.com", pageZoom: 1.25).pageZoom, 1.25)
        XCTAssertEqual(WebAppConfig.pageZoomRange, 0.5...3.0)
    }

    func testExtraHostsAreTrimmedLowercasedAndDeduplicated() {
        let config = WebAppConfig(url: "https://a.com", extraHosts: [" WhatsApp.NET ", "", "whatsapp.net", "B.com", "   "])
        XCTAssertEqual(config.extraHosts, ["whatsapp.net", "b.com"])
    }

    func testUserAgentPresets() {
        XCTAssertEqual(UserAgentPreset.safari.rawValue, "safari")
        XCTAssertEqual(UserAgentPreset.chrome.rawValue, "chrome")
        XCTAssertNil(UserAgentPreset.safari.customUserAgent)
        let chrome = UserAgentPreset.chrome.customUserAgent
        XCTAssertEqual(chrome, UserAgentPreset.chromeDesktopUserAgent)
        XCTAssertEqual(
            chrome,
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
        )
    }

    // MARK: ShortcutConfig.webApp

    func testWebAppIsNilByDefault() {
        XCTAssertNil(makeShortcut(webApp: nil).webApp)
        let app = ShortcutConfig(name: "N", slug: "n", bundleIdentifier: "b", targetPath: "/A.app", targetBundleIdentifier: "a")
        XCTAssertNil(app.webApp)
    }

    func testPlistRoundTripKeepsTheWebAppConfig() throws {
        let config = makeShortcut(webApp: makeWebApp())
        let decoded = try ShortcutConfig(plistDictionary: config.plistDictionary())
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.webApp, makeWebApp())
        XCTAssertEqual(decoded.webApp?.dataStoreID, storeID)
    }

    func testPlistDictionaryEmitsTheWebAppKeysExactly() throws {
        let dictionary = makeShortcut(webApp: makeWebApp()).plistDictionary()
        let web = try XCTUnwrap(dictionary["webApp"] as? [String: Any])
        XCTAssertEqual(Set(web.keys), ["url", "dataStoreID", "userAgent", "badgeRegex", "extraHosts", "pageZoom", "backgroundMode"])
        XCTAssertEqual(web["url"] as? String, "https://web.whatsapp.com")
        XCTAssertEqual(web["dataStoreID"] as? String, storeID.uuidString)
        XCTAssertEqual(web["userAgent"] as? String, "chrome")
        XCTAssertEqual(web["badgeRegex"] as? String, #"\((\d+)\)"#)
        XCTAssertEqual(web["extraHosts"] as? [String], ["whatsapp.com", "whatsapp.net"])
        XCTAssertEqual(web["pageZoom"] as? Double, 1.25)
        XCTAssertEqual(web["backgroundMode"] as? Bool, true)
        XCTAssertNoThrow(try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0))
    }

    func testNilBadgeRegexIsOmittedAndRoundTrips() throws {
        var web = makeWebApp()
        web.badgeRegex = nil
        let config = makeShortcut(webApp: web)
        let dictionary = config.plistDictionary()
        let stored = try XCTUnwrap(dictionary["webApp"] as? [String: Any])
        XCTAssertNil(stored["badgeRegex"])
        XCTAssertEqual(try ShortcutConfig(plistDictionary: dictionary), config)
    }

    func testAbsentWebAppDecodesToNilAndIsNotEmitted() throws {
        let config = makeShortcut(webApp: nil)
        let dictionary = config.plistDictionary()
        XCTAssertNil(dictionary["webApp"])
        XCTAssertNil(try ShortcutConfig(plistDictionary: dictionary).webApp)
    }

    func testPhase3DictionaryWithoutWebAppStillDecodes() throws {
        let legacy: [String: Any] = [
            "kind": "app", "name": "Claude Work", "slug": "claude-work",
            "bundleIdentifier": "com.mikekuta.appduplicator.claude-work",
            "targetPath": "/Applications/Claude.app", "targetBundleIdentifier": "com.anthropic.claudefordesktop",
            "launchMode": "dockShortcut", "dataMode": "auto",
            "environment": [String: String](), "arguments": [String](),
            "appearance": "system", "eraseOnQuit": false, "menuBarIcon": false, "iconMode": "copied", "engineVersion": 1,
        ]
        let config = try ShortcutConfig(plistDictionary: legacy)
        XCTAssertNil(config.webApp)
        XCTAssertEqual(config.kind, .app)
        XCTAssertEqual(config.engineVersion, 1)
    }

    func testOptionalWebAppKeysFallBackToDefaults() throws {
        var dictionary = makeShortcut(webApp: nil).plistDictionary()
        dictionary["webApp"] = ["url": "https://example.com", "dataStoreID": storeID.uuidString]
        let web = try XCTUnwrap(ShortcutConfig(plistDictionary: dictionary).webApp)
        XCTAssertEqual(web, WebAppConfig(url: "https://example.com", dataStoreID: storeID))
    }

    func testStoredPageZoomIsClampedOnDecode() throws {
        var dictionary = makeShortcut(webApp: nil).plistDictionary()
        dictionary["webApp"] = ["url": "https://example.com", "dataStoreID": storeID.uuidString, "pageZoom": 40.0]
        XCTAssertEqual(try ShortcutConfig(plistDictionary: dictionary).webApp?.pageZoom, 3.0)
    }

    func testCorruptWebAppThrowsConfigCorrupt() {
        var badStore = makeShortcut(webApp: nil).plistDictionary()
        badStore["webApp"] = ["url": "https://example.com", "dataStoreID": "not-a-uuid"]
        var missingURL = makeShortcut(webApp: nil).plistDictionary()
        missingURL["webApp"] = ["dataStoreID": storeID.uuidString]
        var badAgent = makeShortcut(webApp: nil).plistDictionary()
        badAgent["webApp"] = ["url": "https://example.com", "dataStoreID": storeID.uuidString, "userAgent": "netscape"]
        for dictionary in [badStore, missingURL, badAgent] {
            XCTAssertThrowsError(try ShortcutConfig(plistDictionary: dictionary)) { error in
                guard case LauncherError.configCorrupt = error else {
                    return XCTFail("expected configCorrupt, got \(error)")
                }
            }
        }
    }

    // MARK: WebAppURLValidator

    func testValidatorAcceptsHTTPSAddresses() throws {
        XCTAssertEqual(try WebAppURLValidator.validate("https://web.whatsapp.com").absoluteString, "https://web.whatsapp.com")
        XCTAssertEqual(try WebAppURLValidator.validate("  https://outlook.office.com/mail/\n").absoluteString, "https://outlook.office.com/mail/")
        XCTAssertEqual(try WebAppURLValidator.validate("HTTPS://Example.com/Path?x=1").host, "Example.com")
        XCTAssertEqual(try WebAppURLValidator.validate("https://localhost:8443/app").port, 8443)
    }

    func testValidatorRejectsEverythingElse() {
        let rejected = [
            "", "   ", "example.com", "www.example.com/path", "http://example.com", "ftp://example.com",
            "mailto:me@example.com", "javascript:alert(1)", "about:blank", "https://", "https:///path", "https://:443",
            "https://exa mple.com", "https://user:secret@example.com", "https://trusted.com@evil.example",
        ]
        for string in rejected {
            XCTAssertThrowsError(try WebAppURLValidator.validate(string), string) { error in
                XCTAssertEqual(error as? WebAppURLError, .invalidAddress, string)
            }
        }
    }

    func testValidatorErrorCopy() {
        XCTAssertEqual(WebAppURLError.invalidAddress.errorDescription, "Enter an https:// address")
        XCTAssertEqual(WebAppURLError.invalidAddress.localizedDescription, "Enter an https:// address")
    }
}
