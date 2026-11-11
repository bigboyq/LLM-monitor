import Foundation
import CryptoKit
import Security

/// ZCode 本地凭证快照（deviceMid、解密后的 JWT Token 与 BigModel Access Token）。
struct GlmZcodeCredentials: Equatable, Sendable {
    let deviceMid: String?
    let jwtToken: String?
    /// 本地读取时是 OAuth access token；发请求前可由 fetcher 替换为配置的 API Key。
    let bigmodelAccessToken: String?

    init(deviceMid: String?, jwtToken: String?, bigmodelAccessToken: String? = nil) {
        self.deviceMid = deviceMid
        self.jwtToken = jwtToken
        self.bigmodelAccessToken = bigmodelAccessToken
    }

    var hasCredentials: Bool {
        guard let jwtToken, !jwtToken.isEmpty else { return false }
        return true
    }

    /// 是否具备调用需双 Token 鉴权接口（如重置卡状态与 Start Plan 额度）的完整凭证
    var hasFullCredentials: Bool {
        guard let jwtToken, !jwtToken.isEmpty,
              let bigmodelAccessToken, !bigmodelAccessToken.isEmpty else {
            return false
        }
        return true
    }
}

/// 读取并解密 ZCode 本地运行环境中的凭证与设备标识。
///
/// 凭证存储规范（与 ZCode 客户端保持一致）：
/// 1. `deviceMid`：明文存储于 `~/.zcode/v2/telemetry-state.json`，格式为 UUID 字符串。
/// 2. `zcodejwttoken`：存储于 `~/.zcode/v2/credentials.json`。
///    - ZCode 客户端 3.18.0 起，token 由明文/`enc:v1:` 改为 `enc:v2:` 加密；
///    - `enc:v2:` 格式：`enc:v2:<variant>:[<keyId>:]<base64url(iv)>.<base64url(tag)>.<base64url(ciphertext)>`
///      （AES-256-GCM，iv 12B / tag 16B；`<keyId>` 为客户端密钥编号提示，不参与解密）；
///    - `os` 变体密钥：macOS Keychain generic password（service = "ZCode Credential Encryption"，
///      account = SHA256(credentials.json 绝对路径).hex），条目 password 即 base64url 的
///      32 字节 AES key（直接解码使用，不再哈希）；
///    - `env` 变体密钥：SHA256(managed secret)——`ZCODE_CREDENTIAL_SECRET` 环境变量，
///      或 `<credentials.json 同目录>/credential-secret` 文件内容（32–4096 字节）；
///    - 若带有 `enc:v1:` 前缀，表示旧版 AES-256-GCM 加密：
///      `enc:v1:<base64url(iv)>.<base64url(tag)>.<base64url(ciphertext)>`，
///      密钥派生源：`ZCODE_CREDENTIAL_SECRET` 环境变量，或默认回退
///      `zcode-credential-fallback:darwin:<homeDirectory>:<userName>` 的 SHA256 摘要；
///    - 若无前缀，直接当作原始 Token 返回。
enum GlmZcodeCredentialReader {
    nonisolated static let defaultDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".zcode", isDirectory: true)
        .appendingPathComponent("v2", isDirectory: true)

    nonisolated static let defaultTelemetryStateURL = defaultDirectoryURL
        .appendingPathComponent("telemetry-state.json", isDirectory: false)

    nonisolated static let defaultCredentialsURL = defaultDirectoryURL
        .appendingPathComponent("credentials.json", isDirectory: false)

    private struct TelemetryStatePayload: Decodable {
        let deviceMid: String?
    }

    private struct CredentialsPayload: Decodable {
        enum CodingKeys: String, CodingKey {
            case zcodejwttoken
            case bigmodelAccessToken = "oauth:bigmodel:access_token"
        }

        let zcodejwttoken: String?
        let bigmodelAccessToken: String?
    }

    /// 解析 authPath 对应的 telemetry-state.json 与 credentials.json 文件 URL。
    /// - 若 authPath 为空，回退默认 ~/.zcode/v2 目录；
    /// - 若 authPath 指向目录或无扩展名，在该目录下拼接 telemetry-state.json 与 credentials.json；
    /// - 若 authPath 直接指向 credentials.json（或其它文件），以其所在父目录定位 telemetry-state.json。
    nonisolated static func resolveURLs(from authPath: String?) -> (telemetryStateURL: URL, credentialsURL: URL) {
        guard let authPath = authPath?.trimmingCharacters(in: .whitespacesAndNewlines), !authPath.isEmpty else {
            return (defaultTelemetryStateURL, defaultCredentialsURL)
        }
        // 输入法易把 `~` 打成全角 `～` (U+FF5E) / `˜` (U+02DC)；expandingTildeInPath 只认
        // ASCII `~`，不归一会让凭证静默找不到（2026-11-03 config 实际发生过）。
        let normalizedPath: String
        if let first = authPath.first, first == "～" || first == "˜" {
            normalizedPath = "~" + authPath.dropFirst()
        } else {
            normalizedPath = authPath
        }
        let rawURL = URL(fileURLWithPath: NSString(string: normalizedPath).expandingTildeInPath)
        let dirURL: URL
        let credsURL: URL
        if rawURL.hasDirectoryPath || rawURL.pathExtension.isEmpty {
            dirURL = rawURL
            credsURL = dirURL.appendingPathComponent("credentials.json", isDirectory: false)
        } else {
            dirURL = rawURL.deletingLastPathComponent()
            credsURL = rawURL
        }
        let telemetryURL = dirURL.appendingPathComponent("telemetry-state.json", isDirectory: false)
        return (telemetryURL, credsURL)
    }

    /// 判定指定 authPath 下本地 ZCode 凭证文件是否存在。
    nonisolated static func hasLocalAuth(authPath: String? = nil) -> Bool {
        let urls = resolveURLs(from: authPath)
        return FileManager.default.fileExists(atPath: urls.credentialsURL.path)
    }

    /// 根据可选自定义 authPath 一次性加载 ZCode 本地凭证。
    nonisolated static func loadCredentials(
        authPath: String?,
        homeDirectory: String = NSHomeDirectory(),
        userName: String = NSUserName(),
        environmentSecret: String? = ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"]
    ) -> GlmZcodeCredentials {
        let urls = resolveURLs(from: authPath)
        return loadCredentials(
            telemetryStateURL: urls.telemetryStateURL,
            credentialsURL: urls.credentialsURL,
            homeDirectory: homeDirectory,
            userName: userName,
            environmentSecret: environmentSecret
        )
    }

    /// 一次性加载 ZCode 本地凭证（设备标识、JWT Token 与 BigModel Access Token）。
    nonisolated static func loadCredentials(
        telemetryStateURL: URL = defaultTelemetryStateURL,
        credentialsURL: URL = defaultCredentialsURL,
        homeDirectory: String = NSHomeDirectory(),
        userName: String = NSUserName(),
        environmentSecret: String? = ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"]
    ) -> GlmZcodeCredentials {
        let deviceMid = loadDeviceMid(from: telemetryStateURL)
        let (jwtToken, bigmodelAccessToken) = loadTokens(
            from: credentialsURL,
            homeDirectory: homeDirectory,
            userName: userName,
            environmentSecret: environmentSecret
        )
        return GlmZcodeCredentials(
            deviceMid: deviceMid,
            jwtToken: jwtToken,
            bigmodelAccessToken: bigmodelAccessToken
        )
    }

    /// 从 `credentials.json` 一次性读取并解密 `zcodejwttoken` 与 `oauth:bigmodel:access_token`。
    nonisolated static func loadTokens(
        from fileURL: URL = defaultCredentialsURL,
        homeDirectory: String = NSHomeDirectory(),
        userName: String = NSUserName(),
        environmentSecret: String? = ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"]
    ) -> (jwtToken: String?, bigmodelAccessToken: String?) {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(CredentialsPayload.self, from: data) else {
            return (nil, nil)
        }

        let jwt = payload.zcodejwttoken.flatMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return decryptCredential(
                trimmed,
                credentialsURL: fileURL,
                homeDirectory: homeDirectory,
                userName: userName,
                environmentSecret: environmentSecret
            )
        }

        let bigmodel = payload.bigmodelAccessToken.flatMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return decryptCredential(
                trimmed,
                credentialsURL: fileURL,
                homeDirectory: homeDirectory,
                userName: userName,
                environmentSecret: environmentSecret
            )
        }

        return (jwt, bigmodel)
    }

    /// 从 `telemetry-state.json` 读取设备标识 `deviceMid`。
    nonisolated static func loadDeviceMid(from fileURL: URL = defaultTelemetryStateURL) -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(TelemetryStatePayload.self, from: data) else {
            return nil
        }
        let mid = payload.deviceMid?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (mid?.isEmpty == false) ? mid : nil
    }

    /// 从 `credentials.json` 读取并解密 `zcodejwttoken`。
    nonisolated static func loadJwtToken(
        from fileURL: URL = defaultCredentialsURL,
        homeDirectory: String = NSHomeDirectory(),
        userName: String = NSUserName(),
        environmentSecret: String? = ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"]
    ) -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(CredentialsPayload.self, from: data),
              let rawToken = payload.zcodejwttoken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawToken.isEmpty else {
            return nil
        }
        return decryptCredential(
            rawToken,
            credentialsURL: fileURL,
            homeDirectory: homeDirectory,
            userName: userName,
            environmentSecret: environmentSecret
        )
    }

    /// 解密可能包含 `enc:v1:` / `enc:v2:` 前缀的 ZCode 凭证。
    /// 若无前缀直接返回原值；解密失败（如文件损坏、密钥不匹配、结构畸形）返回 nil。
    ///
    /// - `credentialsURL`：凭证文件实际路径，v2 `os` 变体据此推导 Keychain account、
    ///   `env` 变体据此定位同目录 `credential-secret` 文件；
    /// - `keychainReader`：v2 `os` 变体的 Keychain 密钥读取（account → password），
    ///   默认走真实 SecItem 实现，供单测注入假实现。
    nonisolated static func decryptCredential(
        _ raw: String,
        credentialsURL: URL = defaultCredentialsURL,
        homeDirectory: String = NSHomeDirectory(),
        userName: String = NSUserName(),
        environmentSecret: String? = ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"],
        keychainReader: ((String) -> String?)? = nil
    ) -> String? {
        if raw.hasPrefix("enc:v2:") {
            return decryptEncV2(
                raw,
                credentialsPath: credentialsURL.path,
                managedSecret: resolveManagedSecret(
                    environmentSecret: environmentSecret,
                    credentialsURL: credentialsURL
                ),
                keychainReader: keychainReader ?? readZcodeCredentialKeychainPassword
            )
        }

        guard raw.hasPrefix("enc:v1:") else {
            return raw
        }

        let parts = raw.dropFirst("enc:v1:".count).split(separator: ".")
        guard parts.count == 3,
              let ivData = base64URLDecode(String(parts[0])),
              let tagData = base64URLDecode(String(parts[1])),
              let ciphertextData = base64URLDecode(String(parts[2])) else {
            return nil
        }

        let secret = resolveSecret(
            environmentSecret: environmentSecret,
            homeDirectory: homeDirectory,
            userName: userName
        )
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))

        guard let nonce = try? AES.GCM.Nonce(data: ivData),
              let sealedBox = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertextData, tag: tagData),
              let decryptedData = try? AES.GCM.open(sealedBox, using: key) else {
            return nil
        }

        return String(data: decryptedData, encoding: .utf8)
    }

    // MARK: - enc:v2（ZCode 客户端 3.18.0 起）

    /// ZCode 客户端（@napi-rs/keyring）的凭证加密密钥 Keychain 条目服务名。
    nonisolated static let zcodeCredentialKeychainService = "ZCode Credential Encryption"

    /// Keychain generic password 的 account：SHA256(credentials.json 绝对路径) 的
    /// 64 位小写 hex。路径须与客户端实际解析的绝对路径一致（含 authPath 自定义
    /// 场景，与 `resolveURLs` 返回值同源）。
    nonisolated static func keychainAccount(forCredentialsPath path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 读 ZCode 凭证加密密钥条目（返回 base64url 的 32 字节 AES key 字符串）。
    ///
    /// 与 `AntigravityKeychain` 同款测试进程护栏：xctest 产物不在条目 ACL 内，
    /// 真实 `SecItemCopyMatching` 会触发系统授权弹窗，测试进程内恒返回 nil；
    /// 单测通过 `decryptCredential` 的 `keychainReader` 注入假实现。
    nonisolated static func readZcodeCredentialKeychainPassword(account: String) -> String? {
        if AntigravityKeychain.isRunningInTestProcess { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: zcodeCredentialKeychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 解密 `enc:v2:` 凭证密文（纯函数，供单测注入密钥来源）。
    ///
    /// 载荷：`enc:v2:<variant>:[<keyId>:]<iv>.<tag>.<ciphertext>`，三段均为
    /// base64url（AES-256-GCM，iv 12B / tag 16B）；`<keyId>` 为客户端的密钥编号
    /// 提示，不参与解密，容忍任意内容。
    /// - `os` 变体：密钥在 macOS Keychain（见 `readZcodeCredentialKeychainPassword`），
    ///   条目 password 直接 base64url 解码即 32 字节 AES key，不再哈希；
    /// - `env` 变体：密钥 = SHA256(managed secret)。
    /// 任何失败（结构畸形 / 密钥不可得 / GCM 校验失败）logWarn（脱敏，不打密钥）
    /// 后返回 nil，不抛错中断整个凭证加载。
    nonisolated static func decryptEncV2(
        _ value: String,
        credentialsPath: String,
        managedSecret: String?,
        keychainReader: ((String) -> String?)?
    ) -> String? {
        let body: String
        let key: SymmetricKey?
        if value.hasPrefix("enc:v2:os:") {
            body = String(value.dropFirst("enc:v2:os:".count))
            guard let reader = keychainReader else {
                logWarn("[glm-zcode] enc:v2:os 密文缺少 Keychain 读取通道，跳过解密")
                return nil
            }
            let account = keychainAccount(forCredentialsPath: credentialsPath)
            guard let stored = reader(account) else {
                logWarn("[glm-zcode] Keychain 无 ZCode 凭证加密密钥（service=\(zcodeCredentialKeychainService)），无法解密 enc:v2:os")
                return nil
            }
            guard let keyData = base64URLDecode(stored), keyData.count == 32 else {
                logWarn("[glm-zcode] Keychain 密钥条目不是 base64url 的 32 字节 AES-256 密钥，无法解密 enc:v2:os")
                return nil
            }
            key = SymmetricKey(data: keyData)
        } else if value.hasPrefix("enc:v2:env:") {
            body = String(value.dropFirst("enc:v2:env:".count))
            guard let managedSecret, !managedSecret.isEmpty else {
                logWarn("[glm-zcode] 无 managed secret（ZCODE_CREDENTIAL_SECRET / credential-secret 文件），无法解密 enc:v2:env")
                return nil
            }
            key = SymmetricKey(data: SHA256.hash(data: Data(managedSecret.utf8)))
        } else {
            logWarn("[glm-zcode] 未知的 enc:v2 变体前缀，无法解密")
            return nil
        }

        // `<keyId>:<iv>.<tag>.<ciphertext>`：keyId 不参与解密。base64url 字符集
        // 不含 `:`，出现冒号即视为带 keyId 段（兼容空 keyId 与任意内容）。
        let payload = body.contains(":")
            ? String(body.split(separator: ":", maxSplits: 1).last ?? "")
            : body
        let parts = payload.split(separator: ".")
        guard parts.count == 3,
              let ivData = base64URLDecode(String(parts[0])),
              let tagData = base64URLDecode(String(parts[1])),
              let ciphertextData = base64URLDecode(String(parts[2])),
              let key,
              let nonce = try? AES.GCM.Nonce(data: ivData),
              let sealedBox = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertextData, tag: tagData),
              let decryptedData = try? AES.GCM.open(sealedBox, using: key) else {
            logWarn("[glm-zcode] enc:v2 密文结构畸形或 AES-GCM 校验失败（密钥不匹配），返回 nil")
            return nil
        }
        return String(data: decryptedData, encoding: .utf8)
    }

    /// v2 managed secret：`ZCODE_CREDENTIAL_SECRET` 环境变量优先，其次
    /// credentials.json 同目录的 `credential-secret` 文件（32–4096 字节，内容
    /// 原样使用不 trim，与客户端一致）。都没有返回 nil（`os` 变体走 Keychain，
    /// 与此独立）。
    private nonisolated static func resolveManagedSecret(
        environmentSecret: String?,
        credentialsURL: URL
    ) -> String? {
        if let env = environmentSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        let secretURL = credentialsURL.deletingLastPathComponent()
            .appendingPathComponent("credential-secret", isDirectory: false)
        guard let data = try? Data(contentsOf: secretURL),
              (32...4096).contains(data.count),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    /// 将明文凭证加密为带有 `enc:v1:` 前缀的标准密文（主要用于单元测试与凭证回写）。
    nonisolated static func encryptCredential(
        _ plaintext: String,
        homeDirectory: String = NSHomeDirectory(),
        userName: String = NSUserName(),
        environmentSecret: String? = ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"]
    ) -> String? {
        let secret = resolveSecret(
            environmentSecret: environmentSecret,
            homeDirectory: homeDirectory,
            userName: userName
        )
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        let nonce = AES.GCM.Nonce()

        guard let sealedBox = try? AES.GCM.seal(Data(plaintext.utf8), using: key, nonce: nonce) else {
            return nil
        }

        let ivPart = base64URLEncode(Data(nonce))
        let tagPart = base64URLEncode(sealedBox.tag)
        let cipherPart = base64URLEncode(sealedBox.ciphertext)
        return "enc:v1:\(ivPart).\(tagPart).\(cipherPart)"
    }

    // MARK: - 内部辅助

    private nonisolated static func resolveSecret(
        environmentSecret: String?,
        homeDirectory: String,
        userName: String
    ) -> String {
        if let env = environmentSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        return "zcode-credential-fallback:darwin:\(homeDirectory):\(userName)"
    }

    private nonisolated static func base64URLDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 {
            str.append("=")
        }
        return Data(base64Encoded: str)
    }

    private nonisolated static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
