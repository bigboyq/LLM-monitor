import Foundation

/// Antigravity 额度抓取器
///
/// **2.5.0（凭据策略重构：ls 优先 + agy 代理刷新 + 开关预检）**：每次额度刷新按
/// 以下决策树取额度（`AntigravityCredentialPolicy` 持有跨刷新的预检 / 缓存 /
/// 退避状态）：
///
/// 1. **ls 可用？**（`AntigravityProcessDiscovery`，pgrep + lsof 毫秒级）→
///    本地 RPC（来源 `.localLanguageServer`）。运行中的 language_server 持有
///    host bridge 新凭据，本地 RPC 一直是权威额度来源——此步**不读钥匙串**
///    （邮箱兜底只用内存缓存）。
/// 2. 开关 `accessTokenFallback`（config 缺省 true；预检发现钥匙串授权被拒时
///    运行时自动 disable）关闭 → 统一提示完成（含「或在终端运行 agy models
///    手动刷新」）。
/// 3. keychain access_token 未过期 → 远端 Cloud Code（来源 `.remoteCloudCode`）。
///    读凭据先走进程内存缓存（`AntigravityCredentialPolicy`），内存过期/缺失才
///    重读 keychain；远端 401 视同凭据不可用，走下一分支。
/// 4. 开关 `allowTokenRefresh`（autoRefresh，2.5.0 语义翻正、缺省 true；预检
///    发现找不到 agy CLI 时运行时自动 disable）关闭，或上轮 agy 刷新失败仍在
///    退避期内 → 同 2 的提示完成。
/// 5. 运行 `agy models`（`AntigravityAgyCLI`：30s 超时、AsyncMutex 互斥、输出
///    不落日志）触发官方认证流写回 keychain → 强制重读 keychain：新 token 未
///    过期 → 远端（来源 `.remoteCloudCode`）；agy 失败 / 重读仍过期 → 退避一个
///    刷新周期并提示（`invalid_grant` 类 → 「请重新登录 Antigravity」）。
///
/// refresh_token 不落盘不进日志（不建模、输出不落日志），监控侧不回写 keychain。
///
/// **阶段一（2026-11-08）**：额度/账号主路径走 Keychain 凭据 + 远端 Google API：
/// 从登录钥匙串读 `gemini` / `antigravity` 条目（见 `AntigravityCredential`），
/// POST `https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`
/// （body `{}`；Bearer access_token + hub 身份 UA；主机回退序 Daily →
/// 生产 cloudcode-pa → sandbox，仅 401 终止，其余非 2xx 换下一主机）；`.full`
/// 追加 `v1internal:loadCodeAssist` 取 tier；邮箱直接用 Keychain 的
/// `id_token_email`。
///
/// **阶段二b（2026-11-08）**：本地用量路径退役本地 RPC
/// `GetCascadeTrajectoryGeneratorMetadata`——scanner 直读会话
/// `.db`（`AntigravitySessionDBReader`），与额度路径无关。
///
/// **2.4.2（历史）**：keychain 陈旧窗口引入本地 RPC 回退（keychain 新鲜 → 远端；
/// 缺失/过期/401 → 本地 RPC）。2.5.0 决策树反转：ls 检查提到最前，本地 RPC 从
/// 「回退」变为「权威主路径」，远端改为 keychain 兜底路径。
///
/// **2.4.3（来源标记）**：两条成功路径各自给返回的 `QuotaInfo` 打来源标记
/// `antigravityQuotaSource`（远端 → `.remoteCloudCode`，本地 →
/// `.localLanguageServer`），供设置窗口 Antigravity pane 的「额度来源」行展示
/// 当前走的是哪条路；merger 在 background 保留上次来源（与账号/套餐同语义）。
struct AntigravityFetcher: QuotaFetcher {
    /// 远端配额 POST 注入点（仅测试用）：host / path / headers / body → (data, status)。
    /// 抛错视为传输层失败（触发主机回退）；非 2xx 状态码由调用方决定回退或终止。
    typealias RemotePostOverride = @Sendable (
        _ host: String,
        _ path: String,
        _ headers: [String: String],
        _ body: Data
    ) async throws -> (Data, Int)

    /// 本地 RPC POST 注入点（仅测试用）：server / path / headers / body → (data, status)。
    /// headers 已含 Content-Type 与（如有）`x-codeium-csrf-token`，便于测试断言
    /// CSRF 两种形态；抛错视为传输层失败。
    typealias LocalPostOverride = @Sendable (
        _ server: ServerInfo,
        _ path: String,
        _ headers: [String: String],
        _ body: Data
    ) async throws -> (Data, Int)

    /// 本地服务 TOCTOU 复查注入点（仅测试用）：默认 `serverStillOwnsEndpoint`
    /// （lsof 复查 pid 仍监听同一 loopback 端口）。
    typealias LocalOwnershipChecker = @Sendable (_ server: ServerInfo) -> Bool

    let providerID = "antigravity"
    let displayName = "Antigravity"
    let kind: ProviderKind = .antigravity
    var resultMerger: RefreshResultMerger { AntigravityFillingMissingMerger() }

    /// 带 delegate 的 URLSession 会被系统强持有到 invalidate / 进程退出；本
    /// fetcher 是按需构造的轻量 struct（每轮刷新、reconcile、auth 探测都会新建
    /// 一个），session 必须进程级共享，否则每次构造都泄漏一套 session + delegate。
    /// LocalhostTrustDelegate 只做无状态的 localhost 信任评估，跨实例复用安全；
    /// 远端 Google API 不命中 localhost 分支，走系统默认 TLS 校验，本地回退 RPC
    /// 命中 127.0.0.1 分支信任自签证书。
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
    /// 本地路径的进程发现（默认 pgrep + lsof；测试注入固定 ServerInfo 或抛错）。
    /// 2.5.0 决策树第 1 步每拍都会先跑发现，默认 seam 带测试进程护栏：xctest
    /// 进程内恒走「无本地后端」，漏注入 stub 的测试不触达真实 pgrep / lsof。
    private let localServerDiscovery: @Sendable () async throws -> ServerInfo
    /// 本地 RPC 传输（默认 CappedDownloader + 共享 session；测试注入记录调用）。
    private let localPost: LocalPostOverride
    /// 本地服务 TOCTOU 复查（默认 lsof；测试可注入 true / false）。
    private let ownershipChecker: LocalOwnershipChecker
    /// 跨刷新的凭据策略状态（预检 / 内存 token 缓存 / agy 退避）。默认进程级
    /// 共享实例；测试注入独立实例隔离状态。
    private let policy: AntigravityCredentialPolicy
    /// 开关 `providers.antigravity.accessTokenFallback`（缺省 true）。
    private let accessTokenFallbackEnabled: Bool
    /// 开关 `providers.antigravity.allowTokenRefresh`（autoRefresh，2.5.0 缺省 true）。
    private let autoRefreshEnabled: Bool
    /// agy 刷新失败的退避时长 = 一个刷新周期（provider 未显式配置时为专属默认 300s）。
    private let backoffIntervalSeconds: TimeInterval

    init(
        credentialReader: @escaping @Sendable () -> AntigravityCredential? = {
            AntigravityKeychain.readCredential()
        },
        hubVersionProvider: @escaping @Sendable () -> String? = {
            AntigravityFetcher.readAntigravityAppVersion()
        },
        remotePostOverride: RemotePostOverride? = nil,
        localServerDiscovery: @escaping @Sendable () async throws -> ServerInfo = {
            if AntigravityKeychain.isRunningInTestProcess {
                throw QuotaError.networkError("test-guardrail: 进程发现在测试进程内不可用（请注入 stub）")
            }
            return try await AntigravityFetcher.discoverServerAsync()
        },
        localPostOverride: LocalPostOverride? = nil,
        localOwnershipChecker: @escaping LocalOwnershipChecker = {
            AntigravityFetcher.serverStillOwnsEndpoint($0)
        },
        policy: AntigravityCredentialPolicy? = nil,
        accessTokenFallbackEnabled: Bool = true,
        autoRefreshEnabled: Bool = true,
        refreshIntervalSeconds: Int? = nil
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
        self.localServerDiscovery = localServerDiscovery
        self.localPost = localPostOverride ?? { server, path, headers, body in
            try await AntigravityFetcher.performLocalPost(
                server: server,
                path: path,
                headers: headers,
                body: body
            )
        }
        self.ownershipChecker = localOwnershipChecker
        // 默认进程级共享实例：fetcher 每轮刷新都重建，预检 / 内存缓存 / 退避必须
        // 跨构造存活。注意 credentialReader 注入只服务 checkLocalAuth（auth 探测）
        // ——fetch 路径的凭据一律经 policy（测试要隔离状态时注入独立 policy）。
        self.policy = policy ?? .shared
        self.accessTokenFallbackEnabled = accessTokenFallbackEnabled
        self.autoRefreshEnabled = autoRefreshEnabled
        self.backoffIntervalSeconds = TimeInterval(
            refreshIntervalSeconds ?? AppConfig.antigravityDefaultRefreshIntervalSeconds
        )
    }

    func hasLocalAuth() -> Bool {
        // 真正的探测在 async checkLocalAuth()（读一次钥匙串）；这个方法会在菜单
        // 和配置变更的主线程路径中频繁调用，这里返回 true 表示"潜在可用"，
        // 把凭据探测推迟到 async 路径，避免打开菜单或设置窗口时发生可感知卡顿。
        true
    }

    /// 凭据可读（条目存在且结构可解析）即视为可用。token 过期不在此判定：
    /// 过期/缺失时 fetch() 按决策树走 keychain 兜底 / agy 刷新分支。auth 探测
    /// 仍只看钥匙串可读性（不跑 pgrep、不跑 agy）。
    func checkLocalAuth() async -> Bool {
        credentialReader() != nil
    }

    // MARK: - 额度抓取决策树（2.5.0：ls 优先 → keychain 兜底 → agy 代理刷新）

    func fetch(mode: RefreshMode) async throws -> QuotaInfo {
        // 1. ls 可用？→ 本地 RPC（来源=localLanguageServer）。运行中的
        //    language_server 持有 host bridge 新凭据，本地 RPC 一直是权威额度
        //    来源；发现本身 pgrep + lsof 毫秒级。此步不读钥匙串（邮箱兜底只用
        //    内存缓存，省一次钥匙串访问）。
        do {
            let server = try await localServerDiscovery()
            let cached = policy.memoryCachedFreshCredential()
            let info = try await fetchLocal(server: server, credential: cached, mode: mode)
            logInfo("[antigravity] 额度来源：本地 language_server")
            return info
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            // ls 不可用（未发现进程/端口）或本地 RPC 失败 → 继续后续分支，
            // 不把本地失败伪装成凭据错误。
            logInfo("[antigravity] 本地 language_server 不可用（\(HTTPRequestLogSanitizer.networkErrorDescription(error))），转入钥匙串/远端分支")
        }

        // 2. accessTokenFallback 关（config 关闭，或预检发现钥匙串授权被拒后
        //    运行时自动 disable）→ 统一提示完成。
        guard policy.isAccessTokenFallbackActive(configEnabled: accessTokenFallbackEnabled) else {
            logWarn("[antigravity] 钥匙串额度兜底未启用，落统一提示")
            throw QuotaError.credentialExpired
        }

        // 3. keychain access_token 未过期 → 远端（来源=remoteCloudCode）。凭据
        //    先走进程内存缓存，内存过期/缺失才重读 keychain（省钥匙串访问）。
        if let credential = policy.currentCredentialForRemote() {
            if !credential.isExpired() {
                do {
                    let info = try await fetchRemote(credential: credential, mode: mode)
                    logInfo("[antigravity] 额度来源：远端 Cloud Code（keychain token）")
                    return info
                } catch let error as QuotaError where error == QuotaError.credentialExpired {
                    // 远端 401：token 本地未过期但已被服务端拒绝（轮询间隙被 IDE
                    // 换掉 / 会话失效）→ 视同凭据不可用，走刷新/提示分支。
                    logWarn("[antigravity] 远端配额 401，keychain token 视同不可用")
                }
            } else {
                logWarn("[antigravity] keychain token 已过期（expiry=\(credential.expiry)）")
            }
        } else {
            logWarn("[antigravity] 未读取到 keychain 凭据")
        }

        // 4. autoRefresh 关（config 关闭，或预检发现找不到 agy CLI 后运行时自动
        //    disable），或上轮 agy 刷新失败仍在退避期内 → 同 2 的提示完成。
        guard policy.isAutoRefreshActive(configEnabled: autoRefreshEnabled) else {
            logWarn("[antigravity] agy 代理刷新未启用，落统一提示")
            throw QuotaError.credentialExpired
        }
        guard !policy.isBackedOff() else {
            logInfo("[antigravity] agy 刷新退避中，本拍跳过")
            throw QuotaError.credentialExpired
        }

        // 5. 运行 agy models（30s 超时、互斥、stdout/stderr 不落日志）→ 成功后
        //    强制重读 keychain。
        let outcome: AntigravityAgyRunOutcome
        do {
            outcome = try await policy.runAgyRefresh()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            logWarn("[antigravity] agy models 运行异常：\(HTTPRequestLogSanitizer.networkErrorDescription(error))")
            outcome = .failure(reloginRequired: false)
        }

        switch outcome {
        case .success:
            guard let refreshed = policy.credentialAfterAgyRefresh(), !refreshed.isExpired() else {
                // agy 成功但重读仍过期/缺失（写入延迟或钥匙串授权被拒）→
                // 退避一个刷新周期，本拍落统一提示。
                logWarn("[antigravity] agy 刷新后 keychain 仍无可用 token，退避一个刷新周期")
                policy.startBackoff(intervalSeconds: backoffIntervalSeconds)
                throw QuotaError.credentialExpired
            }
            logInfo("[antigravity] agy 刷新成功，新 token expiry=\(refreshed.expiry)")
            do {
                let info = try await fetchRemote(credential: refreshed, mode: mode)
                logInfo("[antigravity] 额度来源：远端 Cloud Code（agy 刷新后）")
                return info
            } catch let error as QuotaError where error == QuotaError.credentialExpired {
                // 全新 token 仍 401：会话被服务端吊销类故障，退避避免每拍空转。
                logWarn("[antigravity] agy 刷新后的 token 仍被远端 401，退避一个刷新周期")
                policy.startBackoff(intervalSeconds: backoffIntervalSeconds)
                throw QuotaError.credentialExpired
            }
        case .failure(let reloginRequired):
            logWarn("[antigravity] agy models 刷新失败（reloginRequired=\(reloginRequired)），退避一个刷新周期")
            policy.startBackoff(intervalSeconds: backoffIntervalSeconds)
            throw reloginRequired ? QuotaError.credentialReloginRequired : QuotaError.credentialExpired
        }
    }

    /// 远端路径（阶段一原样提取）：quota + `.full` 时的 tier。
    private func fetchRemote(credential: AntigravityCredential, mode: RefreshMode) async throws -> QuotaInfo {
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
            fetchedAt: Date(),
            antigravityQuotaSource: .remoteCloudCode
        )
    }

    /// 本地 RPC 抓取（2.5.0 决策树第 1 步：已发现 server）。quota 致命；
    /// GetUserStatus / GetLoadCodeAssist 可选失败不致命（对齐旧 postOptional 语义）。
    /// `credential` 只作邮箱兜底（传入内存缓存凭据，绝不为此触发钥匙串访问）。
    private func fetchLocal(
        server: ServerInfo,
        credential: AntigravityCredential?,
        mode: RefreshMode
    ) async throws -> QuotaInfo {
        async let quotaSummary: RetrieveUserQuotaSummaryEnvelope = localPostDecodable(
            server: server,
            path: Self.localQuotaSummaryPath
        )

        let user: UserStatusEnvelope?
        let load: LoadCodeAssistLocalEnvelope?
        if mode == .full {
            // 账号/tier 是可选元数据（「次要信息频率」，仅 .full）；失败只丢
            // 邮箱/tier，不影响主额度。GetUserStatus 带 metadata 请求体（原契约）。
            let userStatusBody = try JSONEncoder().encode(UserStatusRequest(metadata: .init(
                ideName: "antigravity",
                extensionName: "antigravity",
                ideVersion: "unknown",
                locale: "en"
            )))
            async let userStatus: UserStatusEnvelope? = localPostOptional(
                server: server,
                path: Self.localUserStatusPath,
                body: userStatusBody
            )
            async let loadCodeAssist: LoadCodeAssistLocalEnvelope? = localPostOptional(
                server: server,
                path: Self.localLoadCodeAssistPath
            )
            user = await userStatus
            load = await loadCodeAssist
        } else {
            user = nil
            load = nil
        }

        let quota = try await quotaSummary
        let models = try Self.makeModels(from: quota.response)
        let account = Self.parseAccount(
            userStatus: user?.userStatus,
            fallbackTier: load?.response.currentTier?.name
        )
        return QuotaInfo(
            models: models,
            resetCredits: nil,
            planLabel: account.planLabel,
            accountEmail: account.accountEmail ?? credential?.email,
            codexUsageDetails: nil,
            fetchedAt: Date(),
            antigravityQuotaSource: .localLanguageServer
        )
    }

    // MARK: - Remote Google API（额度/账号路径）

    /// 远端配额端点（2026-11-08 用 Keychain access_token 实测 HTTP 200）。
    /// 响应与本地 RPC 同形但**没有** `response` 包装（`RetrieveUserQuotaSummaryResponse`）。
    static let remoteQuotaSummaryPath = "/v1internal:retrieveUserQuotaSummary"
    /// tier 来源（`.full` 模式）。tier 取 `currentTier.name`，回退
    /// `paidTier.name` / `paidTier.id`（见 `LoadCodeAssistRemoteResponse.tierName`）。
    static let remoteLoadCodeAssistPath = "/v1internal:loadCodeAssist"

    // MARK: - 本地回退 RPC 端点（2.4.2 复活，原 Phase-0 契约）

    /// 本地 quota RPC（`response` 包装形状）。仅凭据缺失/过期或远端 401 时调用。
    static let localQuotaSummaryPath =
        "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    /// 本地账号 RPC（email + tier 回退链前六级）。仅 `.full`、可选失败。
    static let localUserStatusPath =
        "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    /// 本地 tier 末位回退 RPC（`currentTier.name`）。仅 `.full`、可选失败。
    static let localLoadCodeAssistPath =
        "/exa.language_server_pb.LanguageServerService/GetLoadCodeAssist"

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

    // MARK: - 本地 RPC（2.4.2 回退路径）

    /// 本地 RPC 调用前的 TOCTOU 复查 + 传输（生产与测试 override 共用入口）。
    /// 复查失败抛 networkError（「本地服务身份已变化」）；取消原样上抛。
    private func localPostChecked(
        server: ServerInfo,
        path: String,
        headers: [String: String],
        body: Data
    ) async throws -> (Data, Int) {
        guard ownershipChecker(server) else {
            throw QuotaError.networkError(
                "Antigravity 本地服务身份已变化（pid=\(server.pid), port=\(server.httpsPort)），请重试刷新"
            )
        }
        return try await localPost(server, path, headers, body)
    }

    /// 组装本地 RPC 请求头：Content-Type 恒带；`x-codeium-csrf-token` 仅在
    /// server 携带非空 CSRF 时附加（CLI 后端不暴露 CSRF）。
    private nonisolated static func localHeaders(csrfToken: String?) -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        if let csrf = StringUtilities.trimmedOrNil(csrfToken) {
            headers["x-codeium-csrf-token"] = csrf
        }
        return headers
    }

    /// 本地 RPC typed 调用： fatal 路径（quota）。非 2xx → httpError；解析失败 →
    /// decodingError。
    private func localPostDecodable<Response: Decodable>(
        server: ServerInfo,
        path: String,
        body: Data = Data("{}".utf8)
    ) async throws -> Response {
        let data = try await localPostData(
            server: server,
            path: path,
            body: body
        )
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

    /// 本地 RPC 可选调用：任何失败（TOCTOU / 传输 / 非 2xx / 解析）都返回 nil，
    /// 不影响主额度——对齐旧 `postOptional` 语义。
    private func localPostOptional<Response: Decodable>(
        server: ServerInfo,
        path: String,
        body: Data? = nil
    ) async -> Response? {
        do {
            let data = try await localPostData(
                server: server,
                path: path,
                body: body ?? Data("{}".utf8)
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Response.self, from: data)
        } catch {
            logWarn("[antigravity] 可选接口 \(path) 失败，将使用兜底: \(HTTPRequestLogSanitizer.networkErrorDescription(error))")
            return nil
        }
    }

    /// 本地 RPC 数据路径：CSRF 头组装 → TOCTOU 复查 → 传输 → 非 2xx 抛 httpError。
    private func localPostData(
        server: ServerInfo,
        path: String,
        body: Data
    ) async throws -> Data {
        let headers = Self.localHeaders(csrfToken: server.csrfToken)
        let (data, status) = try await localPostChecked(
            server: server,
            path: path,
            headers: headers,
            body: body
        )
        guard (200..<300).contains(status) else {
            throw QuotaError.httpError(status: status, body: "响应 \(data.count) bytes")
        }
        return data
    }

    /// 生产传输：POST `https://127.0.0.1:<port><path>`（共享 session 的
    /// LocalhostTrustDelegate 信任本地自签证书；8 MiB standardQuota 上限；
    /// 超时复用 HTTPTimeouts.antigravityRequest/Resource 15s/20s）。
    private static func performLocalPost(
        server: ServerInfo,
        path: String,
        headers: [String: String],
        body: Data
    ) async throws -> (Data, Int) {
        guard let url = URL(string: "https://127.0.0.1:\(server.httpsPort)\(path)") else {
            throw QuotaError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let redactedPath = HTTPRequestLogSanitizer.sanitizedURL(url)
        logInfo("[antigravity] POST \(url.absoluteString) (kind=\(server.kind.rawValue))")
        let startedAt = Date()
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await CappedDownloader.data(
                for: request,
                session: session,
                maxBytes: ResponseByteLimits.standardQuota,
                redactedPath: redactedPath
            )
        } catch let error as URLError where error.code == .cancelled {
            // 保留取消错误类型，让 AppState/CancellationFilter 走 deferred 路径。
            throw error
        } catch let error as URLError {
            throw QuotaError.networkError(
                "Antigravity RPC 失败: \(HTTPRequestLogSanitizer.networkErrorDescription(error))"
            )
        } catch let quotaError as QuotaError {
            throw quotaError
        }
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        logInfo("[antigravity] ← \(http.statusCode) \(data.count) bytes in \(elapsedMs)ms \(url.lastPathComponent)")
        return (data, http.statusCode)
    }

    // MARK: - Mapping

    /// 账号信息：(planLabel, accountEmail)。任一为 nil 表示该字段无法确定。
    struct AccountInfo {
        let planLabel: String?
        let accountEmail: String?
    }

    /// 解析账号信息（本地回退路径）：邮箱取 `userStatus.email`；套餐名优先级
    /// `userStatus.userTier.name` > `userStatus.planStatus.planInfo.*` >
    /// `GetLoadCodeAssist.currentTier.name`（tier 回退链照 spec）。
    /// 远端主路径不用本函数：邮箱 = Keychain `id_token_email`，tier =
    /// `LoadCodeAssistRemoteResponse.tierName`（currentTier.name → paidTier.name
    /// → paidTier.id，远端无 `planStatus.planInfo` 对应字段）。
    nonisolated static func parseAccount(
        userStatus: UserStatus?,
        fallbackTier: String?
    ) -> AccountInfo {
        let email = StringUtilities.trimmedOrNil(userStatus?.email)
        let tier = StringUtilities.trimmedOrNil(userStatus?.userTier?.name)
        let planInfo = userStatus?.planStatus?.planInfo
        let planName = StringUtilities.firstTrimmed(
            planInfo?.planDisplayName,
            planInfo?.displayName,
            planInfo?.productName,
            planInfo?.planName,
            planInfo?.planShortName
        )
        let planLabel = StringUtilities.firstTrimmed(tier, planName, StringUtilities.trimmedOrNil(fallbackTier))
        return AccountInfo(planLabel: planLabel, accountEmail: email)
    }

    /// group/bucket 归一化（远端与本地回退共用）：单 group 的 bucket 数据异常
    /// （缺/非法 remainingFraction）只跳过该 group 并记日志，不作废整次额度刷新
    /// —— 对齐 postOptional 的部分可用语义；全部 group 都不可用时仍然抛错。
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
