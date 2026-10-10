import XCTest
@testable import DuplicatorCore

final class SecretMaskingTests: XCTestCase {
    func testSpecPatternAndMask() {
        XCTAssertEqual(SecretMasking.secretKeyPattern, "(?i)secret|token|key|password|passwd|credential")
        XCTAssertEqual(SecretMasking.maskedValue, "••••••")
    }

    func testSecretLookingKeysAreMaskedCaseInsensitively() {
        let secretKeys = [
            "API_TOKEN", "client_secret", "AWS_ACCESS_KEY_ID", "DB_PASSWORD", "PASSWD",
            "GOOGLE_APPLICATION_CREDENTIALS", "github_Token", "Monkey",
        ]
        let plainKeys = ["PATH", "HOME", "LANG", "MAD_SHORTCUT_NAME", "CFFIXED_USER_HOME"]
        var environment: [String: String] = [:]
        for key in secretKeys + plainKeys {
            environment[key] = "value-of-\(key)"
        }
        let masked = SecretMasking.mask(environment)
        XCTAssertEqual(Set(masked.keys), Set(environment.keys))
        for key in secretKeys {
            XCTAssertEqual(masked[key], "••••••", key)
        }
        for key in plainKeys {
            XCTAssertEqual(masked[key], "value-of-\(key)", key)
        }
    }

    func testEmptyEnvironment() {
        XCTAssertEqual(SecretMasking.mask([:]), [:])
    }

    func testMaskArgumentsHidesSecretValues() {
        let arguments = [
            "--api-key", "hunter2", "--token=not-a-real-token", "-password", "pw", "--plain", "visible", "positional",
            "API_TOKEN=leaked",
        ]
        XCTAssertEqual(SecretMasking.maskArguments(arguments), [
            "--api-key", "••••••", "--token=••••••", "-password", "••••••", "--plain", "visible", "positional",
            "API_TOKEN=••••••",
        ])
    }

    func testMaskArgumentsLeavesFlagsAndPlannerArgumentsAlone() {
        // A secret flag followed by another flag has no value to hide.
        XCTAssertEqual(SecretMasking.maskArguments(["--token", "--verbose", "x"]), ["--token", "--verbose", "x"])
        // Every argument DataSeparationPlanner adds stays readable.
        let planner = [
            "--user-data-dir=/tmp/data", "--profile", "/tmp/profile", "--no-remote", "-data", "/tmp/workspace",
            "-configuration", "/tmp/configuration", "-NSRequiresAquaSystemAppearance", "YES", "--force-dark-mode",
            "-AppleLanguages", "(de)", "-AppleLocale", "de",
        ]
        XCTAssertEqual(SecretMasking.maskArguments(planner), planner)
        XCTAssertEqual(SecretMasking.maskArguments([]), [])
        // Over-masking is accepted: a flag that merely contains "key" hides its value too.
        XCTAssertEqual(SecretMasking.maskArguments(["--use-mock-keychain", "value"]), ["--use-mock-keychain", "••••••"])
    }

    func testMaskLogLineMasksArgvAndEnvironmentWords() {
        XCTAssertEqual(
            SecretMasking.maskLogLine("2026-10-01T09:00:00Z argv --api-key hunter2 --token=abc --plain v"),
            "2026-10-01T09:00:00Z argv --api-key •••••• --token=•••••• --plain v"
        )
        XCTAssertEqual(
            SecretMasking.maskLogLine("2026-10-01T09:00:00Z env GITHUB_TOKEN=leaked"),
            "2026-10-01T09:00:00Z env GITHUB_TOKEN=••••••"
        )
        let plain = "2026-10-01T09:00:00Z config name=Claude Work mode=dockShortcut data=auto"
        XCTAssertEqual(SecretMasking.maskLogLine(plain), plain)
        XCTAssertEqual(SecretMasking.maskLogLine(""), "")
    }
}
