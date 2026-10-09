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
}
