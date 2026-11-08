import Foundation
import Security

/// Antigravity 写入登录钥匙串的 OAuth 凭据（service=`gemini`，account=`antigravity`，
/// 等价 `security find-generic-password -s gemini -a antigravity -w`）。
///
/// Keychain 值形如 `go-keyring-base64:<base64>`，base64 解码后是 JSON：
/// `{token: {access_token, token_type, refresh_token, expiry(ISO8601 带时区),
/// expires_in}, auth_method: "consumer", id_token_email, writer_id}`。
///
/// 额度路径只消费 `access_token` / `expiry` / `id_token_email`：
/// - `refresh_token` 有意不建模（JSONDecoder 忽略未声明键）——token 由 Antigravity
///   客户端自行续期，监控侧禁止用 refresh_token 发起任何网络刷新（config 的
///   `allowTokenRefresh` 强制 false，手改为 true 走配置解码错误路径）。
/// - `expiry` 为 ISO8601 带时区字符串，用 `DateParser` 解析后与本地时钟比较判定
///   过期；过期即抛 `QuotaError.credentialExpired`，不发任何网络请求。
struct AntigravityCredential: Equatable, Sendable {
    let accessToken: String
    let expiry: Date
    /// Keychain `id_token_email`（登录邮箱）；空白视为缺失。
    let email: String?

    /// `now >= expiry` 即过期（纯本地时钟判定，不做任何网络校验）。
    func isExpired(now: Date = Date()) -> Bool {
        now >= expiry
    }

    static let keychainValuePrefix = "go-keyring-base64:"

    /// 解析 Keychain 条目原始值。结构不合法（前缀缺失 / base64 / JSON / 必填字段
    /// 缺失或 expiry 不可解析）返回 nil，调用方按「凭据不可读」处理。
    static func parse(keychainValue rawValue: String, now: Date = Date()) -> AntigravityCredential? {
        guard rawValue.hasPrefix(keychainValuePrefix) else { return nil }
        let base64 = String(rawValue.dropFirst(keychainValuePrefix.count))
        guard let payload = Data(base64Encoded: base64) else { return nil }
        return parse(payload: payload, now: now)
    }

    /// 直接解析 base64 解码后的 JSON 载荷。
    static func parse(payload: Data, now: Date = Date()) -> AntigravityCredential? {
        guard let decoded = try? JSONDecoder().decode(Payload.self, from: payload) else { return nil }
        guard let token = decoded.token,
              let accessToken = StringUtilities.trimmedOrNil(token.accessToken),
              let expiry = token.expiry.flatMap(DateParser.parse) else {
            return nil
        }
        return AntigravityCredential(
            accessToken: accessToken,
            expiry: expiry,
            email: StringUtilities.trimmedOrNil(decoded.idTokenEmail)
        )
    }

    /// 只声明监控侧消费的字段；`refresh_token` / `writer_id` / `auth_method` /
    /// `token_type` / `expires_in` 等键由 JSONDecoder 按未知键忽略。键名为
    /// Go 序列化的 snake_case（实测形态）。
    private struct Payload: Decodable {
        struct Token: Decodable {
            let accessToken: String?
            let expiry: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case expiry
            }
        }

        let token: Token?
        let idTokenEmail: String?

        enum CodingKeys: String, CodingKey {
            case token
            case idTokenEmail = "id_token_email"
        }
    }
}

/// 登录钥匙串读取（Antigravity 凭据条目）。读取失败或条目不存在返回 nil。
///
/// 2.5.0 起另有 `readOutcome()` 三态读取（启动预检专用），本 enum 的既有
/// `readCredential()` / `readKeychainValue()` 契约与测试护栏不变。
enum AntigravityKeychain {
    static let service = "gemini"
    static let account = "antigravity"

    /// xctest 进程识别，两个信号任一命中即视为测试进程：
    /// - `XCTestConfigurationFilePath`：Xcode 测试运行器注入的环境变量；
    /// - `NSClassFromString("XCTestCase")`：XCTest 框架已加载即命中——SwiftPM 的
    ///   `swift test` 直接把 .xctest bundle 当可执行文件运行，**不设置**上述环境
    ///   变量（2026-11-08 实测），框架加载检测才是关键信号。
    static let isRunningInTestProcess =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil

    /// 读 Keychain 条目并解析凭据；任何一步失败都返回 nil（等价
    /// `security find-generic-password -s gemini -a antigravity -w` 读不到或值不合法）。
    static func readCredential() -> AntigravityCredential? {
        guard let rawValue = readKeychainValue() else { return nil }
        return AntigravityCredential.parse(keychainValue: rawValue)
    }

    /// 原始条目值（含 `go-keyring-base64:` 前缀）。
    ///
    /// **测试进程护栏**：xctest 二进制每次构建产物都在变化，永远不在凭据条目的
    /// ACL 内，真实调用 `SecItemCopyMatching` 会每次触发系统授权弹窗（用户每次
    /// 编译运行测试都弹 gemini 授权框）。测试必须通过 `AntigravityFetcher` 的
    /// `credentialReader` 注入 fixture（有效 / 过期 / nil 三种）；此护栏兜底保证
    /// 即使未来某个测试忘记注入，这里也只走「无凭据」路径，不再触碰 SecItem。
    static func readKeychainValue() -> String? {
        if isRunningInTestProcess { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Keychain 条目的三态读取结论（2.5.0 启动预检专用）。
    enum KeychainReadOutcome: Equatable, Sendable {
        /// 条目存在且读出原始值（`go-keyring-base64:` 前缀形态，结构可解析性由
        /// `AntigravityCredential.parse` 另行判定）。
        case readable(String)
        /// 条目不存在（未登录）——软不可用，登录后自动恢复。
        case entryMissing
        /// 系统授权被拒 / 不可读（errSecInteractionNotAllowed、errSecAuthFailed
        /// 等一切非「条目不存在」的失败）——自动 disable 钥匙串兜底开关。
        case accessDenied
    }

    /// 三态读取：区分「条目不存在（未登录）」与「系统授权被拒/不可读」——
    /// 预检对两者采取不同策略（软不可用 vs 自动 disable），而 `readKeychainValue()`
    /// 把两者都折叠成 nil。
    ///
    /// **测试进程护栏**与 `readKeychainValue()` 同款：xctest 进程内恒返回
    /// `.entryMissing`，绝不触碰 SecItem（漏注入 seam 的预检测试只走「条目
    /// 不存在」路径，不弹系统授权框）。
    static func readOutcome() -> KeychainReadOutcome {
        if isRunningInTestProcess { return .entryMissing }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                return .entryMissing
            }
            return .readable(value)
        case errSecItemNotFound:
            return .entryMissing
        default:
            return .accessDenied
        }
    }
}
