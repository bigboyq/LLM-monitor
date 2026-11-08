import Foundation

/// Antigravity 额度抓取器
///
/// **阶段一（2026-11-08）：额度/账号主路径走 Keychain 凭据 + 远端 Google API**——
/// Antigravity 未运行时额度照常工作（token 未过期时）：
///
/// 1. 从登录钥匙串读 `gemini` / `antigravity` 条目（Antigravity 客户端写入并
///    自行续期，见 `AntigravityCredential`），本地判定 `token.expiry`
/// 2. POST `https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`
///    （body `{}`；Bearer access_token + hub 身份 UA；主机回退序 Daily →
///    生产 cloudcode-pa → sandbox，仅 401 终止，其余非 2xx 换下一主机）
/// 3. `.full` 追加 `v1internal:loadCodeAssist` 取 tier（`currentTier.name` →
///    `paidTier.name` → `paidTier.id`）；邮箱直接用 Keychain 的 `id_token_email`
///
/// **阶段二b（2026-11-08）**：本地用量路径退役本地 RPC
/// `GetCascadeTrajectoryGeneratorMetadata`——scanner 直读会话
/// `.db`（`AntigravitySessionDBReader`），与额度路径无关。
///
/// **2.4.2（keychain 陈旧窗口回退）**：keychain 条目只在登录 / agy 使用时被写，
/// IDE 运行期间刷新的 token 只在其内存（经 host bridge 分发），keychain 会陈旧；
/// 而运行中的 language_server 持有 bridge 新凭据且本地 RPC 一直可用。因此
/// fetch 按以下决策树取额度：
///
/// 1. 凭据解析成功且未过期 → 远端路径（不变）；远端配额 401（轮询间隙 token
///    恰好过期）→ 同样转入本地回退
/// 2. 凭据缺失/过期 → 本地回退：进程发现（`AntigravityProcessDiscovery`，
///    pgrep + lsof + CSRF，原排序规则）→ 本地 `RetrieveUserQuotaSummary`
///    （`response` 包装形状，group/bucket 归一化与远端共用）
/// 3. 回退时账号信息用本地 `GetUserStatus`（email/tier，仅 `.full`，可选失败
///    不致命，tier 回退链照 spec）；本地 RPC 成功后不再打远端
/// 4. 回退失败时：凭据缺失或已过期 → `credentialExpired`（打开 Antigravity 可
///    继续监控额度）；远端 401 起始且无本地后端 → 同一文案；其余错误按现有
///    错误路径上抛
///
/// **2.4.3（来源标记）**：两条成功路径各自给返回的 `QuotaInfo` 打来源标记
/// `antigravityQuotaSource`（远端 → `.remoteCloudCode`，本地回退 →
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
    /// 本地回退路径的进程发现（默认 pgrep + lsof；测试注入固定 ServerInfo 或抛错）。
    private let localServerDiscovery: @Sendable () async throws -> ServerInfo
    /// 本地 RPC 传输（默认 CappedDownloader + 共享 session；测试注入记录调用）。
    private let localPost: LocalPostOverride
    /// 本地服务 TOCTOU 复查（默认 lsof；测试可注入 true / false）。
    private let ownershipChecker: LocalOwnershipChecker

    init(
        credentialReader: @escaping @Sendable () -> AntigravityCredential? = {
            AntigravityKeychain.readCredential()
        },
        hubVersionProvider: @escaping @Sendable () -> String? = {
            AntigravityFetcher.readAntigravityAppVersion()
        },
        remotePostOverride: RemotePostOverride? = nil,
        localServerDiscovery: @escaping @Sendable () async throws -> ServerInfo = {
            try await AntigravityFetcher.discoverServerAsync()
        },
        localPostOverride: LocalPostOverride? = nil,
        localOwnershipChecker: @escaping LocalOwnershipChecker = {
            AntigravityFetcher.serverStillOwnsEndpoint($0)
        }
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
    }

    func hasLocalAuth() -> Bool {
        // 真正的探测在 async checkLocalAuth()（读一次钥匙串）；这个方法会在菜单
        // 和配置变更的主线程路径中频繁调用，这里返回 true 表示"潜在可用"，
        // 把凭据探测推迟到 async 路径，避免打开菜单或设置窗口时发生可感知卡顿。
        true
    }

    /// 凭据可读（条目存在且结构可解析）即视为可用。token 过期不在此判定：
    /// 过期/缺失时 fetch() 回退本地 RPC（`AntigravityProcessDiscovery`），全部
    /// 失败才抛 `credentialExpired`。auth 探测仍只看钥匙串可读性（不跑 pgrep）。
    func checkLocalAuth() async -> Bool {
        credentialReader() != nil
    }

    // MARK: - 额度抓取决策树

    func fetch(mode: RefreshMode) async throws -> QuotaInfo {
        let credential = credentialReader()
        if let credential, !credential.isExpired() {
            do {
                return try await fetchRemote(credential: credential, mode: mode)
            } catch let error as QuotaError where error == QuotaError.credentialExpired {
                // 远端 401：轮询间隙 keychain token 恰好过期（IDE 运行期间刷新的
                // token 只在其内存）。转入本地回退，不再重试远端。
                logWarn("[antigravity] 远端配额 401，回退本地 language_server RPC")
                return try await fetchLocalFallback(
                    origin: .remoteUnauthorized,
                    credential: credential,
                    mode: mode
                )
            }
        }
        let origin: LocalFallbackOrigin = credential == nil ? .missingCredential : .expiredCredential
        if let credential {
            logWarn("[antigravity] keychain token 已过期（expiry=\(credential.expiry)），回退本地 language_server RPC")
        } else {
            logWarn("[antigravity] 未读取到 keychain 凭据，尝试本地 language_server RPC 回退")
        }
        return try await fetchLocalFallback(origin: origin, credential: credential, mode: mode)
    }

    /// 回退触发原因（决定回退失败时的错误呈现，见 `fetchLocalFallback`）。
    private enum LocalFallbackOrigin {
        /// keychain 凭据缺失（未登录 / 条目不可解析）。
        case missingCredential
        /// keychain 凭据本地过期判定 `now >= expiry`。
        case expiredCredential
        /// 凭据新鲜但远端配额接口 401。
        case remoteUnauthorized
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

    /// 本地回退路径（2.4.2）：进程发现 → 本地 quota RPC（+ `.full` 时的
    /// GetUserStatus / GetLoadCodeAssist）。本地 RPC 成功后不再打远端。
    ///
    /// 失败呈现（决策树 d）：
    /// - 取消原样上抛（AppState/CancellationFilter deferred 路径）
    /// - 无本地后端（未发现进程 / 进程未监听端口）→ 三种 origin 都落
    ///   `credentialExpired`（打开 Antigravity 可继续监控额度）
    /// - 凭据缺失/过期 origin 下，本地 RPC 报错（TOCTOU / 传输 / 非 2xx / 解析）
    ///   同样落 `credentialExpired`
    /// - 远端 401 origin 下，本地 RPC 报错按现有错误路径上抛（后端在但 RPC 失败
    ///   是真实的本地故障，不该伪装成 token 过期）
    private func fetchLocalFallback(
        origin: LocalFallbackOrigin,
        credential: AntigravityCredential?,
        mode: RefreshMode
    ) async throws -> QuotaInfo {
        let server: ServerInfo
        do {
            server = try await localServerDiscovery()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            logWarn("[antigravity] 本地回退失败（未发现可用后端）：\(HTTPRequestLogSanitizer.networkErrorDescription(error))")
            throw QuotaError.credentialExpired
        }

        do {
            return try await fetchLocal(server: server, credential: credential, mode: mode)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            guard origin == .missingCredential || origin == .expiredCredential else {
                throw error
            }
            logWarn("[antigravity] 本地回退 RPC 失败：\(HTTPRequestLogSanitizer.networkErrorDescription(error))")
            throw QuotaError.credentialExpired
        }
    }

    /// 本地 RPC 抓取（已发现 server）。quota 致命；GetUserStatus / GetLoadCodeAssist
    /// 可选失败不致命（对齐旧 postOptional 语义）。
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
