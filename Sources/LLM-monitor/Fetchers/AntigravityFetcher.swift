import Foundation

/// Antigravity 额度抓取器
///
/// **阶段一（2026-11-08）：额度/账号路径走 Keychain 凭据 + 远端 Google API**——
/// Antigravity 未运行时额度照常工作（token 未过期时）：
///
/// 1. 从登录钥匙串读 `gemini` / `antigravity` 条目（Antigravity 客户端写入并
///    自行续期，见 `AntigravityCredential`），本地判定 `token.expiry`：
///    `now >= expiry` 直接抛 `QuotaError.credentialExpired`，不发任何网络请求
/// 2. POST `https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`
///    （body `{}`；Bearer access_token + hub 身份 UA；主机回退序 Daily →
///    生产 cloudcode-pa → sandbox，仅 401 终止，其余非 2xx 换下一主机）
/// 3. `.full` 追加 `v1internal:loadCodeAssist` 取 tier（`currentTier.name` →
///    `paidTier.name` → `paidTier.id`）；邮箱直接用 Keychain 的 `id_token_email`。
///    本地 RPC 的 `GetUserStatus` / `GetLoadCodeAssist` 在额度路径退役
///    （`planStatus.planInfo` 细节展示名远端无对应，planLabel 回退链相应缩短）
///
/// **阶段二b（2026-11-08）**：本地用量路径退役本地 RPC
/// `GetCascadeTrajectoryGeneratorMetadata` 与进程发现——scanner 直读会话
/// `.db`（`AntigravitySessionDBReader`），本类型只剩远端配额/账号路径，不再
/// 携带任何 localhost / pgrep / lsof / CSRF 代码。
struct AntigravityFetcher: QuotaFetcher {
    /// 远端配额 POST 注入点（仅测试用）：host / path / headers / body → (data, status)。
    /// 抛错视为传输层失败（触发主机回退）；非 2xx 状态码由调用方决定回退或终止。
    typealias RemotePostOverride = @Sendable (
        _ host: String,
        _ path: String,
        _ headers: [String: String],
        _ body: Data
    ) async throws -> (Data, Int)

    let providerID = "antigravity"
    let displayName = "Antigravity"
    let kind: ProviderKind = .antigravity
    var resultMerger: RefreshResultMerger { AntigravityFillingMissingMerger() }

    /// 带 delegate 的 URLSession 会被系统强持有到 invalidate / 进程退出；本
    /// fetcher 是按需构造的轻量 struct（每轮刷新、reconcile、auth 探测都会新建
    /// 一个），session 必须进程级共享，否则每次构造都泄漏一套 session + delegate。
    /// LocalhostTrustDelegate 只做无状态的 localhost 信任评估，跨实例复用安全；
    /// 远端 Google API 不命中 localhost 分支，走系统默认 TLS 校验。
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = HTTPTimeouts.antigravityRequest
        config.timeoutIntervalForResource = HTTPTimeouts.antigravityResource
        return URLSession(
            configuration: config,
            delegate: LocalhostTrustDelegate(),
            delegateQueue: nil
        )
    }()

    /// 远端配额接口的 HTTPClient（glm/minimax 同款 Services/Infra 基础设施）。
    private static let remoteHTTPClient = HTTPClient(
        session: session,
        logTag: "antigravity",
        defaultTimeout: HTTPTimeouts.antigravityRequest,
        maxResponseBytes: ResponseByteLimits.standardQuota
    )

    private let credentialReader: @Sendable () -> AntigravityCredential?
    private let hubVersionProvider: @Sendable () -> String?
    /// 默认走 HTTPClient 生产传输；测试注入 override 后按 host 逐一记录调用。
    private let remotePost: RemotePostOverride

    init(
        credentialReader: @escaping @Sendable () -> AntigravityCredential? = {
            AntigravityKeychain.readCredential()
        },
        hubVersionProvider: @escaping @Sendable () -> String? = {
            AntigravityFetcher.readAntigravityAppVersion()
        },
        remotePostOverride: RemotePostOverride? = nil
    ) {
        self.credentialReader = credentialReader
        self.hubVersionProvider = hubVersionProvider
        self.remotePost = remotePostOverride ?? { host, path, headers, body in
            try await AntigravityFetcher.performRemotePost(
                host: host,
                path: path,
                headers: headers,
                body: body
            )
        }
    }

    func hasLocalAuth() -> Bool {
        // 真正的探测在 async checkLocalAuth()（读一次钥匙串）；这个方法会在菜单
        // 和配置变更的主线程路径中频繁调用，这里返回 true 表示"潜在可用"，
        // 把凭据探测推迟到 async 路径，避免打开菜单或设置窗口时发生可感知卡顿。
        true
    }

    /// 凭据可读（条目存在且结构可解析）即视为可用。token 过期不在此判定：
    /// 过期时 fetch() 抛 `credentialExpired`，卡片显示「打开 Antigravity 更新凭据」。
    func checkLocalAuth() async -> Bool {
        credentialReader() != nil
    }

    func fetch(mode: RefreshMode) async throws -> QuotaInfo {
        guard let credential = credentialReader() else {
            throw QuotaError.networkError(
                "未读取到 Antigravity 登录凭据，请打开 Antigravity 并完成登录"
            )
        }
        // 过期判定在本地完成：过期时不发任何网络请求，直接进入 credentialExpired。
        if credential.isExpired() {
            throw QuotaError.credentialExpired
        }

        async let quotaSummary: RetrieveUserQuotaSummaryResponse = remoteCallDecodable(
            path: Self.remoteQuotaSummaryPath,
            accessToken: credential.accessToken
        )
        let tier: String?
        if mode == .full {
            // loadCodeAssist 是可选元数据：失败只丢 tier（merger 在 background
            // 保留旧值；full 采用 nil），不影响主额度。对齐旧 postOptional 语义。
            let load: LoadCodeAssistRemoteResponse? = try? await remoteCallDecodable(
                path: Self.remoteLoadCodeAssistPath,
                accessToken: credential.accessToken
            )
            tier = load?.tierName
        } else {
            tier = nil
        }

        let quota = try await quotaSummary
        let models = try Self.makeModels(from: quota)
        return QuotaInfo(
            models: models,
            resetCredits: nil,
            planLabel: tier,
            accountEmail: credential.email,
            codexUsageDetails: nil,
            fetchedAt: Date()
        )
    }

    // MARK: - Remote Google API（额度/账号路径）

    /// 远端配额端点（2026-11-08 用 Keychain access_token 实测 HTTP 200）。
    /// 响应与本地 RPC 同形但**没有** `response` 包装（`RetrieveUserQuotaSummaryResponse`）。
    static let remoteQuotaSummaryPath = "/v1internal:retrieveUserQuotaSummary"
    /// tier 来源（`.full` 模式）。tier 取 `currentTier.name`，回退
    /// `paidTier.name` / `paidTier.id`（见 `LoadCodeAssistRemoteResponse.tierName`）。
    static let remoteLoadCodeAssistPath = "/v1internal:loadCodeAssist"

    /// 主机回退序：Daily → 生产 cloudcode-pa → sandbox。仅 401 终止（抛
    /// `credentialExpired`），其余非 2xx 与传输失败换下一主机。
    static let remoteHosts: [String] = [
        "daily-cloudcode-pa.googleapis.com",
        "cloudcode-pa.googleapis.com",
        "daily-cloudcode-pa.sandbox.googleapis.com",
    ]

    /// AntigravityManager 记录的 hub client 版本下限；读不到 app 版本时的 UA 回退值。
    static let fallbackHubVersion = "2.26.0"

    /// hub 身份 UA（实测要求）：裸 `antigravity/cli/…` 身份拿不到 Gemini 4 Argon
    /// 等分组。版本取 `/Applications/Antigravity.app` 的 CFBundleShortVersionString；
    /// os_type / arch 按实测固定（分发只提供 arm64 包）。
    static func hubUserAgent(version: String?) -> String {
        let resolved = StringUtilities.trimmedOrNil(version) ?? fallbackHubVersion
        return "antigravity/hub/\(resolved) (aidev_client; os_type=darwin; arch=arm64)"
    }

    static func remoteHeaders(accessToken: String, version: String?) -> [String: String] {
        [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(accessToken)",
            "User-Agent": hubUserAgent(version: version),
        ]
    }

    /// 从本机 Antigravity.app 的 Info.plist 读 CFBundleShortVersionString；
    /// 读不到返回 nil（调用方回退 `fallbackHubVersion`）。
    static func readAntigravityAppVersion(bundlePath: String = "/Applications/Antigravity.app") -> String? {
        let plistURL = URL(fileURLWithPath: bundlePath)
            .appendingPathComponent("Contents")
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = plist as? [String: Any] else {
            return nil
        }
        return StringUtilities.trimmedOrNil(info["CFBundleShortVersionString"] as? String)
    }

    private func remoteCallDecodable<Response: Decodable>(
        path: String,
        accessToken: String
    ) async throws -> Response {
        let data = try await remoteCall(path: path, accessToken: accessToken)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw QuotaError.decodingError(
                "Antigravity 响应无法解析，响应 \(data.count) bytes"
            )
        }
    }

    /// 远端配额调用（主机回退）。401 → `credentialExpired`（远端 401 与本地
    /// 过期判定落到同一提示）；其余非 2xx 与传输失败换下一主机，全部失败抛
    /// 最后一台的错误。
    private func remoteCall(path: String, accessToken: String) async throws -> Data {
        let headers = Self.remoteHeaders(
            accessToken: accessToken,
            version: hubVersionProvider()
        )
        // 两个端点的 body 都是 `{}`。
        let body = Data("{}".utf8)
        var lastError: Error?
        for host in Self.remoteHosts {
            do {
                let (data, status) = try await remotePost(host, path, headers, body)
                if (200..<300).contains(status) {
                    return data
                }
                if status == 401 {
                    // 仅 401 终止回退：同一凭据在所有主机上都无效。
                    throw QuotaError.credentialExpired
                }
                lastError = QuotaError.httpError(status: status, body: "响应 \(data.count) bytes")
            } catch let error as URLError where error.code == .cancelled {
                // 保留取消错误类型，让 AppState/CancellationFilter 走 deferred 路径。
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as QuotaError {
                switch error {
                case .credentialExpired:
                    throw error
                case .networkError, .httpError:
                    // HTTPClient 把传输失败包装成 networkError、非 2xx 抛 httpError
                    // —— 都属可回退错误，换下一主机。
                    logWarn("[antigravity] 远端 \(host)\(path) 失败：\(error.localizedDescription)，回退下一主机")
                    lastError = error
                default:
                    throw error
                }
            } catch {
                // 其余传输层异常（未被 HTTPClient 包装的 URLError 等）同按可回退处理。
                logWarn("[antigravity] 远端 \(host)\(path) 失败：\(HTTPRequestLogSanitizer.networkErrorDescription(error))，回退下一主机")
                lastError = error
            }
        }
        throw lastError ?? QuotaError.invalidResponse
    }

    /// 生产传输：POST `https://<host><path>`。HTTPClient 对非 2xx 抛 httpError，
    /// 这里把状态码还原为返回值供主机回退判定（401 终止 / 其他回退）。
    private static func performRemotePost(
        host: String,
        path: String,
        headers: [String: String],
        body: Data
    ) async throws -> (Data, Int) {
        guard let url = URL(string: "https://\(host)\(path)") else {
            throw QuotaError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, http) = try await remoteHTTPClient.send(request)
            return (data, http.statusCode)
        } catch let error as QuotaError {
            if case let .httpError(status, _) = error {
                return (Data(), status)
            }
            throw error
        }
    }

    // MARK: - Mapping

    /// 账号信息组装（阶段一起）：邮箱 = Keychain `id_token_email`（随凭据每次
    /// 带回）；planLabel = 远端 `loadCodeAssist` 的 `currentTier.name` →
    /// `paidTier.name` → `paidTier.id`（解析见 `LoadCodeAssistRemoteResponse.tierName`）。
    /// 本地 RPC `GetUserStatus` / `GetLoadCodeAssist` 已在额度路径退役；其
    /// `planStatus.planInfo` 细节展示名（planDisplayName / productName 等）在
    /// 远端无对应字段，planLabel 回退链相应缩短为上述三级。
    private nonisolated static func makeModels(from response: RetrieveUserQuotaSummaryResponse) throws -> [ModelQuota] {
        // 单个 group 的 bucket 数据异常（缺/非法 remainingFraction）只跳过该
        // group 并记日志，不作废整次额度刷新 —— 对齐 postOptional 的部分可用
        // 语义；全部 group 都不可用时仍然抛错。
        var models: [ModelQuota] = []
        for group in response.groups {
            let weekly = bucket(for: "weekly", in: group.buckets)
            let fiveHour = bucket(for: "5h", in: group.buckets)

            guard weekly != nil || fiveHour != nil else { continue }

            do {
                let fiveHourPercent = try percent(
                    from: fiveHour,
                    window: "5h",
                    groupName: group.displayName
                )
                let weeklyPercent = try percent(
                    from: weekly,
                    window: "weekly",
                    groupName: group.displayName
                )

                models.append(ModelQuota(
                    modelName: normalizedModelName(from: group),
                    intervalTotalCount: 0,
                    intervalUsageCount: 0,
                    intervalRemainingPercent: fiveHourPercent,
                    intervalStatus: fiveHour == nil ? .absent : .present,
                    intervalResetsAt: fiveHour?.resetTime,
                    intervalWindowSeconds: fiveHour == nil ? nil : 5 * 3600,
                    weeklyTotalCount: 0,
                    weeklyUsageCount: 0,
                    weeklyRemainingPercent: weeklyPercent,
                    weeklyStatus: weekly == nil ? .absent : .present,
                    weeklyResetsAt: weekly?.resetTime,
                    weeklyWindowSeconds: weekly == nil ? nil : 7 * 24 * 3600
                ))
            } catch {
                logWarn("[antigravity] 跳过 \(group.displayName) group: \(error.localizedDescription)")
                continue
            }
        }

        guard !models.isEmpty else {
            throw QuotaError.decodingError("Antigravity quota 响应里没有可用 bucket")
        }
        return models.sorted { lhs, rhs in
            sortRank(for: lhs.modelName) < sortRank(for: rhs.modelName)
        }
    }

    private nonisolated static func normalizedModelName(from group: QuotaGroup) -> String {
        let title = group.displayName.lowercased()
        let description = (group.description ?? "").lowercased()
        let hasArgonBucket = group.buckets.contains {
            ($0.bucketId?.lowercased() ?? "").contains("argon")
        }

        if title.contains("argon") || description.contains("argon") || hasArgonBucket {
            return AntigravityModelKind.geminiArgon.rawValue
        }
        if title.contains("gemini") || description.contains("gemini") {
            return AntigravityModelKind.geminiModels.rawValue
        }
        if title.contains("claude") || title.contains("gpt") || description.contains("claude") {
            return AntigravityModelKind.claudeAndGptModels.rawValue
        }
        return group.displayName
    }

    private nonisolated static func sortRank(for modelName: String) -> Int {
        switch modelName.lowercased() {
        case AntigravityModelKind.geminiModels.rawValue: return 0
        case AntigravityModelKind.geminiArgon.rawValue: return 1
        case AntigravityModelKind.claudeAndGptModels.rawValue: return 2
        default: return 9
        }
    }

    private nonisolated static func bucket(for window: String, in buckets: [QuotaBucket]) -> QuotaBucket? {
        buckets.first { bucket in
            if bucket.window?.lowercased() == window.lowercased() {
                return true
            }
            if let bucketId = bucket.bucketId?.lowercased(), bucketId.contains(window.lowercased()) {
                return true
            }
            return false
        }
    }

    private nonisolated static func percent(
        from bucket: QuotaBucket?,
        window: String,
        groupName: String
    ) throws -> Double {
        guard let bucket else { return 0 }
        guard let fraction = bucket.remainingFraction,
              fraction.isFinite,
              (0 ... 1).contains(fraction) else {
            throw QuotaError.decodingError(
                "Antigravity quota 响应中的 \(groupName) \(window) bucket remainingFraction 无效"
            )
        }
        return fraction * 100
    }
}

// MARK: - Test surface

extension AntigravityFetcher {
    /// 暴露本实例实际使用的 URLSession（仅测试用：验证多个 fetcher 实例共享
    /// 同一个进程级 session，防止退回"每次构造新建 delegate session"的泄漏）。
    var sessionForTest: URLSession { Self.session }

    /// 从 quota response JSON 构造模型（仅用于验证 bucket presence/status 契约）。
    nonisolated static func parseQuotaModelsForTest(_ data: Data) throws -> [ModelQuota] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try makeModels(from: decoder.decode(RetrieveUserQuotaSummaryResponse.self, from: data))
    }
}
