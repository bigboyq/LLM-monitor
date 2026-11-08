import Foundation
import XCTest
@testable import LLM_monitor

/// 测试共享的凭据 fixture。任何测试构造 `AntigravityFetcher` 都必须经
/// `credentialReader` 注入这里的三种形态之一（有效 / 过期 / `nil`），
/// 禁止触达真实钥匙串：xctest 二进制每次构建都在变化、不在凭据条目的 ACL 内，
/// 真实读取会每次弹系统授权框；`AntigravityKeychain` 在测试进程内另有护栏兜底
/// （见 `readKeychainValue`），漏注入只会退化为「无凭据」路径，不再弹窗。
enum AntigravityCredentialFixtures {
    /// 未过期的有效凭据（expiry = now + 1h）。
    static func valid(now: Date = Date()) -> AntigravityCredential {
        AntigravityCredential(
            accessToken: "test-access-token",
            expiry: now.addingTimeInterval(3600),
            email: "user@example.com"
        )
    }

    /// 已过期凭据（expiry = now − 1h）。
    static func expired(now: Date = Date()) -> AntigravityCredential {
        AntigravityCredential(
            accessToken: "test-access-token",
            expiry: now.addingTimeInterval(-3600),
            email: "user@example.com"
        )
    }
}

/// Antigravity Keychain 凭据解析（`AntigravityCredential` / `AntigravityKeychain`）：
/// go-keyring 前缀 + base64(JSON)、ISO8601 带时区 expiry、本地过期判定边界，
/// 「refresh_token 不进入凭据结构」的形状约束，以及测试进程护栏。
final class AntigravityCredentialTests: XCTestCase {
    // MARK: - Fixtures

    /// 构造 go-keyring 格式的 Keychain 原始值：`go-keyring-base64:` + base64(JSON)。
    private func keychainValue(json: String) -> String {
        "go-keyring-base64:" + Data(json.utf8).base64EncodedString()
    }

    /// 与实测 Keychain 载荷同形：token.{access_token, token_type, refresh_token,
    /// expiry(ISO 带时区), expires_in} + auth_method / id_token_email / writer_id。
    private func payloadJSON(
        accessToken: String = "ya29.test-token",
        expiry: String = "2026-11-08T09:00:00+08:00",
        email: String? = "alice@example.com"
    ) -> String {
        let emailField = email.map { "\"id_token_email\":\"\($0)\"," } ?? ""
        return "{"
            + "\"token\":{"
            + "\"access_token\":\"\(accessToken)\","
            + "\"token_type\":\"Bearer\","
            + "\"refresh_token\":\"1//refresh-must-never-be-used\","
            + "\"expiry\":\"\(expiry)\","
            + "\"expires_in\":3599},"
            + emailField
            + "\"auth_method\":\"consumer\","
            + "\"writer_id\":\"writer-1\"}"
    }

    private static func expectedDate(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: iso))
    }

    // MARK: - go-keyring 前缀 + ISO 时区

    func testParseKeychainValueWithOffsetTimezone() throws {
        let now = Date(timeIntervalSince1970: 1_793_577_600) // 2026-11-02T04:00:00Z，早于 expiry
        let credential = try XCTUnwrap(
            AntigravityCredential.parse(
                keychainValue: keychainValue(json: payloadJSON()),
                now: now
            )
        )
        XCTAssertEqual(credential.accessToken, "ya29.test-token")
        XCTAssertEqual(credential.email, "alice@example.com")
        // 2026-11-08T09:00:00+08:00 == 2026-11-08T01:00:00Z
        XCTAssertEqual(
            credential.expiry,
            try Self.expectedDate("2026-11-08T01:00:00Z")
        )
        XCTAssertFalse(credential.isExpired(now: now))
    }

    func testParseAcceptsFractionalSecondsAndZSuffix() throws {
        let now = Date(timeIntervalSince1970: 1_793_577_600) // 2026-11-02，早于 expiry
        let credential = try XCTUnwrap(
            AntigravityCredential.parse(
                keychainValue: keychainValue(
                    json: payloadJSON(expiry: "2026-11-08T01:00:00.250Z")
                ),
                now: now
            )
        )
        XCTAssertEqual(credential.expiry, try Self.expectedDate("2026-11-08T01:00:00.250Z"))
    }

    // MARK: - 过期判定（now >= expiry 即过期）

    func testIsExpiredBoundary() throws {
        let expiry = try Self.expectedDate("2026-11-08T01:00:00Z")
        let credential = AntigravityCredential(
            accessToken: "tok",
            expiry: expiry,
            email: nil
        )
        // 恰好等于 expiry 视为过期（now >= expiry）。
        XCTAssertTrue(credential.isExpired(now: expiry))
        XCTAssertTrue(credential.isExpired(now: expiry.addingTimeInterval(1)))
        XCTAssertFalse(credential.isExpired(now: expiry.addingTimeInterval(-1)))
    }

    // MARK: - 结构约束：只保留 access_token / expiry / id_token_email

    func testParseKeepsOnlyConsumedFields() throws {
        let now = Date(timeIntervalSince1970: 1_793_577_600) // 2026-11-02，早于 expiry
        let credential = try XCTUnwrap(
            AntigravityCredential.parse(
                keychainValue: keychainValue(json: payloadJSON()),
                now: now
            )
        )
        // refresh_token / writer_id / auth_method / token_type / expires_in 不进
        // 结构（JSONDecoder 忽略未声明键），凭据 Equatable 只由三个消费字段组成。
        XCTAssertEqual(
            credential,
            AntigravityCredential(
                accessToken: "ya29.test-token",
                expiry: try Self.expectedDate("2026-11-08T01:00:00Z"),
                email: "alice@example.com"
            )
        )
    }

    func testBlankEmailAndTokenTreatedAsMissing() throws {
        let now = Date(timeIntervalSince1970: 1_793_577_600) // 2026-11-02，早于 expiry
        let blankEmail = try XCTUnwrap(
            AntigravityCredential.parse(
                keychainValue: keychainValue(json: payloadJSON(email: "   ")),
                now: now
            )
        )
        XCTAssertNil(blankEmail.email)

        let noEmail = try XCTUnwrap(
            AntigravityCredential.parse(
                keychainValue: keychainValue(json: payloadJSON(email: nil)),
                now: now
            )
        )
        XCTAssertNil(noEmail.email)

        // access_token 缺失/空白 → 凭据不可用。
        XCTAssertNil(
            AntigravityCredential.parse(
                keychainValue: keychainValue(json: payloadJSON(accessToken: "")),
                now: now
            )
        )
    }

    // MARK: - 结构不合法 → nil

    func testParseRejectsMalformedKeychainValues() {
        let now = Date(timeIntervalSince1970: 1_793_577_600) // 2026-11-02，早于 expiry

        // 缺 go-keyring 前缀（例如 jetski-standalone-oauth-token 的裸 JSON）。
        XCTAssertNil(
            AntigravityCredential.parse(keychainValue: payloadJSON(), now: now)
        )
        // 非 base64。
        XCTAssertNil(
            AntigravityCredential.parse(keychainValue: "go-keyring-base64:not-base64!!", now: now)
        )
        // base64 后不是 JSON。
        XCTAssertNil(
            AntigravityCredential.parse(
                keychainValue: keychainValue(json: "not-json"),
                now: now
            )
        )
        // token 缺失。
        XCTAssertNil(
            AntigravityCredential.parse(
                keychainValue: keychainValue(json: #"{"id_token_email":"a@b.com"}"#),
                now: now
            )
        )
        // expiry 不可解析（DateParser 不认的纯文本）。
        XCTAssertNil(
            AntigravityCredential.parse(
                keychainValue: keychainValue(json: payloadJSON(expiry: "not-a-date")),
                now: now
            )
        )
        // expiry 缺失。
        XCTAssertNil(
            AntigravityCredential.parse(
                keychainValue: keychainValue(
                    json: #"{"token":{"access_token":"tok"},"id_token_email":"a@b.com"}"#
                ),
                now: now
            )
        )
    }

    // MARK: - 测试进程护栏（兜底）

    /// 兜底护栏：测试进程内禁止真实读钥匙串。开发机登录钥匙串里真实存在
    /// gemini/antigravity 条目（阶段一验收时已验证非空），本用例拿到 nil 只能
    /// 来自 `readKeychainValue` 的护栏分支——护栏若被移除，在有条目的机器上
    /// 此用例会失败（并重新引入每次构建弹授权框的问题）。
    func testKeychainReadIsRefusedInTestProcess() {
        XCTAssertTrue(AntigravityKeychain.isRunningInTestProcess)
        XCTAssertNil(AntigravityKeychain.readKeychainValue())
        XCTAssertNil(AntigravityKeychain.readCredential())
    }
}
