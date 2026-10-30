import XCTest
@testable import LLM_monitor

final class GlmZcodeCredentialReaderTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlmZcodeCredentialReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    func testDecryptPlaintextTokenReturnsAsIs() {
        let plaintext = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.test-raw-token"
        let result = GlmZcodeCredentialReader.decryptCredential(plaintext)
        XCTAssertEqual(result, plaintext)
    }

    func testEncryptAndDecryptRoundtripWithDefaultSecret() {
        let plaintext = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.signature"
        let home = "/Users/testuser"
        let user = "testuser"

        guard let encrypted = GlmZcodeCredentialReader.encryptCredential(
            plaintext,
            homeDirectory: home,
            userName: user
        ) else {
            XCTFail("Encrypt returned nil")
            return
        }

        XCTAssertTrue(encrypted.hasPrefix("enc:v1:"))
        let parts = encrypted.dropFirst("enc:v1:".count).split(separator: ".")
        XCTAssertEqual(parts.count, 3)

        let decrypted = GlmZcodeCredentialReader.decryptCredential(
            encrypted,
            homeDirectory: home,
            userName: user
        )
        XCTAssertEqual(decrypted, plaintext)
    }

    func testEncryptAndDecryptRoundtripWithEnvironmentSecret() {
        let plaintext = "secret-token-payload-12345"
        let customSecret = "custom-env-secret-xyz"

        guard let encrypted = GlmZcodeCredentialReader.encryptCredential(
            plaintext,
            environmentSecret: customSecret
        ) else {
            XCTFail("Encrypt returned nil")
            return
        }

        let decrypted = GlmZcodeCredentialReader.decryptCredential(
            encrypted,
            environmentSecret: customSecret
        )
        XCTAssertEqual(decrypted, plaintext)
    }

    func testDecryptFailsWithMismatchedSecret() {
        let plaintext = "secret-token-payload"
        guard let encrypted = GlmZcodeCredentialReader.encryptCredential(
            plaintext,
            homeDirectory: "/Users/userA",
            userName: "userA"
        ) else {
            XCTFail("Encrypt returned nil")
            return
        }

        let decrypted = GlmZcodeCredentialReader.decryptCredential(
            encrypted,
            homeDirectory: "/Users/userB",
            userName: "userB"
        )
        XCTAssertNil(decrypted, "Decryption with wrong secret should fail and return nil")
    }

    func testDecryptFailsWithCorruptedStructure() {
        // Less than 3 parts
        XCTAssertNil(GlmZcodeCredentialReader.decryptCredential("enc:v1:abc.def"))
        // Corrupted base64
        XCTAssertNil(GlmZcodeCredentialReader.decryptCredential("enc:v1:???." + "tag." + "ciphertext"))
        // Corrupted ciphertext
        let home = "/Users/testuser"
        let user = "testuser"
        guard let valid = GlmZcodeCredentialReader.encryptCredential("token", homeDirectory: home, userName: user) else {
            XCTFail("Failed to encrypt")
            return
        }
        let corrupted = valid + "corrupt"
        XCTAssertNil(GlmZcodeCredentialReader.decryptCredential(corrupted, homeDirectory: home, userName: user))
    }

    func testLoadDeviceMidFromJSON() throws {
        let fileURL = tempDirectory.appendingPathComponent("telemetry-state.json")
        let json = """
        {
          "deviceMid": "12345678-abcd-ef01-2345-6789abcdef01",
          "lastDailyActiveDate": "2026-10-30"
        }
        """
        try json.write(to: fileURL, atomically: true, encoding: .utf8)

        let mid = GlmZcodeCredentialReader.loadDeviceMid(from: fileURL)
        XCTAssertEqual(mid, "12345678-abcd-ef01-2345-6789abcdef01")

        // Missing file
        let missingURL = tempDirectory.appendingPathComponent("nonexistent.json")
        XCTAssertNil(GlmZcodeCredentialReader.loadDeviceMid(from: missingURL))

        // Empty string
        let emptyMidURL = tempDirectory.appendingPathComponent("empty.json")
        try "{\"deviceMid\":\"\"}".write(to: emptyMidURL, atomically: true, encoding: .utf8)
        XCTAssertNil(GlmZcodeCredentialReader.loadDeviceMid(from: emptyMidURL))
    }

    func testLoadJwtTokenFromJSON() throws {
        let home = "/Users/testuser"
        let user = "testuser"
        let expectedToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.decrypted-token-content"

        guard let encrypted = GlmZcodeCredentialReader.encryptCredential(
            expectedToken,
            homeDirectory: home,
            userName: user
        ) else {
            XCTFail("Failed to encrypt token")
            return
        }

        let fileURL = tempDirectory.appendingPathComponent("credentials.json")
        let json = """
        {
          "zcodejwttoken": "\(encrypted)",
          "otherKey": "otherValue"
        }
        """
        try json.write(to: fileURL, atomically: true, encoding: .utf8)

        let loaded = GlmZcodeCredentialReader.loadJwtToken(
            from: fileURL,
            homeDirectory: home,
            userName: user
        )
        XCTAssertEqual(loaded, expectedToken)
    }

    func testLoadCredentialsCombinesBoth() throws {
        let home = "/Users/testuser"
        let user = "testuser"
        let expectedToken = "jwt-sample-token"
        let expectedBigmodel = "bigmodel-sample-token"
        let expectedMid = "test-mid-uuid"

        let telemURL = tempDirectory.appendingPathComponent("telemetry-state.json")
        try "{\"deviceMid\":\"\(expectedMid)\"}".write(to: telemURL, atomically: true, encoding: .utf8)

        let credsURL = tempDirectory.appendingPathComponent("credentials.json")
        guard let encryptedJwt = GlmZcodeCredentialReader.encryptCredential(
            expectedToken,
            homeDirectory: home,
            userName: user
        ),
        let encryptedBigmodel = GlmZcodeCredentialReader.encryptCredential(
            expectedBigmodel,
            homeDirectory: home,
            userName: user
        ) else {
            XCTFail("Failed to encrypt")
            return
        }
        let json = """
        {
          "zcodejwttoken": "\(encryptedJwt)",
          "oauth:bigmodel:access_token": "\(encryptedBigmodel)"
        }
        """
        try json.write(to: credsURL, atomically: true, encoding: .utf8)

        let creds = GlmZcodeCredentialReader.loadCredentials(
            telemetryStateURL: telemURL,
            credentialsURL: credsURL,
            homeDirectory: home,
            userName: user
        )

        XCTAssertEqual(creds.deviceMid, expectedMid)
        XCTAssertEqual(creds.jwtToken, expectedToken)
        XCTAssertEqual(creds.bigmodelAccessToken, expectedBigmodel)
        XCTAssertTrue(creds.hasCredentials)
        XCTAssertTrue(creds.hasFullCredentials)
    }

    func testLiveZcodeCredentialsIfPresent() {
        // Reads from user ~/.zcode/v2 default location if it exists on the host
        let defaultCreds = GlmZcodeCredentialReader.loadCredentials()
        if FileManager.default.fileExists(atPath: GlmZcodeCredentialReader.defaultTelemetryStateURL.path) {
            XCTAssertNotNil(defaultCreds.deviceMid)
            XCTAssertFalse(defaultCreds.deviceMid?.isEmpty ?? true)
        }
        if FileManager.default.fileExists(atPath: GlmZcodeCredentialReader.defaultCredentialsURL.path) {
            XCTAssertNotNil(defaultCreds.jwtToken)
            XCTAssertTrue(defaultCreds.jwtToken?.hasPrefix("eyJ") ?? false, "Real ZCode JWT token starts with eyJ")
            XCTAssertNotNil(defaultCreds.bigmodelAccessToken)
            XCTAssertTrue(defaultCreds.hasCredentials)
            XCTAssertTrue(defaultCreds.hasFullCredentials)
        }
    }
}
