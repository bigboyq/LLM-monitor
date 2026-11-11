import XCTest
import CryptoKit
@testable import LLM_monitor

/// `enc:v2:` 凭证密文（ZCode 客户端 3.18.0 起）的解密测试：
/// `os` 变体（Keychain 密钥，注入假读取器）/ `env` 变体（managed secret）的
/// round-trip、失败路径与 `enc:v1:` / 明文兼容性。全程不触碰真实 SecItem。
final class GlmZcodeCredentialEncV2Tests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlmZcodeCredentialEncV2Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    // MARK: - 测试内加密工具（与客户端 enc:v2 载荷格式对齐）

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private func randomKeyData(count: Int = 32) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    private func sealEncV2(
        _ plaintext: String,
        key: SymmetricKey,
        variant: String,
        keyId: String? = nil
    ) throws -> String {
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        let keyPart = keyId.map { "\($0):" } ?? ""
        return "enc:v2:\(variant):\(keyPart)"
            + base64URLEncode(Data(sealed.nonce)) + "."
            + base64URLEncode(sealed.tag) + "."
            + base64URLEncode(sealed.ciphertext)
    }

    // MARK: - os 变体（Keychain 密钥）

    func testOsVariantRoundTripWithInjectedKeychain() throws {
        let keyData = randomKeyData()
        let keyB64URL = base64URLEncode(keyData)
        let plaintext = "eyJhbGciOiJIUzI1NiJ9.os-variant-real-jwt-token"
        let credentialsPath = "/Users/tester/.zcode/v2/credentials.json"
        let encrypted = try sealEncV2(
            plaintext,
            key: SymmetricKey(data: keyData),
            variant: "os",
            keyId: "0123456789abcdef01234567"
        )

        var seenAccounts: [String] = []
        let decrypted = GlmZcodeCredentialReader.decryptCredential(
            encrypted,
            credentialsURL: URL(fileURLWithPath: credentialsPath),
            keychainReader: { account in
                seenAccounts.append(account)
                return keyB64URL
            }
        )
        XCTAssertEqual(decrypted, plaintext)

        // account = SHA256(credentials.json 绝对路径) 的 64 位小写 hex
        XCTAssertEqual(
            seenAccounts,
            [GlmZcodeCredentialReader.keychainAccount(forCredentialsPath: credentialsPath)]
        )
        let account = try XCTUnwrap(seenAccounts.first)
        XCTAssertEqual(account.count, 64)
        XCTAssertEqual(account, account.lowercased(), "account 应为小写 hex")
        XCTAssertTrue(account.allSatisfy { $0.isHexDigit })
    }

    /// 自定义 authPath 场景：account 由传入的 credentialsURL 推导，而非默认路径
    func testOsVariantUsesResolvedCredentialsPathForAccount() throws {
        let keyData = randomKeyData()
        let encrypted = try sealEncV2(
            "jwt-custom-path",
            key: SymmetricKey(data: keyData),
            variant: "os"
        )
        let customURL = tempDirectory.appendingPathComponent("credentials.json")
        let decrypted = GlmZcodeCredentialReader.decryptCredential(
            encrypted,
            credentialsURL: customURL,
            keychainReader: { account in
                XCTAssertEqual(
                    account,
                    GlmZcodeCredentialReader.keychainAccount(forCredentialsPath: customURL.path)
                )
                return self.base64URLEncode(keyData)
            }
        )
        XCTAssertEqual(decrypted, "jwt-custom-path")
    }

    func testOsVariantFailurePaths() throws {
        let keyData = randomKeyData()
        let encrypted = try sealEncV2(
            "token",
            key: SymmetricKey(data: keyData),
            variant: "os",
            keyId: "aabbccddeeff001122334455"
        )
        let url = URL(fileURLWithPath: "/Users/tester/.zcode/v2/credentials.json")

        // Keychain 条目不存在 / 不可读 → nil
        XCTAssertNil(GlmZcodeCredentialReader.decryptCredential(
            encrypted, credentialsURL: url, keychainReader: { _ in nil }
        ))
        // 密钥条目不是 32 字节（base64url 解码后 16B）→ nil
        let shortKey = base64URLEncode(randomKeyData(count: 16))
        XCTAssertNil(GlmZcodeCredentialReader.decryptCredential(
            encrypted, credentialsURL: url, keychainReader: { _ in shortKey }
        ))
        // 密钥条目不是合法 base64url → nil
        XCTAssertNil(GlmZcodeCredentialReader.decryptCredential(
            encrypted, credentialsURL: url, keychainReader: { _ in "!!!not-base64!!!" }
        ))
        // 测试进程内默认真实读取器（护栏恒 nil，不触碰 SecItem）→ nil
        XCTAssertNil(GlmZcodeCredentialReader.decryptCredential(
            encrypted, credentialsURL: url
        ))
    }

    // MARK: - env 变体（managed secret）

    func testEnvVariantRoundTripWithManagedSecret() throws {
        let secret = "env-managed-secret-0123456789abcdef-3456"
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        let plaintext = "oauth-bigmodel-access-token-payload"

        // 无 keyId 的 env 载荷
        let encryptedNoKeyId = try sealEncV2(plaintext, key: key, variant: "env")
        let result = GlmZcodeCredentialReader.decryptEncV2(
            encryptedNoKeyId,
            credentialsPath: "/Users/tester/.zcode/v2/credentials.json",
            managedSecret: secret,
            keychainReader: nil
        )
        XCTAssertEqual(result, plaintext)

        // decryptCredential 全链路（managed secret 经参数注入；Keychain 不应被触碰）
        let decrypted = GlmZcodeCredentialReader.decryptCredential(
            encryptedNoKeyId,
            credentialsURL: URL(fileURLWithPath: "/Users/tester/.zcode/v2/credentials.json"),
            environmentSecret: secret,
            keychainReader: { _ in
                XCTFail("env 变体不应读取 Keychain")
                return nil
            }
        )
        XCTAssertEqual(decrypted, plaintext)
    }

    func testEnvVariantFailurePaths() throws {
        let secret = "correct-managed-secret-0123456789abcdef"
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        let encrypted = try sealEncV2("token", key: key, variant: "env")

        // 无 managed secret → nil
        XCTAssertNil(GlmZcodeCredentialReader.decryptEncV2(
            encrypted, credentialsPath: "/x/credentials.json", managedSecret: nil, keychainReader: nil
        ))
        // secret 不匹配（GCM tag 校验失败）→ nil
        XCTAssertNil(GlmZcodeCredentialReader.decryptEncV2(
            encrypted, credentialsPath: "/x/credentials.json",
            managedSecret: "wrong-managed-secret-0123456789abcdef", keychainReader: nil
        ))
        // 未知变体 → nil
        XCTAssertNil(GlmZcodeCredentialReader.decryptEncV2(
            "enc:v2:kms:aaaa.bbbb.cccc", credentialsPath: "/x/credentials.json",
            managedSecret: secret, keychainReader: nil
        ))
    }

    /// 坏 tag（密文被篡改）必须失败返回 nil，不得放出损坏明文
    func testTamperedTagFailsClosed() throws {
        let secret = "tamper-test-managed-secret-0123456789ab"
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        let sealed = try AES.GCM.seal(Data("payload".utf8), using: key)
        var tag = [UInt8](sealed.tag)
        tag[0] ^= 0xFF
        let encrypted = "enc:v2:env:"
            + base64URLEncode(Data(sealed.nonce)) + "."
            + base64URLEncode(Data(tag)) + "."
            + base64URLEncode(sealed.ciphertext)
        XCTAssertNil(GlmZcodeCredentialReader.decryptEncV2(
            encrypted, credentialsPath: "/x/credentials.json",
            managedSecret: secret, keychainReader: nil
        ))
    }

    /// keyId 段不参与解密：标准 24hex 与任意非 hex 内容都能容忍
    func testKeyIdSegmentIgnoredAndToleratesArbitraryContent() throws {
        let secret = "keyid-test-managed-secret-0123456789ab"
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        for keyId in ["0123456789abcdef01234567", "zz-not-hex-!!!", ""] {
            let encrypted = try sealEncV2("payload", key: key, variant: "env", keyId: keyId)
            let decrypted = GlmZcodeCredentialReader.decryptEncV2(
                encrypted, credentialsPath: "/x/credentials.json",
                managedSecret: secret, keychainReader: nil
            )
            XCTAssertEqual(decrypted, "payload", "keyId=\(keyId.debugDescription) 不应影响解密")
        }
    }

    // MARK: - v1 / 明文兼容

    func testV1AndPlaintextPathsDoNotTouchKeychain() throws {
        // 明文原样返回，不调 Keychain
        var keychainCalled = false
        XCTAssertEqual(
            GlmZcodeCredentialReader.decryptCredential(
                "plain-token",
                keychainReader: { _ in
                    keychainCalled = true
                    return nil
                }
            ),
            "plain-token"
        )
        XCTAssertFalse(keychainCalled)

        // enc:v1 路径同样不触发 Keychain
        let home = "/Users/testuser"
        let user = "testuser"
        guard let v1Encrypted = GlmZcodeCredentialReader.encryptCredential(
            "v1-token", homeDirectory: home, userName: user
        ) else {
            XCTFail("Failed to encrypt v1")
            return
        }
        XCTAssertEqual(
            GlmZcodeCredentialReader.decryptCredential(
                v1Encrypted,
                homeDirectory: home,
                userName: user,
                keychainReader: { _ in
                    keychainCalled = true
                    return nil
                }
            ),
            "v1-token"
        )
        XCTAssertFalse(keychainCalled, "v1 密钥派生不依赖 Keychain")
    }

    // MARK: - managed secret 接线（loadTokens 层）

    /// credential-secret 文件作为 managed secret；ZCODE_CREDENTIAL_SECRET 优先于文件
    func testLoadTokensResolvesManagedSecretFromFileAndEnvPriority() throws {
        let fileSecret = "file-managed-secret-0123456789abcdef!"
        let fileKey = SymmetricKey(data: SHA256.hash(data: Data(fileSecret.utf8)))
        let credsURL = tempDirectory.appendingPathComponent("credentials.json")

        let encryptedJwt = try sealEncV2("jwt-from-file-secret", key: fileKey, variant: "env")
        let encryptedBigmodel = try sealEncV2("bigmodel-from-file-secret", key: fileKey, variant: "env")
        let json = """
        {
          "zcodejwttoken": "\(encryptedJwt)",
          "oauth:bigmodel:access_token": "\(encryptedBigmodel)"
        }
        """
        try json.write(to: credsURL, atomically: true, encoding: .utf8)

        // 无环境变量：从同目录 credential-secret 文件取 secret
        let secretURL = tempDirectory.appendingPathComponent("credential-secret")
        try Data(fileSecret.utf8).write(to: secretURL)
        let loaded = GlmZcodeCredentialReader.loadTokens(
            from: credsURL,
            homeDirectory: "/Users/testuser",
            userName: "testuser",
            environmentSecret: nil
        )
        XCTAssertEqual(loaded.jwtToken, "jwt-from-file-secret")
        XCTAssertEqual(loaded.bigmodelAccessToken, "bigmodel-from-file-secret")

        // 环境变量存在时优先于文件：文件 secret 加密的密文用环境 secret 解不开 → nil
        let envLoaded = GlmZcodeCredentialReader.loadTokens(
            from: credsURL,
            homeDirectory: "/Users/testuser",
            userName: "testuser",
            environmentSecret: "env-secret-overrides-file-0123456"
        )
        XCTAssertNil(envLoaded.jwtToken, "managed secret 应取环境变量而非文件")
        XCTAssertNil(envLoaded.bigmodelAccessToken)
    }

    /// credential-secret 文件长度越界（<32 字节）→ 视为无 managed secret → 解密失败
    func testLoadTokensRejectsUndersizedSecretFile() throws {
        let fileSecret = "file-managed-secret-0123456789abcdef!"
        let fileKey = SymmetricKey(data: SHA256.hash(data: Data(fileSecret.utf8)))
        let credsURL = tempDirectory.appendingPathComponent("credentials.json")
        let encryptedJwt = try sealEncV2("jwt", key: fileKey, variant: "env")
        try """
        {"zcodejwttoken": "\(encryptedJwt)"}
        """.write(to: credsURL, atomically: true, encoding: .utf8)
        try Data("too-short-secret".utf8).write(to: tempDirectory.appendingPathComponent("credential-secret"))

        let loaded = GlmZcodeCredentialReader.loadTokens(
            from: credsURL,
            homeDirectory: "/Users/testuser",
            userName: "testuser",
            environmentSecret: nil
        )
        XCTAssertNil(loaded.jwtToken, "越界 secret 文件不应被采用")
    }

    /// v2 解密失败置 nil（走「缺失」路径），不影响另一路明文字段
    func testLoadTokensV2FailureYieldsNilWithoutBreakingPlaintext() throws {
        let credsURL = tempDirectory.appendingPathComponent("credentials.json")
        let json = """
        {
          "zcodejwttoken": "enc:v2:os:0123456789abcdef01234567:AAAA.BBBB.CCCC",
          "oauth:bigmodel:access_token": "plain-bigmodel-token"
        }
        """
        try json.write(to: credsURL, atomically: true, encoding: .utf8)

        // 测试进程内真实 Keychain 读取器被护栏拦截（恒 nil）→ os 密文解不开
        let loaded = GlmZcodeCredentialReader.loadTokens(
            from: credsURL,
            homeDirectory: "/Users/testuser",
            userName: "testuser",
            environmentSecret: nil
        )
        XCTAssertNil(loaded.jwtToken, "v2 os 解密失败应置 nil，而不是把密文当 token")
        XCTAssertEqual(loaded.bigmodelAccessToken, "plain-bigmodel-token")
    }
}
