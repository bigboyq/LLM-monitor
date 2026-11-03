import Foundation
import CryptoKit

/// ZCode 本地凭证快照（deviceMid、解密后的 JWT Token 与 BigModel Access Token）。
struct GlmZcodeCredentials: Equatable, Sendable {
    let deviceMid: String?
    let jwtToken: String?
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
///    - 若带有 `enc:v1:` 前缀，表示使用 AES-256-GCM 加密；
///    - 加密格式：`enc:v1:<base64url(iv)>.<base64url(tag)>.<base64url(ciphertext)>`；
///    - 密钥派生源：`ZCODE_CREDENTIAL_SECRET` 环境变量，或默认回退
///      `zcode-credential-fallback:darwin:<homeDirectory>:<userName>` 的 SHA256 摘要；
///    - 若无 `enc:v1:` 前缀，直接当作原始 Token 返回。
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
            homeDirectory: homeDirectory,
            userName: userName,
            environmentSecret: environmentSecret
        )
    }

    /// 解密可能包含 `enc:v1:` 前缀的 ZCode 凭证。
    /// 若无前缀直接返回原值；解密失败（如文件损坏、密钥不匹配、结构畸形）返回 nil。
    nonisolated static func decryptCredential(
        _ raw: String,
        homeDirectory: String = NSHomeDirectory(),
        userName: String = NSUserName(),
        environmentSecret: String? = ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"]
    ) -> String? {
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
